// The AI subscriptions setup asks about, the connected assistants and the full disk access check.
import AppKit
import SwiftUI

/// An AI app the learner may already pay for. Setup asks (product owner, 2026-09-23)
/// instead of telling everyone about Claude and ChatGPT, so the AI step can say
/// what that subscription covers and the last step shows the one connector
/// setup that fits. The steps follow docs-site/setup-mcp.md and the setup
/// prompts in Settings › MCP (`MCPSettingsDetailView`).
enum AISubscription: String, CaseIterable, Identifiable, Hashable {
    case claude
    case chatGPT = "chatgpt"
    case grok
    case gemini
    case other

    /// Synced: what someone pays for follows the account, not the Mac.
    static let storageKey = Prefs.Rail.aiSubscriptions.name
    private static let noneAnswer = "none"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .chatGPT: return "ChatGPT"
        case .grok: return "Grok"
        case .gemini: return "Gemini"
        case .other: return "Another one"
        }
    }

    var logoAssetName: String? {
        switch self {
        case .claude: return "ClaudeIcon"
        case .chatGPT: return "OpenAIIcon"
        case .grok: return "GrokIcon"
        case .gemini: return "GeminiIcon"
        case .other: return nil
        }
    }

    var usesTemplateLogo: Bool { self == .chatGPT || self == .grok }

    /// Where the connector goes in that app; the card adds the address.
    var connectorSteps: [String] {
        switch self {
        // Claude's dialog asks how to sign in and which OAuth client to use.
        // The gateway answers MCP discovery before sign-in, so Claude may
        // detect "No sign-in"; and it registers clients by Dynamic Client
        // Registration only, so Claude's recommended "published identity"
        // does not connect. The step names the two answers that work, in
        // Claude's own words (claude.com/docs/connectors/custom/add-unlisted).
        case .claude:
            return [
                "In Claude, open Customize › Connectors and choose Add custom connector",
                "Name it ForeverLM, paste the address below, and choose Continue",
                "Under Authentication choose Sign in now, and under OAuth client choose Register automatically",
                "Choose Add, then Connect, and sign in with the same Apple Account as here",
            ]
        case .chatGPT:
            return [
                "In ChatGPT, open Settings › Apps › Advanced Settings and turn on developer mode",
                "Back in Settings › Apps, choose Create, name it ForeverLM, and paste the address below",
                "Choose OAuth and sign in with the same Apple Account as here",
                "In a new chat, turn on ForeverLM from the tools menu",
            ]
        case .grok:
            return [
                "On grok.com, open Connectors and choose New Connector, then Custom",
                "Name it ForeverLM and paste the address below",
                "Sign in with the same Apple Account as here",
                "In a Grok chat, turn on ForeverLM under Plugins",
            ]
        case .gemini:
            return [
                "In Gemini on the web, open Settings & help › Connected Apps",
                "Under Custom apps for Spark, choose Add a custom app and paste the address below",
                "Leave the OAuth fields blank, choose Next, and sign in with the same Apple Account as here",
            ]
        case .other:
            return [
                "Add ForeverLM to it as an MCP connector with the address below",
                "Sign in with the same Apple Account as here",
            ]
        }
    }

    var connectorNote: String? {
        self == .gemini ? "Gemini uses ForeverLM in Spark tasks only." : nil
    }

    var connectorPage: (title: String, url: URL)? {
        switch self {
        case .claude: return ("Open Claude Connectors", URL(string: "https://claude.ai/settings/connectors")!)
        case .chatGPT: return ("Open ChatGPT", URL(string: "https://chatgpt.com")!)
        case .grok: return ("Open Grok Connectors", URL(string: "https://grok.com/connectors")!)
        case .gemini: return ("Open Gemini", URL(string: "https://gemini.google.com")!)
        case .other: return nil
        }
    }

    /// The stored answer: nil until asked, empty for "no", else the picks. A
    /// value from a newer build this one does not know is still something the
    /// learner pays for, so it reads as `.other` rather than as unanswered.
    static func decode(_ stored: String) -> Set<AISubscription>? {
        let stored = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if stored.isEmpty { return nil }
        if stored == noneAnswer { return [] }
        return Set(stored.split(separator: ",").map { AISubscription(rawValue: String($0)) ?? .other })
    }

    static func encode(_ answer: Set<AISubscription>?) -> String {
        guard let answer else { return "" }
        if answer.isEmpty { return noneAnswer }
        return allCases.filter(answer.contains).map(\.rawValue).joined(separator: ",")
    }

    /// Which of these an AI app is, from the name it registered with the
    /// hosted connector ("Claude", "ChatGPT", "Grok", "Claude Code (foreverlm)").
    /// Claude Code runs on a Claude plan and Codex on a ChatGPT one, so they
    /// count for those. ForeverLM's own clients are nobody's AI app.
    static func matching(clientName: String) -> AISubscription? {
        let name = clientName.trimmingCharacters(in: .whitespaces).lowercased()
        if name.hasPrefix("foreverlm") { return nil }
        if name.hasPrefix("claude") { return .claude }
        if name.hasPrefix("chatgpt") || name.hasPrefix("codex") || name.hasPrefix("openai") { return .chatGPT }
        if name.hasPrefix("grok") || name.hasPrefix("xai") { return .grok }
        if name.hasPrefix("gemini") || name.hasPrefix("google") { return .gemini }
        return .other
    }

    /// The walkthrough clip of these steps in WelcomeClipsResources; the row
    /// plays it when the folder carries it.
    var walkthroughClip: String { "connector-\(rawValue)" }
}

