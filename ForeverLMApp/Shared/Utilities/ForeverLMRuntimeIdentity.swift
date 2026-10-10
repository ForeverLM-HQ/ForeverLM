import Foundation

/// Build-owned identity for the installed app and the Xcode development app.
///
/// Release builds remain the daily-use ForeverLM installation. The macOS Debug
/// configuration defines `FOREVERLM_DEVELOPMENT`, giving the app a separate
/// bundle, local library, iCloud document root, URL callback, Keychain vault,
/// and MCP listener while keeping the same code and CloudKit schema.
///
/// The FirstRunDebug configuration adds `FOREVERLM_FIRST_RUN` on top: a third app,
/// `com.foreverlm.dev.firstrun`, that exists to be opened as a stranger would
/// open ForeverLM. It is a Dev build in every behavior (no Sparkle, a yielding
/// MCP tunnel), but nothing it keeps is shared with the seeded Dev library, and
/// `scripts/reset_first_run_app.sh` returns it to never having been opened.
enum ForeverLMRuntimeIdentity {
    struct Profile: Equatable, Sendable {
        let isDevelopment: Bool
        let isFirstRun: Bool
        let displayName: String
        /// The `.app` file name, without the extension. It is what Spotlight and the
        /// app pickers of other tools list the app as, so the two development apps
        /// carry short names that typing `@for` in such a picker does not reach.
        /// Kept apart from `productFolderName`, which names the data on disk and in
        /// iCloud and must not move with the app's file name.
        let bundleFileName: String
        let productFolderName: String
        let urlScheme: String
        let keychainService: String
        let keychainVaultAccount: String
        let keychainAccessGroupSuffix: String
        let mcpLoopbackPort: UInt16
    }

    static func profile(isDevelopment: Bool, isFirstRun: Bool = false) -> Profile {
        if isDevelopment, isFirstRun {
            return Profile(
                isDevelopment: true,
                isFirstRun: true,
                displayName: "ForeverLM (First Run)",
                bundleFileName: "FirstRunLM",
                productFolderName: "ForeverLM First Run",
                urlScheme: "foreverlm-firstrun",
                keychainService: "com.foreverlm.dev.firstrun",
                keychainVaultAccount: "__foreverlm_firstrun_keychain_vault_v1",
                keychainAccessGroupSuffix: "com.foreverlm.dev.firstrun.shared",
                mcpLoopbackPort: 8524
            )
        }
        if isDevelopment {
            return Profile(
                isDevelopment: true,
                isFirstRun: false,
                // Matches CFBundleName, so the menu bar and in-app copy agree.
                // The product folder below stays "ForeverLM Dev": it names the
                // seeded library on disk and in iCloud Documents.
                displayName: "ForeverLM (Dev)",
                bundleFileName: "DevLM",
                productFolderName: "ForeverLM Dev",
                urlScheme: "foreverlm-dev",
                keychainService: "com.foreverlm.dev",
                keychainVaultAccount: "__foreverlm_dev_keychain_vault_v1",
                keychainAccessGroupSuffix: "com.foreverlm.dev.shared",
                mcpLoopbackPort: 8523
            )
        }
        return Profile(
            isDevelopment: false,
            isFirstRun: false,
            displayName: "ForeverLM",
            bundleFileName: "ForeverLM",
            productFolderName: "ForeverLM",
            urlScheme: "foreverlm",
            keychainService: "com.foreverlm",
            keychainVaultAccount: "__foreverlm_keychain_vault_v1",
            keychainAccessGroupSuffix: "com.foreverlm.shared",
            mcpLoopbackPort: 8522
        )
    }

    #if os(macOS) && FOREVERLM_DEVELOPMENT && FOREVERLM_FIRST_RUN
    private static let activeProfile = profile(isDevelopment: true, isFirstRun: true)
    #elseif os(macOS) && FOREVERLM_DEVELOPMENT
    private static let activeProfile = profile(isDevelopment: true)
    #else
    private static let activeProfile = profile(isDevelopment: false)
    #endif

