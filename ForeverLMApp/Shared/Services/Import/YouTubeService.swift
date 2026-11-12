import CryptoKit
import Foundation
import Network
import OSLog
import Security
import AppKit

enum YouTubeServiceError: LocalizedError {
    case missingClientID
    case missingClientSecret
    case invalidClientID(String)
    case notSignedIn
    case authFailed(String)
    case dataAPINotEnabled(enableURL: String)
    case apiFailed(String)

    /// When set, Settings can offer a one-click link to fix the problem in Google Cloud.
    var enableURL: String? {
        if case .dataAPINotEnabled(let url) = self { return url }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "This build of ForeverLM has no YouTube OAuth client configured, so YouTube cannot be connected."
        case .missingClientSecret:
            return "This build of ForeverLM has no YouTube OAuth client secret configured, so YouTube cannot be connected."
        case .invalidClientID(let message):
            return message
        case .notSignedIn:
            return "Not signed in to YouTube."
        case .authFailed(let message):
            return "YouTube authentication failed: \(message)"
        case .dataAPINotEnabled:
            return "YouTube Data API v3 is not enabled for ForeverLM's Google Cloud project. This is a ForeverLM configuration problem, not something you can fix — please report it."
        case .apiFailed(let message):
            return message
        }
    }
}

/// Read-only YouTube Data API plugin. Authenticates against ForeverLM's own
/// Google OAuth client (`GoogleOAuthClient.appOwnedYouTube`), requests the
/// `youtube.readonly` scope, and stores its own tokens, so signing into one
/// plugin does not affect the other. Any number of Google accounts can be
/// connected (`YouTubeAccount`); every private read names its account. Used
/// only to import an account's private Liked-videos feed, its playlist named
/// "ForeverLM", or to find a public video when Apple does not expose a
/// podcast transcript.
actor YouTubeService {
    static let shared = YouTubeService()

    private let logger = Logger(subsystem: "com.foreverlm", category: "YouTubeService")
    private let callbackPath = "youtube-oauth"
    /// The only scope a YouTube connection asks for. Kept alone in its request —
    /// see `authorizationURL`.
    nonisolated static let authorizationScope = "https://www.googleapis.com/auth/youtube.readonly"

    /// The canonical URL ForeverLM uses to represent the signed-in user's
    /// "Liked videos" feed as a plugin group. The feed itself is private, so
    /// it is imported through the authenticated Data API (`listLikedVideos`),
    /// never the keyless playlist scraper — but a stable URL keeps the group id
    /// consistent between the app and MCP.
    static let likedVideosPlaylistURL = "https://www.youtube.com/playlist?list=LL"
    static let foreverLMPlaylistName = "ForeverLM"

    /// Serializes read-modify-write of the account list, which the app and MCP
    /// both write from any thread.
    private nonisolated static let accountListLock = NSLock()

    /// Every account the plugin holds, in the order they were connected,
    /// including ones whose grant Google revoked.
    nonisolated var accounts: [YouTubeAccount] {
        YouTubeAccountList.decode(KeychainService.youtubeAccounts)
    }

    /// The accounts that can make a request now.
    nonisolated var connectedAccounts: [YouTubeAccount] {
        accounts.filter(Self.hasStoredCredential)
    }

    nonisolated var isSignedIn: Bool {
        !connectedAccounts.isEmpty
    }

    nonisolated func snapshot() -> YouTubeAccountSnapshot {
        let listed = accounts
        return YouTubeAccountSnapshot(
            accounts: listed,
            disconnectedIDs: Set(listed.filter { !Self.hasStoredCredential($0) }.map(\.id))
        )
    }

    private nonisolated static func hasStoredCredential(_ account: YouTubeAccount) -> Bool {
        KeychainService.youtubeCredential(field: .accessToken, accountID: account.id)?.isEmpty == false
            || KeychainService.youtubeCredential(field: .refreshToken, accountID: account.id)?.isEmpty == false
    }

    /// Disconnect one account: its grant and everything it chose go.
    nonisolated func signOut(accountID: String) {
        Self.accountListLock.lock()
        KeychainService.deleteYouTubeCredentials(accountID: accountID)
        KeychainService.youtubeAccounts = YouTubeAccountList.encode(
            YouTubeAccountList.removing(id: accountID, from: accounts)
        )
        Self.accountListLock.unlock()
        Self.notifyConnectionChanged()
    }

    /// Store what one account imports. The account's grant is untouched.
    @discardableResult
    nonisolated func setChoices(_ choices: YouTubeImportChoices, forAccount accountID: String) -> YouTubeAccount? {
        Self.accountListLock.lock()
        defer { Self.accountListLock.unlock() }
        let updated = YouTubeAccountList.setting(choices, forAccount: accountID, in: accounts)
        guard updated.contains(where: { $0.id == accountID }) else { return nil }
        KeychainService.youtubeAccounts = YouTubeAccountList.encode(updated)
        return updated.first { $0.id == accountID }
    }

    /// Announce a sign-in state change so settings UI refreshes its cached chip.
    nonisolated static func notifyConnectionChanged() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .pluginConnectionChanged, object: nil)
        }
    }

    /// Whether a connection can be started at all — true once the app ships its
    /// own client, or while the user still has Drive credentials from the older
    /// bring-your-own-client setup.
    nonisolated var canConnect: Bool {
        GoogleOAuthClient.youtubeAuthorization() != nil
    }

    /// Public-data calls (channel lookup, uploads, video details, search) need
    /// a token but not a particular account, so the first connected account
    /// lends its own: the same one every time, and the next one once Google
    /// revokes it.
    private nonisolated func publicRequestAccountID() throws -> String {
        guard let account = connectedAccounts.first else { throw YouTubeServiceError.notSignedIn }
        return account.id
    }

    /// Drop only the cached access token so the next request refreshes it.
    /// Keeps the refresh token, so the connection itself survives.
    private nonisolated func invalidateAccessToken(accountID: String) {
        KeychainService.deleteYouTubeCredential(field: .accessToken, accountID: accountID)
        KeychainService.deleteYouTubeCredential(field: .tokenExpiry, accountID: accountID)
    }

    /// Google revoked the grant: the account stays listed (with what it
    /// imports) but holds no credentials until the learner reconnects it.
    private nonisolated func dropCredentials(accountID: String) {
        KeychainService.deleteYouTubeCredentials(accountID: accountID)
        Self.notifyConnectionChanged()
    }

    /// Connect a Google account. Connecting one that is already listed
    /// replaces its grant (the way a revoked grant is repaired) and keeps what
    /// it imports; any other account is added beside the rest.
    @MainActor
    @discardableResult
    func authenticate(
        clientID explicitClientID: String? = nil,
        clientSecret explicitClientSecret: String? = nil
    ) async throws -> YouTubeAccount {
        let explicit = GoogleOAuthCredentials(
            clientID: explicitClientID,
            clientSecret: explicitClientSecret
        )
        guard let credentials = GoogleOAuthClient.youtubeAuthorization(explicit: explicit) else {
            throw YouTubeServiceError.missingClientID
        }
        let clientID = credentials.clientID
        let clientSecret = credentials.clientSecret

        if let validationMessage = validateClientID(clientID) {
            throw YouTubeServiceError.invalidClientID(validationMessage)
        }

        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)
        let state = UUID().uuidString
        let callbackServer = try GoogleOAuthCallbackServer(serviceName: "YouTube", callbackPath: "/\(callbackPath)")
        try await callbackServer.start()
        let redirectURI = callbackServer.redirectURI

        guard let authURL = Self.authorizationURL(
            clientID: clientID,
            redirectURI: redirectURI,
            codeChallenge: codeChallenge,
            state: state
        ) else {
            throw YouTubeServiceError.authFailed("Could not construct the Google authorization URL.")
        }

        let callbackTask = Task {
            try await callbackServer.waitForCallback(timeout: 300)
        }
        defer {
            callbackTask.cancel()
            callbackServer.stop()
        }

        guard NSWorkspace.shared.open(authURL) else {
            throw YouTubeServiceError.authFailed("Could not open the browser sign-in page.")
        }

        do {
            let callbackURL = try await callbackTask.value

            guard let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                  let code = callbackComponents.queryItems?.first(where: { $0.name == "code" })?.value,
                  let returnedState = callbackComponents.queryItems?.first(where: { $0.name == "state" })?.value,
                  returnedState == state else {
                let error = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "error" })?
                    .value
                throw YouTubeServiceError.authFailed(error ?? "Invalid callback")
            }

            let tokens = try await exchangeCodeForTokens(
                code: code,
                codeVerifier: codeVerifier,
                redirectURI: redirectURI,
                clientID: clientID,
                clientSecret: clientSecret
            )
            guard let accessToken = tokens.accessToken, !accessToken.isEmpty else {
                throw YouTubeServiceError.authFailed("Google returned no access token.")
            }
            let channel = try await ownChannel(accessToken: accessToken)
            let account = register(channel: channel, tokens: tokens, issuedBy: credentials)
            Self.notifyConnectionChanged()
            callbackServer.completeBrowserCallback(
                success: true,
                message: "You can close this tab and return to ForeverLM."
            )
            logger.info("Authenticated a YouTube account")
            return account
        } catch {
            callbackServer.completeBrowserCallback(
                success: false,
                message: error.localizedDescription
            )
            throw error
        }
    }

    // MARK: - Video feeds

    /// Search public YouTube videos for a podcast episode whose Apple transcript
    /// is inaccessible. Search results are only candidates: the learner must
    /// choose one before its captions can be attached to the podcast source.
    func searchVideos(query: String, maxResults: Int = 5) async throws -> [YouTubeVideoSearchResult] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else { return [] }

        guard let url = Self.videoSearchURL(query: cleanQuery, maxResults: maxResults) else {
            throw YouTubeServiceError.apiFailed("Could not construct the YouTube search request.")
        }
        let decoded: VideoSearchResponse = try await getJSON(url: url, accountID: try publicRequestAccountID())
        return Self.videoSearchResults(from: decoded)
    }

    /// Public videos by id, in the order asked; one a private or removed id
    /// names is left out. One quota unit for up to fifty, where a search costs
    /// a hundred, and a video is answered the moment it is up, where search
    /// lags new uploads by hours.
    func videos(ids: [String]) async throws -> [YouTubeVideoSearchResult] {
        var seen = Set<String>()
        let wanted = Array(ids.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(50))
        guard !wanted.isEmpty else { return [] }
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "id", value: wanted.joined(separator: ",")),
        ]
        let decoded: VideoListResponse = try await getJSON(url: components.url!, accountID: try publicRequestAccountID())
        return Self.videoListResults(from: decoded, orderedBy: wanted)
    }

    nonisolated static func videoListResults(
        from response: VideoListResponse,
        orderedBy ids: [String]
    ) -> [YouTubeVideoSearchResult] {
        var byID: [String: YouTubeVideoSearchResult] = [:]
        for item in response.items ?? [] {
            guard let videoID = item.id, !videoID.isEmpty, byID[videoID] == nil,
                  let title = item.snippet?.title, !title.isEmpty else { continue }
            byID[videoID] = YouTubeVideoSearchResult(
                videoId: videoID,
                title: title.decodingHTMLCharacterReferences(),
                channelTitle: item.snippet?.channelTitle?.decodingHTMLCharacterReferences(),
                description: item.snippet?.description?.decodingHTMLCharacterReferences(),
                publishedAt: item.snippet?.publishedAt.flatMap(Self.parseAPIDate),
                channelId: item.snippet?.channelId
            )
        }
        return ids.compactMap { byID[$0] }
    }

    /// The Google consent URL for a YouTube connection.
    ///
    /// `include_granted_scopes` is deliberately `false`. Incremental
    /// authorization re-requests every scope the account already granted this
    /// OAuth client, and Google rejects the whole request when the resulting set
    /// mixes `youtube.readonly` with Drive's per-file `drive.file`:
    ///
    ///     Error 400: invalid_request
    ///     This request contains scopes that cannot be requested together:
    ///     [.../youtube.readonly, .../drive.file]
    ///
    /// A learner who had connected Google Drive first therefore could not
    /// connect YouTube at all — including from "Find on YouTube" on a podcast
    /// with no Apple transcript. Nothing here needs incremental authorization:
    /// each plugin stores its own tokens and this one only ever calls the
    /// YouTube Data API. `GoogleDriveService` holds both of its authorizations
    /// apart for the same reason.
    nonisolated static func authorizationURL(
        clientID: String,
        redirectURI: String,
        codeChallenge: String,
        state: String
    ) -> URL? {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: authorizationScope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "include_granted_scopes", value: "false"),
            URLQueryItem(name: "prompt", value: "consent select_account"),
        ]
        return components?.url
    }

    /// Deliberately unfiltered by caption availability: the Data API's
    /// `videoCaption=closedCaption` filter only matches uploader-supplied
    /// caption tracks, so it hides the podcast uploads whose captions are
    /// auto-generated — exactly the videos the transcript importer reads fine.
    /// An import that turns out to have no captions fails visibly instead.
    nonisolated static func videoSearchURL(query: String, maxResults: Int) -> URL? {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")
        components?.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(min(max(maxResults, 1), 10))),
        ]
        return components?.url
    }

    nonisolated static func videoSearchResults(
        from response: VideoSearchResponse
    ) -> [YouTubeVideoSearchResult] {
        (response.items ?? []).compactMap { item in
            guard let videoID = item.id?.videoId, !videoID.isEmpty,
                  let title = item.snippet?.title, !title.isEmpty else { return nil }
            return YouTubeVideoSearchResult(
                videoId: videoID,
                title: title.decodingHTMLCharacterReferences(),
                channelTitle: item.snippet?.channelTitle?.decodingHTMLCharacterReferences(),
                description: item.snippet?.description?.decodingHTMLCharacterReferences(),
                publishedAt: item.snippet?.publishedAt.flatMap(Self.parseAPIDate),
                channelId: item.snippet?.channelId
            )
        }
    }

    /// The account's private "Liked videos" playlist id, read from the
    /// channel's `relatedPlaylists.likes`.
    func likedVideosPlaylistID(accountID: String) async throws -> String {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/channels")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "contentDetails"),
            URLQueryItem(name: "mine", value: "true"),
        ]
        let decoded: ChannelListResponse = try await getJSON(url: components.url!, accountID: accountID)
        guard let likes = decoded.items?.first?.contentDetails?.relatedPlaylists?.likes,
              !likes.isEmpty else {
            throw YouTubeServiceError.apiFailed("Could not find your Liked videos playlist.")
        }
        return likes
    }

    /// Fetch an account's liked videos, newest first. The Liked-videos
    /// feed is private, so this uses the authenticated Data API rather than the
    /// keyless playlist path. Deleted/private entries are skipped.
    func listLikedVideos(accountID: String, maxCount: Int = .max) async throws -> [YouTubePlaylistItem] {
        try await listLikedVideosFeed(accountID: accountID, maxCount: maxCount).items
    }

    /// As `listLikedVideos`, but also reports whether the whole feed was read.
    /// `isComplete` is false when the fetch stopped at `maxCount` with pages
    /// still upstream — callers that archive rows for being absent from the
    /// feed must not treat a truncated fetch as the full picture, or a video
    /// that is merely old gets archived (which deletes its transcript) while
    /// still liked.
    func listLikedVideosFeed(
        accountID: String,
        maxCount: Int = .max
    ) async throws -> (items: [YouTubePlaylistItem], isComplete: Bool) {
        let playlistID = try await likedVideosPlaylistID(accountID: accountID)
        let playlistFeed = try await listPlaylistFeed(playlistID: playlistID, maxCount: maxCount, accountID: accountID)

        // Google documents `videos.list?myRating=like` as a second, direct way
        // to retrieve the authenticated user's positive ratings. In practice it
        // can expose a brand-new like before the channel's generated Liked
        // playlist does. Union both official views so a scroll-to-top refresh
        // cannot miss that window; only call a feed complete when both were read
        // to the end, which keeps absence-based archiving conservative.
        do {
            let ratedFeed = try await listPositivelyRatedVideosFeed(maxCount: maxCount, accountID: accountID)
            return Self.mergeLikedVideoFeeds(playlist: playlistFeed, ratings: ratedFeed)
        } catch {
            logger.warning("Direct YouTube ratings lookup failed; using the Liked playlist: \(error.localizedDescription)")
            return playlistFeed
        }
    }

    nonisolated static func mergeLikedVideoFeeds(
        playlist: (items: [YouTubePlaylistItem], isComplete: Bool),
        ratings: (items: [YouTubePlaylistItem], isComplete: Bool)
    ) -> (items: [YouTubePlaylistItem], isComplete: Bool) {
        let playlistByID = playlist.items.reduce(into: [String: YouTubePlaylistItem]()) {
            $0[$1.videoId] = $1
        }
        var seen = Set<String>()
        var merged: [YouTubePlaylistItem] = []
        merged.reserveCapacity(max(playlist.items.count, ratings.items.count))

        // Ratings-only entries are the fresh-data gap this union is meant to
        // close. Prefer playlist metadata when both feeds know the video because
        // only playlistItem.snippet carries the actual liked timestamp.
        for rated in ratings.items {
            guard seen.insert(rated.videoId).inserted else { continue }
            merged.append(playlistByID[rated.videoId] ?? rated)
        }
        for playlistItem in playlist.items where seen.insert(playlistItem.videoId).inserted {
            merged.append(playlistItem)
        }
        return (merged, playlist.isComplete && ratings.isComplete)
    }

    /// Retrieve the user's positive ratings directly rather than through the
    /// channel-generated Liked playlist. Video resources do not expose when the
    /// rating was added, so `likedAt` remains nil for ratings-only entries and is
    /// filled from the playlist view by `mergeLikedVideoFeeds` whenever possible.
    private func listPositivelyRatedVideosFeed(
        maxCount: Int,
        accountID: String
    ) async throws -> (items: [YouTubePlaylistItem], isComplete: Bool) {
        var items: [YouTubePlaylistItem] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")!
            var queryItems = [
                URLQueryItem(name: "part", value: "snippet"),
                URLQueryItem(name: "myRating", value: "like"),
                URLQueryItem(name: "maxResults", value: "50"),
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = queryItems

            let decoded: RatedVideosResponse = try await getJSON(url: components.url!, accountID: accountID)
            for item in decoded.items ?? [] {
                guard let videoID = item.id, !videoID.isEmpty,
                      let title = item.snippet?.title, !title.isEmpty else { continue }
                items.append(YouTubePlaylistItem(
                    videoId: videoID,
                    title: title,
                    playlistIndex: items.count + 1,
                    channelTitle: item.snippet?.channelTitle,
                    videoPublishedAt: item.snippet?.publishedAt.flatMap(Self.parseAPIDate)
                ))
                if items.count >= maxCount { break }
            }
            pageToken = decoded.nextPageToken
        } while pageToken != nil && items.count < maxCount

        return (items, pageToken == nil)
    }

    /// Find the account's playlist named exactly "ForeverLM". Matching
    /// ignores case and surrounding whitespace, but ambiguity fails loudly so
    /// the plugin never silently follows the wrong playlist.
    func foreverLMPlaylist(accountID: String) async throws -> YouTubePluginPlaylist {
        var matches: [YouTubePluginPlaylist] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/playlists")!
            var queryItems = [
                URLQueryItem(name: "part", value: "snippet"),
                URLQueryItem(name: "mine", value: "true"),
                URLQueryItem(name: "maxResults", value: "50"),
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = queryItems

            let decoded: PlaylistsResponse = try await getJSON(url: components.url!, accountID: accountID)
            matches.append(contentsOf: (decoded.items ?? []).compactMap { item in
                guard let id = item.id, !id.isEmpty,
                      let title = item.snippet?.title,
                      Self.isForeverLMPlaylistTitle(title) else { return nil }
                return YouTubePluginPlaylist(id: id, title: Self.foreverLMPlaylistName)
            })
            pageToken = decoded.nextPageToken
        } while pageToken != nil

        guard let playlist = matches.first else {
            throw YouTubeServiceError.apiFailed(
                "No YouTube playlist named \"ForeverLM\" was found. Create it in YouTube, then try again."
            )
        }
        guard matches.count == 1 else {
            throw YouTubeServiceError.apiFailed(
                "More than one YouTube playlist is named \"ForeverLM\". Rename the extras, then try again."
            )
        }
        return playlist
    }

    /// Fetch every currently visible item in the account's ForeverLM
    /// playlist. Deleted/private entries are skipped, matching Liked videos.
    func listForeverLMPlaylistFeed(
        accountID: String,
        maxCount: Int = .max
    ) async throws -> (playlist: YouTubePluginPlaylist, items: [YouTubePlaylistItem], isComplete: Bool) {
        let playlist = try await foreverLMPlaylist(accountID: accountID)
        let feed = try await listPlaylistFeed(playlistID: playlist.id, maxCount: maxCount, accountID: accountID)
        return (playlist: playlist, items: feed.items, isComplete: feed.isComplete)
    }

    // MARK: - Channels

    /// What a learner can paste to follow a channel: a handle, a channel id, or
    /// one of YouTube's older custom addresses.
    enum ChannelReference: Equatable, Sendable {
        /// `@handle`, without the `@`.
        case handle(String)
        /// A `UC…` channel id.
        case id(String)
        /// The name from a `/c/<name>` or `/user/<name>` address.
        case username(String)
    }

    struct Channel: Equatable, Sendable {
        let id: String
        let title: String
        /// The channel's uploads playlist, which every channel has: its id is
        /// the channel id with `UC` swapped for `UU`.
        let uploadsPlaylistID: String

        var uploadsPlaylistURL: String { YouTubeService.playlistURL(forID: uploadsPlaylistID) }
    }

    /// Reads a channel out of whatever was pasted: `@handle`, a bare `UC…` id,
    /// or a youtube.com address of the `/@handle`, `/channel/UC…`, `/c/<name>`
    /// or `/user/<name>` form, with or without a scheme. Nil for anything else,
    /// a video or playlist link included.
    nonisolated static func channelReference(from input: String) -> ChannelReference? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("@") {
            return handleReference(String(text.dropFirst()))
        }
        if isChannelID(text) { return .id(text) }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text),
              let host = url.host?.lowercased(),
              host == "youtube.com" || host.hasSuffix(".youtube.com") else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard let first = parts.first else { return nil }
        if first.hasPrefix("@") {
            return handleReference(String(first.dropFirst()))
        }
        if first == "channel", parts.count >= 2, isChannelID(parts[1]) {
            return .id(parts[1])
        }
        if first == "c" || first == "user", parts.count >= 2 {
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : .username(name)
        }
        return nil
    }

    private nonisolated static func handleReference(_ raw: String) -> ChannelReference? {
        let handle = raw.split(separator: "/").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return handle.isEmpty ? nil : .handle(handle)
    }

    nonisolated static func isChannelID(_ value: String) -> Bool {
        value.count == 24 && value.hasPrefix("UC")
            && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    nonisolated static func uploadsPlaylistID(forChannelID channelID: String) -> String {
        "UU" + channelID.dropFirst(2)
    }

    nonisolated static func playlistURL(forID id: String) -> String {
        "https://www.youtube.com/playlist?list=\(id)"
    }

    /// The `list` id in a playlist address, or nil when there is none.
    nonisolated static func playlistID(fromPlaylistURL url: String) -> String? {
        URLComponents(string: url)?.queryItems?.first { $0.name == "list" }?.value
    }

    /// Resolve a pasted channel reference through the Data API. A bare channel name
    /// is tried as a username first and as a handle second, since channels
    /// have kept the same word for both.
    func resolveChannel(_ reference: ChannelReference) async throws -> Channel {
        let lookups: [(parameter: String, value: String)]
        switch reference {
        case .handle(let handle): lookups = [("forHandle", handle)]
        case .id(let id): lookups = [("id", id)]
        case .username(let name): lookups = [("forUsername", name), ("forHandle", name)]
        }
        for lookup in lookups {
            var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/channels")!
            components.queryItems = [
                URLQueryItem(name: "part", value: "snippet,contentDetails"),
                URLQueryItem(name: lookup.parameter, value: lookup.value),
                URLQueryItem(name: "maxResults", value: "1"),
            ]
            let decoded: ChannelListResponse = try await getJSON(url: components.url!, accountID: try publicRequestAccountID())
            guard let item = decoded.items?.first, let id = item.id, !id.isEmpty else { continue }
            let title = item.snippet?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let uploads = item.contentDetails?.relatedPlaylists?.uploads ?? Self.uploadsPlaylistID(forChannelID: id)
            return Channel(id: id, title: title.isEmpty ? id : title, uploadsPlaylistID: uploads)
        }
        throw YouTubeServiceError.apiFailed("No YouTube channel matches that address.")
    }

    /// A channel's uploads, newest first, capped at `maxCount` — the plugin
    /// follows the top of the feed, not the whole catalog.
    func listChannelUploadsFeed(
        uploadsPlaylistID: String,
        maxCount: Int
    ) async throws -> (items: [YouTubePlaylistItem], isComplete: Bool) {
        try await listPlaylistFeed(playlistID: uploadsPlaylistID, maxCount: maxCount, accountID: try publicRequestAccountID())
    }

    nonisolated static func isForeverLMPlaylistTitle(_ title: String) -> Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare(foreverLMPlaylistName) == .orderedSame
    }

    private func listPlaylistFeed(
        playlistID: String,
        maxCount: Int,
        accountID: String
    ) async throws -> (items: [YouTubePlaylistItem], isComplete: Bool) {
        var items: [YouTubePlaylistItem] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/playlistItems")!
            var queryItems = [
                // `contentDetails` costs no extra quota on this endpoint and is
                // the only source of the video's own publish date. The liked date
                // is `snippet.publishedAt` — when the item entered the playlist —
                // not to be confused with the video's publication date.
                URLQueryItem(name: "part", value: "snippet,contentDetails"),
                URLQueryItem(name: "playlistId", value: playlistID),
                URLQueryItem(name: "maxResults", value: "50"),
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = queryItems

            let decoded: PlaylistItemsResponse = try await getJSON(url: components.url!, accountID: accountID)
            for item in decoded.items ?? [] {
                guard let videoID = item.snippet?.resourceId?.videoId, !videoID.isEmpty,
                      let title = item.snippet?.title,
                      title != "Deleted video", title != "Private video" else { continue }
                items.append(YouTubePlaylistItem(
                    videoId: videoID,
                    title: title,
                    playlistIndex: item.snippet?.position.map { $0 + 1 },
                    channelTitle: item.snippet?.videoOwnerChannelTitle,
                    likedAt: item.snippet?.publishedAt.flatMap(Self.parseAPIDate),
                    videoPublishedAt: item.contentDetails?.videoPublishedAt.flatMap(Self.parseAPIDate)
                ))
            }
            pageToken = decoded.nextPageToken
        } while pageToken != nil && items.count < maxCount

        // Exiting with a page token still in hand means the cap stopped us, not
        // the end of the feed.
        return (items: items, isComplete: pageToken == nil)
    }

    /// Parse an RFC 3339 timestamp from the Data API. YouTube returns both
    /// `2024-03-15T10:30:00Z` and the fractional-seconds form depending on the
    /// field, and `ISO8601DateFormatter` rejects whichever one it wasn't
    /// configured for — so try both rather than dropping the date.
    nonisolated static func parseAPIDate(_ raw: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) { return date }
        return KnowledgeStore.iso8601Formatter.date(from: raw)
    }

    // MARK: - Networking

    private func getJSON<T: Decodable>(url: URL, accountID: String) async throws -> T {
        var (data, http) = try await performAuthorizedGET(url: url, accountID: accountID)
        if http.statusCode == 401 {
            // Google rejected the stored access token; refresh and retry once
            // instead of treating a lone 401 as a lost connection.
            invalidateAccessToken(accountID: accountID)
            (data, http) = try await performAuthorizedGET(url: url, accountID: accountID)
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw Self.mapAPIError(statusCode: http.statusCode, body: body)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func performAuthorizedGET(url: URL, accountID: String) async throws -> (Data, HTTPURLResponse) {
        var request = try await authorizedRequest(url: url, accountID: accountID)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw YouTubeServiceError.apiFailed("Invalid response")
        }
        return (data, http)
    }

    /// Turn Google API JSON error bodies into actionable messages instead of raw HTTP dumps.
    private static func mapAPIError(statusCode: Int, body: String) -> YouTubeServiceError {
        let parsed = GoogleAPIErrorEnvelope.parse(body)
        if statusCode == 403, parsed.isYouTubeAPINotEnabled {
            return .dataAPINotEnabled(enableURL: parsed.enableURL ?? defaultYouTubeAPIEnableURL)
        }
        if parsed.reasons.contains("quotaExceeded") {
            return .apiFailed("YouTube API quota exceeded. Try again later.")
        }
        if let message = parsed.message, !message.isEmpty {
            return .apiFailed(message)
        }
        if statusCode == 403 {
            return .dataAPINotEnabled(enableURL: defaultYouTubeAPIEnableURL)
        }
        return .apiFailed("YouTube request failed (HTTP \(statusCode)). Check your Google Cloud project setup and try again.")
    }

    private static let defaultYouTubeAPIEnableURL =
        "https://console.cloud.google.com/apis/library/youtube.googleapis.com"

    private func authorizedRequest(url: URL, accountID: String) async throws -> URLRequest {
        let token = try await accessToken(accountID: accountID)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("ForeverLM", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func accessToken(accountID: String) async throws -> String {
        if let expiry = KeychainService.youtubeCredential(field: .tokenExpiry, accountID: accountID),
           let expiryDate = KnowledgeStore.iso8601Formatter.date(from: expiry),
           expiryDate.timeIntervalSinceNow > 60,
           let accessToken = KeychainService.youtubeCredential(field: .accessToken, accountID: accountID),
           !accessToken.isEmpty {
            return accessToken
        }

        if let refreshToken = KeychainService.youtubeCredential(field: .refreshToken, accountID: accountID),
           !refreshToken.isEmpty {
            let tokens = try await refreshAccessToken(accountID: accountID, refreshToken: refreshToken)
            store(tokens: tokens, accountID: accountID)
            if let accessToken = tokens.accessToken {
                return accessToken
            }
        }

        throw YouTubeServiceError.notSignedIn
    }

    /// The signed-in account's own channel: its id names the account, its
    /// title labels it. One quota unit, and inside `youtube.readonly`.
    private func ownChannel(accessToken: String) async throws -> (id: String, title: String) {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/channels")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "mine", value: "true"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("ForeverLM", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw YouTubeServiceError.apiFailed("Invalid response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapAPIError(statusCode: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(ChannelListResponse.self, from: data)
        guard let channel = decoded.items?.first, let id = channel.id, !id.isEmpty else {
            throw YouTubeServiceError.apiFailed("This Google account has no YouTube channel to connect.")
        }
        let title = channel.snippet?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (id, title.isEmpty ? id : title)
    }

    private func exchangeCodeForTokens(
        code: String,
        codeVerifier: String,
        redirectURI: String,
        clientID: String,
        clientSecret: String
    ) async throws -> YouTubeTokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var parameters = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": codeVerifier,
            "client_id": clientID,
        ]
        if !clientSecret.isEmpty {
            parameters["client_secret"] = clientSecret
        }
        request.httpBody = formBody(parameters)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw YouTubeServiceError.authFailed(Self.mapAPIError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, body: body).localizedDescription)
        }
        return try JSONDecoder().decode(YouTubeTokenResponse.self, from: data)
    }

    /// The client that issued an account's tokens. Google refuses to refresh a
    /// token against a different client, so this is the recorded one, never
    /// simply the current default.
    private nonisolated func refreshCredentials(accountID: String) -> GoogleOAuthCredentials? {
        GoogleOAuthCredentials(
            clientID: KeychainService.youtubeCredential(field: .clientID, accountID: accountID),
            clientSecret: KeychainService.youtubeCredential(field: .clientSecret, accountID: accountID)
        )
    }

    private func refreshAccessToken(accountID: String, refreshToken: String) async throws -> YouTubeTokenResponse {
        guard let credentials = refreshCredentials(accountID: accountID) else {
            throw YouTubeServiceError.missingClientID
        }
        do {
            return try await requestRefresh(refreshToken: refreshToken, credentials: credentials)
        } catch let revoked as GrantRevoked {
            dropCredentials(accountID: accountID)
            throw revoked.serviceError
        }
    }

    /// Google no longer honours a refresh token: the connection is gone.
    private struct GrantRevoked: Error {
        let usedAppOwnedClient: Bool

        var serviceError: YouTubeServiceError {
            .authFailed(
                usedAppOwnedClient
                    ? "Google revoked the saved sign-in (invalid_grant). Reconnect YouTube to sign in again."
                    : "Google revoked the saved sign-in (invalid_grant). This connection used your own Google Cloud OAuth client; if its consent screen is still in Testing mode, sign-ins expire after 7 days. Reconnect to switch to ForeverLM's own client."
            )
        }
    }

    private func requestRefresh(
        refreshToken: String,
        credentials: GoogleOAuthCredentials
    ) async throws -> YouTubeTokenResponse {
        let clientID = credentials.clientID
        let clientSecret = credentials.clientSecret

        if let validationMessage = validateClientID(clientID) {
            throw YouTubeServiceError.invalidClientID(validationMessage)
        }

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var parameters = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        if !clientSecret.isEmpty {
            parameters["client_secret"] = clientSecret
        }
        request.httpBody = formBody(parameters)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            // Only a revoked/expired grant means the connection is truly gone.
            // Transient failures (Google 5xx, flaky networks) must not wipe the
            // stored tokens, or the plugin silently disconnects itself.
            if body.contains("invalid_grant") {
                throw GrantRevoked(usedAppOwnedClient: credentials == GoogleOAuthClient.appOwnedYouTube)
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw YouTubeServiceError.authFailed(Self.mapAPIError(statusCode: statusCode, body: body).localizedDescription)
        }
        return try JSONDecoder().decode(YouTubeTokenResponse.self, from: data)
    }

    /// Persist the tokens of one account. `issuedBy` is set only when a fresh
    /// authorization minted them; a refresh leaves the recorded client alone.
    private nonisolated func store(
        tokens: YouTubeTokenResponse,
        accountID: String,
        issuedBy credentials: GoogleOAuthCredentials? = nil
    ) {
        if let accessToken = tokens.accessToken {
            KeychainService.saveYouTubeCredential(accessToken, field: .accessToken, accountID: accountID)
        }
        if let refreshToken = tokens.refreshToken {
            KeychainService.saveYouTubeCredential(refreshToken, field: .refreshToken, accountID: accountID)
        }
        if let expiresIn = tokens.expiresIn {
            let expiry = Date().addingTimeInterval(TimeInterval(expiresIn))
            KeychainService.saveYouTubeCredential(
                KnowledgeStore.iso8601Formatter.string(from: expiry),
                field: .tokenExpiry,
                accountID: accountID
            )
        }
        if let credentials {
            KeychainService.saveYouTubeCredential(credentials.clientID, field: .clientID, accountID: accountID)
            KeychainService.saveYouTubeCredential(credentials.clientSecret, field: .clientSecret, accountID: accountID)
        }
    }

    /// Store a fresh grant under its channel and list the account.
    private nonisolated func register(
        channel: (id: String, title: String),
        tokens: YouTubeTokenResponse,
        issuedBy credentials: GoogleOAuthCredentials?
    ) -> YouTubeAccount {
        store(tokens: tokens, accountID: channel.id, issuedBy: credentials)
        Self.accountListLock.lock()
        defer { Self.accountListLock.unlock() }
        let listed = YouTubeAccountList.connecting(
            id: channel.id,
            title: channel.title,
            into: accounts
        )
        KeychainService.youtubeAccounts = YouTubeAccountList.encode(listed)
        return listed.first { $0.id == channel.id }!
    }

    private nonisolated func validateClientID(_ clientID: String) -> String? {
        if clientID.contains("://") || clientID.hasPrefix("com.foreverlm:") {
            return "Paste the Google OAuth Client ID from Google Cloud, not a redirect URI."
        }
        if !clientID.hasSuffix(".apps.googleusercontent.com") {
            return "Google OAuth Client IDs should end in .apps.googleusercontent.com."
        }
        return nil
    }

    private nonisolated func formBody(_ values: [String: String]) -> Data {
        values
            .map { key, value in "\(formEncode(key))=\(formEncode(value))" }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    private nonisolated func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private nonisolated func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).youtubeBase64URLEncoded()
    }

    private nonisolated func generateCodeChallenge(from verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).youtubeBase64URLEncoded()
    }
}

