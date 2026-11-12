import SwiftUI
import AppKit
import os
import AuthenticationServices
import Combine

// MARK: - One plugin's page

/// One plugin's page in the Plugins place (`PluginsPane`): its name, what it
/// reads, and its own controls — connecting, what it may read, what it
/// imports, disconnecting. These pages are in the Plugins place, not Settings
/// (product owner, 2026-10-13: "so you can take plugins
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
    private static let logger = Logger(subsystem: "com.foreverlm", category: "PluginSettings")
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
        do {
            sourceCounts = try await vm.storage.activePluginSourceCounts()
        } catch {
            Self.logger.error("Counting each plugin's sources failed: \(error.localizedDescription, privacy: .public)")
            sourceCounts = [:]
        }
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
        // Two newlines open this literal on purpose: the lead ends without one,
        // and the recipe starts a paragraph of its own.
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
    /// connected section): connected, or connected and
    /// needing a reconnect. A state not known yet is not installed.
    static func isInstalled(_ status: PluginStatus?) -> Bool {
        status == .connected || status == .needsAttention
    }
}

/// The line under a plugin's name in the Plugins place once it is
/// connected: what the connection may read, named. Each returns nil when the
/// connection has nothing more specific to say than the plugin's own
/// description, which the row then keeps. Internal so the unit tests can pin
/// the sentences.
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

struct PluginSettingsCard<Icon: View, Content: View>: View {
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
