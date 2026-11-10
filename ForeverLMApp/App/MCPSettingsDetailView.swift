// The MCP settings detail view and its setup assistant.
import SwiftUI
import Combine
import UniformTypeIdentifiers
import PDFKit
import WebKit
import AppKit

private enum MCPSetupAssistant: String, CaseIterable, Identifiable {
    case claude
    case codex
    case gemini
    case grok
    case muse
    /// Any other client that adds a remote MCP server with OAuth. Its prompt
    /// names no product, so the assistant it is pasted into maps the steps
    /// onto its own setup.
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "ChatGPT"
        case .gemini: return "Gemini"
        case .grok: return "Grok"
        case .muse: return "Meta Muse"
        case .other: return "Other assistant"
        }
    }

    /// How the setup prompt refers to the client it is pasted into.
    var promptClientName: String {
        switch self {
        case .other: return "assistant"
        default: return "\(displayName) client"
        }
    }

    /// Nil for the generic row, which draws an SF Symbol instead.
    var logoAssetName: String? {
        switch self {
        case .claude: return "ClaudeIcon"
        case .codex: return "OpenAIIcon"
        case .gemini: return "GeminiIcon"
        case .grok: return "GrokIcon"
        case .muse: return "MetaIcon"
        case .other: return nil
        }
    }

    var usesTemplateLogo: Bool {
        self == .codex || self == .grok
    }

    /// The hosted gateway serves every web agent and any client ForeverLM
    /// has no row for: it answers OAuth discovery and registration, and its
    /// consent page names where the sign-in returns. Muse's callback was
    /// admitted there and verified live (ca5e21831).
    var usesPublicMCPURL: Bool {
        self == .gemini || self == .muse || self == .other
    }

    var copyLabel: String {
        "\(displayName) setup prompt"
    }

    /// One line saying where this assistant takes the connection.
    var setupHint: String {
        switch self {
        case .claude:
            return "Claude.ai: Customize → Connectors → Add custom connector. Not in the Claude Directory yet."
        case .codex:
            return "Paste the prompt into Codex, or add a custom connector on chatgpt.com."
        case .gemini:
            return "Settings & help → Connected Apps → Add a custom app. Works in Gemini Spark tasks only."
        case .grok:
            return "Paste the prompt into Grok Build, or add a custom connector on grok.com."
        case .muse:
            return "Paste the prompt into a Muse chat on muse.ai. Muse builds the connector and asks you to sign in."
        case .other:
            return "Any assistant or agent that adds a remote MCP server with OAuth, such as Cursor."
        }
    }

    var openURL: URL? {
        switch self {
        case .claude: return URL(string: "https://claude.ai/settings/connectors")
        case .codex: return URL(string: "https://chatgpt.com/#settings/Connectors")
        case .gemini: return URL(string: "https://gemini.google.com")
        case .grok: return URL(string: "https://grok.com/connectors")
        case .muse: return URL(string: "https://muse.ai")
        case .other: return nil
        }
    }
}

/// The purple "Open Billing" label. `.borderedProminent` paints no hover, and a
/// `.hoverWash` grey sits behind a filled label, so the fill darkens itself.
private struct MCPOpenBillingLabel: View {
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Text("Open Billing")
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(shape.fill(Color.purple))
            .overlay(shape.fill(Color.black.opacity(isHovering ? 0.18 : 0)))
            .contentShape(shape)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// Prompt-first setup for connecting external AI clients to the hosted relay.
struct MCPSettingsDetailView: View {
    private static let publicMCPURL = "https://plugin.foreverlm.com/mcp"

    @State private var launcher = MCPServerLauncher.shared
    @State private var statusChecker = MCPStatusChecker.shared
    @State private var copied: String?
    @State private var hostedStartInProgress = false
    @State private var stopInProgress = false
    @SyncedStorage(AssistantIntegrationSettings.enabledKey) private var assistantIntegrationsEnabled = true
    @SyncedStorage(AssistantIntegrationSettings.statusLightVisibleKey) private var showsMCPStatusLight = true

    @Environment(ManagedAIAccountModel.self) private var account

    let showsPairingCode: Bool
    /// Opens Settings › Billing, where MCP is unlocked.
    let onOpenBilling: () -> Void

    // Keychain reads are securityd IPC round-trips; load them once off-main in
    // `.task` rather than on every render.
    @State private var storedTunnelURL: String?
    @State private var ownerPairingCode: String?

    init(showsPairingCode: Bool = false, onOpenBilling: @escaping () -> Void) {
        self.showsPairingCode = showsPairingCode
        self.onOpenBilling = onOpenBilling
    }

    private var hostedMCPURL: String? {
        launcher.mcpURL ?? storedTunnelURL.map { "\($0)/mcp" }
    }
    private var hostedTunnelIsReachable: Bool {
        guard statusChecker.status == .running,
              statusChecker.successfulURL != nil else {
            return false
        }
        return true
    }

