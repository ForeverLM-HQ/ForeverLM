import SwiftUI

// MARK: - Data & Privacy

/// Settings → Data & Privacy: where the learner's data lives, what ForeverLM's
/// own servers keep, the one switch over models that train on prompts and
/// what AI hosts may retain, and — since 2026-09-24, when they stopped being
/// panes of their own — iCloud sync and the learner's teams.
///
/// Every line on this pane is a claim about the running system, kept to a
/// headline and one sentence. The library is `knowledge.db` and its files on
/// this Mac, carried to the learner's own iCloud by `CKSyncEngine` in the
/// library container; no ForeverLM server holds a copy
/// (docs/backend-storage-sync.md). The managed
/// proxy's D1 ledger (`workers/ai-proxy`, `managed-ai-ledger-schema.js`) has no
/// column for prompt or response text. The MCP gateway and relay
/// (`workers/mcp-gateway`, `workers/mcp-relay`) charge nothing for a tool call,
/// record none, and write error lines only, never bodies; always-on MCP's hosted
/// cache is the one documented exception. Provider training terms were checked
/// against each company's published API terms on 2026-09-12; when one changes,
/// change the sentence here in the same commit. The fuller account is the
/// privacy policy the pane links to.
struct DataPrivacySettingsDetailView: View {
    private static let privacyPolicyURL = URL(string: "https://foreverlm.com/privacy.html")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsSection(title: "Your library") {
                    SettingsCard {
                        DataPrivacyFactRow(
                            icon: "icloud.fill",
                            tint: .blue,
                            title: "Stored in your own iCloud",
                            text: "Sources, chats, reviews and Pages sync through your private iCloud container. ForeverLM keeps no copy."
                        )
                        DataPrivacyFactRow.divider
                        DataPrivacyFactRow(
                            icon: "person.2.fill",
                            tint: .green,
                            title: "Teams",
                            text: "Shared items are copied into the team creator's iCloud. Nothing passes through ForeverLM."
                        )
                        DataPrivacyFactRow.divider
                        DataPrivacyFactRow(
                            icon: "server.rack",
                            tint: .gray,
                            title: "On ForeverLM's servers",
                            text: "Your Apple sign-in identifier and email, your plan, your billing ledger and any AI balance left from before September 25, 2026, and your MCP connections."
                        )
                    }
                }

                WorkingNotesSettingsSection()

                SettingsSection(title: "AI requests") {
                    SettingsCard {
                        DataPrivacyFactRow(
                            icon: "arrow.left.arrow.right",
                            tint: .purple,
                            title: "Built-in models",
                            text: "Requests pass through ForeverLM's proxy to the provider. The proxy bills tokens and cost and never stores the prompt or the answer."
                        )
                        DataPrivacyFactRow.divider
                        DataPrivacyFactRow(
                            icon: "checkmark.shield.fill",
                            tint: .teal,
                            title: "Training",
                            text: "Anthropic, OpenAI, Google's paid API and xAI do not train on API traffic. Meta's Muse Spark 1.2 Contributor is priced for training on what you send it, and every picker that lists it says so."
                        )
                        DataPrivacyFactRow.divider
                        DataPrivacyFactRow(
                            icon: "waveform",
                            tint: .pink,
                            title: "Voice",
                            text: "Dictation is recorded on this Mac and sent to your transcription model only when you stop."
                        )
                        DataPrivacyFactRow.divider
                        AIDataPolicySettingsView()
                            .padding(.vertical, 12)
                    }
                }

                SettingsSection(title: "MCP") {
                    SettingsCard {
                        DataPrivacyFactRow(
                            icon: "link.badge.plus",
                            tint: .purple,
                            title: "Tool calls are not logged",
                            text: "ForeverLM keeps no record of what was asked or returned."
                        )
                        DataPrivacyFactRow.divider
                        DataPrivacyFactRow(
                            icon: "moon.zzz.fill",
                            tint: .indigo,
                            title: "Always-on MCP",
                            text: "Keeps a revocable iCloud session and a metadata cache on ForeverLM's servers so an assistant can work while your devices are off. Disconnecting deletes both."
                        )
                        DataPrivacyFactRow.divider
                        DataPrivacyFactRow(
                            icon: "key.fill",
                            tint: .orange,
                            title: "Cloud plugins",
                            text: "Slack, Linear, GitHub and Notion sign-in tokens are stored encrypted until you disconnect."
                        )
                    }
                }

