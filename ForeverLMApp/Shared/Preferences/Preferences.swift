import Foundation
import os

/// Where preference values are kept. `UserDefaults` is the one production
/// backing; a test binds a suite of its own (`Preferences.withStorage`).
protocol PreferenceBacking {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    /// Every stored row whose key starts with `prefix`.
    func rows(withPrefix prefix: String) -> [String: Any]
}

extension UserDefaults: PreferenceBacking {
    func rows(withPrefix prefix: String) -> [String: Any] {
        dictionaryRepresentation().filter { $0.key.hasPrefix(prefix) }
    }
}

/// A Sendable carrier for the storage a task is bound to; a test's suite is
/// only ever touched by the task that bound it.
struct PreferenceStorageBinding: @unchecked Sendable {
    let backing: any PreferenceBacking

    static let standard = PreferenceStorageBinding(backing: UserDefaults.standard)

    var isStandard: Bool {
        (backing as? UserDefaults) === UserDefaults.standard
    }
}

/// The typed way to read and write a preference. A key (`Prefs`) carries its
/// stored name, value type, default and whether it follows the account, so a
/// call site names none of them.
///
/// - A `DeviceKey` is a plain defaults value on both platforms.
/// - An `AccountKey` is read and written here on the Mac only, where the write
///   goes through `PreferenceStore` (persisted to `user_preferences`, queued
///   for CloudKit, announced). The iPhone has no synchronous view of the
///   account's rows: it uses `MobileModelPreferenceStore.value(for:)`.
///
/// While a test has bound storage of its own, every read and write goes to
/// that storage and nothing reaches `PreferenceStore`, so a test can neither
/// see nor change the learner's settings or put a row on the sync rail.
enum Preferences {
    @TaskLocal static var binding: PreferenceStorageBinding = .standard

    /// The storage this task reads and writes.
    static var storage: any PreferenceBacking { binding.backing }

    private static let logger = Logger(subsystem: "com.foreverlm", category: "Preferences")

    /// Runs `body` with `storage` as the preference storage of the current task.
    /// An asynchronous test binds it the same way with `Preferences.$binding.withValue`.
    static func withStorage<Result>(_ storage: any PreferenceBacking, _ body: () throws -> Result) rethrows -> Result {
        try $binding.withValue(PreferenceStorageBinding(backing: storage), operation: body)
    }

    // MARK: - Device keys

    /// The stored value, or the key's default when nothing is stored or what is
    /// stored has another type.
    static func value<Value>(_ key: DeviceKey<Value>) -> Value {
        read(key)
    }

    /// Whether anything is stored under the key.
    static func isSet<Value>(_ key: DeviceKey<Value>) -> Bool {
        storage.object(forKey: key.name) != nil
    }

    static func set<Value>(_ value: Value, for key: DeviceKey<Value>) {
        write(key.coding.encode(value), name: key.name)
    }

    /// Clears the key, so it reads as its default again.
    static func reset<Value>(_ key: DeviceKey<Value>) {
        write(.absent, name: key.name)
    }

    /// `set`, under the name that says when to call it: after the lock that
    /// guards the in-memory copy is released. A defaults write posts a
    /// notification on the writing thread, and an observer on the main queue
    /// then waits for whoever holds that lock (`PreferenceMemo`).
    static func persist<Value>(_ value: Value, for key: DeviceKey<Value>) {
        set(value, for: key)
    }

    // MARK: - Account keys (the Mac)

    #if os(macOS)
    /// The stored value, or the key's default when nothing is stored or what is
    /// stored has another type.
    static func value<Value>(_ key: AccountKey<Value>) -> Value {
        read(key)
    }

    /// Whether anything is stored under the key.
    static func isSet<Value>(_ key: AccountKey<Value>) -> Bool {
        storage.object(forKey: key.name) != nil
    }

    static func set<Value>(_ value: Value, for key: AccountKey<Value>) {
        write(key.coding.encode(value), name: key.name)
    }

    /// Clears the key on every device, so it reads as its default again.
    static func reset<Value>(_ key: AccountKey<Value>) {
        write(.absent, name: key.name)
    }

    /// `set`, to be called after the lock that guards the in-memory copy is
    /// released (see the device overload).
    static func persist<Value>(_ value: Value, for key: AccountKey<Value>) {
        set(value, for: key)
    }
    #endif

    // MARK: - Plumbing

    private static func read<Key: PreferenceKeyProtocol>(_ key: Key) -> Key.Value {
        key.coding.decode(storage.object(forKey: key.name)) ?? key.defaultValue
    }

    /// The one write path. On the Mac's standard storage it is
    /// `PreferenceStore`, for a device key too: the store writes defaults,
    /// drops a write that changes nothing, announces the change to the key's
    /// watchers, and queues the row only when the key is a synced one.
    private static func write(_ stored: PreferenceStoredValue, name: String) {
        let bound = binding
        switch stored {
        case let .unencodable(error):
            logger.error("Preference \(name, privacy: .public) was not written: \(error.localizedDescription, privacy: .public)")
            assertionFailure("Preference \(name) has no stored form: \(error)")
        case .absent:
            #if os(macOS)
            if bound.isStandard {
                PreferenceStore.remove(forKey: name)
                return
            }
            #endif
            guard bound.backing.object(forKey: name) != nil else { return }
            bound.backing.removeObject(forKey: name)
        case let .value(object):
            #if os(macOS)
            if bound.isStandard {
                PreferenceStore.set(object, forKey: name)
                return
            }
            #endif
            if let existing = bound.backing.object(forKey: name) as? NSObject, existing.isEqual(object as? NSObject) {
                return
            }
            bound.backing.set(object, forKey: name)
        }
    }
}
