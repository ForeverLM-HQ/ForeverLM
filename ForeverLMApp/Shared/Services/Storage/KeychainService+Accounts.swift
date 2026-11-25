// Connector and account credential accessors.

import Foundation
import Security

extension KeychainService {
    private static let zoomRecordingPasscodeAccountPrefix = "zoom_recording_passcode:"

    private static let googleDriveAccountCredentialPrefix = "google_drive_account:"

    private static let xAccountCredentialPrefix = "x_account:"

    private static let googleCalendarAccountCredentialPrefix = "google_calendar_account:"

    private static let youtubeAccountCredentialPrefix = "youtube_account:"

    // MARK: - Source-scoped secrets

    enum GoogleDriveCredentialField: String, CaseIterable {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenExpiry = "token_expiry"
        case grantedScopes = "granted_scopes"
        case clientID = "client_id"
        case clientSecret = "client_secret"
    }

    @discardableResult
    static func saveGoogleDriveCredential(
        _ value: String,
        field: GoogleDriveCredentialField,
        accountID: String
    ) -> Bool {
        guard let account = googleDriveCredentialAccount(field: field, accountID: accountID) else {
            return false
        }
        return saveSynchronizedAccountValue(value, account: account)
    }

    static func googleDriveCredential(
        field: GoogleDriveCredentialField,
        accountID: String
    ) -> String? {
        guard let account = googleDriveCredentialAccount(field: field, accountID: accountID) else {
            return nil
        }
        return loadSynchronizedAccountValue(account: account)
    }

    @discardableResult
    static func deleteGoogleDriveCredential(
        field: GoogleDriveCredentialField,
        accountID: String
    ) -> Bool {
        guard let account = googleDriveCredentialAccount(field: field, accountID: accountID) else {
            return false
        }
        return deleteSynchronizedValue(forAccount: account)
    }

    @discardableResult
    static func deleteGoogleDriveCredentials(accountID: String) -> Bool {
        var succeeded = true
        for field in GoogleDriveCredentialField.allCases {
            guard let account = googleDriveCredentialAccount(field: field, accountID: accountID) else {
                succeeded = false
                continue
            }
            if !deleteSynchronizedValue(forAccount: account) {
                succeeded = false
            }
        }
        return succeeded
    }

    private static func googleDriveCredentialAccount(
        field: GoogleDriveCredentialField,
        accountID: String
    ) -> String? {
        let trimmed = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "\(googleDriveAccountCredentialPrefix)\(trimmed):\(field.rawValue)"
    }

    /// One YouTube account's grant, stored as account-scoped synchronized
    /// items so each Google account keeps its own tokens and issuing client.
    enum YouTubeCredentialField: String, CaseIterable {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenExpiry = "token_expiry"
        case clientID = "client_id"
        case clientSecret = "client_secret"
    }

    @discardableResult
    static func saveYouTubeCredential(
        _ value: String,
        field: YouTubeCredentialField,
        accountID: String
    ) -> Bool {
        guard let account = youtubeCredentialAccount(field: field, accountID: accountID) else { return false }
        return saveSynchronizedAccountValue(value, account: account)
    }

    static func youtubeCredential(field: YouTubeCredentialField, accountID: String) -> String? {
        guard let account = youtubeCredentialAccount(field: field, accountID: accountID) else { return nil }
        return loadSynchronizedAccountValue(account: account)
    }

    @discardableResult
    static func deleteYouTubeCredential(field: YouTubeCredentialField, accountID: String) -> Bool {
        guard let account = youtubeCredentialAccount(field: field, accountID: accountID) else { return false }
        return deleteSynchronizedValue(forAccount: account)
    }

    @discardableResult
    static func deleteYouTubeCredentials(accountID: String) -> Bool {
        var succeeded = true
        for field in YouTubeCredentialField.allCases where !deleteYouTubeCredential(field: field, accountID: accountID) {
            succeeded = false
        }
        return succeeded
    }

