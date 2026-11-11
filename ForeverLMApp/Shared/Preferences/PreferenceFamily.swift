import Foundation

/// The record that took over a family's rows under generation 2 (schema v2
/// §10). The rows stay in defaults for the readers; the record's own writer
/// keeps them.
enum PreferenceRecordHome: String, Sendable {
    /// A field of the member's `NotebookState`.
    case notebookState
    /// The member's `Enrollment` records.
    case enrollment
    /// `ReadingState.listen`.
    case readingState
    /// This Mac's `Device.connectorHealth`.
    case device
    /// A deck's `Card` records. The row still syncs as a preference.
    case card
    /// A quiz `Sitting`. The row still syncs as a preference.
    case sitting

    /// Whether the family's rows still travel as preferences beside the record.
    var stillSyncsAsPreference: Bool {
        switch self {
        case .card, .sitting: return true
        case .notebookState, .enrollment, .readingState, .device: return false
        }
    }
}

/// What is special about a family of account keys.
struct AccountFamilyTraits: Sendable {
    var record: PreferenceRecordHome?
    /// The iPhone's screens set its rows (`MobileSettingCatalog.families`).
    var phoneWritable = false

    init(record: PreferenceRecordHome? = nil, phoneWritable: Bool = false) {
        self.record = record
        self.phoneWritable = phoneWritable
    }

    static let plain = AccountFamilyTraits()
    static func record(_ home: PreferenceRecordHome) -> AccountFamilyTraits { AccountFamilyTraits(record: home) }
    static let phoneWritable = AccountFamilyTraits(phoneWritable: true)
}

/// Whether a family's keys follow the account or stay on the device.
enum PreferenceFamilyScope: Sendable {
    case account(AccountFamilyTraits)
    case device(reason: String)
}

/// A family without its types, for the registry.
struct AnyPreferenceFamily: Sendable {
    let prefix: String
    let scope: PreferenceFamilyScope

    var accountTraits: AccountFamilyTraits? {
        if case let .account(traits) = scope { return traits }
        return nil
    }

    var deviceReason: String? {
        if case let .device(reason) = scope { return reason }
        return nil
    }
}

/// How a family's id becomes the tail of a key and comes back out of one.
struct PreferenceFamilyID<ID>: @unchecked Sendable {
    let string: (ID) -> String
    let parse: (String) -> ID?
}

extension PreferenceFamilyID where ID == String {
    static var string: PreferenceFamilyID<String> {
        PreferenceFamilyID(string: { $0 }, parse: { $0 })
    }
}

extension PreferenceFamilyID where ID: RawRepresentable, ID.RawValue == String {
    static var raw: PreferenceFamilyID<ID> {
        PreferenceFamilyID(string: { $0.rawValue }, parse: { ID(rawValue: $0) })
    }
}

/// What both kinds of family share: a prefix, an id, and the way a row's value
/// is stored.
protocol PreferenceFamilyProtocol {
    associatedtype ID
    associatedtype Value
    var prefix: String { get }
    var id: PreferenceFamilyID<ID> { get }
    var coding: PreferenceCoding<Value> { get }
    var erased: AnyPreferenceFamily { get }
}

extension PreferenceFamilyProtocol {
    /// The stored key for one member: the prefix and the id, byte for byte what
    /// the builders before the typed layer made.
    func name(_ id: ID) -> String {
        prefix + self.id.string(id)
    }

    /// The member a stored key names; nil when the key is not of this family or
    /// is the bare prefix.
    func id(from name: String) -> ID? {
        guard name.hasPrefix(prefix), name.count > prefix.count else { return nil }
        return id.parse(String(name.dropFirst(prefix.count)))
    }

    /// Every stored row of the family, by member. One scan of the storage,
    /// whoever asks.
    func rows(in storage: any PreferenceBacking = Preferences.storage) -> [ID: Value] where ID: Hashable {
        var rows: [ID: Value] = [:]
        for (name, stored) in storage.rows(withPrefix: prefix) {
            guard let member = id(from: name), let value = coding.decode(stored) else { continue }
            rows[member] = value
        }
        return rows
    }
}

