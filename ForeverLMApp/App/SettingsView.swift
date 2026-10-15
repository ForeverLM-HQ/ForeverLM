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
    /// What runs AI and what it cost: the own key, spending and limits, and
    /// the activity by task.
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
    static let enabledKey = "studio.assistantIntegrationsEnabled"
    static let statusLightVisibleKey = "studio.showMCPStatusLight"

    static var isEnabled: Bool {
        guard UserDefaults.standard.object(forKey: enabledKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: enabledKey)
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
        _selection = State(initialValue: initialPane ?? .general)
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

    /// The selected pane. Nothing pushes onto it since the plugins' pages left
    /// for the Plugins place; the stack keeps each pane's title its own.
    private var detailColumn: some View {
        NavigationStack {
            paneView(for: selection)
        }
    }

    private func navigate(to pane: SettingsPane) {
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
                keywords: ["own key", "api key", "key", "byok", "openrouter", "credits", "balance", "spending cap", "spending limit", "monthly limit", "daily limit", "usage", "spend", "cost", "activity", "dashboard", "free requests", "requests left", "daily quota", "rate limit"],
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

/// Settings › AI Usage above the activity: the learner's own key and
/// spending with its limits, one card each. Paying for ForeverLM is
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
                    // model, free ones included (`app_locked`); paying is
                    // Billing's, so this row only goes there.
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

    /// Dollars are OpenRouter's to show (product owner, 2026-10-15: "we
    /// shouldn't maintain our own spend stuff"), so the card links to its
    /// monitor. The daily background limit is this Mac's guard and stays.
    private var spendingSection: some View {
        SettingsSection(title: "Spending") {
            billingCard {
                VStack(alignment: .leading, spacing: 0) {
                    billingRow(
                        title: "Spend",
                        detail: "What your key has cost, by model and day, is in OpenRouter"
                    ) {
                        Link("Open OpenRouter", destination: ManagedAI.openRouterActivityURL)
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("aiUsage.openRouterActivity")
                    }
                    rowDivider
                    BackgroundAIDailyCapRow()
                }
            }
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

/// Settings → AI Usage: what runs ForeverLM's AI and what it has cost — the
/// learner's own key, spending and its limits, then the activity by task.
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

/// AI Usage › Activity: which tasks used AI, grouped by task, for a range,
/// read from this Mac's usage ledger (`ai_usage_events`). It shows what ran,
/// never what it cost: dollars are OpenRouter's monitor (Spending card).
/// Was the Usage pane until 2026-09-24,
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
                .help("They are missing from everything below")

                Spacer(minLength: 0)

                SettingsMoreInfoButton {
                    Text("They are missing from everything below.")
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
                            : "\(Self.exactCountText(totalEvents)) call\(totalEvents == 1 ? "" : "s")"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("The model each task runs on is set under Settings › Background.")

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

            if let task = summary.task {
                switch AIUsageTaskNeed.of(taskKey: task) {
                case .needed:
                    Text("Needed")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help("ForeverLM needs this to import and find what you add, so it has no switch.")
                case .optional:
                    if let control = Self.offSwitch(for: task) {
                        Button("Turn off…") {
                            switch control.place {
                            case .settings(let pane): onOpenSettings(pane)
                            case .plugin(let page): PluginsPlace.requestOpen(page)
                            }
                        }
                            .buttonStyle(.link)
                            .font(.caption)
                            .help(control.help)
                    }
                case .requested:
                    EmptyView()
                }
            }
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
        // Purposes of a chat the learner waits on, run on the chat's model.
        // Its title and history summary are tasks with Background routes.
        case "deep_research_chat", "chat_quiz_grading":
            return .slot(.chat)
        case "meeting_transcription", "podcast_transcription", "course_video_transcription":
            return .transcription(.media)
        case "composer_dictation", "review_dictation", "canvas_voice_dictation":
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

    /// Where an off switch lives: a Settings pane, or a plugin's page in the
    /// Plugins place, which Settings closes for.
    private enum OffSwitchPlace {
        case settings(SettingsPane)
        case plugin(PluginPage)
    }

    /// Where the learner turns off the background work behind an activity,
    /// for the tasks that have a switch. A task without one shows no link: a
    /// link that only opens a pane would not turn anything off. Adding a
    /// switch for another task is one more case here.
    private static func offSwitch(for task: String?) -> (place: OffSwitchPlace, help: String)? {
        switch task {
        case "card_drafting":
            return (.settings(.general), "Settings › General › Memory › Draft cards from what you finish")
        case "realtime_review_preparation":
            return (.settings(.general), "Settings › General › Memory review › Prepare review questions ahead of time")
        case "meeting_transcription":
            return (.plugin(.googleDrive), "Plugins › Google Drive › Transcribe recordings Google didn't")
        case "notebook_cover":
            return (.settings(.aiImages), "Settings › Images › Notebooks › Draw notebook covers")
        case "course_quiz_picture", "course_quiz_icon":
            return (.settings(.aiImages), "Settings › Images › Course quizzes › Draw pictures for new quizzes")
        case "transcript_formatting":
            return (.plugin(.youtube), "Plugins › YouTube › Format new transcripts automatically")
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
                serverReconciliationError = "Server usage could not be reconciled, so the list below may be incomplete: \(error.localizedDescription)"
            }
        } else {
            serverReconciliationError = nil
        }
    }

    /// Publishes the on-device ledger before making any network request. The
    /// server mirror is incremental and authoritative, but it is a refresh of
    /// this cache rather than a prerequisite for rendering it.
    private func reloadLocalUsage(from storage: StorageService) async {
        // Price what can be priced first, so a line is only treated as free
        // when its calls really cost nothing.
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
