import CryptoKit
import Foundation

// MARK: - The move journal (docs/cloudkit-schema-design.md §4.4, §5.3, D51)

/// What one move job carries (`ck_move_jobs.kind`).
enum SpaceMoveKind: String, Sendable {
    /// A notebook into a space its owner owns (§5.3).
    case notebook
    /// A Doc into its Doc space (§9.1, D5).
    case doc
    /// A notebook back to My Library (§5.2 "Move back to My Library").
    case notebookBack
    /// A Doc back from its Doc space.
    case docBack
    /// Late children and grandchildren that landed where a move had taken what they name (§4.4).
    case rehome
}

/// How far a job got. A notebook job writes `movingTo` (`marked`), copies until a catch-up pass finds
/// nothing new (`copied`), turns the original into its stub (`stubbed`), then lists and deletes.
enum SpaceMoveJobState: String, Sendable {
    case started
    case marked
    case copied
    case stubbed
    case done
}

/// How far one record got. A moved record is `queued`, `copied` once its copy is acknowledged,
/// `listed` once a `moveMaps` entry names it, and `deleted` once its original is gone; a record that
/// stays where it is (a private chat, whole, §9.2) is `kept`. A copy (a Source or a Collection, which
/// the library keeps) ends `done` and is never listed or deleted.
enum SpaceMoveItemState: String, Sendable {
    case queued
    case copied
    case listed
    case deleted
    case kept
    case done
}

/// One `ck_move_jobs` row. Zones are replica zone keys (`private/Library`, `private/Space-<id>`).
struct SpaceMoveJobRow: Equatable, Sendable {
    let id: String
    let kind: SpaceMoveKind
    let recordType: SyncRecordType
    let wireID: String
    let fromZone: String
    let toZone: String
    var state: SpaceMoveJobState
    /// The `moveMaps` entries the job has written; the next one's key is `<id>.<pass>`.
    var pass: Int
}

/// One `ck_move_items` row.
struct SpaceMoveItem: Hashable, Sendable {
    let type: SyncRecordType
    let wireID: String
    let fromZone: String
    let toZone: String
    var state: SpaceMoveItemState

    /// Sources and their Collections are copied into the target and stay where they were (§5.3 step
    /// 4, §5.2 "Move back": the personal library keeps its own sources).
    var isCopy: Bool { Self.copiedTypes.contains(type) }

    static let copiedTypes: Set<SyncRecordType> = [.source, .collection]

    var key: SpaceMoveRecordKey { SpaceMoveRecordKey(type: type, wireID: wireID) }
}

struct SpaceMoveRecordKey: Hashable, Sendable {
    let type: SyncRecordType
    let wireID: String
}

/// `ck_move_jobs` and `ck_move_items` (schema 154): the journal that lets a move resume at its last
/// unacknowledged item after a crash, and the only licence to delete an original (§5.3 "Crash safety").
enum SpaceMoveJournal {
    static func job(_ id: String, _ connection: SQLiteConnection) throws -> SpaceMoveJobRow? {
        try jobs(where: "id = ?", [.text(id)], connection).first
    }

    /// Jobs not done yet, oldest first.
    static func unfinished(_ connection: SQLiteConnection) throws -> [SpaceMoveJobRow] {
        try jobs(where: "state <> ?", [.text(SpaceMoveJobState.done.rawValue)], connection)
    }

    /// Every job, done or not, that moves `wireID` of `type`.
    static func jobs(moving type: SyncRecordType, _ wireID: String, _ connection: SQLiteConnection) throws -> [SpaceMoveJobRow] {
        try jobs(where: "record_type = ? AND wire_id = ?", [.text(type.rawValue), .text(wireID)], connection)
    }

