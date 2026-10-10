import SwiftUI
import Observation

/// A drop-in replacement for `@AppStorage` for settings that follow the account.
///
/// Reads and writes go to `UserDefaults.standard` with the same type bridging
/// `AppStorage` applies (`Bool`/`Int`/`Double` all travel as `NSNumber`, so a key
/// written as one reads back as another), and a write is mirrored to
/// `PreferenceStore`, which persists it to `user_preferences` and queues it for
/// CloudKit.
///
/// **Why this no longer wraps `AppStorage`.** `AppStorage` observes its key by
/// KVO, and KVO never fires for a key containing a dot — `"studio.foo"` is parsed
/// as a key-path traversal. Almost every key here is dotted, so `AppStorage` fell
/// back to `UserDefaults.didChangeNotification`, which fires for *every* defaults
/// write in the process. Measured 2026-09-02: persisting the center-pane layout
/// (`studio.centerTabGroups.v1`) re-ran the body of every view holding one of
/// these, `StudioSidebar` included, which then re-diffed the whole sources List —
/// a few hundred milliseconds on a library of a few thousand rows, on every pane
/// close. This wrapper listens to the same notification but compares its own
/// key's stored value first, and only invalidates the view when that changed.
/// Inbound remote writes (`PreferenceStore.applyInbound`) reach the view the same
/// way, which is an improvement: with `AppStorage` they only showed on whatever
/// re-render happened next.
@propertyWrapper
struct SyncedStorage<Value>: DynamicProperty {
    @State private var observer: SyncedStorageObserver
    private let key: String
    private let defaultValue: Value
    private let read: (Any?) -> Value?
    private let write: (Value) -> Any

    private init(
        key: String,
        defaultValue: Value,
        read: @escaping (Any?) -> Value?,
        write: @escaping (Value) -> Any
    ) {
        self.key = key
        self.defaultValue = defaultValue
        self.read = read
        self.write = write
        _observer = State(wrappedValue: SyncedStorageObserver(key: key))
    }

    /// Called by SwiftUI before each body evaluation. Starts observing the
    /// defaults only for the instance SwiftUI actually keeps, so re-creating the
    /// view struct costs one allocation and no notification registration.
    func update() {
        observer.startObservingIfNeeded()
    }

    var wrappedValue: Value {
        get {
            // Reading the revision inside a body subscribes the view to this
            // key's changes, and to nothing else in `UserDefaults`.
            _ = observer.revision
            return read(UserDefaults.standard.object(forKey: key)) ?? defaultValue
        }
        nonmutating set {
            UserDefaults.standard.set(write(newValue), forKey: key)
            PreferenceStore.mirrorExternalWrite(forKey: key)
            observer.noteDefaultsChanged()
        }
    }

    var projectedValue: Binding<Value> {
        Binding(
            get: { wrappedValue },
            set: { wrappedValue = $0 }
        )
    }
}

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

extension SyncedStorage where Value == Bool {
    init(wrappedValue: Value, _ key: String) {
        self.init(
            key: key,
            defaultValue: wrappedValue,
            read: { ($0 as? NSNumber)?.boolValue },
            write: { $0 }
        )
    }
}

extension SyncedStorage where Value == Int {
    init(wrappedValue: Value, _ key: String) {
        self.init(
            key: key,
            defaultValue: wrappedValue,
            read: { ($0 as? NSNumber)?.intValue },
            write: { $0 }
        )
    }
}

extension SyncedStorage where Value == Double {
    init(wrappedValue: Value, _ key: String) {
        self.init(
            key: key,
            defaultValue: wrappedValue,
            read: { ($0 as? NSNumber)?.doubleValue },
            write: { $0 }
        )
    }
}

extension SyncedStorage where Value == String {
    init(wrappedValue: Value, _ key: String) {
        self.init(
            key: key,
            defaultValue: wrappedValue,
            read: { $0 as? String },
            write: { $0 }
        )
    }
}

extension SyncedStorage where Value: RawRepresentable, Value.RawValue == String {
    init(wrappedValue: Value, _ key: String) {
        self.init(
            key: key,
            defaultValue: wrappedValue,
            read: { ($0 as? String).flatMap(Value.init(rawValue:)) },
            write: { $0.rawValue }
        )
    }
}
