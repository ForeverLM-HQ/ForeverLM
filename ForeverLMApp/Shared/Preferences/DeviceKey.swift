import Foundation

/// A preference that stays on this device: a plain defaults value that never
/// reaches `user_preferences` or CloudKit. `reason` is mandatory, because an
/// unexplained device-local key is indistinguishable from one that was
/// forgotten.
struct DeviceKey<Value>: PreferenceKeyProtocol, @unchecked Sendable {
    let name: String
    let defaultValue: Value
    let coding: PreferenceCoding<Value>
    let reason: String

    init(_ name: String, default defaultValue: Value, coding: PreferenceCoding<Value>, reason: String) {
        self.name = name
        self.defaultValue = defaultValue
        self.coding = coding
        self.reason = reason
    }

    var erased: AnyPreferenceKey {
        AnyPreferenceKey(name: name, scope: .device(reason: reason), kind: coding.kind)
    }
}

extension DeviceKey where Value: PreferenceValue {
    init(_ name: String, default defaultValue: Value, reason: String) {
        self.init(name, default: defaultValue, coding: Value.preferenceCoding, reason: reason)
    }
}

extension DeviceKey {
    /// A key with no default of its own: absent reads as nil, and the reader
    /// says what absent means.
    init<Wrapped: PreferenceValue>(_ name: String, reason: String) where Value == Wrapped? {
        self.init(name, default: nil, coding: .optional(Wrapped.preferenceCoding), reason: reason)
    }

    /// The same for a stored shape that needs its coding named (a dictionary,
    /// an array, an untyped row).
    init<Wrapped>(_ name: String, coding: PreferenceCoding<Wrapped>, reason: String) where Value == Wrapped? {
        self.init(name, default: nil, coding: .optional(coding), reason: reason)
    }
}

extension DeviceKey where Value == Any? {
    /// A name that is only ever kept out of sync or cleared: a retired key an
    /// older build may still write, or one whose value no code reads.
    static func unread(_ name: String, reason: String) -> DeviceKey<Any?> {
        DeviceKey(name, default: nil, coding: .optional(.any), reason: reason)
    }
}