                ICloudSyncSettingsSection()

                TeamSettingsSection()

                ScreenRecordingSettingsSection()

                Link(destination: Self.privacyPolicyURL) {
                    Label("Privacy Policy", systemImage: "arrow.up.right")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline)
                }
                .buttonStyle(.hoverWash)
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Data & Privacy")
    }
}

/// One fact: a tinted glyph, a headline, and the sentence behind it.
private struct DataPrivacyFactRow: View {
    let icon: String
    let tint: Color
    let title: String
    let text: String

    static var divider: some View {
        Divider().padding(.vertical, 2)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 12)
    }
}

/// The one switch behind `AIDataPolicy`: whether models that train on prompts
/// are offered at all, and whether OpenRouter may route to hosts that keep or
/// train on them. Writes through the synced preference rail so
/// the other Mac and the phone see the same answer, and re-reads when a remote
/// change lands. Lived under AI Models → Chat until 2026-09-12; it sits with
/// the rest of the data story now, and `AIDataPolicy.settingsLocation` says so.
struct AIDataPolicySettingsView: View {
    @State private var deniesDataCollection = AIDataPolicy.deniesDataCollection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(AIDataPolicy.switchTitle, isOn: Binding(
                get: { deniesDataCollection },
                set: { enabled in
                    // "Deny" leaves a free model no host, so the two switches
                    // exclude each other; Free mode puts its saved picks back.
                    if enabled, AIFreeMode.isOn { FreeModelsSetup.disableFreeMode() }
                    deniesDataCollection = enabled
                    PreferenceStore.set(enabled, forKey: AIDataPolicy.denyDataCollectionKey)
                    AIModelCatalog.dataPolicyDidChange()
                }
            ))
            .accessibilityIdentifier("settings.ai.denyDataCollection")

            Text(AIDataPolicy.switchExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: PreferenceStore.didChangeRemotely)) { note in
            guard let keys = note.userInfo?[PreferenceStore.changedKeysKey] as? Set<String>,
                  keys.contains(AIDataPolicy.denyDataCollectionKey) else { return }
            deniesDataCollection = AIDataPolicy.deniesDataCollection
        }
        // Turning Free mode on turns the switch off; Get Started shows both.
        .onReceive(NotificationCenter.default.publisher(for: .aiProviderDidChange).receive(on: RunLoop.main)) { _ in
            deniesDataCollection = AIDataPolicy.deniesDataCollection
        }
    }
}

/// Admin only: filming product videos against the real library. While on,
/// every list, search and chat pick shows only the chosen Notebook's sources,
/// safe public captures and work made after the mode went on
/// (`ScreenRecordScope`). It sits
/// here because it decides what the screen shows; this pane and the app menu
/// are the only places that say the mode is on, so the recorded window shows
/// nothing of it. Both values are device-local and read through `@AppStorage`
/// so a change made over MCP or from the app menu shows at once; they are
/// written only through `ScreenRecordMode`, which stamps the cutoff and tells
/// the windows.
private struct ScreenRecordingSettingsSection: View {
    private struct MeetingGroupChoice: Identifiable {
        let id: String
        let title: String
    }

    @Environment(StudioViewModel.self) private var vm
    @AppStorage(ScreenRecordMode.confirmedAdminKey) private var isAdmin = false
    @AppStorage(ScreenRecordMode.enabledKey) private var isOn = false
    @AppStorage(ScreenRecordMode.notebookIDKey) private var notebookID = ""
    @AppStorage(ScreenRecordMode.librarySourcesKey) private var showsLibrarySources = false
    @State private var shownMeetingGroupIDs = Set(ScreenRecordMode.meetingGroupIDs)

