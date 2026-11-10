import Foundation

// MARK: - Schema 157: what the Course, Lesson, Quiz and Enrollment records need (§12.7)

extension KnowledgeStore {
    /// The table schema 157 added (docs/cloudkit-schema-design.md §12.7), created empty, with its columns
    /// on the course tables (`courses.created_at`, the order keys, an item's span and slot, a quiz's
    /// revision) in those tables' own definitions. The generation-2 activation fills it
    /// (`courseActivationDerivations`), and from then on the course projections and the upkeep keep it.
    static let courseSyncTables: [ReplicaSchemaTable] = [
        // The member's own Enrollment in one course (§3.5.12), keyed by the course's wire id with no
        // foreign key: per-member state outlives the course it is about (D18). Made only by an explicit
        // act (enroll, a focus, a pace), never by opening the course. `pace_json` is `{lessonsPerWeek}`,
        // `target_date` a calendar day.
        ReplicaSchemaTable("course_enrollments", [
            ("course_id", "TEXT PRIMARY KEY"),
            ("status", "TEXT NOT NULL DEFAULT 'enrolled'"),
            ("focus", "TEXT"),
            ("pace_json", "TEXT"),
            ("target_date", "TEXT"),
            ("started_at", "REAL"),
            ("last_lesson_id", "TEXT"),
        ]),
    ]

    /// Creates schema 157's table where missing: empty, DDL only.
    func createCourseSyncTables() throws {
        for table in Self.courseSyncTables {
            try exec(table.createStatement)
            for index in table.indexes {
                try exec(index)
            }
        }
    }

}

// MARK: - The activation's derivations for courses (§13.3 step 3c)

extension KnowledgeStore {
    /// WP9's derivations, in order, after WP8's: every course's generation-2 columns (its created date,
    /// its lectures' and items' order keys, the items' slots and spans, a team's course's children in
    /// `ck_identity`), exactly what the generation-2 upkeep keeps afterwards; then the member's
    /// Enrollments from the `course.focus.*` rows. Each is idempotent, bounded by the library's courses,
    /// in its own transaction, and reads generation-1 truth only. A quiz's revision needs no
    /// derivation: schema 157 made it 1 on every row. Nothing is derived for a course's home: a course
    /// lives in no notebook (2026-10-03), and `home_notebook_id` is left unread.
    static let courseActivationDerivations: [ActivationDerivation] = [
        ActivationDerivation(id: "courseRows") { store in try store.inDerivationTransaction { try $0.deriveCourseRows() } },
        ActivationDerivation(id: "courseEnrollments") { store in try store.inDerivationTransaction { try $0.deriveCourseEnrollments() } },
    ]

    /// Every course's rows as the upkeep keeps them, each course a lecture or a quiz names included.
    func deriveCourseRows() throws {
        var courses: [String] = []
        try query("""
            SELECT id FROM courses UNION SELECT course_id FROM course_lectures UNION SELECT course_id FROM course_quizzes ORDER BY 1
        """, []) { row in
            if let id = row.text(0) { courses.append(id) }
        }
        let zones = try teamZoneKeys()
        let now = Date().timeIntervalSinceReferenceDate
        for course in courses {
            try CourseUpkeep.keep(courseID: course, now: now, teamZones: zones, connection: self)
        }
    }

    /// The member's Enrollments from generation 1's `course.focus.<courseID>` rows (§10): a course the
    /// learner wrote a focus for is one they are enrolled in, with that focus. Each derived focus is
    /// exactly what the rows say, so a run after generation-1 edits reflects them and a second run
    /// changes nothing.
    func deriveCourseEnrollments() throws {
        var focus: [String: String] = [:]
        try query("SELECT key, value FROM user_preferences WHERE key LIKE ?", [.text(LearnerProfile.courseFocusPreferenceKeyPrefix + "%")]) { row in
            guard let key = row.text(0), key.count > LearnerProfile.courseFocusPreferenceKeyPrefix.count,
                  let text = (row.text(1).flatMap(PreferenceStore.decodePlist) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            focus[String(key.dropFirst(LearnerProfile.courseFocusPreferenceKeyPrefix.count))] = text
        }
        var held: [String] = []
        try query("SELECT course_id FROM course_enrollments", []) { row in if let id = row.text(0) { held.append(id) } }
        for courseID in Set(held).union(focus.keys).sorted() {
            var row = try CourseEnrollmentRow.load(courseID, connection: self) ?? CourseEnrollmentRow(courseID: courseID)
            row.focus = focus[courseID]
            try row.save(self)
        }
    }
}