    private static func jobs(where condition: String, _ parameters: [SQLiteValue], _ connection: SQLiteConnection) throws -> [SpaceMoveJobRow] {
        var found: [SpaceMoveJobRow] = []
        try connection.query("""
            SELECT id, kind, record_type, wire_id, from_zone, to_zone, state, pass FROM ck_move_jobs
            WHERE \(condition) ORDER BY created_at, id
        """, parameters) { row in
            guard let id = row.text(0), let kind = row.text(1).flatMap(SpaceMoveKind.init(rawValue:)),
                  let type = row.text(2).flatMap(SyncRecordType.init(rawValue:)), let state = row.text(6).flatMap(SpaceMoveJobState.init(rawValue:))
            else { return }
            found.append(SpaceMoveJobRow(id: id, kind: kind, recordType: type, wireID: row.text(3) ?? "", fromZone: row.text(4) ?? "",
                                         toZone: row.text(5) ?? "", state: state, pass: Int(row.integer(7) ?? 0)))
        }
        return found
    }

    /// Writes a job that is not in the journal yet; one already there stays as it is (a resumed request).
    static func begin(_ job: SpaceMoveJobRow, now: Date, _ connection: SQLiteConnection) throws {
        try connection.execute("""
            INSERT INTO ck_move_jobs (id, kind, record_type, wire_id, from_zone, to_zone, state, pass, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING
        """, [
            .text(job.id), .text(job.kind.rawValue), .text(job.recordType.rawValue), .text(job.wireID), .text(job.fromZone),
            .text(job.toZone), .text(job.state.rawValue), .integer(Int64(job.pass)), .real(now.timeIntervalSinceReferenceDate),
            .real(now.timeIntervalSinceReferenceDate),
        ])
    }

    static func save(_ job: SpaceMoveJobRow, now: Date, error: String? = nil, _ connection: SQLiteConnection) throws {
        try connection.execute(
            "UPDATE ck_move_jobs SET state = ?, pass = ?, updated_at = ?, last_error = ? WHERE id = ?",
            [.text(job.state.rawValue), .integer(Int64(job.pass)), .real(now.timeIntervalSinceReferenceDate), .text(error), .text(job.id)]
        )
    }

    static func items(_ jobID: String, _ connection: SQLiteConnection) throws -> [SpaceMoveItem] {
        var found: [SpaceMoveItem] = []
        try connection.query(
            "SELECT record_type, wire_id, from_zone, to_zone, state FROM ck_move_items WHERE job_id = ? ORDER BY record_type, wire_id",
            [.text(jobID)]
        ) { row in
            guard let type = row.text(0).flatMap(SyncRecordType.init(rawValue:)), let state = row.text(4).flatMap(SpaceMoveItemState.init(rawValue:)) else { return }
            found.append(SpaceMoveItem(type: type, wireID: row.text(1) ?? "", fromZone: row.text(2) ?? "", toZone: row.text(3) ?? "", state: state))
        }
        return found
    }

    /// Adds the items the job does not list yet; returns how many were new.
    @discardableResult
    static func add(_ items: [SpaceMoveItem], jobID: String, now: Date, _ connection: SQLiteConnection) throws -> Int {
        var added = 0
        for item in items {
            try connection.execute("""
                INSERT INTO ck_move_items (job_id, record_type, wire_id, from_zone, to_zone, state, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(job_id, record_type, wire_id) DO NOTHING
            """, [
                .text(jobID), .text(item.type.rawValue), .text(item.wireID), .text(item.fromZone), .text(item.toZone), .text(item.state.rawValue),
                .real(now.timeIntervalSinceReferenceDate),
            ])
            added += connection.changedRowCount
        }
        return added
    }

    static func set(_ state: SpaceMoveItemState, _ items: [SpaceMoveRecordKey], jobID: String, changeTags: [SpaceMoveRecordKey: String] = [:],
                    now: Date, _ connection: SQLiteConnection) throws {
        for item in items {
            try connection.execute("""
                UPDATE ck_move_items SET state = ?, copy_change_tag = COALESCE(?, copy_change_tag), updated_at = ?
                WHERE job_id = ? AND record_type = ? AND wire_id = ?
            """, [
                .text(state.rawValue), .text(changeTags[item]), .real(now.timeIntervalSinceReferenceDate), .text(jobID), .text(item.type.rawValue),
                .text(item.wireID),
            ])
        }
    }
}

