import Foundation

// MARK: - The Course record (docs/cloudkit-schema-design.md §3.5.9, §5.5)

/// One `courses` row as the Course record reads it.
struct CourseRows: Equatable, Sendable {
    let id: String
    let title: String
    let institution: String?
    let playlistURL: String?
    let isHidden: Bool
    let createdAt: Double?
}

/// The Course record's projection (§3.5.9). A course lives in no notebook (product owner, 2026-10-03,
/// docs/courses-design.md "A course is its own thing"): this projection never writes `notebookID` or
/// `homing`, and the retired `courses.home_notebook_id` is neither read nor written. A notebook's one
/// tie to a course is its follow Entry (`notebook_course_links`, `EntryProjection`).
///
/// `provider` is the institution and `externalURL` the playlist a course was made from; a hidden
/// course is `archived`. The gate is today's for every course: each written quiz holds back what
/// follows it, and a pass is three in four (`LectureQuizScore.rightNeededToPass`), which `policy`
/// states as `{gateQuizzes: true, pass: null}`. `course_code` and `instructors` have no field yet and
/// stay on this Mac. A team's course is a space's (WP15): its changes wait on its `ck_identity`.
struct CourseProjection: RecordProjection {
    var recordType: SyncRecordType { .course }

    static let columns = ["title", "institution", "playlist_url", "is_hidden", "created_at"]

    var tables: [ProjectedTable] {
        [ProjectedTable.records("courses", type: .course, syncedColumns: Self.columns)]
    }

    private static func column(_ name: String) -> FieldFeed { .columns(table: "courses", [name]) }

    var feeds: [String: FieldFeed] {
        [
            "title": Self.column("title"), "provider": Self.column("institution"), "externalURL": Self.column("playlist_url"),
            "status": Self.column("is_hidden"), "createdAt": Self.column("created_at"), "policy": .rowExistence(table: "courses"),
        ]
    }

    /// A deleted course row deletes the record; its Lessons, Quizzes and lesson Entries go with it,
    /// each its own delete from the same device (§5.5).
    var missingRow: MissingRowOutcome { .delete }

    /// Today's gate, the same for every course (`CourseGate`).
    static let policy: SyncJSON = .object(["gateQuizzes": .bool(true), "pass": .null])

    func loadRows(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws -> CourseRows? {
        var rows: CourseRows?
        try connection.query(
            "SELECT title, institution, playlist_url, is_hidden, created_at FROM courses WHERE id = ?", [.text(record.localID)]
        ) { row in
            rows = CourseRows(
                id: record.localID, title: row.text(0) ?? record.localID, institution: row.text(1), playlistURL: row.text(2),
                isHidden: (row.integer(3) ?? 0) != 0, createdAt: row.real(4)
            )
        }
        return rows
    }

    static func encodeRows(_ rows: CourseRows) -> [String: SyncJSON] {
        func optional(_ text: String?) -> SyncJSON {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return .null }
            return .string(text)
        }
        var fields: [String: SyncJSON] = [
            "title": .string(rows.title),
            "provider": optional(rows.institution),
            "externalURL": optional(rows.playlistURL),
            "status": .string(rows.isHidden ? "archived" : "active"),
            "policy": policy,
        ]
        if let created = rows.createdAt { fields["createdAt"] = SyncJSON(SyncTime.milliseconds(cocoaSeconds: created)) }
        return fields
    }

    func apply(_ envelope: SyncEnvelope, to record: ProjectionRecordRef, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        // A space's course is the space packages' (WP15). `notebookID` and `homing`, which another
        // client may still hold, stay in the replica unread.
        guard !record.zone.isSpace else { return .projected }
        let fields = envelope.fields
        var values: [String: SQLiteValue] = [:]
        if let title = fields["title"]?.stringValue { values["title"] = .text(title) }
        if let provider = fields["provider"] { values["institution"] = .text(provider.stringValue) }
        if let url = fields["externalURL"] { values["playlist_url"] = .text(url.stringValue) }
        if let status = fields["status"]?.stringValue { values["is_hidden"] = .integer(status == "archived" ? 1 : 0) }
        if let created = fields["createdAt"]?.int64Value { values["created_at"] = .real(SyncTime.cocoaSeconds(milliseconds: created)) }

        let held = try connection.scalarInteger("SELECT EXISTS(SELECT 1 FROM courses WHERE id = ?)", [.text(record.localID)]) == 1
        if held {
            guard !values.isEmpty else { return .projected }
            let names = values.keys.sorted()
            try connection.execute(
                "UPDATE courses SET \(names.map { "\($0) = ?" }.joined(separator: ", ")) WHERE id = ?",
                names.compactMap { values[$0] } + [.text(record.localID)]
            )
        } else {
            values["title"] = values["title"] ?? .text(record.wireID)
            values["wire_id"] = .text(record.wireID)
            let names = values.keys.sorted()
            try connection.execute(
                "INSERT INTO courses (id, \(names.joined(separator: ", "))) VALUES (?, \(names.map { _ in "?" }.joined(separator: ", ")))",
                [.text(record.localID)] + names.compactMap { values[$0] }
            )
        }
        return .projected
    }

    /// The course and what lives in it on this Mac: its lessons (their items cascade) and quizzes. Their
    /// own deletes follow from the deleting device; a notebook's follow Entry stays, hidden while the
    /// course is missing (§3.5.8).
    func applyDeletion(_ record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        guard !record.zone.isSpace else { return }
        try connection.execute("DELETE FROM course_quizzes WHERE course_id = ?", [.text(record.localID)])
        try connection.execute("DELETE FROM course_lectures WHERE course_id = ?", [.text(record.localID)])
        try connection.execute("DELETE FROM courses WHERE id = ?", [.text(record.localID)])
    }
}
