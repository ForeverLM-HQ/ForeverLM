// The learner's yes, asked in the app, before an MCP call does something a
// caller's word alone must not decide.

import Foundation
#if os(macOS)
import AppKit
#endif

/// Some tool calls change what pays for AI, or spend more than the $3 an
/// operation gets by default. Whatever the caller says, a remote AI app, a
/// plugin, or a prompt-injected chat, the learner says yes in ForeverLM first
/// (security audit, 2026-11-12). An unanswered question is a no after
/// `timeout`, so a call to an unattended Mac does not hang.
@MainActor
enum MCPLearnerConfirmation {
    struct Request: Equatable, Sendable {
        let title: String
        let detail: String
        let confirmLabel: String
    }

    /// Tests answer here instead of an alert. Nil in the app.
    static var answerForTesting: ((Request) -> Bool)?

    static let defaultTimeout: TimeInterval = 120

    static func ask(_ request: Request, timeout: TimeInterval = defaultTimeout) async -> Bool {
        if let answer = answerForTesting { return answer(request) }
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = request.title
        alert.informativeText = request.detail
        alert.addButton(withTitle: request.confirmLabel)
        alert.addButton(withTitle: "Don’t Allow")
        alert.alertStyle = .warning
        let timer = Timer(timeInterval: timeout, repeats: false) { _ in
            MainActor.assumeIsolated { NSApp.abortModal() }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        return alert.runModal() == .alertFirstButtonReturn
        #else
        return false
        #endif
    }

    /// The question for `set_own_router_key`.
    static func ownRouterKeyRequest(routerLabel: String, clear: Bool, caller: String) -> Request {
        clear
            ? Request(
                title: "Remove your \(routerLabel) key?",
                detail: "\(caller) asked ForeverLM to remove the \(routerLabel) key it uses for AI. Without it, AI is paid from your ForeverLM balance.",
                confirmLabel: "Remove Key"
            )
            : Request(
                title: "Use a new \(routerLabel) key?",
                detail: "\(caller) asked ForeverLM to pay for AI with a \(routerLabel) key it supplied. Allow this only if you gave it that key yourself.",
                confirmLabel: "Use This Key"
            )
    }

    /// The question for a paid call whose ceiling is above the default.
    static func spendRequest(tool: String, approvedUSD: Double, caller: String) -> Request {
        Request(
            title: String(format: "Allow up to $%.2f for %@?", approvedUSD, tool),
            detail: String(format: "%@ asked to spend up to $%.2f on one %@ run. Operations are held to $%.2f unless you allow more.", caller, approvedUSD, tool, MCPRunningWork.defaultSpendLimitUSD),
            confirmLabel: "Allow"
        )
    }

    /// The name the learner knows the caller by.
    nonisolated static func callerName(_ access: MCPAccessContext) -> String {
        if access == .internalFullAccess { return "ForeverLM’s chat" }
        return access.assistantName ?? access.connectorLabel
    }
}
