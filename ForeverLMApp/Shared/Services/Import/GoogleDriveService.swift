import AppKit
import CryptoKit
import Foundation
import Network
import OSLog
import Security

struct GoogleDriveAccount: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let email: String
    let displayName: String

    var displayLabel: String {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedEmail.isEmpty { return trimmedEmail }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? "Google Drive account" : trimmedName
    }
}

struct GoogleDriveFile: Sendable {
    let id: String
    let name: String
    let mimeType: String
    let modifiedAt: Date?
    let webViewLink: String?
    let shortcutTargetID: String?
    let shortcutTargetMimeType: String?
    let accountID: String?

    init(
        id: String,
        name: String,
        mimeType: String,
        modifiedAt: Date?,
        webViewLink: String?,
        shortcutTargetID: String?,
        shortcutTargetMimeType: String?,
        accountID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.modifiedAt = modifiedAt
        self.webViewLink = webViewLink
        self.shortcutTargetID = shortcutTargetID
        self.shortcutTargetMimeType = shortcutTargetMimeType
        self.accountID = accountID
    }

    var resourceID: String {
        shortcutTargetID ?? id
    }

    var effectiveMimeType: String {
        shortcutTargetMimeType ?? mimeType
    }

    var isFolder: Bool {
        effectiveMimeType == "application/vnd.google-apps.folder"
    }

    var webURL: String {
        // A shortcut's own webViewLink is not a durable media identity. Point
        // directly at the target so playback, download, and transcript export
        // all address the file the learner can actually open.
        let rawURL: String
        if shortcutTargetID == nil, let webViewLink, !webViewLink.isEmpty {
            rawURL = webViewLink
        } else if isFolder {
            rawURL = "https://drive.google.com/drive/folders/\(resourceID)"
        } else if effectiveMimeType == "application/vnd.google-apps.document" {
            rawURL = "https://docs.google.com/document/d/\(resourceID)/edit"
        } else {
            rawURL = "https://drive.google.com/file/d/\(resourceID)/view"
        }
        return GoogleDriveService.taggedURL(rawURL, accountID: accountID)
    }
}

/// Whether the Drive link behind the meeting folders can read files right now.
/// The one answer every surface (reader, sidebar, Settings) shows, so a broken
/// connection reads the same everywhere instead of as scattered fine print.
enum GoogleDriveHealth: Equatable {
    case notConnected
    /// Signed in, but the stored grant cannot read inside folders (an older
    /// `drive.file`-only grant), or Google revoked it.
    case needsReconnect
    case connected

    var isBroken: Bool { self != .connected }

    var bannerTitle: String {
        switch self {
        case .connected: return ""
        case .notConnected: return "Google Drive is not connected"
        case .needsReconnect: return "Google Drive needs to be reconnected"
        }
    }

    var bannerDetail: String {
        switch self {
        case .connected:
            return ""
        case .notConnected:
            return "Meeting recordings cannot play and new files will not import until you connect Google Drive."
        case .needsReconnect:
            return "ForeverLM can no longer read the files in your meeting folders, so recordings cannot play and new files will not import."
        }
    }

    var reconnectLabel: String {
        self == .notConnected ? "Connect Google Drive" : "Reconnect Google Drive"
    }
}

enum GoogleDriveServiceError: LocalizedError {
    case notConfigured
    case notSignedIn
    case noFolderSelected
    case invalidSelection
    case folderAccessUpgradeRequired
    case accessRevoked
    case authFailed(String)
    case apiFailed(String)
    case downloadFailed(String)

    /// The failures that only a fresh Google sign-in repairs, as opposed to a
    /// network blip or a missing file. The reader and sidebar answer these with
    /// the reconnect banner rather than a one-line error.
    var needsReconnect: Bool {
        switch self {
        case .notSignedIn, .folderAccessUpgradeRequired, .accessRevoked:
            return true
        default:
            return false
        }
    }

    /// No Google account is linked at all, as opposed to one whose grant is
    /// too narrow or was revoked.
    var isNotConnected: Bool {
        if case .notSignedIn = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "This build of ForeverLM has no Google Drive OAuth client configured."
        case .notSignedIn:
            return "Google Drive is not connected."
        case .noFolderSelected:
            return "No Google Drive folder was selected."
        case .invalidSelection:
            return "Choose a folder that contains your meeting recordings or transcripts."
        case .folderAccessUpgradeRequired:
            return "Reconnect Google Drive so ForeverLM can read files inside meeting folders."
        case .accessRevoked:
            return "Google Drive access expired or was revoked. Reconnect Google Drive so ForeverLM can read your meeting folders."
        case .authFailed(let message):
            return "Google Drive sign-in failed: \(message)"
        case .apiFailed(let message):
            return "Google Drive error: \(message)"
        case .downloadFailed(let name):
            return "Could not download \(name) from Google Drive."
        }
    }
}

