import Foundation
import Testing
@testable import ForeverLM

#if os(macOS)

/// The declarations under `Shared/Preferences` (`Prefs`) are the one list of
/// preference keys. These tests keep that list whole (every declaration is in
/// its namespace's `all`, every namespace in the registry), keep the stored
/// names and scopes frozen against `Fixtures/preference-keys.golden.json`, and
/// pin what the typed access stores and reads.
@Suite("Preference registry")
struct PreferenceRegistryTests {

    static var appDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UnitTests
            .deletingLastPathComponent()   // ForeverLMApp
    }

    static var preferencesDirectory: URL {
        appDirectory.appendingPathComponent("Shared/Preferences")
    }

    static var goldenURL: URL {
        appDirectory.appendingPathComponent("UnitTests/Fixtures/preference-keys.golden.json")
    }

    static func declarationFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: preferencesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Prefs+") && $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func matches(_ pattern: String, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    // MARK: - The list is whole

    @Test("Every declared key and family is in its namespace's list, and every namespace is in the registry")
    func everyDeclarationIsRegistered() throws {
        let files = try Self.declarationFiles()
        #expect(files.count >= 20, "the Prefs+*.swift files were not found from this test's path")
        var declaredKeys = 0
        var declaredFamilies = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let keys = try Self.matches(#"static let (\w+) = (?:AccountKey|DeviceKey)<"#, in: text)
            let families = try Self.matches(#"static let (\w+) = (?:AccountFamily|DeviceFamily)<"#, in: text)
            let listed = try Self.matches(#"(\w+)\.erased"#, in: text)
            let declared = keys + families
            #expect(
                Set(declared) == Set(listed),
                "\(file.lastPathComponent): declared but not listed \(Set(declared).subtracting(listed).sorted()), listed but not declared \(Set(listed).subtracting(declared).sorted())"
            )
            #expect(declared.count == Set(declared).count, "\(file.lastPathComponent) declares an identifier twice")
            #expect(listed.count == Set(listed).count, "\(file.lastPathComponent) lists an identifier twice")
            declaredKeys += keys.count
            declaredFamilies += families.count
        }
        #expect(declaredKeys == PreferenceRegistry.keys.count, "a Prefs namespace is missing from PreferenceRegistry.keys")
        #expect(declaredFamilies == PreferenceRegistry.families.count, "a family list is missing from PreferenceRegistry.families")
    }

    @Test("No two declarations share a stored name, and none is empty")
    func namesAreUniqueAndNotEmpty() {
        let names = PreferenceRegistry.keys.map(\.name)
        let repeated = Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        #expect(repeated.isEmpty, "declared twice: \(repeated)")
        #expect(!names.contains(""))
        let prefixes = PreferenceRegistry.families.map(\.prefix)
        #expect(prefixes.count == Set(prefixes).count)
        #expect(!prefixes.contains(""))
        for key in PreferenceRegistry.keys {
            if let reason = key.deviceReason {
                #expect(!reason.isEmpty, "\(key.name) stays on the device without a reason")
            }
        }
        for family in PreferenceRegistry.families {
            if let reason = family.deviceReason {
                #expect(!reason.isEmpty, "\(family.prefix) stays on the device without a reason")
            }
        }
    }

    @Test("A named member of a family sits under an account family, and no other exact key does")
    func familyMembersSitUnderTheirFamily() {
        let accountPrefixes = PreferenceRegistry.families.filter { $0.accountTraits != nil }.map(\.prefix)
        for key in PreferenceRegistry.keys {
            guard let traits = key.accountTraits else { continue }
            let underFamily = accountPrefixes.contains { key.name.hasPrefix($0) }
            #expect(
                traits.contains(.familyMember) == underFamily,
                "\(key.name): a key under an account family's prefix is declared .familyMember, and only such a key"
            )
        }
    }

    // MARK: - The names are frozen

    struct Golden: Decodable {
        struct Key: Decodable, Equatable {
            let name: String
            let scope: String
            let traits: [String]?
            let reason: String?
            let synced: Bool
        }

        struct Prefix: Decodable, Equatable {
            let prefix: String
            let scope: String
            let record: String?
            let phoneWritable: Bool?
            let reason: String?
            let synced: Bool
        }

        let keys: [Key]
        let prefixes: [Prefix]
    }

    static func traitNames(_ traits: AccountTraits) -> [String] {
        var names: [String] = []
        if traits.contains(.familyMember) { names.append("familyMember") }
        if traits.contains(.generation2Only) { names.append("generation2Only") }
        if traits.contains(.modelConfiguration) { names.append("modelConfiguration") }
        if traits.contains(.phoneWritable) { names.append("phoneWritable") }
        if traits.contains(.record) { names.append("record") }
        return names
    }

    @Test("Every stored name, prefix, scope and isSynced answer equals the golden file")
    func goldenKeysAreFrozen() throws {
        let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: Self.goldenURL))
        #expect(golden.keys.count > 300 && golden.prefixes.count > 50)

        let declared = PreferenceRegistry.keys.map { key -> Golden.Key in
            switch key.scope {
            case let .account(traits):
                return Golden.Key(
                    name: key.name, scope: "account", traits: Self.traitNames(traits), reason: nil,
                    synced: SyncedPreferenceKeys.isSynced(key.name)
                )
            case let .device(reason):
                return Golden.Key(
                    name: key.name, scope: "device", traits: nil, reason: reason,
                    synced: SyncedPreferenceKeys.isSynced(key.name)
                )
            }
        }.sorted { $0.name < $1.name }
        let goldenByName = Dictionary(golden.keys.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for key in declared {
            #expect(goldenByName[key.name] == key, "\(key.name) differs from the golden file: \(String(describing: goldenByName[key.name])) there, \(key) declared")
        }
        #expect(Set(golden.keys.map(\.name)) == Set(declared.map(\.name)), "the golden file and the declarations name different keys")

        let declaredPrefixes = PreferenceRegistry.families.map { family -> Golden.Prefix in
            let synced = SyncedPreferenceKeys.isSynced(family.prefix + "example")
            switch family.scope {
            case let .account(traits):
                return Golden.Prefix(
                    prefix: family.prefix, scope: "account", record: traits.record?.rawValue,
                    phoneWritable: traits.phoneWritable ? true : nil, reason: nil, synced: synced
                )
            case let .device(reason):
                return Golden.Prefix(
                    prefix: family.prefix, scope: "device", record: nil, phoneWritable: nil, reason: reason, synced: synced
                )
            }
        }
        let goldenByPrefix = Dictionary(golden.prefixes.map { ($0.prefix, $0) }, uniquingKeysWith: { first, _ in first })
        for family in declaredPrefixes {
            #expect(goldenByPrefix[family.prefix] == family, "\(family.prefix) differs from the golden file: \(String(describing: goldenByPrefix[family.prefix])) there, \(family) declared")
        }
        #expect(Set(golden.prefixes.map(\.prefix)) == Set(declaredPrefixes.map(\.prefix)), "the golden file and the declarations name different prefixes")
    }

    @Test("The sync boundary is the declarations: every account key syncs or has a record, no device key syncs")
    func scopesAgreeWithTheSyncBoundary() {
        for key in PreferenceRegistry.keys {
            switch key.scope {
            case let .account(traits):
                if traits.contains(.record) {
                    #expect(!SyncedPreferenceKeys.isSetting(key.name), "\(key.name) has a record and is no Setting")
                } else {
                    #expect(SyncedPreferenceKeys.isSynced(key.name), "\(key.name) is an account key and does not sync")
                }
            case .device:
                #expect(!SyncedPreferenceKeys.isSynced(key.name), "\(key.name) is a device key and syncs")
                #expect(SyncedPreferenceKeys.excluded[key.name] != nil)
            }
        }
        #expect(SyncedPreferenceKeys.persistedModelConfiguration.count == 49)
        #expect(SyncedPreferenceKeys.persistedModelConfiguration.isSubset(of: SyncedPreferenceKeys.synced))
        #expect(SyncedPreferenceKeys.recordKeys == SyncedPreferenceKeys.generation2MovedKeys)
        #expect(SyncedPreferenceKeys.isPersistedModelConfiguration(Prefs.Families.aiTask.name("summarize.model")))
        #expect(!SyncedPreferenceKeys.isPersistedModelConfiguration(Prefs.Models.chatTaskModel.name))
        #expect(SyncedPreferenceKeys.isPersistedModelConfiguration(Prefs.Models.backgroundProvider.name))
    }

    // MARK: - What a coding stores

    static func isBoolean(_ object: Any?) -> Bool {
        guard let number = object as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func stored<Value>(_ value: Value, _ coding: PreferenceCoding<Value>) -> Any? {
        if case let .value(object) = coding.encode(value) { return object }
        return nil
    }

    @Test("Each coding stores the property-list type its readers expect")
    func codingsStoreTheirPlistType() throws {
        let suite = "PreferenceRegistryTests.codings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(Self.stored(true, .bool), forKey: "bool")
        #expect(Self.isBoolean(defaults.object(forKey: "bool")), "a Bool is stored as a Bool")
        #expect(PreferenceCoding.bool.decode(defaults.object(forKey: "bool")) == true)

        defaults.set(Self.stored(7, .int), forKey: "int")
        #expect(!Self.isBoolean(defaults.object(forKey: "int")))
        #expect(defaults.object(forKey: "int") as? Int == 7)
        #expect(PreferenceCoding.int.decode(defaults.object(forKey: "int")) == 7)
        // Numbers read through NSNumber, as SyncedStorage reads them.
        #expect(PreferenceCoding.double.decode(defaults.object(forKey: "int")) == 7.0)

        defaults.set(Self.stored(0.25, .double), forKey: "double")
        #expect(defaults.object(forKey: "double") as? Double == 0.25)
        #expect(PreferenceCoding.double.decode(defaults.object(forKey: "double")) == 0.25)

        defaults.set(Self.stored(Float(1.5), .float), forKey: "float")
        #expect(PreferenceCoding.float.decode(defaults.object(forKey: "float")) == 1.5)

        defaults.set(Self.stored("alloy", .string), forKey: "string")
        #expect(defaults.string(forKey: "string") == "alloy")
        #expect(PreferenceCoding.string.decode(defaults.object(forKey: "string")) == "alloy")

        defaults.set(Self.stored(["a", "b"], .strings), forKey: "strings")
        #expect(defaults.stringArray(forKey: "strings") == ["a", "b"])
        #expect(PreferenceCoding.strings.decode(defaults.object(forKey: "strings")) == ["a", "b"])

        let bytes = Data([1, 2, 3])
        defaults.set(Self.stored(bytes, .data), forKey: "data")
        #expect(defaults.data(forKey: "data") == bytes)

        let moment = Date(timeIntervalSince1970: 1_700_000_000)
        defaults.set(Self.stored(moment, .date), forKey: "date")
        #expect(defaults.object(forKey: "date") as? Date == moment)

        defaults.set(Self.stored(["k": 1], .dictionary), forKey: "dictionary")
        #expect(PreferenceCoding.dictionary.decode(defaults.object(forKey: "dictionary"))?["k"] as? Int == 1)

        struct Pick: Codable, Equatable { let slug: String }
        let json = PreferenceCoding<Pick>.json()
        defaults.set(Self.stored(Pick(slug: "m"), json), forKey: "json")
        #expect(defaults.object(forKey: "json") is Data, "JSON is stored as Data")
        #expect(json.decode(defaults.object(forKey: "json")) == Pick(slug: "m"))

        enum Layout: String { case list, grid }
        let raw = PreferenceCoding<Layout>.raw()
        defaults.set(Self.stored(.grid, raw), forKey: "raw")
        #expect(defaults.string(forKey: "raw") == "grid")
        #expect(raw.decode(defaults.object(forKey: "raw")) == .grid)
        #expect(raw.decode("columns") == nil)
    }

    @Test("Absent or mistyped reads as nothing, and an optional set to nil is a removal")
    func codingsTreatAbsentAndMistypedAlike() {
        #expect(PreferenceCoding.bool.decode(nil) == nil)
        #expect(PreferenceCoding.bool.decode("yes") == nil)
        #expect(PreferenceCoding.string.decode(3) == nil)
        #expect(PreferenceCoding.strings.decode([1, 2]) == nil)

        let optional = PreferenceCoding<String?>.optional(.string)
        #expect(optional.decode(nil) == nil)
        #expect(optional.decode("x") == .some("x"))
        if case .absent = optional.encode(nil) {} else { Issue.record("nil is not stored") }
        if case let .value(object) = optional.encode("x") {
            #expect(object as? String == "x")
        } else {
            Issue.record("a value is stored")
        }
    }

    // MARK: - Families

    @Test("A family builds the stored key from its prefix and id, and reads the id back")
    func familiesRoundTrip() {
        let pins = Prefs.Families.pagePins
        #expect(pins.name("abc") == "page.pinned.abc")
        #expect(pins.id(from: "page.pinned.abc") == "abc")
        #expect(pins.id(from: "page.pinned.") == nil, "the bare prefix names no member")
        #expect(pins.id(from: "page.parent.abc") == nil)
        #expect(pins.key("abc").name == "page.pinned.abc")

        let host = Prefs.Families.openRouterHost
        #expect(host.name("chat|vendor/model") == "aiHost.chat|vendor/model")
        #expect(host.id(from: "aiHost.chat|vendor/model") == "chat|vendor/model")

        // A record-backed family's member is a record key; a plain one is not.
        #expect(Prefs.Families.notebookChatExcluded.key("n1").traits.contains(.record))
        #expect(!Prefs.Families.pagePins.key("p1").traits.contains(.record))

        for family in PreferenceRegistry.families {
            let name = family.prefix + "member-1"
            #expect(name.hasPrefix(family.prefix))
            switch family.scope {
            case let .account(traits):
                let live = traits.record.map(\.stillSyncsAsPreference) ?? true
                #expect(SyncedPreferenceKeys.isSynced(name) == live, "\(name)")
            case .device:
                #expect(!SyncedPreferenceKeys.isSynced(name), "\(name)")
            }
        }
    }

    @Test("A family's rows are read in one scan, by member")
    func familyRowsAreScannedByPrefix() throws {
        let suite = "PreferenceRegistryTests.rows.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("up", forKey: "readAloud.voiceRating.model|alloy")
        defaults.set("down", forKey: "readAloud.voiceRating.model|sage")
        defaults.set(3, forKey: "readAloud.voiceRating.model|mistyped")
        defaults.set("up", forKey: "readAloud.other")

        let rows = Prefs.Families.voiceRating.rows(in: defaults)
        #expect(rows == ["model|alloy": "up", "model|sage": "down"])
    }

    // MARK: - Access

    @Test("Bound storage takes every read and write, and the standard defaults are left alone")
    func boundStorageIsolatesAccess() throws {
        let suite = "PreferenceRegistryTests.access.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = Prefs.Rail.chatsExpanded          // an account key with a default of true
        let device = Prefs.Space.sidebarHidden          // a device key with a default of false
        let optional = Prefs.ReadAloud.groqVoice        // an account key with no default
        let standardBefore = UserDefaults.standard.object(forKey: account.name) as? NSObject

        Preferences.withStorage(defaults) {
            #expect(!Preferences.binding.isStandard)
            #expect(Preferences.value(account) == true, "absent reads as the key's default")
            #expect(Preferences.value(device) == false)
            #expect(Preferences.value(optional) == nil)
            #expect(!Preferences.isSet(account))

            Preferences.set(false, for: account)
            Preferences.set(true, for: device)
            Preferences.set("alloy", for: optional)
            #expect(Preferences.value(account) == false)
            #expect(Preferences.value(device) == true)
            #expect(Preferences.value(optional) == "alloy")
            #expect(Self.isBoolean(defaults.object(forKey: account.name)), "a Bool is stored as a Bool")

            Preferences.set(nil, for: optional)
            #expect(defaults.object(forKey: optional.name) == nil, "an optional key set to nil is cleared")
            Preferences.reset(account)
            #expect(Preferences.value(account) == true)

            defaults.set("not a flag", forKey: device.name)
            #expect(Preferences.value(device) == false, "a mistyped value reads as the default")
        }

        #expect(Preferences.binding.isStandard)
        let standardAfter = UserDefaults.standard.object(forKey: account.name) as? NSObject
        #expect(standardBefore == standardAfter, "a bound write never reaches the standard defaults")
    }

    @Test("A memo reads once, answers from memory, and persists after its lock is released")
    func memoReadsOnceAndPersists() throws {
        let suite = "PreferenceRegistryTests.memo.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = Prefs.Planner.planTheDayAskedOn
        defaults.set("2026-01-01", forKey: key.name)

        Preferences.withStorage(defaults) {
            let memo = PreferenceMemo(key)
            #expect(memo.value == "2026-01-01")
            defaults.set("2026-01-02", forKey: key.name)
            #expect(memo.value == "2026-01-01", "later reads come from memory")
            memo.reload()
            #expect(memo.value == "2026-01-02")
            memo.set("2026-01-03")
            #expect(memo.value == "2026-01-03")
            #expect(defaults.string(forKey: key.name) == "2026-01-03")
            memo.update { $0 = nil }
            #expect(memo.value == nil)
            #expect(defaults.object(forKey: key.name) == nil)
        }
    }

    // MARK: - No defaults under a lock

    @Test("The typed layer itself never touches defaults while holding a lock")
    func typedLayerKeepsDefaultsOutOfItsLocks() throws {
        let memo = try String(contentsOf: Self.preferencesDirectory.appendingPathComponent("PreferenceMemo.swift"), encoding: .utf8)
        var held = false
        var offenders: [String] = []
        for line in memo.components(separatedBy: "\n") {
            let code = line.trimmingCharacters(in: .whitespaces)
            if code.hasPrefix("//") { continue }
            if code.contains("lock.lock()") { held = true }
            if code.contains("lock.unlock()") { held = false; continue }
            // `defer { lock.unlock() }` holds to the end of the scope: nothing after it may reach defaults either.
            if held, code.contains("load()") || code.contains("persist(") || code.contains("Preferences.") || code.contains("UserDefaults") {
                offenders.append(code)
            }
        }
        #expect(offenders.isEmpty, "PreferenceMemo reaches defaults under its lock: \(offenders)")
    }
}

#endif
