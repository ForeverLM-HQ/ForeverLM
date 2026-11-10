import Foundation

// MARK: - What the shared base holds (docs/cloudkit-schema-design.md §13.6, WP16b)

/// What the shared base (or a Mac's own snapshot) keeps of one v2 record an old record gave: whether the
/// old record owns it, and the hash of each field (a set or map field per element, `<field>/<element>`).
struct MigrationBaseRecord: Equatable, Sendable {
    var owned: Bool
    var hashes: [String: String]
}

/// One old record's entry in the base: its change tag, its `waiting` flag and, per v2 record its mapping
/// gave, `MigrationBaseRecord`. The JSON form is `{w, r}`.
struct MigrationBaseEntry: Equatable, Sendable {
    var changeTag: String?
    var waiting: Bool
    var records: [String: MigrationBaseRecord]

    init(changeTag: String? = nil, waiting: Bool = false, records: [String: MigrationBaseRecord] = [:]) {
        self.changeTag = changeTag
        self.waiting = waiting
        self.records = records
    }

    init?(json: SyncJSON, changeTag: String? = nil) {
        guard let object = json.objectValue else { return nil }
        var records: [String: MigrationBaseRecord] = [:]
        for (key, value) in object["r"]?.objectValue ?? [:] {
            guard let entry = value.objectValue else { continue }
            var hashes: [String: String] = [:]
            for (field, hash) in entry["h"]?.objectValue ?? [:] {
                if let text = hash.stringValue { hashes[field] = text }
            }
            records[key] = MigrationBaseRecord(owned: entry["o"]?.boolValue ?? false, hashes: hashes)
        }
        self.init(changeTag: changeTag ?? object["c"]?.stringValue, waiting: object["w"]?.boolValue ?? false, records: records)
    }

    /// `{w, r: {"<Type>:<id>": {o, h: {field: hash}}}}`, the bytes two Macs mapping one old record agree on.
    var json: SyncJSON {
        .object([
            "w": .bool(waiting),
            "r": .object(records.mapValues { record in
                .object(["o": .bool(record.owned), "h": .object(record.hashes.mapValues(SyncJSON.string))])
            }),
        ])
    }

    /// `json` with the change tag (`c`), as a shard keeps it.
    var jsonWithTag: SyncJSON {
        guard case .object(var object) = json else { return json }
        if let changeTag { object["c"] = .string(changeTag) }
        return .object(object)
    }
}