// MARK: - Google API error parsing

private struct GoogleAPIErrorEnvelope {
    let message: String?
    let reasons: [String]
    let enableURL: String?

    var isYouTubeAPINotEnabled: Bool {
        reasons.contains(where: { $0 == "accessNotConfigured" || $0 == "serviceDisabled" })
            || (message?.localizedCaseInsensitiveContains("youtube data api") == true
                && (message?.localizedCaseInsensitiveContains("disabled") == true
                    || message?.localizedCaseInsensitiveContains("has not been used") == true))
    }

    static func parse(_ body: String) -> GoogleAPIErrorEnvelope {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else {
            return GoogleAPIErrorEnvelope(message: nil, reasons: [], enableURL: nil)
        }

        let message = error["message"] as? String
        let reasons = (error["errors"] as? [[String: Any]])?.compactMap { $0["reason"] as? String } ?? []
        let enableURL = message.flatMap(extractConsoleURL(from:))
        return GoogleAPIErrorEnvelope(message: message, reasons: reasons, enableURL: enableURL)
    }

    private static func extractConsoleURL(from message: String) -> String? {
        guard let range = message.range(of: "https://console") else { return nil }
        let suffix = message[range.lowerBound...]
        let url = suffix.split(whereSeparator: \.isWhitespace).first.map(String.init)
        return url?.trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
    }
}

