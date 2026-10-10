import Foundation

/// The record one local row feeds, as its table's declaration finds it from the row's routing values
/// (docs/cloudkit-schema-design.md §4.3).
struct RowRecord: Hashable, Sendable {
    let type: SyncRecordType
    /// The local id of the record's own row, the one `ck_identity.local_id` names: the row's key for
    /// most tables, the parent's for a row that is an element of its parent's record.
    let localID: String
    /// The record's logical id when the row is the personal library's, where local id and logical id
    /// are one. A space copy's logical id comes from `ck_identity` instead.
    let personalID: String
}

/// A local row that must exist before a row of the table can (§5.7): the parent of a foreign key.
/// A record applied before its parent waits in `ck_unprojected` on the parent's record, and a
/// cascade from the parent lists the record there again.
struct LocalParent: Sendable, Equatable {
    /// What a missing parent means for a record whose row is gone (§5.7 `missingRow`).
    enum Role: Sendable, Equatable {
        /// The record lives in it (a notebook for its Entries): gone, the record is deleted only when
        /// this device deleted the container, else nothing is written.
        case container
        /// The record is about it (a source for its Entries): gone, nothing is written; the record
        /// hides on every device.
        case item
        /// Needed locally, with no meaning for a missing row.
        case other
    }

    /// The child's column that names the parent's row.
    let column: String
    let table: String
    /// The parent's column the child's column matches, usually its primary key.
    let parentColumn: String
    /// The parent's record type: what a waiting child waits on.
    let recordType: SyncRecordType
    let role: Role
    /// For a container: an SQL condition on the parent's row under which it is a stub that holds no
    /// records any more (a merged notebook, §5.2). A row removed from such a container takes its
    /// record with it, whoever removes it, instead of leaving the record behind as removed.
    let retiredWhen: String?

    init(_ column: String, references table: String, _ parentColumn: String = "id", type: SyncRecordType, role: Role, retiredWhen: String? = nil) {
        self.column = column
        self.table = table
        self.parentColumn = parentColumn
        self.recordType = type
        self.role = role
        self.retiredWhen = retiredWhen
    }
}

/// One local table a projection reads (§6.6 step 1): which of its columns the outbox watches, which
/// say what record a row feeds, and which rows must exist first. The trigger installer generates the
/// table's triggers from it, and the feeder routes the table's outbox rows to their records with it.
struct ProjectedTable: Sendable {
    let name: String
    /// The primary key's columns: a row's identity in the outbox (`local_key`).
    let localKey: [String]
    /// The columns that say which record a row feeds. For `learning_goal_items` they are `goal_id` and
    /// `source_id`, since its `id` is not the record's identity; a change to one of them moves the row
    /// to another record, so the old record learns it lost the row.
    let keyColumns: [String]
    /// The columns the projection reads. A write that changes no other column enqueues nothing, so
    /// opening anything (a last-opened time) sends nothing.
    let syncedColumns: [String]
    let parents: [LocalParent]
    /// For a table whose rows are the elements of a set or map field of their record (a chat's context
    /// sources): the column that holds the element's key.
    let elementColumn: String?
    /// The record types a row can feed.
    let recordTypes: [SyncRecordType]
    /// The record a row feeds, from its routing values; nil when they name none.
    let record: @Sendable ([String: SQLiteValue]) -> RowRecord?
    /// SQL for the record's local id and its personal logical id from the row named `row` (`NEW` or
    /// `OLD`), for the triggers that look the record up in the replica.
    let localIDSQL: @Sendable (String) -> String
    let personalIDSQL: @Sendable (String) -> String

    init(
        _ name: String,
        localKey: [String],
        keyColumns: [String],
        syncedColumns: [String],
        parents: [LocalParent] = [],
        elementColumn: String? = nil,
        recordTypes: [SyncRecordType],
        record: @escaping @Sendable ([String: SQLiteValue]) -> RowRecord?,
        localIDSQL: @escaping @Sendable (String) -> String,
        personalIDSQL: @escaping @Sendable (String) -> String
    ) {
        self.name = name
        self.localKey = localKey
        self.keyColumns = keyColumns
        self.syncedColumns = syncedColumns
        self.parents = parents
        self.elementColumn = elementColumn
        self.recordTypes = recordTypes
        self.record = record
        self.localIDSQL = localIDSQL
        self.personalIDSQL = personalIDSQL
    }

    /// A table whose rows are records of `type`, each named by its `idColumn` (its primary key).
    static func records(
        _ name: String,
        type: SyncRecordType,
        idColumn: String = "id",
        syncedColumns: [String],
        parents: [LocalParent] = []
    ) -> ProjectedTable {
        ProjectedTable(
            name, localKey: [idColumn], keyColumns: [idColumn], syncedColumns: syncedColumns, parents: parents,
            recordTypes: [type],
            record: { values in
                values[idColumn]?.textValue.map { RowRecord(type: type, localID: $0, personalID: $0) }
            },
            localIDSQL: { "\($0).\(idColumn)" },
            personalIDSQL: { "\($0).\(idColumn)" }
        )
    }

    /// The columns every outbox row of the table carries in `record_key_json`, so a removed row is
    /// still routed to its record and its parents still checked: key, parent and element columns.
    var routingColumns: [String] {
        var columns: [String] = []
        for column in keyColumns + parents.map(\.column) + [elementColumn].compactMap({ $0 }) where !columns.contains(column) {
            columns.append(column)
        }
        return columns
    }
}

