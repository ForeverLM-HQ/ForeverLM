import SwiftUI
import AppKit
import AuthenticationServices
import Combine
import UniformTypeIdentifiers
import EventKit

enum SettingsPane: Hashable {
    /// Your name, the day's hours, the memory review.
    case general
    /// The data story, iCloud sync, and the learner's teams.
    case dataPrivacy
    /// The open team's own settings, scoped to the active library the way
    /// Claude's organization settings follow the selected organization. They
    /// open in a Settings of their own (`SettingsScope.team`), never beside
    /// the learner's personal panes.
    case teamGeneral
    case teamMembers
    case sources
    case plugins
    /// The models the chat offers, and its default.
    case aiChatModels
    /// The models background work runs on: the Text-only and Multimodal
    /// defaults, and any task given a model of its own.
    case aiBackgroundModels
    /// Dictation and text-to-speech.
    case aiTextToSpeech
    /// The model that draws pictures.
    case aiImages
    /// The model and resolution that film explainer videos.
    case aiVideos
    /// Paying for ForeverLM: the Early user deal, and switching or cancelling
    /// a subscription bought before the lock.
    case aiBilling
    /// What runs AI and what it cost: the own key, Free mode, spending and
    /// limits, and the activity by task.
    case aiUsage
    case mcp
    case mcpPairing
    case xPlugin
    case youtubePlugin
    case googleDrivePlugin
    case appleCalendarPlugin
    case slackPlugin
    case linearPlugin
    case githubPlugin
    case notionPlugin
    case userPlugins
}

/// Which Settings a pane belongs to. The learner's own settings and the open
/// team's are two separate surfaces, the way Claude and Codex keep
/// organization settings apart from the account's (product owner, 2026-09-22):
/// each has its own sidebar, and a link from one to the other reopens
/// Settings in the other scope.
enum SettingsScope: Hashable {
    case personal
    case team

    init(pane: SettingsPane?) {
        switch pane {
        case .teamGeneral, .teamMembers: self = .team
        default: self = .personal
        }
    }
}

enum AssistantIntegrationSettings {
    static let enabledKey = "studio.assistantIntegrationsEnabled"
    static let statusLightVisibleKey = "studio.showMCPStatusLight"

    static var isEnabled: Bool {
        guard UserDefaults.standard.object(forKey: enabledKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: enabledKey)
    }
}

/// Billing, model, plugin, and app settings — or, in the team scope, the
/// open team's settings and nothing else.
///
/// Sidebar + detail, like the macOS System Settings window: the left rail
/// lists every pane grouped by area and stays put, the right column shows the
/// selected pane. Plugin setup pages are subordinate to a pane, so they
/// still push onto the detail column with a back bar.
struct SettingsView: View {
    private let scope: SettingsScope
    @State private var selection: SettingsPane
    @State private var path: [SettingsPane]
    @State private var searchText = ""

    init(initialPane: SettingsPane? = nil) {
        scope = SettingsScope(pane: initialPane)
        let start = Self.navigation(for: initialPane)
        _selection = State(initialValue: start.selection)
        _path = State(initialValue: start.path)
    }

    @Environment(ManagedAIAccountModel.self) private var account

    var body: some View {
        // A locked app (the free days over, nothing paid) keeps only Billing
        // and Sign Out here, as its pay screen does.
        if account.isAppLocked {
            lockedBody
        } else {
            unlockedBody
        }
    }

    private var lockedBody: some View {
        VStack(spacing: 0) {
            paneView(for: .aiBilling)
            Divider()
            HStack {
                Spacer()
                Button("Sign Out") { account.signOut() }
                    .accessibilityIdentifier("settings.locked.signOut")
            }
            .padding(12)
        }
        .navigationTitle("Settings")
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 760, idealWidth: 860)
    }

    private var unlockedBody: some View {
        HStack(spacing: 0) {
            SettingsSidebar(
                scope: scope,
                searchText: $searchText,
                selection: selection,
                onSelect: { navigate(to: $0) }
            )
            Divider()
            detailColumn
        }
        .navigationTitle("Settings")
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 760, idealWidth: 860)
    }

    private var detailColumn: some View {
        NavigationStack(path: $path) {
            paneView(for: selection)
                .navigationDestination(for: SettingsPane.self) { pane in
                    paneView(for: pane)
                        .safeAreaInset(edge: .top, spacing: 0) { backBar }
                }
        }
    }

    /// Maps a requested pane to a sidebar selection plus any pushed detail:
    /// deep links to a page that lives *inside* a pane (plugin setup) select
    /// the owning pane and push the page onto its detail column.
    private static func navigation(for pane: SettingsPane?) -> (selection: SettingsPane, path: [SettingsPane]) {
        guard let pane else { return (.general, []) }
        switch pane {
        case .xPlugin, .youtubePlugin, .googleDrivePlugin, .appleCalendarPlugin,
             .slackPlugin, .linearPlugin, .githubPlugin, .notionPlugin, .userPlugins:
            return (.plugins, [pane])
        default:
            return (pane, [])
        }
    }

    private func navigate(to pane: SettingsPane) {
        // A pane of the other scope is a different Settings: reopen the
        // overlay there rather than showing it in this sidebar.
        guard SettingsScope(pane: pane) == scope else {
            NotificationCenter.default.post(name: .requestOpenStudioSettings, object: pane)
            return
        }
        let destination = Self.navigation(for: pane)
        selection = destination.selection
        path = destination.path
    }

    /// The settings overlay has no window toolbar, so the NavigationStack's
    /// system back button never renders — every pushed pane needs this bar.
    private var backBar: some View {
        HStack {
            Button {
                if !path.isEmpty { path.removeLast() }
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.hoverWash)
            .keyboardShortcut("[", modifiers: .command)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private func paneView(for pane: SettingsPane) -> some View {
        switch pane {
        case .general:
            GeneralSettingsDetailView()
        case .dataPrivacy:
            DataPrivacySettingsDetailView()
        case .teamGeneral:
            TeamGeneralSettingsDetailView(onShowAllTeams: { navigate(to: .dataPrivacy) })
        case .teamMembers:
            TeamMembersSettingsDetailView(onShowAllTeams: { navigate(to: .dataPrivacy) })
        case .sources:
            SourcesSettingsDetailView()
        case .plugins:
            PluginsSettingsDetailView()
        case .aiChatModels:
            ChatModelsSettingsDetailView(
                pane: .chat,
                onRequestAPIKey: { navigate(to: .aiUsage) }
            )
        case .aiBackgroundModels:
            ChatModelsSettingsDetailView(
                pane: .background,
                onRequestAPIKey: { navigate(to: .aiUsage) }
            )
        case .aiTextToSpeech:
            VoiceSettingsDetailView()
        case .aiImages:
            ImageGenerationSettingsDetailView()
        case .aiVideos:
            VideoGenerationSettingsDetailView()
        case .aiBilling:
            BillingSettingsDetailView()
        case .aiUsage:
            AIUsageSettingsDetailView(
                onOpenBilling: { navigate(to: .aiBilling) },
                onOpenSettings: { navigate(to: $0) }
            )
        case .mcp:
            MCPSettingsDetailView()
        case .mcpPairing:
            MCPSettingsDetailView(showsPairingCode: true)
        case .xPlugin:
            PluginSetupDetailView(
                title: "X",
                description: "Sync bookmarks into Studio."
            ) {
                XPluginSettingsView()
            }
        case .youtubePlugin:
            PluginSetupDetailView(
                title: "YouTube",
                description: "Import Liked videos or a playlist named ForeverLM."
            ) {
                YouTubeConnectionSettingsView()
            }
        case .googleDrivePlugin:
            PluginSetupDetailView(
                title: "Google Drive",
                description: "Import meeting recordings and transcripts from a folder you choose."
            ) {
                GoogleDriveConnectionSettingsView()
            }
        case .appleCalendarPlugin:
            PluginSetupDetailView(
                title: "Calendar",
                description: "Your Mac's calendars, for the Now chip and planning in a chat."
            ) {
                AppleCalendarConnectionSettingsView()
            }
        case .slackPlugin:
            PluginSetupDetailView(
                title: "Slack",
                description: "Read preparation material from channels you choose."
            ) {
                SlackPluginSettingsView()
            }
        case .linearPlugin:
            PluginSetupDetailView(
                title: "Linear",
                description: "Read issues, teams and projects as you. Read-only."
            ) {
                LinearPluginSettingsView()
            }
        case .githubPlugin:
            PluginSetupDetailView(
                title: "GitHub",
                description: "Read repositories, issues and pull requests as you. Read-only."
            ) {
                GitHubPluginSettingsView()
            }
        case .notionPlugin:
            PluginSetupDetailView(
                title: "Notion",
                description: "Read the pages and databases you share as you. Read-only."
            ) {
                NotionPluginSettingsView()
            }
        case .userPlugins:
            UserPluginsSettingsDetailView()
        }
    }

}

private struct SettingsSearchItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let keywords: [String]
    let destination: SettingsPane
    let icon: String
    let tint: Color

    func matches(_ query: String) -> Bool {
        let haystack = ([title, subtitle] + keywords)
            .joined(separator: " ")
            .lowercased()
        return haystack.localizedStandardContains(query)
    }
}

private enum SettingsSearchCatalog {
    static func items() -> [SettingsSearchItem] {
        [
            SettingsSearchItem(
                id: "general",
                title: "General",
                subtitle: "App",
                keywords: ["name", "your name", "rename", "display name", "day", "hours", "start", "end", "plan the day", "notification"],
                destination: .general,
                icon: "gearshape.fill",
                tint: .gray
            ),
            SettingsSearchItem(
                id: "memory",
                title: "Memory review",
                subtitle: "General",
                keywords: ["memory", "review", "today's review", "prepare", "ready", "morning", "reminder", "daily", "minutes", "how long", "close the day"],
                destination: .general,
                icon: MemoryReviewSession.sidebarIcon,
                tint: .pink
            ),
            SettingsSearchItem(
                id: "chat",
                title: "Chat",
                subtitle: "AI Models",
                keywords: ["model", "models", "ai", "llm", "provider", "default model", "picker"],
                destination: .aiChatModels,
                icon: "bubble.left.and.bubble.right.fill",
                tint: .blue
            ),
            SettingsSearchItem(
                id: "free-mode",
                title: AIFreeMode.switchTitle,
                subtitle: "AI Usage",
                keywords: ["free", "free models", "openrouter", "free requests", "requests left", "daily quota", "rate limit"],
                destination: .aiUsage,
                icon: "gift.fill",
                tint: .green
            ),
            SettingsSearchItem(
                id: "background-work",
                title: "Background",
                subtitle: "AI Models",
                keywords: ["background", "background work", "background model", "tasks", "per task", "specific tasks", "text-only", "multimodal", "reads images", "backup", "transcripts", "cleanup", "metadata", "read aloud preparation", "free model", "cost"],
                destination: .aiBackgroundModels,
                icon: "gearshape.2.fill",
                tint: .mint
            ),
            SettingsSearchItem(
                id: "voice",
                title: "Voice",
                subtitle: "AI Models",
                keywords: ["dictation", "speech-to-text", "stt", "microphone", "tts", "text-to-speech", "read aloud", "listen", "speed"],
                destination: .aiTextToSpeech,
                icon: "speaker.wave.2.fill",
                tint: .indigo
            ),
            SettingsSearchItem(
                id: "images",
                title: "Images",
                subtitle: "AI Models",
                keywords: ["image", "image model", "picture", "draw", "drawing", "icon", "gpt image", "gemini"],
                destination: .aiImages,
                icon: "photo.fill",
                tint: .orange
            ),
            SettingsSearchItem(
                id: "videos",
                title: "Videos",
                subtitle: "AI Models",
                keywords: ["video", "video model", "explainer", "film", "veo", "kling", "resolution", "720p", "1080p"],
                destination: .aiVideos,
                icon: "film.fill",
                tint: .red
            ),
            SettingsSearchItem(
                id: "billing",
                title: "Billing",
                subtitle: "Account",
                keywords: ["plan", "early user deal", "deal", "paid once", "pay once", "buy", "purchase", "free days", "unlock", "monthly", "subscription", "manage subscription", "cancel", "cancel plan", "cancel subscription", "unsubscribe", "renew", "payment", "card", "stripe", "receipts", "invoices"],
                destination: .aiBilling,
                icon: "creditcard.fill",
                tint: .purple
            ),
            SettingsSearchItem(
                id: "ai-usage",
                title: "AI Usage",
                subtitle: "Account",
                keywords: ["own key", "api key", "key", "byok", "openrouter", "credits", "balance", "spending cap", "spending limit", "monthly limit", "daily limit", "usage", "spend", "cost", "activity", "dashboard"],
                destination: .aiUsage,
                icon: "chart.bar.fill",
                tint: .green
            ),
            SettingsSearchItem(
                id: "data-privacy",
                title: "Data & Privacy",
                subtitle: "Account",
                keywords: ["privacy", "data", "training", "train", "retention", "logging", "privacy policy", "gdpr", "icloud", "sync", "storage", "space", "disk", "full", "team", "teams", "share", "shared library", "create team", "collaborate"],
                destination: .dataPrivacy,
                icon: "hand.raised.fill",
                tint: .gray
            ),
            SettingsSearchItem(
                id: "sources",
                title: "Sources",
                subtitle: "Connections",
                keywords: ["library", "search", "reading list", "safari", "chrome", "brave", "zoom", "transcripts"],
                destination: .sources,
                icon: "books.vertical.fill",
                tint: .teal
            ),
            SettingsSearchItem(
                id: "plugins",
                title: "Plugins",
                subtitle: "Connections",
                keywords: ["integrations", "custom plugins", "build your own"],
                destination: .plugins,
                icon: "point.3.connected.trianglepath.dotted",
                tint: .indigo
            ),
            SettingsSearchItem(
                id: "mcp",
                title: "MCP",
                subtitle: "Connections",
                keywords: ["claude", "chatgpt", "codex", "gemini", "grok", "meta", "muse", "cursor", "assistant", "tunnel", "server", "status light", "dot", "account button"],
                destination: .mcp,
                icon: "link.badge.plus",
                tint: .purple
            ),
            SettingsSearchItem(
                id: "x-plugin",
                title: "X",
                subtitle: "Plugins",
                keywords: ["twitter", "bookmarks", "posts"],
                destination: .xPlugin,
                icon: "at",
                tint: .gray
            ),
            SettingsSearchItem(
                id: "youtube",
                title: "YouTube",
                subtitle: "Plugins",
                keywords: ["liked videos", "ForeverLM playlist", "channels"],
                destination: .youtubePlugin,
                icon: "play.rectangle.fill",
                tint: .red
            ),
            SettingsSearchItem(
                id: "google-drive",
                title: "Google Drive",
                subtitle: "Plugins",
                keywords: ["meetings", "transcripts", "recordings", "folder", "google"],
                destination: .googleDrivePlugin,
                icon: "folder.fill",
                tint: .blue
            ),
            SettingsSearchItem(
                id: "apple-calendar",
                title: "Calendar",
                subtitle: "Plugins",
                keywords: ["planner", "plan the day", "day", "meetings", "events", "calendar", "apple", "icloud", "google", "exchange", "outlook", "teams"],
                destination: .appleCalendarPlugin,
                icon: "calendar",
                tint: .red
            ),
            SettingsSearchItem(
                id: "slack",
                title: "Slack",
                subtitle: "Plugins",
                keywords: ["workspace", "channels", "messages", "threads"],
                destination: .slackPlugin,
                icon: "bubble.left.and.bubble.right.fill",
                tint: Color(red: 0.24, green: 0.06, blue: 0.24)
            ),
            SettingsSearchItem(
                id: "linear",
                title: "Linear",
                subtitle: "Plugins",
                keywords: ["issues", "tickets", "projects", "roadmap"],
                destination: .linearPlugin,
                icon: "checklist",
                tint: Color(red: 0.37, green: 0.42, blue: 0.82)
            ),
            SettingsSearchItem(
                id: "github",
                title: "GitHub",
                subtitle: "Plugins",
                keywords: ["repository", "repo", "code", "issues", "pull requests"],
                destination: .githubPlugin,
                icon: "chevron.left.forwardslash.chevron.right",
                tint: Color(red: 0.14, green: 0.16, blue: 0.18)
            ),
            SettingsSearchItem(
                id: "notion",
                title: "Notion",
                subtitle: "Plugins",
                keywords: ["pages", "databases", "wiki", "notes"],
                destination: .notionPlugin,
                icon: "doc.text",
                tint: Color(red: 0.12, green: 0.12, blue: 0.12)
            ),
            SettingsSearchItem(
                id: "user-plugins",
                title: "Build Your Own Plugin",
                subtitle: "Plugins",
                keywords: ["custom", "connector", "ingest", "readwise", "rss", "script"],
                destination: .userPlugins,
                icon: "puzzlepiece.extension.fill",
                tint: .indigo
            ),
        ]
    }
}

/// The persistent left rail: search on top, panes grouped by area, and the
/// app identity as a footer. Search results replace the groups in place and
/// jump straight to the matching pane, System Settings-style.
private struct SettingsSidebar: View {
    @Environment(StudioViewModel.self) private var vm
    let scope: SettingsScope
    @Binding var searchText: String
    let selection: SettingsPane
    let onSelect: (SettingsPane) -> Void

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredSearchItems: [SettingsSearchItem] {
        let query = trimmedSearchText.lowercased()
        guard !query.isEmpty else { return [] }
        return SettingsSearchCatalog.items().filter { $0.matches(query) }
    }

    private var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    var body: some View {
        VStack(spacing: 0) {
            switch scope {
            case .personal:
                searchField
                    .padding(.horizontal, 10)
                    .padding(.top, 12)
            case .team:
                // Two panes need no search; the rail names the team instead.
                teamIdentity
                    .padding(.horizontal, 17)
                    .padding(.top, 14)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if trimmedSearchText.isEmpty {
                        navigationGroups
                    } else if filteredSearchItems.isEmpty {
                        noResults
                    } else {
                        searchResults
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            footer
        }
        .frame(width: 232)
    }

    private var teamIdentity: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(vm.activeTeam?.name ?? "No team open")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text("Team settings")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search settings", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.hoverWash)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var navigationGroups: some View {
        switch scope {
        case .personal: personalGroups
        case .team: teamGroups
        }
    }

    /// The open team's settings follow the active library, the way Claude's
    /// organization settings follow the selected organization: switch
    /// libraries in the account menu and the account menu's entry names the
    /// other team, or goes away.
    @ViewBuilder
    private var teamGroups: some View {
        if let team = vm.activeTeam {
            Group {
                groupHeader(team.canEdit ? "Team" : "Team · Read only")
                row(.teamGeneral, icon: team.canEdit ? "person.2.fill" : "lock.fill", title: "General", tint: .green)
                row(.teamMembers, icon: "person.crop.circle.badge.checkmark", title: "Members", tint: .green)
            }
        }
    }

    @ViewBuilder
    private var personalGroups: some View {
        Group {
            groupHeader("App")
            row(.general, icon: "gearshape.fill", title: "General", tint: .gray)
        }

        Group {
            groupHeader("AI Models")
            row(.aiChatModels, icon: "bubble.left.and.bubble.right.fill", title: "Chat", tint: .blue)
            row(.aiTextToSpeech, icon: "speaker.wave.2.fill", title: "Voice", tint: .indigo)
            row(.aiImages, icon: "photo.fill", title: "Images", tint: .orange)
            row(.aiVideos, icon: "film.fill", title: "Videos", tint: .red)
            row(.aiBackgroundModels, icon: "gearshape.2.fill", title: "Background", tint: .mint)
        }

        Group {
            groupHeader("Account")
            row(.aiBilling, icon: "creditcard.fill", title: "Billing", tint: .purple)
            row(.aiUsage, icon: "chart.bar.fill", title: "AI Usage", tint: .green)
            row(.dataPrivacy, icon: "hand.raised.fill", title: "Data & Privacy", tint: .gray)
        }

        Group {
            groupHeader("Connections")
            row(.sources, icon: "books.vertical.fill", title: "Sources", tint: .teal)
            row(.plugins, icon: "point.3.connected.trianglepath.dotted", title: "Plugins", tint: .indigo)
            row(.mcp, icon: "link.badge.plus", title: "MCP", tint: .purple)
        }
    }

    private func row(_ pane: SettingsPane, icon: String, title: String, tint: Color) -> some View {
        SettingsSidebarRow(
            icon: icon,
            title: title,
            tint: tint,
            isSelected: isSelected(pane),
            action: { onSelect(pane) }
        )
    }

    private func isSelected(_ pane: SettingsPane) -> Bool {
        if selection == pane { return true }
        // Pairing deep links land on the MCP pane with the code revealed.
        return pane == .mcp && selection == .mcpPairing
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(filteredSearchItems) { item in
                SettingsSidebarSearchRow(item: item) { activate(item) }
            }
        }
        .padding(.top, 10)
    }

    private func activate(_ item: SettingsSearchItem) {
        onSelect(item.destination)
    }

    private var noResults: some View {
        Text("No results for “\(trimmedSearchText)”")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(nsImage: AppIconImage.shared)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text("ForeverLM")
                    .font(.system(size: 11, weight: .medium))
                if let appVersion {
                    Text(RunningBuildChannel.isBeta ? "Version \(appVersion) Beta" : "Version \(appVersion)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// One sidebar entry: a small tinted icon chip and a label, with a persistent
/// wash when selected and the shared hover wash otherwise.
private struct SettingsSidebarRow: View {
    let icon: String
    let title: String
    let tint: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                SettingsSidebarIcon(icon: icon, tint: tint)
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
        }
        .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0))
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.08 : 0))
        )
    }
}

