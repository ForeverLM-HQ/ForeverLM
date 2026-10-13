import Foundation
import OSLog
import CryptoKit
import AuthenticationServices

/// Fetched X bookmark, ready to convert to StudioArticle.
struct XBookmark: Sendable {
    let tweetId: String
    let text: String
    let authorName: String
    let authorUsername: String
    let createdAt: Date?
    let urls: [String]
}

/// What X publishes about the account behind a handle.
struct XUserProfile: Sendable, Equatable {
    /// Lowercased, because a handle is the key every lookup here is keyed by
    /// and X does not preserve its case between the two endpoints.
    let username: String
    let name: String
    /// The account's picture at thumbnail-drawing size, or nil when it has none
    /// beyond X's placeholder.
    let avatarURL: String?
}

/// Handles X (Twitter) OAuth 2.0 PKCE, bookmark fetching, and posting.
/// Cost-minimization strategy:
/// - Tracks the newest tweet ID seen → only fetches new bookmarks on subsequent syncs
/// - Manual sync only (no background polling)
/// - Requests minimal fields to reduce read costs
/// - Reconciles the complete page containing the previous watermark before stopping
actor XBookmarkService {

    static let shared = XBookmarkService()

    /// X OAuth 2.0 native apps are public clients: the client identifier is
    /// intentionally shipped in the binary and PKCE protects each user's
    /// authorization code. This is ForeverLM's production X app, so users
    /// connect their normal X account without creating a developer app.
    nonisolated static let appOwnedOAuthClientID = "M0tEWjR4cTJ5NnJTX1ZUSDJPMmE6MTpjaQ"
    nonisolated static var oauthRedirectURI: String {
        "\(ForeverLMRuntimeIdentity.urlScheme)://x-callback"
    }
    nonisolated static let oauthScopes = "bookmark.read tweet.read tweet.write users.read offline.access"

    private let logger = Logger(subsystem: "com.foreverlm", category: "XBookmarkService")
    private let callbackScheme = ForeverLMRuntimeIdentity.urlScheme
    @MainActor private var authSession: ASWebAuthenticationSession?
    #if os(macOS)
    @MainActor private var presentationContext: WindowPresentationContext?
    #endif

    // MARK: - Sync State (persisted in UserDefaults)

    /// The newest tweet ID from the last successful sync.
    /// On subsequent syncs, we stop paginating when we hit this ID.
    private var newestSeenTweetId: String? {
        get { UserDefaults.standard.string(forKey: "x_bookmarks_newest_id") }
        set { UserDefaults.standard.set(newValue, forKey: "x_bookmarks_newest_id") }
    }

    nonisolated var lastSyncDate: Date? {
        let ts = UserDefaults.standard.double(forKey: "x_bookmarks_last_sync")
        return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
    }

    private func setLastSyncDate(_ date: Date?) {
        UserDefaults.standard.set(date?.timeIntervalSince1970 ?? 0, forKey: "x_bookmarks_last_sync")
    }

    // MARK: - Auth State

    /// Whether we have OAuth user tokens to call user-context endpoints (bookmarks).
    /// The X Bookmarks API requires OAuth 2.0 user context — app-only bearer tokens
    /// cannot access bookmarks. This property only checks for OAuth tokens.
    /// The @handle of the connected account, without the @, once a sign-in or
    /// sync has read it. nil while signed out or before the first read.
    nonisolated var signedInUsername: String? {
        guard isOAuthSignedIn else { return nil }
        return KeychainService.xUsername
    }

    nonisolated var isOAuthSignedIn: Bool {
        KeychainService.xAccessToken != nil && KeychainService.xUserId != nil
    }

    nonisolated var isSignedIn: Bool {
        isOAuthSignedIn
    }

    /// True when tokens exist but the session can no longer work: the access
    /// token is expired (or about to expire) and there is no refresh token or
    /// client ID to renew it with. The UI should prompt for a reconnect
    /// instead of reporting "Connected".
    nonisolated var needsReauthentication: Bool {
        guard isOAuthSignedIn else { return false }
        guard let expiry = KeychainService.xTokenExpiry,
              let expiryDate = ISO8601DateFormatter().date(from: expiry) else {
            return false
        }
        guard expiryDate.timeIntervalSinceNow < 60 else { return false }
        return KeychainService.xRefreshToken == nil || KeychainService.xClientId == nil
    }

    /// Whether the current tokens were granted the `tweet.write` scope.
    /// Sessions created before posting support are read-only until the user
    /// reconnects. Unknown scopes (pre-tracking tokens) count as read-only.
    nonisolated var canPost: Bool {
        guard isOAuthSignedIn, let scopes = KeychainService.xGrantedScopes else { return false }
        return scopes.split(separator: " ").contains("tweet.write")
    }

    nonisolated func signOut() {
        KeychainService.xClientId = nil
        KeychainService.xAccessToken = nil
        KeychainService.xRefreshToken = nil
        KeychainService.xUserId = nil
        KeychainService.xUsername = nil
        KeychainService.xTokenExpiry = nil
        KeychainService.xGrantedScopes = nil
    }

    @MainActor private func clearAuthSession() {
        authSession = nil
        #if os(macOS)
        presentationContext = nil
        #endif
    }

    // MARK: - OAuth 2.0 PKCE

    /// Authenticate with X using OAuth 2.0 PKCE flow.
    /// Returns the authenticated user ID.
    @MainActor
    func authenticate() async throws -> String {
        let clientId = Self.appOwnedOAuthClientID

        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)
        let state = UUID().uuidString

        let redirectURI = Self.oauthRedirectURI
        let scopes = Self.oauthScopes

        var components = URLComponents(string: "https://x.com/i/oauth2/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]

        let authURL = components.url!

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = WebAuthenticationSessionSupport.make(
                url: authURL,
                callbackScheme: callbackScheme
            ) { [weak self] url, error in
                Task { @MainActor [weak self] in self?.clearAuthSession() }
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: XBookmarkError.authFailed("No callback URL"))
                }
            }
            session.prefersEphemeralWebBrowserSession = false

            #if os(macOS)
            // macOS needs a presentation context; store it to keep it alive
            // (presentationContextProvider is a weak property)
            if let window = NSApplication.shared.keyWindow {
                let context = WindowPresentationContext(window: window)
                self.presentationContext = context
                session.presentationContextProvider = context
            }
            #endif

            self.authSession = session
            if !session.start() {
                Task { @MainActor [weak self] in self?.clearAuthSession() }
                continuation.resume(throwing: XBookmarkError.authFailed("Could not start the browser sign-in session."))
            }
        }

        // Extract authorization code
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value,
              returnedState == state else {
            throw XBookmarkError.authFailed("Invalid callback")
        }

        // Exchange code for tokens
        let tokens = try await exchangeCodeForTokens(code: code, codeVerifier: codeVerifier, redirectURI: redirectURI, clientId: clientId)
        KeychainService.xAccessToken = tokens.accessToken
        KeychainService.xRefreshToken = tokens.refreshToken
        KeychainService.xGrantedScopes = tokens.scope ?? scopes
        // Refresh tokens are bound to the client that issued them. Keep that
        // identity beside the tokens so older bring-your-own-client sessions
        // continue refreshing until the user reconnects, while every new
        // authorization migrates to ForeverLM's production client.
        KeychainService.xClientId = clientId
        let expiry = Date().addingTimeInterval(TimeInterval(tokens.expiresIn))
        KeychainService.xTokenExpiry = ISO8601DateFormatter().string(from: expiry)

        // Fetch user ID
        let user = try await fetchCurrentUser()
        KeychainService.xUserId = user.id
        KeychainService.xUsername = user.username
        logger.info("Authenticated with X as user \(user.id)")
        return user.id
    }

    // MARK: - Token Management

    /// The in-flight refresh, if any. X refresh tokens are single-use and
    /// rotate on every refresh, so two concurrent refreshes (the actor is
    /// reentrant across the network await — e.g. a bookmark sync racing an
    /// MCP post) would send the same token twice and X would invalidate the
    /// grant. All concurrent callers must await the same request.
    private var inFlightRefresh: Task<Void, Error>?

    private func refreshTokenIfNeeded() async throws {
        if let inFlightRefresh {
            return try await inFlightRefresh.value
        }

        guard let expiry = KeychainService.xTokenExpiry,
              let expiryDate = ISO8601DateFormatter().date(from: expiry) else {
            return // no expiry info, try using current token
        }

        // Refresh if expiring within 60 seconds
        guard expiryDate.timeIntervalSinceNow < 60 else { return }

        guard let refreshToken = KeychainService.xRefreshToken,
              let clientId = KeychainService.xClientId else {
            // Without a refresh token or client ID this session can never
            // recover — sign out so the UI stops reporting "Connected".
            signOut()
            throw XBookmarkError.sessionExpired
        }

        let task = Task { try await self.performTokenRefresh(refreshToken: refreshToken, clientId: clientId) }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        try await task.value
    }

    private func performTokenRefresh(refreshToken: String, clientId: String) async throws {
        logger.info("Refreshing X access token")

        var request = URLRequest(url: URL(string: "https://api.x.com/2/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        request.httpBody = Self.formURLEncodedBody([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw XBookmarkError.apiFailed("Token refresh failed: invalid response")
        }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            // A dead refresh token means the session is truly gone. X reports
            // it two ways: `invalid_grant`, or `invalid_request` with "Value
            // passed for the token was invalid." (a rotated-away or revoked
            // token — refresh tokens are single-use). Transient failures
            // (X 5xx, 429 rate limits, flaky networks) must NOT wipe the
            // stored refresh token, or we log the user out permanently on a
            // blip. Surface a retryable error instead.
            let tokenIsDead = body.contains("invalid_grant")
                || (body.contains("invalid_request") && body.contains("token was invalid"))
            if tokenIsDead {
                signOut()
                throw XBookmarkError.sessionExpired
            }
            logger.error("X token refresh failed: HTTP \(httpResponse.statusCode, privacy: .public) \(Self.errorSummary(fromBody: body), privacy: .public)")
            if httpResponse.statusCode == 402 {
                throw XBookmarkError.creditsDepleted
            }
            if let limit = Self.rateLimitError(
                status: httpResponse.statusCode,
                resetHeader: httpResponse.value(forHTTPHeaderField: "x-rate-limit-reset"),
                body: body
            ) {
                throw limit
            }
            throw XBookmarkError.apiFailed("Token refresh failed (HTTP \(httpResponse.statusCode)): \(body.prefix(200))")
        }

        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        KeychainService.xAccessToken = tokens.accessToken
        if let newRefresh = tokens.refreshToken {
            KeychainService.xRefreshToken = newRefresh
        }
        if let scope = tokens.scope {
            KeychainService.xGrantedScopes = scope
        }
        let newExpiry = Date().addingTimeInterval(TimeInterval(tokens.expiresIn))
        KeychainService.xTokenExpiry = ISO8601DateFormatter().string(from: newExpiry)
    }

    // MARK: - Fetch Bookmarks

    /// Fetches bookmark candidates since the last sync and persists them via `persist`.
    /// Cost-minimization: stops paginating after reconciling the complete page that
    /// contains the previously-seen tweet ID, or any post already in the library
    /// (`savedPostIDs`). Reconciliation deliberately finishes that page because X
    /// exposes no bookmark timestamp or bookmark-specific `since_id`; stopping
    /// midway can miss a newly added bookmark that X placed behind the watermark.
    ///
    /// X bills every post a page returns, whether or not it is new, so a sync that
    /// has something to stop at first asks for `incrementalPageSize` posts. The
    /// saved bookmarks are already in the library; the page only has to show
    /// whether anything is newer than them. A sync that finds nothing it knows on
    /// that page starts again from the top with full pages — the few posts it
    /// re-reads were billed moments ago and X does not bill them twice in a day.
    ///
    /// Auth strategy: OAuth tokens are preferred because bookmarks require user context.
    /// Bearer tokens are tried as fallback (they work if manually configured as user tokens).
    /// If bearer fails with 401, the error tells the user to sign in via OAuth.
    ///
    /// The sync cursor (`newestSeenTweetId`) and last-sync date are advanced ONLY
    /// after `persist` returns successfully. If the save throws, the watermark stays
    /// put so these bookmarks are re-fetched on the next sync instead of being lost.
    /// `persist` receives the fetched bookmarks (newest first) and returns how many
    /// were actually saved.
    func fetchNewBookmarks(
        savedPostIDs: Set<String> = [],
        persist: ([XBookmark]) async throws -> Int
    ) async throws -> Int {
        // Determine auth token: prefer OAuth (bookmarks require user context),
        // fall back to bearer (works if it's a manually-configured user token)
        let authToken: String
        if let oauthToken = KeychainService.xAccessToken, !oauthToken.isEmpty {
            try await refreshTokenIfNeeded()
            // Re-read after potential refresh
            authToken = KeychainService.xAccessToken ?? oauthToken
        } else {
            throw XBookmarkError.notSignedIn
        }

        // Ensure we have a user ID (needed for bookmarks endpoint URL). A
        // session from before the handle was kept learns it on its first sync.
        var userId = KeychainService.xUserId
        if userId == nil || KeychainService.xUsername == nil {
            let user = try await fetchCurrentUser(token: authToken)
            userId = user.id
            KeychainService.xUserId = user.id
            KeychainService.xUsername = user.username
        }
        guard let userId else {
            throw XBookmarkError.notSignedIn
        }

        var allBookmarks: [XBookmark] = []
        var paginationToken: String? = nil
        let stopAtId = newestSeenTweetId
        var firstTweetId: String? = nil
        let hasStop = stopAtId != nil || !savedPostIDs.isEmpty

        // One small page answers the usual sync, where little or nothing is new.
        // It is the whole answer when it reaches a saved bookmark, or when it is
        // every bookmark the account has.
        if hasStop {
            let (bookmarks, nextToken) = try await fetchBookmarksPage(
                userId: userId,
                accessToken: authToken,
                paginationToken: nil,
                pageSize: Self.incrementalPageSize
            )
            let page = Self.reconciliationCandidates(
                in: bookmarks,
                stopAtTweetID: stopAtId,
                savedPostIDs: savedPostIDs
            )
            if page.hitStop || nextToken == nil {
                return try await finishSync(
                    candidates: page.bookmarks,
                    newestTweetID: bookmarks.first?.tweetId,
                    persist: persist
                )
            }
        }

        // Paginate, stopping when we hit a known tweet
        repeat {
            let (bookmarks, nextToken) = try await fetchBookmarksPage(
                userId: userId,
                accessToken: authToken,
                paginationToken: paginationToken,
                pageSize: Self.fullPageSize
            )

            if firstTweetId == nil, let first = bookmarks.first {
                firstTweetId = first.tweetId
            }

            let page = Self.reconciliationCandidates(
                in: bookmarks,
                stopAtTweetID: stopAtId,
                savedPostIDs: savedPostIDs
            )
            allBookmarks.append(contentsOf: page.bookmarks)

            if page.hitStop {
                logger.info("Reconciled page containing a saved bookmark, stopping pagination")
                break
            }

            paginationToken = nextToken
        } while paginationToken != nil

        return try await finishSync(candidates: allBookmarks, newestTweetID: firstTweetId, persist: persist)
    }

    private func finishSync(
        candidates: [XBookmark],
        newestTweetID: String?,
        persist: ([XBookmark]) async throws -> Int
    ) async throws -> Int {
        // Persist BEFORE advancing the cursor. If the save throws, the watermark
        // stays put so nothing behind it is lost.
        let savedCount = try await persist(candidates)

        // Save succeeded — now it is safe to advance the cursor for next sync.
        if let newestTweetID {
            newestSeenTweetId = newestTweetID
        }
        setLastSyncDate(Date())

        logger.info("Reconciled \(candidates.count) X bookmark candidates, saved \(savedCount)")
        return savedCount
    }

    /// Posts asked for when the sync has a saved bookmark to stop at.
    nonisolated static let incrementalPageSize = 5
    /// X's largest page, for a first sync and for a backlog the small page did
    /// not reach the end of.
    nonisolated static let fullPageSize = 100

    /// Returns every candidate on the watermark page except the watermark itself
    /// and the posts already saved. A page stops pagination when it holds the
    /// watermark or any saved post: the watermark alone lives in this device's
    /// defaults, so a new device, a reset, or an un-bookmarked watermark would
    /// otherwise walk every bookmark the account has.
    /// Keeping candidates that appear after the watermark prevents ordering drift
    /// or eventual consistency in X's bookmark collection from hiding a new item.
    nonisolated static func reconciliationCandidates(
        in bookmarks: [XBookmark],
        stopAtTweetID: String?,
        savedPostIDs: Set<String> = []
    ) -> (bookmarks: [XBookmark], hitStop: Bool) {
        let isKnown: (XBookmark) -> Bool = { bookmark in
            bookmark.tweetId == stopAtTweetID || savedPostIDs.contains(bookmark.tweetId)
        }
        let hitStop = bookmarks.contains(where: isKnown)
        return (bookmarks.filter { !isKnown($0) }, hitStop)
    }

    // MARK: - Posting

    /// Result of a successful post: the new post's ID and canonical URL.
    struct XPostResult: Sendable {
        let postId: String
        let url: String
    }

    /// Publishes a post on X as the signed-in user, optionally as a reply.
    /// Requires the `tweet.write` scope; sessions created before posting
    /// support must reconnect via `authenticate()` to grant it.
    func createPost(text: String, replyToPostId: String? = nil) async throws -> XPostResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw XBookmarkError.apiFailed("Post text is empty.")
        }

        guard let currentToken = KeychainService.xAccessToken, !currentToken.isEmpty else {
            throw XBookmarkError.notSignedIn
        }
        guard canPost else {
            throw XBookmarkError.postingNotAuthorized
        }
        try await refreshTokenIfNeeded()
        let authToken = KeychainService.xAccessToken ?? currentToken

        var body: [String: Any] = ["text": trimmed]
        if let replyToPostId, !replyToPostId.isEmpty {
            body["reply"] = ["in_reply_to_tweet_id": replyToPostId]
        }

        var request = URLRequest(url: URL(string: "https://api.x.com/2/tweets")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw XBookmarkError.apiFailed("Invalid response")
        }

        switch httpResponse.statusCode {
        case 201:
            break
        case 401:
            signOut()
            throw XBookmarkError.notSignedIn
        case 403:
            // Token or developer app lacks write permission.
            throw XBookmarkError.postingNotAuthorized
        default:
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw XBookmarkError.apiFailed("HTTP \(httpResponse.statusCode): \(responseBody.prefix(200))")
        }

        struct CreatePostResponse: Decodable {
            struct PostData: Decodable { let id: String }
            let data: PostData
        }
        let decoded = try JSONDecoder().decode(CreatePostResponse.self, from: data)
        logger.info("Posted to X: \(decoded.data.id)")
        return XPostResult(postId: decoded.data.id, url: "https://x.com/i/status/\(decoded.data.id)")
    }

    // MARK: - Authors

    /// Handles X could not resolve this launch — deleted, renamed, or suspended
    /// accounts. Remembered so a repeated sync does not re-spend a lookup that
    /// already came back empty.
    private var unresolvableUsernames: Set<String> = []

    /// Display names for X handles, keyed by lowercased handle:
    /// `martinbjensen` → "Martin Borch Jensen".
    ///
    /// Looked up per handle rather than per post. A library holds far more posts
    /// than authors, so one call names every post a handle wrote — and unlike
    /// re-reading the posts themselves, it also names posts that were saved from
    /// a pasted link rather than from a bookmark.
    func fetchDisplayNames(forUsernames usernames: [String]) async throws -> [String: String] {
        try await fetchProfiles(forUsernames: usernames).compactMapValues { profile in
            profile.name.isEmpty ? nil : profile.name
        }
    }

    /// Everything one `users/by` lookup knows about a handle — the display name
    /// a search reads and the picture a source row draws — keyed by lowercased
    /// handle.
    ///
    /// Name and picture travel together because they arrive together: asking
    /// for one and then the other would spend two lookups on one handle.
    func fetchProfiles(forUsernames usernames: [String]) async throws -> [String: XUserProfile] {
        let wanted = Set(usernames.map { $0.lowercased() })
            .subtracting(unresolvableUsernames)
            .filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return [:] }

        guard let oauthToken = KeychainService.xAccessToken, !oauthToken.isEmpty else {
            throw XBookmarkError.notSignedIn
        }
        try await refreshTokenIfNeeded()
        let accessToken = KeychainService.xAccessToken ?? oauthToken

        var resolved: [String: XUserProfile] = [:]
        let batches = Array(wanted).chunked(intoBatchesOf: 100)
        for batch in batches {
            for (handle, profile) in try await fetchProfilesPage(batch, accessToken: accessToken) {
                resolved[handle] = profile
            }
        }

        // Whatever X did not answer for is not worth asking about again.
        unresolvableUsernames.formUnion(wanted.subtracting(resolved.keys))
        return resolved
    }

    private func fetchProfilesPage(
        _ usernames: [String],
        accessToken: String
    ) async throws -> [String: XUserProfile] {
        var components = URLComponents(string: "https://api.x.com/2/users/by")!
        components.queryItems = [
            URLQueryItem(name: "usernames", value: usernames.joined(separator: ",")),
            URLQueryItem(name: "user.fields", value: "name,username,profile_image_url"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw XBookmarkError.apiFailed("Invalid response")
        }
        if httpResponse.statusCode == 401 {
            signOut()
            throw XBookmarkError.notSignedIn
        }
        try requireOK(httpResponse, data: data, endpoint: "users/by")

        // Handles that no longer exist come back under `errors` while the rest of
        // the batch still resolves, so a decode of `data` alone is the answer.
        let decoded = try JSONDecoder().decode(UsersResponse.self, from: data)
        var profiles: [String: XUserProfile] = [:]
        for user in decoded.data ?? [] {
            let handle = user.username.lowercased()
            guard !handle.isEmpty else { continue }
            profiles[handle] = XUserProfile(
                username: handle,
                name: user.name.trimmingCharacters(in: .whitespacesAndNewlines),
                // The API and the embed endpoint publish the same avatar at the
                // same thumbnail size, so both go through the one rule that
                // asks for the larger copy.
                avatarURL: XPostThreadService.displayAvatarURL(user.profileImageURL)
            )
        }
        return profiles
    }

    // MARK: - Post Text

    /// Full text for posts by id, including the long-form body X publishes as
    /// `note_tweet`.
    ///
    /// X's public embed endpoint — the route `XPostThreadService` captures a
    /// thread through — cuts long posts short and only flags that it did. This
    /// is the authenticated repair for those posts, so a captured thread holds
    /// the whole essay rather than its first 280 characters. One request covers
    /// a whole thread; callers ask only for the posts that came back truncated.
    func fetchPostTexts(forPostIDs ids: [String]) async throws -> [String: String] {
        let wanted = Array(Set(ids.filter { !$0.isEmpty }))
        guard !wanted.isEmpty else { return [:] }
        guard let oauthToken = KeychainService.xAccessToken, !oauthToken.isEmpty else {
            throw XBookmarkError.notSignedIn
        }
        try await refreshTokenIfNeeded()
        let accessToken = KeychainService.xAccessToken ?? oauthToken

        var texts: [String: String] = [:]
        for batch in wanted.chunked(intoBatchesOf: 100) {
            var components = URLComponents(string: "https://api.x.com/2/tweets")!
            components.queryItems = [
                URLQueryItem(name: "ids", value: batch.joined(separator: ",")),
                URLQueryItem(name: "tweet.fields", value: "text,note_tweet"),
            ]

            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw XBookmarkError.apiFailed("Invalid response")
            }
            if httpResponse.statusCode == 401 {
                signOut()
                throw XBookmarkError.notSignedIn
            }
            try requireOK(httpResponse, data: data, endpoint: "tweets")

            // Posts the account cannot read come back under `errors` while the
            // rest of the batch still resolves, so decoding `data` is the answer.
            let decoded = try JSONDecoder().decode(BookmarksResponse.self, from: data)
            for tweet in decoded.data ?? [] {
                let text = tweet.noteTweet?.text ?? tweet.text
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                texts[tweet.id] = text
            }
        }
        return texts
    }

    // MARK: - API Helpers

    /// Throws for any response that is not a 200, as the error the UI can act
    /// on. A 429 is X saying when to come back (`x-rate-limit-reset`) or, as
    /// `UsageCapExceeded`, that the app's monthly read allowance is spent. Both
    /// used to fall into the generic "try again later" — advice a Try Again
    /// button then made worse, since every early retry is another guaranteed
    /// failure against the same limit. The status and X's own title and detail
    /// are logged public: that line is what answers "why did the sync fail" from
    /// `log show` after the fact, and neither carries anything of the learner's.
    private func requireOK(_ response: HTTPURLResponse, data: Data, endpoint: String) throws {
        guard response.statusCode != 200 else { return }
        let body = String(data: data, encoding: .utf8) ?? ""
        logger.error("X \(endpoint, privacy: .public) failed: HTTP \(response.statusCode, privacy: .public) \(Self.errorSummary(fromBody: body), privacy: .public)")
        // 402 is X saying the developer app's pay-per-use credits are spent.
        // It used to read as a generic "try again later", which sent the
        // learner reconnecting an account that was never the problem.
        if response.statusCode == 402 {
            throw XBookmarkError.creditsDepleted
        }
        if let limit = Self.rateLimitError(
            status: response.statusCode,
            resetHeader: response.value(forHTTPHeaderField: "x-rate-limit-reset"),
            body: body
        ) {
            throw limit
        }
        throw XBookmarkError.apiFailed("HTTP \(response.statusCode): \(body.prefix(200))")
    }

    /// The error a 429 stands for, or nil for any other status. X answers a
    /// spent monthly allowance with the same status as a fifteen-minute window,
    /// telling them apart only in the body's `title`.
    nonisolated static func rateLimitError(status: Int, resetHeader: String?, body: String) -> XBookmarkError? {
        guard status == 429 else { return nil }
        if body.contains("UsageCapExceeded") { return .usageCapExceeded }
        return .rateLimited(resetAt: rateLimitReset(fromHeader: resetHeader))
    }

    /// `x-rate-limit-reset` is epoch seconds.
    nonisolated static func rateLimitReset(fromHeader header: String?) -> Date? {
        guard let header,
              let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// X's error bodies carry a `title` and a `detail` ("Too Many Requests";
    /// "Usage cap exceeded: Monthly product cap"); those are what a log line
    /// wants, not two hundred characters of JSON.
    nonisolated static func errorSummary(fromBody body: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
            return String(body.prefix(120))
        }
        let parts = ["title", "detail"].compactMap { object[$0] as? String }
        return parts.isEmpty ? String(body.prefix(120)) : parts.joined(separator: " · ")
    }

    private func fetchBookmarksPage(
        userId: String,
        accessToken: String,
        paginationToken: String?,
        pageSize: Int
    ) async throws -> ([XBookmark], String?) {
        var components = URLComponents(string: "https://api.x.com/2/users/\(userId)/bookmarks")!
        var queryItems = [
            URLQueryItem(name: "tweet.fields", value: "text,created_at,author_id,entities,note_tweet"),
            URLQueryItem(name: "expansions", value: "author_id"),
            URLQueryItem(name: "user.fields", value: "name,username"),
            URLQueryItem(name: "max_results", value: String(pageSize)),
        ]
        if let paginationToken {
            queryItems.append(URLQueryItem(name: "pagination_token", value: paginationToken))
        }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw XBookmarkError.apiFailed("Invalid response")
        }

        if httpResponse.statusCode == 401 {
            // If we were using bearer token (no OAuth), tell user to sign in via OAuth
            if KeychainService.xAccessToken == nil {
                logger.warning("Bearer token rejected for bookmarks — OAuth sign-in required")
                throw XBookmarkError.bearerTokenInsufficient
            }
            signOut()
            throw XBookmarkError.notSignedIn
        }

        if httpResponse.statusCode == 403 {
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.contains("client-not-enrolled") || body.contains("bookmark") {
                logger.error("X bookmarks failed: HTTP 403 \(Self.errorSummary(fromBody: body), privacy: .public)")
                throw XBookmarkError.appAccessUnavailable
            }
            try requireOK(httpResponse, data: data, endpoint: "bookmarks")
        }

        try requireOK(httpResponse, data: data, endpoint: "bookmarks")

        let decoded = try JSONDecoder().decode(BookmarksResponse.self, from: data)

        // Build author lookup from includes
        var authorMap: [String: (name: String, username: String)] = [:]
        for user in decoded.includes?.users ?? [] {
            authorMap[user.id] = (user.name, user.username)
        }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let bookmarks: [XBookmark] = (decoded.data ?? []).map { tweet in
            let author = authorMap[tweet.authorId ?? ""]
            // Prefer note_tweet for long tweets (>280 chars)
            let fullText = tweet.noteTweet?.text ?? tweet.text
            let tweetURLs = tweet.entities?.urls?.compactMap { $0.expandedURL } ?? []
            return XBookmark(
                tweetId: tweet.id,
                text: fullText,
                authorName: author?.name ?? "Unknown",
                authorUsername: author?.username ?? "unknown",
                createdAt: tweet.createdAt.flatMap { dateFormatter.date(from: $0) },
                urls: tweetURLs
            )
        }

        return (bookmarks, decoded.meta?.nextToken)
    }

    private func exchangeCodeForTokens(code: String, codeVerifier: String, redirectURI: String, clientId: String) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://api.x.com/2/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        request.httpBody = Self.formURLEncodedBody([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": codeVerifier,
            "client_id": clientId,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw XBookmarkError.authFailed("Token exchange failed: \(body.prefix(200))")
        }

        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    /// The signed-in X account: its id, which the bookmarks endpoint needs in
    /// its path, and its @handle, which Settings shows.
    struct CurrentUser: Sendable {
        let id: String
        let username: String?
    }

    private func fetchCurrentUser(token: String? = nil) async throws -> CurrentUser {
        let authToken: String
        if let token {
            authToken = token
        } else if let accessToken = KeychainService.xAccessToken {
            authToken = accessToken
        } else {
            throw XBookmarkError.notSignedIn
        }

        var request = URLRequest(url: URL(string: "https://api.x.com/2/users/me")!)
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw XBookmarkError.apiFailed("Failed to fetch user info")
        }
        if httpResponse.statusCode == 401 {
            signOut()
            throw XBookmarkError.sessionExpired
        }
        try requireOK(httpResponse, data: data, endpoint: "users/me")

        struct UserResponse: Decodable {
            struct UserData: Decodable {
                let id: String
                let username: String?
            }
            let data: UserData
        }
        let decoded = try JSONDecoder().decode(UserResponse.self, from: data)
        let username = decoded.data.username?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CurrentUser(id: decoded.data.id, username: username?.isEmpty == false ? username : nil)
    }

    // MARK: - PKCE Helpers

    private nonisolated func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private nonisolated func generateCodeChallenge(from verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncoded()
    }

    // MARK: - Form Encoding

    /// Percent-encodes an `application/x-www-form-urlencoded` body.
    /// `.urlQueryAllowed` leaves reserved characters like `+`, `&`, and `=`
    /// intact, so a `+` in a token or code would be decoded server-side as a
    /// space and corrupt the value. Escape everything except the unreserved
    /// set so every reserved character survives the round trip.
    private nonisolated static func formURLEncodedBody(_ parameters: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = parameters.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }
}