// MARK: - YouTube Data API response models

private struct YouTubeTokenResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private struct ChannelListResponse: Decodable {
    struct Item: Decodable {
        struct Snippet: Decodable { let title: String? }
        struct ContentDetails: Decodable {
            struct RelatedPlaylists: Decodable {
                let likes: String?
                let uploads: String?
            }
            let relatedPlaylists: RelatedPlaylists?
        }
        let id: String?
        let snippet: Snippet?
        let contentDetails: ContentDetails?
    }
    let items: [Item]?
}

struct YouTubePluginPlaylist: Equatable, Sendable {
    let id: String
    let title: String

    var url: String { YouTubeService.playlistURL(forID: id) }
}

struct YouTubeVideoSearchResult: Equatable, Identifiable, Sendable {
    let videoId: String
    let title: String
    let channelTitle: String?
    let description: String?
    let publishedAt: Date?
    var channelId: String? = nil
    /// Set on a podcast episode's candidates: where the video was found.
    var foundBy: PodcastYouTubeCandidateOrigin? = nil

    var id: String { videoId }
    var url: String { "https://www.youtube.com/watch?v=\(videoId)" }
}

/// Where a YouTube candidate for a podcast episode was found, as the ranker
/// and an assistant read it. A video the episode's own page links is almost
/// always its upload, whatever the video is titled.
enum PodcastYouTubeCandidateOrigin: String, Sendable {
    case episodePage = "linked from the episode's own web page"
    case showChannel = "uploaded to the show's YouTube channel near the episode's release"
    case search = "YouTube search"
}