/// A search hit in the sidebar: same shape as a nav row plus the breadcrumb
/// subtitle, since results can point deep into a pane.
private struct SettingsSidebarSearchRow: View {
    let item: SettingsSearchItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                SettingsSidebarIcon(icon: item.icon, tint: item.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
        }
        .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0))
    }
}

private struct SettingsSidebarIcon: View {
    let icon: String
    let tint: Color

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .fill(tint.gradient)
            )
    }
}

/// Data & Privacy › iCloud: whether the library is in sync, with the one
/// button that pushes it, how much of the learner's iCloud it takes up, and the
/// storage notices when iCloud is full or signed out. Was its own pane until 2026-09-24; the per-change list of
/// pending and refused records was a diagnostic and went then.
struct ICloudSyncSettingsSection: View {
    @ObservedObject private var status = CloudKitSyncStatusCenter.shared
    @State private var isRequestingSync = false

    private var needsAttention: Bool { status.conflictCount > 0 }

    private var title: String {
        if needsAttention {
            let count = status.conflictCount.formatted()
            return status.conflictCount == 1
                ? "1 change needs attention"
                : "\(count) changes need attention"
        }

        switch status.phase {
        case .idle:
            return "Up to date"
        case .sending(let remaining, _):
            return remaining == 1 ? "Uploading 1 change…" : "Uploading \(remaining.formatted()) changes…"
        case .receiving:
            return "Receiving changes…"
        case .backingOff(let remaining, _):
            return remaining == 1 ? "Uploading 1 change…" : "Uploading \(remaining.formatted()) changes…"
        case .waitingToRetry(let remaining, _):
            return remaining == 1 ? "1 change is waiting to retry" : "\(remaining.formatted()) changes are waiting to retry"
        }
    }

    private var detail: String? {
        if needsAttention {
            return "Retry to resolve changes iCloud previously refused."
        }

        switch status.phase {
        case .idle:
            guard let lastCompleted = status.lastCompleted else { return nil }
            return "Last synced \(lastCompleted.formatted(date: .abbreviated, time: .shortened))"
        case .sending(let remaining, let total):
            return "\(remaining.formatted()) of \(total.formatted()) changes remaining"
        case .receiving(let received):
            return "\(received.formatted()) changes received"
        case .backingOff(let remaining, let total):
            // A paced drain sits on the same count between windows. Saying so
            // is what keeps a still count from reading as a stuck one.
            return "\(remaining.formatted()) of \(total.formatted()) changes remaining · next batch shortly"
        case .waitingToRetry:
            return "ForeverLM will retry automatically."
        }
    }

    private var icon: String {
        if needsAttention { return "exclamationmark.triangle.fill" }
        switch status.phase {
        case .idle: return "checkmark.circle.fill"
        case .sending, .backingOff: return "arrow.up.circle.fill"
        case .receiving: return "arrow.down.circle.fill"
        case .waitingToRetry: return "clock.fill"
        }
    }

    private var tint: Color {
        if needsAttention { return .orange }
        switch status.phase {
        case .idle: return .green
        case .sending, .backingOff, .receiving: return .blue
        case .waitingToRetry: return .orange
        }
    }

    private var syncIsActive: Bool {
        // Backing off is an active drain the engine owns the timing of, so the
        // button stays out of its way: forcing a send during the pause is a
        // no-op at best and re-arms the rate limiter at worst.
        switch status.phase {
        case .sending, .backingOff, .receiving: return true
        case .idle, .waitingToRetry: return false
        }
    }

    private var actionTitle: String {
        shouldRetry ? "Retry now" : "Sync now"
    }

    private var shouldRetry: Bool {
        if needsAttention { return true }
        if case .waitingToRetry = status.phase { return true }
        return false
    }

    private func requestSync() async {
        let storage = StorageService()
        if shouldRetry {
            await storage.retryCloudKitNow()
        } else {
            await storage.syncCloudKitNow()
        }
    }

    var body: some View {
        SettingsSection(
            title: "iCloud",
            description: "Your library syncs through your own iCloud to your other devices and teams."
        ) {
            ICloudStorageNotices()

            LibraryMoveSettingsCard()

            ICloudMigrationSettingsView()

            SettingsCard {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)
                        if let detail {
                            Text(detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 16)

                    Button(actionTitle) {
                        Task { @MainActor in
                            isRequestingSync = true
                            await requestSync()
                            isRequestingSync = false
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRequestingSync || syncIsActive)
                }

                Divider().padding(.vertical, 10)

                ICloudStorageUsageRow()
            }
        }
    }
}

/// Data & Privacy › iCloud, above the sync card: where the library's move to the new iCloud store stands
/// (docs/cloudkit-schema-design.md §13.3 step 3), the read-only window of its first minutes, and the
/// question a tripped 5% guard asks (Apply, or Not this library). Nothing shows under generation 1, or
/// once the move is done.
private struct LibraryMoveSettingsCard: View {
    @State private var notice = ActivationNotice.shared
    @State private var isAnswering = false

    private func answer(_ apply: Bool) {
        isAnswering = true
        Task {
            let storage = StorageService()
            try? await storage.performStoreWork { store in
                if apply { try ActivationQuestion.answerApply(store: store) } else { try ActivationQuestion.answerNotThisLibrary(store: store) }
            }
            ActivationStatus.shared.update(.done)
            isAnswering = false
        }
    }

    var body: some View {
        switch notice.phase {
        case .moving(let step, let total, let text):
            card(icon: "arrow.triangle.2.circlepath", tint: .blue, title: "Moving your library to the new iCloud store (step \(step) of \(total))",
                 detail: "\(text). Your library is read-only until this ends.")
        case .asking(let question):
            card(icon: "questionmark.circle.fill", tint: .orange, title: "Your old iCloud library does not look like this Mac's",
                 detail: "It would remove \(question.deleting.formatted()) of \(question.of.formatted()) items here. Nothing was changed.") {
                HStack {
                    Button("Apply") { answer(true) }
                    Button("Not this library") { answer(false) }
                }
                .disabled(isAnswering)
            }
        case .failed(let message):
            card(icon: "exclamationmark.triangle.fill", tint: .orange, title: "Your library has not moved to the new iCloud store yet", detail: message)
        case .idle, .preparing, .done:
            EmptyView()
        }
    }

    private func card<Actions: View>(icon: String, tint: Color, title: String, detail: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) -> some View {
        SettingsCard {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                actions()
            }
        }
        .accessibilityIdentifier("settings.libraryMove")
    }
}

/// Data & Privacy › iCloud: how much of the learner's iCloud ForeverLM's files
/// take up (`ICloudStorageUsage`), with Apple's own storage page beside it for
/// the exact per-app figure. Measured when the pane opens and again after each
/// sync, off the main actor; a figure already on screen stays while the next
/// one is measured, and gives way to the error if that measurement fails.
private struct ICloudStorageUsageRow: View {
    @Environment(StudioViewModel.self) private var vm
    @ObservedObject private var status = CloudKitSyncStatusCenter.shared
    @State private var usage: ICloudStorageUsage?
    @State private var failure: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.icloud")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                if let usage {
                    Text(usage.totalBytes > 0
                        ? "\(Self.format(usage.totalBytes)) in iCloud"
                        : "Nothing in iCloud yet")
                        .font(.headline)
                    if usage.totalBytes > 0 {
                        Text(Self.breakdown(usage))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else if let failure {
                    Text("Couldn't measure iCloud storage")
                        .font(.headline)
                    Text(failure)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Measuring iCloud storage…")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 16)

            Button("Manage…", action: ICloudStorageNotices.openICloudSettings)
                .buttonStyle(.bordered)
        }
        .task(id: status.lastCompleted) {
            do {
                let measured = try await ICloudStorageUsage.measure(storage: vm.storage)
                guard !Task.isCancelled else { return }
                usage = measured
                failure = nil
            } catch {
                guard !Task.isCancelled else { return }
                // An old figure left standing would hide that it is no longer
                // being measured.
                usage = nil
                failure = error.localizedDescription
            }
        }
    }

    static func format(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    static func breakdown(_ usage: ICloudStorageUsage) -> String {
        [
            ("PDFs", usage.documentBytes),
            ("Text", usage.textBytes),
            ("iCloud Drive", usage.driveBytes),
        ]
        .filter { $0.1 > 0 }
        .map { "\($0.0) \(format($0.1))" }
        .joined(separator: " · ")
    }
}

/// Controls source-family knowledge participation and Sources-panel presentation.
private struct SourcesSettingsDetailView: View {
    @Environment(StudioViewModel.self) private var vm
    @State private var zoomFolder = StudioViewModel.zoomLocalTranscriptCustomFolder
    @State private var zoomFolderContents: (transcripts: Int, recordings: Int, unconverted: Int)?
    @State private var enabledReadingListBrowsers = ReadingListBrowser.enabled
    @State private var readingListImportWindow = SourceDiscovery.ReadingListImportWindow.chosen ?? .everything

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsSection(
                    title: "Search & AI",
                    description: "Which kinds of source search and the AI draw on. Pin or unpin a tab from the tab bar itself."
                ) {
                    SettingsCard {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(vm.tabOrder.enumerated()), id: \.element) { index, tab in
                                if index > 0 {
                                    Divider()
                                }
                                sourceTabRow(tab)
                            }
                        }
                    }
                }

                readingListsSection

                zoomTranscriptsSection
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Sources")
    }

    // MARK: - Reading Lists

    /// The same per-Mac browser switches as setup's Articles step. Turning one
    /// on imports its Reading List now; turning one off stops new imports and
    /// keeps what it already brought in.
    private var readingListsSection: some View {
        SettingsSection(
            title: "Reading Lists",
            description: "Imports each browser's Reading List on this Mac."
        ) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(ReadingListBrowser.allCases.enumerated()), id: \.element) { index, browser in
                        if index > 0 {
                            Divider()
                        }
                        Toggle(isOn: readingListBrowserBinding(browser)) {
                            ReadingListBrowserLabel(browser: browser)
                        }
                        .toggleStyle(.switch)
                        .padding(.vertical, 8)
                    }
                    Divider()
                    // The backlog choice from setup's Articles step: pages saved
                    // before its cutoff are left out of every import.
                    Picker("Bring in", selection: readingListImportWindowBinding) {
                        ForEach(SourceDiscovery.ReadingListImportWindow.allCases) { window in
                            Text(window.title).tag(window)
                        }
                    }
                    .padding(.vertical, 8)
                    if let cutoff = SourceDiscovery.ReadingListImportWindow.storedCutoff {
                        Text("Pages saved before \(cutoff.formatted(date: .abbreviated, time: .shortened)) stay out.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 8)
                    }
                }
            }
        }
        .onAppear {
            enabledReadingListBrowsers = ReadingListBrowser.enabled
            readingListImportWindow = SourceDiscovery.ReadingListImportWindow.chosen ?? .everything
        }
    }

    private var readingListImportWindowBinding: Binding<SourceDiscovery.ReadingListImportWindow> {
        Binding(
            get: { readingListImportWindow },
            set: { window in
                let widened = SourceDiscovery.ReadingListImportWindow.widens(
                    from: SourceDiscovery.ReadingListImportWindow.chosen,
                    to: window
                )
                SourceDiscovery.ReadingListImportWindow.choose(window)
                readingListImportWindow = window
                if widened { vm.readingListBrowsersDidChange() }
            }
        )
    }

    private func readingListBrowserBinding(_ browser: ReadingListBrowser) -> Binding<Bool> {
        Binding(
            get: { enabledReadingListBrowsers.contains(browser) },
            set: { isOn in
                browser.setEnabled(isOn)
                if isOn {
                    enabledReadingListBrowsers.insert(browser)
                } else {
                    enabledReadingListBrowsers.remove(browser)
                }
                vm.readingListBrowsersDidChange()
            }
        )
    }

    // MARK: - Zoom transcripts

    /// Where Zoom's saved captions are read from. This exists because the
    /// failure it prevents is silent: Zoom's own default is `~/Documents/Zoom`,
    /// moving it is a Zoom setting ForeverLM cannot see, and a watcher aimed at
    /// the wrong folder reports nothing at all — it just never files a meeting
    /// again. So the folder is shown, it is changeable, and the count says
    /// whether anything is actually there.
    private var zoomTranscriptsSection: some View {
        SettingsSection(
            title: "Zoom Transcripts",
            description: "Meetings Zoom saves in this folder file themselves, from their captions or a transcribed recording."
        ) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(zoomFolder ?? StudioViewModel.zoomLocalTranscriptDefaultFolder(
                            homeDir: BookmarkAccessManager.realHomeDirectory
                        ))
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                        Spacer(minLength: 8)

                        if zoomFolder != nil {
                            Button("Use Default") { setZoomFolder(nil) }
                                .controlSize(.small)
                        }
                        Button("Choose…") { chooseZoomFolder() }
                            .controlSize(.small)
                    }

                    Text(zoomFolderStatus)
                        .font(.caption)
                        .foregroundStyle(zoomFolderIsEmpty ? .orange : .secondary)

                    // Every recording only Zoom can convert, the ignored ones
                    // too, so an Ignore made on the Meetings tab can be undone.
                    if !vm.zoomLocalUnconvertedRecordings.isEmpty {
                        Divider()
                        ForEach(vm.zoomLocalUnconvertedRecordings) { recording in
                            ZoomRecordingAwaitingConversionRow(recording: recording)
                        }
                    }
                }
            }
        }
        .task(id: zoomFolder) { await refreshZoomTranscriptCount() }
    }

    private var zoomFolderIsEmpty: Bool {
        guard let contents = zoomFolderContents else { return false }
        return contents.transcripts == 0 && contents.recordings == 0
    }

    private var zoomFolderStatus: String {
        guard let contents = zoomFolderContents else { return "Looking…" }
        if contents.transcripts == 0 && contents.recordings == 0 {
            return "Nothing here yet. In Zoom, check that its recording folder is this one."
        }
        func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        let parts = [count(contents.transcripts, "transcript"), count(contents.recordings, "recording")]
            .filter { !$0.hasPrefix("0 ") }
        var status = parts.joined(separator: " and ") + " in this folder."
        if contents.unconverted > 0 {
            status += " \(count(contents.unconverted, "recording")) Zoom has not converted; only Zoom can, so each is listed below and on the Meetings tab with Convert in Zoom and Ignore."
        }
        return status
    }

    private func refreshZoomTranscriptCount() async {
        let roots = StudioViewModel.zoomLocalTranscriptRoots(
            homeDir: BookmarkAccessManager.realHomeDirectory,
            customFolder: zoomFolder
        )
        zoomFolderContents = await Task.detached(priority: .utility) {
            let folders = StudioViewModel.zoomLocalRecordingFolders(roots: roots)
            return (
                transcripts: StudioViewModel.zoomLocalTranscriptFiles(roots: roots).count,
                recordings: folders.count,
                unconverted: folders.filter { $0.mediaPath == nil && $0.unconvertedPath != nil }.count
            )
        }.value
    }

    private func chooseZoomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder Zoom saves its transcripts to."
        panel.directoryURL = URL(fileURLWithPath: zoomFolder ?? StudioViewModel
            .zoomLocalTranscriptDefaultFolder(homeDir: BookmarkAccessManager.realHomeDirectory))
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setZoomFolder(url.path)
    }

    private func setZoomFolder(_ path: String?) {
        if let path {
            UserDefaults.standard.set(path, forKey: StudioViewModel.zoomLocalTranscriptFolderKey)
        } else {
            UserDefaults.standard.removeObject(forKey: StudioViewModel.zoomLocalTranscriptFolderKey)
        }
        zoomFolder = path
        zoomFolderContents = nil
        vm.zoomLocalTranscriptFolderDidChange()
    }

    private func sourceTabRow(_ tab: StudioSidebarTab) -> some View {
        HStack(spacing: 10) {
            SidebarTabIcon(tab: tab, showLabel: false, colorfulIcon: true)
                .frame(width: 22, height: 22)
            Text(tab.rawValue)
            Spacer(minLength: 8)
            Toggle("Include \(tab.rawValue) in search and AI", isOn: knowledgeBinding(for: tab))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("Include \(tab.rawValue) in search and AI")
        }
        .padding(.vertical, 6)
    }

    private func knowledgeBinding(for tab: StudioSidebarTab) -> Binding<Bool> {
        Binding(
            get: { !vm.excludedKnowledgeTabs.contains(tab) },
            set: { included in
                if included {
                    vm.excludedKnowledgeTabs.remove(tab)
                } else {
                    vm.excludedKnowledgeTabs.insert(tab)
                }
            }
        )
    }
}

/// Manages built-in and user-created services that feed sources into Studio.
/// MCP stays separate because it controls assistant access to the knowledge
/// base rather than source ingestion.
private struct PluginsSettingsDetailView: View {
    @Environment(StudioViewModel.self) private var vm
    // Placeholders only: these are *synced* Keychain keys, so each read is
    // securityd IPC that bypasses the vault cache — and `@State` initializers
    // re-run on every re-init of this struct. `refreshPluginStates()` fills
    // them in off-main.
    @State private var isYouTubeSignedIn = false
    @State private var isGoogleDriveSignedIn = false
    @State private var isGoogleDriveFolderAccessReady = false
    @State private var isAppleCalendarConnected = false
    @State private var userPlugins: [MCPOAuthProvider.UserPluginSummary] = []
    @State private var userPluginSourceCounts: [String: Int] = [:]
    /// Slack, Linear, GitHub and Notion are connected on the web and their
    /// tokens live on the gateway, so each state is a network answer rather
    /// than a Keychain read. They live in `GatewayPluginState` so the detail pane a row
    /// opens starts from the same answer instead of asking again from blank.
    private var slackConnection: MCPDataStore.SlackWorkspaceConnection? { GatewayPluginState.shared.slack }
    private var linearConnection: MCPDataStore.LinearConnection? { GatewayPluginState.shared.linear }
    private var githubConnection: MCPDataStore.GitHubConnection? { GatewayPluginState.shared.github }
    private var notionConnection: MCPDataStore.NotionConnection? { GatewayPluginState.shared.notion }

    private var slackStatus: PluginStatus? {
        slackConnection.map { $0.isConnected ? .connected : .notConnected }
    }

    private var linearStatus: PluginStatus? {
        linearConnection.map { $0.isConnected ? .connected : .notConnected }
    }

    private var githubStatus: PluginStatus? {
        githubConnection.map { $0.isConnected ? .connected : .notConnected }
    }

    private var notionStatus: PluginStatus? {
        notionConnection.map { $0.isConnected ? .connected : .notConnected }
    }

    // MARK: Row subtitles
    //
    // A plugin that is not connected describes itself; one that is says
    // what it may read — the account, the folders, the workspaces, the
    // organisations — so the list answers "which?" without opening the row.

    private var xSubtitle: String {
        guard vm.isXOAuthSignedIn, let scope = PluginScopeCopy.x(username: vm.xAccountUsername) else {
            return "Import saved posts and bookmarks into Studio."
        }
        return scope
    }

    private var youtubeSubtitle: String {
        guard isYouTubeSignedIn, let scope = PluginScopeCopy.youtube(
            source: vm.youtubeImportSource?.displayName,
            followedChannels: vm.followedYouTubeChannelGroupIDs.count
        ) else {
            return "Import Liked videos or your ForeverLM playlist."
        }
        return scope
    }

    private var googleDriveSubtitle: String {
        guard isGoogleDriveSignedIn, let scope = PluginScopeCopy.googleDrive(
            folders: PluginScopeCopy.googleDriveFolderNames(in: vm.meetingMetadata)
        ) else {
            return "Import meeting recordings and transcripts from a folder."
        }
        return scope
    }

    private var appleCalendarSubtitle: String {
        isAppleCalendarConnected
            ? "Your day, shown in the bottom-left chip and planned into from a chat."
            : "Make the Mac's Calendar — iCloud, Google, Exchange — your day in ForeverLM."
    }

    private var slackSubtitle: String {
        if case .connected(let workspaces)? = slackConnection, let scope = PluginScopeCopy.slack(workspaces) {
            return scope
        }
        return "Read messages and threads from channels you choose."
    }

    private var linearSubtitle: String {
        if case .connected(let workspace, let user)? = linearConnection,
           let scope = PluginScopeCopy.linear(workspace: workspace, user: user) {
            return scope
        }
        return "Read issues, teams and projects as you. Read-only."
    }

    private var githubSubtitle: String {
        if case .connected(let account)? = githubConnection,
           let scope = PluginScopeCopy.github(login: account.login, installations: account.installationNames) {
            return scope
        }
        return "Read repositories, issues and pull requests as you. Read-only."
    }

