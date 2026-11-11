import Foundation

/// What every preference key says about itself. `name` is the stored string:
/// once a build has shipped it, it never changes (other devices, the web and
/// the hosted MCP name the same row).
protocol PreferenceKeyProtocol {
    associatedtype Value
    var name: String { get }
    var defaultValue: Value { get }
    var coding: PreferenceCoding<Value> { get }
    var erased: AnyPreferenceKey { get }
}

/// What is special about a preference that follows the account.
struct AccountTraits: OptionSet, Sendable {
    let rawValue: Int

    /// Model configuration that must survive a rebuild into a fresh defaults
    /// container (`SyncedPreferenceKeys.persistedModelConfiguration`).
    static let modelConfiguration = AccountTraits(rawValue: 1 << 0)
    /// The iPhone's screens set it (`MobileSettingCatalog.keys`).
    static let phoneWritable = AccountTraits(rawValue: 1 << 1)
    /// A Setting of a feature generation 1 never had: it syncs under
    /// generation 2 only (`SyncedPreferenceKeys.generation2OnlyKeys`).
    static let generation2Only = AccountTraits(rawValue: 1 << 2)
    /// Its row became a field of a record, kept by that record's own writer;
    /// `PreferenceStore` only mirrors it (`SyncedPreferenceKeys.recordKeys`).
    static let record = AccountTraits(rawValue: 1 << 3)
    /// A named member of a family (`aiBackground.provider` under
    /// `aiBackground.`): it syncs through its family's prefix and is no exact
    /// entry of `SyncedPreferenceKeys.synced` or of the settings catalog.
    static let familyMember = AccountTraits(rawValue: 1 << 4)
}

/// A preference that follows the account: a `user_preferences` row on the Mac
/// and a CloudKit `Setting` for every device. On the Mac it is written through
/// `Preferences.set`, which reaches `PreferenceStore`; on the iPhone it is read
/// and written through `MobileModelPreferenceStore`, never from a local cache.
/// There is no `AppStorage` initialiser for it, on purpose: a plain defaults
/// write of an account key never reaches the other devices.
struct AccountKey<Value>: PreferenceKeyProtocol, @unchecked Sendable {
    let name: String
    let defaultValue: Value
    let coding: PreferenceCoding<Value>
    let traits: AccountTraits

    init(_ name: String, default defaultValue: Value, coding: PreferenceCoding<Value>, _ traits: AccountTraits = []) {
        self.name = name
        self.defaultValue = defaultValue
        self.coding = coding
        self.traits = traits
    }

    var erased: AnyPreferenceKey {
        AnyPreferenceKey(name: name, scope: .account(traits), kind: coding.kind)
    }
}

extension AccountKey where Value: PreferenceValue {
    init(_ name: String, default defaultValue: Value, _ traits: AccountTraits = []) {
        self.init(name, default: defaultValue, coding: Value.preferenceCoding, traits)
    }
}

extension AccountKey {
    /// A key with no default of its own: absent reads as nil, and the reader
    /// says what absent means.
    init<Wrapped: PreferenceValue>(_ name: String, _ traits: AccountTraits = []) where Value == Wrapped? {
        self.init(name, default: nil, coding: .optional(Wrapped.preferenceCoding), traits)
    }

    /// The same for a stored shape that needs its coding named (a dictionary,
    /// an array, an untyped row).
    init<Wrapped>(_ name: String, coding: PreferenceCoding<Wrapped>, _ traits: AccountTraits = []) where Value == Wrapped? {
        self.init(name, default: nil, coding: .optional(coding), traits)
    }
}

/// Whether a key follows the account or stays on the device, with what the
/// review of that boundary needs to see.
enum PreferenceScope: Sendable {
    case account(AccountTraits)
    /// `reason` is why it stays here: what `SyncedPreferenceKeys.excluded`
    /// carried per entry.
    case device(reason: String)

    var isAccount: Bool {
        if case .account = self { return true }
        return false
    }
}

/// A key without its value type, for the registry and for what is derived from
/// it (`SyncedPreferenceKeys`, the golden key file, the lint).
struct AnyPreferenceKey: Sendable {
    let name: String
    let scope: PreferenceScope
    let kind: PreferencePlistKind

    var accountTraits: AccountTraits? {
        if case let .account(traits) = scope { return traits }
        return nil
    }

    var deviceReason: String? {
        if case let .device(reason) = scope { return reason }
        return nil
    }
}
