import Foundation
import Testing
@testable import ForeverLM

/// Schema 157's activation steps (docs/cloudkit-schema-design.md §13.3 step 3c, WP9): the course rows'
/// generation-2 columns and the member's Enrollments from the `course.focus.*` rows, run twice and after
/// generation-1 edits; and the focus, which generation 1 keeps as a preference row and generation 2 as
/// the member's Enrollment.
extension CourseSchema157MigrationTests {
    typealias F = NotebookSyncFixture

    static func setPreference(_ store: KnowledgeStore, _ key: String, _ value: Any?) throws {
        guard let value else {
            try store.execute("DELETE FROM user_preferences WHERE key = ?", [.text(key)])
            return
        }
        let data = try PropertyListSerialization.data(fromPropertyList: ["v": value], format: .xml, options: 0)
        try store.execute("""
            INSERT INTO user_preferences (key, value, updated_at) VALUES (?, ?, 1)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """, [.text(key), .text(String(decoding: data, as: UTF8.self))])
    }

    static func runDerivations(_ store: KnowledgeStore) throws {
        for derivation in KnowledgeStore.courseActivationDerivations { try derivation.run(store) }
    }

    /// What the derivations wrote, as text, to compare two runs.
    static func derived(_ store: KnowledgeStore) throws -> String {
        var lines: [String] = []
        for sql in [
            "SELECT id || '=' || COALESCE(created_at, '-') FROM courses ORDER BY id",
            "SELECT id || '=' || lecture_number || ',' || COALESCE(order_key, '-') FROM course_lectures ORDER BY id",
            "SELECT id || '=' || COALESCE(order_key, '-') || ',' || COALESCE(span_slot, '-') || ',' || COALESCE(span_json, '-') FROM course_lecture_items ORDER BY id",
            "SELECT course_id || '=' || status || ',' || COALESCE(focus, '-') FROM course_enrollments ORDER BY course_id",
        ] {
            try store.query(sql, []) { row in lines.append(row.text(0) ?? "") }
        }
        return lines.joined(separator: "\n")
    }

    /// A course as generation 1 leaves one: lectures numbered out of their writing order, a chapter read
    /// in two page ranges, a quiz, and two focus rows (one for a course this Mac does not hold).
    static func generation1Course(_ store: KnowledgeStore) throws {
        try store.execute("INSERT INTO courses (id, title, home_notebook_id) VALUES ('crs-1', 'Systems Biology', 'nb-gone')")
        try store.execute("""
            INSERT INTO course_lectures (id, course_id, lecture_number, title, created_at)
            VALUES ('lec-b', 'crs-1', 2, 'Robustness', 50), ('lec-a', 'crs-1', 1, 'Motifs', 60)
        """)
        for source in ["src-video", "src-chapter"] { try F.addSource(store, source) }
        try store.execute("""
            INSERT INTO source_units (id, source_id, kind, locator, title) VALUES ('su-1', 'src-chapter', 'pages', '3-9', 'Reading'), ('su-2', 'src-chapter', 'pages', '20-31', 'Reading');
        """)
        try store.execute("""
            INSERT INTO course_lecture_items (id, lecture_id, source_id, source_unit_id, role, sort_index, created_at) VALUES
                ('cli-2', 'lec-a', 'src-chapter', 'su-1', 'reading', 1, 71),
                ('cli-1', 'lec-a', 'src-video', NULL, 'video', 0, 70),
                ('cli-3', 'lec-a', 'src-chapter', 'su-2', 'reading', 2, 72)
        """)
        try store.execute("""
            INSERT INTO course_quizzes (id, course_id, kind, title, after_lecture_id, questions_json, created_at, updated_at)
            VALUES ('cq-1', 'crs-1', 'practice', 'Motifs', 'lec-a', '[]', 40, 40)
        """)
        try setPreference(store, "course.focus.crs-1", "The feed-forward loop")
        try setPreference(store, "course.focus.crs-elsewhere", "  For the exam ")
        try setPreference(store, "course.focus.crs-blank", "   ")
    }

