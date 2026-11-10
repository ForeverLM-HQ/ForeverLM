import CryptoKit
import Foundation

// MARK: - The shared base's shards (docs/cloudkit-schema-design.md §3.5.1, §13.6, WP16b)

/// `ZoneRoot.legacyBase`: per old record its change tag, its `waiting` flag and, for each v2 record the
/// §10 mapping gives it, the owner flag and the hash of each field, in 64 shards named `00` to `3f` by
/// the first byte of sha256(old record name) divided by 4. Each shard is the JSON below, stored as an
/// inline gzip satellite (`BlobStore.upload(..., encoding: .gzip)`, role `legacyBase.<shard>`, owner the
/// root):
///
///     {"v": 1, "e": {"<old zone>/<old record name>": {"c": changeTag, "w": waiting, "r": {"<Type>:<id>": {"o": owner, "h": {field: hash}}}}}}
///
/// The seed's P0 publishes the shards (WP16, through `MigrationBaseShards.partition` and `encode`). Nothing
/// advances them any more: the old container is no longer read.
enum MigrationBaseShards {
    static let version = 1
    static let count = 64

    /// The satellite role a shard is stored under on the root.
    static func role(forShard name: String) -> String { "legacyBase.\(name)" }

    /// The shard an old record belongs to: the first byte of sha256(record name) divided by 4, as two hex
    /// characters. The zone is not part of it, so a record keeps its shard whichever zone holds it.
    static func name(forRecordName recordName: String) -> String {
        let first = Array(SHA256.hash(data: Data(recordName.utf8))).first ?? 0
        return String(format: "%02x", Int(first) / 4)
    }

    /// Every shard name, `00` to `3f`.
    static let allNames: [String] = (0..<count).map { String(format: "%02x", $0) }

    /// The key an old record is kept under in a shard.
    static func entryKey(zone: String, recordName: String) -> String { "\(zone)/\(recordName)" }

    /// The record name of an entry key (an old zone name never holds a slash).
    static func recordName(ofEntryKey key: String) -> String? {
        key.firstIndex(of: "/").map { String(key[key.index(after: $0)...]) }
    }

    static func zone(ofEntryKey key: String) -> String? {
        key.firstIndex(of: "/").map { String(key[..<$0]) }
    }

    /// Entries split by shard; a shard with no entry is still there, empty, since the root names all 64.
    static func partition(_ entries: [String: MigrationBaseEntry]) -> [String: [String: MigrationBaseEntry]] {
        var shards = Dictionary(uniqueKeysWithValues: allNames.map { ($0, [String: MigrationBaseEntry]()) })
        for (key, entry) in entries {
            guard let record = recordName(ofEntryKey: key) else { continue }
            shards[name(forRecordName: record), default: [:]][key] = entry
        }
        return shards
    }

    /// The decoded bytes of one shard (the gzip is `BlobStore`'s). Keys are sorted, so two Macs that hold
    /// the same entries write the same bytes.
    static func encode(_ entries: [String: MigrationBaseEntry]) -> Data {
        var object: [String: SyncJSON] = [:]
        for (key, entry) in entries {
            object[key] = entry.jsonWithTag
        }
        return SyncJSON.object(["v": SyncJSON(version), "e": .object(object)]).serialized()
    }

    static func decode(_ data: Data) throws -> [String: MigrationBaseEntry] {
        let json = try SyncJSON(parsing: data)
        guard let entries = json["e"]?.objectValue else { return [:] }
        var decoded: [String: MigrationBaseEntry] = [:]
        for (key, value) in entries {
            if let entry = MigrationBaseEntry(json: value) { decoded[key] = entry }
        }
        return decoded
    }
}

// MARK: - The import watermark

/// `ZoneRoot.legacyImport` (§3.5.1): the watermark published with the base in P0. `tokens` holds one change
/// token per old zone as base64 and `zones` names the old zones the base covers; a seed names none, since
/// the old container is no longer read. The dates are what an earlier build's importer left on a root.
struct MigrationImportWatermark: Equatable, Sendable {
    var container: String?
    var zones: [String] = []
    var tokens: [String: String] = [:]
    var lastOldWriteAt: Int64?
    var quietSince: Int64?
    var finishedAt: Int64?
    var removedAt: Int64?

    init(container: String? = nil, zones: [String] = [], tokens: [String: String] = [:]) {
        self.container = container
        self.zones = zones
        self.tokens = tokens
    }

    init?(json: SyncJSON) {
        guard let object = json.objectValue else { return nil }
        container = object["container"]?.stringValue
        zones = (object["zones"]?.arrayValue ?? []).compactMap(\.stringValue)
        tokens = (object["tokens"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
        lastOldWriteAt = object["lastOldWriteAt"]?.int64Value
        quietSince = object["quietSince"]?.int64Value
        finishedAt = object["finishedAt"]?.int64Value
        removedAt = object["removedAt"]?.int64Value
    }

    var json: SyncJSON {
        var object: [String: SyncJSON] = [
            "zones": .array(zones.sorted().map(SyncJSON.string)),
            "tokens": .object(tokens.mapValues(SyncJSON.string)),
        ]
        if let container { object["container"] = .string(container) }
        if let lastOldWriteAt { object["lastOldWriteAt"] = SyncJSON(lastOldWriteAt) }
        if let quietSince { object["quietSince"] = SyncJSON(quietSince) }
        if let finishedAt { object["finishedAt"] = SyncJSON(finishedAt) }
        if let removedAt { object["removedAt"] = SyncJSON(removedAt) }
        return .object(object)
    }
}
