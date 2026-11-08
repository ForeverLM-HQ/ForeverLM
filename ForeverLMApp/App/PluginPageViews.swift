import SwiftUI
import AppKit
import AuthenticationServices
import Combine
import UniformTypeIdentifiers
import EventKit

// MARK: - One plugin's page

/// One plugin's page in the Plugins place (`PluginsPane`): its name, what it
/// reads, and its own controls — connecting, what it may read, what it
/// imports, disconnecting. These pages were Settings' plugin panes until the
/// Plugins place took them (product owner, 2026-10-13: "so you can take plugins
/// out of settings actually and put it similarly to codex").
struct PluginPageContent: View {
    let page: PluginPage

    var body: some View {
        switch page {
        case .x:
            PluginSetupDetailView(title: page.title, description: page.about, includedTools: page.includedTools) {
                XPluginSettingsView()
            }
        case .youtube:
            PluginSetupDetailView(title: page.title, description: page.about, includedTools: page.includedTools) {
                YouTubeConnectionSettingsView()
            }
        case .googleDrive:
            PluginSetupDetailView(title: page.title, description: page.about, includedTools: page.includedTools) {
                GoogleDriveConnectionSettingsView()
            }
        case .appleCalendar:
            PluginSetupDetailView(title: page.title, description: page.about, includedTools: page.includedTools) {
                AppleCalendarConnectionSettingsView()
            }
        case .slack:
            PluginSetupDetailView(title: page.title, description: page.about, includedTools: page.includedTools) {
                SlackPluginSettingsView()
            }
        case .linear:
            PluginSetupDetailView(title: page.title, description: page.about, includedTools: page.includedTools) {
                LinearPluginSettingsView()
            }
        case .github:
            PluginSetupDetailView(title: page.title, description: page.about, includedTools: page.includedTools) {
                GitHubPluginSettingsView()
            }
        case .notion:
            PluginSetupDetailView(title: page.title, description: page.about, includedTools: page.includedTools) {
                NotionPluginSettingsView()
            }
        case .yourPlugins:
            UserPluginsSettingsDetailView()
        }
    }
}

/// The way back from a plugin's page to the Plugins list, which the place
/// hands its pages (`PluginsPane`); nil draws none.
private struct PluginPageBackKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var pluginPageBack: (() -> Void)? {
        get { self[PluginPageBackKey.self] }
        set { self[PluginPageBackKey.self] = newValue }
    }
}

/// The gateway's answers about the plugins it holds the tokens for: Slack,
/// Linear, GitHub and Notion. One copy for the whole app, so the page a row
/// opens starts from the answer the row already shows instead of blank, and a
/// refresh from either place updates both. nil until the gateway has
/// answered at all — no chip, rather than a wrong one for a moment.
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
    @State private var consent = PluginConsentSheet()

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
        // elsewhere, must show it without reopening the page.
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
            let callback = try await consent.authorize(provider: "Slack", url: authorization, redirect: MCPDataStore.slackInstallRedirectURL)
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

/// A provider's consent screen (Slack, Linear, Notion) in an
/// `ASWebAuthenticationSession` over the Studio window. The session is told to
/// stop at the registered redirect address and hand its query back, so the code
/// never loads the web page; the app finishes the install with the gateway
/// itself. Same shape as the Developer ID Sign in with Apple flow in
/// `ManagedAIAccountModel`.
@MainActor
private final class PluginConsentSheet: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    @available(macOS 14.4, *)
    func authorize(provider: String, url: URL, redirect: URL) async throws -> URL {
        session?.cancel()
        guard let host = redirect.host else {
            throw MCPError.invalidInput("The \(provider) redirect address is invalid.")
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
                    continuation.resume(throwing: MCPError.invalidInput("\(provider) returned no response."))
                }
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: MCPError.invalidInput("Could not open \(provider)'s sign-in sheet."))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}

/// One connected workspace as a gateway-held plugin's card draws it.
private struct GatewayWorkspaceCard: Identifiable, Equatable {
    let id: String
    let label: String
    /// "Reads as Robin Vale", when the gateway named the user.
    let detail: String?
}

/// The page of a plugin whose grants the gateway holds, one per workspace
/// (Linear, Notion): a card for each connected workspace with its own
/// Disconnect, and one quiet action below to connect another. The consent
/// screen opens in a sheet over this window and the app finishes the connect
/// with the gateway, the way the Slack page does.
@MainActor
private struct GatewayWorkspacesView: View {
    let provider: String
    /// The provider's web page, for a macOS that cannot stop a sheet at an
    /// https address.
    let setupURL: URL
    let redirect: URL
    /// nil until the gateway has answered.
    let workspaces: [GatewayWorkspaceCard]?
    let isSignedOut: Bool
    let authorize: () async throws -> URL
    let complete: (_ code: String, _ state: String) async throws -> Void
    let disconnect: (_ workspaceID: String) async throws -> Void
    let refresh: () async -> Void

