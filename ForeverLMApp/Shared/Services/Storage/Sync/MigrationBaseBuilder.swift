import Foundation

// MARK: - The seed's P0: this Mac's snapshot as the shared base (docs/cloudkit-schema-design.md §13.4 P0, §13.6)

/// Builds the root's shared base from the snapshot this Mac's catch-up kept (`ck_legacy_snapshot`, and the
/// walk's change tokens in `ck_engine_state`): per old record its change tag and, from `LegacyV2Mapping`, the
/// `waiting` flag and the owner flag and field hashes of each v2 record it gives. The shards and their
/// bytes are `MigrationBaseShards`'; from the seed's save on only the importer advances them
/// (`RootMigrationBaseStore.advance`). A `knowledgeMissing` store, and the rehearsal override, publish a
/// base that names no old zone (R7-m4): nothing of another library is ever read for it.
enum MigrationBaseBuilder {
    /// The root's field names (`legacyBase`, `legacyImport`) are the schema's wire names, which clients
    /// already read; nothing here renames them.
    enum Wire {
        static let baseField = "legacyBase"
        static let importField = "legacyImport"
    }

    /// Everything P0 publishes: the entries by `<old zone>/<record name>`, the zones the base names and each
    /// zone's change token.
    struct Built: Equatable, Sendable {
        var entries: [String: MigrationBaseEntry]
        var zones: [String]
        var tokens: [String: Data]
    }

    static func build(from connection: SQLiteConnection, knowledgeMissing: Bool) throws -> Built {
        guard !knowledgeMissing else { return Built(entries: [:], zones: [], tokens: [:]) }
        var entries: [String: MigrationBaseEntry] = [:]
        var zones = Set<String>()
        try connection.query("SELECT old_zone, record_name, change_tag, field_hashes FROM ck_legacy_snapshot", []) { row in
            let zone = row.text(0) ?? ""
            let name = row.text(1) ?? ""
            let hashes = (try? SyncJSON(parsing: Data((row.text(3) ?? "{}").utf8))) ?? .object([:])
            if let entry = MigrationBaseEntry(json: hashes, changeTag: row.text(2)) {
                entries[MigrationBaseShards.entryKey(zone: zone, recordName: name)] = entry
            }
            zones.insert(zone)
        }
        // A zone the walk covered but found empty still belongs to the base: it has a token.
        try connection.query("SELECT scope FROM ck_engine_state WHERE scope LIKE 'migration.token.%'", []) { row in
            if let scope = row.text(0) { zones.insert(zoneName(ofTokenScope: scope)) }
        }
        var tokens: [String: Data] = [:]
        let replica = ReplicaStore(connection: connection)
        for zone in zones {
            if let data = try replica.engineState(tokenScope(zone: zone)) { tokens[zone] = data }
        }
        return Built(entries: entries, zones: zones.sorted(), tokens: tokens)
    }

    /// `ck_engine_state.scope` of a zone's token (`OldContainerZoneKey.stateKey`): a private zone is
    /// `migration.token.private.<zone>`, a team zone another account owns `migration.token.shared.<zone>@<owner>`.
    static func tokenScope(zone: String) -> String {
        "migration.token.\(zone.contains("@") ? "shared" : "private").\(zone)"
    }

    static func zoneName(ofTokenScope scope: String) -> String {
        let parts = scope.split(separator: ".", maxSplits: 3, omittingEmptySubsequences: false)
        return parts.count == 4 ? String(parts[3]) : scope
    }

    /// The root's `legacyImport` value for a new base (§3.5.1): the watermark the importer advances.
    static func watermark(container: String?, built: Built) -> MigrationImportWatermark {
        MigrationImportWatermark(container: container, zones: built.zones, tokens: built.tokens.mapValues { $0.base64EncodedString() })
    }
}

enum MigrationBaseError: Error, Equatable {
    /// A shard does not fit inline: its stored bytes, the gzip `BlobStore` keeps, are over 256 KiB. The seed
    /// stops at P0 with this cause shown (§13.4 step 2, P0). `bytes` is the gzip's size.
    case shardTooLarge(shard: String, bytes: Int)
    case noRoot
}

/// Uploads the shards as inline satellites of the personal root and names them in a root patch.
struct MigrationBaseWriter {
    let store: PrivateSyncLocalStore
    let blobs: BlobStore

    /// The root patch that names the shards (`legacyBase`, shard to FileRef) and the watermark, once every
    /// shard is acknowledged. The caller saves it with the claim holder's other root fields, so the base and
    /// the tokens appear in one save (§13.4 P0).
    func upload(_ built: MigrationBaseBuilder.Built, container: String?) async throws -> [String: RecordPatch.Change] {
        let shards = MigrationBaseShards.partition(built.entries).mapValues(MigrationBaseShards.encode)
        // The limit is on what is stored, the gzip, as `BlobStore` decides inline: a shard's JSON is mostly
        // repeated keys and runs four to five times its gzip (the product owner's 17,157 old records gave shards of up
        // to 340 KB that store in 72 KB, and the decoded size stopped his seed at P0 on every round).
        for (shard, body) in shards {
            let stored = try SyncGzip.compress(body).count
            if stored > SyncSchema.Limits.inlineSatelliteMaxBytes { throw MigrationBaseError.shardTooLarge(shard: shard, bytes: stored) }
        }
        guard let content = try await store.perform({ try BlobZone.resolve(zoneKey: PrivateSyncZones.key(PrivateSyncZones.content), in: $0) })
        else { throw MigrationBaseError.noRoot }
        var files: [String: SyncJSON] = [:]
        for shard in MigrationBaseShards.allNames {
            let file = try await blobs.upload(
                shards[shard] ?? MigrationBaseShards.encode([:]), owner: SyncSchema.rootRecordName, ownerType: .zoneRoot,
                role: MigrationBaseShards.role(forShard: shard), mime: "application/json", encoding: .gzip, into: content
            )
            files[shard] = file.value
        }
        return [
            MigrationBaseBuilder.Wire.baseField: .elements(files),
            MigrationBaseBuilder.Wire.importField: .value(MigrationBaseBuilder.watermark(container: container, built: built).json),
        ]
    }
}
