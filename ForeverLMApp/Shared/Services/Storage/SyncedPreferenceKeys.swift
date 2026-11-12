import Foundation

/// Which `UserDefaults` keys are *user preferences* that follow the account
/// across devices, and which are deliberately device-local.
///
/// Preferences are persisted to `user_preferences` in `knowledge.db` and synced
/// one row and one record per key, so two Macs changing two different settings
/// never collide. (Conflict resolution is row-level last-write-wins over an
/// opaque payload; a single shared blob row would silently drop one of the two
/// edits.)
///
/// Nothing is listed here. Every key is declared once under
/// `Shared/Preferences` (`Prefs`), as an `AccountKey` or as a `DeviceKey` with
/// its reason, and the sets below are derived from those declarations
/// (`PreferenceRegistry`), so the boundary is reviewed where a key is declared.
/// `UnitTests/Fixtures/preference-keys.golden.json` holds every name, scope
/// and `isSynced` answer; a change to the boundary changes that file.
enum SyncedPreferenceKeys {

    /// Model configuration that must survive a rebuild even when that rebuild
    /// lands in a fresh `UserDefaults` container: the account keys declared
    /// with `.modelConfiguration`.
    ///
    /// Chat-bar picks are deliberately absent: `.chat` is session-scoped,
    /// while the default chat model itself is represented by `ai_provider` plus
    /// the provider's model key. The chat-bar choices kept are the effort and
    /// the speed, which every new chat starts on (`aiRoute.defaultChat.effort`,
    /// `aiRoute.defaultChat.speed`).
    static let persistedModelConfiguration: Set<String> = Set(
        accountKeys.filter { $0.traits.contains(.modelConfiguration) && !$0.traits.contains(.familyMember) }.map(\.name)
    )

    static func isPersistedModelConfiguration(_ key: String) -> Bool {
        guard isSynced(key) else { return false }
        if persistedModelConfiguration.contains(key) { return true }
        if key.hasPrefix(Prefs.Families.aiBackground.prefix) { return true }
        if key.hasPrefix(Prefs.Families.aiTaskRoute.prefix) { return true }
        if key.hasPrefix(Prefs.Families.openRouterHost.prefix) { return true }
        if key.hasPrefix(Prefs.Families.aiBackups.prefix) { return true }
        return key.hasPrefix(Prefs.Families.aiTask.prefix) && !key.hasPrefix(chatTaskPrefix)
    }

    /// A chat's own pick, which is the session's and no model configuration.
    private static let chatTaskPrefix = Prefs.Families.aiTask.name("chat.")

    // MARK: - Synced

    /// Exact keys that sync: every declared `AccountKey`, less the ones that
    /// sync under generation 2 only and the named members of a family, which
    /// sync through their prefix.
    static let synced: Set<String> = Set(
        accountKeys.filter { !$0.traits.contains(.generation2Only) && !$0.traits.contains(.familyMember) }.map(\.name)
    )

    /// Prefixes whose keys are built at runtime and cannot be enumerated: the
    /// declared account families, in declaration order.
    static let syncedPrefixes: [String] = accountFamilies.map(\.prefix)

    // MARK: - Excluded

    /// Keys that must never sync, with the reason: every declared `DeviceKey`.
    /// Checked before `syncedPrefixes`, so an exclusion always beats a prefix
    /// match.
    static let excluded: [String: String] = Dictionary(
        PreferenceRegistry.keys.compactMap { key in key.deviceReason.map { (key.name, $0) } },
        uniquingKeysWith: { first, _ in first }
    )

    /// Prefixes that never sync: the declared device families, and the prefixes
    /// AppKit, the system and foreign frameworks write under.
    static let excludedPrefixes: [String] = PreferenceRegistry.families.compactMap { family in
        family.deviceReason == nil ? nil : family.prefix
    }

    // MARK: - Lookup

    /// Whether a key is a synced user preference. Exclusions win over prefix matches.
    static func isSynced(_ key: String) -> Bool {
        if excluded[key] != nil { return false }
        if excludedPrefixes.contains(where: { key.hasPrefix($0) }) { return false }
        if generation2OnlyKeys.contains(key) { return true }
        if synced.contains(key) { return !generation2MovedKeys.contains(key) }
        return liveSyncedPrefixes.contains(where: { key.hasPrefix($0) })
    }

    /// The exact keys that sync under generation 2 only: Settings of features generation 1 does not
    /// have, so a generation-1 build neither shows them nor syncs them (schema v2 D40). Whether a new
    /// notebook gets its AI-drawn cover, and whether the cover backfill runs
    /// (`Prefs.Imaging.drawNotebookCoversAutomatic`, D53): a spending decision, so it follows the
    /// account.
    static let generation2OnlyKeys: Set<String> = Set(
        accountKeys.filter { $0.traits.contains(.generation2Only) }.map(\.name)
    )

    /// The exact keys that are no synced preference under generation 2, each with the record that holds
    /// it there and a writer that keeps that record: the import-blocked shows (`Mark(importBlocked)`,
    /// `BlockedShowsSync`), and the rail's order, pins and folds (`NotebookState.sidebarKey`, `pinned`,
    /// `expanded`; `NotebookSidebarSync`). The account keys declared with `.record`.
    static let generation2MovedKeys: Set<String> = recordKeys

    /// Whether a key is a `Setting` record of its own under generation 2 (schema v2 §3.5.3): a synced
    /// key that no record took over. The keys and prefixes that became fields of records (§10, the
    /// settings catalog's `records`) are never Settings, whether or not their rows still exist for the
    /// writers that read them.
    static func isSetting(_ key: String) -> Bool {
        guard !recordKeys.contains(key), !recordPrefixes.contains(where: { key.hasPrefix($0) }) else { return false }
        return isSynced(key)
    }

    /// The exact keys whose rows became fields of records (schema v2 §10): the sidebar's order, pins and
    /// folds (`NotebookState.sidebarKey`, `pinned`, `expanded`) and the import-blocked shows
    /// (`Mark(importBlocked)`).
    static let recordKeys: Set<String> = Set(
        accountKeys.filter { $0.traits.contains(.record) && !$0.traits.contains(.familyMember) }.map(\.name)
    )

    /// The prefixes whose rows became fields of records (schema v2 §10): NotebookState's and Enrollment's,
    /// a narration's resume point (`ReadingState.listen`), a deck's card state (`Card`), the quiz scores
    /// (`Sitting`) and a connector's health (`Device.connectorHealth`).
    static let recordPrefixes: [String] = accountFamilies.filter { $0.traits.record != nil }.map(\.prefix)

    /// The prefixes that sync as preferences: the list without the prefixes that moved into records
    /// (§14.1). A deck's card state and the quiz scores have records and still travel as rows.
    static let liveSyncedPrefixes: [String] = accountFamilies.filter { family in
        family.traits.record.map(\.stillSyncsAsPreference) ?? true
    }.map(\.prefix)

    // MARK: - The declarations

    private static let accountKeys: [(name: String, traits: AccountTraits)] = PreferenceRegistry.keys.compactMap { key in
        key.accountTraits.map { (key.name, $0) }
    }

    private static let accountFamilies: [(prefix: String, traits: AccountFamilyTraits)] =
        PreferenceRegistry.families.compactMap { family in
            family.accountTraits.map { (family.prefix, $0) }
        }

    private static func prefixes(in home: PreferenceRecordHome) -> [String] {
        accountFamilies.filter { $0.traits.record == home }.map(\.prefix)
    }
}
