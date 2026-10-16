import Foundation

/// A connected X account. The id is X's user id, the one thing about an account
/// that survives a handle change, so every credential and cursor is keyed by it.
struct XAccount: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    /// Without the @. nil until a sign-in or sync has read it: an account
    /// adopted from an older build knows only its user id.
    var username: String?

    /// What a card, a chip or an error names the account by.
    var displayLabel: String {
        username.map { "@\($0)" } ?? "X account \(id)"
    }
}

/// One account's tokens, stored as one Keychain item so a refresh rewrites the
/// access token, the rotated refresh token and the expiry together: X refresh
/// tokens are single-use, and a crash between three separate writes would keep
/// a refresh token X has already retired.
struct XAccountCredentials: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var tokenExpiry: Date?
    /// Space-separated OAuth scopes the tokens were granted. Lets the app tell
    /// a read-only session (signed in before posting existed) from one that can
    /// also post, without a trial API call.
    var grantedScopes: String?
    /// The OAuth client that issued the tokens. A refresh token is bound to
    /// its client, so sessions from before ForeverLM's own client keep
    /// refreshing against the client that issued them.
    var clientID: String?

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func encoded() -> String? {
        guard let data = try? Self.encoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ value: String?) -> XAccountCredentials? {
        guard let value, let data = value.data(using: .utf8),
              let decoded = try? decoder().decode(XAccountCredentials.self, from: data),
              !decoded.accessToken.isEmpty else {
            return nil
        }
        return decoded
    }
}

/// The last thing that went wrong for one account, kept until its next sync
/// goes through.
struct XAccountFailure: Equatable, Sendable {
    var message: String
    /// Whether a new sign-in might clear it (`XBookmarkError.reconnectMayHelp`).
    var offersReconnect: Bool
}

/// What builds before multiple accounts stored for their one connection: the
/// Keychain's singleton slots and the two unsuffixed sync cursors. Read once,
/// by `XBookmarkService.adoptLegacyConnectionIfNeeded`.
struct XLegacyConnection: Equatable, Sendable {
    var userID: String?
    var username: String?
    var accessToken: String?
    var refreshToken: String?
    /// ISO 8601, as the old slot held it.
    var tokenExpiry: String?
    var grantedScopes: String?
    var clientID: String?
}

/// The account list and the rules around it. Pure, so the tests pin them
/// without a Keychain.
enum XAccountBook {

    // MARK: The list

    static func decode(_ value: String?) -> [XAccount] {
        guard let value, let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([XAccount].self, from: data) else {
            return []
        }
        var seen = Set<String>()
        return decoded.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }

    static func encode(_ accounts: [XAccount]) -> String? {
        guard let data = try? JSONEncoder().encode(accounts) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Adds the account, or refreshes the one with the same X user id in its
    /// place. A sign-in that did not read the handle keeps the one already known.
    static func merging(_ account: XAccount, into accounts: [XAccount]) -> [XAccount] {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else {
            return accounts + [account]
        }
        var merged = accounts
        merged[index] = XAccount(id: account.id, username: account.username ?? accounts[index].username)
        return merged
    }

    static func removing(id: String, from accounts: [XAccount]) -> [XAccount] {
        accounts.filter { $0.id != id }
    }

    // MARK: Adoption

    /// The first account an older build's single connection becomes, with its
    /// tokens. nil when the slots do not hold a finished sign-in (a token with
    /// no user id is a sign-in that never completed).
    static func adoption(of legacy: XLegacyConnection) -> (account: XAccount, credentials: XAccountCredentials)? {
        guard let userID = legacy.userID?.trimmingCharacters(in: .whitespacesAndNewlines), !userID.isEmpty,
              let accessToken = legacy.accessToken, !accessToken.isEmpty else {
            return nil
        }
        let username = legacy.username?.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = XAccount(id: userID, username: username?.isEmpty == false ? username : nil)
        let credentials = XAccountCredentials(
            accessToken: accessToken,
            refreshToken: legacy.refreshToken,
            tokenExpiry: legacy.tokenExpiry.flatMap { ISO8601DateFormatter().date(from: $0) },
            grantedScopes: legacy.grantedScopes,
            clientID: legacy.clientID
        )
        return (account, credentials)
    }

    // MARK: Cursors

    /// Each account's bookmark watermark and last sync live under its own
    /// defaults key, so syncing one account never moves another's.
    static func newestIDKey(accountID: String) -> String { "x_bookmarks_newest_id.\(accountID)" }
    static func lastSyncKey(accountID: String) -> String { "x_bookmarks_last_sync.\(accountID)" }

    /// The posts a sync may stop at besides its own watermark. A saved post
    /// can have come from another account's bookmarks, so on an account's
    /// first sync, with others connected, it says nothing about where this
    /// account's bookmarks end and would cut the first page short.
    static func stopPostIDs(
        savedPostIDs: Set<String>,
        newestSeenTweetID: String?,
        connectedAccountCount: Int
    ) -> Set<String> {
        if newestSeenTweetID == nil, connectedAccountCount > 1 { return [] }
        return savedPostIDs
    }

    // MARK: Posting

    /// The account a post goes out as. One connected account is the answer
    /// when none is named; with several, naming one is required, because
    /// guessing would publish as the wrong person. `requested` is a user id
    /// or a handle, with or without the @.
    static func postingAccount(among accounts: [XAccount], requested: String?) throws -> XAccount {
        guard !accounts.isEmpty else { throw XBookmarkError.notSignedIn }
        let handles = accounts.map(\.displayLabel)
        if let requested = requested?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty {
            let bare = requested.hasPrefix("@") ? String(requested.dropFirst()) : requested
            guard let match = accounts.first(where: {
                $0.id == bare || $0.username?.caseInsensitiveCompare(bare) == .orderedSame
            }) else {
                throw XBookmarkError.accountNotConnected(requested, connected: handles)
            }
            return match
        }
        guard accounts.count == 1 else { throw XBookmarkError.accountRequired(connected: handles) }
        return accounts[0]
    }
}
