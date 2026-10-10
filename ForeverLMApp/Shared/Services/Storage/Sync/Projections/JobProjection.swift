import Foundation

// MARK: - A Job: work a Mac does for the iPhone, the web or the hosted MCP (§3.5.28)

/// One `jobs` row, the one local row of a Job record. The objects the wire holds (`params`,
/// `requestedBy`, `claim`, `result`) are kept as their JSON; times are Cocoa seconds.
struct JobRow: Equatable, Sendable {
    static let statuses: Set<String> = ["queued", "running", "done", "failed", "cancelled"]
    static let finished: Set<String> = ["done", "failed", "cancelled"]

    var id: String
    var kind: String
    var target: String?
    var params: [String: SyncJSON] = [:]
    var requestedBy: [String: SyncJSON]?
    var requestedAt: Double?
    var claim: [String: SyncJSON]?
    var leaseUntil: Double?
    var status: String = "queued"
    var result: [String: SyncJSON]?
    var error: String?
    var expiresAt: Double?

    /// The device whose claim the row holds.
    var claimDevice: String? { claim?["device"]?.stringValue }
    var claimedAt: Double? { claim?["at"]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) } }
    var isFinished: Bool { Self.finished.contains(status) }

    private static let columns = "kind, target, params_json, requested_by_json, requested_at, claim_json, lease_until, status, result_json, error, expires_at"

    private static func object(_ text: String?) -> [String: SyncJSON]? {
        text.flatMap { try? SyncJSON(parsing: Data($0.utf8)) }?.objectValue
    }

    private static func text(_ object: [String: SyncJSON]?) -> String? {
        object.map { String(decoding: SyncJSON.object($0).serialized(), as: UTF8.self) }
    }

    static func load(_ id: String, connection: SQLiteConnection) throws -> JobRow? {
        var found: JobRow?
        try connection.query("SELECT \(columns) FROM jobs WHERE id = ?", [.text(id)]) { row in
            found = JobRow(
                id: id, kind: row.text(0) ?? "", target: row.text(1), params: object(row.text(2)) ?? [:], requestedBy: object(row.text(3)),
                requestedAt: row.real(4), claim: object(row.text(5)), leaseUntil: row.real(6), status: row.text(7) ?? "queued",
                result: object(row.text(8)), error: row.text(9), expiresAt: row.real(10)
            )
        }
        return found
    }

    /// Every row not finished, oldest request first: what a runner looks at.
    static func open(connection: SQLiteConnection) throws -> [JobRow] {
        var ids: [String] = []
        try connection.query(
            "SELECT id FROM jobs WHERE status IN ('queued', 'running') ORDER BY requested_at, id", []
        ) { row in
            if let id = row.text(0) { ids.append(id) }
        }
        return try ids.compactMap { try load($0, connection: connection) }
    }

    /// Writes the row whole (an upsert, so the outbox records only the columns that changed).
    func save(_ connection: SQLiteConnection) throws {
        try connection.execute("""
            INSERT INTO jobs (id, \(Self.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                kind = excluded.kind, target = excluded.target, params_json = excluded.params_json,
                requested_by_json = excluded.requested_by_json, requested_at = excluded.requested_at, claim_json = excluded.claim_json,
                lease_until = excluded.lease_until, status = excluded.status, result_json = excluded.result_json, error = excluded.error,
                expires_at = excluded.expires_at
        """, [
            .text(id), .text(kind), .text(target), .text(Self.text(params) ?? "{}"), .text(Self.text(requestedBy)), .real(requestedAt),
            .text(Self.text(claim)), .real(leaseUntil), .text(status), .text(Self.text(result)), .text(error), .real(expiresAt),
        ])
    }
}

/// The Job record's projection (§3.5.28): private to the member (the codec refuses it in a space).
/// `kind`, `target`, `params`, `requestedBy`, `requestedAt`, `claim` and `expiresAt` are first-writer
/// (S), so a claim is decided by the save the server accepted first; the claimer's `leaseUntil`,
/// `status`, `result` and `error` are last-writer (L). `MacJobRunner` writes the row; a Job a light
/// client wrote arrives through `apply`.
struct JobProjection: RecordProjection {
    var recordType: SyncRecordType { .job }