    private var notionSubtitle: String {
        if case .connected(let workspace, let user)? = notionConnection,
           let scope = PluginScopeCopy.notion(workspace: workspace, user: user) {
            return scope
        }
        return "Read the pages and databases you share as you. Read-only."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsSection(title: "Built-In Plugins") {
                    VStack(spacing: 10) {
                        NavigationLink(value: SettingsPane.xPlugin) {
                            PluginPickerRow(
                                title: "X",
                                subtitle: xSubtitle,
                                status: vm.isXOAuthSignedIn
                                    ? (vm.xPluginNeedsReauth ? .needsAttention : .connected)
                                    : .notConnected,
                                icon: {
                                    XLogoShape()
                                        .fill(.foreground, style: FillStyle(eoFill: true))
                                        .frame(width: 15, height: 15)
                                }
                            )
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(cornerRadius: 18, inset: 0)

                        NavigationLink(value: SettingsPane.youtubePlugin) {
                            PluginPickerRow(
                                title: "YouTube",
                                subtitle: youtubeSubtitle,
                                status: isYouTubeSignedIn ? .connected : .notConnected,
                                icon: {
                                    Image("YouTubeIcon")
                                        .resizable()
                                        .renderingMode(.original)
                                        .scaledToFit()
                                        .frame(width: 25, height: 18)
                                }
                            )
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(cornerRadius: 18, inset: 0)

                        NavigationLink(value: SettingsPane.googleDrivePlugin) {
                            PluginPickerRow(
                                title: "Google Drive",
                                subtitle: googleDriveSubtitle,
                                status: isGoogleDriveSignedIn
                                    ? (isGoogleDriveFolderAccessReady ? .connected : .needsAttention)
                                    : .notConnected,
                                icon: {
                                    Image("GoogleDriveIcon")
                                        .resizable()
                                        .renderingMode(.original)
                                        .scaledToFit()
                                        .frame(width: 22, height: 18)
                                }
                            )
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(cornerRadius: 18, inset: 0)

                        NavigationLink(value: SettingsPane.appleCalendarPlugin) {
                            PluginPickerRow(
                                title: "Calendar",
                                subtitle: appleCalendarSubtitle,
                                status: isAppleCalendarConnected ? .connected : .notConnected,
                                icon: {
                                    Image("AppleCalendarIcon")
                                        .resizable()
                                        .renderingMode(.original)
                                        .scaledToFit()
                                        .frame(width: 20, height: 20)
                                }
                            )
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(cornerRadius: 18, inset: 0)

                        NavigationLink(value: SettingsPane.slackPlugin) {
                            PluginPickerRow(
                                title: "Slack",
                                subtitle: slackSubtitle,
                                status: slackStatus,
                                icon: {
                                    Image("SlackIcon")
                                        .resizable()
                                        .renderingMode(.original)
                                        .scaledToFit()
                                        .frame(width: 22, height: 22)
                                }
                            )
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(cornerRadius: 18, inset: 0)

                        NavigationLink(value: SettingsPane.linearPlugin) {
                            PluginPickerRow(
                                title: "Linear",
                                subtitle: linearSubtitle,
                                status: linearStatus,
                                icon: {
                                    Image("LinearIcon")
                                        .resizable()
                                        .renderingMode(.original)
                                        .scaledToFit()
                                        .frame(width: 20, height: 20)
                                }
                            )
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(cornerRadius: 18, inset: 0)

                        NavigationLink(value: SettingsPane.githubPlugin) {
                            PluginPickerRow(
                                title: "GitHub",
                                subtitle: githubSubtitle,
                                status: githubStatus,
                                icon: {
                                    // GitHub's mark is black on light and white on
                                    // dark, so it is drawn as a template in the
                                    // foreground colour, like the X mark above.
                                    Image("GitHubIcon")
                                        .resizable()
                                        .renderingMode(.template)
                                        .scaledToFit()
                                        .foregroundStyle(.primary)
                                        .frame(width: 22, height: 22)
                                }
                            )
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(cornerRadius: 18, inset: 0)

                        NavigationLink(value: SettingsPane.notionPlugin) {
                            PluginPickerRow(
                                title: "Notion",
                                subtitle: notionSubtitle,
                                status: notionStatus,
                                icon: {
                                    // Notion's mark is black on light and white on
                                    // dark, so it is drawn as a template in the
                                    // foreground colour, like the GitHub mark above.
                                    Image("NotionIcon")
                                        .resizable()
                                        .renderingMode(.template)
                                        .scaledToFit()
                                        .foregroundStyle(.primary)
                                        .frame(width: 20, height: 20)
                                }
                            )
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(cornerRadius: 18, inset: 0)
                    }
                }

                SettingsSection(title: "Your Plugins") {
                    VStack(spacing: 10) {
                        ForEach(meetingPluginProviders) { provider in
                            let plugin = registeredPlugin(for: provider)
                            NavigationLink(value: SettingsPane.userPlugins) {
                                PluginPickerRow(
                                    title: provider.displayName,
                                    subtitle: plugin.map { userPluginSubtitle(for: $0) }
                                        ?? providerWithoutPluginSubtitle(provider),
                                    status: plugin.map(pluginStatus) ?? .notConnected,
                                    icon: {
                                        MeetingProviderMark(provider: provider, size: 20)
                                    }
                                )
                            }
                            .buttonStyle(.plain)
                            .hoverHighlight(cornerRadius: 18, inset: 0)
                        }

                        ForEach(customPluginTabs, id: \.self) { tab in
                            let plugin = registeredPlugin(for: tab)
                            NavigationLink(value: SettingsPane.userPlugins) {
                                PluginPickerRow(
                                    title: tab.rawValue,
                                    subtitle: plugin.map { userPluginSubtitle(for: $0) }
                                        ?? customPluginSubtitle(for: tab),
                                    status: plugin.map(pluginStatus) ?? .notConnected,
                                    icon: {
                                        customPluginLogo(tab)
                                    }
                                )
                            }
                            .buttonStyle(.plain)
                            .hoverHighlight(cornerRadius: 18, inset: 0)
                        }

                        ForEach(unrepresentedUserPlugins) { plugin in
                            NavigationLink(value: SettingsPane.userPlugins) {
                                PluginPickerRow(
                                    title: plugin.name,
                                    subtitle: userPluginSubtitle(for: plugin),
                                    status: pluginStatus(plugin),
                                    icon: {
                                        userPluginLogo(plugin)
                                    }
                                )
                            }
                            .buttonStyle(.plain)
                            .hoverHighlight(cornerRadius: 18, inset: 0)
                        }

                        NavigationLink(value: SettingsPane.userPlugins) {
                            PluginPickerRow(
                                title: "Build Your Own",
                                subtitle: "Add sources from any service your own plugin can reach.",
                                icon: {
                                    Image(systemName: "puzzlepiece.extension.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.indigo)
                                }
                            )
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(cornerRadius: 18, inset: 0)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Plugins")
        .onAppear {
            refreshPluginStates()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pluginConnectionChanged)) { _ in
            refreshPluginStates()
        }
    }

    private func refreshPluginStates() {
        vm.checkXSignInStatus()
        Task {
            // Synced Keychain keys read fresh from securityd every time; keep
            // that IPC off the main actor (same shape as the sidebar's
            // `refreshGoogleDriveConnectionState`).
            let status = await Task.detached(priority: .userInitiated) {
                (
                    youtube: YouTubeService.shared.isSignedIn,
                    drive: GoogleDriveService.shared.isSignedIn,
                    driveFolder: GoogleDriveService.shared.hasFolderReadAccess,
                    appleCalendar: AppleCalendarService.shared.isConnected
                )
            }.value
            isYouTubeSignedIn = status.youtube
            isGoogleDriveSignedIn = status.drive
            isGoogleDriveFolderAccessReady = status.driveFolder
            isAppleCalendarConnected = status.appleCalendar
            let oauthProvider = await MCPOAuthProvider.sharedProvider()
            userPlugins = await oauthProvider.userPluginSummaries()
            userPluginSourceCounts = (try? await vm.storage.activePluginSourceCounts()) ?? [:]
        }
        Task {
            // A round trip to the gateway, so it runs apart from the Keychain
            // reads above and keeps whatever it last knew when it cannot answer.
            if let connection = await MCPDataStore.slackWorkspaceConnection() {
                GatewayPluginState.shared.slack = connection
            }
        }
        Task {
            if let connection = await MCPDataStore.linearConnection() {
                GatewayPluginState.shared.linear = connection
            }
        }
        Task {
            if let connection = await MCPDataStore.githubConnection() {
                GatewayPluginState.shared.github = connection
            }
        }
        Task {
            if let connection = await MCPDataStore.notionConnection() {
                GatewayPluginState.shared.notion = connection
            }
        }
    }

    /// The source-tab classification is the catalog for recognizable custom
    /// integrations. Built-in Slack has its own setup row above and no tab of
    /// its own; any plugin-backed tab appears here automatically and in a
    /// familiar order.
    private var customPluginTabs: [StudioSidebarTab] {
        vm.tabOrder.filter(\.isPluginBacked)
    }

    /// A registered ingest client with a known brand is represented by its
    /// branded card above. Keep the remaining user-built clients in the list
    /// without showing the same plugin twice; Slack, Linear, GitHub and
    /// Notion are the built-in rows.
    private var unrepresentedUserPlugins: [MCPOAuthProvider.UserPluginSummary] {
        userPlugins.filter { plugin in
            plugin.name.caseInsensitiveCompare("Slack") != .orderedSame
            && plugin.name.caseInsensitiveCompare("Linear") != .orderedSame
            && plugin.name.caseInsensitiveCompare("GitHub") != .orderedSame
            && plugin.name.caseInsensitiveCompare("Notion") != .orderedSame
            && !customPluginTabs.contains { tab in
                plugin.name.caseInsensitiveCompare(tab.rawValue) == .orderedSame
            } && !meetingPluginProviders.contains { provider in
                provider.matches(connectorLabel: plugin.name)
            }
        }
    }

    /// Meeting providers that arrive through a registered ingest plugin, so
    /// they earn a branded card of their own.
    ///
    /// Read AI used to get one by virtue of having its own sidebar tab. Folding
    /// the meeting tabs together would have quietly cost it that card, so the
    /// catalog reads providers directly instead of inferring them from the tab
    /// list — which is what the tab list was never really for.
    private var meetingPluginProviders: [MeetingProvider] {
        MeetingProvider.allCases.filter(\.isPlugin)
    }

    /// The plugin claiming a meeting provider — by the brand as the leading
    /// word(s) of its name, the same test the Meetings tab and source filing
    /// use, so one plugin cannot be healthy here and missing there.
    private func registeredPlugin(for provider: MeetingProvider) -> MCPOAuthProvider.UserPluginSummary? {
        userPlugins.first { provider.matches(connectorLabel: $0.name) }
    }

    /// A provider card with no plugin behind it. Meetings from that provider
    /// already in the library mean new ones have stopped arriving, which is
    /// worth saying; otherwise the card is only an offer. Never "reconnect":
    /// there is nothing here for ForeverLM to reconnect.
    private func providerWithoutPluginSubtitle(_ provider: MeetingProvider) -> String {
        vm.meetingProvidersInUse.contains(provider)
            ? "Meetings have stopped arriving. Set up a plugin to get the latest."
            : provider.pluginSubtitle
    }

    private func registeredPlugin(for tab: StudioSidebarTab) -> MCPOAuthProvider.UserPluginSummary? {
        userPlugins.first {
            $0.name.caseInsensitiveCompare(tab.rawValue) == .orderedSame
        }
    }

    private func customPluginSubtitle(for tab: StudioSidebarTab) -> String {
        "Add sources through your plugin."
    }

    @ViewBuilder
    private func customPluginLogo(_ tab: StudioSidebarTab) -> some View {
        if let iconAsset = tab.iconAsset {
            Image(iconAsset)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: tab.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tab.color)
        }
    }

    private func userPluginSubtitle(for plugin: MCPOAuthProvider.UserPluginSummary) -> String {
        if let trouble = plugin.attentionSummary {
            return sentenceCased(trouble, terminated: true)
        }
        if plugin.reportedState == .syncing { return "Syncing…" }
        if let lastSync = plugin.lastSuccessfulSyncAt {
            return "Last synced \(lastSync.formatted(.relative(presentation: .named)))."
        }
        let count = userPluginSourceCounts[plugin.name] ?? 0
        return count == 1 ? "1 source added." : "\(count) sources added."
    }

    private func pluginStatus(_ plugin: MCPOAuthProvider.UserPluginSummary) -> PluginStatus {
        plugin.needsAttention ? .needsAttention : .connected
    }

    /// Registration logos render in Settings lists only — consent surfaces keep
    /// the generic icon so a malicious client can't dress its approval up as a
    /// trusted product (mirrors `UserPluginSettingsRow`).
    @ViewBuilder
    private func userPluginLogo(_ plugin: MCPOAuthProvider.UserPluginSummary) -> some View {
        if let logo = plugin.logoURI, let url = URL(string: logo) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                userPluginFallbackIcon
            }
            .frame(width: 24, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            userPluginFallbackIcon
        }
    }

    private var userPluginFallbackIcon: some View {
        Image(systemName: "puzzlepiece.extension.fill")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.indigo)
    }
}

/// The gateway's answers about the plugins it holds the tokens for: Slack,
/// Linear, GitHub and Notion. One copy for the whole Settings window, so the detail
/// pane a row opens starts from the answer the row already shows instead of
/// blank, and a refresh from either place updates both. nil until the gateway
/// has answered at all — no chip, rather than a wrong one for a moment.
@MainActor
@Observable
final class GatewayPluginState {
    static let shared = GatewayPluginState()

    /// The whole answer is kept, not just a flag, because the row names what
    /// the connection reads: the workspaces and their channel counts.
    var slack: MCPDataStore.SlackWorkspaceConnection?
    var linear: MCPDataStore.LinearConnection?
    var github: MCPDataStore.GitHubConnection?
    var notion: MCPDataStore.NotionConnection?

    private init() {}
}

/// The Slack plugin, managed here rather than on the web page: which
/// workspaces are connected, which channels ForeverLM may read in each, and
/// connecting or disconnecting a workspace. Slack's own consent screen is the
/// one step that needs a browser, and it opens in a sheet over this window.
///
/// Every operation is one of the gateway routes the web page calls, with the
/// managed session as the credential. The page stays available for a browser
/// the learner is already signed in to, and for the re-authorization it
/// offers a workspace whose grant predates a read scope.
@MainActor
private struct SlackPluginSettingsView: View {
    private let setupURL = URL(string: "https://app.foreverlm.com/slack-connect")!
    /// Channel pickers by team id, loaded once the workspaces are known.
    @State private var pickers: [String: MCPDataStore.SlackWorkspaceChannels] = [:]
    @State private var loadingPickers: Set<String> = []
    @State private var pickerErrors: [String: String] = [:]
    /// Channels whose toggle is being written, so a second flip waits.
    @State private var busyChannels: Set<String> = []
    @State private var connecting = false
    @State private var disconnectingTeamID: String?
    @State private var pendingDisconnect: MCPDataStore.SlackWorkspace?
    @State private var message: String?
    @State private var consent = SlackConsentSheet()

    private var connection: MCPDataStore.SlackWorkspaceConnection? { GatewayPluginState.shared.slack }

    /// The connected workspaces the routes can address.
    private var workspaces: [MCPDataStore.SlackWorkspace] {
        guard case .connected(let workspaces)? = connection else { return [] }
        return workspaces.filter { $0.teamID != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 12) {
                        Button(connectTitle) {
                            Task { await connect() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(connecting || connection == nil || connection == .signedOut)
                        if connecting {
                            ProgressView().controlSize(.small)
                        }
                        Link("Open the Slack page", destination: setupURL)
                            .font(.subheadline)
                    }
                    if let message {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            ForEach(workspaces, id: \.teamID) { workspace in
                workspaceCard(workspace)
            }
        }
        .task {
            await refreshConnection()
            await loadPickers()
        }
        // A workspace can be connected from the Slack page in the browser or
        // from a chat; coming back to the app, or the connection changing
        // elsewhere, must show it without reopening Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await resync() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pluginConnectionChanged)) { _ in
            Task { await resync() }
        }
        .confirmationDialog(
            "Disconnect \(pendingDisconnect?.name ?? "this workspace")?",
            isPresented: Binding(get: { pendingDisconnect != nil }, set: { if !$0 { pendingDisconnect = nil } }),
            presenting: pendingDisconnect
        ) { workspace in
            Button("Disconnect", role: .destructive) {
                Task { await disconnect(workspace) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { workspace in
            Text("ForeverLM stops reading \(workspace.name) and its Slack tokens are revoked. You can connect it again later.")
        }
    }

    private var connectTitle: String {
        workspaces.isEmpty ? "Connect Slack…" : "Connect Another Workspace…"
    }

    /// The same answer the plugins list shows as a chip, in a sentence that
    /// says what the cards below are for.
    private var statusMessage: String? {
        switch connection {
        case .connected(let workspaces):
            let named = ListFormatter.localizedString(byJoining: workspaces.map(\.name))
            switch workspaces.count {
            case 0:
                return "Connected. Choose which channels ForeverLM may read below."
            case 1:
                return "Connected to \(named). Choose which channels ForeverLM may read below."
            default:
                return "Connected to \(workspaces.count) workspaces: \(named). Choose which channels ForeverLM may read in each below."
            }
        case .notConnected:
            return "No Slack workspace is connected to your ForeverLM account yet. You can connect more than one."
        case .signedOut:
            return "Sign in with Apple in ForeverLM to connect Slack. ForeverLM reads Slack as you, through your own account."
        case nil:
            return nil
        }
    }

    @ViewBuilder
    private func workspaceCard(_ workspace: MCPDataStore.SlackWorkspace) -> some View {
        let teamID = workspace.teamID ?? ""
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pickers[teamID]?.teamName ?? workspace.name)
                            .font(.headline)
                        if let picker = pickers[teamID] {
                            Text(picker.readsWithoutJoining
                                 ? "ForeverLM reads these as you. Nothing is added to any channel and nobody there is notified."
                                 : "Invite @ForeverLM to a channel before enabling it. The invitation is visible to everyone in the channel.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 12)
                    Button("Disconnect…") {
                        pendingDisconnect = workspace
                    }
                    .disabled(disconnectingTeamID == teamID)
                }
                Divider()
                if loadingPickers.contains(teamID) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading channels…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else if let error = pickerErrors[teamID] {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try Again") {
                            Task { await loadPicker(teamID: teamID) }
                        }
                    }
                } else if let picker = pickers[teamID] {
                    if picker.channels.isEmpty {
                        Text("Slack listed no channels this account can see.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        channelList(picker)
                    }
                }
            }
        }
    }

    private func channelList(_ picker: MCPDataStore.SlackWorkspaceChannels) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(picker.channels) { channel in
                let unreachable = !picker.readsWithoutJoining && !channel.isMember
                Toggle(isOn: Binding(
                    get: { channel.enabled },
                    set: { enabled in Task { await setChannel(teamID: picker.teamID, channelID: channel.id, enabled: enabled) } }
                )) {
                    HStack(spacing: 6) {
                        Image(systemName: channel.isPrivate ? "lock" : "number")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text(channel.name)
                            .foregroundStyle(unreachable ? .secondary : .primary)
                        if unreachable {
                            Text("invite @ForeverLM first")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(unreachable || busyChannels.contains(channel.id))
            }
        }
    }

    // MARK: Actions

    private func refreshConnection() async {
        if let connection = await MCPDataStore.slackWorkspaceConnection() {
            GatewayPluginState.shared.slack = connection
        }
    }

    /// Asks the gateway which workspaces are connected, drops the cards of any
    /// that are gone and loads the channels of any that are new.
    private func resync() async {
        await refreshConnection()
        let connected = Set(workspaces.compactMap(\.teamID))
        for teamID in pickers.keys where !connected.contains(teamID) {
            pickers[teamID] = nil
            pickerErrors[teamID] = nil
        }
        await loadPickers()
    }

    private func loadPickers() async {
        await withTaskGroup(of: Void.self) { group in
            for workspace in workspaces {
                guard let teamID = workspace.teamID, pickers[teamID] == nil,
                      !loadingPickers.contains(teamID) else { continue }
                group.addTask { await loadPicker(teamID: teamID) }
            }
        }
    }

    private func loadPicker(teamID: String) async {
        loadingPickers.insert(teamID)
        pickerErrors[teamID] = nil
        defer { loadingPickers.remove(teamID) }
        do {
            pickers[teamID] = try await MCPDataStore.slackWorkspaceChannels(teamID: teamID)
        } catch {
            pickerErrors[teamID] = error.localizedDescription
        }
    }

    private func setChannel(teamID: String, channelID: String, enabled: Bool) async {
        guard var picker = pickers[teamID],
              let index = picker.channels.firstIndex(where: { $0.id == channelID }),
              !busyChannels.contains(channelID) else { return }
        let previous = picker.channels[index].enabled
        picker.channels[index].enabled = enabled
        pickers[teamID] = picker
        busyChannels.insert(channelID)
        defer { busyChannels.remove(channelID) }
        do {
            try await MCPDataStore.setSlackChannel(teamID: teamID, channelID: channelID, enabled: enabled)
            message = nil
            // The list's row counts enabled channels; tell it the count moved.
            await refreshConnection()
            NotificationCenter.default.post(name: .pluginConnectionChanged, object: nil)
        } catch {
            if var current = pickers[teamID], let index = current.channels.firstIndex(where: { $0.id == channelID }) {
                current.channels[index].enabled = previous
                pickers[teamID] = current
            }
            message = error.localizedDescription
        }
    }

    private func connect() async {
        connecting = true
        message = nil
        defer { connecting = false }
        do {
            guard #available(macOS 14.4, *) else {
                // Older systems cannot stop a sheet at an https address, so the
                // web page finishes the install there.
                NSWorkspace.shared.open(setupURL)
                return
            }
            let authorization = try await MCPDataStore.slackAuthorizationURL()
            let callback = try await consent.authorize(url: authorization, redirect: MCPDataStore.slackInstallRedirectURL)
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? {
                items.first(where: { $0.name == name })?.value.flatMap { $0.isEmpty ? nil : $0 }
            }
            if let error = value("error") {
                if error == "access_denied" { return } // The learner backed out on Slack's screen.
                throw MCPError.invalidInput("Slack did not complete the connection (\(error)).")
            }
            guard let code = value("code"), let state = value("state") else {
                throw MCPError.invalidInput("Slack returned an incomplete authorization response.")
            }
            _ = try await MCPDataStore.completeSlackInstall(code: code, state: state)
            await refreshConnection()
            NotificationCenter.default.post(name: .pluginConnectionChanged, object: nil)
            await loadPickers()
        } catch is CancellationError {
            // The sheet was dismissed.
        } catch {
            message = error.localizedDescription
        }
    }

    private func disconnect(_ workspace: MCPDataStore.SlackWorkspace) async {
        guard let teamID = workspace.teamID else { return }
        disconnectingTeamID = teamID
        message = nil
        defer { disconnectingTeamID = nil }
        do {
            _ = try await MCPDataStore.disconnectSlackWorkspace(teamID: teamID)
            pickers[teamID] = nil
            pickerErrors[teamID] = nil
            await refreshConnection()
            NotificationCenter.default.post(name: .pluginConnectionChanged, object: nil)
        } catch {
            message = error.localizedDescription
        }
    }
}

/// Slack's consent screen in an `ASWebAuthenticationSession` over the Settings
/// window. The session is told to stop at the registered redirect address and
/// hand its query back, so the code never loads the web page; the app finishes
/// the install with the gateway itself. Same shape as the Developer ID Sign in
/// with Apple flow in `ManagedAIAccountModel`.
@MainActor
private final class SlackConsentSheet: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    @available(macOS 14.4, *)
    func authorize(url: URL, redirect: URL) async throws -> URL {
        session?.cancel()
        guard let host = redirect.host else {
            throw MCPError.invalidInput("The Slack redirect address is invalid.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callback: .https(host: host, path: redirect.path)
            ) { [weak self] callbackURL, error in
                Task { @MainActor [weak self] in self?.session = nil }
                if let webError = error as? ASWebAuthenticationSessionError, webError.code == .canceledLogin {
                    continuation.resume(throwing: CancellationError())
                } else if let error {
                    continuation.resume(throwing: error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: MCPError.invalidInput("Slack returned no response."))
                }
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: MCPError.invalidInput("Could not open Slack's sign-in sheet."))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}

@MainActor
private struct LinearPluginSettingsView: View {
    private let setupURL = URL(string: "https://app.foreverlm.com/linear-connect")!
    private var connection: MCPDataStore.LinearConnection? { GatewayPluginState.shared.linear }

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                if let statusMessage {
                    Text(statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Link(connection?.isConnected == true ? "Manage Linear…" : "Connect Linear…", destination: setupURL)
                    .buttonStyle(.borderedProminent)
            }
        }
        .task {
            if let connection = await MCPDataStore.linearConnection() {
                GatewayPluginState.shared.linear = connection
            }
        }
    }

    /// The same answer the plugins list shows as a chip, in a sentence that
    /// says what the button will do about it. Every state says read-only once.
    private var statusMessage: String? {
        switch connection {
        case .connected(let workspace, let user):
            let opening: String
            switch (workspace, user) {
            case (let workspace?, let user?): opening = "Connected to \(workspace) as \(user)."
            case (let workspace?, nil): opening = "Connected to \(workspace)."
            case (nil, let user?): opening = "Connected as \(user)."
            case (nil, nil): opening = "Connected."
            }
            return "\(opening) ForeverLM reads issues, teams and projects as you and changes nothing; disconnect on the Linear page."
        case .notConnected:
            return "No Linear workspace is connected to your ForeverLM account yet. The connection is read-only."
        case .signedOut:
            return "Sign in with Apple in ForeverLM to connect Linear. ForeverLM reads Linear as you, through your own account, and never writes to it."
        case nil:
            return nil
        }
    }
}

/// The GitHub plugin: which account the reads are made as, which
/// organisations and personal accounts the ForeverLM GitHub App is installed
/// on, and the repositories each of those puts within reach — one card per
/// installation, the way Slack draws one card per workspace. Installing the
/// App on another organisation is GitHub's own page; connecting an account
/// is the web page; disconnecting is a gateway route the pane calls itself.
@MainActor
private struct GitHubPluginSettingsView: View {
    private let setupURL = URL(string: "https://app.foreverlm.com/github-connect")!
    @State private var listing: MCPDataStore.GitHubRepositoryListing?
    @State private var loadingRepositories = false
    @State private var repositoriesError: String?
    @State private var disconnecting = false
    @State private var confirmingDisconnect = false
    @State private var message: String?

    private var connection: MCPDataStore.GitHubConnection? { GatewayPluginState.shared.github }
    private var account: MCPDataStore.GitHubAccount? { connection?.account }
    private var installations: [MCPDataStore.GitHubInstallation] { account?.installations ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let account, account.reconnectRequired {
                        Text("GitHub no longer honours this connection. Reconnect on the GitHub page.")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 12) {
                        if let account {
                            if let installURL = account.installURL {
                                Link("Add an Organisation…", destination: installURL)
                                    .buttonStyle(.borderedProminent)
                            } else {
                                Link("Manage GitHub…", destination: setupURL)
                                    .buttonStyle(.borderedProminent)
                            }
                            Button("Disconnect…") {
                                confirmingDisconnect = true
                            }
                            .disabled(disconnecting)
                            if disconnecting {
                                ProgressView().controlSize(.small)
                            }
                        } else {
                            Link("Connect GitHub…", destination: setupURL)
                                .buttonStyle(.borderedProminent)
                                .disabled(connection == nil || connection == .signedOut)
                        }
                        Link("Open the GitHub page", destination: setupURL)
                            .font(.subheadline)
                    }
                    if let message {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let account {
                if installations.isEmpty {
                    SettingsCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Installed nowhere yet")
                                .font(.headline)
                            Text(account.installationsError.map { "GitHub did not list where the ForeverLM App is installed: \($0)" }
                                 ?? "The ForeverLM GitHub App is not installed on any organisation or account yet, so there are no repositories to read. Add an organisation or your own account above.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    ForEach(installations) { installation in
                        installationCard(installation)
                    }
                    let strays = listing?.repositories(notOwnedByAny: account.installationNames) ?? []
                    if !strays.isEmpty {
                        SettingsCard {
                            VStack(alignment: .leading, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Other repositories")
                                        .font(.headline)
                                    Text("Reachable through the grant without an installation of their own.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Divider()
                                repositoryList(strays)
                            }
                        }
                    }
                }
            }
        }
        .task {
            await refreshConnection()
            await loadRepositories()
        }
        .confirmationDialog(
            "Disconnect GitHub?",
            isPresented: $confirmingDisconnect
        ) {
            Button("Disconnect", role: .destructive) {
                Task { await disconnect() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("ForeverLM stops reading GitHub as \(account?.login.map { "@\($0)" } ?? "you") and its GitHub token is revoked. The ForeverLM App stays installed on your organisations; you can connect again later.")
        }
    }

    /// The same answer the plugins list shows as a chip, in a sentence that
    /// says what the cards below are for. Every state says read-only once.
    private var statusMessage: String? {
        switch connection {
        case .connected(let account):
            let who: String
            switch (account.name, account.login) {
            case (let name?, let login?): who = "Connected as \(name) (@\(login))."
            case (nil, let login?): who = "Connected as @\(login)."
            case (let name?, nil): who = "Connected as \(name)."
            case (nil, nil): who = "Connected."
            }
            let scope: String
            switch account.installations.count {
            case 0:
                scope = ""
            case 1:
                scope = " The ForeverLM App is installed on \(account.installations[0].account); its repositories are listed below."
            default:
                let named = ListFormatter.localizedString(byJoining: account.installationNames)
                scope = " The ForeverLM App is installed on \(account.installations.count) accounts: \(named). Each one's repositories are listed below."
            }
            return "\(who)\(scope) ForeverLM reads repositories, issues and pull requests as you and changes nothing."
        case .notConnected:
            return "No GitHub account is connected to your ForeverLM account yet. The connection is read-only."
        case .signedOut:
            return "Sign in with Apple in ForeverLM to connect GitHub. ForeverLM reads GitHub as you, through your own account, and never writes to it."
        case nil:
            return nil
        }
    }

    @ViewBuilder
    private func installationCard(_ installation: MCPDataStore.GitHubInstallation) -> some View {
        let repositories = listing?.repositories(ownedBy: installation.account) ?? []
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: installation.isOrganization ? "building.2" : "person")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(installation.account)
                                .font(.headline)
                            if let kind = installation.kindLabel {
                                Text(kind)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                            }
                        }
                        Text(installationSummary(installation, repositories: repositories))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    if let url = installation.url {
                        Link(destination: url) {
                            Label("Open on GitHub", systemImage: "arrow.up.right")
                                .labelStyle(.titleAndIcon)
                        }
                        .font(.subheadline)
                    }
                }
                Divider()
                if loadingRepositories && listing == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading repositories…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else if let repositoriesError, listing == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(repositoriesError)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try Again") {
                            Task { await loadRepositories() }
                        }
                    }
                } else if repositories.isEmpty {
                    Text(installation.isOrganization
                         ? "The App is installed on \(installation.account) but GitHub listed no repositories for it. An organisation owner chooses which repositories the App may read on GitHub."
                         : "GitHub listed no repositories for \(installation.account). Choose which repositories the App may read on GitHub.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    repositoryList(repositories)
                }
            }
        }
    }

    /// "12 repositories, 9 private." The count is the App's view of the
    /// account, which is what ForeverLM can read — not everything the account owns.
    private func installationSummary(_ installation: MCPDataStore.GitHubInstallation, repositories: [MCPDataStore.GitHubRepositorySummary]) -> String {
        guard listing != nil else { return "ForeverLM reads the repositories the App may see here." }
        let count = repositories.count
        let privateCount = repositories.filter { $0.isPrivate == true }.count
        var text: String
        switch count {
        case 0: text = "No repositories within reach."
        case 1: text = "1 repository within reach"
        default: text = "\(count) repositories within reach"
        }
        if count > 0 {
            if privateCount == count {
                text += count == 1 ? ", private." : ", all private."
            } else if privateCount > 0 {
                text += ", \(privateCount) private."
            } else {
                text += count == 1 ? ", public." : ", all public."
            }
        }
        if listing?.truncated == true {
            text += " GitHub listed more than ForeverLM fetched; the newest are shown."
        }
        return text
    }

    private func repositoryList(_ repositories: [MCPDataStore.GitHubRepositorySummary]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(repositories) { repository in
                repositoryRow(repository)
            }
        }
    }

    private func repositoryRow(_ repository: MCPDataStore.GitHubRepositorySummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: repository.isPrivate == true ? "lock" : "globe")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let url = repository.url {
                        Link(repository.name, destination: url)
                            .foregroundStyle(.primary)
                    } else {
                        Text(repository.name)
                    }
                    if repository.isArchived {
                        Text("archived")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if repository.isFork {
                        Text("fork")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let description = repository.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(repositoryDetail(repository))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// "Swift · pushed 3 days ago".
    private func repositoryDetail(_ repository: MCPDataStore.GitHubRepositorySummary) -> String {
        var parts: [String] = []
        if let language = repository.language { parts.append(language) }
        if let pushedAt = repository.pushedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            parts.append("pushed \(formatter.localizedString(for: pushedAt, relativeTo: Date()))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func refreshConnection() async {
        if let connection = await MCPDataStore.githubConnection() {
            GatewayPluginState.shared.github = connection
        }
    }

    private func loadRepositories() async {
        guard connection?.isConnected == true, !installations.isEmpty else {
            listing = nil
            return
        }
        loadingRepositories = true
        repositoriesError = nil
        defer { loadingRepositories = false }
        do {
            listing = try await MCPDataStore.githubRepositories()
        } catch {
            repositoriesError = error.localizedDescription
        }
    }

    private func disconnect() async {
        disconnecting = true
        message = nil
        defer { disconnecting = false }
        do {
            _ = try await MCPDataStore.disconnectGitHub()
            listing = nil
            repositoriesError = nil
            await refreshConnection()
            NotificationCenter.default.post(name: .pluginConnectionChanged, object: nil)
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct NotionPluginSettingsView: View {
    private let setupURL = URL(string: "https://app.foreverlm.com/notion-connect")!
    private var connection: MCPDataStore.NotionConnection? { GatewayPluginState.shared.notion }

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                if let statusMessage {
                    Text(statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Link(connection?.isConnected == true ? "Manage Notion…" : "Connect Notion…", destination: setupURL)
                    .buttonStyle(.borderedProminent)
            }
        }
        .task {
            if let connection = await MCPDataStore.notionConnection() {
                GatewayPluginState.shared.notion = connection
            }
        }
    }

    /// The same answer the plugins list shows as a chip, in a sentence that
    /// says what the button will do about it. Every state says read-only once.
    private var statusMessage: String? {
        switch connection {
        case .connected(let workspace, let user):
            let opening: String
            switch (workspace, user) {
            case (let workspace?, let user?): opening = "Connected to \(workspace) as \(user)."
            case (let workspace?, nil): opening = "Connected to \(workspace)."
            case (nil, let user?): opening = "Connected as \(user)."
            case (nil, nil): opening = "Connected."
            }
            return "\(opening) ForeverLM reads the pages and databases you shared with it as you and changes nothing; share another page from its ••• menu in Notion, or disconnect on the Notion page."
        case .notConnected:
            return "No Notion workspace is connected to your ForeverLM account yet. The connection is read-only."
        case .signedOut:
            return "Sign in with Apple in ForeverLM to connect Notion. ForeverLM reads Notion as you, through your own account, and never writes to it."
        case nil:
            return nil
        }
    }
}

/// Settings › AI Usage above the activity: the learner's own key, Free mode,
/// and spending with its limits, one card each. Paying for ForeverLM is
/// Settings › Billing; the key card only points there when the account may
/// not run the key.
private struct AIUsageAccountSections: View {
    let onOpenBilling: () -> Void

    @Environment(ManagedAIAccountModel.self) private var account
    @State private var ownKeyRouter: ManagedAI.OwnKeyRouter = .openRouter
    @State private var ownKeyDraft = ""
    @State private var ownKeySaving = false
    @State private var isReplacingOwnKey = false
    @State private var freeRequests: ManagedAI.FreeModelDailyRequests?
    @State private var freeRequestsFailed = false
    @State private var freeRequestsLoading = false

    var body: some View {
        managedAISection
            .task { await account.refresh() }
    }

    @ViewBuilder
    private var managedAISection: some View {
        VStack(alignment: .leading, spacing: 24) {
            if account.isSignedIn {
                ownKeySection
            } else {
                signedOutSection
            }
            freeModeSection
            spendingSection

            accountError
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await account.refresh(minimumInterval: 2, silently: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .managedAIOwnKeyDidChange).receive(on: RunLoop.main)) { _ in
            Task { await account.reloadOwnKey() }
        }
    }

    private var signedOutSection: some View {
        ManagedAISignInSection(title: "Your own key", message: "Sign in to add your own OpenRouter key.")
    }

    /// The product owner (2026-09-25): ForeverLM's AI features are bring your own key.
    /// The key is the pane's first card: with one stored, during the free
    /// days or once ForeverLM is paid for, OpenRouter bills the learner at
    /// cost for everything ForeverLM sends through it. OpenRouter is the only router since Ramp was removed on
    /// 2026-09-23. Every line that names the scope reads it off
    /// `ManagedAI.OwnKeyRouter`.
    private var ownKeySection: some View {
        SettingsSection(
            title: "Your own key",
            description: "AI features run on your own OpenRouter key, billed at cost."
        ) {
            billingCard {
                VStack(alignment: .leading, spacing: 0) {
                    // The key runs while the account is unlocked: the free
                    // days, or paid. Otherwise the proxy refuses it for every
                    // model, free ones and Free mode included (`app_locked`);
                    // paying is Billing's, so this row only goes there.
                    if !account.ownKeyAllowed {
                        billingRow(title: AppLockWall.title, detail: "Your key runs AI features again once you pay") {
                            Button("Open Billing") { onOpenBilling() }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("billing.ownKey.choosePlan")
                        }
                        rowDivider
                    }
                    if let own = account.ownKey {
                        billingRow(
                            title: "\(own.router.label) key ending in \(own.suffix)",
                            detail: "\(own.router.billedScopeCapitalized) are billed to your \(own.router.label) account"
                        ) {
                            Button("Replace") {
                                ownKeyRouter = own.router
                                ownKeyDraft = ""
                                isReplacingOwnKey = true
                            }
                            .buttonStyle(.bordered)
                            .disabled(isReplacingOwnKey || ownKeySaving)

                            Button("Remove", role: .destructive) {
                                Task {
                                    ownKeySaving = true
                                    defer { ownKeySaving = false }
                                    await account.removeOwnKey()
                                    isReplacingOwnKey = false
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(ownKeySaving)
                            .help("Without a key, AI features stop until you add one again")
                        }
                        if own.router == .openRouter {
                            rowDivider
                            freeRequestsRow
                                .task(id: own) { await loadFreeRequests() }
                        }
                    }

                    if account.ownKey == nil || isReplacingOwnKey {
                        if account.ownKey != nil { rowDivider }
                        ownKeyEntry
                    }

                    rowDivider
                    billingRow(title: "Training on your data", detail: ownKeyRouter.trainingSummary) {
                        SettingsMoreInfoButton {
                            Text(ownKeyRouter.aboutNote)
                            Text(ownKeyRouter.trainingNote)
                            Text(AIDataPolicy.openRouterAccountNote)
                        }
                        Button("Privacy Settings") { NSWorkspace.shared.open(AIFreeMode.openRouterPrivacyURL) }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("billing.ownKey.openRouterPrivacy")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("billing.ownKey.training")

                    // Free models too: OpenRouter lifts their daily cap
                    // once the account has bought $10 of credits.
                    rowDivider
                    billingRow(title: "Add $10 of credits", detail: ownKeyRouter.creditsSummary) {
                        SettingsMoreInfoButton {
                            Text(ownKeyRouter.creditsNote)
                        }
                        Button("Add Credits") { NSWorkspace.shared.open(ownKeyRouter.creditsURL) }
                            .buttonStyle(.bordered)
                    }
                    // A group of its own: on a plain container the
                    // identifier landed on the note and on the link.
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("billing.ownKey.credits")
                }
            }
        }
    }

    private var ownKeyEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SecureField("Paste your \(ownKeyRouter.label) key", text: $ownKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await saveOwnKey() } }
                    .accessibilityIdentifier("billing.ownKey.field")

                Button {
                    Task { await saveOwnKey() }
                } label: {
                    if ownKeySaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(ownKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ownKeySaving)
                .accessibilityIdentifier("billing.ownKey.save")

                if isReplacingOwnKey {
                    Button("Cancel") {
                        isReplacingOwnKey = false
                        ownKeyDraft = ""
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack(spacing: 12) {
                if ownKeyRouter == .openRouter {
                    Button {
                        Task {
                            if await account.connectOpenRouter() { isReplacingOwnKey = false }
                        }
                    } label: {
                        if account.openRouterConnectInFlight {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Connect OpenRouter")
                        }
                    }
                    .disabled(account.openRouterConnectInFlight || ownKeySaving)
                }
                Link(ownKeyRouter.keysLinkTitle, destination: ownKeyRouter.keysURL)
                    .font(.caption)
            }

            Label(ownKeyRouter.keyPrivacySummary, systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(ownKeyRouter.keyPrivacyNote)
                .accessibilityIdentifier("billing.ownKey.privacy")
        }
    }

    /// The product owner (2026-09-28): "any way to track how many openrouter free model
    /// calls we have left for the day?" The count is OpenRouter's own, read
    /// when the key row appears and on Refresh.
    private var freeRequestsRow: some View {
        billingRow(title: "Free-model requests today", detail: freeRequestsDetail) {
            Button {
                Task { await loadFreeRequests() }
            } label: {
                if freeRequestsLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .disabled(freeRequestsLoading)
            .help("Ask OpenRouter again")
            .accessibilityLabel("Refresh")
        }
        // A group of its own: on a plain row the identifier landed on both
        // texts and on Refresh.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("billing.ownKey.freeRequests")
    }

    private var freeRequestsDetail: String {
        if let freeRequests { return freeRequests.summary() }
        return freeRequestsFailed ? "Couldn't ask OpenRouter" : "Asking OpenRouter…"
    }

    private func loadFreeRequests() async {
        freeRequestsLoading = true
        defer { freeRequestsLoading = false }
        do {
            freeRequests = try await ManagedAI.freeModelDailyRequests()
            freeRequestsFailed = false
        } catch {
            freeRequests = nil
            freeRequestsFailed = true
        }
    }

    private func saveOwnKey() async {
        let key = ownKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !ownKeySaving else { return }
        ownKeySaving = true
        defer { ownKeySaving = false }
        // A key the router refuses stays in the field, with the reason below.
        guard await account.setOwnKey(key, router: ownKeyRouter) else { return }
        ownKeyDraft = ""
        isReplacingOwnKey = false
    }

    /// Free mode runs on the key above it, while the account may run it
    /// (product owner, 2026-09-26: "it should live under billing", said of the
    /// pane that held both until the 2026-09-28 split), so it sits under the
    /// key.
    private var freeModeSection: some View {
        SettingsSection(title: AIFreeMode.switchTitle) {
            billingCard {
                FreeModeSettingsView()
                    // Whether the account may run the key decides whether the
                    // switch can go on.
                    .id(account.ownKeyAllowed)
            }
        }
    }

    /// What the account has spent and the two limits on it, in one card. The
    /// month's figure and its limit are the proxy's and need an account; the
    /// daily background limit is this Mac's and does not.
    private var spendingSection: some View {
        SettingsSection(title: "Spending") {
            billingCard {
                VStack(alignment: .leading, spacing: 0) {
                    if account.isSignedIn {
                        spentThisMonthRow
                        rowDivider
                        monthlySpendLimitControls
                        rowDivider
                    }
                    BackgroundAIDailyCapRow()
                }
            }
        }
    }

    private var spentThisMonthRow: some View {
        billingRow(title: "Spent this month", detail: "Across all your devices") {
            if account.refreshInFlight, account.balance == nil {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing usage")
            } else {
                Text(Self.creditText(account.balance?.spendCap.spentThisMonthMicroUSD))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Link("Dashboard", destination: ManagedAI.billingDashboardURL)
                .buttonStyle(.bordered)
                .help("Opens the account-wide usage dashboard")
        }
    }

    @ViewBuilder
    private var accountError: some View {
        if let message = account.errorMessage ?? account.balanceErrorMessage {
            billingCard {
                HStack(spacing: 12) {
                    Label(message, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    if account.errorMessage == nil, account.balanceErrorMessage != nil {
                        Button("Retry") {
                            Task { await account.refresh() }
                        }
                        .disabled(account.refreshInFlight)
                    }
                }
            }
        }
    }

    private var rowDivider: some View {
        BillingRowDivider()
    }

    @ViewBuilder
    private var monthlySpendLimitControls: some View {
        let cap = account.balance?.spendCap
        let reached = cap?.isReached ?? false

        billingRow(
            title: reached ? "Monthly limit reached" : "Monthly limit",
            detail: spendLimitDetail(cap)
        ) {
            Picker("Limit", selection: spendCapSelection) {
                Text("No limit").tag(Int?.none)
                ForEach(ManagedAIAccountModel.spendCaps, id: \.self) { amount in
                    Text("$\(amount)")
                        .tag(Int?.some(amount))
                }
            }
            .labelsHidden()
            .frame(width: 96)
            .disabled(account.spendCapInFlight)
        }

        if let cap,
           let limit = cap.limitUSD,
           limit > 0 {
            ProgressView(value: min(cap.spentThisMonthUSD / limit, 1))
                .tint(reached ? .orange : .accentColor)
                .accessibilityLabel("Monthly spend limit")
                .accessibilityValue("\(Self.creditText(cap.spentThisMonthMicroUSD)) of \(Self.capLimitText(limit))")
                .padding(.top, 12)
        }
    }

    /// The cap lives on the server, so changing the picker writes through and a
    /// later refresh cannot drift from a local copy.
    private var spendCapSelection: Binding<Int?> {
        Binding(
            get: {
                guard let limit = account.balance?.spendCap.limitUSD else { return nil }
                return Int(limit.rounded())
            },
            set: { newValue in
                Task { await account.setSpendCap(monthlyLimitUSD: newValue.map(Double.init)) }
            }
        )
    }

    private static func capLimitText(_ usd: Double) -> String {
        creditText(Int((usd * 1_000_000).rounded()))
    }

    private func billingRow<Controls: View>(
        title: String,
        detail: String,
        @ViewBuilder controls: () -> Controls
    ) -> some View {
        BillingRow(title: title, detail: detail, controls: controls)
    }

    private func billingCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        BillingCard(content: content)
    }

    /// The month's spend is the row above, so this says only what the
    /// limit does; the bar under the picker shows how close it is.
    private func spendLimitDetail(_ cap: ManagedAI.SpendCap?) -> String {
        guard let cap else { return "AI pauses when it's reached" }
        if cap.isReached { return "AI is paused until next month" }
        guard cap.limitUSD != nil else { return "No limit set" }
        return "AI pauses when it's reached"
    }

    private static func creditText(_ microUSD: Int?) -> String {
        guard let microUSD else { return "—" }
        return ManagedAI.creditBalanceText(microUSD: microUSD)
    }

}

/// A card asking the learner to sign in, for a pane whose account state
/// needs the ForeverLM account.
private struct ManagedAISignInSection: View {
    let title: String
    let message: String

    @Environment(ManagedAIAccountModel.self) private var account

    var body: some View {
        SettingsSection(title: title) {
            BillingCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        Task { await account.signIn() }
                    } label: {
                        if account.signInInFlight {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Sign in with Apple")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(account.signInInFlight)
                }
            }
        }
    }
}

/// Bundled open-source license texts (ThirdPartyLicenses.txt) in a standalone
/// window (app menu, next to About). The file is already formatted for direct
/// display, so there is no parsing and no per-section SwiftUI layout: the whole
/// string goes into one read-only TextKit 1 NSTextView, which lays out lazily.
struct ThirdPartyLicensesWindowView: View {
    @State private var licenseText: String?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let licenseText {
                ReadOnlyPlainTextView(text: licenseText)
            } else if loadFailed {
                ContentUnavailableView(
                    "Licenses Unavailable",
                    systemImage: "doc.text",
                    description: Text("ThirdPartyLicenses.txt is missing from the app bundle.")
                )
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 480, minHeight: 400)
        .navigationTitle("Third-Party Licenses")
        .task {
            // The bundle read stays off the main actor; only the loaded string
            // is published back to UI state.
            guard licenseText == nil, !loadFailed else { return }
            let text = await Task.detached(priority: .userInitiated) { () -> String? in
                guard let url = Bundle.main.url(forResource: "ThirdPartyLicenses", withExtension: "txt") else {
                    return nil
                }
                return try? String(contentsOf: url, encoding: .utf8)
            }.value
            if let text {
                licenseText = text
            } else {
                loadFailed = true
            }
        }
    }
}

/// Read-only, selectable plain-text scroll view.
private struct ReadOnlyPlainTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1: avoids a macOS 26 TextKit 2 hang where click selection
        // hit-testing loops forever on the main thread (see ReviewChatComposer).
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }
}

/// Settings → Billing: paying for ForeverLM, and nothing else
/// (`AppPlanSettingsSection`). Until 2026-09-28 this pane also held the key,
/// Free mode, limits, usage and activity; the product owner asked for the subscription
/// to stand apart from all the AI usage, which is Settings › AI Usage now.
private struct BillingSettingsDetailView: View {
    @Environment(ManagedAIAccountModel.self) private var account

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if account.isSignedIn {
                    AppPlanSettingsSection()
                } else {
                    ManagedAISignInSection(title: "Plan", message: "Sign in to see your plan.")
                }

                // Checkout, the Stripe page and Keep My Plan report here;
                // cancelling reports in its own sheet.
                if let message = account.errorMessage {
                    Label(message, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Billing")
        .task { await account.refresh() }
    }
}

/// Settings → AI Usage: what runs ForeverLM's AI and what it has cost — the
/// learner's own key, Free mode, spending and its limits, then the activity
/// by task. Split from Billing on 2026-09-28.
private struct AIUsageSettingsDetailView: View {
    let onOpenBilling: () -> Void
    let onOpenSettings: (SettingsPane) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                AIUsageAccountSections(onOpenBilling: onOpenBilling)
                AIActivitySettingsSection(onOpenSettings: onOpenSettings)
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("AI Usage")
    }
}

/// AI Usage › Activity: what this Mac's usage ledger spent, grouped by
/// task, for a range. The managed server remains authoritative for charges;
/// `ai_usage_events` provides the detail. Was the Usage pane until 2026-09-24,
/// with a per-call log, facet filters, a prompt-cache line and a CSV export;
/// those were diagnostics, and `get_ai_usage_report` reads the same ledger.
private struct AIActivitySettingsSection: View {
    private enum UsageRange: String, CaseIterable, Identifiable {
        case today = "Today"
        case week = "7 Days"
        case thirtyDays = "30 Days"
        case allTime = "All"

        var id: String { rawValue }

        /// nil means no lower bound — the full ledger back to the first
        /// recorded call.
        var since: Date? {
            switch self {
            case .today: return Calendar.current.startOfDay(for: Date())
            case .week: return Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            case .thirtyDays: return Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
            case .allTime: return nil
            }
        }
    }

    /// Opens another Settings pane in this window, for a row's off switch.
    let onOpenSettings: (SettingsPane) -> Void

    @Environment(StudioViewModel.self) private var vm
    @Environment(\.dismissSettingsOverlay) private var dismissSettings

    @State private var range: UsageRange = .today
    @State private var isLoading = false
    /// Server reconciliation is deliberately separate from the local load.
    /// A full authoritative-ledger replay can span many network pages, but the
    /// already-cached usage pane must remain immediately useful while it runs.
    @State private var isReconciling = false
    @State private var activityGroups: [AIUsageTaskActivitySummary] = []
    @State private var expandedActivityKeys = Set<String>()
    @State private var subjectsByActivityKey: [String: [AIUsageSubjectActivitySummary]] = [:]
    @State private var subjectOffsetsByActivityKey: [String: Int] = [:]
    @State private var loadingActivityKeys = Set<String>()
    @State private var totalEvents = 0
    @State private var totalCost: Double?
    @State private var unpricedEvents = 0
    /// `AIUsageLedgerHealth`'s counters, read once per reload. Two UserDefaults
    /// lookups, so they stay on the main actor with the rest of the pane state.
    @State private var ledgerFailures = 0
    @State private var ledgerFailureDetail: String?
    @State private var serverReconciliationError: String?
    /// Expanded activity rows participate in the outer settings ScrollView's
    /// AppKit accessibility/focus tree. Keep that tree strictly bounded: a
    /// 410-item activity was enough to stall the main thread for several
    /// seconds even though its SQLite aggregation already ran off-main.
    private static let subjectPageSize = 50

    private var eventFilter: KnowledgeStore.AIUsageEventFilter {
        .init(
            since: range.since,
            provider: nil,
            model: nil,
            operation: nil,
            task: nil,
            clientPlatform: nil
        )
    }

    /// Stable identity for the current range, so a load that finishes after
    /// the range changed is dropped. `eventFilter` itself is not usable for
    /// this: its `since` is derived from `Date()` and so differs on every
    /// evaluation.
    private var filterSelectionKey: String { range.rawValue }

    var body: some View {
        callLogSection
            .task(id: range) { await reload() }
    }

    /// Ledger writes that failed, stated in the pane rather than only counted.
    ///
    /// A failed write is spend that happened and was not recorded, so the whole
    /// pane below reads low without saying so. This went unbuilt once and cost
    /// 486 unrecorded calls over two days: a schema change added
    /// `ai_usage_events.session_id` to the INSERT without the one-time ALTER, so
    /// every write failed with "no such column" into a counter nothing read.
    /// The provider's own message is shown because that is what names the cause.
    @ViewBuilder
    private var ledgerFailureWarning: some View {
        if ledgerFailures > 0 {
            HStack(spacing: 8) {
                Label(
                    "\(Self.exactCountText(ledgerFailures)) usage record\(ledgerFailures == 1 ? "" : "s") not saved",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
                .help("Their spend is missing from everything below")

                Spacer(minLength: 0)

                SettingsMoreInfoButton {
                    Text("Their spend is missing from everything below.")
                    if let detail = ledgerFailureDetail {
                        Text(detail)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Button("Clear Warning") {
                    AIUsageLedgerHealth.reset()
                    ledgerFailures = 0
                    ledgerFailureDetail = nil
                }
                .controlSize(.small)
                .help("Clears the count once the cause is fixed. The calls it counted stay unrecorded.")
            }
        }
    }

    private var callLogSection: some View {
        SettingsSection(title: "Activity") {
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Picker("Range", selection: $range) {
                            ForEach(UsageRange.allCases) { range in
                                Text(range.rawValue).tag(range)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 280)

                        Spacer()

                        if isLoading || isReconciling {
                            ProgressView().controlSize(.small)
                        }
                    }

                    ledgerFailureWarning

                    if let serverReconciliationError {
                        Label(serverReconciliationError, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(
                        totalEvents == 0
                            ? "No AI used in this period."
                            : "\(Self.exactCountText(totalEvents)) call\(totalEvents == 1 ? "" : "s") · \(Self.spendText(totalCost))"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("The model each task runs on is set under Settings › Background.")

                    if unpricedEvents > 0 {
                        Label(
                            "\(Self.exactCountText(unpricedEvents)) call\(unpricedEvents == 1 ? "" : "s") without a recorded cost",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("Their spend is missing from the total above")
                    }

                    if !activityGroups.isEmpty {
                        activityLog
                    }
                }
            }
        }
    }

    private var activityLog: some View {
        // Eager on purpose: nested lazy containers have rendered these rows
        // outside their card on macOS, drawing through the cards above.
        VStack(spacing: 0) {
            ForEach(activityGroups) { summary in
                DisclosureGroup(
                    isExpanded: activityExpansionBinding(for: summary)
                ) {
                    activitySubjects(for: summary)
                        .padding(.leading, 20)
                } label: {
                    activitySummaryRow(summary)
                }
                .padding(.vertical, 4)

                if summary.id != activityGroups.last?.id {
                    Divider()
                }
            }
        }
    }

    private func activityExpansionBinding(
        for summary: AIUsageTaskActivitySummary
    ) -> Binding<Bool> {
        Binding(
            get: { expandedActivityKeys.contains(summary.key) },
            set: { expanded in
                if expanded {
                    expandedActivityKeys.insert(summary.key)
                    guard subjectsByActivityKey[summary.key] == nil else { return }
                    Task { await loadSubjects(for: summary) }
                } else {
                    expandedActivityKeys.remove(summary.key)
                    subjectsByActivityKey.removeValue(forKey: summary.key)
                    subjectOffsetsByActivityKey.removeValue(forKey: summary.key)
                }
            }
        )
    }

    private func activitySummaryRow(_ summary: AIUsageTaskActivitySummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.task.map(Self.taskLabel) ?? "Legacy AI calls")
                    .font(.callout.weight(.medium))
                Text(Self.activityCountSummary(summary))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                modelsLine(
                    summary.models,
                    change: Self.isCharged(summary) ? summary.task.flatMap(Self.modelSetting) : nil
                )
            }

            Spacer(minLength: 8)

            if summary.unpricedCallCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Some calls in this activity have no recorded cost")
            }

            if let task = summary.task {
                switch AIUsageTaskNeed.of(taskKey: task) {
                case .needed:
                    Text("Needed")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help("ForeverLM needs this to import and find what you add, so it has no switch.")
                case .optional:
                    if let control = Self.offSwitch(for: task) {
                        Button("Turn off…") { onOpenSettings(control.pane) }
                            .buttonStyle(.link)
                            .font(.caption)
                            .help(control.help)
                    }
                case .requested:
                    EmptyView()
                }
            }

            Text(Self.spendText(summary.cost))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    /// Where the model behind an activity is chosen.
    private enum ModelSetting {
        /// Settings › Chat, or Settings › Background on a model or a task.
        case slot(ModelPickerSlot)
        /// Settings › Voice › Speech to text, on dictation's or recordings' model.
        case transcription(ManagedTranscriptionClient.Purpose)
        /// A pane with one model for the work: Voice's text to speech, Images, Videos.
        case pane(SettingsPane)
    }

    /// Whatever ForeverLM is charged for can have its model changed from its
    /// line (product owner, 2026-10-10: "for things we get charged for; we
    /// need to be able to change the model"). A free line has no link. A
    /// line with unpriced calls may have been charged, so it keeps one.
    private static func isCharged(_ summary: AIUsageTaskActivitySummary) -> Bool {
        (summary.cost ?? 0) > 0 || summary.unpricedCallCount > 0
    }

    /// Where an activity's model is set. Nil for work whose model is no
    /// learner's choice (Apple's on-device embeddings) or that no route
    /// records; a link there would open a pane that changes nothing.
    private static func modelSetting(for task: String) -> ModelSetting? {
        if let aiTask = AITask(rawValue: task) {
            if KeychainService.canHaveOwnRoute(aiTask) { return .slot(.task(aiTask)) }
            // The chat, and the work that runs on the chat's model.
            return aiTask.usesBackgroundModelDefault ? nil : .slot(.chat)
        }
        switch task {
        // Purposes of a chat, run on the chat's model.
        case "chat_title", "chat_history_compaction", "deep_research_chat", "chat_quiz_grading":
            return .slot(.chat)
        case "meeting_transcription", "podcast_transcription", "course_video_transcription":
            return .transcription(.media)
        case "composer_dictation", "review_dictation":
            return .transcription(.dictation)
        case "read_aloud", "review_speech":
            return .pane(.aiTextToSpeech)
        case "notebook_cover", "course_quiz_picture", "course_quiz_icon", "meeting_icon", "doc_image", "chat_image":
            return .pane(.aiImages)
        case "explainer_video":
            return .pane(.aiVideos)
        default:
            return nil
        }
    }

    private static func modelSettingHelp(_ setting: ModelSetting) -> String {
        switch setting {
        case .slot(.task(let task)):
            return "Settings › Background › Tasks › \(task.displayName)"
        case .slot:
            return "Runs on your chat's model: Settings › Chat"
        case .transcription(let purpose):
            return "Settings › Voice › Speech to text › \(purpose.settingsLabel)"
        case .pane(.aiTextToSpeech):
            return "Settings › Voice › Text to speech"
        case .pane(.aiVideos):
            return "Settings › Videos"
        case .pane:
            return "Settings › Images"
        }
    }

    private func openModelSetting(_ setting: ModelSetting) {
        switch setting {
        case .slot(let slot):
            onOpenSettings(ModelPickerSheetRequest.stage(slot))
        case .transcription(let purpose):
            TranscriptionModelRequest.stage(purpose)
            onOpenSettings(.aiTextToSpeech)
        case .pane(let pane):
            onOpenSettings(pane)
        }
    }

    /// Where the learner turns off the background work behind an activity,
    /// for the tasks that have a switch. A task without one shows no link: a
    /// link that only opens a pane would not turn anything off. Adding a
    /// switch for another task is one more case here.
    private static func offSwitch(for task: String?) -> (pane: SettingsPane, help: String)? {
        switch task {
        case "card_drafting":
            return (.general, "Settings › General › Memory › Draft cards from what you finish")
        case "meeting_transcription":
            return (.googleDrivePlugin, "Settings › Plugins › Google Drive › Transcribe recordings Google didn't")
        case "notebook_cover":
            return (.aiImages, "Settings › Images › Notebooks › Draw notebook covers")
        case "course_quiz_picture", "course_quiz_icon":
            return (.aiImages, "Settings › Images › Course quizzes › Draw pictures for new quizzes")
        case "transcript_formatting":
            return (.youtubePlugin, "Settings › Plugins › YouTube › Format new transcripts automatically")
        default:
            return nil
        }
    }

    @ViewBuilder
    private func activitySubjects(for summary: AIUsageTaskActivitySummary) -> some View {
        if loadingActivityKeys.contains(summary.key) {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        } else if let subjects = subjectsByActivityKey[summary.key] {
            VStack(spacing: 0) {
                ForEach(subjects) { subject in
                    subjectSummaryRow(subject, task: summary.task)
                    if subject.id != subjects.last?.id {
                        Divider()
                    }
                }

                subjectPageControls(for: summary, loadedCount: subjects.count)
            }
        }
    }

    @ViewBuilder
    private func subjectPageControls(
        for summary: AIUsageTaskActivitySummary,
        loadedCount: Int
    ) -> some View {
        let offset = subjectOffsetsByActivityKey[summary.key] ?? 0
        let remaining = max(0, summary.subjectCount - offset - loadedCount)
        if offset > 0 || remaining > 0 {
            HStack(spacing: 12) {
                Button("Previous") {
                    Task {
                        await loadSubjects(
                            for: summary,
                            offset: max(0, offset - Self.subjectPageSize)
                        )
                    }
                }
                .disabled(offset == 0 || loadingActivityKeys.contains(summary.key))

                Text(
                    "\(Self.exactCountText(offset + 1))–\(Self.exactCountText(offset + loadedCount)) "
                        + "of \(Self.exactCountText(summary.subjectCount))"
                )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Next \(Self.exactCountText(min(Self.subjectPageSize, remaining)))") {
                    Task {
                        await loadSubjects(
                            for: summary,
                            offset: offset + loadedCount
                        )
                    }
                }
                .disabled(remaining == 0 || loadingActivityKeys.contains(summary.key))
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func subjectSummaryRow(
        _ summary: AIUsageSubjectActivitySummary,
        task: String?
    ) -> some View {
        if let destination = Self.destination(of: summary) {
            Button { open(destination) } label: {
                subjectSummaryContent(summary, task: task)
            }
            .buttonStyle(.hoverWash(cornerRadius: 7, inset: -4))
            .contextMenu {
                if case .source(let id) = destination {
                    OtherWindowSourceMenuItem(sourceID: id)
                } else if case .entity(let link) = destination {
                    switch link {
                    case .notebook(let id): OtherWindowMenuItem(.notebook(id))
                    case .chat(let id): OtherWindowMenuItem(.chat(id))
                    default: EmptyView()
                    }
                }
            }
        } else {
            subjectSummaryContent(summary, task: task)
        }
    }

    private func subjectSummaryContent(
        _ summary: AIUsageSubjectActivitySummary,
        task: String?
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.subjectTitle ?? "\(task.map(Self.taskLabel) ?? "Legacy AI") activity")
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(Self.subjectDetailSummary(summary))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                modelsLine(summary.models)
            }

            Spacer(minLength: 8)

            if summary.unpricedCallCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("Some calls for this item have no recorded cost")
            }

            Text(Self.spendText(summary.cost))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    /// What a click on an item row opens. The ledger stores an id and a type
    /// per item: a source's id under its source type, a notebook's, a chat's.
    /// Anything else (a memory card, a figure, an activity with no record of
    /// its own) is not something the app has a page for, so its row stays
    /// plain text.
    private enum SubjectDestination {
        case source(String)
        case entity(StudioEntityLink)
    }

    private static let sourceSubjectTypes: Set<String> = [
        "article", "paper", "podcast", "podcast_episode", "book", "meeting",
        "video", "xPost", "manual", "unclassified",
    ]

    private static func destination(of summary: AIUsageSubjectActivitySummary) -> SubjectDestination? {
        guard let id = summary.subjectID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty, let type = summary.subjectType else { return nil }
        if sourceSubjectTypes.contains(type) { return .source(id) }
        switch type {
        case "notebook": return .entity(.notebook(id))
        case "chat", "review_session": return .entity(.chat(id))
        default: return nil
        }
    }

    /// Opens the item in this window, behind Settings: the overlay closes so
    /// the Reader, notebook or chat is what the click shows.
    private func open(_ destination: SubjectDestination) {
        dismissSettings()
        Task {
            switch destination {
            case .source(let id): await vm.openLinkedSourceInReader(id)
            case .entity(let link): await vm.open(link)
            }
        }
    }

    /// The model a row ran on, beneath its counts. A row that ran on several
    /// names the two with the most calls and counts the rest; the tooltip
    /// gives every model's share. A charged row adds a link to where its
    /// model is set, beside the model it changes.
    @ViewBuilder
    private func modelsLine(_ models: [AIUsageModelUse], change: ModelSetting? = nil) -> some View {
        let named = Self.namedModels(models)
        if !named.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.modelsText(named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(
                        named.map { "\($0.name) — \(Self.exactCountText($0.calls)) call\($0.calls == 1 ? "" : "s")" }
                            .joined(separator: "\n")
                    )
                if let change {
                    Button("Change Model…") { openModelSetting(change) }
                        .buttonStyle(.link)
                        .font(.caption)
                        .fixedSize()
                        .help(Self.modelSettingHelp(change))
                }
            }
        }
    }

    /// Models by the name the model picker gives them, most calls first. Two
    /// ledger ids can share a name ("openai/gpt-5.6-sol" and "gpt-5.6-sol"),
    /// so their calls are added together under it.
    private static func namedModels(_ models: [AIUsageModelUse]) -> [(name: String, calls: Int)] {
        var calls: [String: Int] = [:]
        for use in models {
            calls[modelName(use), default: 0] += use.callCount
        }
        return calls
            .map { (name: $0.key, calls: $0.value) }
            .sorted { $0.calls != $1.calls ? $0.calls > $1.calls : $0.name < $1.name }
    }

    /// A ledger row's model as the model picker names it. A host the app no
    /// longer knows keeps the id it recorded.
    private static func modelName(_ use: AIUsageModelUse) -> String {
        guard let provider = AIProvider(ledgerName: use.provider) else { return use.model }
        return AIModelCatalog.pickerName(provider: provider, modelID: use.model)
    }

    private static func modelsText(_ named: [(name: String, calls: Int)]) -> String {
        let shown = named.prefix(2).map(\.name).joined(separator: ", ")
        let rest = named.count - 2
        return rest > 0 ? "\(shown) and \(exactCountText(rest)) more" : shown
    }

    private static func countText(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 10_000 { return String(format: "%.0fk", Double(value) / 1_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return "\(value)"
    }

    /// Grouped, unabbreviated count — the call log states exactly how many
    /// calls exist, since "13.9k" would leave the reader unsure whether
    /// anything was being hidden.
    private static func exactCountText(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private static func activityCountSummary(_ summary: AIUsageTaskActivitySummary) -> String {
        var parts: [String] = []
        if summary.subjectCount > 0 {
            parts.append("\(exactCountText(summary.subjectCount)) \(subjectCountLabel(summary.subjectType, count: summary.subjectCount))")
        } else if summary.activityCount < summary.callCount {
            parts.append("\(exactCountText(summary.activityCount)) activit\(summary.activityCount == 1 ? "y" : "ies")")
        }
        parts.append("\(exactCountText(summary.callCount)) call\(summary.callCount == 1 ? "" : "s")")
        if summary.subjectCount == 0 {
            if summary.inputTokens > 0 { parts.append("\(countText(summary.inputTokens)) in") }
            if summary.outputTokens > 0 { parts.append("\(countText(summary.outputTokens)) out") }
        }
        return parts.joined(separator: " · ")
    }

    private static func subjectDetailSummary(_ summary: AIUsageSubjectActivitySummary) -> String {
        var parts: [String] = []
        if let type = summary.subjectType { parts.append(subjectTypeLabel(type)) }
        parts.append("\(exactCountText(summary.callCount)) call\(summary.callCount == 1 ? "" : "s")")
        if summary.inputTokens > 0 { parts.append("\(countText(summary.inputTokens)) in") }
        if summary.outputTokens > 0 { parts.append("\(countText(summary.outputTokens)) out") }
        return parts.joined(separator: " · ")
    }

    private static func subjectCountLabel(_ type: String?, count: Int) -> String {
        let singular: String
        switch type {
        case "podcast_episode": singular = "podcast episode"
        case "video": singular = "video"
        case "article": singular = "article"
        case "paper": singular = "paper"
        case "book": singular = "book"
        case "chat": singular = "chat"
        case "activity": return count == 1 ? "activity" : "activities"
        case "review_session": singular = "review"
        default: singular = "item"
        }
        return count == 1 ? singular : singular + "s"
    }

    private static func subjectTypeLabel(_ type: String) -> String {
        switch type {
        case "podcast_episode": return "Podcast episode"
        case "review_session": return "Review"
        default: return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func taskLabel(_ task: String) -> String {
        AIUsageTaskLabel.text(for: task)
    }

    /// Period spend. Sub-cent totals keep four decimals so a real amount never
    /// rounds away to $0.00.
    private static func spendText(_ usd: Double?) -> String {
        guard let usd else { return "no cost recorded" }
        if usd > 0 && usd < 0.01 { return String(format: "$%.4f", usd) }
        return String(format: "$%.2f", usd)
    }

    private func reload() async {
        isLoading = true

        ledgerFailures = AIUsageLedgerHealth.failureCount
        ledgerFailureDetail = AIUsageLedgerHealth.lastFailureDescription

        // StorageService is an actor, so the SQLite scans run on its executor
        // rather than the main actor.
        let storage = StorageService()
        await reloadLocalUsage(from: storage)
        isLoading = false

        guard !Task.isCancelled else { return }

        if ManagedAI.isSignedIn {
            isReconciling = true
            defer { isReconciling = false }
            do {
                let importedEvents = try await reconcileManagedUsage(into: storage)
                serverReconciliationError = nil
                if importedEvents, !Task.isCancelled {
                    await reloadLocalUsage(from: storage)
                }
            } catch {
                guard !Task.isCancelled else { return }
                serverReconciliationError = "Server usage could not be reconciled, so the totals below may be incomplete: \(error.localizedDescription)"
            }
        } else {
            serverReconciliationError = nil
        }
    }

    /// Publishes the on-device ledger before making any network request. The
    /// server mirror is incremental and authoritative, but it is a refresh of
    /// this cache rather than a prerequisite for rendering it.
    private func reloadLocalUsage(from storage: StorageService) async {
        // Price what can be priced before counting what cannot, so the
        // unpriced warning names only calls whose price is really unknown.
        await AIUsageTracker.repriceLedger(storage: storage)
        await reloadFilteredUsage(from: storage)
    }

    /// Pull every unseen D1 usage row. Opening the Usage pane is one of the
    /// events that refreshes accounting — running out of credit is the other,
    /// see `ManagedAIAccountModel.pullServerUsage`, which owns the pull so both
    /// share one cursor and one import path.
    private func reconcileManagedUsage(into storage: StorageService) async throws -> Bool {
        try await ManagedAIAccountModel.pullServerUsage(into: storage)
    }

    /// Reloads the range's totals and activity groups without reconciling the
    /// server.
    private func reloadFilteredUsage(from storage: StorageService = StorageService()) async {
        let key = filterSelectionKey
        let filter = eventFilter
        let totals = try? await storage.aiUsageEventTotals(filter: filter)
        let loadedActivityGroups = (try? await storage.aiUsageTaskActivities(filter: filter)) ?? []

        // A newer range may have started another load while these
        // actor-isolated SQLite reads were in flight.
        guard key == filterSelectionKey else { return }

        totalEvents = totals?.count ?? 0
        totalCost = totals?.cost
        unpricedEvents = totals?.unpriced ?? 0
        activityGroups = loadedActivityGroups
        expandedActivityKeys.removeAll()
        subjectsByActivityKey.removeAll()
        subjectOffsetsByActivityKey.removeAll()
        loadingActivityKeys.removeAll()
    }

    private func loadSubjects(
        for summary: AIUsageTaskActivitySummary,
        offset: Int = 0
    ) async {
        guard !loadingActivityKeys.contains(summary.key) else { return }
        loadingActivityKeys.insert(summary.key)
        defer { loadingActivityKeys.remove(summary.key) }

        let key = filterSelectionKey
        let filter = eventFilter
        let subjects = (try? await StorageService().aiUsageSubjectActivities(
            task: summary.task,
            filter: filter,
            limit: Self.subjectPageSize,
            offset: offset
        )) ?? []
        guard key == filterSelectionKey,
              expandedActivityKeys.contains(summary.key),
              activityGroups.contains(where: { $0.key == summary.key }) else { return }
        subjectsByActivityKey[summary.key] = subjects
        subjectOffsetsByActivityKey[summary.key] = offset
    }

}

/// Settings → Plugins → Build Your Own: the user-facing home for
/// user-built (ingest-scoped) plugins. Three jobs, in plain words: explain
/// what a personal plugin is, hand the user a ready-made setup prompt with
/// their real MCP URL filled in, and list connected plugins with their
/// source counts and the two kill switches (remove access / remove sources).
private struct UserPluginsSettingsDetailView: View {
    @Environment(StudioViewModel.self) private var vm

    @State private var mcpURL: String?
    @State private var plugins: [MCPOAuthProvider.UserPluginSummary] = []
    @State private var sourceCounts: [String: Int] = [:]
    @State private var didCopyPrompt = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var pluginPendingAccessRemoval: MCPOAuthProvider.UserPluginSummary?
    @State private var pluginPendingSourceRemoval: MCPOAuthProvider.UserPluginSummary?

    var body: some View {
        PluginSetupDetailView(
            title: "Build Your Own",
            description: "A private plugin your AI assistant builds; it can add sources, never read your library."
        ) {
            VStack(alignment: .leading, spacing: 24) {
                setupSection
                pluginListSection
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .task { await reload() }
        .confirmationDialog(
            "Remove this plugin's access?",
            isPresented: Binding(
                get: { pluginPendingAccessRemoval != nil },
                set: { if !$0 { pluginPendingAccessRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: pluginPendingAccessRemoval
        ) { plugin in
            Button("Remove Access", role: .destructive) {
                Task { await removeAccess(plugin) }
            }
        } message: { plugin in
            Text("“\(plugin.name)” loses access immediately and would need your approval to reconnect. Sources it added stay in your library.")
        }
        .confirmationDialog(
            "Remove this plugin's sources?",
            isPresented: Binding(
                get: { pluginPendingSourceRemoval != nil },
                set: { if !$0 { pluginPendingSourceRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: pluginPendingSourceRemoval
        ) { plugin in
            Button("Remove \(sourceCounts[plugin.name] ?? 0) Sources", role: .destructive) {
                Task { await removeSources(plugin) }
            }
        } message: { plugin in
            Text("Every source “\(plugin.name)” added is dismissed and archived, and won't be re-added automatically. Reviews you completed on them are kept.")
        }
    }

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How it works")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Copy the setup prompt below — it already contains your personal ForeverLM address.")
                Text("2. Paste it into Claude, ChatGPT, or any coding assistant and tell it what to sync.")
                Text("3. Approve the connection once in ForeverLM — the approval says exactly what it may do.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    copyPrompt()
                } label: {
                    Label(didCopyPrompt ? "Copied" : "Copy Setup Prompt", systemImage: didCopyPrompt ? "checkmark" : "doc.on.doc")
                }
                .disabled(mcpURL == nil)

                Link("Read the full guide", destination: URL(string: "https://foreverlm.com/build-your-own-plugin")!)
                    .font(.callout)
            }
            if mcpURL == nil {
                NavigationLink(value: SettingsPane.mcp) {
                    Label("Set Up MCP", systemImage: "link.badge.plus")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var pluginListSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your plugins")
                .font(.headline)
            if plugins.isEmpty {
                Text("None yet. Once a plugin you set up is approved, it appears here with what it has added.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(plugins) { plugin in
                        UserPluginSettingsRow(
                            plugin: plugin,
                            sourceCount: sourceCounts[plugin.name] ?? 0,
                            isWorking: isWorking,
                            onRemoveAccess: { pluginPendingAccessRemoval = plugin },
                            onRemoveSources: { pluginPendingSourceRemoval = plugin }
                        )
                        if plugin.id != plugins.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .quaternarySystemFill))
                )
            }
        }
    }

    private func reload() async {
        let oauthProvider = await MCPOAuthProvider.sharedProvider()
        plugins = await oauthProvider.userPluginSummaries()
        sourceCounts = (try? await vm.storage.activePluginSourceCounts()) ?? [:]
        let url = await Task.detached { KeychainService.load(.mcpTunnelURL) }.value
        mcpURL = (url?.isEmpty == false) ? url : nil
    }

    private func copyPrompt() {
        guard let mcpURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(UserPluginSetupPrompt.text(mcpURL: mcpURL), forType: .string)
        didCopyPrompt = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopyPrompt = false
        }
    }

    private func removeAccess(_ plugin: MCPOAuthProvider.UserPluginSummary) async {
        isWorking = true
        defer { isWorking = false }
        let oauthProvider = await MCPOAuthProvider.sharedProvider()
        await oauthProvider.revokeClient(plugin.id)
        await reload()
    }

    private func removeSources(_ plugin: MCPOAuthProvider.UserPluginSummary) async {
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        // Same implementation the assistant-facing tool uses (MCP/UI parity),
        // so removal semantics can never drift between the two surfaces.
        let outcome = await MCPToolRegistry.shared.callToolDetailed(
            name: "remove_connector_sources",
            arguments: ["connector_label": plugin.name],
            access: .internalFullAccess
        )
        if outcome.isError {
            errorMessage = outcome.text
        }
        await reload()
    }

}

/// The paste-into-your-assistant recipe with the user's real MCP URL. Kept in
/// lockstep with docs-site/build-your-own-plugin.md — the Build Your Own
/// button is that page with the blank filled in, and the Meetings tab's notice
/// is the same page with the blank filled in for the provider whose meetings
/// have stopped arriving.
enum UserPluginSetupPrompt {
    /// The Meetings tab's version. It is only ever copied when the library
    /// already holds the provider's meetings, so a plugin ran once and has
    /// stopped — the assistant's first job is to find it and get it going
    /// again, not to build a second one beside it. Building is the fallback,
    /// and the contract that follows applies to both.
    static func text(mcpURL: String, for provider: MeetingProvider) -> String {
        let meetings = "my \(provider.displayName) meetings"
        let lead = """
        My \(provider.displayName) meetings have stopped arriving in ForeverLM. Get them syncing again, and make sure they keep syncing.

        They arrived through a plugin before, so start by finding it rather than building a new one: look for its scheduled job (a launchd agent labelled com.foreverlm.plugin.*, or a cron entry), its script (under ~/.foreverlm/plugins, ~/Library/Application Support/ForeverLM/Plugins, or in one of my repos), and its stored tokens and log. If it exists, read the log and find out why it stopped — usually one of its two authorizations expired or was never finished, its schedule stopped loading, or a rotating refresh token was lost to overlapping runs. Reconnect only the half that dropped, keep its existing ForeverLM registration (or, if ForeverLM no longer knows it, register again under the same client_name) so its sources stay filed together, run it once, confirm the meetings land, and fix whatever let it drop so it does not happen again. If there are several copies, keep the one that works and remove the rest so they cannot fight over tokens.

        Only if no plugin is left, build me one that syncs \(meetings) into ForeverLM, then set it up to run on a sensible schedule.
        """
        return text(mcpURL: mcpURL, syncing: meetings, lead: lead, notes: provider.pluginSetupNotes)
    }

    /// `syncing` fills the recipe's blank when the caller already knows what
    /// the plugin is for; nil leaves it for the user. `lead` replaces the
    /// opening request when the caller has a more specific one to make than
    /// "build me a plugin". `notes` is appended as a closing paragraph
    /// when non-empty.
    static func text(
        mcpURL: String,
        syncing subject: String? = nil,
        lead: String? = nil,
        notes: String = ""
    ) -> String {
        var prompt = lead ?? """
        Build me a plugin that syncs \(subject ?? "[WHAT — e.g. my Readwise highlights]") into ForeverLM, then set it up to run on a sensible schedule.
        """
        prompt += """


        ForeverLM exposes an MCP server (Streamable HTTP) at my personal URL:
        \(mcpURL)

        The plugin must follow ForeverLM's ingest-only contract:
        1. Register itself as an OAuth client: POST \(mcpURL)/oauth/register with JSON including "client_name" (a short human name — it labels every source this plugin adds), optionally "logo_uri" (an https icon URL shown in ForeverLM's plugin list), "redirect_uris" (e.g. ["http://127.0.0.1:<port>/callback"]), and "token_endpoint_auth_method": "none".
        2. Run the OAuth 2.1 authorization-code flow with PKCE (S256) against \(mcpURL)/oauth/authorize and \(mcpURL)/oauth/token, requesting scope=mcp:ingest. I will approve it once in ForeverLM. Store the refresh token (it rotates on every refresh) and refresh as needed. If the token endpoint answers invalid_client, ForeverLM no longer knows this registration: I removed the plugin's access, or ForeverLM was reinstalled or moved to another Apple account. Stop and tell me how to reconnect it; reconnecting registers again with the same client_name and never reuses the old client_id.
        3. Speak MCP at POST \(mcpURL)/mcp: call initialize first and reuse the Mcp-Session-Id response header on later requests; push ordinary content with add_sources — items of {url, title, source_type, content}, where url is a stable canonical URL (the dedup key — the same item must produce the same URL every run), source_type is usually "article", and content is the full plain text. A meeting (source_type "meeting") also carries occurred_at (when it took place, ISO 8601) and parent_group (the recurring series it belongs to, matched to an existing meeting group by id or title or created); without them a meeting is dated by the push and sits outside every series. At most 50 items and about 1 MB per call; split larger batches. Papers must use import_connector_paper so the mandatory paper models run: pass a public paper url, or call get_connector_inbox, stage a PDF only in that returned directory, and pass its file_path plus a stable public source_url.
        4. Be idempotent: re-runs must not duplicate anything (the server dedups by URL and reports "already existed"); re-push items whose content changed with "update_existing": true, which for a meeting also applies occurred_at and parent_group.
        5. Print add_sources' per-item results and fail loudly on any error line. My credentials for the service being synced stay inside the plugin and are never sent to ForeverLM.
        6. If the MCP URL doesn't answer, ForeverLM isn't running on my Mac — skip the run quietly and try again next time. One exception: if it answers HTTP 502, 503 or 504 and GET http://127.0.0.1:\(ForeverLMRuntimeIdentity.mcpLoopbackPort)/mcp-url (ForeverLM's own listener on this Mac, up only while it is connected) returns {"url": …} naming a different URL, my personal URL has moved. Save that URL, register there again under the same client_name, approve again, and carry on. A registration and its tokens belong to the URL they were made at, so never send them to the new one.
        """
        if !notes.isEmpty {
            prompt += "\n\n" + notes
        }
        return prompt
    }
}

/// A plugin's attention summary as a line of its own: capitalised, and
/// ended with a period when asked for one and the text doesn't already end a
/// sentence.
private func sentenceCased(_ text: String, terminated: Bool = false) -> String {
    var line = text.prefix(1).uppercased() + text.dropFirst()
    if terminated, let last = line.last, !".!?…".contains(last) {
        line += "."
    }
    return line
}

private struct UserPluginSettingsRow: View {
    let plugin: MCPOAuthProvider.UserPluginSummary
    let sourceCount: Int
    let isWorking: Bool
    let onRemoveAccess: () -> Void
    let onRemoveSources: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            logoView
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name)
                    .font(.body.weight(.medium))
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(plugin.needsAttention ? .orange : .secondary)
            }
            Spacer()
            if sourceCount > 0 {
                Button("Remove Sources…", action: onRemoveSources)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isWorking)
            }
            Button("Remove Access…", action: onRemoveAccess)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isWorking)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusText: String {
        if let trouble = plugin.attentionSummary { return sentenceCased(trouble) }
        if plugin.reportedState == .syncing { return "Syncing…" }
        if let lastSync = plugin.lastSuccessfulSyncAt {
            return "Last synced \(lastSync.formatted(.relative(presentation: .named)))"
        }
        return sourceCount == 1 ? "1 source added" : "\(sourceCount) sources added"
    }

    /// Registration logos render here and only here — the consent surfaces
    /// deliberately keep the generic icon so a malicious client can't dress
    /// its approval request up as a trusted product.
    @ViewBuilder
    private var logoView: some View {
        if let logo = plugin.logoURI, let url = URL(string: logo) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                fallbackIcon
            }
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            fallbackIcon
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: "puzzlepiece.extension.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.indigo)
            .frame(width: 26, height: 26)
    }
}

private struct PluginPickerRow<Icon: View>: View {
    let title: String
    let subtitle: String
    /// nil renders no state chip — for action rows (Build Your Own) that have
    /// no connection of their own.
    var status: PluginStatus?
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        SettingsCard {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                    icon()
                }
                .frame(width: 44, height: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 12)

                if let status {
                    Text(status.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(status.color)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(status.color.opacity(status == .connected ? 0.12 : 0.08))
                        )
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Playful 2×2 cluster of the external assistant logos (Claude, Codex, Gemini, Grok),
/// each tilted slightly like stickers.
struct AssistantLogoCluster: View {
    var logoSize: CGFloat = 13

    private var spacing: CGFloat { logoSize * 4 / 13 }

    var body: some View {
        VStack(spacing: spacing) {
            HStack(spacing: spacing) {
                logo("ClaudeIcon", rotation: -8)
                logo("OpenAIIcon", rotation: 6, isTemplate: true)
            }
            HStack(spacing: spacing) {
                logo("GeminiIcon", rotation: 7)
                // Grok's logo is solid black; template rendering keeps it visible in dark mode.
                logo("GrokIcon", rotation: -6, isTemplate: true)
            }
        }
    }

    @ViewBuilder
    private func logo(_ name: String, rotation: Double, isTemplate: Bool = false) -> some View {
        Image(name)
            .resizable()
            .renderingMode(isTemplate ? .template : .original)
            .scaledToFit()
            .frame(width: logoSize, height: logoSize)
            .foregroundStyle(.primary)
            .rotationEffect(.degrees(rotation))
    }
}

private struct PluginSetupDetailView<Content: View>: View {
    let title: String
    let description: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsSection(
                    title: title,
                    description: description
                ) {
                    content()
                }
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(title)
    }
}

private struct XPluginSettingsView: View {
    @Environment(StudioViewModel.self) private var vm

    private var status: PluginStatus {
        guard vm.isXOAuthSignedIn else { return .notConnected }
        return vm.xPluginNeedsReauth ? .needsAttention : .connected
    }

    private var subtitle: String {
        switch status {
        case .connected: return "Connected for bookmark sync"
        case .needsAttention: return "Session expired — reconnect to keep syncing"
        case .notConnected: return "Connect your X account"
        }
    }

    /// The button says so while the sign-in window is on its way. The system
    /// agent that hosts it launches on demand and can take a while on a busy
    /// Mac; until this spinner, the click looked like it had done nothing. The
    /// resting label stays in the layout so the button keeps its width.
    @ViewBuilder
    private func connectLabel<Resting: View>(_ resting: Resting) -> some View {
        ZStack {
            resting.opacity(vm.isConnectingX ? 0 : 1)
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text("Connecting…")
            }
            .opacity(vm.isConnectingX ? 1 : 0)
        }
    }

    var body: some View {
        PluginSettingsCard(
            title: "",
            subtitle: subtitle,
            icon: {
                XLogoShape()
                    .fill(.foreground, style: FillStyle(eoFill: true))
                    .frame(width: 15, height: 15)
            },
            status: status
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Spacer()

                    if vm.isXOAuthSignedIn {
                        if vm.xPluginNeedsReauth {
                            Button {
                                Task { await vm.signInWithX() }
                            } label: {
                                connectLabel(Label("Reconnect", systemImage: "arrow.clockwise"))
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityLabel(Text(vm.isConnectingX ? "Connecting to X" : "Reconnect X account"))
                        } else {
                            Button {
                                Task { await vm.syncXBookmarks(showResult: true) }
                            } label: {
                                ZStack {
                                    Label("Sync", systemImage: "arrow.clockwise")
                                        .opacity(vm.isSyncingXBookmarks ? 0 : 1)
                                    HStack(spacing: 6) {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("Syncing")
                                    }
                                    .opacity(vm.isSyncingXBookmarks ? 1 : 0)
                                }
                            }
                            .disabled(vm.isSyncingXBookmarks || vm.isXSyncPaused)
                            .accessibilityLabel(Text(vm.isSyncingXBookmarks ? "Syncing X bookmarks" : "Sync X bookmarks"))

                            if vm.xPluginOffersReconnect {
                                Button {
                                    Task { await vm.signInWithX() }
                                } label: {
                                    Label("Reconnect", systemImage: "link")
                                }
                                .disabled(vm.isSyncingXBookmarks || vm.isConnectingX)
                                .accessibilityLabel(Text(vm.isConnectingX ? "Connecting to X" : "Reconnect X account"))
                            }
                        }

                        Button("Disconnect", role: .destructive) {
                            vm.signOutOfX()
                        }
                    } else {
                        Button {
                            Task { await vm.signInWithX() }
                        } label: {
                            connectLabel(Label("Connect", systemImage: "link"))
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel(Text(vm.isConnectingX ? "Connecting to X" : "Connect X account"))
                    }
                }

                if let error = vm.xPluginErrorMessage {
                    PluginErrorNotice(title: "Couldn’t connect to X", message: error)
                }

                Divider()

                HStack(spacing: 12) {
                    if let lastSync = vm.lastXSyncDate {
                        Label("Synced \(lastSync.roughTimeAgo)", systemImage: "clock")
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Link(destination: URL(string: "https://docs.foreverlm.com/x-posts")!) {
                        Label("About X bookmarks", systemImage: "arrow.up.right")
                            .labelStyle(.titleAndIcon)
                    }
                    .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

            }
        }
        .onAppear {
            vm.checkXSignInStatus()
        }
    }
}

private struct GoogleDriveConnectionSettingsView: View {
    @Environment(StudioViewModel.self) private var vm
    // Placeholders; `.onAppear` fills them in off-main (synced Keychain keys
    // are securityd IPC on every read, and `@State` inits re-run per re-init).
    @State private var isSignedIn = false
    @State private var hasFolderReadAccess = false
    @State private var connectedAccounts: [GoogleDriveAccount] = []
    @State private var hasLegacyConnection = false
    /// The account an untagged folder is read through, from the Keychain.
    @State private var defaultAccountID: String?
    @State private var isWorking = false
    @State private var statusMessage: String?
    @SyncedStorage(StudioViewModel.meetingOwnTranscriptionEnabledKey)
    private var ownTranscriptionEnabled = false

    /// The meeting folders each connected account reads, by account id.
    private var foldersByAccount: GoogleDriveFolderAttribution {
        GoogleDriveFolderAttribution(
            metadata: vm.meetingMetadata,
            accountIDs: connectedAccounts.map(\.id),
            defaultAccountID: defaultAccountID
        )
    }

    var body: some View {
        PluginSettingsCard(
            title: "Google Drive",
            subtitle: "Read-only import of meeting recordings and transcripts from folders you choose.",
            icon: {
                Image("GoogleDriveIcon")
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: 22, height: 18)
            },
            status: isSignedIn
                ? (hasFolderReadAccess ? .connected : .needsAttention)
                : .notConnected
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if !connectedAccounts.isEmpty {
                    let attribution = foldersByAccount
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(connectedAccounts) { account in
                            accountSection(account, folders: attribution.folders(for: account.id))
                        }
                        let strays = attribution.unattributed
                        if !strays.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Folders whose Google account is no longer connected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                folderList(strays)
                            }
                        }
                    }
                } else if hasLegacyConnection {
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.fill")
                            .foregroundStyle(.secondary)
                        Text("Connected Google account")
                        Spacer(minLength: 8)
                        Button("Disconnect", role: .destructive) {
                            disconnectLegacyConnection()
                        }
                        .disabled(isWorking)
                    }
                }

                HStack(spacing: 8) {
                    Spacer()
                    Button {
                        connectAndChooseFolder()
                    } label: {
                        if isWorking {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label(
                                isSignedIn && !hasFolderReadAccess
                                    ? "Reconnect and Choose Folder"
                                    : (isSignedIn ? "Add Account or Folder" : "Connect and Choose Folder"),
                                systemImage: "folder.badge.plus"
                            )
                        }
                    }
                    .disabled(!GoogleDriveService.shared.canConnect || isWorking)
                }

                if isSignedIn {
                    Divider()
                    Toggle("Transcribe recordings Google didn't", isOn: $ownTranscriptionEnabled)
                    Text("Each recording is a paid speech-to-text run.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !GoogleDriveService.shared.canConnect {
                    Text("This build of ForeverLM has no Google Drive OAuth client configured.")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if isSignedIn && !hasFolderReadAccess {
                    Text("Reconnect to let ForeverLM read the files inside meeting folders.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            Task {
                _ = try? await GoogleDriveService.shared.adoptLegacyAccountIfNeeded()
                await refreshConnectionState()
            }
        }
    }

    /// One connected Google account: who it is, the meeting folders ForeverLM
    /// reads through it, and its Disconnect — the shape Slack gives a workspace.
    @ViewBuilder
    private func accountSection(_ account: GoogleDriveAccount, folders: [GoogleDriveFolderAttribution.Folder]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayLabel)
                        .lineLimit(1)
                    Text(accountSummary(account, folders: folders))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Disconnect", role: .destructive) {
                    disconnect(accountID: account.id)
                }
                .disabled(isWorking)
            }
            if !folders.isEmpty {
                folderList(folders)
                    .padding(.leading, 24)
            }
        }
    }

    /// "Alan Young · reads 2 folders." The name is left out when the label
    /// already is the name (an account Google gave no email for).
    private func accountSummary(_ account: GoogleDriveAccount, folders: [GoogleDriveFolderAttribution.Folder]) -> String {
        var parts: [String] = []
        let name = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != account.displayLabel { parts.append(name) }
        switch folders.count {
        case 0: parts.append("No meeting folder yet")
        case 1: parts.append("Reads 1 folder")
        default: parts.append("Reads \(folders.count) folders")
        }
        return parts.joined(separator: " · ")
    }

    private func folderList(_ folders: [GoogleDriveFolderAttribution.Folder]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(folders) { folder in
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(folder.title)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let url = folder.url {
                        Link(destination: url) {
                            Label("Open in Drive", systemImage: "arrow.up.right")
                                .labelStyle(.titleAndIcon)
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    private func connectAndChooseFolder() {
        guard !isWorking else { return }
        isWorking = true
        statusMessage = nil
        Task { @MainActor in
            defer {
                isWorking = false
            }
            do {
                try await vm.connectAndImportGoogleDriveMeetings()
                await refreshConnectionState()
                statusMessage = "Meeting folder added."
            } catch is CancellationError {
                return
            } catch {
                await refreshConnectionState()
                statusMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func refreshConnectionState() async {
        let status = await Task.detached(priority: .userInitiated) {
            (
                signedIn: GoogleDriveService.shared.isSignedIn,
                folder: GoogleDriveService.shared.hasFolderReadAccess,
                accounts: GoogleDriveService.shared.connectedAccounts,
                legacy: GoogleDriveService.shared.hasLegacyConnection,
                defaultAccountID: KeychainService.googleDriveDefaultAccountID
            )
        }.value
        isSignedIn = status.signedIn
        hasFolderReadAccess = status.folder
        defaultAccountID = status.defaultAccountID
        connectedAccounts = status.accounts.sorted {
            $0.displayLabel.localizedCaseInsensitiveCompare($1.displayLabel) == .orderedAscending
        }
        hasLegacyConnection = status.legacy && connectedAccounts.isEmpty
    }

    private func disconnect(accountID: String) {
        guard !isWorking else { return }
        isWorking = true
        statusMessage = nil
        connectedAccounts.removeAll { $0.id == accountID }
        Task { @MainActor in
            await GoogleDriveService.shared.signOut(accountID: accountID)
            await refreshConnectionState()
            isWorking = false
        }
    }

    private func disconnectLegacyConnection() {
        guard !isWorking else { return }
        isWorking = true
        statusMessage = nil
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) {
                GoogleDriveService.shared.signOut()
            }.value
            await refreshConnectionState()
            isWorking = false
        }
    }
}

/// Settings → Plugins → Calendar: turn the Mac's Calendar app on, choose which
/// of its calendars are the day, and which one new events go to. The system
/// asks for access the first time; the choices are this Mac's, like the grant.
/// An Exchange account is signed in by macOS, so Add Exchange Account… opens
/// Internet Accounts and the list follows Calendar when the learner returns.
/// The day itself is read by `DayModel` and written by the assistant's
/// calendar tools.
private struct AppleCalendarConnectionSettingsView: View {
    @State private var isConnected = false
    @State private var isBlockedBySystem = false
    @State private var isConnecting = false
    @State private var statusMessage: String?
    @State private var calendars: [AppleCalendarListEntry] = []
    @State private var isLoadingCalendars = false
    /// The learner's selection, nil while every calendar but Birthdays is
    /// shown. Mirrors `AppleCalendarService.selectedIDs`.
    @State private var selectedIDs: Set<String>?
    /// Mirrors `AppleCalendarService.knownAccountIDs`: calendars of any other
    /// account are ticked until the learner unticks them.
    @State private var knownAccountIDs: [String]?
    /// The calendar new events go to: the learner's choice, or nil for the
    /// Calendar app's own default (`newEventsDefault`).
    @State private var newEventsCalendarID: String?
    /// The calendar the Calendar app itself puts new events on.
    @State private var newEventsDefault: AppleCalendarListEntry?

    var body: some View {
        PluginSettingsCard(
            title: "Calendar",
            subtitle: "The Mac's calendars you choose — from iCloud, Google, Exchange or any account Calendar holds — are your day: the bottom-left chip shows them, and a chat plans the day by adding events to the calendar you pick below.",
            icon: {
                Image("AppleCalendarIcon")
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: 18, height: 18)
            },
            status: isConnected ? .connected : (isBlockedBySystem ? .needsAttention : .notConnected)
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Access is granted to this Mac by macOS and never leaves it. ForeverLM writes only the events you or the assistant add, and never changes a meeting with other people on it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if isBlockedBySystem {
                        Button("Open Privacy & Security…") {
                            AppleCalendarService.openPrivacySettings()
                        }
                        .accessibilityIdentifier("settings.appleCalendar.privacy")
                    }
                    Button("Add Exchange Account…") {
                        AppleCalendarService.openInternetAccountsSettings()
                    }
                    .help("Opens System Settings › Internet Accounts. Choose Add Account… › Microsoft Exchange and sign in; its calendars appear here and in your day.")
                    .accessibilityIdentifier("settings.appleCalendar.addAccount")
                    Spacer()
                    if isConnected {
                        Button("Turn Off", role: .destructive) {
                            isConnected = false
                            calendars = []
                            selectedIDs = nil
                            knownAccountIDs = nil
                            statusMessage = nil
                            Task.detached(priority: .userInitiated) {
                                AppleCalendarService.shared.disconnect()
                            }
                        }
                        .accessibilityIdentifier("settings.appleCalendar.disconnect")
                    } else {
                        Button {
                            connect()
                        } label: {
                            if isConnecting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Turn On", systemImage: "calendar.badge.checkmark")
                            }
                        }
                        .disabled(isConnecting)
                        .accessibilityIdentifier("settings.appleCalendar.connect")
                    }
                }

                if isConnected {
                    Divider()
                    if isLoadingCalendars && calendars.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                    } else if calendars.isEmpty {
                        Text("The Calendar app holds no calendars on this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        newEventsPicker
                        Divider()
                        Text("Calendars in your day")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(calendars) { calendar in
                            let takesNewEvents = calendar.id == newEventsTargetID
                            Toggle(isOn: Binding(
                                get: { isImported(calendar) },
                                set: { setImported($0, calendar) }
                            )) {
                                HStack(spacing: 6) {
                                    Text(calendar.title)
                                        .lineLimit(1)
                                    if !calendar.account.isEmpty {
                                        Text(calendar.account)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    if takesNewEvents {
                                        Text("· new events")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                            // What a chat plans lands here, so it is always
                            // in the day (`AppleCalendarService.shown`).
                            .disabled(takesNewEvents)
                            .help(takesNewEvents ? "New events go to this calendar, so it is always in your day." : "")
                            .accessibilityIdentifier("settings.appleCalendar.calendar.\(calendar.id)")
                        }
                    }
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(isBlockedBySystem ? .red : .secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .pluginConnectionChanged)) { _ in
            refresh()
        }
        // Back from System Settings: a grant given or an account signed in.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        // An account's calendars arrive in Calendar while it syncs.
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            if isConnected { loadCalendars() }
        }
    }

    private func refresh() {
        Task {
            let state = await Task.detached(priority: .userInitiated) {
                (
                    connected: AppleCalendarService.shared.isConnected,
                    blocked: AppleCalendarService.shared.isBlockedBySystem,
                    selected: AppleCalendarService.shared.selectedIDs,
                    known: AppleCalendarService.shared.knownAccountIDs,
                    newEvents: AppleCalendarService.shared.newEventsCalendarID
                )
            }.value
            isConnected = state.connected
            isBlockedBySystem = state.blocked
            selectedIDs = state.selected.map(Set.init)
            knownAccountIDs = state.known
            newEventsCalendarID = state.newEvents
            if state.connected { loadCalendars() }
        }
    }

    /// Where the assistant's new events land: the Calendar app's own default,
    /// or one of the calendars that take events.
    @ViewBuilder
    private var newEventsPicker: some View {
        let writable = calendars.filter(\.allowsModifications)
        HStack(spacing: 8) {
            Text("New events go to")
                .font(.callout.weight(.medium))
            Spacer(minLength: 8)
            Picker("New events go to", selection: Binding(
                get: { newEventsCalendarID ?? "" },
                set: { setNewEventsCalendar($0.isEmpty ? nil : $0) }
            )) {
                Text(newEventsDefault.map { "Calendar's default (\($0.title))" } ?? "Calendar's default").tag("")
                ForEach(writable) { calendar in
                    Text(calendar.account.isEmpty ? calendar.title : "\(calendar.title) · \(calendar.account)").tag(calendar.id)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("settings.appleCalendar.newEvents")
        }
    }

    private func setNewEventsCalendar(_ id: String?) {
        newEventsCalendarID = id
        Task.detached(priority: .userInitiated) {
            AppleCalendarService.shared.setNewEventsCalendarID(id)
        }
    }

    /// The calendar new events land on, the way `AppleCalendarService`
    /// resolves it: the learner's choice while it still takes events, else
    /// the Calendar app's own default.
    private var newEventsTargetID: String? {
        if let newEventsCalendarID,
           calendars.contains(where: { $0.id == newEventsCalendarID && $0.allowsModifications }) {
            return newEventsCalendarID
        }
        return newEventsDefault?.id
    }

    /// Whether `calendar` is in the day: chosen by the learner, from an
    /// account signed in since, or, before any choice, anything but Birthdays;
    /// and the calendar new events go to, always.
    private func isImported(_ calendar: AppleCalendarListEntry) -> Bool {
        !AppleCalendarService.shown(
            from: [calendar],
            selectedIDs: selectedIDs.map(Array.init),
            knownAccountIDs: knownAccountIDs,
            newEventsCalendarID: newEventsTargetID
        ).isEmpty
    }

    /// The first flip turns what is shown into the learner's own list, and
    /// every account listed now into one the choice covers. The calendar new
    /// events go to joins the list only if the learner's choice already took
    /// it in, so picking another one later does not leave it ticked.
    private func setImported(_ imported: Bool, _ calendar: AppleCalendarListEntry) {
        let selection = selectedIDs.map(Array.init)
        var chosen = Set(calendars.filter {
            AppleCalendarService.isChosen($0, selectedIDs: selection, knownAccountIDs: knownAccountIDs)
        }.map(\.id))
        if imported { chosen.insert(calendar.id) } else { chosen.remove(calendar.id) }
        selectedIDs = chosen
        knownAccountIDs = AppleCalendarService.accountIDs(of: calendars)
        let listed = calendars
        let ids = listed.map(\.id).filter { chosen.contains($0) }
        Task.detached(priority: .userInitiated) {
            // Posts the change the chip and the day model read again on.
            AppleCalendarService.shared.setSelectedIDs(ids, among: listed)
        }
    }

    private func loadCalendars() {
        guard !isLoadingCalendars else { return }
        isLoadingCalendars = true
        Task {
            defer { isLoadingCalendars = false }
            do {
                calendars = try await AppleCalendarService.shared.calendars()
                // Reading them records the accounts an older choice covers.
                knownAccountIDs = AppleCalendarService.shared.knownAccountIDs
                newEventsDefault = try await AppleCalendarService.shared.calendarAppNewEventsCalendar()
                statusMessage = nil
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func connect() {
        guard !isConnecting else { return }
        isConnecting = true
        statusMessage = nil
        Task {
            do {
                try await AppleCalendarService.shared.connect()
                isConnected = AppleCalendarService.shared.isConnected
                isBlockedBySystem = false
                loadCalendars()
            } catch {
                isBlockedBySystem = AppleCalendarService.shared.isBlockedBySystem
                statusMessage = error.localizedDescription
            }
            isConnecting = false
        }
    }
}

private struct YouTubeConnectionSettingsView: View {
    @Environment(StudioViewModel.self) private var vm
    // Placeholders; `.onAppear` fills them in off-main — both are synced
    // Keychain reads, and `@State` inits re-run on every re-init.
    @State private var isSignedIn = false
    @State private var isConnecting = false
    @State private var statusMessage: String?
    @State private var autoImportEnabled = false
    /// What the stores currently say, so the `.onChange` below can tell the
    /// user flipping the toggle apart from the off-main refresh seeding it.
    @State private var persistedAutoImportEnabled = false
    @State private var setupDialog: YouTubeSetupDialog?
    @State private var isConfiguringSource = false
    @State private var pendingLikedImportPolicy: YouTubeLikedImportPolicy?
    @State private var channelInput = ""
    @State private var isFollowingChannel = false
    @SyncedStorage(StudioViewModel.youtubeLikedTranscriptFormattingKey)
    private var automaticallyFormatLikedVideoTranscripts = false

    var body: some View {
        PluginSettingsCard(
            title: "YouTube",
            subtitle: subtitleText,
            icon: {
                Image("YouTubeIcon")
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: 22, height: 16)
            },
            status: isSignedIn ? .connected : (needsReconnect ? .needsAttention : .notConnected)
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose what enters your library: your Liked videos or a YouTube playlist named ForeverLM, plus any channels you follow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Scope: https://www.googleapis.com/auth/youtube.readonly")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    Spacer()
                    if isSignedIn {
                        Button("Disconnect", role: .destructive) {
                            // UI first; the synced-Keychain deletes run off the
                            // click (see the Drive button above).
                            isSignedIn = false
                            statusMessage = nil
                            Task.detached(priority: .userInitiated) {
                                YouTubeService.shared.signOut()
                            }
                        }
                    } else {
                        Button {
                            connect()
                        } label: {
                            if isConnecting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Connect", systemImage: "person.crop.circle.badge.checkmark")
                            }
                        }
                        .disabled(!canConnect || isConnecting)
                    }
                }

                if isSignedIn {
                    Divider()
                    Toggle("Automatically import new videos", isOn: $autoImportEnabled)
                        .onChange(of: autoImportEnabled) { _, enabled in
                            // Seeding from `.onAppear` must not re-persist or
                            // kick an import; only a real user flip does.
                            guard enabled != persistedAutoImportEnabled else { return }
                            persistedAutoImportEnabled = enabled
                            StudioViewModel.setYouTubeAutoImportEnabled(enabled)
                            if enabled { Task { await vm.runYouTubeAutoImportOnce() } }
                        }
                    Text("ForeverLM keeps the selected source up to date in the background. Paid AI work follows your consent settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()
                    importSourceSection
                    if vm.youtubeImportSource == .likedVideos {
                        Divider()
                        likedImportPolicySection
                    }
                    Divider()
                    followedChannelsSection
                    if !vm.hiddenYouTubeChannelNames.isEmpty {
                        Divider()
                        hiddenChannelsSection
                    }
                }

                if !canConnect {
                    Text("This build of ForeverLM has no YouTube OAuth client configured, so YouTube cannot be connected.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Link("Setup guide", destination: URL(string: "https://docs.foreverlm.com/external-plugins#youtube")!)
                    .font(.caption)
            }
        }
        .onAppear {
            // A failed token refresh during a background import signs the
            // service out; re-read so the card doesn't show a stale
            // "Connected" state. Off-main: both are synced Keychain reads.
            Task {
                let status = await Task.detached(priority: .userInitiated) {
                    (
                        signedIn: YouTubeService.shared.isSignedIn,
                        autoImport: StudioViewModel.isYouTubeAutoImportEnabled
                    )
                }.value
                isSignedIn = status.signedIn
                persistedAutoImportEnabled = status.autoImport
                autoImportEnabled = status.autoImport
            }
        }
        .confirmationDialog(
            "Import videos from…",
            isPresented: dialogBinding(.importSource),
            titleVisibility: .visible
        ) {
            Button("Liked Videos") {
                showLikedHistoryChoiceAfterCurrentDialog()
            }
            Button("ForeverLM Playlist") {
                configureForeverLMPlaylist()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The playlist option uses a playlist in your YouTube account named ForeverLM.")
        }
        .confirmationDialog(
            "Import existing liked videos?",
            isPresented: dialogBinding(.likedHistory),
            titleVisibility: .visible
        ) {
            Button("Import Existing and Future Likes") {
                chooseLikedImportPolicy(.importExisting)
            }
            Button("Only Import Future Likes") {
                chooseLikedImportPolicy(.futureOnly)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Nothing is imported until you choose. You can change this later.")
        }
        .confirmationDialog(
            "Format liked-video transcripts with AI?",
            isPresented: dialogBinding(.likedFormatting),
            titleVisibility: .visible
        ) {
            Button("Keep Raw Transcripts") {
                finishLikedVideosSetup(automaticallyFormatTranscripts: false)
            }
            Button("Format Automatically") {
                finishLikedVideosSetup(automaticallyFormatTranscripts: true)
            }
            Button("Cancel", role: .cancel) {
                pendingLikedImportPolicy = nil
            }
        } message: {
            Text("Automatic formatting can spend a lot on AI when importing a large history. Raw transcripts remain readable and searchable.")
        }
    }

    /// True only once a background sync has actually failed on a lost
    /// connection, so a user who has simply never connected YouTube still sees
    /// a neutral "Not connected" rather than a warning.
    private var needsReconnect: Bool {
        !isSignedIn && vm.youtubePluginNeedsReconnect
    }

    private var subtitleText: String {
        if isSignedIn { return "Connected for YouTube import" }
        if needsReconnect { return "Disconnected — YouTube import has stopped" }
        return configurationText
    }

    // MARK: - Import source

    @ViewBuilder
    private var importSourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Import from")
                .font(.subheadline.weight(.semibold))
            ForEach(YouTubeImportSource.allCases) { source in
                HStack(spacing: 8) {
                    Image(systemName: source.iconName)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(source.displayName)
                        .font(.callout)
                    Spacer()
                    if vm.youtubeImportSource == source {
                        Label("Selected", systemImage: "checkmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if isConfiguringSource {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Use") {
                            if source == .likedVideos {
                                setupDialog = .likedHistory
                            } else {
                                configureForeverLMPlaylist()
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    /// Channels the plugin follows, each a group in the YouTube tab, and the
    /// field that adds one. A follow imports the channel's newest uploads and
    /// then every new one; stopping keeps the videos already imported.
    private var followedChannelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Followed channels")
                .font(.subheadline.weight(.semibold))
            ForEach(vm.followedYouTubeChannelGroupIDs, id: \.self) { groupID in
                HStack(spacing: 8) {
                    Image(systemName: "play.rectangle")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(vm.videoPlaylistDisplayName(groupID))
                        .font(.callout)
                        .lineLimit(1)
                    Spacer()
                    Button("Stop Following") {
                        Task { await vm.unfollowYouTubePluginPlaylist(groupID) }
                    }
                    .controlSize(.small)
                }
            }
            HStack(spacing: 8) {
                TextField("Channel address or @handle", text: $channelInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(followChannel)
                    .disabled(isFollowingChannel)
                if isFollowingChannel {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Follow") {
                        followChannel()
                    }
                    .controlSize(.small)
                    .disabled(channelInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Text("Imports the newest \(StudioViewModel.youtubeChannelFollowImportCount) videos, then each new upload.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func followChannel() {
        let input = channelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isFollowingChannel else { return }
        isFollowingChannel = true
        statusMessage = nil
        Task {
            let groupID = await vm.followYouTubeChannel(input)
            if groupID == nil {
                statusMessage = vm.errorMessage ?? "Couldn’t follow that channel."
            } else {
                channelInput = ""
            }
            autoImportEnabled = StudioViewModel.isYouTubeAutoImportEnabled
            isFollowingChannel = false
        }
    }

    private var likedImportPolicySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Liked-video history")
                        .font(.callout)
                    Text(vm.youtubeLikedImportPolicy.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isConfiguringSource {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Change…") {
                        setupDialog = .likedHistory
                    }
                    .controlSize(.small)
                }
            }
            Toggle(
                "Format new transcripts automatically",
                isOn: $automaticallyFormatLikedVideoTranscripts
            )
            Text("Billed to your OpenRouter key. Raw transcripts are always imported.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var hiddenChannelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hidden channels")
                .font(.subheadline.weight(.semibold))
            ForEach(vm.hiddenYouTubeChannelNames, id: \.self) { channel in
                HStack {
                    Image(systemName: "eye.slash")
                        .foregroundStyle(.secondary)
                    Text(channel)
                        .lineLimit(1)
                    Spacer()
                    Button("Unhide") {
                        Task { await vm.setYouTubeChannelHidden(channel, hidden: false) }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Helpers

    private var configurationText: String {
        canConnect ? "Ready to connect" : "Unavailable in this build"
    }

    /// Release builds ship ForeverLM's own YouTube OAuth client, so this is
    /// always true for users. It can only be false in a Debug build whose .env
    /// carries no YouTube client and which has no legacy Drive credentials.
    private var canConnect: Bool {
        YouTubeService.shared.canConnect
    }

    private func connect() {
        guard canConnect else {
            statusMessage = "This build has no YouTube OAuth client configured."
            return
        }
        isConnecting = true
        statusMessage = nil
        Task {
            do {
                try await YouTubeService.shared.authenticate()
                isSignedIn = YouTubeService.shared.isSignedIn
                statusMessage = nil
                if isSignedIn && vm.youtubeImportSource == nil {
                    setupDialog = .importSource
                }
            } catch {
                statusMessage = error.localizedDescription
            }
            isConnecting = false
        }
    }

    private func configureLikedVideos(
        _ policy: YouTubeLikedImportPolicy,
        automaticallyFormatTranscripts: Bool
    ) {
        isConfiguringSource = true
        statusMessage = nil
        Task {
            let groupID = await vm.configureYouTubeLikedVideos(
                policy,
                automaticallyFormatTranscripts: automaticallyFormatTranscripts
            )
            if groupID == nil {
                statusMessage = vm.errorMessage ?? "Could not configure Liked videos."
            }
            autoImportEnabled = StudioViewModel.isYouTubeAutoImportEnabled
            isConfiguringSource = false
        }
    }

    private func chooseLikedImportPolicy(_ policy: YouTubeLikedImportPolicy) {
        pendingLikedImportPolicy = policy
        setupDialog = nil
        Task { @MainActor in
            await Task.yield()
            setupDialog = .likedFormatting
        }
    }

    private func finishLikedVideosSetup(automaticallyFormatTranscripts: Bool) {
        guard let policy = pendingLikedImportPolicy else { return }
        pendingLikedImportPolicy = nil
        automaticallyFormatLikedVideoTranscripts = automaticallyFormatTranscripts
        configureLikedVideos(
            policy,
            automaticallyFormatTranscripts: automaticallyFormatTranscripts
        )
    }

    private func showLikedHistoryChoiceAfterCurrentDialog() {
        setupDialog = nil
        Task { @MainActor in
            await Task.yield()
            setupDialog = .likedHistory
        }
    }

    private func configureForeverLMPlaylist() {
        isConfiguringSource = true
        statusMessage = nil
        Task {
            let groupID = await vm.followYouTubeForeverLMPlaylist()
            if groupID == nil {
                statusMessage = vm.errorMessage ?? "Could not find your ForeverLM playlist."
            }
            autoImportEnabled = StudioViewModel.isYouTubeAutoImportEnabled
            isConfiguringSource = false
        }
    }

    private func dialogBinding(_ dialog: YouTubeSetupDialog) -> Binding<Bool> {
        Binding(
            get: { setupDialog == dialog },
            set: { presented in
                if !presented, setupDialog == dialog {
                    setupDialog = nil
                }
            }
        )
    }
}

private enum YouTubeSetupDialog: Equatable {
    case importSource
    case likedHistory
    case likedFormatting
}

private enum PluginStatus: Equatable {
    case connected
    case needsAttention
    case notConnected

    var label: String {
        switch self {
        case .connected: return "Connected"
        case .needsAttention: return "Reconnect needed"
        case .notConnected: return "Not connected"
        }
    }

    var color: Color {
        switch self {
        case .connected: return .green
        case .needsAttention: return .orange
        case .notConnected: return .secondary
        }
    }

    var iconName: String {
        switch self {
        case .connected: return "checkmark.circle.fill"
        case .needsAttention: return "exclamationmark.triangle.fill"
        case .notConnected: return "circle"
        }
    }
}

/// The line under a plugin's name in Settings → Plugins once it is
/// connected: what the connection may read, named. Each returns nil when the
/// connection has nothing more specific to say than the plugin's own
/// description, which the row then keeps. Internal so the unit tests can pin
/// the sentences; Web Studio's `pluginScopeDescriptions` says the same.
enum PluginScopeCopy {
    /// "Imports bookmarks and saved posts from @handle."
    static func x(username: String?) -> String? {
        guard let username = trimmed(username) else { return nil }
        return "Imports bookmarks and saved posts from @\(username)."
    }

    /// "Imports your Liked videos and follows 3 channels."
    static func youtube(source: String?, followedChannels: Int) -> String? {
        var clauses: [String] = []
        if let source = trimmed(source) { clauses.append("imports your \(source)") }
        if followedChannels > 0 {
            clauses.append("follows \(followedChannels) \(followedChannels == 1 ? "channel" : "channels")")
        }
        guard let first = clauses.first else { return nil }
        let sentence = ([first.prefix(1).uppercased() + String(first.dropFirst())] + clauses.dropFirst()).joined(separator: " and ")
        return sentence + "."
    }

    /// "Reads the folders Acme Journal Club and Team weekly."
    static func googleDrive(folders: [String]) -> String? {
        let names = folders.compactMap(trimmed)
        guard !names.isEmpty else { return nil }
        let noun = names.count == 1 ? "the folder" : "the folders"
        return "Reads \(noun) \(ListFormatter.localizedString(byJoining: names))."
    }

    /// The meeting groups that follow a Drive folder, by name, in name order.
    /// A hidden or merged-away group no longer reads its folder.
    static func googleDriveFolderNames(in metadata: [String: MeetingMetadata]) -> [String] {
        metadata
            .filter { key, value in
                !value.isHidden
                    && trimmed(value.mergedIntoGroupID) == nil
                    && trimmed(value.driveFolderURL) != nil
                    && (trimmed(value.title) ?? key).isEmpty == false
            }
            .map { key, value in trimmed(value.title) ?? key }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// "Reads 4 channels in Acme Lab and 2 channels in Bench Lab." A gateway
    /// that does not count channels gives "Reads channels in Acme Lab and
    /// Bench Lab."
    static func slack(_ workspaces: [MCPDataStore.SlackWorkspace]) -> String? {
        guard !workspaces.isEmpty else { return nil }
        if workspaces.allSatisfy({ $0.channelCount != nil }) {
            let parts = workspaces.map { workspace -> String in
                let count = workspace.channelCount ?? 0
                switch count {
                case 0: return "no channels yet in \(workspace.name)"
                case 1: return "1 channel in \(workspace.name)"
                default: return "\(count) channels in \(workspace.name)"
                }
            }
            return "Reads \(ListFormatter.localizedString(byJoining: parts))."
        }
        return "Reads channels in \(ListFormatter.localizedString(byJoining: workspaces.map(\.name)))."
    }

    /// "Reads the Bench Lab workspace as Alan Young. Read-only."
    static func linear(workspace: String?, user: String?) -> String? {
        switch (trimmed(workspace), trimmed(user)) {
        case (let workspace?, let user?): return "Reads the \(workspace) workspace as \(user). Read-only."
        case (let workspace?, nil): return "Reads the \(workspace) workspace. Read-only."
        case (nil, let user?): return "Reads Linear as \(user). Read-only."
        case (nil, nil): return nil
        }
    }

    /// "Reads the Bench Lab workspace as Alan Young. Read-only."
    static func notion(workspace: String?, user: String?) -> String? {
        switch (trimmed(workspace), trimmed(user)) {
        case (let workspace?, let user?): return "Reads the \(workspace) workspace as \(user). Read-only."
        case (let workspace?, nil): return "Reads the \(workspace) workspace. Read-only."
        case (nil, let user?): return "Reads Notion as \(user). Read-only."
        case (nil, nil): return nil
        }
    }

    /// "Reads ForeverLM-HQ and alanyoung as @alanyoung. Read-only."
    static func github(login: String?, installations: [String]) -> String? {
        let names = installations.compactMap(trimmed)
        let named = names.isEmpty ? nil : ListFormatter.localizedString(byJoining: names)
        switch (named, trimmed(login)) {
        case (let named?, let login?): return "Reads \(named) as @\(login). Read-only."
        case (let named?, nil): return "Reads \(named). Read-only."
        case (nil, let login?): return "Reads GitHub as @\(login). Read-only."
        case (nil, nil): return nil
        }
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Which connected Google account reads which meeting folder. A folder URL
/// carries the account it was chosen through as a query tag; one without a tag
/// predates multi-account and is read through the default account. A folder
/// tagged with an account that is no longer connected is neither — it is
/// listed apart, so the learner sees why it stopped updating.
struct GoogleDriveFolderAttribution: Equatable {
    struct Folder: Equatable, Identifiable {
        /// The meeting group's id, the key in `meetingMetadata`.
        let groupID: String
        /// The group's title, or its id when it has none.
        let title: String
        /// The Drive folder id parsed off the URL, when the URL has one.
        let folderID: String?
        /// The account tag on the URL, when there is one.
        let accountID: String?

        var id: String { groupID }

        /// The folder on Drive, without the account tag ForeverLM added.
        var url: URL? {
            folderID.flatMap { URL(string: "https://drive.google.com/drive/folders/\($0)") }
        }
    }

    private(set) var byAccount: [String: [Folder]] = [:]
    /// Folders tagged with an account that is not connected any more.
    private(set) var unattributed: [Folder] = []

    init(metadata: [String: MeetingMetadata], accountIDs: [String], defaultAccountID: String?) {
        let connected = Set(accountIDs)
        // An untagged folder reads through the default account when it is
        // connected, else through the only account, else through none.
        let fallback: String? = {
            if let defaultAccountID, connected.contains(defaultAccountID) { return defaultAccountID }
            return accountIDs.count == 1 ? accountIDs[0] : nil
        }()
        let folders = metadata
            .compactMap { key, value -> Folder? in
                guard !value.isHidden,
                      Self.trimmed(value.mergedIntoGroupID) == nil,
                      let url = Self.trimmed(value.driveFolderURL) else { return nil }
                let title = Self.trimmed(value.title) ?? key
                guard !title.isEmpty else { return nil }
                return Folder(
                    groupID: key,
                    title: title,
                    folderID: try? StudioViewModel.googleDriveFolderID(from: url),
                    accountID: GoogleDriveService.accountID(from: url)
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        for folder in folders {
            let owner = folder.accountID ?? fallback
            if let owner, connected.contains(owner) {
                byAccount[owner, default: []].append(folder)
            } else {
                unattributed.append(folder)
            }
        }
    }

    func folders(for accountID: String) -> [Folder] { byAccount[accountID] ?? [] }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct PluginSettingsCard<Icon: View, Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var icon: () -> Icon
    let status: PluginStatus
    @ViewBuilder var content: () -> Content

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.primary.opacity(0.055))

                        icon()
                            .frame(width: 20, height: 20)
                    }
                    .frame(width: 34, height: 34)

                    VStack(alignment: .leading, spacing: 3) {
                        if !title.isEmpty {
                            Text(title)
                                .font(.headline)
                        }
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 12)

                    Label(status.label, systemImage: status.iconName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(status.color)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(status.color.opacity(status == .notConnected ? 0.07 : 0.11))
                        )
                }

                Divider()

                content()
            }
        }
    }
}

private struct PluginErrorNotice: View {
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.medium))

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.red.opacity(0.12), lineWidth: 1)
        }
    }
}

/// The small "i" at the end of a Settings row. The row says one line; what the
/// learner may want to read in full opens from here, in a popover that is
/// narrow enough to read, never as a paragraph on the page.
struct SettingsMoreInfoButton<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var isShowing = false

    var body: some View {
        Button {
            isShowing.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("More info")
        .accessibilityLabel("More info")
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 300, alignment: .leading)
            .padding(14)
        }
    }
}

struct SettingsButtonGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        // The VStack matters: without a container, the background/overlay would apply to each
        // row individually instead of wrapping the whole group in one card.
        VStack(spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

struct SettingsButtonDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 54)
    }
}

/// The app menu's Screen Record Mode item: the one place outside Settings that
/// says the mode is on, so the recorded window itself carries no badge. Shown
/// only once the proxy has confirmed this account as an admin.
struct ScreenRecordModeMenuItem: View {
    @AppStorage(ScreenRecordMode.confirmedAdminKey) private var isAdmin = false
    @AppStorage(ScreenRecordMode.enabledKey) private var isOn = false

    var body: some View {
        if isAdmin {
            Toggle("Screen Record Mode", isOn: Binding(
                get: { isOn },
                set: { ScreenRecordMode.setEnabled($0) }
            ))
        }
    }
}