struct VideoSearchResponse: Decodable {
    struct Item: Decodable {
        struct Identifier: Decodable { let videoId: String? }
        struct Snippet: Decodable {
            let title: String?
            let channelId: String?
            let channelTitle: String?
            let description: String?
            let publishedAt: String?
        }
        let id: Identifier?
        let snippet: Snippet?
    }
    let items: [Item]?
}

/// `videos.list`: the same snippet as a search result, under a plain id.
struct VideoListResponse: Decodable {
    struct Item: Decodable {
        let id: String?
        let snippet: VideoSearchResponse.Item.Snippet?
    }
    let items: [Item]?
}

private struct PlaylistsResponse: Decodable {
    struct Item: Decodable {
        struct Snippet: Decodable { let title: String? }
        let id: String?
        let snippet: Snippet?
    }
    let items: [Item]?
    let nextPageToken: String?
}

private struct PlaylistItemsResponse: Decodable {
    struct Item: Decodable {
        struct Snippet: Decodable {
            struct ResourceId: Decodable { let videoId: String? }
            let title: String?
            let position: Int?
            let resourceId: ResourceId?
            let videoOwnerChannelTitle: String?
            /// When the item was added to the playlist — for the Liked feed,
            /// when the video was liked.
            let publishedAt: String?
        }
        struct ContentDetails: Decodable {
            /// When the video itself was published to YouTube.
            let videoPublishedAt: String?
        }
        let snippet: Snippet?
        let contentDetails: ContentDetails?
    }
    let items: [Item]?
    let nextPageToken: String?
}

