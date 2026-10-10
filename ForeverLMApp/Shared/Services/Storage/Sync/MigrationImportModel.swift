import Foundation

// MARK: - What an import pass reads and writes (docs/cloudkit-schema-design.md §13.6, WP16b)

/// One v2 record an old record gives or lists: the personal library's, or a space's (a `Team-*` zone's).
struct MigrationRecordKey: Hashable, Sendable {
    let type: SyncRecordType
    let id: String
    let spaceID: String?

    init(_ type: SyncRecordType, _ id: String, spaceID: String? = nil) {
        self.type = type
        self.id = id
        self.spaceID = spaceID
    }

    /// The key a base entry lists the record under (`LegacyV2Record.key`).
    var baseKey: String { "\(type.rawValue):\(id)" }

    /// The record a base key names, in the space of the old zone it came from.
    init?(baseKey: String, spaceID: String?) {
        guard let colon = baseKey.firstIndex(of: ":"), let type = SyncRecordType(rawValue: String(baseKey[..<colon])) else { return nil }
        self.init(type, String(baseKey[baseKey.index(after: colon)...]), spaceID: spaceID)
    }
}

// MARK: - The base, per old record

/// What the shared base (or a Mac's own snapshot) keeps of one v2 record an old record gave: whether the
/// old record owns it, and the hash of each field (a set or map field per element, `<field>/<element>`).
struct MigrationBaseRecord: Equatable, Sendable {
    var owned: Bool
    var hashes: [String: String]
}

/// One old record's entry in the base: its change tag, its `waiting` flag and, per v2 record its mapping
/// gave, `MigrationBaseRecord`. The JSON form is `LegacyMapping.baseEntry`'s `{w, r}`.
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

    /// `json` with the change tag (`c`), as a shard and the importer's journal keep it.
    var jsonWithTag: SyncJSON {
        guard case .object(var object) = json else { return json }
        if let changeTag { object["c"] = .string(changeTag) }
        return .object(object)
    }

    /// The entry for what a mapping gives (a `clears` record is listed with its hashes, never owned, so a later
    /// pass applies it only when the old record's state changed, F2).
    init(mapping: LegacyMapping, changeTag: String?, waiting: Bool = false) {
        var records: [String: MigrationBaseRecord] = [:]
        for record in mapping.records {
            records[record.key] = MigrationBaseRecord(owned: record.owned, hashes: LegacyFieldHashes.hashes(record))
        }
        self.init(changeTag: changeTag, waiting: waiting, records: records)
    }
}

// MARK: - One old record, as a pass sees it

/// An old record a pass met: changed since the base, found again by name because it waits, or deleted.
struct MigrationOldRecord: Sendable {
    /// The old zone as the base and the snapshot name it (`Knowledge`, `Team-<id>`), and the record's name.
    var zone: String
    var name: String
    var changeTag: String?
    /// The server's modification date: every field the record gives is stamped with it (§13.6).
    var modifiedAt: Date
    var mapping: LegacyMapping?
    /// What a deleted old record gives as it goes, read from what the base listed of it: the ids a deleted
    /// `notebook.collections.*`, `notebook.chatExcluded.*` or `notebook.chatContextNotebooks.*` row listed leave
    /// their set, and a deleted `course.focus.*` row clears its focus (F8).
    var deletionRecords: [LegacyV2Record] = []
    /// The space a `Team-*` zone's records live in; nil for the learner's own `Knowledge` zone.
    var spaceID: String?
    /// The old record is gone: every owned record it gave is a removal candidate.
    var isDeleted: Bool { mapping == nil }

    /// The key a pass uses for the record's bookkeeping (waiting since, the base).
    var id: String { "\(zone)/\(name)" }
}

struct MigrationOldRecordInput: Sendable {
    let old: MigrationOldRecord
    /// What the base holds of it; nil for an old record the base never met.
    let base: MigrationBaseEntry?
}

// MARK: - The world a pass reads

/// A record as this Mac holds it: the server's copy with this Mac's own pending patch laid over it, and
/// what its body pointer is on each side.
struct MigrationHeldRecord: Sendable {
    var merged: SyncEnvelope
    /// Whether the server's copy is in the replica. A record this Mac's earlier pass created and has not
    /// had acknowledged is held without one.
    var inReplica: Bool
    /// The hash of the FileRef in `body` as the server's copy holds it.
    var replicaBodyHash: String?
    /// The hash of a `body` the pending patch carries.
    var pendingBodyHash: String?
}

/// What a pass asks about the new world. The Mac's implementation is a snapshot read before the pass
/// plans, since the store is reached through the storage actor (`MigrationWorldSnapshot`).
protocol MigrationWorld {
    func held(_ key: MigrationRecordKey) -> MigrationHeldRecord?
    /// Whether the seed manifest or a manifest delta lists the record: it was in the new world, so an
    /// absent one was deleted there (§13.5).
    func isListed(_ key: MigrationRecordKey) -> Bool
    /// Whether this Mac holds the record's rows without the server's copy or a pending patch (a Mac whose
    /// activation derived it and whose reconcile has not uploaded it yet): its catch-up already brought it
    /// the old world's changes, and a patch of fields alone would be sent as a record that lacks the rest.
    func isLocalOnly(_ key: MigrationRecordKey) -> Bool
    /// Whether this Mac holds the space a `Team-*` zone's records belong in and may write to it: its own, or a
    /// joined one on a roster that says read-write.
    func holdsSpace(_ spaceID: String) -> Bool
    /// Whether this Mac holds an edit of the record's body it has not sent: a change to the body itself,
    /// never a rename or a filing (§13.6).
    func ownBodyEdit(_ key: MigrationRecordKey) -> Bool
    /// Whether the record has a change of this Mac's own that is not sent (a `ck_outbox` row): every record
    /// this Mac made since its activation has one, and an old removal does not take it (§13.3, R5-4).
    func hasLocalChange(_ key: MigrationRecordKey) -> Bool
}

