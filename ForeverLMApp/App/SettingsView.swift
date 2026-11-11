import SwiftUI
import AppKit
import Combine

enum SettingsPane: Hashable {
    /// The data story, iCloud sync, and the learner's teams.
    case dataPrivacy
    /// The open team's own settings, scoped to the active library the way
    /// Claude's organization settings follow the selected organization. They
    /// open in a Settings of their own (`SettingsScope.team`), never beside
    /// the learner's personal panes.
    case teamGeneral
    case teamMembers
    case sources
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
    /// Unlocking MCP: the Early user deal, and switching or cancelling a
    /// subscription bought before the lock.
    case aiBilling
    /// What runs AI and what it cost: the own key, spending and limits, and
    /// the activity by task. Not a pane: it opens from the rail's OpenRouter
    /// button beside what is running now (`AIUsagePlace`), so a request for
    /// this pane goes there.
    case aiUsage
    case mcp
    case mcpPairing
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

    static var isEnabled: Bool {
        Preferences.value(Prefs.MCP.assistantIntegrationsEnabled)
    }
}

/// Billing, model and app settings — or, in the team scope, the open team's
/// settings and nothing else. Plugins are not settings: they have a place of
/// their own on the icon strip, as Codex's do (`PluginsPane`).
///
/// Sidebar + detail, like the macOS System Settings window: the left rail
/// lists every pane grouped by area and stays put, the right column shows the
/// selected pane.
struct SettingsView: View {
    private let scope: SettingsScope
    @State private var selection: SettingsPane
    @State private var searchText = ""

    init(initialPane: SettingsPane? = nil) {
        scope = SettingsScope(pane: initialPane)
        // Settings opens on the AI models (product owner, 2026-11-08: "the main
        // page that should open is an ai models page").
        _selection = State(initialValue: initialPane ?? .aiChatModels)
    }

