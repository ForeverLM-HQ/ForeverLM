import Foundation

// The account's Settings by typed key (`Prefs`). Each call goes to the same
// CloudKit read or write as the string accessors it wraps, so the rule holds
// here too: a CloudKit error is propagated, and a value cached on the phone is
// never substituted for the account's.

extension MobileModelPreferenceStore {
    /// A key's stored shape that the phone has no accessor for.
    struct UnsupportedPreferenceShape: LocalizedError {
        let key: String
        let kind: PreferencePlistKind

        var errorDescription: String? {
            "The setting \(key) is stored as \(kind.rawValue), which this iPhone cannot read or write."
        }
    }

    /// The account's value for `key`, or nil when the account has none. The
    /// key's default is not applied: absent and unreachable are both the
    /// caller's to tell apart from a stored value.
    func value<Value>(for key: AccountKey<Value>) async throws -> Value? {
        key.coding.decode(try await storedObject(forKey: key.name, kind: key.coding.kind))
    }

    /// The account's value for `key`, or the key's default when the account
    /// has none.
    func valueOrDefault<Value>(for key: AccountKey<Value>) async throws -> Value {
        try await value(for: key) ?? key.defaultValue
    }

    /// Writes `value` as the account's value for `key`; an optional key set to
    /// nil is cleared on every device.
    func set<Value>(_ value: Value, for key: AccountKey<Value>) async throws {
        switch key.coding.encode(value) {
        case .absent:
            try await removeValue(forKey: key.name)
        case let .unencodable(error):
            throw error
        case let .value(object):
            switch key.coding.kind {
            case .bool:
                guard let flag = object as? Bool else { throw MobileModelRouteError.invalidPreference(key.name) }
                try await setBool(flag, forKey: key.name)
            case .int:
                guard let number = object as? Int else { throw MobileModelRouteError.invalidPreference(key.name) }
                try await setInt(number, forKey: key.name)
            case .string:
                guard let text = object as? String else { throw MobileModelRouteError.invalidPreference(key.name) }
                try await setString(text, forKey: key.name)
            case .strings:
                guard let list = object as? [String] else { throw MobileModelRouteError.invalidPreference(key.name) }
                try await setStringArray(list, forKey: key.name)
            case .double, .float, .data, .date, .dictionary, .array, .any:
                throw UnsupportedPreferenceShape(key: key.name, kind: key.coding.kind)
            }
        }
    }

    /// Clears the account's value for `key` on every device.
    func reset<Value>(_ key: AccountKey<Value>) async throws {
        try await removeValue(forKey: key.name)
    }

    private func storedObject(forKey name: String, kind: PreferencePlistKind) async throws -> Any? {
        switch kind {
        case .bool: return try await bool(forKey: name)
        case .int: return try await int(forKey: name)
        case .string: return try await string(forKey: name)
        case .strings: return try await stringArray(forKey: name)
        case .data: return try await data(forKey: name)
        case .double, .float, .date, .dictionary, .array, .any:
            throw UnsupportedPreferenceShape(key: name, kind: kind)
        }
    }
}
