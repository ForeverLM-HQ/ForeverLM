import Foundation
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
    private static let zoomRecordingPasscodeAccountPrefix = "zoom_recording_passcode:"
    private static let googleDriveAccountCredentialPrefix = "google_drive_account:"
    private static let googleCalendarAccountCredentialPrefix = "google_calendar_account:"
    #if os(macOS)
    private static let vaultAccount = ForeverLMRuntimeIdentity.keychainVaultAccount
    private static let retiredVaultAccount = "__feynmanlm_keychain_vault_v1"
    private static let vaultVersion = 1
    private static let vaultLock = NSRecursiveLock()
    private static var cachedVault: [String: String]?
    #endif
    /// Non-synced keys known absent from the individual Keychain, so repeated
    /// reads of a missing value (e.g. `managedAISessionToken` while signed out)
    /// don't pay a securityd IPC round-trip each time — reads happen on the
    /// main thread from view code, and a miss is otherwise never memoized the
    /// way a hit is (hits self-heal into the vault). Synced keys stay out:
    /// iCloud Keychain can materialize those behind the process's back.
    private static let missLock = NSLock()
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
        /// A learner's own Ramp Router key, from before Ramp was removed on
        /// 2026-09-23. Kept only so the upgrade purge can delete the iCloud
        /// Keychain item; nothing reads or writes it.
        case retiredOwnRampRouterKey = "own_ramp_router_key"
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
        case serverURL = "server_url"
        case appleUserID = "apple_user_id"
        case appleUserName = "apple_user_name"
        case appleUserEmail = "apple_user_email"
        case stripeAPIKey = "stripe_api_key"
        case stripeMonthlyLink = "stripe_monthly_link"
        case stripeYearlyLink = "stripe_yearly_link"
        case xClientId = "x_client_id"
        case xAccessToken = "x_access_token"
        case xRefreshToken = "x_refresh_token"
        case xUserId = "x_user_id"
        case xUsername = "x_username"
        case xTokenExpiry = "x_token_expiry"
        case xGrantedScopes = "x_granted_scopes"
        case googleDriveClientID = "google_drive_client_id"
        case googleDriveClientSecret = "google_drive_client_secret"
        case googleDriveAccessToken = "google_drive_access_token"
        case googleDriveRefreshToken = "google_drive_refresh_token"
        case googleDriveTokenExpiry = "google_drive_token_expiry"
        /// Space-separated OAuth scopes attached to the stored Drive grant.
        /// Sessions created before folder traversal was fixed have only
        /// `drive.file`; keeping the scope lets UI require a deliberate
        /// reconnect instead of presenting an authorized-but-empty folder.
        case googleDriveGrantedScopes = "google_drive_granted_scopes"
        case googleDriveAccounts = "google_drive_accounts_v2"
        /// Account used by Drive links written before links carried their own
        /// account identity. It is set when the legacy singleton grant is
        /// adopted into the account-indexed store.
        case googleDriveLegacyAccountID = "google_drive_legacy_account_id_v2"
        /// Account used for account-agnostic Drive actions such as creating a
        /// Google Doc. Folder and recording reads always use their tagged owner.
        case googleDriveDefaultAccountID = "google_drive_default_account_id_v2"
        case youtubeAccessToken = "youtube_access_token"
        case youtubeRefreshToken = "youtube_refresh_token"
        case youtubeTokenExpiry = "youtube_token_expiry"
        case youtubeAutoImportEnabled = "youtube_auto_import_enabled"
        /// The OAuth client that issued the stored YouTube tokens. Google only
        /// refreshes a token for the client it was issued to, so the plugin
        /// records the client rather than assuming the current default.
        case youtubeClientID = "youtube_client_id"
        case youtubeClientSecret = "youtube_client_secret"
        /// The OAuth client that issued the stored Drive tokens. Drive now signs
        /// in against a ForeverLM-owned client; Google only
        /// refreshes a token for its issuing client, so it is recorded here
        /// rather than assumed to be the current default.
        case driveClientID = "drive_client_id"
        case driveClientSecret = "drive_client_secret"
        /// The retired Google Calendar plugin's grant, its issuing client,
        /// and the calendars the Planner drew from. Kept only so
        /// `purgeRetiredGoogleCalendarGrants` can delete what an older build
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
        /// No longer carries AI traffic — every provider request goes through
        /// the Cloudflare AI Gateway. This is now purely an identity/billing
        /// credential (launch gate, credits, Stripe portal).
        case managedAISessionToken = "managed_ai_session_token"
        case managedAISessionExpiry = "managed_ai_session_expiry"
    }

    private static let defaultAnthropicModel = AIModelDefaults.defaultAnthropic
    /// The persisted Anthropic default before Sonnet 5. Installs from that era have
    /// this stored in the keychain, which would shadow the new default forever.
    private static let retiredAnthropicDefaultModel = "claude-sonnet-4-6"
    /// Set once the user explicitly picks an Anthropic model, so a deliberate
    /// re-pick of the retired default is honored instead of remapped.
    private static let anthropicModelPickedDefaultsKey = "anthropic_model_explicitly_picked"
    private static let defaultOpenAIModel = AIModelDefaults.defaultOpenAI
    /// The persisted OpenAI default before GPT-5.6 — same shadowing problem as
    /// the retired Anthropic default above, and no longer offered in pickers.
    private static let retiredOpenAIDefaultModel = "gpt-5.5"
    private static let openAIModelPickedDefaultsKey = "openai_model_explicitly_picked"
    private static let defaultGroqModel = "openai/gpt-oss-120b"
    private static let defaultCerebrasModel = "gpt-oss-120b"
    private static let defaultXAIModel = "grok-4.3"
    private static let defaultGeminiModel = AIModelDefaults.defaultGemini
    private static let defaultMetaModel = AIModelDefaults.latestMuseSpark
    private static let defaultTogetherModel = AIModelDefaults.defaultTogether
    private static let defaultFireworksModel = AIModelDefaults.defaultFireworks
    private static let defaultNVIDIAModel = AIModelDefaults.defaultNVIDIA
    private static let defaultOpenRouterModel = AIModelDefaults.defaultOpenRouter
    private static let defaultOpenAITranscriptionModel = AIModelDefaults.batchTranscription
    private static let defaultGroqTranscriptionModel = "whisper-large-v3-turbo"
    private static let defaultOpenRouterTranscriptionModel = "nvidia/parakeet-tdt-0.6b-v3"
    /// Batch media defaults to the same model dictation uses, so an existing
    /// install keeps behaving exactly as it did until the learner picks
    /// something else for recordings.
    private static let defaultMediaTranscriptionModel = AIModelDefaults.batchTranscription

    /// Plugin credentials ride iCloud Keychain so the same Google account
    /// and explicitly selected Drive folders remain available on the user's
    /// Macs. The selected meeting groups themselves sync through SQLite and
    /// CloudKit; these tokens only let each Mac refresh their contents.
    private static let syncedKeys: Set<Key> = [
        .openAIAPIKey,
        // The learner's own router key follows them to their other devices, so
        // the iPhone is billed to the same router account the Mac is.
        .ownOpenRouterKey,
        // Synced so the purge's delete reaches the iCloud copy.
        .retiredOwnRampRouterKey,
        // A child's other Macs open the same sealed family key, and know it
        // was the family's key that they hold (docs/family-design.md).
        .familyDeviceKey,
        .familyAppliedKeyStamp,
        .googleDriveClientID,
        .googleDriveClientSecret,
        .googleDriveAccessToken,
        .googleDriveRefreshToken,
        .googleDriveTokenExpiry,
        .googleDriveGrantedScopes,
        .googleDriveAccounts,
        .googleDriveLegacyAccountID,
        .googleDriveDefaultAccountID,
        .youtubeAccessToken,
        .youtubeRefreshToken,
        .youtubeTokenExpiry,
        .youtubeAutoImportEnabled,
        .youtubeClientID,
        .youtubeClientSecret,
        .driveClientID,
        .driveClientSecret,
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
    /// a synced ID next to an unsynced secret (see the `youtubeClientID` note above).
    private static let preferenceBackedKeys: Set<Key> = [
        .aiProvider,
        .anthropicModel, .openAIModel, .groqModel, .cerebrasModel, .xaiModel,
        .geminiModel, .metaModel, .togetherModel, .fireworksModel, .nvidiaModel,
        .openRouterModel,
        .sttProvider, .sttModelMedia,
        .sttModelOpenAI, .sttModelGroq, .sttModelOpenRouter, .sttModelWispr,
        .sttModelWhisperKit, .sttModelAssemblyAI, .sttModelCartesia,
        .sttModelTailscale, .sttLocalServerURL,
        .ttsProvider,
        .ttsModelApple, .ttsModelOpenAI, .ttsModelGroq, .ttsModelElevenLabs,
        .ttsModelTogetherAI, .ttsModelLocalMac, .ttsModelXAI, .ttsModelOpenRouter,
        .ttsModelGemini, .ttsModelCartesia, .ttsModelTailscale, .ttsLocalServerURL,
    ]

    private static func isPreferenceBacked(_ key: Key) -> Bool {
        preferenceBackedKeys.contains(key)
    }

    static func save(_ value: String, for key: Key) {
        clearIndividualMiss(key)
        if isPreferenceBacked(key) {
            // The Keychain copy is deliberately left in place rather than deleted:
            // `load` prefers UserDefaults, so it can never shadow this write, and
            // leaving it keeps a downgrade to a build without this routing working.
            // `delete` clears both so a reset stays a reset.
            //
            // Empty is stored as absent, matching `loadVaultValue`'s `!value.isEmpty`
            // guard. Callers rely on it: `load(.ttsModelOpenRouter) ?? defaultModel`
            // must yield the default for a cleared field, not "".
            if value.isEmpty {
                PreferenceStore.remove(forKey: key.rawValue)
            } else {
                PreferenceStore.set(value, forKey: key.rawValue)
            }
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
        if saveVaultValue(value, for: key) {
            return
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
        // keychain in that case: falling straight through to the legacy
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
        if isPreferenceBacked(key) {
            if let value = UserDefaults.standard.string(forKey: key.rawValue), !value.isEmpty {
                return value
            }
            // Not migrated yet: promote the existing Keychain value on first read,
            // the same shape as the vault promotion below. Lazy by design — CLAUDE.md
            // forbids migrations that run at launch, and this costs one read per key
            // per install rather than a startup pass.
            guard let migrated = loadFromKeychain(key) else { return nil }
            PreferenceStore.set(migrated, forKey: key.rawValue)
            return migrated
        }
        return loadFromKeychain(key)
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
            return loadVaultValue(for: key)
        }

        if let value = loadVaultValue(for: key) {
            return value
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
            promoteLegacyIndividualValueIfNeeded(value, for: key)
            return value
        }

        // Only a properly signed build may pay the one-time migration cost of
        // reading an old file-based item. An ad-hoc build would be authorized by
        // CDHash, which turns this read into a password prompt on every rebuild.
        if sharedAccessGroup != nil, let value = loadStandard(key) {
            promoteLegacyIndividualValueIfNeeded(value, for: key)
            return value
        }
        #endif

        return nil
    }

    #if os(macOS)
    private static func promoteLegacyIndividualValueIfNeeded(_ value: String, for key: Key) {
        guard syncsAcrossDevices(key) else { return }
        _ = saveIndividualToDataProtectionKeychain(Data(value.utf8), for: key)
    }
    #endif

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
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    #if os(macOS)
    private static func ungroupedDataProtectionBaseQuery(for key: Key) -> [String: Any] {
        ungroupedDataProtectionBaseQuery(forAccount: key.rawValue)
    }

    private static func ungroupedDataProtectionBaseQuery(forAccount account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func standardBaseQuery(for key: Key) -> [String: Any] {
        standardBaseQuery(forAccount: key.rawValue)
    }

    private static func standardBaseQuery(forAccount account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
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

    private static func loadVaultValue(for key: Key) -> String? {
        vaultLock.lock()
        defer { vaultLock.unlock() }

        if cachedVault == nil {
            cachedVault = loadVault() ?? bootstrapVaultFromIndividualItems()
        }

        guard let value = cachedVault?[key.rawValue], !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func saveVaultValue(_ value: String, for key: Key) -> Bool {
        vaultLock.lock()
        defer { vaultLock.unlock() }

        if cachedVault == nil {
            cachedVault = loadVault() ?? bootstrapVaultFromIndividualItems()
        }

        var vault = cachedVault ?? [:]
        vault[key.rawValue] = value
        guard saveVault(vault) else {
            return false
        }
        cachedVault = vault
        return true
    }

    private static func deleteVaultValue(for key: Key) -> Bool {
        vaultLock.lock()
        defer { vaultLock.unlock() }

        if cachedVault == nil {
            cachedVault = loadVault() ?? bootstrapVaultFromIndividualItems()
        }

        var vault = cachedVault ?? [:]
        vault.removeValue(forKey: key.rawValue)
        guard saveVault(vault) else {
            return false
        }
        cachedVault = vault
        return true
    }

    private static func loadVault() -> [String: String]? {
        var values: [String: String]?
        for query in vaultLookupQueries() {
            if let decoded = decodeVault(matching: query) {
                values = decoded
                break
            }
        }

        if values == nil {
            // No local vault yet — promote a vault that an older build created as
            // an iCloud-synchronized item. From here on this device reads and
            // writes only its local copy.
            for query in legacySynchronizableVaultLookupQueries() {
                if let decoded = decodeVault(matching: query) {
                    _ = saveVault(decoded)
                    values = decoded
                    break
                }
            }
        }

        // The old file-based login keychain protects items with a code-signing
        // ACL. That is the source of the system password dialog when people
        // alternate between development, App Store, and direct-download
        // builds. Pay that migration cost at most once. After the replacement
        // has been committed to the data-protection keychain, retire the old
        // item so an older or partially migrated launch cannot append another
        // exact build hash to its ACL and recreate the prompt cycle.
        // This item is ACL-guarded too, so the read is bounded: an unanswered
        // dialog leaves the vault empty for this launch rather than freezing it.
        // Nothing is recorded either way — the item is retired only once its
        // contents are safely copied, so a timeout simply asks again next time.
        if values == nil, sharedAccessGroup != nil {
            for query in legacyStandardVaultLookupQueries() {
                guard case .decoded(let decoded) = readPromptableVault(matching: query) else {
                    continue
                }
                if saveVault(decoded) {
                    deleteLegacyStandardVault(matching: query)
                }
                values = decoded
                break
            }
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

        return values
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
                // is all this adoption was ever allowed to be: legacy data whose
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
    private static let retiredFileVaultAdoptedKey = "keychain.retiredProductFileVaultAdopted"

    private static func settleRetiredFileVault() {
        UserDefaults.standard.set(true, forKey: retiredFileVaultAdoptedKey)
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
        //     ForeverLM-named legacy vault: an ad-hoc build is authorized by
        //     CDHash, so the grant never survives the next rebuild and the read
        //     becomes a password prompt on every single launch.
        //   - The question has not already been settled, by an adoption or by
        //     someone dismissing the dialog.
        if allowFileBased,
           sharedAccessGroup != nil,
           !UserDefaults.standard.bool(forKey: retiredFileVaultAdoptedKey) {
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

    private static let promptableVaultReadLock = NSLock()
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
    /// they can recover is legacy data that a later launch can pick up just as
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
            let lock = NSLock()
            var result: (values: [String: String]?, status: OSStatus)?
        }
        let outcome = Outcome()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = decodeVaultResult(matching: query)
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
    private static func decodeVaultResult(matching query: [String: Any]) -> (values: [String: String]?, status: OSStatus) {
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return (nil, status)
        }
        if let payload = try? JSONDecoder().decode(VaultPayload.self, from: data) {
            return (payload.values, status)
        }
        if let values = try? JSONDecoder().decode([String: String].self, from: data) {
            return (values, status)
        }
        return (nil, status)
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
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if updateStatus == errSecSuccess {
                return true
            }
            guard updateStatus == errSecItemNotFound else {
                continue
            }

            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                return true
            }
            if addStatus == errSecDuplicateItem,
               SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess {
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
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
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

    /// Older builds created the vault as an iCloud-synchronized item. These
    /// queries find such a vault so `loadVault` can promote its contents into
    /// the local vault. The synced item is left in place — deleting it would
    /// propagate through iCloud Keychain and strand other Macs still running
    /// an older build — but nothing writes to it anymore, so it goes stale and
    /// stops carrying rotated tokens between devices.
    private static func legacySynchronizableVaultLookupQueries() -> [[String: Any]] {
        vaultStorageQueries().map { query in
            var lookup = query
            lookup[kSecAttrSynchronizable as String] = kCFBooleanTrue
            lookup[kSecReturnData as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            return lookup
        }
    }

    private static func legacyStandardVaultLookupQueries() -> [[String: Any]] {
        var lookup = standardVaultBaseQuery()
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        return [lookup]
    }

    private static func deleteLegacyStandardVault(matching lookupQuery: [String: Any]) {
        var deleteQuery = lookupQuery
        deleteQuery.removeValue(forKey: kSecReturnData as String)
        deleteQuery.removeValue(forKey: kSecMatchLimit as String)
        SecItemDelete(deleteQuery as CFDictionary)
    }

    private static func vaultBaseQuery() -> [String: Any] {
        var query = baseQuery(forAccount: vaultAccount)
        query[kSecUseDataProtectionKeychain as String] = true
        return query
    }

    private static func ungroupedDataProtectionVaultBaseQuery() -> [String: Any] {
        ungroupedDataProtectionBaseQuery(forAccount: vaultAccount)
    }

    private static func standardVaultBaseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultAccount,
        ]
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

    private static func loadStandard(_ key: Key) -> String? {
        var query = standardBaseQuery(for: key)
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
    #endif

    static func delete(_ key: Key) {
        clearIndividualMiss(key)
        if isPreferenceBacked(key) {
            // Clear both stores: leaving the pre-migration Keychain copy behind
            // would let `load` promote it again on the next read and resurrect a
            // selection the user just reset.
            PreferenceStore.remove(forKey: key.rawValue)
        }
        #if os(macOS)
        _ = deleteVaultValue(for: key)
        #endif

        deleteCurrent(key)
        #if os(macOS)
        deleteUngroupedDataProtection(key)
        if sharedAccessGroup != nil {
            var standardQuery = standardBaseQuery(for: key)
            if syncsAcrossDevices(key) {
                standardQuery[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            }
            SecItemDelete(standardQuery as CFDictionary)
        }
        #endif
    }

    /// Read a boolean stored as "true"/"false". Returns nil when unset so callers
    /// can fall back to a legacy default.
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

    // MARK: The retired Google Calendar plugin

    /// The Google Calendar plugin went with the Planner on 2026-09-30: the
    /// day is the Mac's Calendar, which holds a Google account itself through
    /// System Settings › Internet Accounts. Its grants rode iCloud Keychain,
    /// so without this they would sit there for good with no pane left to
    /// disconnect them. Once per Mac, off-main: every account-scoped grant,
    /// the account list, the calendar choice and the plugin's first single
    /// grant go. Deleting a synced item deletes it on the learner's other
    /// Macs too, which is the point.
    static func purgeRetiredGoogleCalendarGrants() {
        let completionKey = "retiredGoogleCalendarGrantsPurged.v1"
        guard !UserDefaults.standard.bool(forKey: completionKey) else { return }
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
        UserDefaults.standard.set(true, forKey: completionKey)
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
    /// ungrouped and legacy-keychain shapes older builds wrote under.
    private static func loadSynchronizedAccountValue(account: String) -> String? {
        if let value = loadSynchronizedValue(matching: baseQuery(forAccount: account)) {
            return value
        }

        #if os(macOS)
        if let value = loadSynchronizedValue(matching: ungroupedDataProtectionBaseQuery(forAccount: account)) {
            return value
        }
        guard sharedAccessGroup != nil else { return nil }
        return loadSynchronizedValue(matching: standardBaseQuery(forAccount: account))
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
        guard sharedAccessGroup != nil else { return nil }
        return loadSynchronizedValue(matching: standardBaseQuery(forAccount: account))
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

        if sharedAccessGroup != nil {
            var standardQuery = standardBaseQuery(forAccount: account)
            standardQuery[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            let standardStatus = SecItemDelete(standardQuery as CFDictionary)
            if standardStatus != errSecSuccess, standardStatus != errSecItemNotFound {
                succeeded = false
            }
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

    /// Whether semantic source search is available. Embeddings run on-device
    /// through Apple's `NLContextualEmbedding`, so this needs no credential at
    /// all — it stays as a named constant rather than being inlined at the call
    /// sites so the concept survives if the embedder ever moves off-device.
    static var hasSourceSemanticSearch: Bool { true }

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
        return data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - X (Twitter) OAuth

    static var xClientId: String? {
        get { load(.xClientId) }
        set {
            if let newValue { save(newValue, for: .xClientId) }
            else { delete(.xClientId) }
        }
    }

    static var xAccessToken: String? {
        get { load(.xAccessToken) }
        set {
            if let newValue { save(newValue, for: .xAccessToken) }
            else { delete(.xAccessToken) }
        }
    }

    static var xRefreshToken: String? {
        get { load(.xRefreshToken) }
        set {
            if let newValue { save(newValue, for: .xRefreshToken) }
            else { delete(.xRefreshToken) }
        }
    }

    static var xUserId: String? {
        get { load(.xUserId) }
        set {
            if let newValue { save(newValue, for: .xUserId) }
            else { delete(.xUserId) }
        }
    }

    /// The @handle of the X account the tokens belong to, read from
    /// `users/me` beside the user id, so the plugins list can say whose
    /// bookmarks it imports without an API call.
    static var xUsername: String? {
        get { load(.xUsername) }
        set {
            if let newValue { save(newValue, for: .xUsername) }
            else { delete(.xUsername) }
        }
    }

    static var xTokenExpiry: String? {
        get { load(.xTokenExpiry) }
        set {
            if let newValue { save(newValue, for: .xTokenExpiry) }
            else { delete(.xTokenExpiry) }
        }
    }

    /// Space-separated OAuth scopes the current X tokens were granted.
    /// Lets the app tell a read-only session (pre-posting sign-in) from one
    /// that can also write posts, without a trial API call.
    static var xGrantedScopes: String? {
        get { load(.xGrantedScopes) }
        set {
            if let newValue { save(newValue, for: .xGrantedScopes) }
            else { delete(.xGrantedScopes) }
        }
    }

    // MARK: - Google Drive OAuth

    static var googleDriveClientID: String? {
        get { load(.googleDriveClientID) }
        set {
            if let newValue { save(newValue, for: .googleDriveClientID) }
            else { delete(.googleDriveClientID) }
        }
    }

    static var googleDriveClientSecret: String? {
        get { load(.googleDriveClientSecret) }
        set {
            if let newValue { save(newValue, for: .googleDriveClientSecret) }
            else { delete(.googleDriveClientSecret) }
        }
    }

    static var googleDriveAccessToken: String? {
        get { load(.googleDriveAccessToken) }
        set {
            if let newValue { save(newValue, for: .googleDriveAccessToken) }
            else { delete(.googleDriveAccessToken) }
        }
    }

    static var googleDriveRefreshToken: String? {
        get { load(.googleDriveRefreshToken) }
        set {
            if let newValue { save(newValue, for: .googleDriveRefreshToken) }
            else { delete(.googleDriveRefreshToken) }
        }
    }

    static var googleDriveTokenExpiry: String? {
        get { load(.googleDriveTokenExpiry) }
        set {
            if let newValue { save(newValue, for: .googleDriveTokenExpiry) }
            else { delete(.googleDriveTokenExpiry) }
        }
    }

    static var googleDriveGrantedScopes: String? {
        get { load(.googleDriveGrantedScopes) }
        set {
            if let newValue { save(newValue, for: .googleDriveGrantedScopes) }
            else { delete(.googleDriveGrantedScopes) }
        }
    }

    static var googleDriveAccounts: String? {
        get { load(.googleDriveAccounts) }
        set {
            if let newValue { save(newValue, for: .googleDriveAccounts) }
            else { delete(.googleDriveAccounts) }
        }
    }

    static var googleDriveLegacyAccountID: String? {
        get { load(.googleDriveLegacyAccountID) }
        set {
            if let newValue { save(newValue, for: .googleDriveLegacyAccountID) }
            else { delete(.googleDriveLegacyAccountID) }
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
    // (Secrets.youtubeOAuthClientID). `youtubeClientID` / `youtubeClientSecret`
    // record whichever client actually issued the stored tokens, so connections
    // made under the older shared-with-Drive client keep refreshing.

    static var youtubeAccessToken: String? {
        get { load(.youtubeAccessToken) }
        set {
            if let newValue { save(newValue, for: .youtubeAccessToken) }
            else { delete(.youtubeAccessToken) }
        }
    }

    static var youtubeRefreshToken: String? {
        get { load(.youtubeRefreshToken) }
        set {
            if let newValue { save(newValue, for: .youtubeRefreshToken) }
            else { delete(.youtubeRefreshToken) }
        }
    }

    static var youtubeTokenExpiry: String? {
        get { load(.youtubeTokenExpiry) }
        set {
            if let newValue { save(newValue, for: .youtubeTokenExpiry) }
            else { delete(.youtubeTokenExpiry) }
        }
    }

    static var youtubeClientID: String? {
        get { load(.youtubeClientID) }
        set {
            if let newValue { save(newValue, for: .youtubeClientID) }
            else { delete(.youtubeClientID) }
        }
    }

    static var youtubeClientSecret: String? {
        get { load(.youtubeClientSecret) }
        set {
            if let newValue { save(newValue, for: .youtubeClientSecret) }
            else { delete(.youtubeClientSecret) }
        }
    }

    static var driveClientID: String? {
        get { load(.driveClientID) }
        set {
            if let newValue { save(newValue, for: .driveClientID) }
            else { delete(.driveClientID) }
        }
    }

    static var driveClientSecret: String? {
        get { load(.driveClientSecret) }
        set {
            if let newValue { save(newValue, for: .driveClientSecret) }
            else { delete(.driveClientSecret) }
        }
    }

    /// Raw stored string to a provider case, before any retirement filtering.
    private static func decodeProvider(_ raw: String) -> AIProvider {
        switch raw {
        case "anthropic": return .anthropic
        case "openai": return .openai
        case "groq": return .groq
        case "cerebras": return .cerebras
        case "xai": return .xai
        case "gemini": return .gemini
        case "meta": return .meta
        case "together": return .together
        case "fireworks": return .fireworks
        case "nvidia": return .nvidia
        case "openrouter": return .openRouter
        default: return .anthropic
        }
    }

    static var aiProvider: AIProvider {
        get {
            if let route = storedRoute(forKey: AIModelPreferenceKey.defaultChatRoute),
               let provider = AIProvider(rawValue: route.provider) {
                return provider
            }
            // This is the Chat (review) default. Unset, legacy "appleIntelligence",
            // and unknown values all map to Anthropic. Without a managed Apple
            // session, resolveConfig returns nil and the review UI asks the user
            // to sign in instead of silently degrading.
            guard let raw = load(.aiProvider) else {
                return .anthropic
            }
            // Keep the stored identity visible. `resolveConfig` rejects retired
            // providers; changing the value here would silently present and run
            // a provider the learner did not select.
            let decoded = decodeProvider(raw)
            return decoded
        }
        set {
            switch newValue {
            case .anthropic: save("anthropic", for: .aiProvider)
            case .openai: save("openai", for: .aiProvider)
            case .groq: save("groq", for: .aiProvider)
            case .cerebras: save("cerebras", for: .aiProvider)
            case .xai: save("xai", for: .aiProvider)
            case .gemini: save("gemini", for: .aiProvider)
            case .meta: save("meta", for: .aiProvider)
            case .together: save("together", for: .aiProvider)
            case .fireworks: save("fireworks", for: .aiProvider)
            case .nvidia: save("nvidia", for: .aiProvider)
            case .openRouter: save("openrouter", for: .aiProvider)
            }
            // Every writer of the global text provider funnels through here, so this is
            // the one place to notify UI (assistant launcher logo, Settings text-model
            // selector) so displays can never drift out of sync with the stored value.
            NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
        }
    }

    static var anthropicModel: String {
        get {
            guard let stored = load(.anthropicModel) else { return defaultAnthropicModel }
            // Same read-time mapping as `aiProvider` uses for legacy values: a stored
            // copy of the retired default follows the current default (Sonnet 5)
            // unless the user explicitly picked it after this build.
            if stored == retiredAnthropicDefaultModel,
               !UserDefaults.standard.bool(forKey: anthropicModelPickedDefaultsKey) {
                return defaultAnthropicModel
            }
            return stored
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.anthropicModel) }
            else {
                save(trimmed, for: .anthropicModel)
                PreferenceStore.set(true, forKey: anthropicModelPickedDefaultsKey)
            }
        }
    }

    static var openAIModel: String {
        get {
            guard let stored = load(.openAIModel) else { return defaultOpenAIModel }
            // Same read-time mapping as `anthropicModel`: a stored copy of the
            // retired default follows the current default (GPT-5.6 Sol) unless
            // the user explicitly picked it after this build.
            if stored == retiredOpenAIDefaultModel,
               !UserDefaults.standard.bool(forKey: openAIModelPickedDefaultsKey) {
                return defaultOpenAIModel
            }
            return stored
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.openAIModel) }
            else {
                save(trimmed, for: .openAIModel)
                PreferenceStore.set(true, forKey: openAIModelPickedDefaultsKey)
            }
        }
    }

    static var groqModel: String {
        get { load(.groqModel) ?? defaultGroqModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.groqModel) }
            else { save(trimmed, for: .groqModel) }
        }
    }

    static var cerebrasModel: String {
        get { load(.cerebrasModel) ?? defaultCerebrasModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.cerebrasModel) }
            else { save(trimmed, for: .cerebrasModel) }
        }
    }

    static var xaiModel: String {
        get { load(.xaiModel) ?? defaultXAIModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.xaiModel) }
            else { save(trimmed, for: .xaiModel) }
        }
    }

    static var metaModel: String {
        get { load(.metaModel) ?? defaultMetaModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.metaModel) }
            else { save(trimmed, for: .metaModel) }
        }
    }

    static var geminiTextModel: String {
        get { load(.geminiModel) ?? defaultGeminiModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.geminiModel) }
            else { save(trimmed, for: .geminiModel) }
        }
    }

    static var togetherModel: String {
        get { load(.togetherModel) ?? defaultTogetherModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.togetherModel) }
            else { save(trimmed, for: .togetherModel) }
        }
    }

    static var fireworksModel: String {
        get { load(.fireworksModel) ?? defaultFireworksModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.fireworksModel) }
            else { save(trimmed, for: .fireworksModel) }
        }
    }

    static var nvidiaModel: String {
        get { load(.nvidiaModel) ?? defaultNVIDIAModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.nvidiaModel) }
            else { save(trimmed, for: .nvidiaModel) }
        }
    }

    static var openRouterModel: String {
        get { load(.openRouterModel) ?? defaultOpenRouterModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.openRouterModel) }
            else { save(trimmed, for: .openRouterModel) }
        }
    }

    static func model(for provider: AIProvider) -> String {
        if let route = storedRoute(forKey: AIModelPreferenceKey.defaultChatRoute),
           route.provider == provider.rawValue {
            return route.model
        }
        switch provider {
        case .anthropic: return anthropicModel
        case .openai: return openAIModel
        case .groq: return groqModel
        case .cerebras: return cerebrasModel
        case .xai: return xaiModel
        case .gemini: return geminiTextModel
        case .meta: return metaModel
        case .together: return togetherModel
        case .fireworks: return fireworksModel
        case .nvidia: return nvidiaModel
        case .openRouter: return openRouterModel
        }
    }

    static func setModel(_ model: String, for provider: AIProvider) {
        switch provider {
        case .anthropic: anthropicModel = model
        case .openai: openAIModel = model
        case .groq: groqModel = model
        case .cerebras: cerebrasModel = model
        case .xai: xaiModel = model
        case .gemini: geminiTextModel = model
        case .meta: metaModel = model
        case .together: togetherModel = model
        case .fireworks: fireworksModel = model
        case .nvidia: nvidiaModel = model
        case .openRouter: openRouterModel = model
        }
    }

    static var openAITranscriptionModel: String {
        get { load(.sttModelOpenAI) ?? defaultOpenAITranscriptionModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.sttModelOpenAI) }
            else { save(trimmed, for: .sttModelOpenAI) }
        }
    }

    /// Model for batch media transcription — meeting recordings and podcast
    /// episodes — kept separate from dictation on purpose. Dictation is a few
    /// seconds of one clear voice and wants the fastest model; a recording is
    /// an hour of several people, crosstalk, and domain vocabulary, and is
    /// worth paying more per minute to get right. One setting could not serve
    /// both without making one of them wrong.
    static var mediaTranscriptionModel: String {
        get { load(.sttModelMedia) ?? defaultMediaTranscriptionModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.sttModelMedia) }
            else { save(trimmed, for: .sttModelMedia) }
        }
    }

    static var groqTranscriptionModel: String {
        get { load(.sttModelGroq) ?? defaultGroqTranscriptionModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.sttModelGroq) }
            else { save(trimmed, for: .sttModelGroq) }
        }
    }

    static var openRouterTranscriptionModel: String {
        get { load(.sttModelOpenRouter) ?? defaultOpenRouterTranscriptionModel }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.sttModelOpenRouter) }
            else { save(trimmed, for: .sttModelOpenRouter) }
        }
    }

    /// The slot batch speech-to-text is stored under (`stt_model_openai`, a
    /// name kept for the stored rows). Whatever it holds is an OpenRouter
    /// model and goes to OpenRouter (`ManagedTranscriptionClient.route`).
    static var speechToTextProvider: SpeechToTextProvider { .openai }

    static func transcriptionModel(for provider: SpeechToTextProvider) -> String {
        switch provider {
        case .groq: return groqTranscriptionModel
        case .openai: return openAITranscriptionModel
        case .openRouter: return openRouterTranscriptionModel
        }
    }

    static func setTranscriptionModel(_ model: String, for provider: SpeechToTextProvider) {
        switch provider {
        case .groq: groqTranscriptionModel = model
        case .openai: openAITranscriptionModel = model
        case .openRouter: openRouterTranscriptionModel = model
        }
    }

    /// True when requests to this provider can succeed through managed AI.
    static func hasUsableTextProviderCredentials(for provider: AIProvider) -> Bool {
        return ManagedAI.isSignedIn && AIProvider.activeChatProviders.contains(provider)
    }

    /// API key for a specific provider.
    static func apiKey(for provider: AIProvider) -> String? {
        return ManagedAI.isSignedIn && AIProvider.activeChatProviders.contains(provider) ? "" : nil
    }

    // MARK: - Text Routing

    /// The transport every ordinary managed text request uses. The server names
    /// it; OpenRouter is the one text router and the shipped default.
    ///
    /// This is deliberately not the user's choice, and not a synced preference:
    /// the proxy refuses a request naming a different transport, so a stale
    /// synced value would only produce 403s. It is server policy because the
    /// reason to change it — a router outage, a de-listed model family — arrives
    /// without warning and must not wait on an App Store release. The setter
    /// still writes the preference so older builds keep a complete
    /// configuration, but nothing here reads it back.
    static var textRoutingMode: AITextRoutingMode {
        get {
            // The learner's own key names its router itself. The account-wide
            // policy exists to keep ForeverLM's spend on one exactly billed
            // rail; a request ForeverLM is not paying for is outside it, and the
            // proxy admits the key's router regardless of the policy.
            if let own = ManagedAI.ownKeyRouter { return own.routingMode }
            return ManagedAI.requiredTextRoutingMode ?? .shippedDefault
        }
        set {
            PreferenceStore.set(newValue.rawValue, forKey: AIModelPreferenceKey.textRoutingMode)
            NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
        }
    }

    /// Applies the account transport policy after a task's canonical
    /// provider/model selection and request options have been validated.
    static func routedTextSelection(
        provider: AIProvider,
        model: String,
        speed: AISpeed? = nil,
        mode: AITextRoutingMode = textRoutingMode
    ) -> (provider: AIProvider, model: String) {
        switch mode {
        case .openRouter:
            return (.openRouter, OpenRouterModelID.slug(provider: provider, model: model))
        }
    }

    /// Re-applies the account-wide transport policy at the moment a request is
    /// dispatched. Background workflows can retain an `AITaskConfig` for many
    /// minutes; resolving only when that workflow starts would let an old
    /// config escape a transport change the server made in between.
    static func routedTextConfig(
        _ config: AITaskConfig,
        mode: AITextRoutingMode = textRoutingMode
    ) -> AITaskConfig {
        let routed = routedTextSelection(
            provider: config.provider,
            model: config.model,
            speed: config.speed,
            mode: mode
        )
        var result = AITaskConfig(
            provider: routed.provider,
            apiKey: apiKey(for: routed.provider) ?? config.apiKey,
            model: routed.model
        )
        result.effort = config.effort
        result.speed = config.speed
        result.taskLabel = config.taskLabel
        result.isBackup = config.isBackup
        return result
    }

    // MARK: - Background Model

    /// Routes used when the learner has never made a Background selection.
    /// Text-only and image-reading work stay separate so a cheap text default
    /// cannot make multimodal preparation fail at runtime.
    static let defaultBackgroundTaskRoute = AITaskModelRoute(
        provider: .openRouter,
        model: AIModelDefaults.defaultOpenRouter
    )
    static let defaultBackgroundMultimodalTaskRoute = AITaskModelRoute(
        provider: .openRouter,
        model: AIModelDefaults.visionOpenRouter
    )

    private static func storedRoute(forKey key: String) -> AIModelRoutePreference? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let route = try? JSONDecoder().decode(AIModelRoutePreference.self, from: data),
              route.isValid,
              let provider = AIProvider(rawValue: route.provider),
              provider.canServeStoredSelection,
              route.effort == nil || route.effort.flatMap(AIEffort.init(rawValue:)) != nil,
              route.speed == nil || route.speed.flatMap(AISpeed.init(rawValue:)) != nil else { return nil }
        return route
    }

    private static func storedRouteIsInvalid(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) != nil && storedRoute(forKey: key) == nil
    }

    private static func modelRouteConfigurationIsInvalid(for task: AITask) -> Bool {
        let effectiveTask = task.followsChatRoute ? AITask.chat : task

        if effectiveTask == .chat {
            let taskKey = AIModelPreferenceKey.taskRoute(.chat)
            if storedRouteIsInvalid(taskKey) { return true }
            if UserDefaults.standard.object(forKey: taskKey) != nil { return false }
            let legacyTaskProvider = UserDefaults.standard.string(forKey: "aiTask.chat.provider")
            let legacyTaskModel = UserDefaults.standard.string(forKey: "aiTask.chat.model")
            if legacyTaskProvider != nil || legacyTaskModel != nil {
                guard let rawProvider = legacyTaskProvider,
                      let model = legacyTaskModel,
                      !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let provider = AIProvider(rawValue: rawProvider),
                      provider.canServeStoredSelection else { return true }
                return false
            }
            if storedRouteIsInvalid(AIModelPreferenceKey.defaultChatRoute) { return true }
            guard UserDefaults.standard.object(forKey: AIModelPreferenceKey.defaultChatRoute) == nil,
                  let raw = load(.aiProvider) else { return false }
            return !["anthropic", "openai", "xai", "gemini", "meta", "openrouter"].contains(raw)
        }

        // A model the learner set for this task that cannot be read fails the
        // task closed rather than quietly running Background's.
        if storedRouteIsInvalid(AIModelPreferenceKey.taskRoute(effectiveTask)) { return true }

        if effectiveTask.usesMultimodalBackgroundModelDefault {
            return storedRouteIsInvalid(AIModelPreferenceKey.backgroundMultimodalRoute)
        }

        if storedRouteIsInvalid(AIModelPreferenceKey.backgroundRoute) { return true }
        guard UserDefaults.standard.object(forKey: AIModelPreferenceKey.backgroundRoute) == nil,
              let raw = UserDefaults.standard.string(forKey: "aiBackground.provider") else { return false }
        guard let provider = AIProvider(rawValue: raw) else { return true }
        return !provider.canServeStoredSelection
    }

    private static func saveRoute(_ route: AIModelRoutePreference, forKey key: String) {
        guard route.isValid, let data = try? JSONEncoder().encode(route) else { return }
        PreferenceStore.set(data, forKey: key)
        NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
    }

    static func setDefaultChatRoute(provider: AIProvider, model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saveRoute(
            AIModelRoutePreference(provider: provider.rawValue, model: trimmed),
            forKey: AIModelPreferenceKey.defaultChatRoute
        )
        // Keep the legacy keys current for older builds during rollout. The
        // atomic route above is authoritative for current builds.
        setModel(trimmed, for: provider)
        aiProvider = provider
    }

    static func setBackgroundTaskRoute(provider: AIProvider, model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saveRoute(
            AIModelRoutePreference(provider: provider.rawValue, model: trimmed),
            forKey: AIModelPreferenceKey.backgroundRoute
        )
        PreferenceStore.set(provider.rawValue, forKey: "aiBackground.provider")
        PreferenceStore.set(trimmed, forKey: backgroundTaskModelKey(for: provider))
        PreferenceStore.remove(forKey: "aiBackground.model")
    }

    static func setBackgroundMultimodalTaskRoute(provider: AIProvider, model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saveRoute(
            AIModelRoutePreference(provider: provider.rawValue, model: trimmed),
            forKey: AIModelPreferenceKey.backgroundMultimodalRoute
        )
    }

    // MARK: - A Background task's own model

    /// Whether `task` can be given a model of its own: it runs on a Background
    /// model today and is one of the tasks Settings › Background lists.
    static func canHaveOwnRoute(_ task: AITask) -> Bool {
        task.usesBackgroundModelDefault && AITask.advancedTasks.contains(task)
    }

    /// The model the learner set for `task` itself, which wins over Background's
    /// (product owner, 2026-10-07: "people should be allowed to set it for each task
    /// still somehow"). Synced as `aiRoute.task.<task>`. Nil while the task
    /// follows Background, and while the pick is a free model that OpenRouter
    /// now charges for.
    static func ownRoute(for task: AITask) -> AITaskModelRoute? {
        guard canHaveOwnRoute(task),
              let stored = storedRoute(forKey: AIModelPreferenceKey.taskRoute(task)),
              let provider = AIProvider(rawValue: stored.provider) else { return nil }
        let route = AITaskModelRoute(provider: provider, model: stored.model)
        if AIFreeModels.isFreeModelID(stored.model), AIFreeModelPrices.isListedAsPaid(stored.model) { return nil }
        return route
    }

    /// Gives `task` a model of its own, or with nil sends it back to
    /// Background's.
    static func setOwnRoute(_ route: AITaskModelRoute?, for task: AITask) {
        guard canHaveOwnRoute(task) else { return }
        guard let route else {
            PreferenceStore.remove(forKey: AIModelPreferenceKey.taskRoute(task))
            NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
            return
        }
        let trimmed = route.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saveRoute(
            AIModelRoutePreference(provider: route.provider.rawValue, model: trimmed),
            forKey: AIModelPreferenceKey.taskRoute(task)
        )
    }

    /// The synced mark that Canvas Voice was given its starting model, so a
    /// learner who sends it back to Background is not given it again, here
    /// or on another Mac (`aiSeeded.task.<task>`).
    static let canvasVoiceSeededKey = "aiSeeded.task." + AITask.canvasVoice.rawValue

    /// Gives Canvas Voice its starting model (`AIModelDefaults.canvasVoice`)
    /// as a model of its own, once for the account, when it has none: speaking
    /// to the canvas is waited on, and Background's model is chosen for work
    /// nobody waits on. Run when the learner first speaks to a canvas rather
    /// than at launch, so a new Mac has read the account's settings first.
    /// It then shows, and is changed, in Settings › Background › Tasks like
    /// any model the learner set.
    static func seedCanvasVoiceRoute() {
        guard canHaveOwnRoute(.canvasVoice),
              !UserDefaults.standard.bool(forKey: canvasVoiceSeededKey),
              storedRoute(forKey: AIModelPreferenceKey.taskRoute(.canvasVoice)) == nil else { return }
        PreferenceStore.set(true, forKey: canvasVoiceSeededKey)
        setOwnRoute(AITaskModelRoute(provider: .openRouter, model: AIModelDefaults.canvasVoice), for: .canvasVoice)
    }

    // MARK: - Docs Model

    /// The model a Doc's Edit with AI runs on, when the learner gave Docs one
    /// of their own; nil while Docs follow the Default Model (product owner,
    /// 2026-09-29: "for rewrites; let me choose a model"). Synced like the
    /// Default Model. Never the chat on screen's own pick: a model tried in
    /// one chat is not a choice about docs.
    static var docsRoute: AITaskModelRoute? {
        guard let route = storedRoute(forKey: AIModelPreferenceKey.docsRoute),
              let provider = AIProvider(rawValue: route.provider) else { return nil }
        return AITaskModelRoute(provider: provider, model: route.model)
    }

    /// What a Doc's Edit with AI runs on: Docs' own model, else the Default Model.
    static var displayedDocsRoute: AITaskModelRoute {
        if let docsRoute { return docsRoute }
        let provider = aiProvider
        return AITaskModelRoute(provider: provider, model: model(for: provider))
    }

    /// Gives Docs a model of their own, or with nil sends them back to the
    /// Default Model.
    static func setDocsRoute(_ route: AITaskModelRoute?) {
        guard let route else {
            PreferenceStore.remove(forKey: AIModelPreferenceKey.docsRoute)
            NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
            return
        }
        let trimmed = route.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saveRoute(
            AIModelRoutePreference(provider: route.provider.rawValue, model: trimmed),
            forKey: AIModelPreferenceKey.docsRoute
        )
    }

    /// The config for a Doc's Edit with AI, through the same checks as
    /// `resolveConfig(for: .chat)`, on `displayedDocsRoute`. The effort is the
    /// one last chosen in a chat when the model offers it, as a new chat
    /// starts on; Docs have no speed of their own. A stored Docs model that
    /// cannot be read fails closed instead of quietly running the Default Model.
    static func resolveDocsConfig() -> AITaskConfig? {
        guard ManagedAI.isSignedIn else { return nil }
        guard !storedRouteIsInvalid(AIModelPreferenceKey.docsRoute) else { return nil }
        if docsRoute == nil, modelRouteConfigurationIsInvalid(for: .chat) { return nil }
        guard !AICreditEntitlement.isOutOfCredits else { return nil }
        let route = displayedDocsRoute
        let effort = chosenChatEffort.flatMap { chosen in
            AIRequestOptionSupport.supportedEfforts(provider: route.provider, model: route.model)
                .contains(chosen) ? chosen : nil
        }
        return textConfig(
            provider: route.provider,
            model: route.model,
            requiresVision: false,
            effort: effort,
            requestedSpeed: nil,
            taskLabel: "doc_edit"
        )
    }

    /// The model of the chat on screen, held in memory for that chat only.
    /// Nothing else takes a model of its own: every background task runs on
    /// Background's Text-only or Multimodal model (`backgroundRoute(for:)`).
    static func setTaskRoute(
        provider: AIProvider,
        model: String,
        effort: AIEffort? = nil,
        speed: AISpeed? = nil,
        for task: AITask
    ) {
        guard isChat(task) else { return }
        chatModelLock.lock()
        chatSessionProvider = provider
        chatSessionModel = model
        chatSessionEffort = effort
        chatSessionSpeed = speed
        chatModelLock.unlock()
        NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
    }

    /// Provider used by background tasks (everything except Chat). Nil means
    /// `defaultBackgroundTaskRoute`.
    static var backgroundTaskProvider: AIProvider? {
        get {
            if let route = storedRoute(forKey: AIModelPreferenceKey.backgroundRoute) {
                return AIProvider(rawValue: route.provider)
            }
            guard let raw = UserDefaults.standard.string(forKey: "aiBackground.provider") else { return nil }
            return AIProvider.allCases.first { $0.rawValue == raw }
        }
        set {
            if let newValue { PreferenceStore.set(newValue.rawValue, forKey: "aiBackground.provider") }
            else { PreferenceStore.remove(forKey: "aiBackground.provider") }
            NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
        }
    }

    /// Model used by background tasks on the currently selected background provider,
    /// or nil to use that provider's default model.
    static var backgroundTaskModel: String? {
        get { backgroundTaskModel(for: backgroundTaskProvider ?? defaultBackgroundTaskRoute.provider) }
        set { setBackgroundTaskModel(newValue, for: backgroundTaskProvider ?? defaultBackgroundTaskRoute.provider) }
    }

    /// Background › Text: the persisted selection or the explicit shipped
    /// default.
    static var displayedBackgroundTaskRoute: AITaskModelRoute {
        guard let provider = backgroundTaskProvider else {
            return defaultBackgroundTaskRoute
        }
        return AITaskModelRoute(
            provider: provider,
            model: backgroundTaskModel(for: provider) ?? model(for: provider)
        )
    }

    /// Background › Multimodal: the persisted vision route or the explicit
    /// shipped default.
    static var displayedBackgroundMultimodalTaskRoute: AITaskModelRoute {
        guard let route = storedRoute(forKey: AIModelPreferenceKey.backgroundMultimodalRoute),
              let provider = AIProvider(rawValue: route.provider) else {
            return defaultBackgroundMultimodalTaskRoute
        }
        return AITaskModelRoute(provider: provider, model: route.model)
    }

    static func displayedBackgroundTaskRoute(for task: AITask) -> AITaskModelRoute {
        task.usesMultimodalBackgroundModelDefault
            ? displayedBackgroundMultimodalTaskRoute
            : displayedBackgroundTaskRoute
    }

    /// The model a background task runs on: its own (`ownRoute(for:)`), else
    /// Background's Text-only or Multimodal model, except that a meeting task
    /// does not follow that onto a free one (`MeetingModels`). A meeting task
    /// with nowhere paid to go shows Background's here, but
    /// `isWaitingForPaidModel` is true and no request is built for it.
    static func backgroundRoute(for task: AITask) -> AITaskModelRoute {
        if let own = ownRoute(for: task) { return own }
        let background = displayedBackgroundTaskRoute(for: task)
        return meetingRoute(for: task, background: background) ?? background
    }

    /// A meeting task that stays off free models, whose Background model is
    /// free and which has no paid backup to run on: it waits for the learner
    /// to choose a paid model, here or in Setup.
    static func isWaitingForPaidModel(_ task: AITask) -> Bool {
        guard ownRoute(for: task) == nil else { return false }
        return meetingRoute(for: task, background: displayedBackgroundTaskRoute(for: task)) == nil
    }

    private static func meetingRoute(for task: AITask, background: AITaskModelRoute) -> AITaskModelRoute? {
        MeetingModels.route(
            for: task,
            background: background,
            staysOffFree: MeetingModels.staysOffFree(task),
            paid: { MeetingModels.paidRoute(multimodal: task.usesMultimodalBackgroundModelDefault) }
        )
    }

    // The pick is stored per provider. A single shared slot meant switching
    // providers had to clear it, so leaving a provider and coming back read as
    // "never picked" and silently reverted to that provider's chat default.
    private static func backgroundTaskModelKey(for provider: AIProvider) -> String {
        "aiBackground.model.\(provider.rawValue)"
    }

    /// The background-task model picked for a specific provider, or nil when that
    /// provider has never been given one.
    static func backgroundTaskModel(for provider: AIProvider) -> String? {
        if let route = storedRoute(forKey: AIModelPreferenceKey.backgroundRoute),
           route.provider == provider.rawValue {
            return route.model
        }
        if let model = UserDefaults.standard.string(forKey: backgroundTaskModelKey(for: provider)) {
            return model
        }
        // Builds before the per-provider split kept one shared value, which
        // belonged to whichever provider was selected when it was written.
        // Read it through rather than dropping the user's existing pick; the
        // first explicit pick retires the old key.
        // An absent provider meant Anthropic in those builds. Do not reinterpret
        // a legacy Claude model as an OpenRouter slug now that the new-install
        // default is OpenRouter.
        if provider == (backgroundTaskProvider ?? .anthropic) {
            return UserDefaults.standard.string(forKey: "aiBackground.model")
        }
        return nil
    }

    static func setBackgroundTaskModel(_ model: String?, for provider: AIProvider) {
        let key = backgroundTaskModelKey(for: provider)
        if let model, !model.isEmpty { PreferenceStore.set(model, forKey: key) }
        else { PreferenceStore.remove(forKey: key) }
        PreferenceStore.remove(forKey: "aiBackground.model")
        NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
    }

    /// The provider a task runs on when the chat has no model of its own.
    /// Chat, text-only background work, and multimodal background work each
    /// follow their corresponding Settings selection.
    static func fallbackProvider(for task: AITask) -> AIProvider {
        guard task.usesBackgroundModelDefault else { return aiProvider }
        return backgroundRoute(for: task).provider
    }

    /// The provider a task will actually use: the chat's own pick, then the task's fallback.
    static func resolvedProvider(for task: AITask) -> AIProvider {
        taskProvider(task) ?? fallbackProvider(for: task)
    }

    // MARK: - Per-Task Model Configuration

    // The Chat model pick (`.chat`) is held in memory only, never persisted:
    // a model chosen from the chat bar belongs to the current chat, and every new
    // chat starts back on the Default Model from Settings. Persisting it created a
    // hidden override that contradicted the Settings pane with no way to see why.
    private static let chatModelLock = NSLock()
    private static var chatSessionProvider: AIProvider?
    private static var chatSessionModel: String?
    private static var chatSessionEffort: AIEffort?
    private static var chatSessionSpeed: AISpeed?

    /// The in-memory override only exists when the complete route is still
    /// enabled. A saved chat can restore a historical model identity for
    /// display, but disabling or removing that model makes the current chat
    /// follow the Settings default immediately.
    private static func enabledChatSessionRoute() -> (
        provider: AIProvider,
        model: String,
        effort: AIEffort?,
        speed: AISpeed?
    )? {
        chatModelLock.lock()
        let route = (
            provider: chatSessionProvider,
            model: chatSessionModel,
            effort: chatSessionEffort,
            speed: chatSessionSpeed
        )
        chatModelLock.unlock()
        guard let provider = route.provider,
              let model = route.model,
              AIProvider.activeChatProviders.contains(provider),
              AIModelCatalog.isEnabledChatSelection(provider: provider, modelID: model) else {
            return nil
        }
        return (provider, model, route.effort, route.speed)
    }

    /// Return Chat to the Settings default without touching persisted
    /// preferences. Used whenever the UI leaves one chat for a fresh one.
    static func resetChatSessionSelection() {
        chatModelLock.lock()
        chatSessionProvider = nil
        chatSessionModel = nil
        chatSessionEffort = nil
        chatSessionSpeed = nil
        chatModelLock.unlock()
        NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
    }

    static func resetChatSessionSelectionIfMatching(provider: AIProvider, model: String) {
        chatModelLock.lock()
        let matches = chatSessionProvider == provider && chatSessionModel == model
        if matches {
            chatSessionProvider = nil
            chatSessionModel = nil
            chatSessionEffort = nil
            chatSessionSpeed = nil
        }
        chatModelLock.unlock()
        if matches {
            NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
        }
    }

    // The four parts of the chat's own pick. Only the chat has one: the
    // tasks that follow the chat's route read it, and every other task runs
    // on Background's model (product owner, 2026-09-28: "I don't think anybody will
    // actually want to set the model for all these specific tasks"), so for
    // them each read is nil and each write is refused.

    /// The chat's own provider, or nil to use the Default Model.
    static func taskProvider(_ task: AITask) -> AIProvider? {
        if task.followsChatRoute { return taskProvider(.chat) }
        guard task == .chat else { return nil }
        return enabledChatSessionRoute()?.provider
    }

    /// Set or clear the chat's own provider.
    static func setTaskProvider(_ provider: AIProvider?, for task: AITask) {
        guard isChat(task) else { return }
        chatModelLock.lock()
        chatSessionProvider = provider
        chatModelLock.unlock()
        // Drop any override persisted before chat picks became session-scoped.
        PreferenceStore.remove(forKey: "aiTask.chat.provider")
        NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
    }

    /// The chat's own model, or nil to use the Default Model.
    static func taskModel(_ task: AITask) -> String? {
        if task.followsChatRoute { return taskModel(.chat) }
        guard task == .chat else { return nil }
        return enabledChatSessionRoute()?.model
    }

    /// Set or clear the chat's own model.
    static func setTaskModel(_ model: String?, for task: AITask) {
        guard isChat(task) else { return }
        chatModelLock.lock()
        chatSessionModel = (model?.isEmpty == false) ? model : nil
        chatModelLock.unlock()
        // Drop any override persisted before chat picks became session-scoped.
        PreferenceStore.remove(forKey: "aiTask.chat.model")
        NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
    }

    /// The chat's own effort, else the effort last chosen from the chat bar
    /// when the chat's model offers it, else nil for the model's default.
    ///
    /// Unlike its model, a chat's effort does not reset with each new chat.
    /// Every new chat used to start on the model's default effort, and the product owner
    /// set Low again in each one: "whenever I set the level of reasoning, I
    /// want that to persist" (2026-09-28). A chat whose model does not offer
    /// the chosen effort runs on that model's default; the choice itself is
    /// kept for the next model that does.
    static func taskEffort(_ task: AITask) -> AIEffort? {
        if task.followsChatRoute { return taskEffort(.chat) }
        guard task == .chat else { return nil }
        if let own = enabledChatSessionRoute()?.effort { return own }
        guard let chosen = chosenChatEffort else { return nil }
        let selection = resolvedSelection(for: .chat)
        let offered = AIRequestOptionSupport.supportedEfforts(provider: selection.provider, model: selection.model)
        return offered.contains(chosen) ? chosen : nil
    }

    /// The effort last picked from a chat's effort control. It follows the
    /// account like the Default Model it sits beside. Only a learner's pick
    /// writes it — never a restored chat's effort, nor one dropped because a
    /// new model does not offer it.
    static var chosenChatEffort: AIEffort? {
        get {
            UserDefaults.standard.string(forKey: AIModelPreferenceKey.defaultChatEffort)
                .flatMap(AIEffort.init(rawValue:))
        }
        set {
            PreferenceStore.set(newValue?.rawValue, forKey: AIModelPreferenceKey.defaultChatEffort)
        }
    }

    /// Chat effort and speed ride on the in-memory session route, and that
    /// route only counts once it names a provider *and* a model — which, until
    /// this ran, happened only when a model had been picked from the chat bar.
    /// Tuning a chat still following the Settings default therefore had nowhere
    /// to live: `enabledChatSessionRoute()` stayed nil, the read came back
    /// empty, and the composer's effort chip snapped back to Medium the moment
    /// its storage sync ran (2026-09-04). Pinning the resolved default model
    /// makes the pick the same session-scoped route a model pick makes, so a
    /// new chat still returns to the Settings default with it.
    private static func pinChatSessionRouteToResolvedModelIfMissing() {
        // Resolve before taking the lock: `resolvedSelection` reads the session
        // route itself, and the lock is not reentrant.
        let resolved = resolvedSelection(for: .chat)
        chatModelLock.lock()
        defer { chatModelLock.unlock() }
        guard chatSessionProvider == nil || chatSessionModel == nil else { return }
        chatSessionProvider = resolved.provider
        chatSessionModel = resolved.model
    }

    /// Set or clear the chat's own effort, session-scoped like its model.
    static func setTaskEffort(_ effort: AIEffort?, for task: AITask) {
        guard isChat(task) else { return }
        if effort != nil {
            pinChatSessionRouteToResolvedModelIfMissing()
        }
        chatModelLock.lock()
        chatSessionEffort = effort
        chatModelLock.unlock()
        PreferenceStore.remove(forKey: "aiTask.chat.effort")
        NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
    }

    /// The chat's own speed, or nil for standard speed.
    static func taskSpeed(_ task: AITask) -> AISpeed? {
        if task.followsChatRoute { return taskSpeed(.chat) }
        guard task == .chat else { return nil }
        return enabledChatSessionRoute()?.speed
    }

    /// Set or clear the chat's own speed, session-scoped like its model.
    static func setTaskSpeed(_ speed: AISpeed?, for task: AITask) {
        guard isChat(task) else { return }
        if let speed, speed != .standard {
            pinChatSessionRouteToResolvedModelIfMissing()
        }
        chatModelLock.lock()
        chatSessionSpeed = speed
        chatModelLock.unlock()
        PreferenceStore.remove(forKey: "aiTask.chat.speed")
        NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
    }

    private static func isChat(_ task: AITask) -> Bool {
        guard task == .chat else {
            assertionFailure("\(task.rawValue) has no model of its own; it runs on Background's")
            return false
        }
        return true
    }

    /// Explicit permission for automatic LLM work to consume the learner's AI
    /// credits. This syncs with the account through the `aiBackground.` prefix.
    static var hasConsentedToBackgroundAIUsage: Bool {
        get { UserDefaults.standard.bool(forKey: backgroundAIUsageConsentKey) }
        set { PreferenceStore.set(newValue, forKey: backgroundAIUsageConsentKey) }
    }

    static let backgroundAIUsageConsentKey = "aiBackground.usageConsented"

    /// Remove credentials from the retired client-side provider integrations
    /// and all former direct-Meta trial flags.
    /// This fixed-size upgrade cleanup runs once per installation; no request
    /// path can read these values after the update.
    static func purgeRetiredProviderData() {
        purgeRetiredRampRouterData()
        let completionKey = "retiredProviderDataPurged.v1"
        guard !UserDefaults.standard.bool(forKey: completionKey) else { return }

        for key: Key in [
            .anthropicAPIKey, .openAIAPIKey, .groqAPIKey, .cerebrasAPIKey,
            .geminiAPIKey, .xaiAPIKey, .retiredMetaTrialAPIKey,
            .fireworksAPIKey, .nvidiaAPIKey, .openRouterAPIKey,
            .elevenLabsAPIKey, .togetherAIAPIKey, .wisprAPIKey,
            .assemblyAIAPIKey, .cartesiaAPIKey,
        ] {
            delete(key)
        }
        for key in [
            "aiBackground.metaFreeTrial.active",
            "aiBackground.metaFreeTrial.startedAt",
            "aiBackground.metaFreeTrial.exhausted",
            "aiBackground.metaFreeTrial.limitUSD",
        ] {
            PreferenceStore.remove(forKey: key)
        }
        UserDefaults.standard.set(true, forKey: completionKey)
    }

    /// Ramp Router was removed on 2026-09-23 in
    /// the `ramp-router` change. A learner's own Ramp key is a live credential with nothing
    /// left in the app to show or remove it, so it goes, and so do Ramp's
    /// model slot, its user-added models and its context-window cache. Runs
    /// once per installation. A stored route that still names "Ramp Router"
    /// is left alone: it no longer decodes to a provider, so Settings reports
    /// it as a selection to re-pick rather than silently running another model.
    private static func purgeRetiredRampRouterData() {
        let completionKey = "retiredRampRouterDataPurged.v1"
        guard !UserDefaults.standard.bool(forKey: completionKey) else { return }
        delete(.retiredOwnRampRouterKey)
        for key in ["ramp_router_model", "chatModels.rampRouterCustom"] {
            PreferenceStore.remove(forKey: key)
        }
        UserDefaults.standard.removeObject(forKey: "aiCapabilities.rampRouterContextLength")
        UserDefaults.standard.set(true, forKey: completionKey)
    }

    /// Chat and reviews are initiated directly by the learner. On the
    /// managed rail, every task that follows the Background model is blocked
    /// until onboarding has captured explicit credit consent.
    static func isAIUsageAllowed(for task: AITask) -> Bool {
        return !task.usesBackgroundModelDefault || hasConsentedToBackgroundAIUsage
    }

    /// The three reasons a signed-in learner's background work cannot run,
    /// besides the app lock (`ManagedAI.appLockedMessage`).
    /// Named so the surfaces that must route each one to its own fix — the
    /// paper row's recovery button most visibly — match on a constant rather
    /// than on a re-typed sentence.
    static let emptyBalanceMessage = "Add your OpenRouter key in Settings → AI Usage to run this."
    static let invalidModelRouteMessage =
        "The selected AI model route is invalid. Choose the model again in Settings."
    static let backgroundAIConsentMessage =
        "Background AI usage has not been accepted. Open Getting Started to review and agree to it."

    /// Why `resolveConfig` came back nil when a learner asks for background work
    /// directly and deserves better than "configure an API key". Nil when
    /// missing consent is not the reason.
    static func backgroundAIUnavailableMessage(for task: AITask) -> String? {
        if ManagedAI.isAppLocked {
            return ManagedAI.appLockedMessage
        }
        if AICreditEntitlement.isOutOfCredits {
            return emptyBalanceMessage
        }
        if modelRouteConfigurationIsInvalid(for: task) {
            return invalidModelRouteMessage
        }
        guard task.usesBackgroundModelDefault, !hasConsentedToBackgroundAIUsage else { return nil }
        return backgroundAIConsentMessage
    }

    /// Get the custom prompt override for a specific AI task, or nil to use the built-in default.
    static func taskPrompt(_ task: AITask) -> String? {
        UserDefaults.standard.string(forKey: "aiTask.\(task.rawValue).prompt")
    }

    /// Set or clear the prompt override for a specific AI task.
    static func setTaskPrompt(_ prompt: String?, for task: AITask) {
        let key = "aiTask.\(task.rawValue).prompt"
        if let prompt, !prompt.isEmpty { PreferenceStore.set(prompt, forKey: key) }
        else { PreferenceStore.remove(forKey: key) }
    }

    /// The provider and model a task will actually use: a background task's
    /// is its own or Background's (`backgroundRoute(for:)`), the chat's its own pick or
    /// the Default Model. Unlike `resolveConfig`, this answers regardless of
    /// session state, so Settings can show what each task resolves to before
    /// sign-in.
    static func resolvedSelection(for task: AITask) -> (provider: AIProvider, model: String) {
        if task.usesBackgroundModelDefault {
            let route = backgroundRoute(for: task)
            return (route.provider, route.model)
        }
        let provider = taskProvider(task) ?? fallbackProvider(for: task)
        return (provider, taskModel(task) ?? model(for: provider))
    }

    /// Resolve the full config (provider + credential + model) for an AI task.
    static func resolveConfig(
        for task: AITask,
        explicitlyAuthorizedBackgroundUsage: Bool = false
    ) -> AITaskConfig? {
        guard ManagedAI.isSignedIn else { return nil }
        // Corrupt, half-synced, or retired provider/model preferences are a
        // configuration failure.
        guard !modelRouteConfigurationIsInvalid(for: task) else {
            return nil
        }
        // Background work can run without a click, so signing in is not consent
        // to spend credits on it. The onboarding acknowledgement is a separate,
        // synced prerequisite checked before any request can be built.
        guard explicitlyAuthorizedBackgroundUsage || isAIUsageAllowed(for: task) else { return nil }
        // The managed rail cannot pay. Refusing at the one place a config is built stops
        // every automatic path — classification, metadata, transcripts, review —
        // from firing requests the proxy will only refuse, and leaves that work
        // pending instead of failed. Reading what is already in the library needs
        // no config and is untouched by this.
        guard !AICreditEntitlement.isOutOfCredits else { return nil }
        // A locked app (the free days over, nothing paid) runs no AI, and its
        // background work waits rather than fails: paying picks it up again.
        guard !ManagedAI.isAppLocked else { return nil }
        // A meeting with no paid model to run on waits, like one with no key.
        guard !isWaitingForPaidModel(task) else { return nil }
        let (provider, resolvedModel) = resolvedSelection(for: task)
        return textConfig(
            provider: provider,
            model: resolvedModel,
            requiresVision: task.requiresVision,
            effort: taskEffort(task),
            requestedSpeed: taskSpeed(task),
            taskLabel: task.rawValue
        )
    }

    /// `resolveConfig` once a route is chosen: the checks every text route
    /// passes before it may be sent, shared with `resolveDocsConfig`.
    private static func textConfig(
        provider: AIProvider,
        model resolvedModel: String,
        requiresVision: Bool,
        effort: AIEffort?,
        requestedSpeed: AISpeed?,
        taskLabel: String
    ) -> AITaskConfig? {
        if AIModelDefaults.isRetiredChatModel(provider: provider, model: resolvedModel) {
            return nil
        }
        // A selected text-only model for a vision task is a configuration error,
        // not permission to bill a different model. Background › Multimodal
        // takes a model that reads images; until one is chosen the task fails
        // closed.
        if requiresVision,
           modelSupportsVision(provider: provider, model: resolvedModel) != true {
            return nil
        }
        // Effort and speed are part of the selected route. If the current model
        // cannot honor either value, the route is invalid; silently omitting it
        // would execute a materially different request than Settings promises.
        if let effort {
            guard AIRequestOptionSupport.supportedEfforts(
                provider: provider,
                model: resolvedModel
            ).contains(effort) else { return nil }
        }
        // A speed rides along whenever the route can carry one. Whether the
        // model's fast endpoint is known is decided at dispatch, after the
        // endpoint cache is primed; failing the whole config on a cold cache
        // here would take the chat down for a stored preference.
        let speed = requestedSpeed.flatMap { speed -> AISpeed? in
            guard speed != .standard else { return nil }
            return AIRequestOptionSupport.routeCanCarrySpeed(provider: provider, model: resolvedModel)
                ? speed : nil
        }
        let routed = routedTextSelection(provider: provider, model: resolvedModel, speed: speed)
        guard let apiKey = apiKey(for: routed.provider) else { return nil }
        var config = AITaskConfig(provider: routed.provider, apiKey: apiKey, model: routed.model)
        // Tag the ledger with the task this config was resolved for, so the AI
        // Usage pane can say which feature each call served.
        config.taskLabel = taskLabel
        config.effort = effort
        config.speed = speed
        return config
    }

    /// Whether a model accepts image input, as far as can be known without a
    /// network call. `nil` means unknown — callers must warn only on a definite
    /// `false`, never on `nil`, so a capable new model is never wrongly flagged.
    ///
    /// The closed labs' currently-offered models are all multimodal, so those
    /// providers answer `true`. OpenRouter is mixed: the answer comes from the
    /// capability captured when the user added the model, then from the directory
    /// snapshot cached alongside prices, and is `nil` until a fetch has run.
    static func modelSupportsVision(provider: AIProvider, model: String) -> Bool? {
        switch provider {
        case .anthropic, .openai, .gemini, .xai, .meta:
            return true
        case .openRouter:
            if model == AIModelDefaults.visionOpenRouter {
                return true
            }
            // Pinned capabilities are available at build time and must not
            // depend on a directory refresh before a vision route is filtered.
            if AIModelDefaults.preferredOpenRouter.contains(model) {
                return model == "meta/\(AIModelDefaults.latestMuseSpark)"
                    || model == "meta-llama/llama-4-maverick"
            }
            if let known = AIModelCatalog.customOpenRouterModel(id: model)?.supportsVision {
                return known
            }
            return AIModelCatalog.openRouterModelSupportsVision(model)
        default:
            return nil
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

    // MARK: - Stripe

    static var stripeAPIKey: String? {
        get { load(.stripeAPIKey) }
        set {
            if let newValue { save(newValue, for: .stripeAPIKey) }
            else { delete(.stripeAPIKey) }
        }
    }

    static var stripeMonthlyLink: String {
        get { load(.stripeMonthlyLink) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.stripeMonthlyLink) }
            else { save(trimmed, for: .stripeMonthlyLink) }
        }
    }

    static var stripeYearlyLink: String {
        get { load(.stripeYearlyLink) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { delete(.stripeYearlyLink) }
            else { save(trimmed, for: .stripeYearlyLink) }
        }
    }

}