    var body: some View {
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

    /// The selected pane. Nothing pushes onto it since the plugins' pages left
    /// for the Plugins place; the stack keeps each pane's title its own.
    private var detailColumn: some View {
        NavigationStack {
            paneView(for: selection)
        }
    }

    private func navigate(to pane: SettingsPane) {
        if pane == .aiUsage {
            AIUsagePlace.requestOpen()
            return
        }
        // A pane of the other scope is a different Settings: reopen the
        // overlay there rather than showing it in this sidebar.
        guard SettingsScope(pane: pane) == scope else {
            NotificationCenter.default.post(name: .requestOpenStudioSettings, object: pane)
            return
        }
        selection = pane
    }

    @ViewBuilder
    private func paneView(for pane: SettingsPane) -> some View {
        switch pane {
        case .dataPrivacy:
            DataPrivacySettingsDetailView()
        case .teamGeneral:
            TeamGeneralSettingsDetailView(onShowAllTeams: { navigate(to: .dataPrivacy) })
        case .teamMembers:
            TeamMembersSettingsDetailView(onShowAllTeams: { navigate(to: .dataPrivacy) })
        case .sources:
            SourcesSettingsDetailView()
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
            // `navigate(to:)` sends this to the rail's popover; no pane here.
            EmptyView()
        case .mcp:
            MCPSettingsDetailView(onOpenBilling: { navigate(to: .aiBilling) })
        case .mcpPairing:
            MCPSettingsDetailView(showsPairingCode: true, onOpenBilling: { navigate(to: .aiBilling) })
        }
    }

}

struct SettingsSearchItem: Identifiable {
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

/// Settings' search: the panes by the words a learner may type for them. The
/// command menu offers the same rows (`ShellCommands.setting`).
enum SettingsSearchCatalog {
    static func items() -> [SettingsSearchItem] {
        [
            SettingsSearchItem(
                id: "name",
                title: "Your name",
                subtitle: "Data & Privacy",
                keywords: ["name", "your name", "rename", "display name", "you", "profile"],
                destination: .dataPrivacy,
                icon: "person.crop.circle.fill",
                tint: .gray
            ),
            SettingsSearchItem(
                id: "day",
                title: "Day",
                subtitle: "Chat",
                keywords: ["day", "hours", "start", "end", "plan the day", "make me plan", "planning", "morning"],
                destination: .aiChatModels,
                icon: "sun.max.fill",
                tint: .yellow
            ),
            SettingsSearchItem(
                id: "quick-assistant",
                title: "Quick assistant",
                subtitle: "Chat",
                keywords: ["quick assistant", "shortcut", "hotkey", "keyboard", "spotlight"],
                destination: .aiChatModels,
                icon: "command",
                tint: .blue
            ),
            SettingsSearchItem(
                id: "think-first",
                title: "Think first",
                subtitle: "Chat",
                keywords: ["think first", "own line", "guess", "before the gist"],
                destination: .aiChatModels,
                icon: "lightbulb.fill",
                tint: .yellow
            ),
            SettingsSearchItem(
                id: "memory",
                title: "Memory review",
                subtitle: "Background",
                keywords: ["memory", "review", "cards", "new cards", "draft cards", "today's review", "prepare", "ready", "morning", "reminder", "notification", "daily", "minutes", "how long"],
                destination: .aiBackgroundModels,
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
                id: "mcp",
                title: "MCP",
                subtitle: "Connections",
                keywords: ["claude", "chatgpt", "codex", "gemini", "grok", "meta", "muse", "cursor", "assistant", "tunnel", "server", "status light", "dot", "account button"],
                destination: .mcp,
                icon: "link.badge.plus",
                tint: .purple
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
            row(.dataPrivacy, icon: "hand.raised.fill", title: "Data & Privacy", tint: .gray)
        }

        Group {
            groupHeader("Connections")
            row(.sources, icon: "books.vertical.fill", title: "Sources", tint: .teal)
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
            // Beta releases sit with the version they change, since General
            // went (2026-11-08); the team scope has no say in updates.
            if scope == .personal {
                SettingsBetaReleasesToggle()
            }
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
/// storage notices when iCloud is full or signed out. The per-change list of
/// pending and refused records is a diagnostic and is not shown.
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

/// Data & Privacy › iCloud, above the sync card: a library whose move to the new iCloud store failed
/// (docs/cloudkit-schema-design.md §13.3 step 3). Nothing shows otherwise.
private struct LibraryMoveSettingsCard: View {
    @State private var notice = ActivationNotice.shared

    var body: some View {
        switch notice.phase {
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
            ("Other files", usage.otherBytes),
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
    @State private var webLinkDestination = WebLinkOpening.destination

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

                linksSection

                readingListsSection

                zoomTranscriptsSection
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Sources")
    }

    // MARK: - Links

    /// Where a web link clicked in ForeverLM opens on this Mac
    /// (`WebLinkOpening`): the Browser pane, whose Add to Library files the
    /// page, unless the learner picks their own browser.
    private var linksSection: some View {
        SettingsSection(
            title: "Links",
            description: "Where a web link you click in ForeverLM opens on this Mac. In ForeverLM’s Browser, Add to Library saves the page to your library."
        ) {
            SettingsCard {
                Picker("Open links in", selection: Binding(
                    get: { webLinkDestination },
                    set: { destination in
                        WebLinkOpening.setDestination(destination)
                        webLinkDestination = destination
                    }
                )) {
                    ForEach(WebLinkDestination.allCases) { destination in
                        Text(destination.title).tag(destination)
                    }
                }
                .padding(.vertical, 8)
                .accessibilityIdentifier("settings.sources.linksOpenIn")
            }
        }
        .onAppear { webLinkDestination = WebLinkOpening.destination }
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
            Preferences.set(path, for: Prefs.Meetings.zoomLocalTranscriptFolder)
        } else {
            Preferences.reset(Prefs.Meetings.zoomLocalTranscriptFolder)
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

/// A card asking the learner to sign in, for a pane whose account state
/// needs the ForeverLM account.
struct ManagedAISignInSection: View {
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
/// (`AppPlanSettingsSection`): the product owner asked for the subscription
/// to stand apart from all the AI usage (2026-09-28), which is Settings › AI
/// Usage.
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

/// The app menu's Screen Record Mode item: the one place outside Settings that
/// says the mode is on, so the recorded window itself carries no badge. Shown
/// only once the proxy has confirmed this account as an admin.
struct ScreenRecordModeMenuItem: View {
    @AppStorage(Prefs.Lifecycle.screenRecordConfirmedAdmin) private var isAdmin: Bool
    @AppStorage(Prefs.Lifecycle.screenRecordEnabled) private var isOn: Bool

    var body: some View {
        if isAdmin {
            Toggle("Screen Record Mode", isOn: Binding(
                get: { isOn },
                set: { ScreenRecordMode.setEnabled($0) }
            ))
        }
    }
}
