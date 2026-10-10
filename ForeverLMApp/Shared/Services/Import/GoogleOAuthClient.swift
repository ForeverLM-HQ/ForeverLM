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

/// Resolves the app-owned Google OAuth clients used by YouTube and Drive, plus
/// the issuing client recorded for older bring-your-own-client sessions.
enum GoogleOAuthClient {
    /// ForeverLM's own YouTube client. `nil` in Debug builds whose `.env` has no
    /// YouTube client — release builds fail to compile without one.
    static var appOwnedYouTube: GoogleOAuthCredentials? {
        GoogleOAuthCredentials(
            clientID: Secrets.youtubeOAuthClientID,
            clientSecret: Secrets.youtubeOAuthClientSecret
        )
    }

    /// The user's own client, originally created for the retired Google Drive
    /// plugin. Kept because YouTube tokens issued under it can only refresh
    /// against it — the keychain keys keep their historical `googleDrive` names
    /// so existing entries keep resolving.
    static var userSuppliedGoogle: GoogleOAuthCredentials? {
        GoogleOAuthCredentials(
            clientID: KeychainService.googleDriveClientID,
            clientSecret: KeychainService.googleDriveClientSecret
        )
    }

    /// The client a *new* YouTube authorization should run against: an explicit
    /// override (advanced/development use), else ForeverLM's own client, else
    /// the user's Drive client, which is how YouTube worked before this app
    /// shipped its own.
    static func youtubeAuthorization(
        explicit: GoogleOAuthCredentials? = nil
    ) -> GoogleOAuthCredentials? {
        explicit ?? appOwnedYouTube ?? userSuppliedGoogle
    }

    /// The client that issued the stored YouTube tokens. Google refuses to
    /// refresh a token against a different client, so this must be the recorded
    /// one — never simply the current default. Connections predating the
    /// recorded client were issued under the user's own Google client.
    static var youtubeRefresh: GoogleOAuthCredentials? {
        GoogleOAuthCredentials(
            clientID: KeychainService.youtubeClientID,
            clientSecret: KeychainService.youtubeClientSecret
        ) ?? userSuppliedGoogle
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
        explicit ?? appOwnedDrive ?? userSuppliedGoogle
    }

    /// Google binds refresh tokens to the client that issued them.
    static var driveRefresh: GoogleOAuthCredentials? {
        GoogleOAuthCredentials(
            clientID: KeychainService.driveClientID,
            clientSecret: KeychainService.driveClientSecret
        ) ?? userSuppliedGoogle
    }
}