    static var isDevelopment: Bool { activeProfile.isDevelopment }
    /// The FirstRun app: a Dev build that stands in for a stranger's first
    /// launch, so anything the learner reads should be what production shows.
    static var isFirstRun: Bool { activeProfile.isFirstRun }
    static var displayName: String { activeProfile.displayName }
    static var bundleFileName: String { activeProfile.bundleFileName }
    static var productFolderName: String { isolatedFolderName ?? activeProfile.productFolderName }

    /// A Development build's own data folder under Application Support, from `FOREVERLM_DATA_FOLDER_NAME`
    /// (one path component, never a profile's folder): the isolated instance the cutover rehearsal runs on
    /// (docs/cloudkit-schema-design.md §14 WP28), so a generation or seed override never reaches the store
    /// every Dev build opens. Nil in Release and First Run builds and when the variable is unset.
    static let isolatedFolderName: String? = isolatedFolderName(
        environment: ProcessInfo.processInfo.environment, isDevelopmentBuild: isDevelopmentDataBuild
    )

    static func isolatedFolderName(environment: [String: String], isDevelopmentBuild: Bool) -> String? {
        guard isDevelopmentBuild,
              let name = environment["FOREVERLM_DATA_FOLDER_NAME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return nil }
        let profileFolders = [false, true].flatMap { isDevelopment in
            [false, true].map { isFirstRun in profile(isDevelopment: isDevelopment, isFirstRun: isFirstRun).productFolderName }
        }
        return profileFolders.contains(name) ? nil : name
    }

    private static var isDevelopmentDataBuild: Bool {
        #if os(macOS) && FOREVERLM_DEVELOPMENT
        return !activeProfile.isFirstRun
        #else
        return false
        #endif
    }
    static var urlScheme: String { activeProfile.urlScheme }
    static var keychainService: String { activeProfile.keychainService }
    static var keychainVaultAccount: String { activeProfile.keychainVaultAccount }
    static var keychainAccessGroupSuffix: String { activeProfile.keychainAccessGroupSuffix }
    static var mcpLoopbackPort: UInt16 { activeProfile.mcpLoopbackPort }

    /// Whether this process is a unit-test host: the Debug app that XCTest and Swift Testing load their bundle
    /// into. The host is generation 2 on the shared Development container, so anything that would start a
    /// real activation or a real sync in it (writing to a store and a container the learner's Dev app uses)
    /// checks this first (`GenerationActivationLauncher`, `MacSyncSession.startIfEnabled`).
    static var isTestHost: Bool {
        isTestHost(environment: ProcessInfo.processInfo.environment, arguments: ProcessInfo.processInfo.arguments,
                   bundlePath: Bundle.main.bundlePath, testFrameworkLoaded: NSClassFromString("XCTestCase") != nil)
    }

    static func isTestHost(environment: [String: String], arguments: [String], bundlePath: String, testFrameworkLoaded: Bool = false) -> Bool {
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil { return true }
        if arguments.contains(where: { $0.contains("xctest") }) { return true }
        return bundlePath.hasSuffix(".xctest") || testFrameworkLoaded
    }

    /// The folder in `~/Library/Mobile Documents` that holds ForeverLM's iCloud Documents: the
    /// document scope of the `iCloud.com.foreverlm` container, under which most of the learner's
    /// content files still sit, fully downloaded, in `Documents/<productFolderName>`. The Mac reads
    /// them by plain path (`StorageService.ubiquityContentRootPath`), which a non-sandboxed app may do
    /// whatever team signs it. No build is entitled to that container any more (it stayed with the
    /// personal team when ForeverLM moved to the company Apple team, 2026-10-09), so nothing resolves it
    /// through `url(forUbiquityContainerIdentifier:)` and nothing constructs it as a `CKContainer`:
    /// `CKContainer(identifier:)` traps on a container the app is not entitled to.
    static let iCloudDocumentsFolderName = "iCloud~com~foreverlm"

    static var applicationSupportDirectoryURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    static var applicationSupportRootURL: URL {
        applicationSupportDirectoryURL
            .appendingPathComponent(productFolderName, isDirectory: true)
    }

    /// The one folder both profiles resolve to, holding derived caches that
    /// carry no identity. Everything under it must be re-derivable from scratch
    /// and byte-identical whichever profile produced it, because production and
    /// Dev run at the same time by design and neither owns what it finds here.
    ///
    /// Deliberately *not* a profile folder: it holds no `knowledge.db`, so the
    /// `user_version` interlock that keeps the two libraries apart has nothing
    /// to guard here. The name is also outside the product-folder pattern
    /// `StorageService` uses to strip a root from a stored content path, which
    /// is correct — no content source is ever stored under this folder.
    static let sharedProductFolderName = "ForeverLM Shared"

    static var sharedDerivedCacheRootURL: URL {
        applicationSupportDirectoryURL
            .appendingPathComponent(sharedProductFolderName, isDirectory: true)
    }

    static func sharedDerivedCacheURL(named name: String) -> URL {
        sharedDerivedCacheRootURL.appendingPathComponent(name, isDirectory: true)
    }

    /// Per-request TTS audio, keyed by a SHA-256 of provider, model, voice,
    /// speed and text. Two profiles asking for the same narration produce the
    /// same bytes under the same name, so the second one should not pay for it.
    /// The `ArticleMarkers` half of the old per-profile `TTSAudioCache` stays
    /// per-profile — see `ArticleSpeechAudioCache.markerDirectory`.
    static var sharedTTSAudioCacheURL: URL {
        sharedDerivedCacheURL(named: "TTSAudioCache")
    }

    /// Voice samples, keyed by a SHA-256 of model, voice and the fixed sample
    /// text. The repository prewarms every voice in the catalog, so a split
    /// cache means each profile separately pays to generate the same set.
    static var sharedVoicePreviewCacheURL: URL {
        sharedDerivedCacheURL(named: "ReadAloudVoicePreviews")
    }

    static var localContentRootURL: URL {
        applicationSupportRootURL.appendingPathComponent("Content", isDirectory: true)
    }

    static var diagnosticsRootURL: URL {
        applicationSupportRootURL.appendingPathComponent("Diagnostics", isDirectory: true)
    }
}

/// Which CloudKit sync this build runs (D40, docs/cloudkit-schema-design.md §13.2). Every build is
/// generation 2, the schema-v2 sync on `libraryContainerIdentifier`: generation 1's container stayed
/// with the old Apple team, and no build is entitled to it. What is left of generation 1 is the store's
/// own behaviour behind `.one`, which a test pins (`pinnedSyncGeneration`), until WP30 deletes it.
enum SyncGeneration: Int, Sendable, Equatable {
    case one = 1
    case two = 2

