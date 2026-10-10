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
/// The seed's P0 publishes the shards from its snapshot (WP16, through `MigrationBaseShards.partition`
/// and `encode`), and only the importer advances them (`MigrationBaseStore.advance`).
enum MigrationBaseShards {
    static let version = 1
    static let count = 64

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

/// `ZoneRoot.legacyImport` (§3.5.1): the late-import watermark, published with the base in P0 and advanced
/// only by the importer. `tokens` holds one change token per old zone as base64; `zones` names the zones
/// the import reads (none for a `knowledgeMissing` seed, whose base names no old zone, R7-m4).
struct MigrationImportWatermark: Equatable, Sendable {
    /// Days without an old-zone write before `finishedAt` is set (§13.6, §13.8).
    static let quietDays = 7
    static let hour: TimeInterval = 3_600
    static let day: TimeInterval = 86_400

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

    /// What a pass that fetched the old zones tells the watermark: whether any old record was written or
    /// deleted since the tokens. A write restarts the quiet period and clears `finishedAt` again; seven
    /// quiet days set it, which only enables "Remove old iCloud data" (§13.8). Polling goes on.
    mutating func recordPass(at now: Date, sawOldWrite: Bool) {
        let milliseconds = SyncTime.milliseconds(now)
        if sawOldWrite {
            lastOldWriteAt = milliseconds
            quietSince = milliseconds
            finishedAt = nil
        } else if quietSince == nil {
            quietSince = milliseconds
        }
        if finishedAt == nil, let quietSince, now.timeIntervalSince(SyncTime.date(milliseconds: quietSince)) >= Double(Self.quietDays) * Self.day {
            finishedAt = milliseconds
        }
    }

    /// How long the importer waits before it polls the old zones again: hourly until the learner removes
    /// the old data, daily once seven quiet days have passed, weekly after the removal (the check for a
    /// zone a stale build re-created).
    var pollInterval: TimeInterval {
        if removedAt != nil { return 7 * Self.day }
        return finishedAt == nil ? Self.hour : Self.day
    }

    /// An old write after `finishedAt` clears it; the same state after a removal restarts the import.
    var isQuiet: Bool { finishedAt != nil }
}

// MARK: - What reads and advances the base

/// What the importer's `advance` writes: the entries that changed (nil removes one) and the watermark.
struct MigrationBaseAdvance: Equatable, Sendable {
    var entries: [String: MigrationBaseEntry?] = [:]
    var watermark: MigrationImportWatermark
}

/// The shared base on the personal root. `RootMigrationBaseStore` is the Mac's; tests use an in-memory one.
protocol MigrationBaseStore: Sendable {
    /// The watermark on the root; nil when the root holds no base yet (nothing has been seeded).
    func watermark() async throws -> MigrationImportWatermark?
    /// One shard's entries by `<old zone>/<record name>`.
    func shard(_ name: String) async throws -> [String: MigrationBaseEntry]
    /// Writes the changed entries into their shards (bytes before pointers) and the watermark, in one
    /// compare-and-set save of the root. Returns false when the root changed meanwhile: nothing landed.
    func advance(_ update: MigrationBaseAdvance) async throws -> Bool
}

/// A pass's cache of the shards it reads, so a record's shard is fetched once.
actor MigrationBaseReader {
    private let store: any MigrationBaseStore
    private var shards: [String: [String: MigrationBaseEntry]] = [:]

    init(store: any MigrationBaseStore) {
        self.store = store
    }

    func entry(zone: String, recordName: String) async throws -> MigrationBaseEntry? {
        let name = MigrationBaseShards.name(forRecordName: recordName)
        return try await shard(name)[MigrationBaseShards.entryKey(zone: zone, recordName: recordName)]
    }

    /// Every entry of the base: the old records that wait, an expired token's diff, the guard's count.
    func all() async throws -> [String: MigrationBaseEntry] {
        var all: [String: MigrationBaseEntry] = [:]
        for name in MigrationBaseShards.allNames { all.merge(try await shard(name)) { first, _ in first } }
        return all
    }

    private func shard(_ name: String) async throws -> [String: MigrationBaseEntry] {
        if let cached = shards[name] { return cached }
        let loaded = try await store.shard(name)
        shards[name] = loaded
        return loaded
    }
}

/// What the seed manifest and the manifest deltas say about the new world (§13.5, §13.6): a record they
/// list was in it, so a record that is absent was deleted there. WP16's `SeedManifest` conforms.
protocol MigrationManifestLedger: Sendable {
    /// The records among `keys` that the manifest or a delta lists.
    func listed(_ keys: Set<MigrationRecordKey>) async throws -> Set<MigrationRecordKey>
    /// This pass's delta, under the key `<deviceID>.<passID>`, written once its creates are acknowledged.
    func writeDelta(key: String, records: [MigrationRecordKey]) async throws
    /// How many deltas the root holds.
    func deltaCount() async throws -> Int
    /// Folds the deltas and the manifest into a new `seed.manifest` and clears the folded keys in the same
    /// save. Only the importer folds, past 32 deltas.
    func fold() async throws
}

/// The importer folds the deltas into the manifest once the root holds more than this many.
let migrationManifestFoldAbove = 32

// MARK: - The root's implementation

/// The shared base on the personal root, read and advanced as `foldMoveMaps` folds `moveMaps`: shards are
/// satellites of the root fetched and uploaded by name, and the root's pointers and watermark move in one
/// compare-and-set save beside the engine.
struct RootMigrationBaseStore: MigrationBaseStore {
    static let owner = SyncSchema.rootRecordName

