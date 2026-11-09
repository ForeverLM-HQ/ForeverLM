import Foundation

// MARK: - What generation 2 keeps beside generation 1's course writes (§12.7 v157)

extension KnowledgeStore {
    /// After a write to a course's rows, under generation 2 only: the course gets its created date,
    /// its lectures and their items their order keys (only the rows out of order take new ones), each
    /// item its slot and its span, and a team's course its children's `ck_identity` rows. Runs inside the
    /// writer's transaction; generation 1 writes exactly what build 177 does (D40).
    func keepCourseRowsForGeneration2(courseIDs: [String]) throws {
        let zones = try teamZoneKeys()
        let now = Date().timeIntervalSinceReferenceDate
        for courseID in Set(courseIDs).sorted() {
            try CourseUpkeep.keep(courseID: courseID, now: now, teamZones: zones, connection: self)
        }
    }

    /// A quiz whose questions a save changed counts a new revision (§3.5.11, `QuizRevisionTests`), so a
    /// sitting of the earlier questions reads as a previous version's. Generation 2 only.
    func countQuizRevisionForGeneration2(quizID: String, questionsBefore: String?) throws {
        guard let questionsBefore else { return }
        guard let after = try scalarText("SELECT questions_json FROM course_quizzes WHERE id = ?", [.text(quizID)]),
              !Self.sameQuestions(questionsBefore, after) else { return }
        try execute("UPDATE course_quizzes SET revision = revision + 1 WHERE id = ?", [.text(quizID)])
    }

    /// Whether two `questions_json` texts hold the same questions: the same bytes, or the same value once
    /// parsed (a re-encode that orders keys or spaces them otherwise is no new revision).
    static func sameQuestions(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        func parsed(_ text: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) }
        guard let first = parsed(a) as? NSObject, let second = parsed(b) as? NSObject else { return false }
        return first.isEqual(second)
    }
}

/// The course rows' generation-2 columns, kept from what generation 1 wrote (`keepCourseRowsForGeneration2`)
/// and derived once at the activation (`courseActivationDerivations`): both give the same result.
enum CourseUpkeep {
    static func keep(courseID: String, now: Double, teamZones: [String: String], connection: SQLiteConnection) throws {
        // The course's first lecture or quiz dates it; one with neither is dated now.
        try connection.execute("""
            UPDATE courses SET created_at = COALESCE(
                MIN((SELECT MIN(created_at) FROM course_lectures WHERE course_id = ?1), (SELECT MIN(created_at) FROM course_quizzes WHERE course_id = ?1)),
                (SELECT MIN(created_at) FROM course_lectures WHERE course_id = ?1),
                (SELECT MIN(created_at) FROM course_quizzes WHERE course_id = ?1),
                ?2)
            WHERE id = ?1 AND created_at IS NULL
        """, [.text(courseID), .real(now)])
        try LessonOrderKeys.replanLessons(courseID: courseID, connection: connection)
        var lectures: [String] = []
        try connection.query("SELECT id FROM course_lectures WHERE course_id = ? ORDER BY id", [.text(courseID)]) { row in
            if let id = row.text(0) { lectures.append(id) }
        }
        for lecture in lectures {
            try LessonOrderKeys.assignSlots(lectureID: lecture, connection: connection)
            try LessonOrderKeys.fillSpans(lectureID: lecture, connection: connection)
            try LessonOrderKeys.replanItems(lectureID: lecture, connection: connection)
        }
        try recordTeamIdentities(courseID: courseID, teamZones: teamZones, connection: connection)
    }

    /// A team's course lives in the space its team becomes (§13.7, WP15): its lessons, quizzes and lesson
    /// Entries get `ck_identity` rows in that zone, as the course itself did (`deriveWireIDs`), so the
    /// feeder holds their changes until the space has a root instead of sending them into `Library`.
    static func recordTeamIdentities(courseID: String, teamZones: [String: String], connection: SQLiteConnection) throws {
        guard let team = try connection.scalarText("SELECT team_id FROM courses WHERE id = ?", [.text(courseID)]),
              let zone = teamZones[team] else { return }
        var children: [(type: SyncRecordType, id: String)] = []
        try connection.query("SELECT id FROM course_lectures WHERE course_id = ?", [.text(courseID)]) { row in
            if let id = row.text(0) { children.append((.lesson, id)) }
        }
        try connection.query("SELECT id FROM course_quizzes WHERE course_id = ?", [.text(courseID)]) { row in
            if let id = row.text(0) { children.append((.quiz, id)) }
        }
        // A lesson Entry is named by its source's wire id (a team's copy goes by the canonical personal
        // id, §4.3, WP15), and its row by the copy's local id.
        var entries: [(wire: String, local: String)] = []
        try connection.query("""
            SELECT i.lecture_id, i.source_id, COALESCE(i.span_slot, 1), COALESCE(s.wire_key, i.source_id) FROM course_lecture_items i
            JOIN course_lectures l ON l.id = i.lecture_id LEFT JOIN sources s ON s.id = i.source_id
            WHERE l.course_id = ? AND i.source_id IS NOT NULL
        """, [.text(courseID)]) { row in
            guard let lecture = row.text(0), let source = row.text(1), let wire = row.text(3) else { return }
            let span = Int(row.integer(2) ?? 1)
            entries.append((SyncIdentity.entryID(containerID: lecture, itemKind: "source", itemID: wire, span: span),
                            SyncIdentity.entryID(containerID: lecture, itemKind: "source", itemID: source, span: span)))
        }
        let identities = children.map { (type: $0.type, wire: $0.id, local: $0.id) } + entries.map { (type: SyncRecordType.entry, wire: $0.wire, local: $0.local) }
        for child in identities {
            // A copy named before it had its wire id keeps one identity, under the wire id it has now.
            try connection.execute(
                "DELETE FROM ck_identity WHERE zone_key = ? AND record_type = ? AND local_id = ? AND wire_id <> ?",
                [.text(zone), .text(child.type.rawValue), .text(child.local), .text(child.wire)]
            )
            try connection.execute("""
                INSERT INTO ck_identity (zone_key, record_type, wire_id, local_id) VALUES (?, ?, ?, ?)
                ON CONFLICT(zone_key, record_type, wire_id) DO UPDATE SET local_id = excluded.local_id
            """, [.text(zone), .text(child.type.rawValue), .text(child.wire), .text(child.local)])
        }
    }
}
