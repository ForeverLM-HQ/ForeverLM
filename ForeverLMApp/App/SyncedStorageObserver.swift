import Foundation
import Observation

// What `@PreferenceStorage` (App/PreferenceStorage.swift) watches its key with.
//
// `@AppStorage` observes its key by KVO, and KVO never fires for a key containing
// a dot: `"studio.foo"` is parsed as a key-path traversal. Almost every key here
// is dotted, so `AppStorage` falls back to `UserDefaults.didChangeNotification`,
// which fires for *every* defaults write in the process. Measured 2026-09-02:
// persisting the center-pane layout (`studio.centerTabGroups.v1`) re-ran the body
// of every view holding one of these, `StudioSidebar` included, which then
// re-diffed the whole sources List: a few hundred milliseconds on a library of a
// few thousand rows, on every pane close. The observer below listens to the same
// notification but compares its own key's stored value first, and only
// invalidates the view when that changed. Inbound remote writes
// (`PreferenceStore.applyInbound`) reach the view the same way.

/// Per-view-identity watcher for one defaults key. Bumps `revision` — the only
/// observation-tracked property — when, and only when, the stored value for its
/// key differs from the one it last saw. Not actor-isolated so the wrapper's
/// nonisolated `DynamicProperty` plumbing can create and poke it; every call
/// happens on the main thread in practice (view bodies, and a main-queue
/// notification observer).
@Observable
final class SyncedStorageObserver {
    private(set) var revision = 0

    @ObservationIgnored private let key: String
    @ObservationIgnored private var lastSeen: Any?
    @ObservationIgnored private var token: NSObjectProtocol?

    init(key: String) {
        self.key = key
        lastSeen = UserDefaults.standard.object(forKey: key)
    }

    deinit {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func startObservingIfNeeded() {
        guard token == nil else { return }
        token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            self?.noteDefaultsChanged()
        }
    }

    func noteDefaultsChanged() {
        let current = UserDefaults.standard.object(forKey: key)
        guard !Self.plistEqual(current, lastSeen) else { return }
        lastSeen = current
        revision &+= 1
    }

    /// `UserDefaults` hands back Foundation bridged types, so `isEqual` is the
    /// comparison that matches `Int` against `NSNumber` and `[String]` against
    /// `NSArray`; `==` is not available on `Any`.
    private static func plistEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?): return (l as? NSObject)?.isEqual(r as? NSObject) ?? false
        default: return false
        }
    }
}