extension MigrationWorld {
    func hasLocalChange(_ key: MigrationRecordKey) -> Bool { false }
}

/// The world a pass planned against, read once.
struct MigrationWorldSnapshot: MigrationWorld, Sendable {
    var records: [MigrationRecordKey: MigrationHeldRecord] = [:]
    var listed: Set<MigrationRecordKey> = []
    var spaces: Set<String> = []
    var ownEdits: Set<MigrationRecordKey> = []
    var localOnly: Set<MigrationRecordKey> = []
    var localChanges: Set<MigrationRecordKey> = []

    func held(_ key: MigrationRecordKey) -> MigrationHeldRecord? { records[key] }
    func isListed(_ key: MigrationRecordKey) -> Bool { listed.contains(key) }
    func isLocalOnly(_ key: MigrationRecordKey) -> Bool { localOnly.contains(key) }
    func holdsSpace(_ spaceID: String) -> Bool { spaces.contains(spaceID) }
    func ownBodyEdit(_ key: MigrationRecordKey) -> Bool { ownEdits.contains(key) }
    func hasLocalChange(_ key: MigrationRecordKey) -> Bool { localChanges.contains(key) }
}

// MARK: - What a pass writes

/// Where the bytes of a `body` the pass writes come from: the old record's own package or notes.
enum MigrationBodySource: Equatable, Sendable {
    /// A Doc's body package (`LegacyRecord.bodyPackage`), uploaded as it is.
    case docPackage(oldRecord: String)
    /// A notebook's notes, as the Notes Doc encodes their text.
    case notes(oldRecord: String)
}

/// The changes to one v2 record: created whole, or patched field by field, each with its stamp.
struct MigrationWrite: Equatable, Sendable {
    let key: MigrationRecordKey
    /// The record does not exist yet: every field the old record gives, none only the changed ones.
    var creates: Bool
    var changes: [String: RecordPatch.Change] = [:]
    var stamps: [StampedPath: SyncStamp] = [:]
    /// A `body` among the changes needs these bytes uploaded before its pointer (D10).
    var bodySource: MigrationBodySource?
    /// For a Recovered Doc, whose satellites are named for the new record: its title and notebook come
    /// from the old record's mapping, its body from the old package.
    var isRecoveredDoc = false
    /// The write is an old record's removal of an owned record: an Entry's or a Placement's `state` flipped to
    /// `removed`, a Setting's `value` cleared. A record only this Mac's rows hold is then left by its rows
    /// alone, with nothing queued for a server that never held it (§13.3).
    var removes = false

    var isEmpty: Bool { changes.isEmpty && !creates }
}

/// A record removed because the old record that owned it went (§13.6): flipped by type, or deleted.
struct MigrationRemoval: Equatable, Sendable {
    let key: MigrationRecordKey
    /// Entry and Placement flip `state` to `removed`, a Setting clears its `value`; any other type is
    /// deleted. A flip is a patch in the record's `MigrationWrite`; only a deletion is this removal's.
    let deletes: Bool
}

/// Why an old record's value or removal was not applied, for the log and Settings (§13.6).
struct MigrationLogEntry: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable {
        /// The record was deleted in the new world: the delete wins.
        case deletedInNewWorld
        /// The record it hangs from was deleted in the new world.
        case parentDeletedInNewWorld
        /// An old build removed something late import never removes: per-member state and history, or a
        /// record only fed.
        case neverRemoved
        /// The new world edited the record after T0, so an old removal does not take it.
        case editedInNewWorld
        /// The old record gave it without owning it, and an old build stopped giving it.
        case notOwned
        /// The learner answered Keep to a tripped 5% guard.
        case keptByAnswer
        /// A value waited 30 days for a record that never came.
        case waitedTooLong
        /// The old Team's space is not on this Mac.
        case spaceMissing
    }

    var oldRecord: String
    var type: String
    var id: String
    var reason: Reason
    var at: Date
}

/// An old record's result in a pass.
struct MigrationOldRecordPlan: Equatable, Sendable {
    let oldRecord: String
    /// What the base keeps of it next; nil when the old record is gone.
    var nextEntry: MigrationBaseEntry?
    /// Some value of it still waits for a record that does not exist yet.
    var waiting = false
    /// The keys that wait, by `<Type>:<id>`.
    var waitingKeys: Set<String> = []
    var removals = 0
    var skipped: [MigrationLogEntry] = []
    var kept: [MigrationLogEntry] = []
    var notApplied: [MigrationLogEntry] = []
}

struct MigrationPassPlan: Equatable, Sendable {
    var olds: [MigrationOldRecordPlan] = []
    /// Creates and patches, creates first, one entry per record (two old records' values for one record
    /// are folded field by field by stamp).
    var writes: [MigrationWrite] = []
    var deletions: [MigrationRemoval] = []

    var removals: Int { olds.reduce(0) { $0 + $1.removals } }
    var kept: [MigrationLogEntry] { olds.flatMap(\.kept) }
    var skipped: [MigrationLogEntry] { olds.flatMap(\.skipped) }
    var notApplied: [MigrationLogEntry] { olds.flatMap(\.notApplied) }
    var creates: [MigrationRecordKey] { writes.filter(\.creates).map(\.key) }
}