    static let columns = [
        "kind", "target", "params_json", "requested_by_json", "requested_at", "claim_json", "lease_until", "status", "result_json",
        "error", "expires_at",
    ]

    var tables: [ProjectedTable] {
        [.records("jobs", type: .job, syncedColumns: Self.columns)]
    }

    private static func column(_ name: String) -> FieldFeed { .columns(table: "jobs", [name]) }

    var feeds: [String: FieldFeed] {
        [
            "kind": Self.column("kind"), "target": Self.column("target"), "params": Self.column("params_json"),
            "requestedBy": Self.column("requested_by_json"), "requestedAt": Self.column("requested_at"), "claim": Self.column("claim_json"),
            "leaseUntil": Self.column("lease_until"), "status": Self.column("status"), "result": Self.column("result_json"),
            "error": Self.column("error"), "expiresAt": Self.column("expires_at"),
        ]
    }

    var missingRow: MissingRowOutcome { .delete }
    var missingParentNeverDeletes: Bool { true }

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> JobRow? {
        try JobRow.load(record.wireID, connection: connection)
    }

    static func encodeRows(_ row: JobRow) -> [String: SyncJSON] {
        func milliseconds(_ seconds: Double?) -> SyncJSON { seconds.map { SyncJSON(SyncTime.milliseconds(cocoaSeconds: $0)) } ?? .null }
        return [
            "kind": .string(row.kind),
            "target": row.target.map(SyncJSON.string) ?? .null,
            "params": .object(row.params),
            "requestedBy": row.requestedBy.map(SyncJSON.object) ?? .null,
            "requestedAt": milliseconds(row.requestedAt),
            "claim": row.claim.map(SyncJSON.object) ?? .null,
            "leaseUntil": milliseconds(row.leaseUntil),
            "status": .string(row.status),
            "result": row.result.map(SyncJSON.object) ?? .null,
            "error": row.error.map(SyncJSON.string) ?? .null,
            "expiresAt": milliseconds(row.expiresAt),
        ]
    }

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        guard !record.zone.isSpace else { return .projected }
        let fields = envelope.fields
        func seconds(_ field: String) -> Double? { fields[field]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) } }
        var row = try JobRow.load(record.wireID, connection: connection) ?? JobRow(id: record.wireID, kind: "")
        if let kind = fields["kind"]?.stringValue { row.kind = kind }
        if let target = fields["target"] { row.target = target.stringValue }
        if let params = fields["params"]?.objectValue { row.params = params }
        if let requested = fields["requestedBy"] { row.requestedBy = requested.objectValue }
        if fields["requestedAt"] != nil { row.requestedAt = seconds("requestedAt") }
        if let claim = fields["claim"] { row.claim = claim.objectValue }
        if fields["leaseUntil"] != nil { row.leaseUntil = seconds("leaseUntil") }
        if let status = fields["status"]?.stringValue { row.status = status }
        if let result = fields["result"] { row.result = result.objectValue }
        if let error = fields["error"] { row.error = error.stringValue }
        if fields["expiresAt"] != nil { row.expiresAt = seconds("expiresAt") }
        try row.save(connection)
        return .projected
    }

    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        guard !record.zone.isSpace else { return }
        try connection.execute("DELETE FROM jobs WHERE id = ?", [.text(record.wireID)])
    }
}

/// A Job this Mac asks of another Mac (§3.5.28): Run now on an automation another Mac runs. Its row goes
/// out like any other, and the Mac that can run it claims it.
enum MacJobRequests {
    /// A Job is kept for 7 days after it was asked for (`expiresAt`).
    static let lifetime: TimeInterval = 7 * 86_400

    @discardableResult
    static func request(kind: String, target: String?, params: [String: SyncJSON], device: String, at date: Date,
                        connection: SQLiteConnection) throws -> String {
        let requested = date.timeIntervalSinceReferenceDate
        let row = JobRow(
            id: UUID().uuidString.lowercased(), kind: kind, target: target, params: params,
            requestedBy: ["device": .string(device), "platform": .string("mac")], requestedAt: requested,
            expiresAt: requested + lifetime
        )
        try row.save(connection)
        return row.id
    }
}