/// Account keys built at runtime from a prefix and an id: one row per member,
/// so two devices changing two members never collide.
struct AccountFamily<ID, Value>: PreferenceFamilyProtocol, @unchecked Sendable {
    let prefix: String
    let id: PreferenceFamilyID<ID>
    let coding: PreferenceCoding<Value>
    let defaultValue: Value
    let traits: AccountFamilyTraits

    init(
        prefix: String, id: PreferenceFamilyID<ID>, default defaultValue: Value, coding: PreferenceCoding<Value>,
        _ traits: AccountFamilyTraits = .plain
    ) {
        self.prefix = prefix
        self.id = id
        self.coding = coding
        self.defaultValue = defaultValue
        self.traits = traits
    }

    func key(_ member: ID) -> AccountKey<Value> {
        AccountKey(name(member), default: defaultValue, coding: coding, traits.record == nil ? [] : .record)
    }

    var erased: AnyPreferenceFamily {
        AnyPreferenceFamily(prefix: prefix, scope: .account(traits))
    }
}

extension AccountFamily where ID == String {
    /// A family keyed by a plain string id whose rows may be absent.
    init<Wrapped: PreferenceValue>(prefix: String, _ traits: AccountFamilyTraits = .plain) where Value == Wrapped? {
        self.init(prefix: prefix, id: .string, default: nil, coding: .optional(Wrapped.preferenceCoding), traits)
    }

    /// The same for a stored shape that needs its coding named.
    init<Wrapped>(prefix: String, coding: PreferenceCoding<Wrapped>, _ traits: AccountFamilyTraits = .plain)
    where Value == Wrapped? {
        self.init(prefix: prefix, id: .string, default: nil, coding: .optional(coding), traits)
    }
}

/// Device keys built at runtime from a prefix and an id.
struct DeviceFamily<ID, Value>: PreferenceFamilyProtocol, @unchecked Sendable {
    let prefix: String
    let id: PreferenceFamilyID<ID>
    let coding: PreferenceCoding<Value>
    let defaultValue: Value
    let reason: String

    init(
        prefix: String, id: PreferenceFamilyID<ID>, default defaultValue: Value, coding: PreferenceCoding<Value>,
        reason: String
    ) {
        self.prefix = prefix
        self.id = id
        self.coding = coding
        self.defaultValue = defaultValue
        self.reason = reason
    }

    func key(_ member: ID) -> DeviceKey<Value> {
        DeviceKey(name(member), default: defaultValue, coding: coding, reason: reason)
    }

    var erased: AnyPreferenceFamily {
        AnyPreferenceFamily(prefix: prefix, scope: .device(reason: reason))
    }
}

extension DeviceFamily where ID == String {
    /// A family keyed by a plain string id whose rows may be absent.
    init<Wrapped: PreferenceValue>(prefix: String, reason: String) where Value == Wrapped? {
        self.init(prefix: prefix, id: .string, default: nil, coding: .optional(Wrapped.preferenceCoding), reason: reason)
    }

    /// The same for a stored shape that needs its coding named.
    init<Wrapped>(prefix: String, coding: PreferenceCoding<Wrapped>, reason: String) where Value == Wrapped? {
        self.init(prefix: prefix, id: .string, default: nil, coding: .optional(coding), reason: reason)
    }
}

extension DeviceFamily where ID == String, Value == Any? {
    /// A prefix that is only ever kept out of sync: what AppKit, a framework or
    /// a retired feature writes under it, which no code here reads by key.
    static func unread(prefix: String, reason: String) -> DeviceFamily<String, Any?> {
        DeviceFamily(prefix: prefix, id: .string, default: nil, coding: .optional(.any), reason: reason)
    }
}