    /// A build setting's value: "1" or "2", nothing else.
    init?(setting: String) {
        guard let number = Int(setting.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(rawValue: number)
    }
}

extension ForeverLMRuntimeIdentity {
    static let syncGenerationInfoKey = "ForeverLMSyncGeneration"
    static let libraryContainerInfoKey = "ForeverLMLibraryContainer"
    /// The Dev-only override, honoured on an isolated Development instance alone.
    static let syncGenerationOverrideKey = "FOREVERLM_SYNC_GENERATION"

    /// This build's generation: the `FOREVERLM_SYNC_GENERATION` build setting of its configuration,
    /// which `project.yml` sets to 2 on every configuration of both apps and Info.plist carries as
    /// `ForeverLMSyncGeneration`. A bundle without a readable value is generation 2 as well: no build
    /// can sync generation 1, whose container stayed with the old Apple team.
    static var syncGeneration: SyncGeneration { pinnedSyncGeneration ?? configuredSyncGeneration }

    /// A test's own generation, bound for the task that runs it: the Mac test host is a Debug build and
    /// so runs generation 2, and a test of what generation 1 still does (the preference rows a
    /// notebook's ticks and collections live in) binds `.one` around its body. Nothing in the app binds
    /// it, so a launch always reads its configuration.
    @TaskLocal static var pinnedSyncGeneration: SyncGeneration?

