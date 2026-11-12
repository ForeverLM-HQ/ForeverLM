import Foundation
import OSLog
import Security

extension Notification.Name {
    /// Posted whenever any AI text-model selection changes: the default provider
    /// (`KeychainService.aiProvider`), the background-tasks models, or the chat's own
    /// pick from the chat bar. UI that displays a current model
    /// (the Studio assistant launcher logo, the Settings selectors, the inline chat picker)
    /// observes this so it can never drift out of sync with the stored values.
    static let aiProviderDidChange = Notification.Name("aiProviderDidChange")
    /// Posted after a source-scoped Zoom passcode is saved or removed so an
    /// already-open recording can update without polling Keychain.
    static let zoomRecordingPasscodeDidChange = Notification.Name("zoomRecordingPasscodeDidChange")
}

/// Stores and retrieves API keys from the system Keychain.
enum KeychainService {
    
    private static let service = ForeverLMRuntimeIdentity.keychainService
    private static let retiredService = "com.feynmanlm"
    #if os(macOS)
    private static let vaultAccount = ForeverLMRuntimeIdentity.keychainVaultAccount
    private static let retiredVaultAccount = "__feynmanlm_keychain_vault_v1"
    private static let vaultVersion = 1
    private static let vaultLock = NSRecursiveLock()
    private static let vaultLogger = Logger(subsystem: "ForeverLM", category: "KeychainVault")

    /// The Keychain calls the vault makes, and the vault as this process last
    /// read it. The app runs on `.system`; a test runs its own backend through
    /// `$vaultBackend.withValue` to stand in for a Keychain that cannot be read,
    /// without touching the real vault or another test's.
    final class VaultBackend: @unchecked Sendable {
        let copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
        let update: (CFDictionary, CFDictionary) -> OSStatus
        let add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
        /// The vault as last read or written; nil until a read has succeeded.
        /// Held under `vaultLock`.
        fileprivate var cachedVault: [String: String]?
        /// Why the last read of the vault failed; nil once it has been read.
        /// Held under `vaultLock`.
        fileprivate var readFailure: OSStatus?

        init(
            copyMatching: @escaping (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus,
            update: @escaping (CFDictionary, CFDictionary) -> OSStatus,
            add: @escaping (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
        ) {
            self.copyMatching = copyMatching
            self.update = update
            self.add = add
        }

        static let system = VaultBackend(copyMatching: SecItemCopyMatching, update: SecItemUpdate, add: SecItemAdd)
    }

    @TaskLocal static var vaultBackend: VaultBackend = .system
    #endif

    /// The Keychain holds a vault this process could not read: locked
    /// (`errSecInteractionNotAllowed`), refused, or a payload this build cannot
    /// decode (`errSecDecode`). Not the same as a value that was never stored,
    /// and nothing is written over the vault while it stands.
    struct VaultUnavailableError: Error, LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            let reason = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "OSStatus \(status)"
            return "The Keychain could not be read (\(reason)). Stored credentials are unchanged; try again once the Mac is unlocked."
        }
    }
    /// Non-synced keys known absent from the individual Keychain, so repeated
    /// reads of a missing value (e.g. `managedAISessionToken` while signed out)
    /// don't pay a securityd IPC round-trip each time — reads happen on the
    /// main thread from view code, and a miss is otherwise never memoized the
    /// way a hit is (hits self-heal into the vault). Synced keys stay out:
    /// iCloud Keychain can materialize those behind the process's back.
    private static let missLock = AppLock()
    private static var missedIndividualKeys = Set<String>()

    private static func individualMissCached(_ key: Key) -> Bool {
        missLock.lock()
        defer { missLock.unlock() }
        return missedIndividualKeys.contains(key.rawValue)
    }

    private static func cacheIndividualMiss(_ key: Key) {
        guard !syncsAcrossDevices(key) else { return }
        missLock.lock()
        defer { missLock.unlock() }
        missedIndividualKeys.insert(key.rawValue)
    }

    private static func clearIndividualMiss(_ key: Key) {
        missLock.lock()
        defer { missLock.unlock() }
        missedIndividualKeys.remove(key.rawValue)
    }
    private static let sharedAccessGroupSuffix = ForeverLMRuntimeIdentity.keychainAccessGroupSuffix
    /// The retired FeynmanLM sharing group. The rename changed the Keychain
    /// service AND the access group, and an access group is enforced by the
    /// signed entitlement: without `$(AppIdentifierPrefix)com.feynmanlm.shared`
    /// listed in `keychain-access-groups`, every retired-vault lookup below
    /// misses no matter which service or account it asks for, and an upgrading
    /// install silently loses the whole vault — Apple user ID included, which
    /// takes MCP provisioning down with it. Keep this entitlement until no
    /// FeynmanLM install is left to adopt.
    private static let retiredSharedAccessGroupSuffix = "com.feynmanlm.shared"
    private static let appIdentifierPrefixInfoKey = "ForeverLMAppIdentifierPrefix"

    private static let sharedAccessGroup: String? = {
        KeychainAccess.sharedGroup(suffix: sharedAccessGroupSuffix)
    }()

    /// Non-nil only while the retired group is still in the signed entitlement,
    /// because `KeychainAccess.sharedGroup` verifies it there. That makes a
    /// dropped entitlement fail closed and visibly, rather than degrading into
    /// an adoption that quietly finds nothing.
    private static let retiredSharedAccessGroup: String? = {
        KeychainAccess.sharedGroup(suffix: retiredSharedAccessGroupSuffix)
    }()