    private func startHostedTunnelFromSettings(takingOver: Bool = false) {
        guard !hostedStartInProgress else { return }
        hostedStartInProgress = true
        Task {
            await MCPRuntimeCoordinator.startHostedTunnel(takingOver: takingOver)
            _ = await statusChecker.waitForHostedTunnel()
            await MainActor.run {
                hostedStartInProgress = false
            }
        }
    }

    private func stopMCPFromSettings() {
        guard !stopInProgress else { return }
        stopInProgress = true
        hostedStartInProgress = false
        assistantIntegrationsEnabled = false
        Task {
            await MCPRuntimeCoordinator.stopAll()
            await MainActor.run {
                stopInProgress = false
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                // Header
                VStack(spacing: 12) {
                    AssistantLogoCluster(logoSize: 24)
                    Text("External AI Assistants")
                        .font(.title.weight(.semibold))
                    Text("Connect Claude, ChatGPT, Gemini, Grok, Meta Muse, or any MCP assistant")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 20)

                if account.isMCPLocked {
                    // The connection is stopped until MCP is paid for; nothing
                    // else in the app is held back.
                    GroupBox {
                        HStack(spacing: 10) {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.secondary)
                            Text(EarlyUserDealOffer.lockedTitle)
                                .font(.title3.weight(.semibold))
                            Spacer()
                            Button(action: onOpenBilling) {
                                MCPOpenBillingLabel()
                            }
                            .buttonStyle(.hoverWash(in: RoundedRectangle(cornerRadius: 6, style: .continuous), inset: 0, opacity: 0))
                            .accessibilityIdentifier("settings.mcp.openBilling")
                        }
                        .padding(6)
                    }
                } else if assistantIntegrationsEnabled {
                    mcpConnectionPanel
                } else {
                    GroupBox {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(.secondary.opacity(0.5))
                                .frame(width: 10, height: 10)
                            Text("Disconnected")
                                .font(.title3.weight(.semibold))
                            Spacer()
                            Button("Connect") {
                                assistantIntegrationsEnabled = true
                                startHostedTunnelFromSettings()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.purple)
                            .disabled(stopInProgress)
                        }
                        .padding(6)
                    }
                }

                // The account button's dot, bottom left of the main window.
                // Its switch lives here, beside the connection it reports on.
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Show the status light in the account button", isOn: $showsMCPStatusLight)
                            .toggleStyle(.switch)
                            .accessibilityIdentifier("settings.mcp.showStatusLight")
                        Text("A dot by your name, bottom left, while assistants cannot reach your library.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle("MCP")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            let shouldLoadPairingCode = showsPairingCode
            let loaded = await Task.detached(priority: .utility) {
                (
                    KeychainService.load(.mcpTunnelURL),
                    shouldLoadPairingCode ? MCPOAuthProvider.ownerPairingCode : nil
                )
            }.value
            storedTunnelURL = loaded.0
            ownerPairingCode = loaded.1
        }
        .onAppear {
            guard assistantIntegrationsEnabled else { return }
            Task {
                _ = await statusChecker.checkHostedTunnel()
            }
        }
    }

    @ViewBuilder
    private var mcpConnectionPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(isMCPReachable ? .green : .red.opacity(0.6))
                        .frame(width: 10, height: 10)
                    Text(serverStatusLabel)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(isMCPReachable ? .primary : .secondary)
                    Spacer()
                    if launcher.isInProgress || hostedStartInProgress || stopInProgress {
                        ProgressView().controlSize(.small)
                    }

                    if launcher.state == .servedElsewhere && !hostedStartInProgress && !stopInProgress {
                        Button("Use This Mac") {
                            startHostedTunnelFromSettings(takingOver: true)
                        }
                        .buttonStyle(.bordered)
                        .help("Answer assistants from this Mac. The other ForeverLM steps aside until this one stops.")
                    }

                    if isMCPReachable {
                        Button("Disconnect") {
                            stopMCPFromSettings()
                        }
                        .buttonStyle(.bordered)
                        .disabled(stopInProgress)
                    } else if !launcher.isInProgress && !hostedStartInProgress && !stopInProgress {
                        Button("Connect") {
                            startHostedTunnelFromSettings()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                    }
                }

                if launcher.state == .servedElsewhere {
                    Text("Another ForeverLM signed in to your Apple ID is answering assistants. This Mac takes over when it quits or sleeps.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if case .failed(let reason) = launcher.state {
                    Divider()
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if showsPairingCode, let ownerPairingCode, !ownerPairingCode.isEmpty {
                    Divider()
                    pairingCodeRow(ownerPairingCode)
                } else if isMCPReachable, let hostedMCPURL, !hostedMCPURL.isEmpty {
                    Divider()
                    assistantSetupPanel(personalMCPURL: hostedMCPURL)
                }
            }
            .padding(6)
        }
    }