    private static let configuredSyncGeneration: SyncGeneration = resolveSyncGeneration(
        configured: infoString(syncGenerationInfoKey),
        override: ProcessInfo.processInfo.environment[syncGenerationOverrideKey],
        overrideAllowed: honoursSyncGenerationOverride
    )

    static func resolveSyncGeneration(configured: String?, override: String?, overrideAllowed: Bool) -> SyncGeneration {
        if overrideAllowed, let override, let generation = SyncGeneration(setting: override) {
            return generation
        }
        return configured.flatMap(SyncGeneration.init(setting:)) ?? .two
    }

    /// Whether the Dev-only override may choose the generation: only a Development build (Debug and
    /// FirstRun sign for CloudKit's Development environment) whose data folder is its own, never one
    /// of the three profile folders, so one agent's test can never activate the store every Dev
    /// build opens. A launch with `FOREVERLM_DATA_FOLDER_NAME` set (`isolatedFolderName`) has such a folder.
    static var honoursSyncGenerationOverride: Bool {
        #if os(macOS) && FOREVERLM_DEVELOPMENT
        let ownFolder = applicationSupportRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let profileFolders = [false, true].flatMap { isDevelopment in
            [false, true].map { isFirstRun in
                applicationSupportDirectoryURL
                    .appendingPathComponent(profile(isDevelopment: isDevelopment, isFirstRun: isFirstRun).productFolderName, isDirectory: true)
                    .standardizedFileURL.resolvingSymlinksInPath()
            }
        }
        return !profileFolders.contains(ownFolder)
        #else
        return false
        #endif
    }

    /// The one CloudKit container the app syncs with (docs/cloudkit-schema-design.md §2.1): the
    /// `FOREVERLM_CLOUDKIT_CONTAINER` build setting, which Info.plist carries as
    /// `ForeverLMLibraryContainer`. `project.yml` sets it to `iCloud.com.foreverlm.knowledge` in every
    /// configuration of both apps, and every entitlements file grants exactly that container. The
    /// signed environment entitlement picks its Development or Production replica. Nil in a bundle
    /// without the key or with it empty, which has no sync: nothing guesses a container for it, since
    /// `CKContainer(identifier:)` traps on one the app is not entitled to.
    static let libraryContainerIdentifier: String? = infoString(libraryContainerInfoKey)

    /// An Info.plist string, trimmed; nil when the key is absent or its value empty.
    private static func infoString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Whether this launch may spend a model on source clean-up: the canonical
/// content clean-up that every new paper and article passes through, and the
/// historical podcast ad clean-up.
///
/// The Dev app's library is a copy of a library the installed app has already
/// cleaned, and its queues refill with every schema bump that restages history,
/// so a Dev launch used to re-buy that work on every build. A Dev build now
/// skips paid clean-up: a newly added source is published with its raw text so
/// ingestion still finishes, and historical rows stay queued untouched. A
/// developer working on the clean-up itself opts back in for one launch with
/// `FOREVERLM_SOURCE_CLEANUP=1` in the environment. The installed app is never
/// affected.
enum PaidSourceCleanupPolicy {
    static let optInEnvironmentKey = "FOREVERLM_SOURCE_CLEANUP"

    static func runsPaidCleanup(
        isDevelopment: Bool,
        environment: [String: String]
    ) -> Bool {
        guard isDevelopment else { return true }
        return environment[optInEnvironmentKey] == "1"
    }

    static var runsPaidCleanup: Bool {
        runsPaidCleanup(
            isDevelopment: ForeverLMRuntimeIdentity.isDevelopment,
            environment: ProcessInfo.processInfo.environment
        )
    }
}
