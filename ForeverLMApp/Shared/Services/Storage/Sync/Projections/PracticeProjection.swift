import Foundation

// MARK: - Practice (docs/cloudkit-schema-design.md §3.5.25)

/// A proposed or adopted study practice, as `practices` holds it (times in Cocoa seconds).
struct PracticeRecord: Equatable, Sendable {
    static let origins: Set<String> = ["rule", "user", "ai"]
    static let statuses: Set<String> = ["proposed", "adopted", "dismissed", "retired"]

    var id: String
    var ruleID: String?
    var scope: String?
    var period: String?
    var origin: String
    var status: String
    var title: String
    var body: String?
    var evidence: SyncJSON?
    var minSampleMet: Bool?
    var rule: SyncJSON?
    var settingChange: SyncJSON?
    var madeBy: SyncJSON?
    var decidedAt: Double?
    var appliedAt: Double?
    var validUntil: Double?
    var createdAt: Double
}

/// The Practice record's projection: one `practices` row per record. A rule's proposal has a deterministic
/// id (`pr:<ruleID>:<scope>:<period>`), so two devices never propose it twice; deciding it is an L write.
struct PracticeProjection: RecordProjection {
    var recordType: SyncRecordType { .practice }

    static let columns = [
        "rule_id", "scope", "period", "origin", "status", "title", "body", "evidence_json", "min_sample_met", "rule_json",
        "setting_change_json", "made_by_json", "decided_at", "applied_at", "valid_until", "created_at",
    ]

    var tables: [ProjectedTable] { [.records("practices", type: .practice, syncedColumns: Self.columns)] }

    var feeds: [String: FieldFeed] {
        var feeds: [String: FieldFeed] = [:]
        let fields = [
            "ruleID": "rule_id", "scope": "scope", "period": "period", "origin": "origin", "status": "status", "title": "title",
            "body": "body", "evidence": "evidence_json", "minSampleMet": "min_sample_met", "rule": "rule_json",
            "settingChange": "setting_change_json", "madeBy": "made_by_json", "decidedAt": "decided_at", "appliedAt": "applied_at",
            "validUntil": "valid_until", "createdAt": "created_at",
        ]
        for (field, column) in fields { feeds[field] = .columns(table: "practices", [column]) }
        return feeds
    }

    var missingRow: MissingRowOutcome { .delete }
    var priority: OutboxPriority { .personal }

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> PracticeRecord? {
        try Self.load(id: record.localID, connection: connection)
    }

    static func load(id: String, connection: SQLiteConnection) throws -> PracticeRecord? {
        try loadAll(connection: connection, where: "id = ?", [.text(id)]).first
    }

    static func loadAll(connection: SQLiteConnection, where condition: String = "1", _ parameters: [SQLiteValue] = []) throws -> [PracticeRecord] {
        var practices: [PracticeRecord] = []
        try connection.query("""
            SELECT id, rule_id, scope, period, origin, status, title, body, evidence_json, min_sample_met, rule_json,
                   setting_change_json, made_by_json, decided_at, applied_at, valid_until, created_at
            FROM practices WHERE \(condition) ORDER BY created_at DESC, id
        """, parameters) { row in
            practices.append(PracticeRecord(
                id: row.text(0) ?? "", ruleID: row.text(1), scope: row.text(2), period: row.text(3), origin: row.text(4) ?? "user",
                status: row.text(5) ?? "proposed", title: row.text(6) ?? "", body: row.text(7),
                evidence: SittingProjection.json(row.text(8)), minSampleMet: row.integer(9).map { $0 == 1 },
                rule: SittingProjection.json(row.text(10)), settingChange: SittingProjection.json(row.text(11)),
                madeBy: SittingProjection.json(row.text(12)), decidedAt: row.real(13), appliedAt: row.real(14),
                validUntil: row.real(15), createdAt: row.real(16) ?? 0
            ))
        }
        return practices
    }