// MARK: - What a move carries (§5.3 steps 3 and 4)

/// A record as one zone of the replica holds it.
struct SpaceMoveHeld: Sendable {
    let type: SyncRecordType
    let wireID: String
    let envelope: SyncEnvelope
    let recordName: String

    var key: SpaceMoveRecordKey { SpaceMoveRecordKey(type: type, wireID: wireID) }
    var fields: [String: SyncJSON] { envelope.fields }
}

/// Finds a move's records in the replica, which is the server as this Mac last fetched it: a notebook's
/// children by their back-pointers (an Entry's container, a chat's, a Doc's and a task's `notebookID`,
/// the Notes Doc `notes:<id>`), their grandchildren (Exchanges of the chats, Comments of the Docs), and
/// the Sources the notebook's live Entries name (§5.3).
enum SpaceMoveScan {
    static let copyOrder: [SyncRecordType] = [.notebook, .collection, .source, .entry, .artifact, .chat, .exchange, .comment, .task]

    static func held(in zoneKey: String, types: [SyncRecordType], _ connection: SQLiteConnection) throws -> [SpaceMoveHeld] {
        var found: [SpaceMoveHeld] = []
        let marks = types.map { _ in "?" }.joined(separator: ", ")
        try connection.query(
            "SELECT record_type, wire_id, record_name, payload FROM ck_records WHERE zone_key = ? AND record_type IN (\(marks)) ORDER BY record_type, wire_id",
            [.text(zoneKey)] + types.map { .text($0.rawValue) }
        ) { row in
            guard let type = row.text(0).flatMap(SyncRecordType.init(rawValue:)), let payload = row.blob(3),
                  let envelope = try? SyncEnvelope(storedPayload: payload)
            else { return }
            found.append(SpaceMoveHeld(type: type, wireID: row.text(1) ?? "", envelope: envelope, recordName: row.text(2) ?? ""))
        }
        return found
    }

    static func held(_ type: SyncRecordType, _ wireID: String, in zoneKey: String, _ connection: SQLiteConnection) throws -> SpaceMoveHeld? {
        guard let record = try ReplicaStore(connection: connection).record(zoneKey: zoneKey, recordType: type.rawValue, wireID: wireID),
              let envelope = try? SyncEnvelope(storedPayload: record.payload)
        else { return nil }
        return SpaceMoveHeld(type: type, wireID: wireID, envelope: envelope, recordName: record.recordName)
    }

    /// The notebook and every record that belongs to it in `zoneKey`.
    static func notebook(_ notebookID: String, in zoneKey: String, _ connection: SQLiteConnection) throws -> [SpaceMoveHeld] {
        var found: [SpaceMoveHeld] = []
        if let notebook = try held(.notebook, notebookID, in: zoneKey, connection) { found.append(notebook) }
        let records = try held(in: zoneKey, types: [.entry, .artifact, .chat, .exchange, .comment, .task], connection)
        let notes = NotesDoc.id(notebookID: notebookID)
        var chats = Set<String>()
        var docs = Set<String>()
        for record in records {
            switch record.type {
            case .entry where record.fields["containerKind"]?.stringValue == "notebook" && record.fields["containerID"]?.stringValue == notebookID:
                found.append(record)
            case .artifact where record.wireID == notes || record.fields["notebookID"]?.stringValue == notebookID:
                // A member's draft of a space Doc is that member's own (§9.5): it never travels.
                guard record.fields["draftOf"] == nil || record.fields["draftOf"] == .null else { continue }
                found.append(record)
                docs.insert(record.wireID)
            case .chat where record.fields["notebookID"]?.stringValue == notebookID:
                found.append(record)
                chats.insert(record.wireID)
            case .task where record.fields["notebookID"]?.stringValue == notebookID:
                found.append(record)
            default:
                continue
            }
        }
        for record in records {
            switch record.type {
            case .exchange where chats.contains(record.fields["chatID"]?.stringValue ?? ""): found.append(record)
            case .comment where docs.contains(record.fields["artifactID"]?.stringValue ?? ""): found.append(record)
            default: continue
            }
        }
        return found
    }