    var body: some View {
        if isAdmin {
            SettingsSection(title: "Screen recording") {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle(isOn: Binding(
                            get: { isOn },
                            set: { ScreenRecordMode.setEnabled($0) }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Screen record mode")
                                    .font(.headline)
                                Text(isOn
                                    ? "On since \(cutoffText). Only the choices below, new public Reading List pages, X bookmarks and work made since show."
                                    : "Shows one curated notebook, new public Reading List pages, X bookmarks and selected meetings. This Mac only.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)

                        Divider()

                        HStack(alignment: .center, spacing: 20) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Show only this notebook's sources")
                                    .font(.headline)
                                Text("Other notebooks and their sources stay off screen. Use this notebook as the exact recording source list.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 12)
                            Picker("Notebook", selection: Binding(
                                get: { notebookID },
                                set: { ScreenRecordMode.setNotebookID($0) }
                            )) {
                                Text("None").tag("")
                                ForEach(notebookChoices, id: \.id) { notebook in
                                    Text(notebook.title).tag(notebook.id)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 220)
                        }

                        Divider()

                        Toggle(isOn: Binding(
                            get: { showsLibrarySources },
                            set: { ScreenRecordMode.setShowsLibrarySources($0) }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Also show the library's public sources")
                                    .font(.headline)
                                Text("Published papers, articles, podcasts, books and public videos. This never adds meetings, old X posts, uploads or your own chats and Pages.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)

                        Divider()

                        HStack(alignment: .center, spacing: 20) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Meeting folders kept on screen")
                                    .font(.headline)
                                Text("Choose only public seminar series intended for the recording. Every other meeting stays off screen.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 12)
                            Menu {
                                if meetingGroupChoices.isEmpty {
                                    Text("No meeting folders")
                                } else {
                                    ForEach(meetingGroupChoices) { choice in
                                        Button {
                                            toggleMeetingGroup(choice.id)
                                        } label: {
                                            Label(
                                                choice.title,
                                                systemImage: shownMeetingGroupIDs.contains(choice.id) ? "checkmark" : "circle"
                                            )
                                        }
                                    }
                                }
                                if !shownMeetingGroupIDs.isEmpty {
                                    Divider()
                                    Button("Show no meetings") {
                                        ScreenRecordMode.setMeetingGroupIDs([])
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Text(meetingSelectionLabel)
                                        .lineLimit(1)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption2)
                                }
                            }
                            .frame(width: 220)
                        }
                    }
                    .padding(.vertical, 4)
                    .onReceive(NotificationCenter.default.publisher(for: ScreenRecordMode.didChangeNotification)) { _ in
                        shownMeetingGroupIDs = Set(ScreenRecordMode.meetingGroupIDs)
                    }
                }
            }
        }
    }

    /// Every Notebook in the learner's own library, whatever the scope is
    /// showing, so the picker can move the scope to one that is hidden now.
    private var notebookChoices: [LearningGoalRecord] {
        vm.learningGoals
            .filter { $0.isNotebook && !$0.isArchived && $0.teamID == nil }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var cutoffText: String {
        guard let cutoff = ScreenRecordMode.cutoff else { return "now" }
        return cutoff.formatted(date: .abbreviated, time: .shortened)
    }

    private var meetingGroupChoices: [MeetingGroupChoice] {
        vm.allMeetingGroupNames.map { MeetingGroupChoice(id: $0, title: vm.meetingDisplayName($0)) }
    }

    private var meetingSelectionLabel: String {
        switch shownMeetingGroupIDs.count {
        case 0:
            return "None"
        case 1:
            let id = shownMeetingGroupIDs.first ?? ""
            return vm.meetingDisplayName(id)
        default:
            return "\(shownMeetingGroupIDs.count) folders"
        }
    }

    private func toggleMeetingGroup(_ id: String) {
        var next = shownMeetingGroupIDs
        if next.contains(id) {
            next.remove(id)
        } else {
            next.insert(id)
        }
        ScreenRecordMode.setMeetingGroupIDs(meetingGroupChoices.map(\.id).filter { next.contains($0) })
    }
}
