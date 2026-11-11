import Foundation

/// Every declared preference, gathered from the `Prefs` namespaces.
///
/// Swift has no static reflection, so each namespace keeps an `all` array and
/// this lists the namespaces; `PreferenceRegistryTests` reads the sources and
/// fails when a declaration is missing from its array or a namespace from
/// this list.
enum PreferenceRegistry {
    /// Every exact key, in declaration order.
    static let keys: [AnyPreferenceKey] =
        Prefs.Account.all + Prefs.Models.all + Prefs.AIPolicy.all + Prefs.Spend.all + Prefs.ReadAloud.all
        + Prefs.Imaging.all + Prefs.Studio.all + Prefs.Rail.all + Prefs.Readers.all + Prefs.Space.all
        + Prefs.KnowledgeMap.all + Prefs.Memory.all + Prefs.Planner.all + Prefs.Discovery.all
        + Prefs.Meetings.all + Prefs.Lifecycle.all + Prefs.MCP.all + Prefs.Mobile.all + Prefs.System.all

    /// Every family: the account families in the order the sync boundary has
    /// always listed them, then the device families, then the prefixes the
    /// system and foreign frameworks own.
    static let families: [AnyPreferenceFamily] = Prefs.Families.all + Prefs.System.prefixes

    /// The keys by stored name.
    static let keysByName: [String: AnyPreferenceKey] = Dictionary(keys.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

    /// The declaration a stored key belongs to: its own, or its family's.
    static func scope(of name: String) -> PreferenceScope? {
        if let key = keysByName[name] { return key.scope }
        guard let family = families.first(where: { name.hasPrefix($0.prefix) }) else { return nil }
        switch family.scope {
        case let .account(traits): return .account(traits.record == nil ? [] : .record)
        case let .device(reason): return .device(reason: reason)
        }
    }
}
