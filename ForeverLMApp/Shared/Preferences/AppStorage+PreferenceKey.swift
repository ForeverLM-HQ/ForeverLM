import SwiftUI

// `@AppStorage` for device keys: the name and the default come from the key.
//
// There is no initialiser for an `AccountKey`, on purpose. `AppStorage` writes
// defaults and nothing else, so an account key behind it never reaches the
// other devices: `@AppStorage(Prefs.Planner.dayStart)` does not compile. On
// the Mac a view takes `@PreferenceStorage` for either kind of key; on the
// iPhone an account key is read through `MobileModelPreferenceStore`.

extension AppStorage where Value == Bool {
    init(_ key: DeviceKey<Bool>) {
        self.init(wrappedValue: key.defaultValue, key.name)
    }
}

extension AppStorage where Value == Int {
    init(_ key: DeviceKey<Int>) {
        self.init(wrappedValue: key.defaultValue, key.name)
    }
}

extension AppStorage where Value == Double {
    init(_ key: DeviceKey<Double>) {
        self.init(wrappedValue: key.defaultValue, key.name)
    }
}

extension AppStorage where Value == String {
    init(_ key: DeviceKey<String>) {
        self.init(wrappedValue: key.defaultValue, key.name)
    }
}

extension AppStorage where Value == Data {
    init(_ key: DeviceKey<Data>) {
        self.init(wrappedValue: key.defaultValue, key.name)
    }
}

extension AppStorage where Value == Bool? {
    init(_ key: DeviceKey<Bool?>) {
        self.init(key.name)
    }
}

extension AppStorage where Value == Int? {
    init(_ key: DeviceKey<Int?>) {
        self.init(key.name)
    }
}

extension AppStorage where Value == Double? {
    init(_ key: DeviceKey<Double?>) {
        self.init(key.name)
    }
}

extension AppStorage where Value == String? {
    init(_ key: DeviceKey<String?>) {
        self.init(key.name)
    }
}

extension AppStorage where Value == Data? {
    init(_ key: DeviceKey<Data?>) {
        self.init(key.name)
    }
}

// A key whose declaration has no default of its own, read with the view's.
// The default stays where the feature's type lives, which the shared key
// declarations cannot name.

extension AppStorage where Value == Bool {
    init(_ key: DeviceKey<Bool?>, default defaultValue: Bool) {
        self.init(wrappedValue: defaultValue, key.name)
    }
}

extension AppStorage where Value == Int {
    init(_ key: DeviceKey<Int?>, default defaultValue: Int) {
        self.init(wrappedValue: defaultValue, key.name)
    }
}

extension AppStorage where Value == Double {
    init(_ key: DeviceKey<Double?>, default defaultValue: Double) {
        self.init(wrappedValue: defaultValue, key.name)
    }
}

extension AppStorage where Value == String {
    init(_ key: DeviceKey<String?>, default defaultValue: String) {
        self.init(wrappedValue: defaultValue, key.name)
    }
}

// An enum stored as its raw value under a key declared with the raw type.

extension AppStorage where Value: RawRepresentable, Value.RawValue == String {
    init(_ key: DeviceKey<String?>, default defaultValue: Value) {
        self.init(wrappedValue: defaultValue, key.name)
    }

    init(_ key: DeviceKey<String>, default defaultValue: Value) {
        self.init(wrappedValue: defaultValue, key.name)
    }
}

extension AppStorage where Value: RawRepresentable, Value.RawValue == Int {
    init(_ key: DeviceKey<Int?>, default defaultValue: Value) {
        self.init(wrappedValue: defaultValue, key.name)
    }

    init(_ key: DeviceKey<Int>, default defaultValue: Value) {
        self.init(wrappedValue: defaultValue, key.name)
    }
}
