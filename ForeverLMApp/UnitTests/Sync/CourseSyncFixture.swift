import Foundation
import Testing
@testable import ForeverLM

/// Courses, lectures, items and quizzes for WP9's suites (docs/cloudkit-schema-design.md §3.5.8–§3.5.12),
/// written as generation 1's writers leave their rows and then kept as a generation-2 write keeps them
/// (`keepCourseRowsForGeneration2`), on `NotebookSyncFixture`'s generation-2 store and replica. It reads
/// nothing but the store, the replica and the feeder, so the suites built on it also run standalone.
enum CourseSyncFixture {
    typealias F = NotebookSyncFixture

    static func addCourse(_ store: KnowledgeStore, _ id: String, title: String = "Systems Biology", institution: String? = "Weizmann",
                          playlist: String? = "https://youtube.com/playlist?list=PL1", homeNotebook: String? = nil) throws {
        try store.execute(
            "INSERT INTO courses (id, title, institution, playlist_url, home_notebook_id) VALUES (?, ?, ?, ?, ?)",
            [.text(id), .text(title), .text(institution), .text(playlist), .text(homeNotebook)]
        )
        try store.keepCourseRowsForGeneration2(courseIDs: [id])
    }

    static func addLecture(_ store: KnowledgeStore, _ id: String, course: String, number: Int, title: String? = nil, createdAt: Double = 100) throws {
        try store.execute(
            "INSERT INTO course_lectures (id, course_id, lecture_number, title, created_at) VALUES (?, ?, ?, ?, ?)",
            [.text(id), .text(course), .integer(Int64(number)), .text(title ?? "Lecture \(id)"), .real(createdAt)]
        )
        try store.keepCourseRowsForGeneration2(courseIDs: [course])
    }