/// Google Drive's browser picker plus a read-only Drive API client.
///
/// Google's desktop Picker is deliberately limited to the per-file `drive.file`
/// scope. Selecting a folder grants access to that folder object, not to its
/// children, so that token cannot power a folder plugin. The user first
/// chooses the folder in Picker, then grants read-only Drive access in a second
/// Google-owned consent step. ForeverLM traverses only folders the user links.
/// Network and Drive traversal stay inside this actor; the main actor is used
/// only to open the system browser.
actor GoogleDriveService {
    static let shared = GoogleDriveService()

    private let logger = Logger(subsystem: "com.foreverlm", category: "GoogleDriveService")
    private let callbackPath = "google-drive-oauth"
    nonisolated static let pickerScope = "https://www.googleapis.com/auth/drive.file"
    nonisolated static let folderReadScope = "https://www.googleapis.com/auth/drive.readonly"
    private let folderMimeType = "application/vnd.google-apps.folder"
    private let googleDocMimeType = "application/vnd.google-apps.document"
    nonisolated static let accountQueryItem = "foreverlm_drive_account"
    private var recordingDownloadTasks: [String: Task<URL, Error>] = [:]
    /// The loopback server of a sign-in in progress, so Cancel can reach it.
    private var activeCallbackServer: GoogleDriveOAuthCallbackServer?

    nonisolated var isSignedIn: Bool {
        connectedAccounts.contains(where: Self.hasStoredCredential)
    }

    nonisolated func isSignedIn(accountID: String?) -> Bool {
        guard let accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accountID.isEmpty else {
            return isSignedIn
        }
        return connectedAccounts.contains { account in
            account.id == accountID && Self.hasStoredCredential(account)
        }
    }

    nonisolated var canConnect: Bool {
        GoogleOAuthClient.driveAuthorization() != nil
    }

    nonisolated var hasFolderReadAccess: Bool {
        connectedAccounts.contains { account in
            Self.storedScopes(accountID: account.id).contains(Self.folderReadScope)
        }
    }

    nonisolated var health: GoogleDriveHealth {
        guard isSignedIn else { return .notConnected }
        return hasFolderReadAccess ? .connected : .needsReconnect
    }

    /// Health for the account a recording or folder belongs to; an untagged
    /// link answers for the connection as a whole.
    nonisolated func health(accountID: String?) -> GoogleDriveHealth {
        guard isSignedIn(accountID: accountID) else { return .notConnected }
        return hasFolderReadAccess(accountID: accountID) ? .connected : .needsReconnect
    }

    nonisolated func hasFolderReadAccess(accountID: String?) -> Bool {
        guard let accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accountID.isEmpty else {
            return hasFolderReadAccess
        }
        return Self.storedScopes(accountID: accountID).contains(Self.folderReadScope)
    }

    /// Whether the stored grant can create files in the user's Drive. This is
    /// the per-file `drive.file` scope, which the folder plugin's read-only
    /// grant does not include: Picker's `drive.file` token is deliberately
    /// never stored, so a Mac with a working meeting folder still answers
    /// false here until a conversion asks for it.
    nonisolated var hasFileCreateAccess: Bool {
        connectedAccounts.contains { account in
            Self.storedScopes(accountID: account.id).contains(Self.pickerScope)
        }
    }

    nonisolated var connectedAccounts: [GoogleDriveAccount] {
        Self.decodeAccounts(KeychainService.googleDriveAccounts)
            .filter(Self.hasStoredCredential)
    }

    func signOut(accountID: String) {
        let trimmed = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        KeychainService.deleteGoogleDriveCredentials(accountID: trimmed)
        let remaining = Self.removingAccount(id: trimmed, from: connectedAccounts)
        Self.storeAccounts(remaining)
        if KeychainService.googleDriveDefaultAccountID == trimmed {
            KeychainService.googleDriveDefaultAccountID = remaining.first?.id
        }
        Self.notifyConnectionChanged()
    }

    nonisolated static func notifyConnectionChanged() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .pluginConnectionChanged, object: nil)
        }
    }

    nonisolated static func decodeAccounts(_ value: String?) -> [GoogleDriveAccount] {
        guard let value, let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([GoogleDriveAccount].self, from: data) else {
            return []
        }
        var seen = Set<String>()
        return decoded.filter { account in
            !account.id.isEmpty && seen.insert(account.id).inserted
        }
    }

    nonisolated static func encodeAccounts(_ accounts: [GoogleDriveAccount]) -> String? {
        guard let data = try? JSONEncoder().encode(accounts) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func mergingAccount(
        _ account: GoogleDriveAccount,
        into accounts: [GoogleDriveAccount]
    ) -> [GoogleDriveAccount] {
        accounts.filter { $0.id != account.id } + [account]
    }

    nonisolated static func removingAccount(
        id: String,
        from accounts: [GoogleDriveAccount]
    ) -> [GoogleDriveAccount] {
        accounts.filter { $0.id != id }
    }

    nonisolated static func taggedURL(_ value: String, accountID: String?) -> String {
        guard let accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accountID.isEmpty,
              var components = URLComponents(string: value) else {
            return value
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == accountQueryItem }
        items.append(URLQueryItem(name: accountQueryItem, value: accountID))
        components.queryItems = items
        return components.url?.absoluteString ?? value
    }

    nonisolated static func accountID(from value: String) -> String? {
        guard let components = URLComponents(string: value),
              let accountID = components.queryItems?.first(where: { $0.name == accountQueryItem })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !accountID.isEmpty else {
            return nil
        }
        return accountID
    }

    nonisolated private static func hasStoredCredential(_ account: GoogleDriveAccount) -> Bool {
        KeychainService.googleDriveCredential(field: .accessToken, accountID: account.id)?.isEmpty == false
            || KeychainService.googleDriveCredential(field: .refreshToken, accountID: account.id)?.isEmpty == false
    }

    nonisolated private static func storedScopes(accountID: String) -> Set<String> {
        scopeSet(from: KeychainService.googleDriveCredential(field: .grantedScopes, accountID: accountID))
    }

    nonisolated private static func storeAccounts(_ accounts: [GoogleDriveAccount]) {
        KeychainService.googleDriveAccounts = encodeAccounts(accounts)
    }

    nonisolated private func register(_ account: GoogleDriveAccount) {
        Self.storeAccounts(Self.mergingAccount(account, into: connectedAccounts))
        if KeychainService.googleDriveDefaultAccountID?.isEmpty != false {
            KeychainService.googleDriveDefaultAccountID = account.id
        }
    }

    /// The one Google sign-in: read-only Drive access (`drive.readonly`) for the
    /// account the learner picks, stored per account. Folders are then chosen
    /// in the app (`listFolders`, `searchFolders`), so there is no second consent.
    ///
    /// Google's own Picker would have chosen the folder in the browser, but its
    /// `drive.file` token reaches only the folder object itself, never what is
    /// inside it, so a folder plugin built on it had to ask for `drive.readonly`
    /// as well: two consent screens for one connection.
    ///
    /// An existing grant for the same account is replaced, which is also how a
    /// revoked or too-narrow grant is repaired. Cancel it with
    /// `cancelPendingConnection()`.
    func connectAccount() async throws -> GoogleDriveAccount {
        guard let credentials = GoogleOAuthClient.driveAuthorization() else {
            throw GoogleDriveServiceError.notConfigured
        }
        guard credentials.clientID.hasSuffix(".apps.googleusercontent.com") else {
            throw GoogleDriveServiceError.authFailed("The configured OAuth client ID is invalid.")
        }

        let callbackServer = try GoogleDriveOAuthCallbackServer(callbackPath: "/\(callbackPath)")
        try await callbackServer.start()
        defer {
            callbackServer.stop()
            activeCallbackServer = nil
        }
        activeCallbackServer = callbackServer

        let verifier = Self.codeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let state = UUID().uuidString
        let redirectURI = callbackServer.redirectURI

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: Self.folderReadScope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent select_account"),
            URLQueryItem(name: "include_granted_scopes", value: "false"),
        ]
        guard let authorizationURL = components.url else {
            throw GoogleDriveServiceError.authFailed("Could not construct the Google authorization URL.")
        }

        let openedBrowser = await MainActor.run {
            NSWorkspace.shared.open(authorizationURL)
        }
        guard openedBrowser else {
            throw GoogleDriveServiceError.authFailed("Could not open the browser sign-in page.")
        }

        do {
            // Ten minutes: the consent screen carries Google's "unverified app"
            // interstitial, which adds an Advanced -> continue detour. The wait
            // answers task cancellation and `cancelPendingConnection()`.
            let callbackURL = try await callbackServer.waitForCallback(timeout: 600)
            let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let oauthError = items.first(where: { $0.name == "error" })?.value {
                throw GoogleDriveServiceError.authFailed(oauthError)
            }
            guard items.first(where: { $0.name == "state" })?.value == state,
                  let code = items.first(where: { $0.name == "code" })?.value else {
                throw GoogleDriveServiceError.authFailed("Google returned an invalid callback.")
            }
            let tokens = try await exchangeCodeForTokens(
                code: code,
                verifier: verifier,
                redirectURI: redirectURI,
                credentials: credentials
            )
            let callbackScopes = items.first(where: { $0.name == "scope" })?.value
            let grantedScopes = Self.scopeSet(from: tokens.scope ?? callbackScopes)
            guard grantedScopes.contains(Self.folderReadScope) else {
                throw GoogleDriveServiceError.authFailed(
                    "Google did not grant read-only Drive access. Tick the Drive permission on Google's consent screen."
                )
            }
            guard let accessToken = tokens.accessToken, !accessToken.isEmpty else {
                throw GoogleDriveServiceError.authFailed("Google did not return a Drive access token.")
            }
            let account = try await accountProfile(accessToken: accessToken)
            let existingRefreshToken = Self.storedScopes(accountID: account.id).contains(Self.folderReadScope)
                ? KeychainService.googleDriveCredential(field: .refreshToken, accountID: account.id)
                : nil
            guard tokens.refreshToken?.isEmpty == false || existingRefreshToken?.isEmpty == false else {
                throw GoogleDriveServiceError.authFailed("Google did not return long-lived Drive access. Try connecting again.")
            }
            store(
                tokens: tokens,
                account: account,
                issuedBy: credentials,
                grantedScopes: grantedScopes,
                retainedRefreshToken: existingRefreshToken
            )
            callbackServer.completeBrowserCallback(
                success: true,
                message: "Google Drive is connected. Return to ForeverLM to choose your meeting folder. You can close this tab."
            )
            Self.notifyConnectionChanged()
            logger.info("Connected Google Drive account \(account.id, privacy: .private(mask: .hash))")
            return account
        } catch {
            callbackServer.completeBrowserCallback(success: false, message: error.localizedDescription)
            throw error
        }
    }

    /// Stop waiting for the browser: closing the Google tab sends nothing back,
    /// so without this a sign-in that went nowhere held its button for ten
    /// minutes. `connectAccount()` then throws `CancellationError`.
    func cancelPendingConnection() {
        activeCallbackServer?.cancelWait()
    }

    // MARK: Choosing a folder

    /// Where the in-app folder browser is looking.
    enum FolderLocation: Hashable, Sendable {
        case myDrive
        case sharedWithMe
        case sharedDrives
        case folder(String)
    }

    /// The folders directly inside `location`, by name. Shared drives list as
    /// folders whose id is the drive id, which Drive accepts as a parent.
    func listFolders(in location: FolderLocation, accountID: String) async throws -> [GoogleDriveFile] {
        switch location {
        case .sharedDrives:
            return try await listSharedDrives(accountID: accountID)
        case .myDrive:
            return try await listFiles(
                query: "'root' in parents and mimeType = '\(folderMimeType)' and trashed = false",
                accountID: accountID,
                acrossAllDrives: true
            )
        case .sharedWithMe:
            return try await listFiles(
                query: "sharedWithMe = true and mimeType = '\(folderMimeType)' and trashed = false",
                accountID: accountID,
                acrossAllDrives: true
            )
        case .folder(let id):
            return try await listFiles(
                query: "'\(Self.escapedQueryLiteral(id))' in parents and mimeType = '\(folderMimeType)' and trashed = false",
                accountID: accountID,
                acrossAllDrives: true
            )
        }
    }

    /// Folders anywhere in the account (My Drive, shared with me, shared
    /// drives) whose name contains `text`.
    func searchFolders(matching text: String, accountID: String) async throws -> [GoogleDriveFile] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await listFiles(
            query: "name contains '\(Self.escapedQueryLiteral(trimmed))' and mimeType = '\(folderMimeType)' and trashed = false",
            accountID: accountID,
            acrossAllDrives: true
        )
    }

    private func listSharedDrives(accountID: String) async throws -> [GoogleDriveFile] {
        var pageToken: String?
        var drives: [GoogleDriveFile] = []
        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/drives")!
            var queryItems = [
                URLQueryItem(name: "pageSize", value: "100"),
                URLQueryItem(name: "fields", value: "nextPageToken,drives(id,name)"),
            ]
            if let pageToken { queryItems.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components.queryItems = queryItems
            let (data, response) = try await authorizedData(url: components.url!, accountID: accountID)
            try Self.requireSuccess(response, data: data)
            let page = try JSONDecoder.googleDrive.decode(SharedDriveListPayload.self, from: data)
            drives.append(contentsOf: page.drives.map {
                GoogleDriveFile(
                    id: $0.id,
                    name: $0.name,
                    mimeType: folderMimeType,
                    modifiedAt: nil,
                    webViewLink: nil,
                    shortcutTargetID: nil,
                    shortcutTargetMimeType: nil,
                    accountID: accountID
                )
            })
            pageToken = page.nextPageToken
        } while pageToken != nil
        return drives.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private nonisolated static func escapedQueryLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    /// Create a Google Doc in the user's Drive from HTML and return its
    /// document id. Drive converts the upload into a Google Doc itself; the
    /// request is `GoogleDocConversion.createRequest`, so its shape is pinned
    /// without a network.
    ///
    /// Needs only `drive.file`. A Mac that has never connected Google, or one
    /// whose grant is the folder plugin's read-only one, is sent through one
    /// consent round for that scope first — with `include_granted_scopes`, so a
    /// working folder grant on the same account survives the upgrade.
    func createGoogleDoc(title: String, html: String) async throws -> String {
        let authorization = try await fileCreateAuthorization()
        let first = try await performCreateGoogleDoc(
            title: title,
            html: html,
            accessToken: authorization.token
        )
        if first.response.statusCode == 401 {
            // The stored token is stale; refresh once and try again, as every
            // other authenticated call here does.
            clearCachedAccessToken(accountID: authorization.accountID)
            let refreshed = try await accessToken(
                requiring: Self.pickerScope,
                accountID: authorization.accountID
            )
            let second = try await performCreateGoogleDoc(title: title, html: html, accessToken: refreshed)
            return try Self.documentID(from: second)
        }
        return try Self.documentID(from: first)
    }

    private func performCreateGoogleDoc(
        title: String,
        html: String,
        accessToken: String
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        let request = try GoogleDocConversion.createRequest(title: title, html: html, accessToken: accessToken)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            // The sheet's Cancel: not a network failure, and nothing to show.
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw GoogleDocConversionError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GoogleDocConversionError.invalidResponse
        }
        return (data, http)
    }

    private nonisolated static func documentID(from result: (data: Data, response: HTTPURLResponse)) throws -> String {
        guard (200..<300).contains(result.response.statusCode) else {
            throw GoogleDocConversionError.refused(
                status: result.response.statusCode,
                detail: GoogleDocConversion.errorMessage(fromResponse: result.data)
            )
        }
        return try GoogleDocConversion.documentID(fromCreateResponse: result.data)
    }

    /// A token that may create files: the stored one when the grant already
    /// covers `drive.file`, otherwise the one a fresh consent round returns.
    private func fileCreateAuthorization() async throws -> (accountID: String?, token: String) {
        if let defaultAccountID = KeychainService.googleDriveDefaultAccountID,
           Self.storedScopes(accountID: defaultAccountID).contains(Self.pickerScope) {
            return (
                defaultAccountID,
                try await accessToken(requiring: Self.pickerScope, accountID: defaultAccountID)
            )
        }
        if let account = connectedAccounts.first(where: {
            Self.storedScopes(accountID: $0.id).contains(Self.pickerScope)
        }) {
            KeychainService.googleDriveDefaultAccountID = account.id
            return (
                account.id,
                try await accessToken(requiring: Self.pickerScope, accountID: account.id)
            )
        }
        return try await authorizeFileCreateAccess()
    }

    /// One OAuth round for `drive.file` alone — no Picker, no folder — the way
    /// the plugin's read-only round runs: the system browser, the loopback
    /// callback, PKCE. The stored tokens are replaced; with
    /// `include_granted_scopes` Google folds a read-only grant already held by
    /// the same account into the new token, so the granted-scope set that is
    /// written back names both.
    private func authorizeFileCreateAccess() async throws -> (accountID: String?, token: String) {
        guard let credentials = GoogleOAuthClient.driveAuthorization() else {
            throw GoogleDriveServiceError.notConfigured
        }
        guard credentials.clientID.hasSuffix(".apps.googleusercontent.com") else {
            throw GoogleDocConversionError.signInIncomplete("The configured OAuth client ID is invalid.")
        }
        let callbackServer = try GoogleDriveOAuthCallbackServer(callbackPath: "/\(callbackPath)")
        try await callbackServer.start()
        defer { callbackServer.stop() }

        let verifier = Self.codeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let state = UUID().uuidString
        let redirectURI = callbackServer.redirectURI

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: Self.pickerScope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent select_account"),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
        ]
        guard let authorizationURL = components.url else {
            throw GoogleDocConversionError.signInIncomplete("Could not construct the Google authorization URL.")
        }

        // Ten minutes, like the plugin's rounds: the consent screen carries
        // Google's "unverified app" interstitial and its Advanced detour.
        let callbackTask = Task {
            try await callbackServer.waitForCallback(timeout: 600)
        }
        defer { callbackTask.cancel() }

        let openedBrowser = await MainActor.run {
            NSWorkspace.shared.open(authorizationURL)
        }
        guard openedBrowser else {
            throw GoogleDocConversionError.signInIncomplete("Could not open the browser sign-in page.")
        }

        do {
            // Cancel in the sheet reaches the wait: the callback task is its
            // own task, so the caller's cancellation is forwarded by hand and
            // the consent round ends at once rather than at its timeout.
            let callbackURL = try await withTaskCancellationHandler {
                try await callbackTask.value
            } onCancel: {
                callbackTask.cancel()
            }
            let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
            let items = callback?.queryItems ?? []
            if let oauthError = items.first(where: { $0.name == "error" })?.value {
                throw GoogleDocConversionError.signInIncomplete("Google answered: \(oauthError).")
            }
            guard items.first(where: { $0.name == "state" })?.value == state,
                  let code = items.first(where: { $0.name == "code" })?.value else {
                throw GoogleDocConversionError.signInIncomplete("Google returned an invalid callback.")
            }
            let tokens = try await exchangeCodeForTokens(
                code: code,
                verifier: verifier,
                redirectURI: redirectURI,
                credentials: credentials
            )
            let callbackScopes = items.first(where: { $0.name == "scope" })?.value
            let grantedScopes = Self.scopeSet(from: tokens.scope ?? callbackScopes)
            guard grantedScopes.contains(Self.pickerScope) else {
                throw GoogleDocConversionError.signInIncomplete("Google did not grant ForeverLM permission to create files in your Drive.")
            }
            guard let accessToken = tokens.accessToken, !accessToken.isEmpty else {
                throw GoogleDocConversionError.signInIncomplete("Google did not return an access token.")
            }
            let account = try await accountProfile(accessToken: accessToken)
            let retainedRefreshToken = KeychainService.googleDriveCredential(
                field: .refreshToken,
                accountID: account.id
            )
            // A refresh token already stored keeps working only for the scopes
            // it was issued with; a new grant carries its own, and Google
            // returns one on every consent round with offline access.
            guard tokens.refreshToken?.isEmpty == false || retainedRefreshToken?.isEmpty == false else {
                throw GoogleDocConversionError.signInIncomplete("Google did not return long-lived access. Try converting again.")
            }
            store(
                tokens: tokens,
                account: account,
                issuedBy: credentials,
                grantedScopes: grantedScopes,
                retainedRefreshToken: retainedRefreshToken
            )
            KeychainService.googleDriveDefaultAccountID = account.id
            Self.notifyConnectionChanged()
            callbackServer.completeBrowserCallback(
                success: true,
                message: "ForeverLM can now create Google Docs in your Drive. You can close this tab."
            )
            logger.info("Granted Google Drive file access for doc conversion")
            return (account.id, accessToken)
        } catch {
            callbackServer.completeBrowserCallback(success: false, message: error.localizedDescription)
            throw error
        }
    }

    /// Every file under `folderID`, minus the subtrees named in
    /// `excludingFolderIDs`.
    ///
    /// An excluded subfolder is one the learner already imported as a series of
    /// its own. Walking into it anyway files the same recording under two
    /// series at once — which is how a parent shared-drive folder came to hold
    /// a second copy of all forty-two sessions of the meetings folder nested
    /// inside it. A folder id is the identity boundary; the deeper folder owns
    /// what is inside it.
    func listFolderItemsRecursively(
        folderID: String,
        accountID: String? = nil,
        excludingFolderIDs: Set<String> = []
    ) async throws -> [GoogleDriveFile] {
        let ownerAccountID = resolvedAccountID(accountID)
        guard ownerAccountID != nil,
              hasFolderReadAccess(accountID: ownerAccountID) else {
            throw GoogleDriveServiceError.folderAccessUpgradeRequired
        }
        let excluded = excludingFolderIDs.subtracting([folderID])
        var visited = Set<String>()
        var pending = [folderID]
        var pendingIndex = 0
        var result: [GoogleDriveFile] = []

        while pending.indices.contains(pendingIndex) {
            let next = pending[pendingIndex]
            pendingIndex += 1
            guard visited.insert(next).inserted else { continue }
            guard visited.count <= 1_000 else {
                throw GoogleDriveServiceError.apiFailed("The selected folder contains more than 1,000 nested folders. Choose a smaller meeting folder.")
            }
            let children = try await listFolderItems(folderID: next, accountID: ownerAccountID)
            result.append(contentsOf: children)
            guard result.count <= 25_000 else {
                throw GoogleDriveServiceError.apiFailed("The selected folder contains more than 25,000 items. Choose a smaller meeting folder.")
            }
            pending.append(
                contentsOf: children
                    .filter { $0.isFolder && !excluded.contains($0.resourceID) }
                    .map(\.resourceID)
            )
        }
        return result
    }

    func downloadText(file: GoogleDriveFile) async throws -> String? {
        let ext = (file.name as NSString).pathExtension.lowercased()
        let isGoogleDoc = file.effectiveMimeType == googleDocMimeType
        guard isGoogleDoc || ["txt", "md", "markdown", "vtt", "srt", "sbv", "ttml", "html", "htm"].contains(ext) else {
            return nil
        }

        let url: URL
        if isGoogleDoc {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(file.resourceID)/export")!
            components.queryItems = [URLQueryItem(name: "mimeType", value: "text/plain")]
            url = components.url!
        } else {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(file.resourceID)")!
            components.queryItems = [
                URLQueryItem(name: "alt", value: "media"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
            ]
            url = components.url!
        }

        let (data, response) = try await authorizedData(url: url, accountID: file.accountID)
        guard (200..<300).contains(response.statusCode) else {
            throw GoogleDriveServiceError.downloadFailed(file.name)
        }
        return String(data: data, encoding: .utf8)
    }

    /// Download one authenticated Drive recording into the disposable app
    /// cache and return a native AVFoundation-readable URL. The Drive preview
    /// web page has its own browser cookie jar and therefore cannot reuse the
    /// plugin's OAuth grant; the Drive API download can. Concurrent player
    /// and transcription requests share one task so a large meeting is never
    /// downloaded twice.
    func cachedRecordingURL(
        fileURLOrID: String,
        mimeType: String?,
        modifiedAt: Date?,
        accountID: String? = nil
    ) async throws -> URL {
        guard let fileID = Self.fileID(from: fileURLOrID) else {
            throw GoogleDriveServiceError.downloadFailed("meeting recording")
        }
        let ownerAccountID = accountID ?? Self.accountID(from: fileURLOrID)
        let cacheKey = Self.recordingCacheKey(
            fileID: fileID,
            modifiedAt: modifiedAt,
            accountID: ownerAccountID
        )
        let fileExtension = Self.recordingFileExtension(for: mimeType)
        // A recording the learner kept for offline viewing answers first, so a
        // plane without Wi-Fi never reaches for the network or the sweep.
        if let offline = Self.existingOfflineRecordingURL(cacheKey: cacheKey, fileExtension: fileExtension) {
            return offline
        }
        let destination = try recordingCacheURL(
            cacheKey: cacheKey,
            fileExtension: fileExtension
        )
        if Self.isUsableCachedFile(destination) { return destination }
        if let task = recordingDownloadTasks[cacheKey] {
            return try await task.value
        }

        let task = Task { [weak self] () throws -> URL in
            guard let self else { throw CancellationError() }
            return try await self.downloadRecording(
                fileID: fileID,
                accountID: ownerAccountID,
                to: destination
            )
        }
        recordingDownloadTasks[cacheKey] = task
        defer { recordingDownloadTasks[cacheKey] = nil }
        return try await task.value
    }

    /// The thumbnail Drive has already rendered for a file, at the size the
    /// sidebar stores. Returns nil when Drive made none — a plain audio
    /// recording, or a file too new to have been processed yet.
    ///
    /// Deliberately two requests and not one: the metadata call is
    /// authenticated, and the thumbnail it names is a short-lived signed URL on
    /// Google's content host, fetched with no credential at all. Attaching the
    /// plugin's OAuth token would send it to a host the API response chose.
    func thumbnailData(fileURLOrID: String, accountID: String? = nil) async throws -> Data? {
        guard let fileID = Self.fileID(from: fileURLOrID) else { return nil }
        let ownerAccountID = accountID ?? Self.accountID(from: fileURLOrID)
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(fileID)")!
        components.queryItems = [
            URLQueryItem(name: "fields", value: "hasThumbnail,thumbnailLink"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
        ]
        let (data, response) = try await authorizedData(
            url: components.url!,
            accountID: ownerAccountID
        )
        guard (200..<300).contains(response.statusCode),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["hasThumbnail"] as? Bool == true,
              let link = payload["thumbnailLink"] as? String,
              let url = URL(string: Self.thumbnailLink(link, size: 512)) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("ForeverLM", forHTTPHeaderField: "User-Agent")
        let (imageData, imageResponse) = try await URLSession.shared.data(for: request)
        guard let http = imageResponse as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !imageData.isEmpty else {
            return nil
        }
        return imageData
    }

    /// Drive hands back a content URL whose trailing `=s220` names the rendered
    /// size. Asking for a larger one is a suffix swap; a link in some other
    /// shape is used exactly as given rather than rewritten on a guess.
    nonisolated static func thumbnailLink(_ link: String, size: Int) -> String {
        guard let range = link.range(of: "=s\\d+", options: .regularExpression, range: nil, locale: nil),
              range.upperBound == link.endIndex else {
            return link
        }
        return link.replacingCharacters(in: range, with: "=s\(size)")
    }

    /// The cached recording for a file, only if this Mac already downloaded it.
    ///
    /// The counterpart to `cachedRecordingURL` for callers that want a
    /// recording opportunistically rather than at any cost — an icon is worth
    /// reading a file already on disk for, and not worth pulling a gigabyte of
    /// video across the network for.
    func existingCachedRecordingURL(
        fileURLOrID: String,
        mimeType: String?,
        modifiedAt: Date?,
        accountID: String? = nil
    ) -> URL? {
        guard let fileID = Self.fileID(from: fileURLOrID) else { return nil }
        let ownerAccountID = accountID ?? Self.accountID(from: fileURLOrID)
        let cacheKey = Self.recordingCacheKey(
            fileID: fileID,
            modifiedAt: modifiedAt,
            accountID: ownerAccountID
        )
        let fileExtension = Self.recordingFileExtension(for: mimeType)
        if let offline = Self.existingOfflineRecordingURL(cacheKey: cacheKey, fileExtension: fileExtension) {
            return offline
        }
        let destination = try? recordingCacheURL(cacheKey: cacheKey, fileExtension: fileExtension)
        guard let destination, Self.isUsableCachedFile(destination) else { return nil }
        return destination
    }

    // MARK: Offline recordings

    /// Whether this Mac holds a copy of the recording that the sweep will leave
    /// alone. Actor-isolated on purpose: it stats a file, and the reader asks
    /// from the main actor.
    func hasOfflineRecording(
        fileURLOrID: String,
        mimeType: String?,
        modifiedAt: Date?,
        accountID: String? = nil
    ) -> Bool {
        guard let key = Self.offlineRecordingKey(
            fileURLOrID: fileURLOrID,
            mimeType: mimeType,
            modifiedAt: modifiedAt,
            accountID: accountID
        ) else { return false }
        return Self.existingOfflineRecordingURL(cacheKey: key.cacheKey, fileExtension: key.fileExtension) != nil
    }

    /// Keep a recording on this Mac until the learner removes it. The download
    /// is the same one playback makes (shared, so pressing this while the
    /// player is still fetching adds no second transfer); the copy then lands
    /// beside the library, outside the disposable cache and its two-week,
    /// 2 GB sweep. On APFS the copy is a clone, so it costs no second pass of
    /// disk space while the cache entry lives.
    @discardableResult
    func makeRecordingAvailableOffline(
        fileURLOrID: String,
        mimeType: String?,
        modifiedAt: Date?,
        accountID: String? = nil
    ) async throws -> URL {
        guard let key = Self.offlineRecordingKey(
            fileURLOrID: fileURLOrID,
            mimeType: mimeType,
            modifiedAt: modifiedAt,
            accountID: accountID
        ) else {
            throw GoogleDriveServiceError.downloadFailed("meeting recording")
        }
        if let existing = Self.existingOfflineRecordingURL(cacheKey: key.cacheKey, fileExtension: key.fileExtension) {
            return existing
        }
        let cached = try await cachedRecordingURL(
            fileURLOrID: fileURLOrID,
            mimeType: mimeType,
            modifiedAt: modifiedAt,
            accountID: accountID
        )
        let directory = try Self.offlineRecordingDirectory()
        let destination = directory.appendingPathComponent("\(key.cacheKey).\(key.fileExtension)")
        let partial = directory.appendingPathComponent("\(key.cacheKey).\(key.fileExtension).partial")
        try? FileManager.default.removeItem(at: partial)
        try FileManager.default.copyItem(at: cached, to: partial)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        guard Self.isUsableCachedFile(destination) else {
            throw GoogleDriveServiceError.downloadFailed("meeting recording")
        }
        // Drive re-uploads change the modification date and so the key; the
        // copy kept for the old key would otherwise sit here for good.
        Self.removeOfflineRecordings(forFilePrefix: key.filePrefix, except: destination)
        return destination
    }

    /// Drop the kept copy. The recording stays in Google Drive and plays again
    /// (and downloads again) the next time it is opened.
    func removeOfflineRecording(
        fileURLOrID: String,
        mimeType: String?,
        modifiedAt: Date?,
        accountID: String? = nil
    ) {
        guard let key = Self.offlineRecordingKey(
            fileURLOrID: fileURLOrID,
            mimeType: mimeType,
            modifiedAt: modifiedAt,
            accountID: accountID
        ) else { return }
        Self.removeOfflineRecordings(forFilePrefix: key.filePrefix, except: nil)
    }

    nonisolated static func offlineRecordingKey(
        fileURLOrID: String,
        mimeType: String?,
        modifiedAt: Date?,
        accountID: String?
    ) -> (cacheKey: String, fileExtension: String, filePrefix: String)? {
        guard let fileID = fileID(from: fileURLOrID) else { return nil }
        let ownerAccountID = accountID ?? Self.accountID(from: fileURLOrID)
        let cacheKey = recordingCacheKey(fileID: fileID, modifiedAt: modifiedAt, accountID: ownerAccountID)
        let stamp = cacheKey.split(separator: "-", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let filePrefix = String(cacheKey.dropLast(stamp.count))
        return (cacheKey, recordingFileExtension(for: mimeType), filePrefix)
    }

    /// Beside the library, not in `~/Library/Caches`: macOS may empty a cache
    /// whenever the disk runs short, and that is exactly the guarantee an
    /// offline copy exists to break. Local to this Mac and out of backups, as
    /// Drive still has the original, so nothing here syncs and nothing here
    /// needs a schema.
    private nonisolated static func offlineRecordingDirectory() throws -> URL {
        var directory = offlineRecordingsFolderURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        return directory
    }

    nonisolated static var offlineRecordingsFolderURL: URL {
        ForeverLMRuntimeIdentity.applicationSupportRootURL
            .appendingPathComponent("OfflineRecordings", isDirectory: true)
    }

    private nonisolated static func existingOfflineRecordingURL(
        cacheKey: String,
        fileExtension: String
    ) -> URL? {
        let url = offlineRecordingsFolderURL.appendingPathComponent("\(cacheKey).\(fileExtension)")
        return isUsableCachedFile(url) ? url : nil
    }

    private nonisolated static func removeOfflineRecordings(forFilePrefix prefix: String, except keep: URL?) {
        let directory = offlineRecordingsFolderURL
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in contents where url.lastPathComponent != keep?.lastPathComponent {
            // What follows the prefix is one modification stamp and an
            // extension, never another "-": a file whose id merely starts with
            // this one's is somebody else's copy.
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix), !name.dropFirst(prefix.count).contains("-") else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    nonisolated static func fileID(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("/"), !trimmed.contains(" ") { return trimmed }
        guard let url = URL(string: trimmed) else { return nil }
        let parts = url.pathComponents
        if let index = parts.firstIndex(of: "d"), parts.indices.contains(index + 1) {
            return parts[index + 1]
        }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "id" })?
            .value
    }

    /// Recordings are the largest thing this app caches and the cheapest to get
    /// back, because Drive still has them. Two weeks of them, capped at 2 GB,
    /// keeps the meetings anyone is actually working through instant while
    /// bounding a directory that used to only grow.
    private static let recordingCacheBudget: Int64 = 2 * 1024 * 1024 * 1024
    private static let recordingCacheLifetime: TimeInterval = 14 * 24 * 60 * 60

    private static var recordingCacheDirectory: URL? {
        guard let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return root
            .appendingPathComponent(ForeverLMRuntimeIdentity.productFolderName, isDirectory: true)
            .appendingPathComponent("GoogleDriveRecordings", isDirectory: true)
    }

    /// Runs once per process, off whichever thread first reaches for a
    /// recording. A sweep is a directory listing and some unlinks, but the
    /// callers here are already waiting on the network and should not also wait
    /// on that.
    private static let recordingCacheSweep: Void = {
        guard let directory = recordingCacheDirectory else { return }
        DispatchQueue.global(qos: .utility).async {
            CacheDirectorySweep.sweep(
                directory: directory,
                maximumBytes: recordingCacheBudget,
                maximumAge: recordingCacheLifetime
            )
        }
    }()

    private func recordingCacheURL(cacheKey: String, fileExtension: String) throws -> URL {
        guard let directory = Self.recordingCacheDirectory else {
            throw GoogleDriveServiceError.downloadFailed("meeting recording")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = Self.recordingCacheSweep
        return directory.appendingPathComponent("\(cacheKey).\(fileExtension)")
    }

    private func downloadRecording(
        fileID: String,
        accountID: String?,
        to destination: URL
    ) async throws -> URL {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(fileID)")!
        components.queryItems = [
            URLQueryItem(name: "alt", value: "media"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
        ]
        let (temporaryURL, response) = try await authorizedDownload(
            url: components.url!,
            accountID: accountID
        )
        guard (200..<300).contains(response.statusCode) else {
            throw GoogleDriveServiceError.downloadFailed("meeting recording (HTTP \(response.statusCode))")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        guard Self.isUsableCachedFile(destination) else {
            throw GoogleDriveServiceError.downloadFailed("meeting recording")
        }
        return destination
    }

    private func authorizedDownload(
        url: URL,
        accountID: String?
    ) async throws -> (URL, HTTPURLResponse) {
        let first = try await performAuthorizedDownload(url: url, accountID: accountID)
        guard first.1.statusCode == 401 else { return first }
        clearCachedAccessToken(accountID: resolvedAccountID(accountID))
        return try await performAuthorizedDownload(url: url, accountID: accountID)
    }

    private func performAuthorizedDownload(
        url: URL,
        accountID: String?
    ) async throws -> (URL, HTTPURLResponse) {
        let token = try await accessToken(accountID: accountID)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("ForeverLM", forHTTPHeaderField: "User-Agent")
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw GoogleDriveServiceError.apiFailed("Google returned an invalid response.")
        }
        return (temporaryURL, response)
    }

    private nonisolated static func recordingCacheKey(
        fileID: String,
        modifiedAt: Date?,
        accountID: String?
    ) -> String {
        let stamp = modifiedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "current"
        let owner = (accountID ?? "untagged").replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "_",
            options: .regularExpression
        )
        let safeID = fileID.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "_",
            options: .regularExpression
        )
        return "\(owner)-\(safeID)-\(stamp)"
    }

    private nonisolated static func recordingFileExtension(for mimeType: String?) -> String {
        switch mimeType?.lowercased() {
        case "video/quicktime": return "mov"
        case "video/x-m4v": return "m4v"
        case "audio/mpeg": return "mp3"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        case "audio/wav", "audio/x-wav": return "wav"
        default: return "mp4"
        }
    }

    private nonisolated static func isUsableCachedFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return false
        }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }

    private func listFolderItems(folderID: String, accountID: String?) async throws -> [GoogleDriveFile] {
        try await listFiles(
            query: "'\(Self.escapedQueryLiteral(folderID))' in parents and trashed = false",
            accountID: accountID
        )
    }

    /// Every page of a Drive `files.list` query, folders first, then by name.
    private func listFiles(
        query: String,
        accountID: String?,
        acrossAllDrives: Bool = false
    ) async throws -> [GoogleDriveFile] {
        var pageToken: String?
        var files: [GoogleDriveFile] = []
        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            var queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,modifiedTime,webViewLink,shortcutDetails(targetId,targetMimeType))"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "orderBy", value: "folder,name_natural"),
            ]
            // Folder browsing spans My Drive, shared-with-me and shared drives
            // in one query; the import's own listing stays per-parent.
            if acrossAllDrives { queryItems.append(URLQueryItem(name: "corpora", value: "allDrives")) }
            if let pageToken { queryItems.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components.queryItems = queryItems

            let (data, response) = try await authorizedData(
                url: components.url!,
                accountID: accountID
            )
            try Self.requireSuccess(response, data: data)
            let page = try JSONDecoder.googleDrive.decode(DriveFileListPayload.self, from: data)
            files.append(contentsOf: page.files.map { $0.file(accountID: resolvedAccountID(accountID)) })
            pageToken = page.nextPageToken
        } while pageToken != nil
        return files
    }

    private func authorizedData(
        url: URL,
        accountID: String?
    ) async throws -> (Data, HTTPURLResponse) {
        let first = try await performAuthorizedGET(url: url, accountID: accountID)
        guard first.1.statusCode == 401 else { return first }
        clearCachedAccessToken(accountID: resolvedAccountID(accountID))
        return try await performAuthorizedGET(url: url, accountID: accountID)
    }

    private func performAuthorizedGET(
        url: URL,
        accountID: String?
    ) async throws -> (Data, HTTPURLResponse) {
        let token = try await accessToken(accountID: accountID)
        return try await performGET(url: url, accessToken: token)
    }

    private func performGET(url: URL, accessToken: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("ForeverLM", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw GoogleDriveServiceError.apiFailed("Google returned an invalid response.")
        }
        return (data, response)
    }

    /// The folder plugin's token: every Drive read here needs the read-only
    /// grant, which a `drive.file`-only grant does not stand in for.
    private func accessToken(accountID: String? = nil) async throws -> String {
        try await accessToken(requiring: Self.folderReadScope, accountID: accountID)
    }

    /// A valid access token whose stored grant includes `scope`, refreshed
    /// when the cached one is about to expire.
    private func accessToken(requiring scope: String, accountID: String?) async throws -> String {
        guard let accountID = resolvedAccountID(accountID) else {
            throw GoogleDriveServiceError.notSignedIn
        }
        guard Self.storedScopes(accountID: accountID).contains(scope) else {
            throw scope == Self.folderReadScope
                ? GoogleDriveServiceError.folderAccessUpgradeRequired
                : GoogleDriveServiceError.notSignedIn
        }
        if let expiry = KeychainService.googleDriveCredential(
            field: .tokenExpiry,
            accountID: accountID
        ),
           let expiryDate = ISO8601DateFormatter().date(from: expiry),
           expiryDate.timeIntervalSinceNow > 60,
           let token = KeychainService.googleDriveCredential(
            field: .accessToken,
            accountID: accountID
           ),
           !token.isEmpty {
            return token
        }
        guard let refreshToken = KeychainService.googleDriveCredential(
            field: .refreshToken,
            accountID: accountID
        ), !refreshToken.isEmpty else {
            throw GoogleDriveServiceError.notSignedIn
        }
        let credentials = accountCredentials(accountID: accountID)
        do {
            let tokens = try await refreshAccessToken(refreshToken, credentials: credentials)
            store(tokens: tokens, accountID: accountID)
            guard let token = tokens.accessToken, !token.isEmpty else {
                throw GoogleDriveServiceError.notSignedIn
            }
            return token
        } catch let error as GoogleDriveServiceError {
            if error.localizedDescription.contains("invalid_grant") {
                signOut(accountID: accountID)
                throw GoogleDriveServiceError.accessRevoked
            }
            throw error
        }
    }

    private func exchangeCodeForTokens(
        code: String,
        verifier: String,
        redirectURI: String,
        credentials: GoogleOAuthCredentials
    ) async throws -> GoogleDriveTokenPayload {
        try await tokenRequest(parameters: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
            "client_id": credentials.clientID,
            "client_secret": credentials.clientSecret,
        ])
    }

    private func refreshAccessToken(
        _ refreshToken: String,
        credentials: GoogleOAuthCredentials?
    ) async throws -> GoogleDriveTokenPayload {
        guard let credentials else { throw GoogleDriveServiceError.notConfigured }
        return try await tokenRequest(parameters: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": credentials.clientID,
            "client_secret": credentials.clientSecret,
        ])
    }

    private func tokenRequest(parameters: [String: String]) async throws -> GoogleDriveTokenPayload {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(parameters)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown response"
            throw GoogleDriveServiceError.authFailed(String(body.prefix(300)))
        }
        return try JSONDecoder().decode(GoogleDriveTokenPayload.self, from: data)
    }

    private func accountProfile(accessToken: String) async throws -> GoogleDriveAccount {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/about")!
        components.queryItems = [URLQueryItem(name: "fields", value: "user(displayName,emailAddress,permissionId)")]
        let (data, response) = try await performGET(url: components.url!, accessToken: accessToken)
        try Self.requireSuccess(response, data: data)
        let payload = try JSONDecoder().decode(DriveAboutPayload.self, from: data)
        let accountID = payload.user.permissionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountID.isEmpty else {
            throw GoogleDriveServiceError.authFailed("Google did not identify the selected Drive account.")
        }
        return GoogleDriveAccount(
            id: accountID,
            email: payload.user.emailAddress ?? "",
            displayName: payload.user.displayName ?? ""
        )
    }

    private nonisolated func resolvedAccountID(_ requestedAccountID: String?) -> String? {
        if let requestedAccountID = requestedAccountID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requestedAccountID.isEmpty {
            return requestedAccountID
        }
        let accounts = connectedAccounts
        return accounts.count == 1 ? accounts[0].id : nil
    }

    private nonisolated func accountCredentials(accountID: String) -> GoogleOAuthCredentials? {
        GoogleOAuthCredentials(
            clientID: KeychainService.googleDriveCredential(field: .clientID, accountID: accountID),
            clientSecret: KeychainService.googleDriveCredential(field: .clientSecret, accountID: accountID)
        ) ?? GoogleOAuthClient.driveAuthorization()
    }

    private nonisolated func clearCachedAccessToken(accountID: String?) {
        if let accountID {
            KeychainService.deleteGoogleDriveCredential(field: .accessToken, accountID: accountID)
            KeychainService.deleteGoogleDriveCredential(field: .tokenExpiry, accountID: accountID)
        }
    }

    private nonisolated func store(
        tokens: GoogleDriveTokenPayload,
        account: GoogleDriveAccount,
        issuedBy credentials: GoogleOAuthCredentials? = nil,
        grantedScopes: Set<String>? = nil,
        retainedRefreshToken: String? = nil
    ) {
        store(
            tokens: tokens,
            accountID: account.id,
            issuedBy: credentials,
            grantedScopes: grantedScopes,
            retainedRefreshToken: retainedRefreshToken
        )
        register(account)
    }

    private nonisolated func store(
        tokens: GoogleDriveTokenPayload,
        accountID: String,
        issuedBy credentials: GoogleOAuthCredentials? = nil,
        grantedScopes: Set<String>? = nil,
        retainedRefreshToken: String? = nil
    ) {
        if let value = tokens.accessToken {
            KeychainService.saveGoogleDriveCredential(value, field: .accessToken, accountID: accountID)
        }
        if let value = tokens.refreshToken ?? retainedRefreshToken {
            KeychainService.saveGoogleDriveCredential(value, field: .refreshToken, accountID: accountID)
        }
        if let value = tokens.expiresIn {
            KeychainService.saveGoogleDriveCredential(
                ISO8601DateFormatter().string(from: Date().addingTimeInterval(TimeInterval(value))),
                field: .tokenExpiry,
                accountID: accountID
            )
        }
        if let credentials {
            KeychainService.saveGoogleDriveCredential(credentials.clientID, field: .clientID, accountID: accountID)
            KeychainService.saveGoogleDriveCredential(credentials.clientSecret, field: .clientSecret, accountID: accountID)
        }
        let scopes = grantedScopes ?? Self.scopeSet(from: tokens.scope)
        if !scopes.isEmpty {
            KeychainService.saveGoogleDriveCredential(
                scopes.sorted().joined(separator: " "),
                field: .grantedScopes,
                accountID: accountID
            )
        }
    }

    nonisolated static func scopeSet(from value: String?) -> Set<String> {
        Set((value ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init))
    }

    private nonisolated static func requireSuccess(_ response: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GoogleDriveServiceError.apiFailed("HTTP \(response.statusCode): \(body.prefix(300))")
        }
    }

    private nonisolated static func formBody(_ values: [String: String]) -> Data {
        values
            .map { "\(formEncode($0.key))=\(formEncode($0.value))" }
            .sorted()
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    private nonisolated static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private nonisolated static func codeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).googleDriveBase64URLEncoded()
    }

    private nonisolated static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).googleDriveBase64URLEncoded()
    }
}