/// Which columns feed a field, for the field's event time (§6.3): the latest change of those columns,
/// a column with no change of its own taking the row's insert time.
enum FieldFeed: Sendable, Equatable {
    /// Read from these columns of `table`.
    case columns(table: String, [String])
    /// Fed by the row's existence (`Entry.state`, `Mark.on`, `Placement.state`): the insert or delete time.
    case rowExistence(table: String)
    /// A set or map whose elements are rows of `table`, keyed by its `elementColumn`: each element takes
    /// its own row's time, and a row gone because its item went is not a removal (§5.7).
    case elementRows(table: String)
    /// Read from any of these, whichever holds the record's row: a Source's title is in the per-type
    /// table of its kind (WP7). The latest change among them.
    indirect case anyOf([FieldFeed])
}

/// What a record's missing local row means (§5.7, §6.6 step 5), once its parents are known to exist.
/// A missing container or item is decided by the parents' roles, before this.
enum MissingRowOutcome: Sendable, Equatable {
    /// The record goes: a deleted `sources` row deletes the Source record.
    case delete
    /// The record stays and these fields take the row's removal (`Entry.state = removed`).
    case fields([String: SyncJSON])
}

/// The order the feeder sends in (§6.6 step 4): what the learner sees as structure first.
enum OutboxPriority: Int, Comparable, Sendable {
    case structure = 0
    case personal = 1
    case other = 2

    static func < (lhs: OutboxPriority, rhs: OutboxPriority) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A record as a projection reads and writes it: in a zone of this device, by logical id, with the
/// local id `ck_identity` gives a space copy.
struct ProjectionRecordRef: Hashable, Sendable {
    let zoneKey: String
    let zone: SyncZoneName
    let type: SyncRecordType
    let wireID: String
    /// The local id of the record's row; for the personal library's rows the logical id itself.
    let localID: String
}

/// A local parent an applied record is waiting for, by its record.
struct WaitingParent: Hashable, Sendable {
    let type: SyncRecordType
    let wireID: String
}

enum ProjectionApplyOutcome: Equatable, Sendable {
    /// The record's local rows are written.
    case projected
    /// A local parent is missing: nothing is written, and the record waits in `ck_unprojected` until
    /// the parent's row arrives (§5.7).
    case waiting([WaitingParent])
}

/// One record type's projection into the Mac's domain tables (D32, §14.1): what it reads, how it
/// encodes the rows into fields, and how it writes an inbound record back into them.
///
/// `encodeRows(_:)` is pure, so the late import's `LegacyV2Mapping` encodes the old world's values
/// with exactly the field encoding the outbox sends (R5-m11); `encode` loads the rows and calls it.
/// `apply` and `applyDeletion` run inside an apply transaction, under the guard, and must not reach
/// past their own record: a parent that is missing is reported, never created.
protocol RecordProjection: Sendable {
    /// The local rows one record is encoded from.
    associatedtype Rows

    var recordType: SyncRecordType { get }
    var tables: [ProjectedTable] { get }
    /// Which columns feed each field. A field it does not list takes the latest change of the
    /// record's rows.
    var feeds: [String: FieldFeed] { get }
    var missingRow: MissingRowOutcome { get }
    /// Per-member state (D18): a missing parent never deletes such a record.
    var missingParentNeverDeletes: Bool { get }
    var priority: OutboxPriority { get }
    /// How long a change waits after its last write before it is sent: 2 s, 30 s for reading
    /// positions and Sittings, and for bodies (idle, D44).
    var debounce: TimeInterval { get }

    /// The record's local rows, or nil when its row is gone.
    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> Rows?
    /// The fields the projection knows, from the rows; `.null` for a value that is cleared.
    static func encodeRows(_ rows: Rows) -> [String: SyncJSON]
    /// Writes an inbound record's fields into the local rows, or says which parent it waits for.
    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome
    /// Removes the local rows of a record the server deleted.
    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws
    /// The server took a save of the record (§6.6 step 6): what the projection keeps besides the
    /// replica, such as a body's merge base (WP11). Runs inside the acknowledgement's transaction.
    func acknowledged(_ change: OutboxChange, serverRecord: ReplicaRecord, connection: SQLiteConnection) throws
}

extension RecordProjection {
    var feeds: [String: FieldFeed] { [:] }
    var missingParentNeverDeletes: Bool { false }
    var priority: OutboxPriority { .structure }
    var debounce: TimeInterval { 2 }
    func acknowledged(_ change: OutboxChange, serverRecord: ReplicaRecord, connection: SQLiteConnection) throws {}

    /// The record's fields from its current local rows; nil when its row is gone.
    func encode(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> [String: SyncJSON]? {
        try loadRows(record, connection: connection).map(Self.encodeRows)
    }

    func table(named name: String) -> ProjectedTable? {
        tables.first { $0.name == name }
    }
}

extension SQLiteValue {
    /// The value as text: text as it is, a number in SQLite's own spelling, nil for NULL and blobs.
    var textValue: String? {
        switch self {
        case .text(let text): return text
        case .integer(let number): return String(number)
        case .real(let number): return String(number)
        case .null, .blob: return nil
        }
    }

    /// A JSON value as SQLite would hold it: an integral number as an integer.
    init(json: SyncJSON) {
        switch json {
        case .null: self = .null
        case .bool(let flag): self = .integer(flag ? 1 : 0)
        case .number(let number):
            if number.rounded() == number, abs(number) < 9_007_199_254_740_992 {
                self = .integer(Int64(number))
            } else {
                self = .real(number)
            }
        case .string(let text): self = .text(text)
        case .array, .object: self = .text(String(decoding: json.serialized(), as: UTF8.self))
        }
    }
}
