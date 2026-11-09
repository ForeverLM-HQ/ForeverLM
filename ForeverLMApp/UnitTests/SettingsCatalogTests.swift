import Foundation
import Testing
@testable import ForeverLM

#if os(macOS)

/// `schema/generated/settings-catalog.json` (docs/cloudkit-schema-design.md
/// §3.5.3) is what the hosted MCP and the web validate a Setting record by,
/// and how the hosted MCP knows which key a chat's `set_app_setting` writes.
/// It is generated from `schema/cloudkit-schema.json`, so it can only be right
/// if that file says what the Mac does: every key and prefix
/// `SyncedPreferenceKeys` syncs (the domain prefixes of §10 as `records`, which
/// are not Settings, and a Notebook Collection's name in `leftOut`, which only
/// its own writers set), the keys each `set_app_setting` entry writes with
/// their types and ranges, the tools that set the rest, and the AI tasks.
/// A failure here means the two disagree: change the `settings` section of
/// `schema/cloudkit-schema.json` and run `node scripts/schema/generate.mjs`.
@Suite("Settings catalog")
struct SettingsCatalogTests {

    /// Resolved from this file, as `MCPToolContractTests` resolves its catalogue.
    static var catalogURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UnitTests
            .deletingLastPathComponent()   // ForeverLMApp
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("schema/generated/settings-catalog.json")
    }

    /// Entries `appSettingsCatalog()` builds only for the stored text-to-speech
    /// provider, or only when there is a provider to choose
    /// (`MCPTools+VoiceSettings.swift`), so any one run sees some of them.
    static let providerDependentSettings: Set<String> = [
        "read_aloud.provider", "read_aloud.model", "read_aloud.voice", "read_aloud.apple_voice",
        "read_aloud.local_server_url", "read_aloud.local_model", "read_aloud.local_voice",
        "read_aloud.voice_rating",
    ]

    struct Catalog {
        let keys: [String: [String: Any]]
        let families: [String: [[String: Any]]]
        let records: [String: [String: Any]]
        /// Synced prefixes that stay Settings but stay out of the catalog: only
        /// their own writers set them, never `set_app_setting` (§3.5.3).
        let leftOut: [String: [String: Any]]
        let aiTaskIDs: [String]
        let aiTasksVersion: Int?

        /// Every exact key (by its key) and family pattern (by its pattern), for
        /// the checks that treat both alike.
        var rows: [(name: String, row: [String: Any], isKey: Bool)] {
            keys.map { ($0.key, $0.value, true) }
                + families.values.flatMap { patterns in patterns.map { ($0["pattern"] as? String ?? "?", $0, false) } }
        }

        /// The exact key, else the family pattern, that `key` falls under.
        func row(for key: String) -> [String: Any]? {
            if let row = keys[key] { return row }
            for (prefix, patterns) in families where key.hasPrefix(prefix) {
                if let row = patterns.first(where: { matches(key, $0) }) { return row }
            }
            return nil
        }

        /// A family pattern is literal text with `<name>` placeholders; one
        /// matches one or more characters, or one of `parts[name]`, where
        /// `aiTasks` means the AI task ids.
        func matches(_ key: String, _ row: [String: Any]) -> Bool {
            key.range(of: expression(for: row), options: .regularExpression) != nil
        }

        func expression(for row: [String: Any]) -> String {
            pieces(of: row).reduce("^") { expression, piece in
                switch piece {
                case let .literal(text): expression + NSRegularExpression.escapedPattern(for: text)
                case let .placeholder(values?): expression + "(" + values.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")"
                case .placeholder(nil): expression + "(.+)"
                }
            } + "$"
        }

        /// A key the pattern names: each placeholder filled with its first
        /// allowed value, or "x".
        func example(of row: [String: Any]) -> String {
            pieces(of: row).map { piece in
                switch piece {
                case let .literal(text): text
                case let .placeholder(values): values?.first ?? "x"
                }
            }.joined()
        }

        enum Piece {
            case literal(String)
            case placeholder([String]?)
        }

        func pieces(of row: [String: Any]) -> [Piece] {
            let parts = row["parts"] as? [String: Any] ?? [:]
            var pieces: [Piece] = []
            var rest = Substring(row["pattern"] as? String ?? "")
            while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
                pieces.append(.literal(String(rest[..<open])))
                let name = String(rest[rest.index(after: open)..<close])
                pieces.append(.placeholder((parts[name] as? String) == "aiTasks" ? aiTaskIDs : parts[name] as? [String]))
                rest = rest[rest.index(after: close)...]
            }
            pieces.append(.literal(String(rest)))
            return pieces
        }
    }

    static func loadCatalog() throws -> Catalog {
        let data = try Data(contentsOf: catalogURL)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let aiTasks = try #require(json["aiTasks"] as? [String: Any])
        return Catalog(
            keys: try #require(json["keys"] as? [String: [String: Any]]),
            families: try #require(json["families"] as? [String: [[String: Any]]]),
            records: try #require(json["records"] as? [String: [String: Any]]),
            leftOut: try #require(json["leftOut"] as? [String: [String: Any]]),
            aiTaskIDs: try #require(aiTasks["ids"] as? [String]),
            aiTasksVersion: (aiTasks["version"] as? NSNumber)?.intValue
        )
    }

    static func mcp(_ row: [String: Any]) -> [String: Any]? {
        row["mcp"] as? [String: Any]
    }

    static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    @Test("Every key and prefix SyncedPreferenceKeys syncs is in the catalog once or left out by name, and every catalog key syncs")
    func catalogMatchesSyncedPreferenceKeys() throws {
        let catalog = try Self.loadCatalog()
        let exactRecords = catalog.records.filter { $0.value["match"] as? String == "key" }.map(\.key)
        let prefixRecords = catalog.records.filter { $0.value["match"] as? String == "prefix" }.map(\.key)

        for key in SyncedPreferenceKeys.synced.union(SyncedPreferenceKeys.generation2OnlyKeys) {
            let entries = (catalog.keys[key] == nil ? 0 : 1) + (exactRecords.contains(key) ? 1 : 0)
            #expect(entries == 1, "\(key) is synced; the catalog lists it \(entries) times (keys or records)")
        }
        for prefix in SyncedPreferenceKeys.syncedPrefixes {
            let entries = (catalog.families[prefix] == nil ? 0 : 1) + (prefixRecords.contains(prefix) ? 1 : 0)
                + (catalog.leftOut[prefix] == nil ? 0 : 1)
            #expect(entries == 1, "\(prefix) is a synced prefix; the catalog lists it \(entries) times (families, records or leftOut)")
        }
        for (key, row) in catalog.keys {
            if row["origin"] as? String == "spec" {
                #expect(!SyncedPreferenceKeys.isSynced(key), "\(key) syncs now; drop its origin spec in the catalog")
            } else if SyncedPreferenceKeys.generation2OnlyKeys.contains(key) {
                #expect(SyncedPreferenceKeys.isSynced(key), "\(key) is in the catalog but does not sync")
            } else {
                #expect(SyncedPreferenceKeys.synced.contains(key) && SyncedPreferenceKeys.isSynced(key), "\(key) is in the catalog but does not sync")
            }
        }
        for (prefix, patterns) in catalog.families {
            for row in patterns {
                let example = catalog.example(of: row)
                #expect(catalog.matches(example, row), "\(example) does not match its own pattern")
                if row["origin"] as? String == "spec" {
                    #expect(!SyncedPreferenceKeys.isSynced(example), "\(example) syncs now; drop its pattern's origin spec")
                } else {
                    #expect(SyncedPreferenceKeys.syncedPrefixes.contains(prefix), "\(prefix) is a catalog family but not a synced prefix")
                    #expect(SyncedPreferenceKeys.isSynced(example), "\(example) falls under \(prefix) but does not sync")
                }
            }
        }
        for key in exactRecords {
            #expect(SyncedPreferenceKeys.synced.contains(key), "\(key) moves to a record but is not a synced key")
        }
        // A record the spec maps before every generation-1 build writes it
        // (origin spec) may or may not sync on this build.
        for prefix in prefixRecords where catalog.records[prefix]?["origin"] as? String != "spec" {
            #expect(SyncedPreferenceKeys.syncedPrefixes.contains(prefix), "\(prefix) moves to a record but is not a synced prefix")
        }
        for (prefix, row) in catalog.leftOut where prefix != NotebookCoverBackfillMarker.keyPrefix {
            let example = catalog.example(of: row)
            #expect(SyncedPreferenceKeys.syncedPrefixes.contains(prefix), "\(prefix) is left out of the catalog but is not a synced prefix")
            #expect(catalog.matches(example, row) && SyncedPreferenceKeys.isSynced(example), "\(example) is left out under \(prefix) but does not sync")
        }
    }

    @Test("The notebook cover Setting is a catalog key, and the cover backfill's marker is left out and never a preference")
    @MainActor
    func notebookCoverSettingAndMarker() async throws {
        let catalog = try Self.loadCatalog()
        let key = MacImageGenerationSettings.automaticForNewNotebooksKey
        let row = try #require(catalog.keys[key], "\(key) is not in the catalog's keys")
        #expect(row["type"] as? String == "bool")
        #expect(Self.mcp(row)?["setting"] as? String == "images.draw_notebook_covers")
        #expect(SyncedPreferenceKeys.isSetting(key) == SyncedPreferenceKeys.isSynced(key))

        let marker = try #require(catalog.leftOut[NotebookCoverBackfillMarker.keyPrefix], "the marker prefix is not under leftOut")
        #expect(marker["type"] as? String == "dict")
        #expect(marker["scope"] as? [String] == ["account"])
        let example = NotebookCoverBackfillMarker.key(zoneName: "Library")
        #expect(catalog.matches(example, marker))
        #expect(catalog.row(for: example) == nil, "the marker is no catalog key or family")
        // Only the backfill writes it, beside the engine: never a preference row, never a Setting
        // the Setting projection would bring into user_preferences.
        #expect(!SyncedPreferenceKeys.isSynced(example))
        #expect(!SyncedPreferenceKeys.isSetting(example))
        await #expect(throws: MCPError.self) {
            _ = try await MCPDataStore().setAppSetting(settingID: example, value: ["state": "done"])
        }
    }

    @Test("Every set_app_setting entry names the keys it writes, and its reach is whether they sync")
    @MainActor
    func entriesNameTheirKeys() {
        for entry in MCPDataStore.appSettingsCatalog() {
            #expect(!entry.preferenceKeys.isEmpty, "\(entry.id) names no preference key")
            for key in entry.preferenceKeys {
                #expect(
                    SyncedPreferenceKeys.isSynced(key) == (entry.reach == .account),
                    "\(entry.id) reaches \(entry.reach.rawValue), but \(key) \(SyncedPreferenceKeys.isSynced(key) ? "syncs" : "does not sync")"
                )
            }
        }
    }

    @Test("Each account setting of set_app_setting writes the catalog's keys, with the catalog's type and range")
    @MainActor
    func accountSettingsMatchTheCatalog() throws {
        let catalog = try Self.loadCatalog()
        let entries = MCPDataStore.appSettingsCatalog()
        for entry in entries {
            for key in entry.preferenceKeys {
                #expect(!catalog.leftOut.keys.contains { key.hasPrefix($0) }, "\(entry.id) writes \(key), which only its own writers set (the catalog leaves it out)")
            }
        }
        for entry in entries where entry.reach == .account {
            for key in entry.preferenceKeys {
                let row = try #require(catalog.row(for: key), "\(entry.id) writes \(key), which the catalog lacks")
                let mcp = Self.mcp(row)
                #expect(mcp?["tool"] as? String == "set_app_setting" && mcp?["setting"] as? String == entry.id,
                        "\(key) is written by set_app_setting \(entry.id), but the catalog routes it \(mcp ?? [:])")
                guard mcp?["derived"] as? Bool != true else { continue }
                let type = row["type"] as? String ?? "?"
                switch entry.kind {
                case .boolean:
                    #expect(type == "bool", "\(entry.id) is a switch, but \(key) is \(type)")
                case let .number(min, max, step):
                    #expect(type == "double" || type == "int", "\(entry.id) is a number, but \(key) is \(type)")
                    let range = row["range"] as? [String: Any]
                    #expect(Self.number(range?["min"]) == min && Self.number(range?["max"]) == max,
                            "\(entry.id) runs from \(min) to \(max); the catalog's \(key) says \(range ?? [:])")
                    #expect(Self.number(range?["step"]) == step, "\(entry.id) steps by \(step.map(String.init(describing:)) ?? "nothing"); the catalog's \(key) says \(range ?? [:])")
                case .choice, .text:
                    #expect(type == "string", "\(entry.id) takes a string, but \(key) is \(type)")
                case .stringList:
                    #expect(type == "array", "\(entry.id) takes a list, but \(key) is \(type)")
                }
            }
        }

        // The other way: every key the catalog says a setting writes is one it
        // names, and every setting the catalog names exists.
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        for (name, row, isKey) in catalog.rows {
            guard let mcp = Self.mcp(row), mcp["tool"] as? String == "set_app_setting", let id = mcp["setting"] as? String else { continue }
            guard let entry = byID[id] else {
                #expect(Self.providerDependentSettings.contains(id),
                        "the catalog routes \(name) to \(id), which set_app_setting does not have")
                continue
            }
            #expect(entry.reach == .account, "\(id) stays on this Mac, so it writes no Setting such as \(name)")
            if isKey {
                #expect(entry.preferenceKeys.contains(name), "the catalog says \(id) writes \(name); the entry does not name it")
            } else {
                #expect(entry.preferenceKeys.contains { catalog.matches($0, row) }, "the catalog says \(id) writes \(name); the entry names no such key")
            }
        }
    }

    /// The JSON Schema types a tool argument may have for a value of each
    /// Setting type it is stored as.
    static let argumentTypes: [String: Set<String>] = [
        "bool": ["boolean"], "int": ["integer"], "double": ["number", "integer"],
        "string": ["string"], "array": ["array"],
    ]

    @Test("Every other route the catalog names is a tool that takes the argument it names, of the key's type")
    func dedicatedRoutesExist() throws {
        let catalog = try Self.loadCatalog()
        let schemas = Dictionary(MCPToolRegistry(store: MCPDataStore()).tools.map { ($0.name, $0.inputSchema) }, uniquingKeysWith: { first, _ in first })
        for (name, row, _) in catalog.rows {
            guard let mcp = Self.mcp(row) else { continue }
            let tool = try #require(mcp["tool"] as? String, "\(name) has an mcp route without a tool")
            let properties = schemas[tool]?["properties"] as? [String: Any]
            #expect(schemas[tool] != nil, "the catalog routes \(name) to \(tool), which is not a tool")
            if let argument = mcp["argument"] as? String {
                let property = properties?[argument] as? [String: Any]
                #expect(property != nil, "\(tool) takes no argument \(argument), which the catalog names for \(name)")
                // An argument that is the stored value has the key's type; a
                // derived key is computed from its arguments.
                if let property, mcp["derived"] as? Bool != true, let type = row["type"] as? String {
                    let schemaType = property["type"] as? String ?? "?"
                    #expect(Self.argumentTypes[type]?.contains(schemaType) == true,
                            "\(name) holds \(type), but \(tool)'s \(argument) is \(schemaType)")
                }
            }
            if let target = mcp["target"] as? String {
                #expect(tool == "set_ai_task_settings" && MCPDataStore.aiTaskSettingsTargets.contains(target),
                        "\(name) is routed to \(tool) target \(target), which it does not have")
            }
        }
    }

    @Test("The AI tasks are AITaskSettingsCatalog's, in its order, and every AITask is one")
    func aiTasksMatch() throws {
        let catalog = try Self.loadCatalog()
        #expect(catalog.aiTaskIDs == AITaskSettingsCatalog.tasks.map(\.id))
        #expect(catalog.aiTasksVersion == AITaskSettingsCatalog.version)
        #expect(Set(AITask.allCases.map(\.rawValue)) == Set(catalog.aiTaskIDs), "aiTask.<task> keys are built from AITask raw values")
    }

    @Test("The ranges, values and slots the catalog gives are the ones the app keeps to")
    func rangesAndValuesMatch() throws {
        let catalog = try Self.loadCatalog()
        /// [min, max] as the catalog gives them.
        func range(_ key: String) -> [Double] {
            let range = catalog.keys[key]?["range"] as? [String: Any]
            return [range?["min"], range?["max"]].compactMap(Self.number)
        }
        #expect(range(MemoryReviewBudget.preferenceKey) == [Double(MemoryReviewBudget.minimumMinutes), Double(MemoryReviewBudget.maximumMinutes)])
        #expect(range(MemoryCardSettings.newCardsPerDayKey) == [Double(MemoryCardQueue.newPerDayRange.lowerBound), Double(MemoryCardQueue.newPerDayRange.upperBound)])
        #expect(range(PlannerDayHours.startKey) == [Double(PlannerDayHours.startHours.lowerBound), Double(PlannerDayHours.startHours.upperBound)])
        #expect(range(PlannerDayHours.endKey) == [Double(PlannerDayHours.endHours.lowerBound), Double(PlannerDayHours.endHours.upperBound)])
        #expect(range(BackgroundAIDailyCap.preferenceKey) == [0, BackgroundAIDailyCap.maximumUSD])

        #expect(catalog.keys[ApplePodcastDiscoveryScope.defaultsKey]?["values"] as? [String] == ApplePodcastDiscoveryScope.allCases.map(\.rawValue))
        #expect(catalog.keys[ThinkFirst.levelKey]?["values"] as? [String] == ThinkFirstLevel.allCases.map(\.rawValue))
        let thinkFirst = try #require(catalog.families[ThinkFirst.notebookKeyPrefix]?.first)
        #expect(thinkFirst["values"] as? [String] == ThinkFirstLevel.allCases.map(\.rawValue))
        #expect(Self.mcp(thinkFirst)?["tool"] as? String == "update_notebook" && Self.mcp(thinkFirst)?["argument"] as? String == "think_first")
        let depth = try #require(catalog.families[MemoryReviewDepth.typePreferenceKeyPrefix]?.first)
        #expect(depth["values"] as? [String] == MemoryReviewDepth.allCases.map(\.rawValue))
        let rating = try #require(catalog.families[ArticleSpeechVoiceRating.preferencePrefix]?.first)
        #expect(rating["values"] as? [String] == [ArticleSpeechVoiceRating.up.rawValue, ArticleSpeechVoiceRating.down.rawValue])
        for prefix in [OpenRouterHostPreference.keyPrefix, AIBackupModels.keyPrefix] {
            let live = try #require(catalog.families[prefix]?.first)
            #expect((live["parts"] as? [String: Any])?["slot"] as? [String] == OpenRouterHostPreference.sharedSlots, "\(prefix) slots")
        }
    }
}

#endif