private struct GoogleDriveTokenPayload: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
    }
}

private struct DriveAboutPayload: Decodable {
    struct User: Decodable {
        let displayName: String?
        let emailAddress: String?
        let permissionId: String
    }

    let user: User
}

private struct DriveFilePayload: Decodable {
    struct ShortcutDetails: Decodable {
        let targetId: String
        let targetMimeType: String
    }

    let id: String
    let name: String
    let mimeType: String
    let modifiedTime: Date?
    let webViewLink: String?
    let shortcutDetails: ShortcutDetails?

    func file(accountID: String?) -> GoogleDriveFile {
        GoogleDriveFile(
            id: id,
            name: name,
            mimeType: mimeType,
            modifiedAt: modifiedTime,
            webViewLink: webViewLink,
            shortcutTargetID: shortcutDetails?.targetId,
            shortcutTargetMimeType: shortcutDetails?.targetMimeType,
            accountID: accountID
        )
    }
}

private struct SharedDriveListPayload: Decodable {
    struct Drive: Decodable {
        let id: String
        let name: String
    }

    let drives: [Drive]
    let nextPageToken: String?
}

private struct DriveFileListPayload: Decodable {
    let files: [DriveFilePayload]
    let nextPageToken: String?
}

private extension JSONDecoder {
    static var googleDrive: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension Data {
    func googleDriveBase64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class GoogleDriveOAuthCallbackServer: @unchecked Sendable {
    private let callbackPath: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.foreverlm.google-drive-oauth-callback")
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var pendingCallback: Result<URL, Error>?
    private var browserConnection: NWConnection?
    private var didStart = false
    private var didComplete = false
    private var callbackGeneration = 0
    private var stopped = false
    private(set) var port: UInt16 = 0

    var redirectURI: String { "http://127.0.0.1:\(port)\(callbackPath)" }

    init(callbackPath: String) throws {
        self.callbackPath = callbackPath
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters, on: 0)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.startContinuation = continuation
                self.listener.stateUpdateHandler = { state in
                    self.queue.async {
                        switch state {
                        case .ready:
                            guard let port = self.listener.port?.rawValue else {
                                self.finishStart(.failure(GoogleDriveServiceError.authFailed("Could not open the local callback.")))
                                return
                            }
                            self.port = port
                            self.finishStart(.success(()))
                        case .failed(let error):
                            self.finishStart(.failure(error))
                            self.finishCallback(.failure(error))
                        case .cancelled:
                            self.finishStart(.failure(CancellationError()))
                            self.finishCallback(.failure(CancellationError()))
                        default:
                            break
                        }
                    }
                }
                self.listener.newConnectionHandler = { connection in self.receive(connection, buffer: Data()) }
                self.listener.start(queue: self.queue)
            }
        }
    }

    func waitForCallback(timeout: TimeInterval) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let pending = self.pendingCallback {
                        self.pendingCallback = nil
                        continuation.resume(with: pending)
                    } else {
                        self.callbackContinuation = continuation
                        // Tie the timer to this round. Without the generation
                        // check, round one's timer would still be in flight and
                        // would fire straight through round two's wait.
                        let generation = self.callbackGeneration
                        self.queue.asyncAfter(deadline: .now() + timeout) {
                            guard generation == self.callbackGeneration else { return }
                            self.finishCallback(.failure(GoogleDriveServiceError.authFailed("Timed out waiting for Google Drive.")))
                        }
                    }
                }
            }
        } onCancel: {
            self.queue.async { self.finishCallback(.failure(CancellationError())) }
        }
    }

    /// Ends the current wait with a cancellation, from outside the waiting task.
    func cancelWait() {
        queue.async { self.finishCallback(.failure(CancellationError())) }
    }

    func completeBrowserCallback(success: Bool, message: String) {
        queue.async {
            guard let connection = self.browserConnection else { return }
            self.browserConnection = nil
            let title = success ? "Google Drive connected" : "Google Drive sign-in failed"
            let body = "<html><head><meta charset=\"utf-8\"><title>\(title)</title></head><body style=\"font-family:-apple-system,sans-serif;padding:32px\"><h1>\(title)</h1><p>\(self.escape(message))</p></body></html>"
            self.send(connection, status: 200, reason: "OK", body: body, contentType: "text/html; charset=utf-8")
        }
    }

    func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.browserConnection?.cancel()
            self.browserConnection = nil
            self.listener.cancel()
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, error in
            self.queue.async {
                if let error {
                    self.send(connection, status: 500, reason: "Internal Server Error", body: error.localizedDescription)
                    return
                }
                guard let data else {
                    self.send(connection, status: 400, reason: "Bad Request", body: "Invalid callback.")
                    return
                }
                let accumulated = buffer + data
                if accumulated.range(of: Data([13, 10, 13, 10])) == nil, accumulated.count < 16_384 {
                    self.receive(connection, buffer: accumulated)
                    return
                }
                self.handle(accumulated, connection: connection)
            }
        }
    }

    private func handle(_ data: Data, connection: NWConnection) {
        guard let request = String(data: data, encoding: .utf8),
              let requestLine = request.components(separatedBy: "\r\n").first else {
            send(connection, status: 400, reason: "Bad Request", body: "Invalid callback.")
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2,
              let url = URL(string: "http://127.0.0.1:\(port)\(parts[1])"),
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.path == callbackPath else {
            send(connection, status: 404, reason: "Not Found", body: "Not found.")
            return
        }
        browserConnection?.cancel()
        browserConnection = connection
        finishCallback(.success(url))
    }

    private func finishStart(_ result: Result<Void, Error>) {
        guard !didStart, let continuation = startContinuation else { return }
        didStart = true
        startContinuation = nil
        continuation.resume(with: result)
    }

    private func finishCallback(_ result: Result<URL, Error>) {
        guard !stopped, !didComplete else { return }
        didComplete = true
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            continuation.resume(with: result)
        } else if pendingCallback == nil {
            pendingCallback = result
        }
    }

    private func send(
        _ connection: NWConnection,
        status: Int,
        reason: String,
        body: String,
        contentType: String = "text/plain; charset=utf-8"
    ) {
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + bodyData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