    /// A lecture item; with `pages`, a textbook reading of those pages (one-based, inclusive) through its
    /// page unit, as `replaceTextbookReadings` writes one.
    static func addItem(_ store: KnowledgeStore, _ id: String, lecture: String, source: String, role: String = "video", label: String? = nil,
                        sortIndex: Int, pages: ClosedRange<Int>? = nil, createdAt: Double = 200) throws {
        var unit: String?
        if let pages {
            let page = LessonItemSpan.pageUnit(sourceID: source, pages: pages)
            try store.execute("""
                INSERT INTO source_units (id, source_id, kind, locator, title) VALUES (?, ?, 'pages', ?, 'Reading')
                ON CONFLICT(id) DO NOTHING
            """, [.text(page.id), .text(source), .text(page.locator)])
            unit = page.id
        }
        try store.execute("""
            INSERT INTO course_lecture_items (id, lecture_id, source_id, source_unit_id, role, label, sort_index, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, [.text(id), .text(lecture), .text(source), .text(unit), .text(role), .text(label), .integer(Int64(sortIndex)), .real(createdAt)])
        try keep(store, lecture: lecture)
    }

    static func addQuiz(_ store: KnowledgeStore, _ id: String, course: String, after lecture: String?, covers: [String], kind: String = "practice",
                        title: String = "Motifs", questions: String = #"[{"id":"q1","question":"What is a motif?","answer":"A recurring circuit","keyPoints":[]}]"#,
                        author: String = "foreverlm", artwork: Data? = nil) throws {
        let lectures = String(decoding: SyncJSON.array(covers.map(SyncJSON.string)).serialized(), as: UTF8.self)
        try store.execute("""
            INSERT INTO course_quizzes (id, course_id, kind, title, lecture_ids_json, after_lecture_id, questions_json, author, created_at, updated_at, symbol, artwork)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 300, 300, 'atom', ?)
        """, [.text(id), .text(course), .text(kind), .text(title), .text(lectures), .text(lecture), .text(questions), .text(author), .blob(artwork)])
        try store.keepCourseRowsForGeneration2(courseIDs: [course])
    }

    /// Keeps a lecture's course as a generation-2 write does after writing its rows.
    static func keep(_ store: KnowledgeStore, lecture: String) throws {
        if let course = try F.text(store, "SELECT course_id FROM course_lectures WHERE id = ?", [.text(lecture)]) {
            try store.keepCourseRowsForGeneration2(courseIDs: [course])
        }
    }

    /// A course of two lectures: the first holds a video and two page ranges of one chapter, the second
    /// a video; a practice quiz follows the first lecture.
    static func addSampleCourse(_ store: KnowledgeStore) throws {
        try addCourse(store, "crs-1")
        try addLecture(store, "lec-1", course: "crs-1", number: 1, title: "Network motifs", createdAt: 100)
        try addLecture(store, "lec-2", course: "crs-1", number: 2, title: "Robustness", createdAt: 110)
        for source in ["src-video", "src-chapter", "src-video-2"] { try F.addSource(store, source) }
        try addItem(store, "cli-1", lecture: "lec-1", source: "src-video", sortIndex: 0, createdAt: 201)
        try addItem(store, "cli-2", lecture: "lec-1", source: "src-chapter", role: "reading", label: "Read first", sortIndex: 1, pages: 3...9, createdAt: 202)
        try addItem(store, "cli-3", lecture: "lec-1", source: "src-chapter", role: "reading", sortIndex: 2, pages: 20...31, createdAt: 203)
        try addItem(store, "cli-4", lecture: "lec-2", source: "src-video-2", sortIndex: 0, createdAt: 204)
        try addQuiz(store, "cq-1", course: "crs-1", after: "lec-1", covers: ["lec-1"])
    }

    static func lessonEntryID(_ lecture: String, _ source: String, slot: Int = 1) -> String {
        SyncIdentity.entryID(containerID: lecture, itemKind: "source", itemID: source, span: slot)
    }

    /// The Entry of a lesson's item as another device writes one.
    static func lessonEntryRecord(_ lecture: String, _ source: String, slot: Int = 1, state: String = "active", role: String = "reading",
                                  orderKey: String = "a0", span: SyncJSON? = nil, label: String? = nil, ms: Int64 = 1_759_400_000_000) throws -> ReplicaRecord {
        var fields: [String: SyncJSON] = [
            "containerKind": .string("lesson"), "containerID": .string(lecture), "itemKind": .string("source"), "itemID": .string(source),
            "state": .string(state), "orderKey": .string(orderKey), "origin": .string("course"), "role": .string(role),
            "addedAt": SyncJSON(Int64(1_759_000_000_000)),
        ]
        if let span { fields["span"] = span }
        if let label { fields["label"] = .string(label) }
        return try F.record(.entry, lessonEntryID(lecture, source, slot: slot), fields, ms: ms)
    }

    static func courseRecord(_ id: String, title: String = "Systems Biology", extra: [String: SyncJSON] = [:]) throws -> ReplicaRecord {
        var fields: [String: SyncJSON] = [
            "title": .string(title), "status": .string("active"), "policy": CourseProjection.policy,
            "createdAt": SyncJSON(Int64(1_758_000_000_000)),
        ]
        fields.merge(extra) { _, new in new }
        return try F.record(.course, id, fields)
    }

    static func lessonRecord(_ id: String, course: String, orderKey: String, title: String = "A lesson", ms: Int64 = 1_759_400_000_000) throws -> ReplicaRecord {
        try F.record(.lesson, id, [
            "courseID": .string(course), "orderKey": .string(orderKey), "kind": .string("lecture"), "title": .string(title),
            "createdAt": SyncJSON(Int64(1_758_000_000_000)),
        ], ms: ms)
    }

    /// A span of 0-based PDF pages, as the wire holds one.
    static func pageSpan(_ first: Int, _ last: Int) -> SyncJSON {
        LocatorSpan(from: Locator(.pdf, ["page": SyncJSON(first)]), to: Locator(.pdf, ["page": SyncJSON(last)])).value
    }
}