    private static func youtubeCredentialAccount(field: YouTubeCredentialField, accountID: String) -> String? {
        let trimmed = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "\(youtubeAccountCredentialPrefix)\(trimmed):\(field.rawValue)"
    }

    // MARK: The retired Google Calendar plugin

    /// The Google Calendar plugin is gone: the
    /// day is the Mac's Calendar, which holds a Google account itself through
    /// System Settings › Internet Accounts. Its grants rode iCloud Keychain,
    /// so without this they would sit there for good with no pane left to
    /// disconnect them. Once per Mac, off-main: every account-scoped grant,
    /// the account list, the calendar choice and the plugin's first single
    /// grant go. Deleting a synced item deletes it on the learner's other
    /// Macs too, which is the point.
    static func purgeRetiredGoogleCalendarGrants() {
        guard Preferences.value(Prefs.Lifecycle.retiredGoogleCalendarGrantsPurged) != true else { return }
        if let raw = load(.googleCalendarAccounts), let data = raw.data(using: .utf8),
           let accounts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for account in accounts {
                guard let id = (account["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { continue }
                for field in ["access_token", "refresh_token", "token_expiry", "client_id", "client_secret"] {
                    _ = deleteSynchronizedValue(forAccount: "\(googleCalendarAccountCredentialPrefix)\(id):\(field)")
                }
            }
        }
        for key: Key in [
            .googleCalendarAccounts, .googleCalendarSelectedIDs,
            .googleCalendarAccessToken, .googleCalendarRefreshToken, .googleCalendarTokenExpiry,
            .googleCalendarClientID, .googleCalendarClientSecret,
        ] {
            delete(key)
        }
        Preferences.set(true, for: Prefs.Lifecycle.retiredGoogleCalendarGrantsPurged)
    }

    // MARK: Account-scoped synchronized items

    /// Write one iCloud-synchronized item under an arbitrary account name —
    /// a per-Google-account token, keyed by the account rather than by `Key`.
    /// Empty values are refused: absence is what "no token" means.
    private static func saveSynchronizedAccountValue(_ value: String, account: String) -> Bool {
        guard !value.isEmpty else { return false }
        _ = deleteSynchronizedValue(forAccount: account)

        let data = Data(value.utf8)
        var addQuery = baseQuery(forAccount: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        addQuery[kSecAttrSynchronizable as String] = kCFBooleanTrue
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    /// Read one account-scoped synchronized item, falling back on macOS to the
    /// ungrouped shape ad-hoc builds write under.
    private static func loadSynchronizedAccountValue(account: String) -> String? {
        if let value = loadSynchronizedValue(matching: baseQuery(forAccount: account)) {
            return value
        }

        #if os(macOS)
        if let value = loadSynchronizedValue(matching: ungroupedDataProtectionBaseQuery(forAccount: account)) {
            return value
        }
        return nil
        #else
        return nil
        #endif
    }

    /// Store a Zoom cloud-recording passcode separately from source metadata.
    ///
    /// Source IDs are stable CloudKit identities, so using one as the Keychain
    /// account keeps the passcode attached to the same recording on every Mac
    /// without exposing it in the source URL or SQLite payload.
    @discardableResult
    static func saveZoomRecordingPasscode(_ passcode: String, forSourceID sourceID: String) -> Bool {
        let trimmed = passcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let account = zoomRecordingPasscodeAccount(for: sourceID) else {
            return false
        }

        _ = deleteSynchronizedValue(forAccount: account)

        let data = Data(trimmed.utf8)
        var addQuery = baseQuery(forAccount: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        addQuery[kSecAttrSynchronizable as String] = kCFBooleanTrue
        if SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess {
            postZoomRecordingPasscodeChange(sourceID: sourceID)
            return true
        }

        // A file-based fallback would attach this passcode to the exact build
        // hash and recreate the repeated login-password prompt.
        return false
    }

    static func zoomRecordingPasscode(forSourceID sourceID: String) -> String? {
        guard let account = zoomRecordingPasscodeAccount(for: sourceID) else {
            return nil
        }

        if let value = loadSynchronizedValue(matching: baseQuery(forAccount: account)) {
            return value
        }

        #if os(macOS)
        if let value = loadSynchronizedValue(matching: ungroupedDataProtectionBaseQuery(forAccount: account)) {
            return value
        }
        return nil
        #else
        return nil
        #endif
    }

    @discardableResult
    static func deleteZoomRecordingPasscode(forSourceID sourceID: String) -> Bool {
        guard let account = zoomRecordingPasscodeAccount(for: sourceID) else {
            return false
        }
        let deleted = deleteSynchronizedValue(forAccount: account)
        if deleted {
            postZoomRecordingPasscodeChange(sourceID: sourceID)
        }
        return deleted
    }

    private static func zoomRecordingPasscodeAccount(for sourceID: String) -> String? {
        let trimmed = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "\(zoomRecordingPasscodeAccountPrefix)\(trimmed)"
    }

    private static func postZoomRecordingPasscodeChange(sourceID: String) {
        NotificationCenter.default.post(
            name: .zoomRecordingPasscodeDidChange,
            object: nil,
            userInfo: ["sourceID": sourceID]
        )
    }

    private static func loadSynchronizedValue(matching baseQuery: [String: Any]) -> String? {
        var query = baseQuery
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func deleteSynchronizedValue(forAccount account: String) -> Bool {
        var succeeded = true
        var currentQuery = baseQuery(forAccount: account)
        currentQuery[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        let currentStatus = SecItemDelete(currentQuery as CFDictionary)
        if currentStatus != errSecSuccess, currentStatus != errSecItemNotFound {
            succeeded = false
        }

        #if os(macOS)
        var ungroupedQuery = ungroupedDataProtectionBaseQuery(forAccount: account)
        ungroupedQuery[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        let ungroupedStatus = SecItemDelete(ungroupedQuery as CFDictionary)
        if ungroupedStatus != errSecSuccess, ungroupedStatus != errSecItemNotFound {
            succeeded = false
        }
        #endif
        return succeeded
    }

    // MARK: - Convenience

    /// Persist managed-session state and notify dependent AI surfaces.
    private static func saveManagedSessionValue(_ newValue: String?, for key: Key) {
        let oldValue = load(key)
        if let newValue { save(newValue, for: key) }
        else { delete(key) }
        if oldValue != newValue {
            NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
        }
    }

    // Signing in or out of the managed rail changes
    // which surfaces are available, so dependent UI must refresh with it.
    static var managedAISessionToken: String? {
        get { load(.managedAISessionToken) }
        set { saveManagedSessionValue(newValue, for: .managedAISessionToken) }
    }

    static var managedAISessionExpiry: String? {
        get { load(.managedAISessionExpiry) }
        set { saveManagedSessionValue(newValue, for: .managedAISessionExpiry) }
    }

    // MARK: - MCP OAuth

    static var mcpOAuthClientID: String? {
        get { load(.mcpOAuthClientID) }
        set {
            if let newValue { save(newValue, for: .mcpOAuthClientID) }
            else { delete(.mcpOAuthClientID) }
        }
    }

    static var mcpOAuthClientSecret: String? {
        get { load(.mcpOAuthClientSecret) }
        set {
            if let newValue { save(newValue, for: .mcpOAuthClientSecret) }
            else { delete(.mcpOAuthClientSecret) }
        }
    }

    /// Generate MCP OAuth credentials if they don't exist yet.
    /// Returns (clientID, clientSecret).
    static func ensureMCPOAuthCredentials() -> (clientID: String, clientSecret: String) {
        if let existing = mcpOAuthClientID, let secret = mcpOAuthClientSecret,
           !existing.isEmpty, !secret.isEmpty {
            return (existing, secret)
        }
        // Generate new random credentials (once)
        let clientID = "foreverlm-mcp-\(randomHex(8))"
        let clientSecret = randomHex(32)
        mcpOAuthClientID = clientID
        mcpOAuthClientSecret = clientSecret
        return (clientID, clientSecret)
    }

    private static func randomHex(_ bytes: Int) -> String {
        var data = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &data)
        return data.hexString
    }

    // MARK: - X (Twitter) accounts

    /// JSON list of the connected accounts (`XAccountBook`).
    static var xAccounts: String? {
        get { load(.xAccounts) }
        set {
            if let newValue { save(newValue, for: .xAccounts) }
            else { delete(.xAccounts) }
        }
    }

    /// One account's credentials JSON (`XAccountCredentials`), in an item of
    /// its own so accounts never share a write. Local to this Mac, like every
    /// X credential.
    @discardableResult
    static func saveXAccountCredentials(_ value: String, accountID: String) -> Bool {
        guard !value.isEmpty, let account = xAccountCredentialsAccount(accountID) else { return false }
        _ = deleteXAccountCredentialsItem(account)
        var addQuery = baseQuery(forAccount: account)
        addQuery[kSecValueData as String] = Data(value.utf8)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    static func xAccountCredentials(accountID: String) -> String? {
        guard let account = xAccountCredentialsAccount(accountID) else { return nil }
        var queries = [baseQuery(forAccount: account)]
        #if os(macOS)
        queries.append(ungroupedDataProtectionBaseQuery(forAccount: account))
        #endif
        for var query in queries {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
               let data = result as? Data,
               let value = String(data: data, encoding: .utf8), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    @discardableResult
    static func deleteXAccountCredentials(accountID: String) -> Bool {
        guard let account = xAccountCredentialsAccount(accountID) else { return false }
        return deleteXAccountCredentialsItem(account)
    }

    private static func xAccountCredentialsAccount(_ accountID: String) -> String? {
        let trimmed = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "\(xAccountCredentialPrefix)\(trimmed)"
    }

    private static func deleteXAccountCredentialsItem(_ account: String) -> Bool {
        var succeeded = true
        var queries = [baseQuery(forAccount: account)]
        #if os(macOS)
        queries.append(ungroupedDataProtectionBaseQuery(forAccount: account))
        #endif
        for query in queries {
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess, status != errSecItemNotFound { succeeded = false }
        }
        return succeeded
    }

    // MARK: - Google Drive OAuth

    static var googleDriveAccounts: String? {
        get { load(.googleDriveAccounts) }
        set {
            if let newValue { save(newValue, for: .googleDriveAccounts) }
            else { delete(.googleDriveAccounts) }
        }
    }

    static var googleDriveDefaultAccountID: String? {
        get { load(.googleDriveDefaultAccountID) }
        set {
            if let newValue { save(newValue, for: .googleDriveDefaultAccountID) }
            else { delete(.googleDriveDefaultAccountID) }
        }
    }

    // MARK: - YouTube OAuth
    //
    // The YouTube plugin authenticates against ForeverLM's own OAuth client
    // (Secrets.youtubeOAuthClientID). Each account records whichever client
    // issued its tokens (`YouTubeCredentialField.clientID`), so connections
    // made under the older shared-with-Drive client keep refreshing.

    static var youtubeAccounts: String? {
        get { load(.youtubeAccounts) }
        set {
            if let newValue { save(newValue, for: .youtubeAccounts) }
            else { delete(.youtubeAccounts) }
        }
    }

    static var appleUserID: String? {
        get { load(.appleUserID) }
        set {
            if let newValue, !newValue.isEmpty { save(newValue, for: .appleUserID) }
            else { delete(.appleUserID) }
        }
    }

    static var appleUserName: String? {
        get { load(.appleUserName) }
        set {
            if let newValue, !newValue.isEmpty { save(newValue, for: .appleUserName) }
            else { delete(.appleUserName) }
        }
    }

    static var appleUserEmail: String? {
        get { load(.appleUserEmail) }
        set {
            if let newValue, !newValue.isEmpty { save(newValue, for: .appleUserEmail) }
            else { delete(.appleUserEmail) }
        }
    }
}