    enum Key: String, CaseIterable {
        case anthropicAPIKey = "anthropic_api_key"
        case openAIAPIKey = "openai_api_key"
        case groqAPIKey = "groq_api_key"
        case cerebrasAPIKey = "cerebras_api_key"
        case geminiAPIKey = "gemini_api_key"
        case xaiAPIKey = "xai_api_key"
        /// Retired direct-Meta trial credential. Kept only so upgrades can
        /// delete the old Keychain item; no request path can read or write it.
        case retiredMetaTrialAPIKey = "meta_api_key"
        case fireworksAPIKey = "fireworks_api_key"
        case nvidiaAPIKey = "nvidia_api_key"
        case openRouterAPIKey = "openrouter_api_key"
        /// The learner's own router key (`ManagedAI.OwnKey`): requests go to the
        /// router with it and the router bills the learner directly. Distinct
        /// from the retired `openRouterAPIKey` slot, which the upgrade purge
        /// deletes; this one is never purged.
        case ownOpenRouterKey = "own_openrouter_key"
        /// The learner's own OpenAI API key for voice mode
        /// (`ManagedAI.ownOpenAIVoiceKey`, product owner, 2026-11-08): voice
        /// sessions are opened on it straight with OpenAI, which bills the
        /// learner. Its own slot, not the retired `openAIAPIKey` one, which
        /// the upgrade purge deletes.
        case ownOpenAIVoiceKey = "own_openai_voice_key"
        /// This account's X25519 private key for family plans, raw and base64
        /// (docs/family-design.md). A parent seals a child's OpenRouter key to
        /// its public half; only this Keychain can open it. Synced, so a
        /// child's other Macs open the same sealed key.
        case familyDeviceKey = "family_device_key"
        /// `updated_at` of the family key the own key was last set from, so
        /// the same sealed key is applied once and a key the learner set
        /// themselves is never replaced by one from the family.
        case familyAppliedKeyStamp = "family_applied_key_stamp"
        case elevenLabsAPIKey = "elevenlabs_api_key"
        case togetherAIAPIKey = "together_api_key"
        case wisprAPIKey = "wispr_api_key"
        case assemblyAIAPIKey = "assemblyai_api_key"
        case cartesiaAPIKey = "cartesia_api_key"
        case anthropicModel = "anthropic_model"
        case openAIModel = "openai_model"
        case groqModel = "groq_model"
        case cerebrasModel = "cerebras_model"
        case xaiModel = "xai_model"
        case geminiModel = "gemini_model"
        case metaModel = "meta_model"
        case togetherModel = "together_model"
        case fireworksModel = "fireworks_model"
        case nvidiaModel = "nvidia_model"
        case openRouterModel = "openrouter_model"
        case sttProvider = "stt_provider"
        case sttModelOpenAI = "stt_model_openai"
        case sttModelMedia = "stt_model_media"
        case sttModelGroq = "stt_model_groq"
        case sttModelOpenRouter = "stt_model_openrouter"
        case sttModelWispr = "stt_model_wispr"
        case sttModelWhisperKit = "stt_model_whisperkit"
        case sttModelAssemblyAI = "stt_model_assemblyai"
        case sttModelCartesia = "stt_model_cartesia"
        case sttLocalServerURL = "stt_local_server_url"
        case sttModelTailscale = "stt_model_tailscale"
        case ttsProvider = "tts_provider"
        case ttsModelApple = "tts_model_apple"
        case ttsModelOpenAI = "tts_model_openai"
        case ttsModelGroq = "tts_model_groq"
        case ttsModelElevenLabs = "tts_model_elevenlabs"
        case ttsModelTogetherAI = "tts_model_together"
        case ttsModelLocalMac = "tts_model_local_mac"
        case ttsModelXAI = "tts_model_xai"
        case ttsModelOpenRouter = "tts_model_openrouter"
        case ttsModelGemini = "tts_model_gemini"
        case ttsModelCartesia = "tts_model_cartesia"
        case ttsModelTailscale = "tts_model_tailscale"
        case ttsLocalServerURL = "tts_local_server_url"
        case aiProvider = "ai_provider"
        case appleUserID = "apple_user_id"
        case appleUserName = "apple_user_name"
        case appleUserEmail = "apple_user_email"
        case stripeAPIKey = "stripe_api_key"
        case stripeMonthlyLink = "stripe_monthly_link"
        case stripeYearlyLink = "stripe_yearly_link"
        /// The connected X accounts, as JSON (`XAccountBook`). Each account's
        /// tokens live in an account-scoped item (`x_account:<id>`). Not synced:
        /// X refresh tokens are single-use, so two Macs sharing one grant would
        /// retire each other's.
        case xAccounts = "x_accounts_v1"
        case googleDriveAccounts = "google_drive_accounts_v2"
        /// Account used for account-agnostic Drive actions such as creating a
        /// Google Doc. Folder and recording reads always use their tagged owner.
        case googleDriveDefaultAccountID = "google_drive_default_account_id_v2"
        case youtubeAutoImportEnabled = "youtube_auto_import_enabled"
        /// JSON array of the YouTube accounts the plugin holds; each account's
        /// grant lives in account-scoped items (`youtube_account:<id>:<field>`).
        case youtubeAccounts = "youtube_accounts_v1"
        /// The retired Google Calendar plugin's grant, its issuing client,
        /// and the calendars the Planner drew from. Kept only so
        /// `purgeRetiredGoogleCalendarGrants` can delete what the plugin
        /// stored; nothing reads them.
        case googleCalendarAccessToken = "google_calendar_access_token"
        case googleCalendarRefreshToken = "google_calendar_refresh_token"
        case googleCalendarTokenExpiry = "google_calendar_token_expiry"
        case googleCalendarClientID = "google_calendar_client_id"
        case googleCalendarClientSecret = "google_calendar_client_secret"
        case googleCalendarSelectedIDs = "google_calendar_selected_ids"
        /// JSON array of the Google accounts the plugin held; each account's
        /// grant lives in account-scoped items
        /// (`google_calendar_account:<id>:<field>`).
        case googleCalendarAccounts = "google_calendar_accounts_v1"
        case mcpOAuthClientID = "mcp_oauth_client_id"
        case mcpOAuthClientSecret = "mcp_oauth_client_secret"
        case mcpOAuthDynamicClients = "mcp_oauth_dynamic_clients"
        case mcpOAuthTokens = "mcp_oauth_tokens"
        case mcpTunnelToken = "mcp_tunnel_token"
        case mcpTunnelURL = "mcp_tunnel_url"
        /// The identity hash the cached tunnel was provisioned under, so a
        /// build whose identity rule changed re-provisions instead of reusing
        /// a tunnel that is now another build's.
        case mcpTunnelIdentity = "mcp_tunnel_identity"
        /// Managed AI ("ForeverLM AI") session minted from Sign in with Apple.
        /// Local to this Mac: the token is device-scoped and cheap to re-mint,
        /// so it deliberately does not ride iCloud Keychain.
        ///
        /// Carries no AI traffic — every provider request goes through
        /// the Cloudflare AI Gateway. It is purely an identity/billing
        /// credential (launch gate, credits, Stripe portal).
        case managedAISessionToken = "managed_ai_session_token"
        case managedAISessionExpiry = "managed_ai_session_expiry"
    }