    private func assistantSetupPanel(personalMCPURL: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            serverURLRow

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Connect an assistant")
                    .font(.headline)
                Text("Copy the prompt and paste it into the assistant. It sets up the connection and asks you to approve it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(Array(MCPSetupAssistant.allCases.enumerated()), id: \.element) { index, assistant in
                    if index > 0 {
                        Divider().padding(.leading, 46)
                    }
                    assistantRow(
                        assistant,
                        mcpURL: assistant.usesPublicMCPURL ? Self.publicMCPURL : personalMCPURL
                    )
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
        }
    }

    private var serverURLRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Server URL")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(Self.publicMCPURL)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                copy(Self.publicMCPURL, label: "MCP URL")
            } label: {
                Label(
                    copied == "MCP URL" ? "Copied" : "Copy URL",
                    systemImage: copied == "MCP URL" ? "checkmark" : "doc.on.doc"
                )
            }
            .buttonStyle(.bordered)
        }
    }

    private func assistantRow(
        _ assistant: MCPSetupAssistant,
        mcpURL: String
    ) -> some View {
        let isCopied = copied == assistant.copyLabel
        return HStack(alignment: .center, spacing: 12) {
            Group {
                if let logoAssetName = assistant.logoAssetName {
                    Image(logoAssetName)
                        .resizable()
                        .renderingMode(assistant.usesTemplateLogo ? .template : .original)
                        .scaledToFit()
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18))
                }
            }
            .frame(width: 22, height: 22)
            .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(assistant.displayName)
                    .font(.headline)
                Text(assistant.setupHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if let openURL = assistant.openURL {
                Link(destination: openURL) {
                    Label("Open", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                .help("Open \(assistant.displayName)")
            }

            Button {
                copy(
                    Self.setupPrompt(for: assistant, mcpURL: mcpURL),
                    label: assistant.copyLabel
                )
            } label: {
                Label(
                    isCopied ? "Copied" : "Copy prompt",
                    systemImage: isCopied ? "checkmark" : "doc.on.doc"
                )
                .frame(minWidth: 96)
            }
            .buttonStyle(.borderedProminent)
            .tint(isCopied ? .green : .purple)
            .help("Copy the \(assistant.displayName) setup prompt")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Short, client-specific prompts based on each assistant's current remote
    /// HTTP MCP flow, plus one generic prompt for clients without a row. The
    /// URL is necessary; OAuth credentials are deliberately omitted because
    /// every client registers itself at the gateway.
    private static func setupPrompt(
        for assistant: MCPSetupAssistant,
        mcpURL: String
    ) -> String {
        let clientSteps: String
        switch assistant {
        case .claude:
            clientSteps = """
            If this is Claude Code:
            1. Run `claude mcp get foreverlm`. If it is missing, run `claude mcp add --transport http --scope user foreverlm "\(mcpURL)"`.
            2. If the saved server uses a different URL, remove it and add it again with the command above.
            3. Have me open `/mcp` if OAuth does not begin automatically.

            If this is Claude.ai or a Claude mobile app:
            ForeverLM is not in the Claude Directory yet, so add it as a custom connector:
            1. On the web, open https://claude.ai/settings/connectors (Customize → Connectors) and choose Add custom connector.
            2. Name it ForeverLM, enter "\(Self.publicMCPURL)", and choose Continue.
            3. Under Authentication choose Always required; under OAuth client choose No client ID — register one automatically.
            4. Choose Add, open the ForeverLM entry, choose Connect, and complete Sign in with Apple. It then works in Claude Desktop and mobile too.
            5. Verify the connection with get_mcp_status.
            """
        case .codex:
            clientSteps = """
            1. Run `codex mcp list`.
            2. If `foreverlm` is missing, run `codex mcp add foreverlm --url "\(mcpURL)"`. If it exists with a different URL, remove it and add it again with that command.
            3. Run `codex mcp login foreverlm` and complete OAuth.
            4. If this task cannot load the new tools, tell me to restart Codex or open a new task.
            """
        case .gemini:
            clientSteps = """
            If this is Gemini on the web:
            1. Open Settings & help → Connected Apps.
            2. Under Custom apps for Spark, choose Add a custom app.
            3. Enter "\(mcpURL)", leave advanced OAuth credentials blank, and choose Next.
            4. Complete Sign in with Apple, then enable ForeverLM in a Spark task.
            5. Verify the connection by calling `get_mcp_status`.

            Google currently requires custom apps to be added on the web. They work in Gemini Spark, not regular Gemini chats. If Custom apps for Spark is missing, explain that Google has not enabled the feature for this account; do not claim the MCP server is unavailable.

            If this is Gemini CLI instead:
            1. Run `gemini mcp list`.
            2. If `foreverlm` is missing, run `gemini mcp add foreverlm "\(mcpURL)" --transport http --scope user`.
            3. If OAuth does not begin automatically, have me run `/mcp auth foreverlm`.
            4. Run `/mcp list` and confirm that `foreverlm` is connected.
            """
        case .grok:
            clientSteps = """
            If this is Grok Build or Grok CLI:
            1. Run `grok mcp list`.
            2. If `foreverlm` is missing, run `grok mcp add --transport http foreverlm "\(mcpURL)"`.
            3. Complete the automatic OAuth flow on first use.

            If this is Grok web and you cannot edit Plugins yourself, give me only the remaining clicks: open https://grok.com/connectors, choose New Connector → Custom, name it ForeverLM, and use the URL above.
            """
        case .muse:
            clientSteps = """
            1. Create a Custom Connector named ForeverLM for the MCP server above. It is a hosted, public HTTPS endpoint that speaks Streamable HTTP, so connect to it as an MCP server; do not wrap it in an API client or scrape it.
            2. Start its OAuth sign-in. ForeverLM accepts Muse's registration automatically, so do not ask me for credentials. Hand me the sign-in page and let me finish Sign in with Apple there.
            3. When Muse asks me to approve the connector's access, tell me in one line what I am approving.
            4. Save the connector as a reusable skill so later Muse tasks can use ForeverLM without setting it up again.
            """
        case .other:
            clientSteps = """
            Use your own way of adding a remote MCP server. Products call it a custom connector, app, integration, extension, plugin, or MCP server.
            1. If you run in a terminal and have an MCP command (such as `<cli> mcp add`), add a server named `foreverlm` with HTTP transport and the URL above.
            2. If you are configured by a JSON file (such as `mcp.json`), add a `foreverlm` entry with the URL above in that file's format for remote HTTP servers.
            3. If you run in a web or desktop app, find where it adds a custom MCP server, name it ForeverLM, enter the URL above, choose OAuth, and leave client ID and secret blank.
            4. Complete OAuth. The ForeverLM page names the app I will be sent back to and says when it does not recognise it; I continue there with Sign in with Apple.
            5. If you cannot reach remote MCP servers at all, say so plainly. Do not improvise a workaround.
            """
        }

        return """
        Connect this \(assistant.promptClientName) to my existing ForeverLM MCP server.

        Name: ForeverLM
        Transport: Streamable HTTP
        URL: \(mcpURL)
        Authentication: OAuth 2.1 with PKCE, discovery, and dynamic client registration

        \(clientSteps)

        Important:
        - This is an existing remote MCP server. Do not build a plugin or write a new MCP server.
        - Use OAuth discovery and dynamic client registration. Do not ask me for a client ID, client secret, or API key. If an authorization page explicitly requires a pairing code, have me use its ForeverLM link and enter the code directly there; never ask me to paste it into chat.
        - ForeverLM must stay open on my Mac. Have me approve the connection when ForeverLM or my browser asks.
        - After setup, verify that the ForeverLM tools are listed and call `get_mcp_status`. Do not claim success until verification passes.
        - If permissions or workspace policy block custom MCP servers, state the exact blocker and the shortest action I need to take.

        Set it up now if you can. Otherwise, guide me through only what you cannot perform yourself.
        """
    }

    private var serverStatusLabel: String {
        if stopInProgress {
            return "Stopping..."
        }
        if hostedStartInProgress {
            return "Connecting..."
        }
        switch launcher.state {
        case .idle:
            if hostedTunnelIsReachable {
                return "Connected"
            }
            if statusChecker.status == .checking {
                return "Checking..."
            }
            return "Offline"
        case .starting:
            return "Starting..."
        case .settingUp:
            return "Connecting..."
        case .running:
            return "Connected"
        case .servedElsewhere:
            return "Served by another Mac"
        case .failed:
            return "Connection failed"
        }
    }

    private var isMCPReachable: Bool {
        launcher.state == .running || hostedTunnelIsReachable
    }

    @ViewBuilder
    private func pairingCodeRow(_ value: String) -> some View {
        HStack(spacing: 12) {
            Text("Pairing code")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button {
                copy(value, label: "Pairing code")
            } label: {
                Image(systemName: copied == "Pairing code" ? "checkmark" : "doc.on.doc")
                    .font(.body)
                    .foregroundStyle(copied == "Pairing code" ? .green : .secondary)
            }
            .buttonStyle(.hoverWash)
        }
    }

    private func copy(_ value: String, label: String) {
        copyToClipboard(value)
        copied = label
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copied == label { copied = nil }
        }
    }

    private func copyToClipboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