    static func encodeRows(_ rows: PracticeRecord) -> [String: SyncJSON] {
        func ms(_ seconds: Double?) -> SyncJSON? { seconds.map { SyncJSON(SyncTime.milliseconds(cocoaSeconds: $0)) } }
        var fields: [String: SyncJSON] = [
            "origin": .string(rows.origin), "status": .string(rows.status), "title": .string(rows.title),
            "createdAt": SyncJSON(SyncTime.milliseconds(cocoaSeconds: rows.createdAt)),
        ]
        if let value = rows.ruleID { fields["ruleID"] = .string(value) }
        if let value = rows.scope { fields["scope"] = .string(value) }
        if let value = rows.period { fields["period"] = .string(value) }
        fields["body"] = rows.body.map(SyncJSON.string) ?? .null
        if let value = rows.evidence { fields["evidence"] = value }
        if let value = rows.minSampleMet { fields["minSampleMet"] = .bool(value) }
        fields["rule"] = rows.rule ?? .null
        fields["settingChange"] = rows.settingChange ?? .null
        if let value = rows.madeBy { fields["madeBy"] = value }
        fields["decidedAt"] = ms(rows.decidedAt) ?? .null
        fields["appliedAt"] = ms(rows.appliedAt) ?? .null
        fields["validUntil"] = ms(rows.validUntil) ?? .null
        return fields
    }

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        guard !record.zone.isSpace else { return .projected }
        let fields = envelope.fields
        let held = try Self.load(id: record.localID, connection: connection)
        func text(_ field: String, _ held: String?) -> String? {
            guard let given = fields[field] else { return held }
            return given.stringValue
        }
        func json(_ field: String, _ held: SyncJSON?) -> String? {
            guard let given = fields[field] else { return SittingProjection.text(held) }
            return SittingProjection.text(given)
        }
        func time(_ field: String, _ held: Double?) -> Double? {
            guard let given = fields[field] else { return held }
            return given.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) }
        }
        let minSample = fields["minSampleMet"].map { $0.boolValue } ?? held?.minSampleMet
        try connection.execute("""
            INSERT INTO practices (id, rule_id, scope, period, origin, status, title, body, evidence_json, min_sample_met, rule_json,
                setting_change_json, made_by_json, decided_at, applied_at, valid_until, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                rule_id = excluded.rule_id, scope = excluded.scope, period = excluded.period, origin = excluded.origin,
                status = excluded.status, title = excluded.title, body = excluded.body, evidence_json = excluded.evidence_json,
                min_sample_met = excluded.min_sample_met, rule_json = excluded.rule_json,
                setting_change_json = excluded.setting_change_json, made_by_json = excluded.made_by_json,
                decided_at = excluded.decided_at, applied_at = excluded.applied_at, valid_until = excluded.valid_until,
                created_at = excluded.created_at
        """, [
            .text(record.localID), .text(text("ruleID", held?.ruleID)), .text(text("scope", held?.scope)),
            .text(text("period", held?.period)), .text(text("origin", held?.origin) ?? "user"),
            .text(text("status", held?.status) ?? "proposed"), .text(text("title", held?.title) ?? ""),
            .text(text("body", held?.body)), .text(json("evidence", held?.evidence)), .integer(minSample.map { $0 ? 1 : 0 }),
            .text(json("rule", held?.rule)), .text(json("settingChange", held?.settingChange)), .text(json("madeBy", held?.madeBy)),
            .real(time("decidedAt", held?.decidedAt)), .real(time("appliedAt", held?.appliedAt)),
            .real(time("validUntil", held?.validUntil)),
            .real(time("createdAt", held?.createdAt) ?? Date().timeIntervalSinceReferenceDate),
        ])
        return .projected
    }

    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        guard !record.zone.isSpace else { return }
        try connection.execute("DELETE FROM practices WHERE id = ?", [.text(record.localID)])
    }
}

// MARK: - Practices on this Mac

enum PracticeError: Error, LocalizedError, Equatable {
    case generation1
    case notFound(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .generation1:
            return "Study practices arrive with ForeverLM's new iCloud sync. This Mac still syncs the old way, so there are none yet."
        case .notFound(let id): return "No study practice has the id \(id)."
        case .invalid(let message): return message
        }
    }
}

extension KnowledgeStore {
    /// Every practice, newest first; those of `status` only when given.
    func loadPractices(status: String? = nil) throws -> [PracticeRecord] {
        guard try recordsMemoryForGeneration2() else { throw PracticeError.generation1 }
        if let status { return try PracticeProjection.loadAll(connection: self, where: "status = ?", [.text(status)]) }
        return try PracticeProjection.loadAll(connection: self)
    }

    func loadPractice(id: String) throws -> PracticeRecord? {
        guard try recordsMemoryForGeneration2() else { throw PracticeError.generation1 }
        return try PracticeProjection.load(id: id, connection: self)
    }

    /// Writes a practice whole: an upsert, so the outbox records only the columns that changed.
    func savePractice(_ practice: PracticeRecord) throws {
        guard try recordsMemoryForGeneration2() else { throw PracticeError.generation1 }
        guard PracticeRecord.origins.contains(practice.origin), PracticeRecord.statuses.contains(practice.status) else {
            throw PracticeError.invalid("A practice's origin is rule, user or ai, and its status proposed, adopted, dismissed or retired.")
        }
        guard !practice.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PracticeError.invalid("A practice needs a title.")
        }
        guard (practice.body?.utf8.count ?? 0) <= 4_096 else { throw PracticeError.invalid("A practice's rationale is at most 4 KB.") }
        try execute("""
            INSERT INTO practices (id, rule_id, scope, period, origin, status, title, body, evidence_json, min_sample_met, rule_json,
                setting_change_json, made_by_json, decided_at, applied_at, valid_until, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                rule_id = excluded.rule_id, scope = excluded.scope, period = excluded.period, origin = excluded.origin,
                status = excluded.status, title = excluded.title, body = excluded.body, evidence_json = excluded.evidence_json,
                min_sample_met = excluded.min_sample_met, rule_json = excluded.rule_json,
                setting_change_json = excluded.setting_change_json, made_by_json = excluded.made_by_json,
                decided_at = excluded.decided_at, applied_at = excluded.applied_at, valid_until = excluded.valid_until
        """, [
            .text(practice.id), .text(practice.ruleID), .text(practice.scope), .text(practice.period), .text(practice.origin),
            .text(practice.status), .text(practice.title), .text(practice.body), .text(SittingProjection.text(practice.evidence)),
            .integer(practice.minSampleMet.map { $0 ? 1 : 0 }), .text(SittingProjection.text(practice.rule)),
            .text(SittingProjection.text(practice.settingChange)), .text(SittingProjection.text(practice.madeBy)),
            .real(practice.decidedAt), .real(practice.appliedAt), .real(practice.validUntil), .real(practice.createdAt),
        ])
    }

    /// A proposal from the rule engine, written only where no practice of that rule, scope and period
    /// exists: a learner's decision, or another device's proposal, is never overwritten.
    @discardableResult
    func proposePractice(_ practice: PracticeRecord) throws -> Bool {
        guard try PracticeProjection.load(id: practice.id, connection: self) == nil else { return false }
        try savePractice(practice)
        return true
    }
}
