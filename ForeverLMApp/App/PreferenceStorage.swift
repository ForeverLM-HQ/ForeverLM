import SwiftUI

/// A view's binding to one preference, by its typed key (`Prefs`).
///
/// The key's name, default and stored shape are taken from the declaration: the view re-renders only when its own key's value
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
    fileprivate let name: String
    fileprivate let defaultValue: Value
    fileprivate let read: (Any?) -> Value?
    fileprivate let write: (Value) -> PreferenceStoredValue

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

// MARK: - A view choice each window keeps for itself

/// A view's binding to a choice its window keeps for itself: a list or grid,
/// a sort, a fold, a column's width. Declared like `@PreferenceStorage`, with
/// the same keys.
///
/// The value is the window's own (`StudioWindowState.viewChoices`), so a click
/// in one window never re-lays out another (product owner, 2026-11-12: "Those
/// two windows have to be independent"). A write also goes to the preference,
/// which is the last choice made in any window: a window that has made none of
/// its own opens with it, and so does the next launch. Outside a Studio window
/// (a popped-out Reader) there is no window state and the preference is the
/// value, as with `@PreferenceStorage`.
///
/// ```swift
/// @WindowStorage(Prefs.Space.layout, default: SpaceLayout.list) private var layout
/// @WindowStorage(Prefs.Space.sidebarRecentsFolded) private var recentsFolded
/// ```
@MainActor
@propertyWrapper
struct WindowStorage<Value>: DynamicProperty {
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    private var preference: PreferenceStorage<Value>

    init(preference: PreferenceStorage<Value>) {
        self.preference = preference
    }

    var wrappedValue: Value {
        get {
            guard let windowState else { return preference.wrappedValue }
            let name = preference.name
            let object = windowState.viewChoiceObject(named: name) { UserDefaults.standard.object(forKey: name) }
            return preference.read(object) ?? preference.defaultValue
        }
        nonmutating set {
            if let windowState {
                switch preference.write(newValue) {
                case let .value(object): windowState.setViewChoice(object, named: preference.name)
                case .absent: windowState.setViewChoice(nil, named: preference.name)
                case .unencodable: break
                }
            }
            preference.wrappedValue = newValue
        }
    }

    var projectedValue: Binding<Value> {
        Binding(
            get: { wrappedValue },
            set: { wrappedValue = $0 }
        )
    }
}

extension WindowStorage {
    init(_ key: AccountKey<Value>) { self.init(preference: PreferenceStorage(key)) }
    init(_ key: DeviceKey<Value>) { self.init(preference: PreferenceStorage(key)) }
    init(_ key: AccountKey<Value?>, default defaultValue: Value) { self.init(preference: PreferenceStorage(key, default: defaultValue)) }
    init(_ key: DeviceKey<Value?>, default defaultValue: Value) { self.init(preference: PreferenceStorage(key, default: defaultValue)) }
}

extension WindowStorage where Value: RawRepresentable, Value.RawValue == String {
    init(_ key: AccountKey<String?>, default defaultValue: Value) { self.init(preference: PreferenceStorage(key, default: defaultValue)) }
    init(_ key: AccountKey<String>, default defaultValue: Value) { self.init(preference: PreferenceStorage(key, default: defaultValue)) }
    init(_ key: DeviceKey<String?>, default defaultValue: Value) { self.init(preference: PreferenceStorage(key, default: defaultValue)) }
    init(_ key: DeviceKey<String>, default defaultValue: Value) { self.init(preference: PreferenceStorage(key, default: defaultValue)) }
}