// MARK: - Response Models

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let tokenType: String
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case scope
    }
}

private struct BookmarksResponse: Decodable {
    let data: [TweetData]?
    let includes: Includes?
    let meta: Meta?

    struct TweetData: Decodable {
        let id: String
        let text: String
        let authorId: String?
        let createdAt: String?
        let entities: Entities?
        let noteTweet: NoteTweet?

        enum CodingKeys: String, CodingKey {
            case id, text, entities
            case authorId = "author_id"
            case createdAt = "created_at"
            case noteTweet = "note_tweet"
        }
    }

    struct NoteTweet: Decodable {
        let text: String
    }

    struct Entities: Decodable {
        let urls: [EntityURL]?
    }

    struct EntityURL: Decodable {
        let expandedURL: String?
        enum CodingKeys: String, CodingKey {
            case expandedURL = "expanded_url"
        }
    }

    struct Includes: Decodable {
        let users: [User]?
    }

    struct User: Decodable {
        let id: String
        let name: String
        let username: String
    }

    struct Meta: Decodable {
        let resultCount: Int?
        let nextToken: String?
        enum CodingKeys: String, CodingKey {
            case resultCount = "result_count"
            case nextToken = "next_token"
        }
    }
}

private struct UsersResponse: Decodable {
    let data: [User]?

