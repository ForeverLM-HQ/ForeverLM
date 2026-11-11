import Foundation
import OSLog

/// Keys this Mac's preferences hold that nothing reads any more, removed once,
/// at launch, after the windows are up and off the main actor.
///
/// **Why it matters.** CFPreferences keeps the whole domain in one dictionary,
/// and after every defaults write the next read re-merges it and diffs it for
/// the KVO observers `@AppStorage` and AppKit register: the whole dictionary,
/// after every write, on whichever thread reads first, usually the main one.
/// Build 210's preferences file was 2.4 MB in 1,490 keys; on a copy of it, in
/// a throwaway suite with one KVO observer, the first read after a write took
/// 46 ms (median of 40). Without the type-named frames below it took 0.34 ms,
/// and 0.28 ms with the Canvas summaries (`KnowledgeMapSummaries.cacheKey`)
/// moved to a file as well. In build 210's stalls that read was the beta
/// sign-up check's, 137 samples of 5 ms.
///
/// **What goes.**
/// - Window and split-view frames saved under a SwiftUI type name
///   (`isTypeNamedFrameKey`). A `WindowGroup` without an id is identified by
///   its type, so AppKit autosaved its frame as `NSWindow Frame
///   SwiftUI.WindowGroup<…>-1-AppWindow-1`, a name of about 1.5 KB that
///   changed whenever a modifier on the scene did: a new key each such build.
///   1,093 of them, 1.7 MB of names, all naming the retired product's module,
///   came over with its preferences (`LegacyIdentityAdoption.copyMissingDefaults`).
///
///   The rule never touches a frame a window of this build could restore,
///   by two guards that each suffice. Every scene has an id now (`studio`,
///   `source-reader`, `third-party-licenses`), so its frame is `NSWindow
///   Frame studio-AppWindow-1`: a name made from an id holds no `<`. And a
///   type-named frame spells out its scene's view types, module and all, so
///   one a scene of this build saved names this module (`ownModuleName`);
///   such a key stays even if a scene without an id comes back. Only a
///   type-named key naming no type of this module goes, which no scene this
///   build declares can ever look up.
/// - Keys whose last reader is gone (`retiredKeys`, `retiredPrefixes`).
///
/// **How.** One `CFPreferencesSetMultiple` removes them all: no
/// `UserDefaults.didChangeNotification` per key, whose main-queue observers
/// would each make the main thread read the domain again, a thousand times
/// over. The completion mark is written only once a second listing finds
/// nothing retired left, so a removal cfprefsd refused is tried again at the
/// next launch, and a launch after a finished one costs one read.
enum RetiredDefaultsCleanup {
    /// Set once the domain holds nothing retired. To retire another key, add
    /// it below and bump the version; the next launch removes it.
    static let completionKey = Prefs.Lifecycle.retiredDefaultsCleanupDone.name
    /// The AppKit autosave families whose names SwiftUI built from a scene's
    /// type: a window's frame, and the subview frames of a split view in it.
    static let frameAutosavePrefixes = ["NSWindow Frame ", "NSSplitView Subview Frames "]

    /// This build's Swift module, as a type name spells it ("ForeverLM").
    static let ownModuleName: String = {
        let qualified = String(reflecting: RetiredDefaultsCleanup.self)
        return String(qualified.prefix { $0 != "." })
    }()

    /// Whether `key` is a frame AppKit saved under a SwiftUI type name — a
    /// Swift generic type, `<` and all, where a scene id would be — that names
    /// no type of this module, so no scene of this build saved it or can
    /// restore it.
    static func isTypeNamedFrameKey(_ key: String) -> Bool {
        guard let prefix = frameAutosavePrefixes.first(where: { key.hasPrefix($0) }) else { return false }
        let name = key.dropFirst(prefix.count)
        return name.contains("<") && !name.contains(ownModuleName + ".")
    }

    /// Exact keys nothing reads or writes any more.
    static let retiredKeys: Set<String> = [
        // Chapter titles cached by local PDF path; the code that read and
        // wrote them went with the semantic heuristics on 2026-08-05.
        "enrichedChapterTitles",
        // Written by builds older than this repository (2026-07-24) and
        // read by none since.
        "readai.importedMeetingIDs",
        "bookNameOverrides",
        "drive.lastDisconnectReason",
    ]

    /// Prefixes of keys nothing reads or writes any more: a per-day usage log
    /// and its daily totals from builds older than this repository (dated
    /// 2026-03 and 2026-04). Usage lives in `ai_usage_events` in knowledge.db.
    /// They stay in `SyncedPreferenceKeys.excludedPrefixes`, so an older
    /// build that writes one again never syncs it.
    static let retiredPrefixes = ["usage_records_", "usage_daily_total_"]

    static func isRetired(_ key: String) -> Bool {
        isTypeNamedFrameKey(key) || retiredKeys.contains(key) || retiredPrefixes.contains { key.hasPrefix($0) }
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
        category: "Preferences"
    )

    /// The production entry point: this app's own domain, at most once per
    /// process however many windows ask. Blocking work, so callers run it off
    /// the main actor at `.utility`.
    static func runAtLaunch() {
        _ = launchRun
    }

    private static let launchRun: Int = removeRetiredKeysIfNeeded(applicationID: kCFPreferencesCurrentApplication)

    /// Removes every retired key `applicationID`'s own domain holds (the
    /// current user's, any host: where `UserDefaults` writes), then marks the
    /// domain done. Returns how many keys went; 0 once marked.
    @discardableResult
    static func removeRetiredKeysIfNeeded(applicationID: CFString) -> Int {
        let user = kCFPreferencesCurrentUser
        let host = kCFPreferencesAnyHost
        if (CFPreferencesCopyAppValue(completionKey as CFString, applicationID) as? Bool) == true { return 0 }
        func retiredKeysHeld() -> [String] {
            (CFPreferencesCopyKeyList(applicationID, user, host) as? [String] ?? []).filter(isRetired)
        }
        let retired = retiredKeysHeld()
        if !retired.isEmpty {
            CFPreferencesSetMultiple(nil, retired as CFArray, applicationID, user, host)
        }
        let left = retired.isEmpty ? 0 : retiredKeysHeld().count
        guard left == 0 else {
            logger.error("Could not remove \(left, privacy: .public) retired preference keys; trying again at the next launch")
            return retired.count - left
        }
        CFPreferencesSetValue(completionKey as CFString, kCFBooleanTrue, applicationID, user, host)
        if !retired.isEmpty {
            logger.notice("Removed \(retired.count, privacy: .public) preference keys nothing reads any more")
        }
        return retired.count
    }
}
