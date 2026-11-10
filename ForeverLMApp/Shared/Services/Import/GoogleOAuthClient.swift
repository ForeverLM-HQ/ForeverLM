import Foundation

extension Notification.Name {
    /// Posted (on the main actor) when a plugin's sign-in state changes, so
    /// settings UI can refresh a cached "Connected" chip even when SwiftUI's
    /// `onAppear` doesn't re-fire on navigation pop-back.
    static let pluginConnectionChanged = Notification.Name("foreverlm.pluginConnectionChanged")
}

/// A Google OAuth client id/secret pair, guaranteed non-empty.
struct GoogleOAuthCredentials: Equatable, Sendable {
    let clientID: String
    let clientSecret: String

    init?(clientID: String?, clientSecret: String?) {
        let id = clientID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let secret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty, !secret.isEmpty else { return nil }
        self.clientID = id
        self.clientSecret = secret
    }
}

/// Resolves the app-owned Google OAuth clients used by YouTube and Drive. The
/// client that issued a YouTube account's tokens is recorded per account
/// (`YouTubeService`).
enum GoogleOAuthClient {
    /// ForeverLM's own YouTube client. `nil` in Debug builds whose `.env` has no
    /// YouTube client — release builds fail to compile without one.
    static var appOwnedYouTube: GoogleOAuthCredentials? {
        GoogleOAuthCredentials(
            clientID: Secrets.youtubeOAuthClientID,
            clientSecret: Secrets.youtubeOAuthClientSecret
        )
    }

    /// The client a *new* YouTube authorization should run against: an explicit
    /// override (advanced/development use), else ForeverLM's own client.
    static func youtubeAuthorization(
        explicit: GoogleOAuthCredentials? = nil
    ) -> GoogleOAuthCredentials? {
        explicit ?? appOwnedYouTube
    }

    // MARK: - Google Drive

    /// ForeverLM's Drive desktop client. Google Picker itself requires
    /// `drive.file`; the plugin follows that selection with a separate
    /// read-only Drive grant so it can actually enumerate the chosen folder.
    static var appOwnedDrive: GoogleOAuthCredentials? {
        GoogleOAuthCredentials(
            clientID: Secrets.driveOAuthClientID,
            clientSecret: Secrets.driveOAuthClientSecret
        ) ?? appOwnedYouTube
    }

    static func driveAuthorization(
        explicit: GoogleOAuthCredentials? = nil
    ) -> GoogleOAuthCredentials? {
        explicit ?? appOwnedDrive
    }
}
