import Foundation

/// Reads `defaults write com.foreverlm …` settings that have no UI, from whichever
/// preference domain the user actually wrote to.
///
/// **The problem.** The `defaults` CLI resolves the *domain* form to a sandbox
/// container whenever one exists on disk, and one lingers under
/// `~/Library/Containers/com.foreverlm/` from an abandoned sandboxed flavor. Every
/// build this notebook still produces is unsandboxed and reads the user domain:
///
///     container    ~/Library/Containers/com.foreverlm/Data/Library/Preferences/com.foreverlm.plist
///     user domain  ~/Library/Preferences/com.foreverlm.plist
///
/// So `defaults write com.foreverlm readingListSafari -bool NO` lands
/// in the container plist, invisible to the build that reads the user domain and
/// falls back to its default. The hatches documented in this codebase have therefore
/// never worked, silently: the setting is accepted, stored, and ignored.
///
/// **The fix.** Consult the current domain first, then the other one. That makes
/// the documented command work in every flavor without changing what users type.
///
/// Deliberately scoped to these few keys rather than all preferences. Cross-reading
/// every setting would let a stale container plist — the one here was months out of
/// date — resurrect old values over fresh ones. Real preferences cross build flavors
/// through CloudKit (see `SyncedPreferenceKeys`), which carries a timestamp and can
/// resolve that; a blind file read cannot.
///
/// Full unification would need an App Group container, which means a new entitlement
/// and a Developer ID provisioning-profile regeneration. Not worth it for five
/// developer affordances.
enum DefaultsEscapeHatch {

    // MARK: - Public reads

    static func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        if let value = UserDefaults.standard.object(forKey: key) as? Bool {
            return value
        }
        if let value = foreignDomain()[key] as? Bool {
            return value
        }
        return defaultValue
    }

    static func string(forKey key: String) -> String? {
        if let value = UserDefaults.standard.string(forKey: key) {
            return value
        }
        return foreignDomain()[key] as? String
    }

    /// Load the foreign domain ahead of first use.
    ///
    /// The read is one small local file, but it would otherwise happen lazily on
    /// whichever thread asked first — and several of these keys are read from
    /// main-actor derived-state paths. Priming from the post-launch task keeps that
    /// off the render path entirely.
    static func prime() {
        _ = foreignDomain()
    }

    // MARK: - Foreign domain

    private static let lock = AppLock()
    private nonisolated(unsafe) static var cached: [String: Any]?

    private static func foreignDomain() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let loaded = loadForeignDomain() ?? [:]
        cached = loaded
        return loaded
    }

    private static func loadForeignDomain() -> [String: Any]? {
        guard let url = foreignDomainURL(),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any]
        else { return nil }
        return plist
    }

    /// The plist this build does *not* read.
    ///
    /// Kept symmetrical on purpose. No sandboxed build ships today, but if this ever
    /// runs inside a container it cannot read the user-domain file — the sandbox
    /// denies it — so the lookup returns nil and degrades to current behavior. That
    /// is the harmless direction: there `defaults write` already targets the
    /// container, which is the domain it reads.
    private static func foreignDomainURL() -> URL? {
        let home = NSHomeDirectory()
        let isSandboxed = home.contains("/Library/Containers/")
        if isSandboxed { return nil }

        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Containers/com.foreverlm/Data/Library/Preferences/com.foreverlm.plist")
    }
}