    /// Plugin credentials ride iCloud Keychain so the same Google account
    /// and explicitly selected Drive folders remain available on the user's
    /// Macs. The selected meeting groups themselves sync through SQLite and
    /// CloudKit; these tokens only let each Mac refresh their contents.
    private static let syncedKeys: Set<Key> = [
        .openAIAPIKey,
        // The learner's own router key follows them to their other devices, so
        // the iPhone is billed to the same router account the Mac is.
        .ownOpenRouterKey,
        // The voice key too, so the iPhone's voice mode runs on it as well.
        .ownOpenAIVoiceKey,
        // A child's other Macs open the same sealed family key, and know it
        // was the family's key that they hold (docs/family-design.md).
        .familyDeviceKey,
        .familyAppliedKeyStamp,
        .googleDriveAccounts,
        .googleDriveDefaultAccountID,
        .youtubeAutoImportEnabled,
        .youtubeAccounts,
        .googleCalendarAccessToken,
        .googleCalendarRefreshToken,
        .googleCalendarTokenExpiry,
        .googleCalendarClientID,
        .googleCalendarClientSecret,
        .googleCalendarSelectedIDs,
        .googleCalendarAccounts,
    ]

    private static func syncsAcrossDevices(_ key: Key) -> Bool {
        syncedKeys.contains(key)
    }

    /// Keys that are *selections*, not secrets: which provider and model to use for
    /// chat, speech-to-text and text-to-speech. They live in `UserDefaults`
    /// rather than the Keychain vault.
    ///
    /// The vault is reached through a team-prefixed access group (see
    /// `KeychainAccess.sharedGroup`), so rebuilding under a different signing
    /// identity makes it unreadable and every model pick silently reverts to its
    /// default. Nothing here is sensitive — leaking "the user picked Opus 4.8"
    /// costs nothing — so the vault bought no security and cost persistence.
    ///
    /// Credentials stay in the Keychain. Never add an `*_api_key`, `*_access_token`,
    /// `*_refresh_token`, `*_client_secret`, `*_token_expiry`, `mcp_*`,
    /// `managed_ai_session_*`, `apple_user_*` or `stripe_*` key to this set. The
    /// OAuth *client IDs* also stay put despite not being secret: they already ride
    /// iCloud Keychain paired with secrets that don't, and splitting a pair strands
    /// a synced ID next to an unsynced secret.
    /// The preference row behind a `Key` that is a selection, typed. Every other key
    /// is a credential or a toggle and stays in the Keychain. A test holds each
    /// `rawValue` of the keys below to the declared name.
    private enum PreferenceSlot {
        case account(AccountKey<String?>)
        case device(DeviceKey<String?>)

        var stored: String? {
            switch self {
            case let .account(key): return Preferences.value(key)
            case let .device(key): return Preferences.value(key)
            }
        }

        func write(_ value: String?) {
            switch self {
            case let .account(key): Preferences.set(value, for: key)
            case let .device(key): Preferences.set(value, for: key)
            }
        }
    }

    private static func preferenceSlot(for key: Key) -> PreferenceSlot? {
        switch key {
        case .aiProvider: return .account(Prefs.Models.aiProvider)
        case .anthropicModel: return .account(Prefs.Models.anthropicModel)
        case .openAIModel: return .account(Prefs.Models.openAIModel)
        case .groqModel: return .account(Prefs.Models.groqModel)
        case .cerebrasModel: return .account(Prefs.Models.cerebrasModel)
        case .xaiModel: return .account(Prefs.Models.xaiModel)
        case .geminiModel: return .account(Prefs.Models.geminiModel)
        case .metaModel: return .account(Prefs.Models.metaModel)
        case .togetherModel: return .account(Prefs.Models.togetherModel)
        case .fireworksModel: return .account(Prefs.Models.fireworksModel)
        case .nvidiaModel: return .account(Prefs.Models.nvidiaModel)
        case .openRouterModel: return .account(Prefs.Models.openRouterModel)
        case .sttProvider: return .account(Prefs.Models.sttProvider)
        case .sttModelOpenAI: return .account(Prefs.Models.sttModelOpenAI)
        case .sttModelGroq: return .account(Prefs.Models.sttModelGroq)
        case .sttModelOpenRouter: return .account(Prefs.Models.sttModelOpenRouter)
        case .sttModelWispr: return .account(Prefs.Models.sttModelWispr)
        case .sttModelWhisperKit: return .account(Prefs.Models.sttModelWhisperKit)
        case .sttModelAssemblyAI: return .account(Prefs.Models.sttModelAssemblyAI)
        case .sttModelCartesia: return .account(Prefs.Models.sttModelCartesia)
        case .sttModelTailscale: return .account(Prefs.Models.sttModelTailscale)
        case .sttLocalServerURL: return .account(Prefs.Models.sttLocalServerURL)
        case .ttsProvider: return .account(Prefs.Models.ttsProvider)
        case .ttsModelApple: return .account(Prefs.Models.ttsModelApple)
        case .ttsModelOpenAI: return .account(Prefs.Models.ttsModelOpenAI)
        case .ttsModelGroq: return .account(Prefs.Models.ttsModelGroq)
        case .ttsModelElevenLabs: return .account(Prefs.Models.ttsModelElevenLabs)
        case .ttsModelTogetherAI: return .account(Prefs.Models.ttsModelTogetherAI)
        case .ttsModelLocalMac: return .account(Prefs.Models.ttsModelLocalMac)
        case .ttsModelXAI: return .account(Prefs.Models.ttsModelXAI)
        case .ttsModelOpenRouter: return .account(Prefs.Models.ttsModelOpenRouter)
        case .ttsModelGemini: return .account(Prefs.Models.ttsModelGemini)
        case .ttsModelCartesia: return .account(Prefs.Models.ttsModelCartesia)
        case .ttsModelTailscale: return .account(Prefs.Models.ttsModelTailscale)
        case .ttsLocalServerURL: return .account(Prefs.Models.ttsLocalServerURL)
        case .sttModelMedia: return .device(Prefs.Models.sttModelMedia)
        default: return nil
        }
    }

