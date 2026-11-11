import Foundation
import Security

enum KeychainService {
    private static let service = "com.foreverlm"
    private static let retiredService = "com.feynmanlm"
    private static let vaultAccount = "__foreverlm_keychain_vault_v1"
    private static let retiredVaultAccount = "__feynmanlm_keychain_vault_v1"
    private static let vaultVersion = 1
    private static let sharedAccessGroupSuffix = "com.foreverlm.shared"
    private static let appIdentifierPrefixInfoKey = "ForeverLMAppIdentifierPrefix"
    private static let defaultOpenAITranscriptionModel = AIModelDefaults.batchTranscription
    private static let defaultMediaTranscriptionModel = AIModelDefaults.batchTranscription

    private static let sharedAccessGroup: String? = {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: appIdentifierPrefixInfoKey) as? String,
              !prefix.isEmpty else {
            return nil
        }
        let normalizedPrefix = prefix.hasSuffix(".") ? prefix : "\(prefix)."
        return "\(normalizedPrefix)\(sharedAccessGroupSuffix)"
    }()

    enum Key: String {
        case openAIAPIKey = "openai_api_key"
        case anthropicAPIKey = "anthropic_api_key"
        case sttModelOpenAI = "stt_model_openai"
        case sttModelMedia = "stt_model_media"
        case managedAISessionToken = "managed_ai_session_token"
        case managedAISessionExpiry = "managed_ai_session_expiry"
        /// The learner's own router key (`ManagedAI.OwnKey`), the same iCloud
        /// Keychain items the Mac writes, so both devices bill one router account.
        case ownOpenRouterKey = "own_openrouter_key"
        /// The learner's own OpenAI key for voice mode, the same iCloud
        /// Keychain item the Mac writes (`ManagedAI.ownOpenAIVoiceKey`).
        case ownOpenAIVoiceKey = "own_openai_voice_key"
    }

    static var openAITranscriptionModel: String {
        get { load(.sttModelOpenAI) ?? defaultOpenAITranscriptionModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                delete(.sttModelOpenAI)
            } else {
                save(trimmed, for: .sttModelOpenAI)
            }
        }
    }

    /// Batch media transcription, chosen separately from dictation. The phone
    /// has no Settings pane for it; it reads whatever the Mac stored so an
    /// imported podcast episode transcribes with the same model either way.
    static var mediaTranscriptionModel: String {
        get { load(.sttModelMedia) ?? defaultMediaTranscriptionModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                delete(.sttModelMedia)
            } else {
                save(trimmed, for: .sttModelMedia)
            }
        }
    }

    // The managed-rail session, read and written by ManagedAI. Raw values match the
    // Mac's KeychainService so the two agree on account names, but this deliberately
    // stays out of syncsAcrossDevices: a session token is device-scoped, and letting
    // the Mac's copy shadow the phone's would hand both devices the same expiring
    // token with no way to tell whose it is.
    static var managedAISessionToken: String? {
        get { load(.managedAISessionToken) }
        set {
            if let newValue {
                save(newValue, for: .managedAISessionToken)
            } else {
                delete(.managedAISessionToken)
            }
        }
    }

    static var managedAISessionExpiry: String? {
        get { load(.managedAISessionExpiry) }
        set {
            if let newValue {
                save(newValue, for: .managedAISessionExpiry)
            } else {
                delete(.managedAISessionExpiry)
            }
        }
    }

    /// Delete keys from the retired client-side AI routes. Provider credentials
    /// now live only in the managed proxy; keeping old synchronized copies on a
    /// phone would serve no feature and needlessly retain secrets.
    static func purgeRetiredProviderData() {
        guard Preferences.value(Prefs.Lifecycle.retiredProviderDataPurged) != true else { return }
        delete(.openAIAPIKey)
        delete(.anthropicAPIKey)
        Preferences.set(true, for: Prefs.Lifecycle.retiredProviderDataPurged)
    }

    static func save(_ value: String, for key: Key) {
        saveIndividual(value, for: key)
        if syncsAcrossDevices(key) {
            updateVaultValue(value, for: key)
        }
    }

    private static func saveIndividual(_ value: String, for key: Key) {
        let data = Data(value.utf8)
        deleteCurrent(key)

        var addQuery = baseQuery(for: key)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if syncsAcrossDevices(key) {
            addQuery[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func load(_ key: Key) -> String? {
        if let value = loadCurrent(key) {
            return value
        }
        if syncsAcrossDevices(key), let value = loadVaultValue(for: key) {
            saveIndividual(value, for: key)
            return value
        }
        return nil
    }

    static func delete(_ key: Key) {
        deleteCurrent(key)
        if syncsAcrossDevices(key) {
            deleteVaultValue(for: key)
        }
    }

    private static func syncsAcrossDevices(_ key: Key) -> Bool {
        key == .openAIAPIKey || key == .anthropicAPIKey
            || key == .ownOpenRouterKey || key == .ownOpenAIVoiceKey
    }

    private static func baseQuery(for key: Key) -> [String: Any] {
        baseQuery(forAccount: key.rawValue)
    }

    private static func baseQuery(forAccount account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let sharedAccessGroup {
            query[kSecAttrAccessGroup as String] = sharedAccessGroup
        }
        return query
    }

    private static func loadCurrent(_ key: Key) -> String? {
        if syncsAcrossDevices(key), let value = loadCurrent(key, synchronizable: kCFBooleanTrue) {
            return value
        }

        if let value = loadCurrent(key, synchronizable: nil) {
            if syncsAcrossDevices(key) {
                save(value, for: key)
            }
            return value
        }

        return nil
    }

    private static func loadCurrent(_ key: Key, synchronizable: CFTypeRef?) -> String? {
        var query = baseQuery(for: key)
        query.merge([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
        if let synchronizable {
            query[kSecAttrSynchronizable as String] = synchronizable
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess,
           let data = result as? Data,
           let value = String(data: data, encoding: .utf8),
           !value.isEmpty {
            return value
        }

        return nil
    }

    private static func deleteCurrent(_ key: Key) {
        var query = baseQuery(for: key)
        if syncsAcrossDevices(key) {
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }
        SecItemDelete(query as CFDictionary)
    }

    private struct VaultPayload: Codable {
        var version: Int
        var values: [String: String]
    }

    private static func loadVaultValue(for key: Key) -> String? {
        guard let vault = loadVault(),
              let value = vault[key.rawValue],
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func updateVaultValue(_ value: String, for key: Key) {
        var vault = loadVault() ?? [:]
        vault[key.rawValue] = value
        saveVault(vault)
    }

    private static func deleteVaultValue(for key: Key) {
        guard var vault = loadVault(),
              vault[key.rawValue] != nil else {
            return
        }
        vault.removeValue(forKey: key.rawValue)
        saveVault(vault)
    }

    private static func loadVault() -> [String: String]? {
        var values: [String: String]?
        for query in vaultLookupQueries() {
            if let decoded = decodeVault(matching: query) {
                values = decoded
                break
            }
        }

        for query in retiredProductVaultLookupQueries() {
            guard let retired = decodeVault(matching: query) else { continue }
            var merged = values ?? [:]
            var added = false
            for (key, value) in retired where merged[key] == nil && !value.isEmpty {
                merged[key] = value
                added = true
            }
            if values == nil || added {
                saveVault(merged)
                values = merged
            }
            break
        }

        return values
    }

    private static func decodeVault(matching query: [String: Any]) -> [String: String]? {
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        if let payload = try? JSONDecoder().decode(VaultPayload.self, from: data) {
            return payload.values
        }
        if let values = try? JSONDecoder().decode([String: String].self, from: data) {
            return values
        }
        return nil
    }

    private static func retiredProductVaultLookupQueries() -> [[String: Any]] {
        vaultStorageQueries().map { query in
            var lookup = query
            lookup[kSecAttrService as String] = retiredService
            lookup[kSecAttrAccount as String] = retiredVaultAccount
            lookup[kSecReturnData as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            return lookup
        }
    }

    private static func saveVault(_ values: [String: String]) {
        let payload = VaultPayload(version: vaultVersion, values: values)
        guard let data = try? JSONEncoder().encode(payload) else {
            return
        }

        for query in vaultStorageQueries() {
            let update: [String: Any] = [
                kSecValueData as String: data,
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if updateStatus == errSecSuccess {
                return
            }
            guard updateStatus == errSecItemNotFound else {
                continue
            }

            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                return
            }
            if addStatus == errSecDuplicateItem,
               SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess {
                return
            }
        }
    }

    private static func vaultLookupQueries() -> [[String: Any]] {
        vaultStorageQueries().map { query in
            var lookup = query
            lookup[kSecReturnData as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            return lookup
        }
    }

    private static func vaultStorageQueries() -> [[String: Any]] {
        var synchronizableQuery = baseQuery(forAccount: vaultAccount)
        synchronizableQuery[kSecAttrSynchronizable as String] = kCFBooleanTrue

        return [
            synchronizableQuery,
            baseQuery(forAccount: vaultAccount),
        ]
    }
}