    let store: PrivateSyncLocalStore
    let blobs: BlobStore
    let writer: MaintenanceWriter
    /// The zone the root lives in (`Library`), and the one its shard satellites live in (`Content`).
    let library: @Sendable () async throws -> BlobZone
    let content: @Sendable () async throws -> BlobZone

    static func role(forShard name: String) -> String { "legacyBase.\(name)" }

    private func root() async throws -> SyncEnvelope? {
        try await store.perform { try $0.replica.personalRoot()?.envelope }
    }

    func watermark() async throws -> MigrationImportWatermark? {
        guard let root = try await root(), root.fields["legacyBase"]?.objectValue?.isEmpty == false else { return nil }
        return root.fields["legacyImport"].flatMap(MigrationImportWatermark.init(json:))
    }

    func shard(_ name: String) async throws -> [String: MigrationBaseEntry] {
        guard let pointer = try await root()?.fields["legacyBase"]?.objectValue?[name], let file = FileRef(json: pointer) else { return [:] }
        return try MigrationBaseShards.decode(try await blobs.fetch(file, from: try await content()))
    }

    func advance(_ update: MigrationBaseAdvance) async throws -> Bool {
        let zone = try await library()
        let satellites = try await content()
        var byShard: [String: [String: MigrationBaseEntry?]] = [:]
        for (key, entry) in update.entries {
            guard let record = MigrationBaseShards.recordName(ofEntryKey: key) else { continue }
            byShard[MigrationBaseShards.name(forRecordName: record), default: [:]][key] = entry
        }
        var pointers: [String: SyncJSON] = [:]
        for (name, changes) in byShard.sorted(by: { $0.key < $1.key }) {
            var entries = try await shard(name)
            for (key, entry) in changes { entries[key] = entry }
            let file = try await blobs.upload(
                MigrationBaseShards.encode(entries), owner: Self.owner, ownerType: .zoneRoot, role: Self.role(forShard: name),
                mime: "application/json", encoding: .gzip, into: satellites
            )
            pointers[name] = file.value
        }
        var changes: [String: RecordPatch.Change] = ["legacyImport": .value(update.watermark.json)]
        if !pointers.isEmpty { changes["legacyBase"] = .elements(pointers) }
        let patch = RecordPatch(.zoneRoot, id: SyncSchema.rootRecordName, changes: changes)
        let outcome = try await writer.save([MaintenanceWriter.Write(zone: zone, patch: patch)]).first
        return outcome == .saved || outcome == .unchanged
    }
}
