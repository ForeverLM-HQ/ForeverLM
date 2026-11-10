// Derived state for connected X accounts and their sync pauses.

import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

extension StudioViewModel {

    /// Whether any X account is connected: the sidebar, the corner overlays and
    /// source discovery ask only this.
    var isXOAuthSignedIn: Bool { !xAccounts.isEmpty }

    /// Whether any account's session needs signing in again.
    var xPluginNeedsReauth: Bool { !xAccountsNeedingReauth.isEmpty }

    /// True when a failed sync is one a reconnect might clear, so the X tab
    /// and the plugin page offer Reconnect beside the retry.
    var xPluginOffersReconnect: Bool { xAccountFailures.values.contains { $0.offersReconnect } }

    /// True while X has told us to wait on this account. A retry the learner
    /// presses inside this window cannot succeed, so the button is disabled and
    /// the message beside it names the time instead.
    func isXSyncPaused(accountID: String) -> Bool {
        Self.isXSyncPaused(until: xSyncPausedUntil[accountID], now: Date())
    }

    /// True while every account that could sync is waiting out a limit.
    var isXSyncPaused: Bool {
        let syncable = xAccounts.filter { !xAccountsNeedingReauth.contains($0.id) }
        return !syncable.isEmpty && syncable.allSatisfy { isXSyncPaused(accountID: $0.id) }
    }

    nonisolated static func isXSyncPaused(until: Date?, now: Date) -> Bool {
        guard let until else { return false }
        return until > now
    }

    /// The pause a failed sync earns: the reset time of a 429 that carried
    /// one, and nothing for every other failure — an offline error or a 500
    /// is worth retrying as soon as the learner asks. A usage cap is a 429
    /// without a window (X resets it monthly, on a date it does not send), so
    /// it pauses nothing; the message already says a retry will not help.
    nonisolated static func xSyncPause(after error: Error, now: Date) -> Date? {
        guard case .rateLimited(let resetAt)? = error as? XBookmarkError,
              let resetAt, resetAt > now else { return nil }
        return resetAt
    }

    /// What the X tab's red attention dot stands for, or nil when there is
    /// nothing to flag. A sync that failed on its own — at launch, on
    /// activation, on the timer — is not news the learner asked for, so it is
    /// not announced with a toast that goes away unread; it waits on the tab
    /// until the learner looks, and the X list explains it with a retry
    /// beside it. An expired session counts too: it is the one failure a
    /// retry cannot fix, so the dot stays up until the learner reconnects.
    var xPluginAttention: String? {
        Self.xPluginAttention(
            accounts: xAccounts,
            failures: xAccountFailures,
            needsReauth: xAccountsNeedingReauth
        )
    }

    nonisolated static func xPluginAttention(
        accounts: [XAccount],
        failures: [String: XAccountFailure],
        needsReauth: Set<String>
    ) -> String? {
        // A disconnected X has its own "Connect to X" row; a dot on top of that
        // would nag about an integration the learner never set up.
        let lines: [String] = accounts.compactMap { account in
            let line: String
            if let message = failures[account.id]?.message, !message.isEmpty {
                line = message
            } else if needsReauth.contains(account.id) {
                line = "Reconnect to X to keep syncing bookmarks."
            } else {
                return nil
            }
            // With several accounts the line must say whose it is.
            return accounts.count > 1 ? "\(account.displayLabel): \(line)" : line
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

}
