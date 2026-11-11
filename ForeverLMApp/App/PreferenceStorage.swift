import SwiftUI

/// A view's binding to one preference, by its typed key (`Prefs`).
///
/// It is `SyncedStorage` with the key's name, default and stored shape taken
/// from the declaration: the view re-renders only when its own key's value
/// changes (`SyncedStorageObserver`), a write goes to `UserDefaults.standard`
/// and is mirrored to `PreferenceStore`, which queues an account key for the
/// other devices and announces either kind to its watchers. A device key is
/// welcome here too: `AppStorage` observes by KVO, which never fires for a
/// dotted key, so it re-renders on every defaults write in the process.
///
/// ```swift
/// @PreferenceStorage(Prefs.Rail.chatsExpanded) private var chatsExpanded
/// @PreferenceStorage(Prefs.Studio.zoomStep, default: UIZoom.defaultStep) private var zoomStep
/// @PreferenceStorage(Prefs.Planner.thinkFirstLevel, default: ThinkFirstLevel.off) private var level
/// ```
@propertyWrapper
struct PreferenceStorage<Value>: DynamicProperty {
    @State private var observer: SyncedStorageObserver
    private let name: String
    private let defaultValue: Value
    private let read: (Any?) -> Value?
    private let write: (Value) -> PreferenceStoredValue

    private init(
        name: String,
        defaultValue: Value,
        read: @escaping (Any?) -> Value?,
        write: @escaping (Value) -> PreferenceStoredValue
    ) {
        self.name = name
        self.defaultValue = defaultValue
        self.read = read
        self.write = write
        _observer = State(wrappedValue: SyncedStorageObserver(key: name))
    }

    /// Called by SwiftUI before each body evaluation. Starts observing the
    /// defaults only for the instance SwiftUI actually keeps.
    func update() {
        observer.startObservingIfNeeded()
    }

    var wrappedValue: Value {
        get {
            // Reading the revision inside a body subscribes the view to this
            // key's changes, and to nothing else in `UserDefaults`.
            _ = observer.revision
            return read(UserDefaults.standard.object(forKey: name)) ?? defaultValue
        }
        nonmutating set {
            switch write(newValue) {
            case let .value(object):
                UserDefaults.standard.set(object, forKey: name)
            case .absent:
                UserDefaults.standard.removeObject(forKey: name)
            case let .unencodable(error):
                assertionFailure("Preference \(name) has no stored form: \(error)")
                return
            }
            PreferenceStore.mirrorExternalWrite(forKey: name)
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

// MARK: - A key that carries its own default

extension PreferenceStorage {
    init(_ key: AccountKey<Value>) {
        self.init(name: key.name, defaultValue: key.defaultValue, read: key.coding.decode, write: key.coding.encode)
    }

    init(_ key: DeviceKey<Value>) {
        self.init(name: key.name, defaultValue: key.defaultValue, read: key.coding.decode, write: key.coding.encode)
    }
}

// MARK: - A key with no default of its own, read with the view's

extension PreferenceStorage {
    init(_ key: AccountKey<Value?>, default defaultValue: Value) {
        self.init(
            name: key.name, defaultValue: defaultValue,
            read: { key.coding.decode($0) ?? nil }, write: { key.coding.encode($0) }
        )
    }

    init(_ key: DeviceKey<Value?>, default defaultValue: Value) {
        self.init(
            name: key.name, defaultValue: defaultValue,
            read: { key.coding.decode($0) ?? nil }, write: { key.coding.encode($0) }
        )
    }
}

// MARK: - An enum stored as its raw string under a key declared as a string

extension PreferenceStorage where Value: RawRepresentable, Value.RawValue == String {
    init(_ key: AccountKey<String?>, default defaultValue: Value) {
        self.init(
            name: key.name, defaultValue: defaultValue,
            read: { ($0 as? String).flatMap(Value.init(rawValue:)) }, write: { .value($0.rawValue) }
        )
    }

    init(_ key: AccountKey<String>, default defaultValue: Value) {
        self.init(
            name: key.name, defaultValue: defaultValue,
            read: { ($0 as? String).flatMap(Value.init(rawValue:)) }, write: { .value($0.rawValue) }
        )
    }

    init(_ key: DeviceKey<String?>, default defaultValue: Value) {
        self.init(
            name: key.name, defaultValue: defaultValue,
            read: { ($0 as? String).flatMap(Value.init(rawValue:)) }, write: { .value($0.rawValue) }
        )
    }

    init(_ key: DeviceKey<String>, default defaultValue: Value) {
        self.init(
            name: key.name, defaultValue: defaultValue,
            read: { ($0 as? String).flatMap(Value.init(rawValue:)) }, write: { .value($0.rawValue) }
        )
    }
}