    /// A Doc and its Comments in `zoneKey`.
    static func doc(_ artifactID: String, in zoneKey: String, _ connection: SQLiteConnection) throws -> [SpaceMoveHeld] {
        guard let doc = try held(.artifact, artifactID, in: zoneKey, connection) else { return [] }
        let comments = try held(in: zoneKey, types: [.comment], connection).filter { $0.fields["artifactID"]?.stringValue == artifactID }
        return [doc] + comments
    }

    /// What stays where it is when `records` go into a space (§9.2, R5-m1): whatever the space guard
    /// refuses, and every chat whole, with its Exchanges, when the guard refuses the Chat or any one
    /// of its Exchanges (a private kind, `overallScore`, an Exchange's `score` or `grading`). Decided
    /// before any of a chat is copied, so no chat is ever split between `Library` and a space.
    static func kept(_ records: [SpaceMoveHeld], writer: SpaceWriteGuard.Writer) -> Set<SpaceMoveRecordKey> {
        var refusedChats = Set<String>()
        var kept = Set<SpaceMoveRecordKey>()
        for record in records where !SpaceWriteGuard.refusals(writing: record.type.rawValue, fields: record.fields, by: writer).isEmpty {
            kept.insert(record.key)
            switch record.type {
            case .chat: refusedChats.insert(record.wireID)
            case .exchange: refusedChats.insert(record.fields["chatID"]?.stringValue ?? "")
            default: break
            }
        }
        for record in records {
            if record.type == .chat, refusedChats.contains(record.wireID) { kept.insert(record.key) }
            if record.type == .exchange, refusedChats.contains(record.fields["chatID"]?.stringValue ?? "") { kept.insert(record.key) }
        }
        return kept
    }

    /// The Sources the live Entries among `records` name, active and approved or pending (a rejected
    /// suggestion travels as its Entry alone), with their Collections, as `zoneKey` holds them.
    static func sources(namedBy records: [SpaceMoveHeld], in zoneKey: String, _ connection: SQLiteConnection) throws -> [SpaceMoveHeld] {
        var found: [SpaceMoveHeld] = []
        var collections = Set<String>()
        for entry in records where entry.type == .entry && entry.fields["itemKind"]?.stringValue == "source" {
            guard entry.fields["state"]?.stringValue == "active",
                  ["approved", "pending"].contains(entry.fields["approval"]?.stringValue ?? "approved"),
                  let sourceID = entry.fields["itemID"]?.stringValue,
                  let source = try held(.source, sourceID, in: zoneKey, connection)
            else { continue }
            found.append(source)
            if let collection = source.fields["collectionID"]?.stringValue, !collection.isEmpty { collections.insert(collection) }
        }
        for collection in collections.sorted() {
            if let held = try held(.collection, collection, in: zoneKey, connection) { found.append(held) }
        }
        return found
    }

    /// Every FileRef a record names, wherever it sits (a field, a map's values, an Exchange's
    /// attachments, a spilled string's marker), with the children each one lists.
    static func files(in envelope: SyncEnvelope) -> [FileRef] {
        var found: [FileRef] = []
        func walk(_ value: SyncJSON) {
            if let file = FileRef(json: value) {
                found.append(file)
                return
            }
            if let object = value.objectValue {
                for key in object.keys.sorted() { walk(object[key] ?? .null) }
            } else if let array = value.arrayValue {
                array.forEach(walk)
            }
        }
        for field in envelope.fields.keys.sorted() { walk(envelope.fields[field] ?? .null) }
        return found
    }
}

/// A space id that one Job always gives, so a `Job(moveToSpace)` resumed after a crash finds the space
/// its first run made instead of making another (§5.3 step 1): a lowercase UUID from sha256 of the Job's
/// id, version and variant bits set as UUIDv4 sets them.
enum SpaceMoveIdentity {
    static func spaceID(forJob jobID: String) -> String {
        var bytes = Array(SHA256.hash(data: Data("space:v1:job:\(jobID)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return uuid.uuidString.lowercased()
    }
}
