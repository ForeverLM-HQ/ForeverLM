import Foundation

// MARK: - The member's Enrollment in a course (docs/cloudkit-schema-design.md §3.5.12)

/// One `course_enrollments` row: the member's own standing in one course, keyed by the course's wire id
/// with no foreign key (D18). Made only by an explicit act (a focus, a pace, enrolling), never by
/// opening the course.
struct CourseEnrollmentRow: Equatable, Sendable {
    var courseID: String
    var status: String = "enrolled"
    var focus: String?
    var paceJSON: String?
    var targetDate: String?
    var startedAt: Double?
    var lastLessonID: String?

    static func load(_ courseID: String, connection: SQLiteConnection) throws -> CourseEnrollmentRow? {
        var row: CourseEnrollmentRow?
        try connection.query("""
            SELECT status, focus, pace_json, target_date, started_at, last_lesson_id FROM course_enrollments WHERE course_id = ?
        """, [.text(courseID)]) { values in
            row = CourseEnrollmentRow(
                courseID: courseID, status: values.text(0) ?? "enrolled", focus: values.text(1), paceJSON: values.text(2),
                targetDate: values.text(3), startedAt: values.real(4), lastLessonID: values.text(5)
            )
        }
        return row
    }

    /// Writes the row whole (an upsert, so the outbox records only the columns that changed).
    func save(_ connection: SQLiteConnection) throws {
        try connection.execute("""
            INSERT INTO course_enrollments (course_id, status, focus, pace_json, target_date, started_at, last_lesson_id)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(course_id) DO UPDATE SET
                status = excluded.status, focus = excluded.focus, pace_json = excluded.pace_json, target_date = excluded.target_date,
                started_at = excluded.started_at, last_lesson_id = excluded.last_lesson_id
        """, [.text(courseID), .text(status), .text(focus), .text(paceJSON), .text(targetDate), .real(startedAt), .text(lastLessonID)])
    }
}

/// The Enrollment record's projection (§3.5.12): private to the member (the codec refuses it in a
/// space), never deleted because its course went.
struct EnrollmentProjection: RecordProjection {
    var recordType: SyncRecordType { .enrollment }

    static let columns = ["status", "focus", "pace_json", "target_date", "started_at", "last_lesson_id"]

    var tables: [ProjectedTable] {
        let recordIDSQL: @Sendable (String) -> String = { "'enr:' || \($0).course_id" }
        return [ProjectedTable(
            "course_enrollments", localKey: ["course_id"], keyColumns: ["course_id"], syncedColumns: Self.columns,
            recordTypes: [.enrollment],
            record: { values in
                values["course_id"]?.textValue.map {
                    let id = SyncIdentity.enrollmentID(courseID: $0)
                    return RowRecord(type: .enrollment, localID: id, personalID: id)
                }
            },
            localIDSQL: recordIDSQL, personalIDSQL: recordIDSQL
        )]
    }

    private static func column(_ name: String) -> FieldFeed { .columns(table: "course_enrollments", [name]) }

    var feeds: [String: FieldFeed] {
        [
            "courseID": .rowExistence(table: "course_enrollments"), "status": Self.column("status"), "focus": Self.column("focus"),
            "pace": Self.column("pace_json"), "targetDate": Self.column("target_date"), "startedAt": Self.column("started_at"),
            "lastLessonID": Self.column("last_lesson_id"),
        ]
    }

    var missingRow: MissingRowOutcome { .delete }
    var missingParentNeverDeletes: Bool { true }
    var priority: OutboxPriority { .personal }

    static func courseID(ofRecord wireID: String) -> String {
        wireID.hasPrefix("enr:") ? String(wireID.dropFirst(4)) : wireID
    }

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> CourseEnrollmentRow? {
        try CourseEnrollmentRow.load(Self.courseID(ofRecord: record.wireID), connection: connection)
    }

    static func encodeRows(_ row: CourseEnrollmentRow) -> [String: SyncJSON] {
        var fields: [String: SyncJSON] = [
            "courseID": .string(row.courseID),
            "status": .string(row.status),
            "focus": row.focus.flatMap { $0.isEmpty ? nil : SyncJSON.string($0) } ?? .null,
            "pace": row.paceJSON.flatMap { try? SyncJSON(parsing: Data($0.utf8)) } ?? .null,
            "targetDate": row.targetDate.map(SyncJSON.string) ?? .null,
            "lastLessonID": row.lastLessonID.map(SyncJSON.string) ?? .null,
        ]
        if let started = row.startedAt { fields["startedAt"] = SyncJSON(SyncTime.milliseconds(cocoaSeconds: started)) }
        return fields
    }

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        guard !record.zone.isSpace else { return .projected }
        let fields = envelope.fields
        let courseID = fields["courseID"]?.stringValue ?? Self.courseID(ofRecord: record.wireID)
        var row = try CourseEnrollmentRow.load(courseID, connection: connection) ?? CourseEnrollmentRow(courseID: courseID)
        if let status = fields["status"]?.stringValue { row.status = status }
        if let focus = fields["focus"] { row.focus = focus.stringValue }
        if let pace = fields["pace"] { row.paceJSON = pace.isNull ? nil : String(decoding: pace.serialized(), as: UTF8.self) }
        if let target = fields["targetDate"] { row.targetDate = target.stringValue }
        if let started = fields["startedAt"]?.int64Value { row.startedAt = SyncTime.cocoaSeconds(milliseconds: started) }
        if let lesson = fields["lastLessonID"] { row.lastLessonID = lesson.stringValue }
        try row.save(connection)
        return .projected
    }

    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        try connection.execute("DELETE FROM course_enrollments WHERE course_id = ?", [.text(Self.courseID(ofRecord: record.wireID))])
    }
}