private struct RatedVideosResponse: Decodable {
    struct Item: Decodable {
        struct Snippet: Decodable {
            let title: String?
            let channelTitle: String?
            let publishedAt: String?
        }
        let id: String?
        let snippet: Snippet?
    }
    let items: [Item]?
    let nextPageToken: String?
}

// MARK: - Local OAuth callback server

/// The loopback `http://127.0.0.1:<port>/<path>` Google's desktop OAuth flow
/// returns to. One instance per sign-in; shared by the YouTube and Google
/// Calendar plugins (Drive keeps its own, which stays up across its two
/// consent rounds). `serviceName` only names the plugin in the page the
/// browser is left on and in the errors.
final class GoogleOAuthCallbackServer: @unchecked Sendable {
    private let serviceName: String
    private let callbackPath: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.foreverlm.youtube-oauth-callback")
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var pendingCallbackResult: Result<URL, Error>?
    private var pendingBrowserConnection: NWConnection?
    private var isStopped = false
    private var didFinishStart = false
    private var didFinishCallback = false
    private(set) var port: UInt16 = 0

    var redirectURI: String {
        "http://127.0.0.1:\(port)\(callbackPath)"
    }

    init(serviceName: String, callbackPath: String) throws {
        self.serviceName = serviceName
        self.callbackPath = callbackPath
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters, on: 0)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { return }
                self.startContinuation = continuation
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    self.queue.async {
                        switch state {
                        case .ready:
                            guard let listenerPort = self.listener.port?.rawValue else {
                                self.finishStart(.failure(YouTubeServiceError.authFailed("Could not determine the local \(self.serviceName) callback port.")))
                                return
                            }
                            self.port = listenerPort
                            self.finishStart(.success(()))
                        case .failed(let error):
                            self.finishStart(.failure(YouTubeServiceError.authFailed("Local \(self.serviceName) callback server failed: \(error.localizedDescription)")))
                            self.finishCallback(.failure(YouTubeServiceError.authFailed("Local \(self.serviceName) callback server failed: \(error.localizedDescription)")))
                        case .cancelled:
                            self.finishStart(.failure(YouTubeServiceError.authFailed("Local \(self.serviceName) callback server stopped before sign-in completed.")))
                            self.finishCallback(.failure(YouTubeServiceError.authFailed("Local \(self.serviceName) callback server stopped before sign-in completed.")))
                        default:
                            break
                        }
                    }
                }
                self.listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection)
                }
                self.listener.start(queue: self.queue)
            }
        }
    }

    func waitForCallback(timeout: TimeInterval) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.queue.async {
                    if let pendingCallbackResult = self.pendingCallbackResult {
                        self.pendingCallbackResult = nil
                        continuation.resume(with: pendingCallbackResult)
                        return
                    }
                    self.callbackContinuation = continuation
                    self.queue.asyncAfter(deadline: .now() + timeout) {
                        self.finishCallback(.failure(YouTubeServiceError.authFailed("Timed out waiting for \(self.serviceName) sign-in to return to ForeverLM.")))
                    }
                }
            }
        } onCancel: {
            self.queue.async {
                self.finishCallback(.failure(CancellationError()))
            }
        }
    }

    func stop() {
        queue.async {
            guard !self.isStopped else { return }
            self.isStopped = true
            self.pendingBrowserConnection?.cancel()
            self.pendingBrowserConnection = nil
            self.listener.cancel()
        }
    }

    func completeBrowserCallback(success: Bool, message: String) {
        queue.async {
            guard let connection = self.pendingBrowserConnection else { return }
            self.pendingBrowserConnection = nil
            let title = success ? "\(self.serviceName) connected" : "\(self.serviceName) sign-in failed"
            let escapedTitle = self.htmlEscaped(title)
            let escapedMessage = self.htmlEscaped(message)
            let body = """
            <!doctype html>
            <html><head><meta charset="utf-8"><title>\(escapedTitle)</title></head>
            <body style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;padding:32px;">
            <h1>\(escapedTitle)</h1><p>\(escapedMessage)</p>
            </body></html>
            """
            self.sendResponse(connection, status: 200, reason: "OK", body: body, contentType: "text/html; charset=utf-8")
        }
    }

    private func finishStart(_ result: Result<Void, Error>) {
        guard !didFinishStart, let continuation = startContinuation else { return }
        didFinishStart = true
        startContinuation = nil
        continuation.resume(with: result)
    }

    private func finishCallback(_ result: Result<URL, Error>) {
        guard !isStopped, !didFinishCallback else { return }
        didFinishCallback = true
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            continuation.resume(with: result)
        } else if pendingCallbackResult == nil {
            pendingCallbackResult = result
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }
            self.queue.async {
                if let error {
                    self.sendResponse(
                        connection,
                        status: 500,
                        reason: "Internal Server Error",
                        body: "\(self.serviceName) sign-in failed: \(error.localizedDescription)"
                    )
                    return
                }
                guard let data else {
                    self.sendResponse(connection, status: 400, reason: "Bad Request", body: "Invalid \(self.serviceName) sign-in callback.")
                    return
                }

                let accumulated = buffer + data
                if accumulated.range(of: Data([13, 10, 13, 10])) == nil, accumulated.count < 16_384 {
                    self.receiveRequest(on: connection, buffer: accumulated)
                    return
                }

                self.handleRequestData(accumulated, on: connection)
            }
        }
    }

    private func handleRequestData(_ data: Data, on connection: NWConnection) {
        guard let request = String(data: data, encoding: .utf8),
              let requestLine = request.components(separatedBy: "\r\n").first else {
            sendResponse(connection, status: 400, reason: "Bad Request", body: "Invalid \(self.serviceName) sign-in callback.")
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendResponse(connection, status: 400, reason: "Bad Request", body: "Invalid \(self.serviceName) sign-in callback.")
            return
        }

        let target = String(parts[1])
        guard let url = URL(string: "http://127.0.0.1:\(port)\(target)"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path == callbackPath else {
            sendResponse(connection, status: 404, reason: "Not Found", body: "Not found.")
            return
        }

        guard components.queryItems?.contains(where: { $0.name == "code" }) == true else {
            let message = components.queryItems?.first(where: { $0.name == "error" })?.value
                ?? "Return to ForeverLM to see the sign-in error."
            let body = """
            <!doctype html>
            <html><head><meta charset="utf-8"><title>\(htmlEscaped(serviceName)) sign-in did not complete</title></head>
            <body style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;padding:32px;">
            <h1>\(htmlEscaped(serviceName)) sign-in did not complete</h1><p>\(htmlEscaped(message))</p>
            </body></html>
            """
            sendResponse(connection, status: 200, reason: "OK", body: body, contentType: "text/html; charset=utf-8")
            finishCallback(.success(url))
            return
        }

        pendingBrowserConnection?.cancel()
        pendingBrowserConnection = connection
        finishCallback(.success(url))
    }

    private func htmlEscaped(_ value: String) -> String {
        value.htmlEscaped.replacingOccurrences(of: "'", with: "&#39;")
    }

    private func sendResponse(
        _ connection: NWConnection,
        status: Int,
        reason: String,
        body: String,
        contentType: String = "text/plain; charset=utf-8"
    ) {
        let bodyData = Data(body.utf8)
        let header = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: \(contentType)",
            "Content-Length: \(bodyData.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        let response = Data(header.utf8) + bodyData
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private extension Data {
    func youtubeBase64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