/// The AI apps connected to this account's hosted connector, as the gateway's
/// `/assistants` lists them, so the setup plan can tick each app off once the
/// learner has added ForeverLM to it. Nil when that cannot be read (signed
/// out, offline), which the plan shows as unknown rather than "not connected".
enum ConnectedAssistants {
    static func fetch() async -> Set<AISubscription>? {
        guard let token = ManagedAI.requestSessionToken,
              let url = URL(string: "https://plugin.\(MCPBrandDomains.current)/assistants") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let reply = try? await URLSession.shared.data(for: request),
              (reply.1 as? HTTPURLResponse)?.statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: reply.0)) as? [String: Any],
              let rows = object["assistants"] as? [[String: Any]] else { return nil }
        return Set(rows.compactMap { ($0["name"] as? String).flatMap(AISubscription.matching(clientName:)) })
    }
}

/// Full Disk Access, which Apple Podcasts and the browsers' Reading Lists
/// need. Setup asks for it once; the sidebar's access card asks again when a
/// scan is blocked.
enum FullDiskAccess {
    /// Whether this process can read files only Full Disk Access opens. The
    /// TCC databases are protected by nothing else and never raise a prompt,
    /// unlike the Podcasts group container, whose "access data from other
    /// apps" dialog discovery must never provoke.
    static var isGranted: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probes = [
            home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path,
            "/Library/Application Support/com.apple.TCC/TCC.db",
        ]
        for path in probes {
            let descriptor = open(path, O_RDONLY)
            if descriptor >= 0 {
                close(descriptor)
                return true
            }
        }
        return false
    }

    /// System Settings on the Full Disk Access list: the Ventura+ anchor
    /// first, then the older ones.
    static func openSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    /// macOS evaluates Full Disk Access per process at launch, so a grant made
    /// while the app is running takes effect only after a relaunch — no rescan
    /// from the still-running process can pick it up.
    @MainActor
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = [
            "-c",
            "for _ in $(seq 1 150); do kill -0 \(pid) 2>/dev/null || break; sleep 0.2; done; "
                + "kill -0 \(pid) 2>/dev/null || exec /usr/bin/open \"$0\"",
            Bundle.main.bundleURL.path
        ]
        try? relauncher.run()
        // The same app comes straight back, so it comes back to the same view.
        StudioWorkspaceWindowCoordinator.shared.prepareForRelaunch()
        NSApp.terminate(nil)
    }
}