    static func save(_ value: String, for key: Key) {
        clearIndividualMiss(key)
        if let slot = preferenceSlot(for: key) {
            // The Keychain copy is deliberately left in place rather than deleted:
            // `load` prefers UserDefaults, so it can never shadow this write, and
            // leaving it keeps a downgrade to a build without this routing working.
            // `delete` clears both so a reset stays a reset.
            //
            // Empty is stored as absent, matching `loadVaultValue`'s `!value.isEmpty`
            // guard. Callers rely on it: `load(.ttsModelOpenRouter) ?? defaultModel`
            // must yield the default for a cleared field, not "".
            slot.write(value.isEmpty ? nil : value)
            return
        }
        #if os(macOS)
        if syncsAcrossDevices(key) {
            // Synced credentials/toggles live only as iCloud Keychain
            // (synchronizable) individual items so rotated OAuth tokens and
            // toggle changes propagate between devices. They must stay OUT of
            // the local vault, whose in-memory cache would otherwise shadow a
            // newer value synced in from another Mac.
            saveIndividual(value, for: key)
            _ = deleteVaultValue(for: key)
            return
        }
        switch saveVaultValue(value, for: key) {
        case .written:
            return
        case .refused(let status):
            // Not written anywhere else either: an individual item written now
            // would be shadowed by the vault's own copy once the vault reads.
            vaultLogger.error("Did not save \(key.rawValue, privacy: .public): the Keychain vault could not be read (OSStatus \(status)).")
            return
        case .failed:
            break
        }
        #endif

        saveIndividual(value, for: key)
    }

