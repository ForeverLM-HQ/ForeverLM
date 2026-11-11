import Foundation

// The Mac's preference notifications and watchers, by typed key (`Prefs`).
// The string forms stay for the sync projections, which carry stored names.

extension PreferenceStore {
    /// Whether a `didChangeLocally` or `didChangeRemotely` notification may have
    /// changed `key`.
    static func notification<Key: PreferenceKeyProtocol>(_ notification: Notification, mayHaveChanged key: Key) -> Bool {
        self.notification(notification, mayHaveChanged: key.name)
    }

    /// Whether a `didChangeLocally` or `didChangeRemotely` notification may have
    /// changed a member of `family`. A notification that names no keys may have
    /// changed anything.
    static func notification<Family: PreferenceFamilyProtocol>(
        _ notification: Notification, mayHaveChangedMemberOf family: Family
    ) -> Bool {
        guard let keys = notification.userInfo?[changedKeysKey] as? Set<String>, !keys.isEmpty else { return true }
        return keys.contains { $0.hasPrefix(family.prefix) }
    }
}

extension PreferenceKeyWatcher {
    /// Watches one account key: reads it only when a preference notification
    /// names it, and calls back when the value differs from the one last read.
    convenience init(
        _ key: AccountKey<Value>,
        center: NotificationCenter = .default,
        onChange: @escaping (Value) -> Void
    ) {
        self.init(key: key.name, center: center, read: { Preferences.value(key) }, onChange: onChange)
    }

    /// Watches one device key. Its writers reach the watcher when they write
    /// through `Preferences.set` or `@PreferenceStorage`, which announce the
    /// change; a plain defaults write does not.
    convenience init(
        _ key: DeviceKey<Value>,
        center: NotificationCenter = .default,
        onChange: @escaping (Value) -> Void
    ) {
        self.init(key: key.name, center: center, read: { Preferences.value(key) }, onChange: onChange)
    }
}