    @Test("The activation derives created dates, keys, slots, spans and Enrollments, the same twice, and after generation-1 edits")
    func activationDerives() throws {
        let (root, store) = try F.makeStore("157-derive", triggers: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.generation1Course(store)
        try Self.runDerivations(store)

        #expect(try F.text(store, "SELECT created_at FROM courses WHERE id = 'crs-1'") == "40.0", "its first lecture or quiz dates it")
        var lessons: [String] = []
        try store.query("SELECT id FROM course_lectures ORDER BY order_key", []) { lessons.append($0.text(0) ?? "") }
        #expect(lessons == ["lec-a", "lec-b"], "keys follow lecture_number")
        var items: [String] = []
        try store.query("SELECT id || ':' || span_slot FROM course_lecture_items ORDER BY order_key", []) { items.append($0.text(0) ?? "") }
        #expect(items == ["cli-1:1", "cli-2:1", "cli-3:2"], "keys follow sort_index; the older range of a chapter is its first slot")
        #expect(try F.text(store, "SELECT span_json FROM course_lecture_items WHERE id = 'cli-3'")
                == String(decoding: CourseSyncFixture.pageSpan(19, 30).serialized(), as: UTF8.self))
        #expect(try F.text(store, "SELECT group_concat(course_id || '=' || focus, ',') FROM (SELECT * FROM course_enrollments ORDER BY course_id)")
                == "crs-1=The feed-forward loop,crs-elsewhere=For the exam", "a blank focus is none")
        #expect(try F.text(store, "SELECT home_notebook_id FROM courses WHERE id = 'crs-1'") == "nb-gone", "the retired home is left as it was, unread")
        #expect(try F.count(store, "SELECT COUNT(*) FROM course_quizzes WHERE revision = 1") == 1)

        let first = try Self.derived(store)
        try Self.runDerivations(store)
        #expect(try Self.derived(store) == first, "a second run changes nothing")

        // Generation-1 writes after the first run: a lecture between the two, a focus changed, one removed.
        try store.execute("UPDATE course_lectures SET lecture_number = 3 WHERE id = 'lec-b'")
        try store.execute("INSERT INTO course_lectures (id, course_id, lecture_number, title, created_at) VALUES ('lec-m', 'crs-1', 2, 'Middle', 80)")
        try Self.setPreference(store, "course.focus.crs-1", "Integral feedback")
        try Self.setPreference(store, "course.focus.crs-elsewhere", nil)
        try Self.runDerivations(store)
        lessons = []
        try store.query("SELECT id FROM course_lectures ORDER BY order_key", []) { lessons.append($0.text(0) ?? "") }
        #expect(lessons == ["lec-a", "lec-m", "lec-b"])
        #expect(try F.text(store, "SELECT group_concat(course_id || '=' || COALESCE(focus, '-'), ',') FROM (SELECT * FROM course_enrollments ORDER BY course_id)")
                == "crs-1=Integral feedback,crs-elsewhere=-", "what the rows say now; the Enrollment stays")
    }

    @Test("Under generation 1 a course's focus stays a synced preference row; under generation 2 it is no row")
    func generation1KeepsFocusRows() throws {
        let prefix = LearnerProfile.courseFocusPreferenceKeyPrefix
        #expect(SyncedPreferenceKeys.syncedPrefixes(for: .one).contains(prefix))
        #expect(!SyncedPreferenceKeys.syncedPrefixes(for: .two).contains(prefix), "a focus is an Enrollment field under generation 2")
        #expect(SyncedPreferenceKeys.syncedPrefixes(for: .one) == SyncedPreferenceKeys.syncedPrefixes)
        guard ForeverLMRuntimeIdentity.syncGeneration == .one else { return }
        #expect(!CourseEnrollmentStore.isActive)
        #expect(SyncedPreferenceKeys.isSynced(LearnerProfile.courseFocusPreferenceKey(courseID: "crs-1")))

        // The store writes no Enrollment under generation 1.
        let (root, store) = try F.makeStore("157-gen1-focus", generation: .one)
        defer { try? FileManager.default.removeItem(at: root) }
        try store.setCourseFocus(courseID: "crs-1", focus: "Anything")
        #expect(try F.count(store, "SELECT COUNT(*) FROM course_enrollments") == 0)
    }

    @Test("Under generation 2 the learner's focus is read and written through the Enrollment store")
    func focusIsAnEnrollment() {
        let box = CourseEnrollmentStore.Box(["crs-1": "Motifs"])
        CourseEnrollmentStore.$override.withValue(box) {
            #expect(CourseEnrollmentStore.isActive)
            #expect(LearnerProfile.courseFocus(courseID: "crs-1") == "Motifs")
            #expect(LearnerProfile.setCourseFocus("  Robustness  ", courseID: "crs-1"))
            #expect(box.focus["crs-1"] == "Robustness")
            #expect(LearnerProfile.setCourseFocus("", courseID: "crs-1"))
            #expect(box.focus["crs-1"] == nil)
            #expect(!LearnerProfile.setCourseFocus(String(repeating: "x", count: LearnerProfile.maximumFocusLength + 1), courseID: "crs-1"))
        }
    }
}