    private static func saveIndividual(_ value: String, for key: Key) {
        let data = Data(value.utf8)

        #if os(macOS)
        // Never fall back to the file-based login Keychain. Ad-hoc test builds
        // have no stable application identifier, so that implementation binds
        // an item to the build's exact CDHash and macOS asks for the login
        // password again after every rebuild. A build without data-protection
        // Keychain access stays signed out instead of creating prompt-generating
        // state. Properly signed development and distribution builds have the
        // shared access-group entitlement and succeed here.
        _ = saveIndividualToDataProtectionKeychain(data, for: key)
        #else
        deleteCurrent(key)

        var addQuery = baseQuery(for: key)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if syncsAcrossDevices(key) {
            addQuery[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }
        SecItemAdd(addQuery as CFDictionary, nil)
        #endif
    }

    #if os(macOS)
    private static func saveIndividualToDataProtectionKeychain(_ data: Data, for key: Key) -> Bool {
        deleteCurrent(key)

        var addQuery = baseQuery(for: key)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if syncsAcrossDevices(key) {
            addQuery[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }
        if SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess {
            return true
        }

        // A shared access group can be unavailable in ad-hoc or otherwise
        // unusually signed development builds. Stay on the data-protection
        // keychain in that case: falling straight through to the
        // file-based login keychain gives the item an app-signature ACL and
        // makes macOS ask for the login password again when another valid
        // ForeverLM build accesses it.
        let fallbackQuery = ungroupedDataProtectionBaseQuery(for: key)
        var deleteQuery = fallbackQuery
        if syncsAcrossDevices(key) {
            deleteQuery[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }
        SecItemDelete(deleteQuery as CFDictionary)

        var fallbackAddQuery = fallbackQuery
        fallbackAddQuery[kSecValueData as String] = data
        fallbackAddQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if syncsAcrossDevices(key) {
            fallbackAddQuery[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }
        return SecItemAdd(fallbackAddQuery as CFDictionary, nil) == errSecSuccess
    }
    #endif
    
    static func load(_ key: Key) -> String? {
        if let slot = preferenceSlot(for: key) {
            if let value = slot.stored, !value.isEmpty {
                return value
            }
            // Not migrated yet: promote the existing Keychain value on first read,
            // the same shape as the vault promotion below. Lazy by design — CLAUDE.md
            // forbids migrations that run at launch, and this costs one read per key
            // per install rather than a startup pass.
            guard let migrated = loadFromKeychain(key) else { return nil }
            slot.write(migrated)
            return migrated
        }
        return loadFromKeychain(key)
    }

    /// `load`, but a Keychain vault that could not be read throws rather than
    /// reading as a value never stored. Use it where a missing value leads to
    /// an action: minting a replacement, signing out, telling the learner to
    /// connect again.
    static func loadIfReadable(_ key: Key) throws -> String? {
        if let value = load(key) {
            return value
        }
        #if os(macOS)
        if let status = withVaultLock({ vaultBackend.readFailure }) {
            throw VaultUnavailableError(status: status)
        }
        #endif
        return nil
    }

    private static func loadFromKeychain(_ key: Key) -> String? {
        #if os(macOS)
        if syncsAcrossDevices(key) {
            // Prefer the iCloud-synchronized item so a value rotated on another
            // device (e.g. a Read AI refresh token) is read fresh. Fall back to
            // the local vault only if no synced item exists yet (a value written
            // before this key became synced); the next save promotes it.
            if let value = loadIndividual(key) {
                return value
            }
            guard case .value(let value) = loadVaultValue(for: key) else { return nil }
            return value
        }

        switch loadVaultValue(for: key) {
        case .value(let value):
            return value
        case .unavailable:
            // Unknown, not missing: an individual item may be older than the
            // vault's copy, and promoting it would be a write.
            return nil
        case .missing:
            break
        }

        if individualMissCached(key) {
            return nil
        }
        if let value = loadIndividual(key) {
            _ = saveVaultValue(value, for: key)
            return value
        }
        cacheIndividualMiss(key)
        #else
        if individualMissCached(key) {
            return nil
        }
        if let value = loadIndividual(key) {
            return value
        }
        cacheIndividualMiss(key)
        #endif

        return nil
    }

    private static func loadIndividual(_ key: Key) -> String? {
        if let value = loadCurrent(key) {
            return value
        }

        #if os(macOS)
        if let value = loadUngroupedDataProtection(key) {
            return value
        }
        #endif

        return nil
    }

    static func baseQuery(for key: Key) -> [String: Any] {
        baseQuery(forAccount: key.rawValue)
    }

    static func baseQuery(forAccount account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let sharedAccessGroup {
            query[kSecAttrAccessGroup as String] = sharedAccessGroup
        }
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    #if os(macOS)
    static func ungroupedDataProtectionBaseQuery(for key: Key) -> [String: Any] {
        ungroupedDataProtectionBaseQuery(forAccount: key.rawValue)
    }

    static func ungroupedDataProtectionBaseQuery(forAccount account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    #endif

    private enum KeychainAccess {
        static func sharedGroup(suffix: String) -> String? {
            guard let prefix = Bundle.main.object(forInfoDictionaryKey: appIdentifierPrefixInfoKey) as? String,
                  !prefix.isEmpty else {
                return nil
            }
            let normalizedPrefix = prefix.hasSuffix(".") ? prefix : "\(prefix)."
            let group = "\(normalizedPrefix)\(suffix)"
            #if os(macOS)
            // Info.plist survives ad-hoc re-signing, but the entitlement does not.
            // Trust the process's signed entitlement so a re-signed test build can
            // never fall through to the ACL-based login keychain.
            guard let task = SecTaskCreateFromSelf(nil),
                  let groups = SecTaskCopyValueForEntitlement(
                      task,
                      "keychain-access-groups" as CFString,
                      nil
                  ) as? [String],
                  groups.contains(group) else {
                return nil
            }
            #endif
            return group
        }
    }

    #if os(macOS)
    private struct VaultPayload: Codable {
        var version: Int
        var values: [String: String]
    }

    /// What one key's vault entry is.
    private enum VaultValue {
        case value(String)
        case missing
        /// The vault could not be read, so whether the key is stored is unknown.
        case unavailable(OSStatus)
    }

    /// What a write to the vault came to.
    private enum VaultWrite {
        case written
        /// The vault was read but the Keychain refused the write.
        case failed
        /// The vault could not be read, so nothing was written over it.
        case refused(OSStatus)
    }

    /// The vault, read once per process and cached; `.failure` while it cannot
    /// be read. Only a vault the Keychain reports absent is rebuilt from the
    /// individual items. A read that failed is not cached, so the next call
    /// asks the Keychain again (a locked Mac unlocks). Held under `vaultLock`.
    private static func readableVault() -> Result<[String: String], VaultUnavailableError> {
        let backend = vaultBackend
        if let cached = backend.cachedVault {
            return .success(cached)
        }
        switch loadVault() {
        case .found(let values):
            backend.cachedVault = values
        case .absent:
            backend.cachedVault = bootstrapVaultFromIndividualItems()
        case .unreadable(let status):
            if backend.readFailure != status {
                vaultLogger.error("Keychain vault could not be read (OSStatus \(status)); it is left as stored and nothing is written over it until it reads.")
            }
            backend.readFailure = status
            return .failure(VaultUnavailableError(status: status))
        }
        backend.readFailure = nil
        return .success(backend.cachedVault ?? [:])
    }

    private static func loadVaultValue(for key: Key) -> VaultValue {
        withVaultLock {
            switch readableVault() {
            case .failure(let error):
                return .unavailable(error.status)
            case .success(let vault):
                guard let value = vault[key.rawValue], !value.isEmpty else { return .missing }
                return .value(value)
            }
        }
    }

    private static func saveVaultValue(_ value: String, for key: Key) -> VaultWrite {
        writeVault { $0[key.rawValue] = value }
    }

    private static func deleteVaultValue(for key: Key) -> VaultWrite {
        writeVault { $0.removeValue(forKey: key.rawValue) }
    }

    /// Changes the vault as read, never a vault that could not be read: the
    /// write replaces the whole item, so writing from an empty stand-in would
    /// erase every credential it holds.
    private static func writeVault(_ change: (inout [String: String]) -> Void) -> VaultWrite {
        withVaultLock {
            var vault: [String: String]
            switch readableVault() {
            case .failure(let error):
                return .refused(error.status)
            case .success(let read):
                vault = read
            }
            change(&vault)
            guard saveVault(vault) else {
                return .failed
            }
            vaultBackend.cachedVault = vault
            return .written
        }
    }

    /// Runs `body` under `vaultLock`. What it settled about the retired vault is written to
    /// UserDefaults only once the outermost hold is released: a defaults write under a lock is the
    /// Swift trap AGENTS.md names, and these reads run on the main thread from view code.
    private static func withVaultLock<T>(_ body: () -> T) -> T {
        vaultLock.lock()
        vaultLockDepth += 1
        let result = body()
        vaultLockDepth -= 1
        let settle = vaultLockDepth == 0 && retiredFileVaultSettlePending
        if settle { retiredFileVaultSettlePending = false }
        vaultLock.unlock()
        if settle { Preferences.persist(true, for: Prefs.Lifecycle.retiredFileVaultAdopted) }
        return result
    }

    /// What reading the vault item found.
    private enum VaultRead {
        case found([String: String])
        /// The Keychain reports no such item.
        case absent
        /// Any other answer, or a payload this build cannot decode.
        case unreadable(OSStatus)
    }

    /// Reads the vault. Only `errSecItemNotFound` from every place the vault
    /// is stored makes it absent; a vault that is there but cannot be read is
    /// never mistaken for none, since what follows an absent vault writes one.
    private static func loadVault() -> VaultRead {
        var values: [String: String]?
        for query in vaultLookupQueries() {
            switch readVault(matching: query) {
            case .found(let decoded):
                values = decoded
            case .absent:
                continue
            case .unreadable(let status):
                return .unreadable(status)
            }
            break
        }

        if let retired = loadRetiredReviewVault(allowFileBased: values == nil) {
            var merged = values ?? [:]
            var added = false
            for (key, value) in retired.values where merged[key] == nil && !value.isEmpty {
                merged[key] = value
                added = true
            }
            var adopted = values != nil && !added
            if values == nil || added {
                adopted = saveVault(merged)
                values = merged
            }
            // A retired vault in the file-based keychain is the remaining source
            // of the system password dialog, and unlike the ForeverLM-named item
            // above nothing retired it — so every launch asked again. Record the
            // adoption instead of deleting the item: the Dev and Release profiles
            // keep separate vaults and adopt independently, and on someone else's
            // Mac that item may still be the only copy of credentials this
            // profile has already taken but the other one has not.
            if adopted, retired.wasFileBased {
                settleRetiredFileVault()
            }
        }

        return values.map(VaultRead.found) ?? .absent
    }

    /// The product rename changed the Keychain service and vault account. Read
    /// the retired FeynmanLM vault once and copy missing keys into the ForeverLM
    /// vault; do not keep reading both names afterward.
    private static func loadRetiredReviewVault(allowFileBased: Bool) -> RetiredVault? {
        for query in retiredProductVaultLookupQueries(allowFileBased: allowFileBased) {
            // Only the file-based item carries a code-signing ACL, so only it can
            // put a dialog on screen. Bound that one; leave the data-protection
            // queries direct, since they cannot prompt and a thread hop would
            // cost every launch that has a vault to read.
            guard query[kSecUseDataProtectionKeychain as String] == nil else {
                if let values = decodeVault(matching: query) {
                    return RetiredVault(values: values, wasFileBased: false)
                }
                continue
            }

            switch readPromptableVault(matching: query) {
            case .decoded(let values):
                return RetiredVault(values: values, wasFileBased: true)
            case .missing(let status):
                // A person who dismissed the dialog has answered the question.
                // Take that as the answer rather than asking again on the next
                // launch: the credentials are still in the old item if they are
                // ever wanted, and nothing here is worth a password prompt every
                // time the app opens.
                if status == errSecUserCanceled || status == errSecAuthFailed {
                    settleRetiredFileVault()
                    return nil
                }
            case .unanswered:
                // Nobody said no — nobody said anything. Leave the question open
                // for a later launch and report an ordinary empty result, which
                // is all this adoption was ever allowed to be: older-install data whose
                // absence costs a re-entered credential, never a working app.
                return nil
            }
        }
        return nil
    }

    private struct RetiredVault {
        let values: [String: String]
        /// True only when the vault was found in the old file-based keychain, whose
        /// items are the ones guarded by a code-signing ACL.
        let wasFileBased: Bool
    }

    /// Set once the file-based FeynmanLM vault has been dealt with — adopted, or
    /// refused by the person the dialog interrupted. Either way it is settled and
    /// the login keychain is never asked for it again. Bundle IDs differ per
    /// profile, so `UserDefaults.standard` already scopes this to Dev or Release,
    /// and each adopts independently.
    /// Held under `vaultLock`. `retiredFileVaultSettledThisLaunch` answers the lookup at once; the defaults write waits
    /// for `withVaultLock` to release the lock.
    private static var vaultLockDepth = 0
    private static var retiredFileVaultSettledThisLaunch = false
    private static var retiredFileVaultSettlePending = false

    private static func settleRetiredFileVault() {
        retiredFileVaultSettledThisLaunch = true
        retiredFileVaultSettlePending = true
    }

    private static func retiredProductVaultLookupQueries(allowFileBased: Bool) -> [[String: Any]] {
        // The retired vault was written into the retired sharing group, so ask
        // for that group first. `sharedAccessGroup` is the ForeverLM group and
        // is kept only as a fallback for a build that wrote the old service
        // name into the new group. Omitting the group searches every group the
        // entitlement grants, which now includes the retired one.
        var queries = [
            vaultQuery(service: retiredService, account: retiredVaultAccount, accessGroup: retiredSharedAccessGroup, dataProtection: true),
            vaultQuery(service: retiredService, account: retiredVaultAccount, accessGroup: sharedAccessGroup, dataProtection: true),
            vaultQuery(service: retiredService, account: retiredVaultAccount, accessGroup: nil, dataProtection: true),
        ]
        // The file-based item is the one guarded by a code-signing ACL, so it is
        // the one that can cost a keychain password dialog. Three things have to
        // hold before it is worth asking for:
        //
        //   - This profile has no vault yet. A profile that already has one has
        //     nothing to gain: the retired vault can only fill in keys that are
        //     missing, and an established install is not missing them. Only a
        //     fresh install inheriting a pre-rename FeynmanLM keychain is.
        //   - The build is properly signed. Same rule as `load(_:)` and the
        //     ForeverLM-named vault: an ad-hoc build is authorized by
        //     CDHash, so the grant never survives the next rebuild and the read
        //     becomes a password prompt on every single launch.
        //   - The question has not already been settled, by an adoption or by
        //     someone dismissing the dialog.
        if allowFileBased,
           sharedAccessGroup != nil,
           !retiredFileVaultSettledThisLaunch,
           Preferences.value(Prefs.Lifecycle.retiredFileVaultAdopted) != true {
            queries.append(vaultQuery(service: retiredService, account: retiredVaultAccount, accessGroup: retiredSharedAccessGroup, dataProtection: false))
            queries.append(vaultQuery(service: retiredService, account: retiredVaultAccount, accessGroup: nil, dataProtection: false))
        }
        return queries.map { query in
            var lookup = query
            lookup[kSecReturnData as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            return lookup
        }
    }

    private static func vaultQuery(
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    /// What a read of an ACL-guarded vault item came back with.
    private enum PromptableVaultRead {
        case decoded([String: String])
        /// No such item, or the read failed for a reason the caller can inspect —
        /// including the person answering the dialog with "Deny".
        case missing(OSStatus)
        /// The read is still sitting behind an authorization dialog nobody has
        /// answered. Not the same as a refusal: the question stays open.
        case unanswered
    }

    /// How long an ACL-guarded Keychain read is given before it is abandoned.
    /// Generous next to a real read, which is a local lookup and returns in
    /// microseconds; the only thing this waits out is a dialog.
    private static let promptableVaultReadTimeout: DispatchTimeInterval = .milliseconds(1_500)

    private static let promptableVaultReadLock = AppLock()
    /// Set once a read has been abandoned to an unanswered dialog. That dialog is
    /// still on screen and the thread that asked for it is still parked behind
    /// it, so a second read would only park another thread and wait out another
    /// timeout. Report `unanswered` straight away instead.
    private static var promptableVaultReadAbandoned = false

    /// Reads an item whose ACL can raise a system authorization dialog, and gives
    /// up on it after `promptableVaultReadTimeout`.
    ///
    /// `SecItemCopyMatching` on such an item does not return until the dialog is
    /// answered, and none of the callers here are worth waiting on: everything
    /// they can recover is older-install data that a later launch can pick up just as
    /// well. Waiting instead cost the app its launch — a signed build sat with no
    /// window at all until the dialog was answered, and an app-hosted test run,
    /// which has no way to answer one, timed out before the runner connected.
    ///
    /// The read runs on its own thread so the timeout can be a real deadline
    /// rather than a hope. Whatever the abandoned thread eventually reads is
    /// dropped: a timeout is not an answer, so callers must treat it as an
    /// ordinary empty result and must NOT record the question as settled.
    private static func readPromptableVault(matching query: [String: Any]) -> PromptableVaultRead {
        promptableVaultReadLock.lock()
        let alreadyAbandoned = promptableVaultReadAbandoned
        promptableVaultReadLock.unlock()
        if alreadyAbandoned {
            return .unanswered
        }

        final class Outcome {
            let lock = AppLock()
            var result: (values: [String: String]?, status: OSStatus)?
        }
        let outcome = Outcome()
        let finished = DispatchSemaphore(value: 0)
        let backend = vaultBackend
        DispatchQueue.global(qos: .userInitiated).async {
            let result = decodeVaultResult(matching: query, backend: backend)
            outcome.lock.lock()
            outcome.result = result
            outcome.lock.unlock()
            finished.signal()
        }

        guard finished.wait(timeout: .now() + promptableVaultReadTimeout) == .success else {
            promptableVaultReadLock.lock()
            promptableVaultReadAbandoned = true
            promptableVaultReadLock.unlock()
            return .unanswered
        }

        outcome.lock.lock()
        let result = outcome.result
        outcome.lock.unlock()
        guard let result else { return .unanswered }
        if let values = result.values {
            return .decoded(values)
        }
        return .missing(result.status)
    }

    private static func decodeVault(matching query: [String: Any]) -> [String: String]? {
        decodeVaultResult(matching: query).values
    }

    /// Reports the status as well, so a caller can tell "no such item" from
    /// "the person said no" — the two answers deserve different treatment.
    private static func decodeVaultResult(
        matching query: [String: Any],
        backend: VaultBackend = vaultBackend
    ) -> (values: [String: String]?, status: OSStatus) {
        var result: CFTypeRef?
        let status = backend.copyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return (nil, status)
        }
        return (decodeVaultPayload(data), status)
    }

    /// The vault this process reads and writes, told apart from its absence.
    private static func readVault(matching query: [String: Any]) -> VaultRead {
        var result: CFTypeRef?
        let status = vaultBackend.copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return .absent
        }
        guard status == errSecSuccess, let data = result as? Data else {
            return .unreadable(status == errSecSuccess ? errSecDecode : status)
        }
        guard let values = decodeVaultPayload(data) else {
            return .unreadable(errSecDecode)
        }
        return .found(values)
    }

    private static func decodeVaultPayload(_ data: Data) -> [String: String]? {
        if let payload = try? JSONDecoder().decode(VaultPayload.self, from: data) {
            return payload.values
        }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    private static func saveVault(_ values: [String: String]) -> Bool {
        let payload = VaultPayload(version: vaultVersion, values: values)
        guard let data = try? JSONEncoder().encode(payload) else {
            return false
        }

        for query in vaultStorageQueries() {
            let update: [String: Any] = [
                kSecValueData as String: data,
            ]
            let backend = vaultBackend
            let updateStatus = backend.update(query as CFDictionary, update as CFDictionary)
            if updateStatus == errSecSuccess {
                return true
            }
            guard updateStatus == errSecItemNotFound else {
                continue
            }

            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = backend.add(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                return true
            }
            if addStatus == errSecDuplicateItem,
               backend.update(query as CFDictionary, update as CFDictionary) == errSecSuccess {
                return true
            }
        }

        return false
    }

    private static func bootstrapVaultFromIndividualItems() -> [String: String] {
        var values: [String: String] = [:]
        mergeIndividualItems(from: currentServiceQuery(), into: &values)
        mergeIndividualItems(from: ungroupedDataProtectionServiceQuery(), into: &values)
        mergeIndividualItems(from: retiredProductServiceQuery(), into: &values)
        mergeIndividualItems(from: retiredProductUngroupedServiceQuery(), into: &values)

        // Do not enumerate every item in the file-based login keychain here.
        // Each old item can carry a separate ACL, so one bulk query can produce
        // a wall of password dialogs. `loadIndividual` migrates those items one
        // at a time if and when the app actually needs them.

        if !values.isEmpty {
            _ = saveVault(values)
        }
        return values
    }

    private static func mergeIndividualItems(from query: [String: Any], into values: inout [String: String]) {
        var result: CFTypeRef?
        let status = vaultBackend.copyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            return
        }

        let items: [[String: Any]]
        if let array = result as? [[String: Any]] {
            items = array
        } else if let item = result as? [String: Any] {
            items = [item]
        } else {
            return
        }

        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account != vaultAccount,
                  Key(rawValue: account) != nil,
                  values[account] == nil,
                  let data = item[kSecValueData as String] as? Data,
                  let value = String(data: data, encoding: .utf8),
                  !value.isEmpty else {
                continue
            }
            values[account] = value
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

    /// The vault is deliberately device-local (never `kSecAttrSynchronizable`).
    /// It holds credentials that must NOT ride iCloud Keychain — notably the X
    /// OAuth tokens, whose refresh token is single-use and rotates on every
    /// refresh: two Macs sharing one via keychain sync burn each other's token
    /// and X invalidates the grant. Keys that should carry between Macs are
    /// stored as individual synchronizable items instead (see `syncedKeys`).
    private static func vaultStorageQueries() -> [[String: Any]] {
        if sharedAccessGroup == nil {
            return [ungroupedDataProtectionVaultBaseQuery()]
        }
        return [vaultBaseQuery(), ungroupedDataProtectionVaultBaseQuery()]
    }

    private static func vaultBaseQuery() -> [String: Any] {
        var query = baseQuery(forAccount: vaultAccount)
        query[kSecUseDataProtectionKeychain as String] = true
        return query
    }

    private static func ungroupedDataProtectionVaultBaseQuery() -> [String: Any] {
        ungroupedDataProtectionBaseQuery(forAccount: vaultAccount)
    }

    private static func currentServiceQuery() -> [String: Any] {
        var query = serviceQuery(service)
        if let sharedAccessGroup {
            query[kSecAttrAccessGroup as String] = sharedAccessGroup
        }
        query[kSecUseDataProtectionKeychain as String] = true
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        return query
    }

    private static func ungroupedDataProtectionServiceQuery() -> [String: Any] {
        var query = serviceQuery(service)
        query[kSecUseDataProtectionKeychain as String] = true
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        return query
    }

    private static func retiredProductServiceQuery() -> [String: Any] {
        var query = serviceQuery(retiredService)
        if let sharedAccessGroup {
            query[kSecAttrAccessGroup as String] = sharedAccessGroup
        }
        query[kSecUseDataProtectionKeychain as String] = true
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        return query
    }

    private static func retiredProductUngroupedServiceQuery() -> [String: Any] {
        var query = serviceQuery(retiredService)
        query[kSecUseDataProtectionKeychain as String] = true
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        return query
    }

    private static func serviceQuery(_ service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
    }
    #endif

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

        if status == errSecSuccess, let data = result as? Data,
           let value = String(data: data, encoding: .utf8), !value.isEmpty {
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

    #if os(macOS)
    private static func loadUngroupedDataProtection(_ key: Key) -> String? {
        var query = ungroupedDataProtectionBaseQuery(for: key)
        query.merge([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let data = result as? Data,
           let value = String(data: data, encoding: .utf8), !value.isEmpty {
            return value
        }

        return nil
    }

    private static func deleteUngroupedDataProtection(_ key: Key) {
        var query = ungroupedDataProtectionBaseQuery(for: key)
        if syncsAcrossDevices(key) {
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }
        SecItemDelete(query as CFDictionary)
    }
    #endif

    static func delete(_ key: Key) {
        clearIndividualMiss(key)
        if let slot = preferenceSlot(for: key) {
            // Clear both stores: leaving the pre-migration Keychain copy behind
            // would let `load` promote it again on the next read and resurrect a
            // selection the user just reset.
            slot.write(nil)
        }
        #if os(macOS)
        if case .refused(let status) = deleteVaultValue(for: key) {
            vaultLogger.error("Did not remove \(key.rawValue, privacy: .public) from the Keychain vault: it could not be read (OSStatus \(status)).")
        }
        #endif

        deleteCurrent(key)
        #if os(macOS)
        deleteUngroupedDataProtection(key)
        #endif
    }

    /// Read a boolean stored as "true"/"false". Returns nil when unset so callers
    /// can fall back to their own default.
    static func loadBool(_ key: Key) -> Bool? {
        guard let value = load(key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return (value as NSString).boolValue
    }

    static func saveBool(_ value: Bool, for key: Key) {
        save(value ? "true" : "false", for: key)
    }

}