    @State private var connecting = false
    @State private var disconnectingID: String?
    @State private var pendingDisconnect: GatewayWorkspaceCard?
    @State private var message: String?
    @State private var consent = PluginConsentSheet()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isSignedOut {
                SettingsCard {
                    Text("Sign in with Apple in ForeverLM to connect \(provider). ForeverLM reads \(provider) as you, through your own account, and never writes to it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(workspaces ?? []) { workspace in
                    workspaceCard(workspace)
                }
                addRow
            }
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await refresh() }
        // A workspace can be connected or disconnected from a chat or the web
        // page; coming back to the app must show it without reopening this page.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pluginConnectionChanged)) { _ in
            Task { await refresh() }
        }
        .confirmationDialog(
            "Disconnect \(pendingDisconnect?.label ?? "this workspace")?",
            isPresented: Binding(get: { pendingDisconnect != nil }, set: { if !$0 { pendingDisconnect = nil } }),
            presenting: pendingDisconnect
        ) { workspace in
            Button("Disconnect", role: .destructive) {
                Task { await disconnectWorkspace(workspace) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { workspace in
            Text("ForeverLM stops reading \(workspace.label) and its \(provider) grant is revoked. You can connect it again later.")
        }
    }

    private func workspaceCard(_ workspace: GatewayWorkspaceCard) -> some View {
        SettingsCard {
            HStack(alignment: .center, spacing: 12) {
                Text(String(workspace.label.prefix(1)).uppercased())
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.primary.opacity(0.055)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.label)
                        .font(.headline)
                        .lineLimit(1)
                    if let detail = workspace.detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                Button("Disconnect", role: .destructive) {
                    pendingDisconnect = workspace
                }
                .buttonStyle(.hoverWash)
                .foregroundStyle(.secondary)
                .disabled(disconnectingID == workspace.id)
            }
        }
    }

    private var addRow: some View {
        HStack(spacing: 10) {
            if connecting {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for \(provider)…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    Task { await connect() }
                } label: {
                    Label(
                        (workspaces ?? []).isEmpty ? "Connect \(provider)" : "Add Another Workspace",
                        systemImage: "plus"
                    )
                    .font(.callout.weight(.medium))
                }
                .buttonStyle(.hoverWash)
                .disabled(workspaces == nil)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private func connect() async {
        connecting = true
        message = nil
        defer { connecting = false }
        do {
            guard #available(macOS 14.4, *) else {
                NSWorkspace.shared.open(setupURL)
                return
            }
            let authorization = try await authorize()
            let callback = try await consent.authorize(provider: provider, url: authorization, redirect: redirect)
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? {
                items.first(where: { $0.name == name })?.value.flatMap { $0.isEmpty ? nil : $0 }
            }
            if let error = value("error") {
                if error == "access_denied" { return } // The learner backed out on the provider's screen.
                throw MCPError.invalidInput("\(provider) did not complete the connection (\(error)).")
            }
            guard let code = value("code"), let state = value("state") else {
                throw MCPError.invalidInput("\(provider) returned an incomplete authorization response.")
            }
            try await complete(code, state)
            await refresh()
            NotificationCenter.default.post(name: .pluginConnectionChanged, object: nil)
        } catch is CancellationError {
            // The sheet was dismissed.
        } catch {
            message = error.localizedDescription
        }
    }

    private func disconnectWorkspace(_ workspace: GatewayWorkspaceCard) async {
        disconnectingID = workspace.id
        message = nil
        defer { disconnectingID = nil }
        do {
            try await disconnect(workspace.id)
            await refresh()
            NotificationCenter.default.post(name: .pluginConnectionChanged, object: nil)
        } catch {
            message = error.localizedDescription
        }
    }
}

/// The Linear plugin: one card per connected workspace.
@MainActor
private struct LinearPluginSettingsView: View {
    private var connection: MCPDataStore.LinearConnection? { GatewayPluginState.shared.linear }

    var body: some View {
        GatewayWorkspacesView(
            provider: "Linear",
            setupURL: URL(string: "https://app.foreverlm.com/linear-connect")!,
            redirect: MCPDataStore.linearInstallRedirectURL,
            workspaces: connection.map { connection in
                connection.workspaces.map {
                    GatewayWorkspaceCard(id: $0.id, label: $0.label, detail: $0.user.map { "Reads as \($0)" })
                }
            },
            isSignedOut: connection == .signedOut,
            authorize: { try await MCPDataStore.linearAuthorizationURL() },
            complete: { code, state in try await MCPDataStore.completeLinearInstall(code: code, state: state) },
            disconnect: { id in _ = try await MCPDataStore.disconnectLinearWorkspace(id: id) },
            refresh: {
                if let connection = await MCPDataStore.linearConnection() {
                    GatewayPluginState.shared.linear = connection
                }
            }
        )
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

/// The Notion plugin: one card per connected workspace.
@MainActor
private struct NotionPluginSettingsView: View {
    private var connection: MCPDataStore.NotionConnection? { GatewayPluginState.shared.notion }

    var body: some View {
        GatewayWorkspacesView(
            provider: "Notion",
            setupURL: URL(string: "https://app.foreverlm.com/notion-connect")!,
            redirect: MCPDataStore.notionInstallRedirectURL,
            workspaces: connection.map { connection in
                connection.workspaces.map {
                    GatewayWorkspaceCard(id: $0.id, label: $0.label, detail: $0.user.map { "Reads as \($0)" })
                }
            },
            isSignedOut: connection == .signedOut,
            authorize: { try await MCPDataStore.notionAuthorizationURL() },
            complete: { code, state in try await MCPDataStore.completeNotionInstall(code: code, state: state) },
            disconnect: { id in _ = try await MCPDataStore.disconnectNotionWorkspace(id: id) },
            refresh: {
                if let connection = await MCPDataStore.notionConnection() {
                    GatewayPluginState.shared.notion = connection
                }
            }
        )
    }
}

/// Plugins › Build Your Own: the user-facing home for
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
            description: "A private plugin your AI assistant builds; it can add sources, never read your library.",
            includedTools: PluginPage.yourPlugins.includedTools
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
                Button {
                    NotificationCenter.default.post(name: .requestOpenStudioSettings, object: SettingsPane.mcp)
                } label: {
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
func sentenceCased(_ text: String, terminated: Bool = false) -> String {
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

/// A plugin's page: Codex's breadcrumb (Plugins › its name), its name and
/// what it reads, then its controls, then what it includes — the tools it
/// brings to a chat and over MCP — in the Plugins place's column.
private struct PluginSetupDetailView<Content: View>: View {
    let title: String
    let description: String
    var includedTools: [String] = []
    @ViewBuilder var content: () -> Content
    @Environment(\.pluginPageBack) private var back

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let back {
                    PluginsPlaceBreadcrumb(root: "Plugins", current: title, back: back)
                }
                SettingsSection(
                    title: title,
                    description: description
                ) {
                    content()
                }
                if !includedTools.isEmpty {
                    PluginIncludesSection(tools: includedTools)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .spacePlaceColumn()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .settingsFocusHost(pane: nil)
    }
}

/// Plugins › X: one card per connected X account, the way Google Drive and
/// Slack draw theirs, and one quiet action below them to add another.
private struct XPluginSettingsView: View {
    @Environment(StudioViewModel.self) private var vm

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if vm.xAccounts.isEmpty {
                SettingsCard {
                    HStack(spacing: 12) {
                        xGlyph
                        Text("No X account connected")
                            .font(.headline)
                        Spacer(minLength: 12)
                    }
                }
            }

            ForEach(vm.xAccounts) { account in
                accountCard(account)
            }

            if let error = vm.xConnectError {
                PluginErrorNotice(title: "Couldn’t connect to X", message: error)
            }

            addRow

            Link(destination: URL(string: "https://docs.foreverlm.com/x-posts")!) {
                Label("About X bookmarks", systemImage: "arrow.up.right")
                    .labelStyle(.titleAndIcon)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
        .onAppear {
            vm.checkXSignInStatus()
        }
    }

    private var xGlyph: some View {
        XLogoShape()
            .fill(.foreground, style: FillStyle(eoFill: true))
            .frame(width: 15, height: 15)
            .frame(width: 34, height: 34)
            .background(Circle().fill(Color.primary.opacity(0.055)))
    }

    /// Connecting never replaces what is there: it adds another account, or
    /// refreshes the one the browser's X session turns out to be.
    @ViewBuilder
    private var addRow: some View {
        HStack(spacing: 10) {
            if vm.isConnectingX {
                // The sign-in window is hosted by a system agent that can be
                // slow to launch; the row says so instead of looking dead.
                ProgressView()
                    .controlSize(.small)
                Text("Connecting…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    Task { await vm.signInWithX() }
                } label: {
                    Label(vm.xAccounts.isEmpty ? "Connect X" : "Add Another Account", systemImage: "plus")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.hoverWash)
                .accessibilityLabel(Text(vm.xAccounts.isEmpty ? "Connect X account" : "Connect another X account"))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func accountCard(_ account: XAccount) -> some View {
        let needsReauth = vm.xAccountsNeedingReauth.contains(account.id)
        let failure = vm.xAccountFailures[account.id]
        let isSyncing = vm.xSyncingAccountIDs.contains(account.id)
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    xGlyph
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.displayLabel)
                            .font(.headline)
                            .lineLimit(1)
                        Text(stateLine(account, needsReauth: needsReauth, isSyncing: isSyncing))
                            .font(.subheadline)
                            .foregroundStyle(needsReauth ? Color.orange : Color.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    if !needsReauth {
                        Button {
                            Task { await vm.syncXBookmarks(showResult: true, accountID: account.id) }
                        } label: {
                            ZStack {
                                Label("Sync", systemImage: "arrow.clockwise")
                                    .opacity(isSyncing ? 0 : 1)
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Syncing")
                                }
                                .opacity(isSyncing ? 1 : 0)
                            }
                        }
                        .buttonStyle(.hoverWash)
                        .disabled(vm.isSyncingXBookmarks || vm.isXSyncPaused(accountID: account.id))
                        .accessibilityLabel(Text(isSyncing ? "Syncing X bookmarks" : "Sync X bookmarks"))
                    }
                    if needsReauth || failure?.offersReconnect == true {
                        Button {
                            Task { await vm.signInWithX() }
                        } label: {
                            Label("Reconnect", systemImage: "link")
                        }
                        .buttonStyle(.hoverWash)
                        .disabled(vm.isSyncingXBookmarks || vm.isConnectingX)
                        .accessibilityLabel(Text(vm.isConnectingX ? "Connecting to X" : "Reconnect X account"))
                    }
                    Button("Disconnect", role: .destructive) {
                        vm.signOutOfX(accountID: account.id)
                    }
                    .buttonStyle(.hoverWash)
                    .foregroundStyle(.secondary)
                }
                if let failure {
                    PluginErrorNotice(title: "Couldn’t sync bookmarks", message: failure.message)
                }
            }
        }
    }

    private func stateLine(_ account: XAccount, needsReauth: Bool, isSyncing: Bool) -> String {
        if needsReauth { return "Reconnect needed" }
        if isSyncing { return "Syncing…" }
        if let lastSync = vm.xLastSyncDates[account.id] { return "Synced \(lastSync.roughTimeAgo)" }
        return "Connected"
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
        VStack(alignment: .leading, spacing: 16) {
            if connectedAccounts.isEmpty {
                SettingsCard {
                    HStack(spacing: 12) {
                        driveGlyph
                        Text(hasLegacyConnection ? "Connected Google account" : "No Google account connected")
                            .font(.headline)
                        Spacer(minLength: 12)
                        if hasLegacyConnection {
                            Button("Disconnect", role: .destructive) {
                                disconnectLegacyConnection()
                            }
                            .buttonStyle(.hoverWash)
                            .disabled(isWorking)
                        }
                    }
                }
            }

            // One card per Google account, the way Slack draws a workspace: any
            // number of accounts, and under each any number of folders.
            let attribution = foldersByAccount
            ForEach(connectedAccounts) { account in
                accountCard(account, folders: attribution.folders(for: account.id))
            }
            let strays = attribution.unattributed
            if !strays.isEmpty {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Account no longer connected")
                            .font(.callout.weight(.medium))
                        folderList(strays)
                    }
                }
            }

            addRow

            if isSignedIn {
                SettingsCard {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Transcribe recordings Google didn't")
                            Text("Each recording is a paid speech-to-text run.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Toggle("", isOn: $ownTranscriptionEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
                .settingsFocusRow(.driveTranscribeRecordings)
            }

            notice
        }
        .onAppear {
            Task {
                _ = try? await GoogleDriveService.shared.adoptLegacyAccountIfNeeded()
                await refreshConnectionState()
            }
        }
    }

    private var driveGlyph: some View {
        Image("GoogleDriveIcon")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: 20, height: 17)
            .frame(width: 34, height: 34)
            .background(Circle().fill(Color.primary.opacity(0.055)))
    }

    /// Connecting never replaces what is there: it adds another account, and
    /// each account takes more folders from its own card.
    @ViewBuilder
    private var addRow: some View {
        HStack(spacing: 10) {
            if isWorking {
                // The browser sends nothing back when its tab is closed,
                // so a bare spinner held this page for ten minutes.
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for Google…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Cancel") {
                    Task { await GoogleDriveService.shared.cancelPendingConnection() }
                }
                .buttonStyle(.hoverWash)
            } else {
                Button {
                    connectAndChooseFolder()
                } label: {
                    Label(
                        isSignedIn && !hasFolderReadAccess
                            ? "Reconnect Google Drive"
                            : (isSignedIn ? "Add Another Account" : "Connect Google Drive"),
                        systemImage: "plus"
                    )
                    .font(.callout.weight(.medium))
                }
                .buttonStyle(.hoverWash)
                .disabled(!GoogleDriveService.shared.canConnect)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var notice: some View {
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

    /// One connected Google account: who it is, the meeting folders ForeverLM
    /// reads through it, a way to add another, and its Disconnect.
    @ViewBuilder
    private func accountCard(_ account: GoogleDriveAccount, folders: [GoogleDriveFolderAttribution.Folder]) -> some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    Text(String(account.displayLabel.prefix(1)).uppercased())
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textSelection(.disabled)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.primary.opacity(0.055)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.displayLabel)
                            .font(.headline)
                            .lineLimit(1)
                        Text(accountSummary(account, folders: folders))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    if !hasFolderReadAccess {
                        Label("Reconnect", systemImage: "exclamationmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                    Button("Disconnect", role: .destructive) {
                        disconnect(accountID: account.id)
                    }
                    .buttonStyle(.hoverWash)
                    .foregroundStyle(.secondary)
                    .disabled(isWorking)
                }
                if !folders.isEmpty {
                    folderList(folders)
                }
                Button {
                    addFolder(to: account)
                } label: {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                        .font(.callout)
                }
                .buttonStyle(.hoverWash)
                .disabled(isWorking)
            }
        }
    }

    /// "Zara Holt · 1 folder." The name is left out when the label
    /// already is the name (an account Google gave no email for).
    private func accountSummary(_ account: GoogleDriveAccount, folders: [GoogleDriveFolderAttribution.Folder]) -> String {
        var parts: [String] = []
        let name = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != account.displayLabel { parts.append(name) }
        switch folders.count {
        case 0: parts.append("No meeting folder yet")
        case 1: parts.append("1 folder")
        default: parts.append("\(folders.count) folders")
        }
        return parts.joined(separator: " · ")
    }

    private func folderList(_ folders: [GoogleDriveFolderAttribution.Folder]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(folders.enumerated()), id: \.element.id) { index, folder in
                if index > 0 { Divider().padding(.leading, 38) }
                GoogleDriveFolderRow(folder: folder)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    /// Another meeting folder through an account that is already connected:
    /// no second sign-in, only the folder chooser.
    private func addFolder(to account: GoogleDriveAccount) {
        guard !isWorking else { return }
        isWorking = true
        statusMessage = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                guard let folder = await GoogleDriveFolderPicker.choose(account: account) else { return }
                vm.pinIntegrationTabsInUse()
                try await vm.importMeetingFolderFromAuthenticatedDrive(
                    folder.webURL,
                    groupTitle: folder.name,
                    silent: false
                )
                await refreshConnectionState()
            } catch is CancellationError {
                return
            } catch {
                await refreshConnectionState()
                statusMessage = error.localizedDescription
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
                try await vm.connectAndImportGoogleDriveMeetings(
                    reconnectOnly: isSignedIn && !hasFolderReadAccess
                )
                await refreshConnectionState()
                statusMessage = "Google Drive is connected."
            } catch is CancellationError {
                return
            } catch GoogleDriveServiceError.noFolderSelected {
                await refreshConnectionState()
                statusMessage = "Google Drive is connected. Choose a meeting folder to start importing."
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

/// Plugins › Calendar: turn the Mac's Calendar app on, choose which
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
                        CalendarGroupsSettingsSection(calendars: calendars, reloadCalendars: loadCalendars)
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
                            .disabled(takesNewEvents || holdsGroup(calendar))
                            .help(takesNewEvents ? "New events go to this calendar, so it is always in your day." : (holdsGroup(calendar) ? "A group's blocks go to this calendar, so it is always in your day." : ""))
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
            newEventsCalendarID: newEventsTargetID,
            groupCalendarIDs: Set(AppleCalendarService.shared.groups.map(\.calendarID))
        ).isEmpty
    }

    private func holdsGroup(_ calendar: AppleCalendarListEntry) -> Bool {
        AppleCalendarService.shared.groups.contains { $0.calendarID == calendar.id }
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

/// Plugins › Calendar › Groups: each context of the learner's work on a
/// calendar of its own, so it has one colour everywhere the calendar shows
/// (`CalendarGroup`). A group's calendar is one an account already brings in
/// (the day job's Exchange calendar) or one made for it here, in iCloud.
private struct CalendarGroupsSettingsSection: View {
    let calendars: [AppleCalendarListEntry]
    let reloadCalendars: () -> Void

    @State private var groups: [CalendarGroup] = AppleCalendarService.shared.groups
    @State private var message: String?
    @State private var isWorking = false
    /// What Move Blocks Into Groups would move, while the learner confirms.
    @State private var pendingMoves: [CalendarRegroupMove] = []
    @State private var confirmingMoves = false

    /// The swatches a group's calendar can wear: distinct at a glance in
    /// the Calendar app's light and dark week views.
    private static let swatches: [(name: String, color: CalendarColor)] = [
        ("Red", CalendarColor(red: 0.90, green: 0.22, blue: 0.27)),
        ("Orange", CalendarColor(red: 1.00, green: 0.55, blue: 0.16)),
        ("Yellow", CalendarColor(red: 0.96, green: 0.77, blue: 0.00)),
        ("Green", CalendarColor(red: 0.20, green: 0.66, blue: 0.33)),
        ("Teal", CalendarColor(red: 0.10, green: 0.65, blue: 0.70)),
        ("Blue", CalendarColor(red: 0.12, green: 0.48, blue: 0.95)),
        ("Purple", CalendarColor(red: 0.64, green: 0.35, blue: 0.85)),
        ("Pink", CalendarColor(red: 0.95, green: 0.35, blue: 0.62)),
        ("Brown", CalendarColor(red: 0.62, green: 0.45, blue: 0.30)),
        ("Graphite", CalendarColor(red: 0.50, green: 0.52, blue: 0.56)),
    ]

    private static let newCalendarTag = "foreverlm.newCalendar"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Groups")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Add Group") { addGroup() }
                    .controlSize(.small)
                    .accessibilityIdentifier("settings.appleCalendar.groups.add")
            }
            Text("Each part of your work on a calendar of its own, so it keeps one colour in Calendar, on your phone and in Plan. A block whose title or notes name a group goes onto its calendar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach($groups) { $group in
                row($group)
            }
            if !groups.isEmpty {
                HStack(spacing: 8) {
                    Button("Move Blocks Into Groups…") { previewMoves() }
                        .controlSize(.small)
                        .disabled(isWorking)
                        .help("Moves the blocks of the coming weeks that name a group onto its calendar. Meetings and repeating events stay where they are.")
                        .accessibilityIdentifier("settings.appleCalendar.groups.regroup")
                    if isWorking { ProgressView().controlSize(.small) }
                }
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pluginConnectionChanged)) { _ in
            let stored = AppleCalendarService.shared.groups
            if stored != groups { groups = stored }
        }
        .confirmationDialog(
            pendingMoves.count == 1 ? "Move 1 block into its group?" : "Move \(pendingMoves.count) blocks into their groups?",
            isPresented: $confirmingMoves
        ) {
            Button("Move") { applyMoves() }
            Button("Cancel", role: .cancel) { pendingMoves = [] }
        } message: {
            Text(Self.movesSummary(pendingMoves))
        }
    }

    private func row(_ group: Binding<CalendarGroup>) -> some View {
        let calendar = calendars.first { $0.id == group.wrappedValue.calendarID }
        let writable = calendars.filter(\.allowsModifications)
        return HStack(spacing: 8) {
            Menu {
                ForEach(Self.swatches, id: \.name) { swatch in
                    Button {
                        recolor(group.wrappedValue, swatch.color)
                    } label: {
                        Label {
                            Text(swatch.name)
                        } icon: {
                            Image(nsImage: Self.swatchImage(swatch.color))
                        }
                    }
                }
            } label: {
                Circle()
                    .fill(calendar?.color.map { Color(cgColor: $0.cgColor) } ?? Color.secondary.opacity(0.3))
                    .frame(width: 12, height: 12)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(calendar == nil || calendar?.allowsModifications == false)
            .help(calendar == nil ? "Choose a calendar first" : "Colour of “\(calendar?.title ?? "")”")
            TextField("Name", text: group.name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .onSubmit { save() }
            Picker("Calendar", selection: Binding(
                get: { group.wrappedValue.calendarID },
                set: { choose($0, for: group.wrappedValue) }
            )) {
                if calendar == nil { Text("Choose…").tag(group.wrappedValue.calendarID) }
                ForEach(writable) { entry in
                    Text(entry.account.isEmpty ? entry.title : "\(entry.title) · \(entry.account)").tag(entry.id)
                }
                Divider()
                Text("New Calendar “\(group.wrappedValue.name)”").tag(Self.newCalendarTag)
            }
            .labelsHidden()
            .frame(maxWidth: 200)
            TextField("Also named by…", text: Binding(
                get: { group.wrappedValue.keywords.joined(separator: ", ") },
                set: { group.wrappedValue.keywords = CalendarGroups.keywords(from: $0) }
            ))
            .textFieldStyle(.roundedBorder)
            .onSubmit { save() }
            .help("More words that name this group in a block's title or notes, separated by commas: Grant draft, Widget review")
            Button {
                groups.removeAll { $0.id == group.wrappedValue.id }
                save()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove the group. Its calendar and events stay.")
        }
        .onChange(of: group.wrappedValue.name) { _, _ in saveSoon() }
        .onChange(of: group.wrappedValue.keywords) { _, _ in saveSoon() }
        .accessibilityIdentifier("settings.appleCalendar.group.\(group.wrappedValue.id)")
    }

    // MARK: Changes

    private func addGroup() {
        groups.append(CalendarGroup(name: "New Group", calendarID: ""))
        save()
    }

    @State private var pendingSave: Task<Void, Never>?

    /// Typing saves after a pause, so each keystroke is not a write.
    private func saveSoon() {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save() {
        pendingSave?.cancel()
        let snapshot = groups
        Task.detached(priority: .userInitiated) {
            AppleCalendarService.shared.setGroups(snapshot)
        }
    }

    private func choose(_ calendarID: String, for group: CalendarGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        guard calendarID == Self.newCalendarTag else {
            groups[index].calendarID = calendarID
            save()
            return
        }
        let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            message = "Name the group first; its new calendar takes the name."
            return
        }
        let taken = Set(groups.compactMap { group in calendars.first { $0.id == group.calendarID }?.color?.hex })
        let color = Self.swatches.map(\.color).first { !taken.contains($0.hex) }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let made = try await AppleCalendarService.shared.createCalendar(title: name, color: color)
                if let index = groups.firstIndex(where: { $0.id == group.id }) {
                    groups[index].calendarID = made.id
                    save()
                }
                message = "Made “\(made.title)” in \(made.account.isEmpty ? "this Mac" : made.account)."
                reloadCalendars()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func recolor(_ group: CalendarGroup, _ color: CalendarColor) {
        Task {
            do {
                try await AppleCalendarService.shared.setColor(color, ofCalendar: group.calendarID)
                reloadCalendars()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func previewMoves() {
        save()
        isWorking = true
        message = nil
        let span = CalendarGroups.regroupSpan()
        Task {
            defer { isWorking = false }
            do {
                // Saved first, so the service reads these groups.
                try? await Task.sleep(for: .milliseconds(100))
                let moves = try await AppleCalendarService.shared.regroupEvents(from: span.start, to: span.end, apply: false)
                if moves.isEmpty {
                    message = "Every block of the coming weeks is already on its group's calendar."
                } else {
                    pendingMoves = moves
                    confirmingMoves = true
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func applyMoves() {
        let span = CalendarGroups.regroupSpan()
        isWorking = true
        Task {
            defer { isWorking = false; pendingMoves = [] }
            do {
                let moved = try await AppleCalendarService.shared.regroupEvents(from: span.start, to: span.end, apply: true)
                message = moved.count == 1 ? "Moved 1 block into its group." : "Moved \(moved.count) blocks into their groups."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    // MARK: Words and pictures

    /// "Day job: 4 blocks · Society: 7 blocks", then the first few blocks.
    static func movesSummary(_ moves: [CalendarRegroupMove]) -> String {
        var counts: [(String, Int)] = []
        for move in moves {
            if let index = counts.firstIndex(where: { $0.0 == move.group }) { counts[index].1 += 1 } else { counts.append((move.group, 1)) }
        }
        let byGroup = counts.map { "\($0.0): \($0.1) \($0.1 == 1 ? "block" : "blocks")" }.joined(separator: " · ")
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMdjmm")
        let first = moves.prefix(6).map { "\(formatter.string(from: $0.start))  \($0.title) → \($0.group)" }
        let more = moves.count > 6 ? ["and \(moves.count - 6) more"] : []
        return ([byGroup, ""] + first + more).joined(separator: "\n")
    }

    /// A menu item's swatch: menus draw an image, not a SwiftUI shape.
    static func swatchImage(_ color: CalendarColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(cgColor: color.cgColor)?.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

private struct YouTubeConnectionSettingsView: View {
    @Environment(StudioViewModel.self) private var vm
    @State private var isConnecting = false
    @State private var statusMessage: String?
    // Placeholders; `.onAppear` fills them in off-main (a synced Keychain read).
    @State private var autoImportEnabled = false
    /// What the stores currently say, so the `.onChange` below can tell the
    /// user flipping the toggle apart from the off-main refresh seeding it.
    @State private var persistedAutoImportEnabled = false
    @State private var setupDialog: YouTubeSetupDialog?
    @State private var configuringAccountID: String?
    @State private var pendingLikedImportPolicy: YouTubeLikedImportPolicy?
    @State private var channelInput = ""
    @State private var isFollowingChannel = false
    @SyncedStorage(StudioViewModel.youtubeLikedTranscriptFormattingKey)
    private var automaticallyFormatLikedVideoTranscripts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if vm.youtubeAccounts.isEmpty {
                SettingsCard {
                    HStack(spacing: 12) {
                        youtubeGlyph
                        Text("No YouTube account connected")
                            .font(.headline)
                        Spacer(minLength: 12)
                    }
                }
            }

            // One card per account, the way Google Drive and Slack draw theirs.
            ForEach(vm.youtubeAccounts) { account in
                accountCard(account)
            }

            if vm.hasConnectedYouTubeAccount {
                learnerCard
            }

            addRow
            notice
        }
        .onAppear {
            // A failed token refresh during a background import drops an
            // account's grant; re-read so a card never shows a stale
            // "Connected" state. Off-main: synced Keychain reads.
            Task {
                await vm.reloadYouTubeAccounts()
                let enabled = await Task.detached(priority: .userInitiated) {
                    StudioViewModel.isYouTubeAutoImportEnabled
                }.value
                persistedAutoImportEnabled = enabled
                autoImportEnabled = enabled
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
                if let accountID = setupDialog?.accountID { configureForeverLMPlaylist(accountID: accountID) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The playlist option uses a playlist in this YouTube account named ForeverLM.")
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

    private var youtubeGlyph: some View {
        Image("YouTubeIcon")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: 20, height: 14)
            .frame(width: 34, height: 34)
            .background(Circle().fill(Color.primary.opacity(0.055)))
    }

    // MARK: - Accounts

    /// One connected account: who it is, what it imports, its Disconnect.
    @ViewBuilder
    private func accountCard(_ account: YouTubeAccount) -> some View {
        let disconnected = vm.youtubeDisconnectedAccountIDs.contains(account.id)
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    Text(String(account.title.prefix(1)).uppercased())
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textSelection(.disabled)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.primary.opacity(0.055)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(stateLine(account, disconnected: disconnected))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    if disconnected {
                        Button {
                            connect()
                        } label: {
                            Label("Reconnect", systemImage: "exclamationmark.circle.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.hoverWash)
                        .disabled(isConnecting || !canConnect)
                    }
                    Button("Disconnect", role: .destructive) {
                        // UI first; the synced-Keychain deletes run off the click.
                        Task { await vm.disconnectYouTubeAccount(account.id) }
                    }
                    .buttonStyle(.hoverWash)
                    .foregroundStyle(.secondary)
                }
                if !disconnected {
                    importSourceRows(account)
                    if account.choices.source == .likedVideos {
                        likedImportPolicyRow(account)
                    }
                }
            }
        }
    }

    private func stateLine(_ account: YouTubeAccount, disconnected: Bool) -> String {
        if disconnected { return "Disconnected, import has stopped" }
        return account.choices.source.map { "Imports \($0.displayName)" } ?? "Choose what to import"
    }

    @ViewBuilder
    private func importSourceRows(_ account: YouTubeAccount) -> some View {
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
                    if account.choices.source == source {
                        Label("Selected", systemImage: "checkmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if configuringAccountID == account.id {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Use") {
                            if source == .likedVideos {
                                setupDialog = YouTubeSetupDialog(kind: .likedHistory, accountID: account.id)
                            } else {
                                configureForeverLMPlaylist(accountID: account.id)
                            }
                        }
                        .buttonStyle(.hoverWash)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func likedImportPolicyRow(_ account: YouTubeAccount) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Liked-video history")
                    .font(.callout)
                Text(account.choices.likedPolicy.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if configuringAccountID == account.id {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Change…") {
                    setupDialog = YouTubeSetupDialog(kind: .likedHistory, accountID: account.id)
                }
                .buttonStyle(.hoverWash)
                .controlSize(.small)
            }
        }
    }

    /// Connecting never replaces what is there: it adds another account.
    @ViewBuilder
    private var addRow: some View {
        HStack(spacing: 10) {
            if isConnecting {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for Google…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    connect()
                } label: {
                    Label(
                        vm.youtubeAccounts.isEmpty ? "Connect YouTube" : "Add Another Account",
                        systemImage: "plus"
                    )
                    .font(.callout.weight(.medium))
                }
                .buttonStyle(.hoverWash)
                .disabled(!canConnect)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var notice: some View {
        VStack(alignment: .leading, spacing: 6) {
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
        .padding(.horizontal, 4)
    }

    // MARK: - The learner's own

    /// What does not depend on the account: the automatic-import switch and
    /// the channels, which are public follows.
    private var learnerCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Automatically import new videos", isOn: $autoImportEnabled)
                    .onChange(of: autoImportEnabled) { _, enabled in
                        // Seeding from `.onAppear` must not re-persist or
                        // kick an import; only a real user flip does.
                        guard enabled != persistedAutoImportEnabled else { return }
                        persistedAutoImportEnabled = enabled
                        StudioViewModel.setYouTubeAutoImportEnabled(enabled)
                        if enabled { Task { await vm.runYouTubeAutoImportOnce() } }
                    }
                if vm.youtubeAccounts.contains(where: { $0.choices.source == .likedVideos }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(
                            "Format new transcripts automatically",
                            isOn: $automaticallyFormatLikedVideoTranscripts
                        )
                        Text("Billed to your OpenRouter key. Raw transcripts are always imported.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .settingsFocusRow(.youTubeFormatTranscripts)
                }
                Divider()
                followedChannelsSection
                if !vm.hiddenYouTubeChannelNames.isEmpty {
                    Divider()
                    hiddenChannelsSection
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
                    .buttonStyle(.hoverWash)
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
                    .buttonStyle(.hoverWash)
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
                    .buttonStyle(.hoverWash)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Actions

    /// Release builds ship ForeverLM's own YouTube OAuth client, so this is
    /// always true for users. It can only be false in a Debug build whose .env
    /// carries no YouTube client and which has no legacy Drive credentials.
    private var canConnect: Bool {
        YouTubeService.shared.canConnect
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

    private func connect() {
        guard canConnect else {
            statusMessage = "This build has no YouTube OAuth client configured."
            return
        }
        isConnecting = true
        statusMessage = nil
        Task {
            do {
                let account = try await YouTubeService.shared.authenticate()
                await vm.reloadYouTubeAccounts()
                if vm.youtubeAccount(id: account.id)?.choices.source == nil {
                    setupDialog = YouTubeSetupDialog(kind: .importSource, accountID: account.id)
                }
            } catch {
                statusMessage = error.localizedDescription
            }
            isConnecting = false
        }
    }

    private func configureLikedVideos(
        _ policy: YouTubeLikedImportPolicy,
        accountID: String,
        automaticallyFormatTranscripts: Bool
    ) {
        configuringAccountID = accountID
        statusMessage = nil
        Task {
            let groupID = await vm.configureYouTubeLikedVideos(
                policy,
                accountID: accountID,
                automaticallyFormatTranscripts: automaticallyFormatTranscripts
            )
            if groupID == nil {
                statusMessage = vm.errorMessage ?? "Could not configure Liked videos."
            }
            autoImportEnabled = StudioViewModel.isYouTubeAutoImportEnabled
            configuringAccountID = nil
        }
    }

    private func chooseLikedImportPolicy(_ policy: YouTubeLikedImportPolicy) {
        pendingLikedImportPolicy = policy
        guard let accountID = setupDialog?.accountID else { return }
        setupDialog = nil
        Task { @MainActor in
            await Task.yield()
            setupDialog = YouTubeSetupDialog(kind: .likedFormatting, accountID: accountID)
        }
    }

    private func finishLikedVideosSetup(automaticallyFormatTranscripts: Bool) {
        guard let policy = pendingLikedImportPolicy, let accountID = setupDialog?.accountID else { return }
        pendingLikedImportPolicy = nil
        automaticallyFormatLikedVideoTranscripts = automaticallyFormatTranscripts
        configureLikedVideos(
            policy,
            accountID: accountID,
            automaticallyFormatTranscripts: automaticallyFormatTranscripts
        )
    }

    private func showLikedHistoryChoiceAfterCurrentDialog() {
        guard let accountID = setupDialog?.accountID else { return }
        setupDialog = nil
        Task { @MainActor in
            await Task.yield()
            setupDialog = YouTubeSetupDialog(kind: .likedHistory, accountID: accountID)
        }
    }

    private func configureForeverLMPlaylist(accountID: String) {
        configuringAccountID = accountID
        statusMessage = nil
        Task {
            let groupID = await vm.followYouTubeForeverLMPlaylist(accountID: accountID)
            if groupID == nil {
                statusMessage = vm.errorMessage ?? "Could not find your ForeverLM playlist."
            }
            autoImportEnabled = StudioViewModel.isYouTubeAutoImportEnabled
            configuringAccountID = nil
        }
    }

    private func dialogBinding(_ kind: YouTubeSetupDialog.Kind) -> Binding<Bool> {
        Binding(
            get: { setupDialog?.kind == kind },
            set: { presented in
                if !presented, setupDialog?.kind == kind {
                    setupDialog = nil
                }
            }
        )
    }
}

/// A question the page is asking about one account.
private struct YouTubeSetupDialog: Equatable {
    enum Kind {
        case importSource
        case likedHistory
        case likedFormatting
    }

    let kind: Kind
    let accountID: String
}

enum PluginStatus: Equatable {
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

    /// Whether the directory lists a plugin under Installed (Codex's
    /// `skills.appsPage.section.connected`): connected, or connected and
    /// needing a reconnect. A state not known yet is not installed.
    static func isInstalled(_ status: PluginStatus?) -> Bool {
        status == .connected || status == .needsAttention
    }
}

/// The line under a plugin's name in the Plugins place once it is
/// connected: what the connection may read, named. Each returns nil when the
/// connection has nothing more specific to say than the plugin's own
/// description, which the row then keeps. Internal so the unit tests can pin
/// the sentences; Web Studio's `pluginScopeDescriptions` says the same.
enum PluginScopeCopy {
    /// "Imports bookmarks and saved posts from @handle." for one account,
    /// "… from 2 accounts." for several.
    static func x(accounts: [XAccount]) -> String? {
        switch accounts.count {
        case 0:
            return nil
        case 1:
            guard let username = trimmed(accounts[0].username) else { return nil }
            return "Imports bookmarks and saved posts from @\(username)."
        default:
            return "Imports bookmarks and saved posts from \(accounts.count) accounts."
        }
    }

    /// "Imports your Liked videos and follows 3 channels." Each source named
    /// once however many accounts read it: "Imports your Liked videos and
    /// ForeverLM playlist."
    static func youtube(sources: [String], followedChannels: Int) -> String? {
        var seen = Set<String>()
        let named = sources.compactMap(trimmed).filter { seen.insert($0).inserted }
        var clauses: [String] = []
        if !named.isEmpty { clauses.append("imports your \(ListFormatter.localizedString(byJoining: named))") }
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

    /// "Reads the Bench Lab workspace as Alan Young. Read-only." With several
    /// workspaces, "Reads the Bench Lab and Acme Lab workspaces. Read-only."
    static func linear(_ workspaces: [MCPDataStore.LinearWorkspace]) -> String? {
        workspaceScope(workspaces.map { ($0.name ?? $0.urlKey, $0.user) }, provider: "Linear")
    }

    /// The same sentences for Notion workspaces.
    static func notion(_ workspaces: [MCPDataStore.NotionWorkspace]) -> String? {
        workspaceScope(workspaces.map { ($0.name, $0.user) }, provider: "Notion")
    }

    private static func workspaceScope(_ workspaces: [(name: String?, user: String?)], provider: String) -> String? {
        let names = workspaces.compactMap { trimmed($0.name) }
        if workspaces.count > 1 {
            guard !names.isEmpty else { return nil }
            return "Reads the \(ListFormatter.localizedString(byJoining: names)) workspaces. Read-only."
        }
        switch (names.first, workspaces.first.flatMap { trimmed($0.user) }) {
        case (let workspace?, let user?): return "Reads the \(workspace) workspace as \(user). Read-only."
        case (let workspace?, nil): return "Reads the \(workspace) workspace. Read-only."
        case (nil, let user?): return "Reads \(provider) as \(user). Read-only."
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

/// One meeting folder under a Google account. "Open in Drive" appears on hover.
private struct GoogleDriveFolderRow: View {
    let folder: GoogleDriveFolderAttribution.Folder
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(folder.title)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let url = folder.url {
                Link(destination: url) {
                    Label("Open in Drive", systemImage: "arrow.up.right")
                        .font(.caption)
                }
                .opacity(isHovering ? 1 : 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
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
