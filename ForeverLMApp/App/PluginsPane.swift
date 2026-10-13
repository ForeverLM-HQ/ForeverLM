import SwiftUI
import AppKit

// MARK: - The Plugins place

/// Plugins, a place of its own as in Codex (product owner, 2026-10-13: "plugins
/// we already have; it just lives in settings right now", then "so you can
/// take plugins out of settings actually and put it similarly to codex";
/// docs/codex-shell-plan.md, Track 2). The icon strip's Plugins row opens it:
/// a directory of every plugin with its state — the built-in ones, then the
/// learner's own — and a click on one shows that plugin's page here, with
/// ‹ Plugins back to the list. A place like the Library: a pane with its ×,
/// Open Beside, Open in Other Window and a drag; it leaves a notebook the way
/// the Library does. Settings has no Plugins since.
struct PluginsPane: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState

    var body: some View {
        Group {
            if let page = windowState.pluginPage {
                PluginPageContent(page: page)
                    .id(page)
                    .environment(\.pluginPageBack, { vm.openPluginsPlace(nil, in: windowState) })
            } else {
                PluginDirectoryView { page in vm.openPluginsPlace(page, in: windowState) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .studioCenterTabCloseChrome(for: .plugins)
        .onExitCommand {
            guard windowState.pluginPage != nil else { return }
            vm.openPluginsPlace(nil, in: windowState)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Plugins")
        .accessibilityIdentifier("plugins.pane")
    }
}

/// Ways into the Plugins place from what is not a window's own view: a
/// banner, a chat's prompt, Settings, a menu, MCP. The key window opens it,
/// closing its Settings first when Settings is open.
enum PluginsPlace {
    @MainActor
    static func requestOpen(_ page: PluginPage? = nil) {
        NotificationCenter.default.post(name: .requestOpenPluginsPlace, object: page)
    }
}

extension Notification.Name {
    /// The Plugins place in the key window, at the `PluginPage` the object
    /// names, or at its list when there is none.
    static let requestOpenPluginsPlace = Notification.Name("requestOpenPluginsPlace")
}

extension StudioViewModel {
    /// The Plugins place in `window` (the window in scope when nil), at
    /// `page` or at its list: the strip's Plugins row, a plugin's row, a
    /// reconnect banner, `open_settings` with a plugin's id. A window holding
    /// a notebook leaves it the way it does for the Library (`.plugins`
    /// routes `.leave`), and its rail row brings it back.
    func openPluginsPlace(_ page: PluginPage? = nil, in window: StudioWindowState? = nil) {
        let window = window ?? activeWindowState
        if window.pluginPage != page { window.pluginPage = page }
        activateCenterTab(.plugins, in: window)
    }
}

// MARK: - The directory

/// Every plugin and its state, in the Space's list head (`SpacePlaceHeader`):
/// the built-in plugins, then Your Plugins — the meeting providers and the
/// learner's own ingest plugins, and Build Your Own. A row shows what the
/// plugin reads once it is connected, its own description until then.
private struct PluginDirectoryView: View {
    @Environment(StudioViewModel.self) private var vm
    let open: (PluginPage) -> Void
    @State private var query = ""
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
    /// than a Keychain read. They live in `GatewayPluginState` so the page a
    /// row opens starts from the same answer instead of asking again from blank.
    private var slackConnection: MCPDataStore.SlackWorkspaceConnection? { GatewayPluginState.shared.slack }
    private var linearConnection: MCPDataStore.LinearConnection? { GatewayPluginState.shared.linear }
    private var githubConnection: MCPDataStore.GitHubConnection? { GatewayPluginState.shared.github }
    private var notionConnection: MCPDataStore.NotionConnection? { GatewayPluginState.shared.notion }

    /// One row of the directory.
    private struct Row: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        /// nil draws no chip: a gateway that has not answered yet, or Build
        /// Your Own, which is an offer rather than a connection.
        let status: PluginStatus?
        let logo: Logo
        let page: PluginPage
    }

    /// What a row's tile draws.
    private enum Logo {
        case x
        /// An asset of the app's own; a template one takes the foreground
        /// colour (GitHub's and Notion's marks are black on light, white on dark).
        case asset(String, width: CGFloat, height: CGFloat, template: Bool)
        case meetingProvider(MeetingProvider)
        case sourceTab(StudioSidebarTab)
        case userPlugin(MCPOAuthProvider.UserPluginSummary)
        case buildYourOwn
    }

    private var builtInRows: [Row] {
        [
            Row(
                id: PluginPage.x.rawValue, title: PluginPage.x.title, subtitle: xSubtitle,
                status: vm.isXOAuthSignedIn ? (vm.xPluginNeedsReauth ? .needsAttention : .connected) : .notConnected,
                logo: .x, page: .x
            ),
            Row(
                id: PluginPage.youtube.rawValue, title: PluginPage.youtube.title, subtitle: youtubeSubtitle,
                status: isYouTubeSignedIn ? .connected : .notConnected,
                logo: .asset("YouTubeIcon", width: 25, height: 18, template: false), page: .youtube
            ),
            Row(
                id: PluginPage.googleDrive.rawValue, title: PluginPage.googleDrive.title, subtitle: googleDriveSubtitle,
                status: isGoogleDriveSignedIn ? (isGoogleDriveFolderAccessReady ? .connected : .needsAttention) : .notConnected,
                logo: .asset("GoogleDriveIcon", width: 22, height: 18, template: false), page: .googleDrive
            ),
            Row(
                id: PluginPage.appleCalendar.rawValue, title: PluginPage.appleCalendar.title, subtitle: appleCalendarSubtitle,
                status: isAppleCalendarConnected ? .connected : .notConnected,
                logo: .asset("AppleCalendarIcon", width: 20, height: 20, template: false), page: .appleCalendar
            ),
            Row(
                id: PluginPage.slack.rawValue, title: PluginPage.slack.title, subtitle: slackSubtitle,
                status: slackConnection.map { $0.isConnected ? .connected : .notConnected },
                logo: .asset("SlackIcon", width: 22, height: 22, template: false), page: .slack
            ),
            Row(
                id: PluginPage.linear.rawValue, title: PluginPage.linear.title, subtitle: linearSubtitle,
                status: linearConnection.map { $0.isConnected ? .connected : .notConnected },
                logo: .asset("LinearIcon", width: 20, height: 20, template: false), page: .linear
            ),
            Row(
                id: PluginPage.github.rawValue, title: PluginPage.github.title, subtitle: githubSubtitle,
                status: githubConnection.map { $0.isConnected ? .connected : .notConnected },
                logo: .asset("GitHubIcon", width: 22, height: 22, template: true), page: .github
            ),
            Row(
                id: PluginPage.notion.rawValue, title: PluginPage.notion.title, subtitle: notionSubtitle,
                status: notionConnection.map { $0.isConnected ? .connected : .notConnected },
                logo: .asset("NotionIcon", width: 20, height: 20, template: true), page: .notion
            ),
        ]
    }

    /// Your Plugins: each a row that opens Build Your Own, where the
    /// learner's plugins are listed with what they added and their switches.
    private var yourPluginRows: [Row] {
        var rows: [Row] = meetingPluginProviders.map { provider in
            let plugin = registeredPlugin(for: provider)
            return Row(
                id: "provider.\(provider.rawValue)",
                title: provider.displayName,
                subtitle: plugin.map { userPluginSubtitle(for: $0) } ?? providerWithoutPluginSubtitle(provider),
                status: plugin.map(pluginStatus) ?? .notConnected,
                logo: .meetingProvider(provider),
                page: .yourPlugins
            )
        }
        rows += customPluginTabs.map { tab in
            let plugin = registeredPlugin(for: tab)
            return Row(
                id: "tab.\(tab.rawValue)",
                title: tab.rawValue,
                subtitle: plugin.map { userPluginSubtitle(for: $0) } ?? customPluginSubtitle(for: tab),
                status: plugin.map(pluginStatus) ?? .notConnected,
                logo: .sourceTab(tab),
                page: .yourPlugins
            )
        }
        rows += unrepresentedUserPlugins.map { plugin in
            Row(
                id: "plugin.\(plugin.id)",
                title: plugin.name,
                subtitle: userPluginSubtitle(for: plugin),
                status: pluginStatus(plugin),
                logo: .userPlugin(plugin),
                page: .yourPlugins
            )
        }
        rows.append(Row(
            id: PluginPage.yourPlugins.rawValue,
            title: PluginPage.yourPlugins.title,
            subtitle: PluginPage.yourPlugins.about,
            status: nil,
            logo: .buildYourOwn,
            page: .yourPlugins
        ))
        return rows
    }

    /// The rows the search keeps: a name or a line holding its words.
    private func searched(_ rows: [Row]) -> [Row] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return rows }
        return rows.filter {
            $0.title.localizedCaseInsensitiveContains(words) || $0.subtitle.localizedCaseInsensitiveContains(words)
        }
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
        let builtIn = searched(builtInRows)
        let yours = searched(yourPluginRows)
        ScrollView {
            VStack(alignment: .leading, spacing: StudioDesign.Spacing.xLarge) {
                SpacePlaceHeader(searchText: $query, searchIdentifier: "plugins.search") {
                    SpacePlaceTitle(title: "Plugins")
                } actions: {
                    EmptyView()
                }
                if builtIn.isEmpty && yours.isEmpty {
                    SpaceEmptyLine(systemImage: "magnifyingglass", text: "No results for “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”")
                        .frame(maxWidth: .infinity)
                        .padding(.top, SpacePlaceMetrics.emptyTopPadding - StudioDesign.Spacing.xLarge)
                } else {
                    section("Built-In", builtIn)
                    section("Your Plugins", yours)
                }
            }
            .spacePlaceColumn()
        }
        .onAppear {
            refreshPluginStates()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pluginConnectionChanged)) { _ in
            refreshPluginStates()
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [Row]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: StudioDesign.Spacing.small) {
                Text(title)
                    .zoomedSystemFont(size: 12, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
                ForEach(rows) { row in
                    Button { open(row.page) } label: {
                        PluginPickerRow(title: row.title, subtitle: row.subtitle, status: row.status) {
                            logo(row.logo)
                        }
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight(cornerRadius: 18, inset: 0)
                    .accessibilityIdentifier("plugins.row.\(row.id)")
                }
            }
        }
    }

    @ViewBuilder
    private func logo(_ logo: Logo) -> some View {
        switch logo {
        case .x:
            XLogoShape()
                .fill(.foreground, style: FillStyle(eoFill: true))
                .frame(width: 15, height: 15)
        case .asset(let name, let width, let height, let template):
            if template {
                Image(name)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(.primary)
                    .frame(width: width, height: height)
            } else {
                Image(name)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: width, height: height)
            }
        case .meetingProvider(let provider):
            MeetingProviderMark(provider: provider, size: 20)
        case .sourceTab(let tab):
            customPluginLogo(tab)
        case .userPlugin(let plugin):
            userPluginLogo(plugin)
        case .buildYourOwn:
            userPluginFallbackIcon
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

    /// Registration logos render in the Plugins lists only — consent surfaces keep
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

/// A plugin's row in the directory: its logo, its name and one line, its
/// state, and the chevron that says it opens a page.
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