    struct User: Decodable {
        let name: String
        let username: String
        let profileImageURL: String?

        enum CodingKeys: String, CodingKey {
            case name, username
            case profileImageURL = "profile_image_url"
        }
    }
}

private extension Array {
    /// X caps a `users/by` lookup at 100 handles per call.
    func chunked(intoBatchesOf size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - macOS Presentation Context

#if os(macOS)
private final class WindowPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    let window: NSWindow

    init(window: NSWindow) {
        self.window = window
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window
    }
}
#endif

// MARK: - Base64URL

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
// MARK: - Errors

enum XBookmarkError: LocalizedError, Equatable {
    case notSignedIn
    case sessionExpired
    case bearerTokenInsufficient
    case appAccessUnavailable
    case postingNotAuthorized
    case authFailed(String)
    case apiFailed(String)
    /// X answered 429 for a request window. `resetAt` is when the window
    /// reopens, when X said.
    case rateLimited(resetAt: Date?)
    /// X answered 429 with `UsageCapExceeded`: the app's monthly read
    /// allowance is spent, and no fifteen-minute wait changes that.
    case usageCapExceeded
    /// X answered 402 Payment Required: ForeverLM's developer app has spent
    /// its pay-per-use API credits. Every request fails until they are topped
    /// up in X's developer console; neither a retry nor a reconnect helps.
    case creditsDepleted

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in to X. Please sign in first."
        case .sessionExpired: return "Your X session has expired and could not be renewed. Reconnect to X to continue syncing bookmarks."
        case .bearerTokenInsufficient: return "Bearer token cannot access bookmarks. Please sign in with X using OAuth."
        case .appAccessUnavailable: return "ForeverLM's X bookmark access is temporarily unavailable. Please try again later or contact support."
        case .postingNotAuthorized: return "This X session cannot post. Reconnect to X (Plugins → X) to refresh its permission. If the problem continues, contact support."
        case .authFailed(let msg): return "X authentication failed: \(msg)"
        case .apiFailed(let msg): return "X API error: \(msg)"
        case .rateLimited(let resetAt):
            if let resetAt {
                return "X rate limit reached; the window reopens at \(resetAt.formatted(date: .omitted, time: .shortened))."
            }
            return "X rate limit reached."
        case .usageCapExceeded: return "X monthly usage cap exceeded for this app."
        case .creditsDepleted: return "X API credits depleted for this app (HTTP 402)."
        }
    }

    /// Converts transport and API failures into concise recovery guidance for
    /// plugin UI. Keep `localizedDescription` for diagnostics only: it can
    /// contain TLS terminology, HTTP bodies, and other implementation details
    /// that are neither useful nor appropriate in a toast or settings card.
    nonisolated static func userFacingMessage(for error: Error, action: UserAction) -> String {
        if let urlCode = urlErrorCode(for: error) {
            switch urlCode {
            case .notConnectedToInternet,
                 .dataNotAllowed,
                 .internationalRoamingOff:
                return "You’re offline. Connect to the internet, then try again."

            case .timedOut:
                return "X took too long to respond. Try again."

            case .networkConnectionLost:
                return "The connection to X was interrupted. Try again."

            case .cannotFindHost,
                 .cannotConnectToHost,
                 .dnsLookupFailed:
                return "Couldn’t reach X. Check your internet connection, then try again."

            case .secureConnectionFailed,
                 .serverCertificateHasBadDate,
                 .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid,
                 .clientCertificateRejected,
                 .clientCertificateRequired,
                 .appTransportSecurityRequiresSecureConnection:
                return "Couldn’t securely connect to X. Check your internet connection and your device’s date and time, then try again."

            case .cancelled:
                return action == .connect
                    ? "Connecting to X was canceled."
                    : "X bookmark sync was canceled."

            default:
                return action.fallbackMessage
            }
        }

        guard let xError = error as? XBookmarkError else {
            return action.fallbackMessage
        }
        switch xError {
        case .notSignedIn:
            return "Reconnect to X to sync bookmarks."
        case .sessionExpired:
            return "Your X session expired. Reconnect to keep syncing bookmarks."
        case .bearerTokenInsufficient:
            return "Reconnect to X to sync bookmarks."
        case .appAccessUnavailable:
            return "X bookmark access is temporarily unavailable. Try again later."
        case .postingNotAuthorized:
            return "Reconnect to X to allow posting."
        case .authFailed:
            return "Couldn’t connect to X. Try again."
        case .apiFailed:
            return action == .connect
                ? "Couldn’t connect to X. Try again later."
                : "X bookmarks couldn’t be synced right now. Try again later."
        case .rateLimited(let resetAt):
            return rateLimitedMessage(resetAt: resetAt, action: action)
        case .usageCapExceeded:
            return action == .connect
                ? "ForeverLM has used up its monthly allowance of X requests. Try again after X resets it."
                : "ForeverLM has used up its monthly allowance of X reads. Bookmarks sync again once X resets it."
        case .creditsDepleted:
            return action == .connect
                ? "ForeverLM’s X API credits have run out, so X can’t be connected right now. Reconnecting won’t help until they’re topped up."
                : "ForeverLM’s X API credits have run out, so bookmarks can’t sync until they’re topped up. Reconnecting won’t help."
        }
    }

    /// Whether reconnecting X is worth offering beside a retry for this
    /// failure. A failure X explained as a limit, a spent allowance, or a
    /// network problem is not about the learner's session, and a Reconnect
    /// button beside it would send them through a sign-in that changes
    /// nothing. Every other failure — an auth error, or an HTTP status X did
    /// not explain — may be a token X no longer honours, so the learner gets
    /// the one fix within their reach instead of only "try again later".
    nonisolated static func reconnectMayHelp(after error: Error) -> Bool {
        if urlErrorCode(for: error) != nil { return false }
        guard let xError = error as? XBookmarkError else { return true }
        switch xError {
        case .appAccessUnavailable, .rateLimited, .usageCapExceeded, .creditsDepleted:
            return false
        case .notSignedIn, .sessionExpired, .bearerTokenInsufficient, .postingNotAuthorized,
             .authFailed, .apiFailed:
            return true
        }
    }

    /// A rate limit is a wait with a known end, so the message names the end
    /// rather than inviting a retry that X has already refused.
    nonisolated static func rateLimitedMessage(resetAt: Date?, action: UserAction, now: Date = Date()) -> String {
        let subject = action == .connect ? "requests" : "bookmark reads"
        guard let resetAt, resetAt > now else {
            return "X is limiting \(subject) right now. Try again in a few minutes."
        }
        let time = resetAt.formatted(date: .omitted, time: .shortened)
        return action == .connect
            ? "X is limiting \(subject) right now. Try again after \(time)."
            : "X is limiting \(subject) right now. ForeverLM will sync again at \(time)."
    }

    enum UserAction: Sendable {
        case connect
        case syncBookmarks

        fileprivate var fallbackMessage: String {
            switch self {
            case .connect:
                return "Couldn’t connect to X. Try again."
            case .syncBookmarks:
                return "X bookmarks couldn’t be synced. Try again."
            }
        }
    }

    private nonisolated static func urlErrorCode(for error: Error) -> URLError.Code? {
        if let urlError = error as? URLError {
            return urlError.code
        }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return nil }
        return URLError.Code(rawValue: nsError.code)
    }
}
