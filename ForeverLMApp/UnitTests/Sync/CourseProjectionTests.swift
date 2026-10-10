import Foundation
import Testing
@testable import ForeverLM

/// The Course, Lesson, lesson Entry, Quiz and Enrollment projections (docs/cloudkit-schema-design.md
/// §3.5.8–§3.5.12, §5.5, §5.7, WP9): a round trip of every field the Mac holds; a course that lives in no
/// notebook; a lesson Entry applied before its Lesson and its Source; a local source delete that cascades
/// the item while the server's Entry stays, and a re-import that projects it again; a course deleted here;
/// the member's Enrollment; a team's course held for its space.
@Suite("Course projection")
struct CourseProjectionTests {
    typealias F = NotebookSyncFixture
    typealias C = CourseSyncFixture

    @Test("A course's rows encode every field the Mac holds, and the records project into the same rows on another Mac")
    func roundTrip() throws {
        let (root, store) = try F.makeStore("crs-round")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try C.addSampleCourse(store)
        let pending = try F.pending(store)

        let course = try #require(F.savedFields(pending["Course:crs-1"]))
        #expect(course["title"] == .string("Systems Biology"))
        #expect(course["provider"] == .string("Weizmann"))
        #expect(course["externalURL"] == .string("https://youtube.com/playlist?list=PL1"))
        #expect(course["status"] == .string("active"))
        #expect(course["policy"] == CourseProjection.policy)
        let created = try #require(try store.scalarText("SELECT created_at FROM courses WHERE id = 'crs-1'").flatMap(Double.init))
        #expect(course["createdAt"] == SyncJSON(SyncTime.milliseconds(cocoaSeconds: created)), "dated when its row was first kept")

        let lesson = try #require(F.savedFields(pending["Lesson:lec-1"]))
        #expect(lesson["courseID"] == .string("crs-1") && lesson["kind"] == .string("lecture") && lesson["title"] == .string("Network motifs"))
        let second = try #require(F.savedFields(pending["Lesson:lec-2"]))
        #expect((lesson["orderKey"]?.stringValue ?? "") < (second["orderKey"]?.stringValue ?? ""), "lecture 1 before lecture 2")

        let video = try #require(F.savedFields(pending["Entry:\(C.lessonEntryID("lec-1", "src-video"))"]))
        #expect(video["containerKind"] == .string("lesson") && video["containerID"] == .string("lec-1"))
        #expect(video["itemKind"] == .string("source") && video["itemID"] == .string("src-video"))
        #expect(video["state"] == .string("active") && video["origin"] == .string("course") && video["role"] == .string("video"))
        let reading = try #require(F.savedFields(pending["Entry:\(C.lessonEntryID("lec-1", "src-chapter"))"]))
        #expect(reading["span"] == C.pageSpan(2, 8), "pages 3–9 are PDF pages 2–8")
        #expect(reading["label"] == .string("Read first"))
        #expect(F.savedFields(pending["Entry:\(C.lessonEntryID("lec-1", "src-chapter", slot: 2))"])?["span"] == C.pageSpan(19, 30))

        let quiz = try #require(F.savedFields(pending["Quiz:cq-1"]))
        #expect(quiz["courseID"] == .string("crs-1") && quiz["lessonID"] == .string("lec-1"))
        #expect(quiz["coversLessonIDs"] == .object(["lec-1": .bool(true)]))
        #expect(quiz["kind"] == .string("practice") && quiz["revision"] == SyncJSON(1) && quiz["questionCount"] == SyncJSON(1))
        #expect(quiz["author"] == .string("foreverlm") && quiz["symbol"] == .string("atom"))
        let questions = try #require(quiz["questions"].flatMap(FileRef.init(json:)))
        #expect(questions.owner == "cq-1" && questions.role == "questions" && questions.encoding == "gzip")
        let heldQuestions = try #require(try F.text(store, "SELECT questions_json FROM course_quizzes WHERE id = 'cq-1'"))
        #expect(questions.hash == SyncIdentity.sha256Hex(Data(heldQuestions.utf8)))
        #expect((quiz["pictures"]?.objectValue ?? [:]).isEmpty, "no drawing yet")

        // Another Mac holds the sources and nothing of the course, and projects every record.
        let (otherRoot, other) = try F.makeStore("crs-round-other")
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        try F.prepareReplica(other)
        for source in ["src-video", "src-chapter", "src-video-2"] { try F.addSource(other, source) }
        try F.sendAll(other)
        var records: [ReplicaRecord] = []
        for (key, change) in pending where !key.hasPrefix("Source:") {
            records.append(try OutboxTestProjections.serverRecord(for: change))
        }
        try F.apply(other, records)
        #expect(try F.text(other, "SELECT title || '|' || institution || '|' || playlist_url || '|' || is_hidden FROM courses WHERE id = 'crs-1'")
                == "Systems Biology|Weizmann|https://youtube.com/playlist?list=PL1|0")
        #expect(try F.text(other, "SELECT group_concat(id || ':' || lecture_number || ':' || title, ',') FROM (SELECT * FROM course_lectures ORDER BY lecture_number)")
                == "lec-1:1:Network motifs,lec-2:2:Robustness")
        #expect(try F.count(other, "SELECT COUNT(*) FROM course_lecture_items WHERE lecture_id = 'lec-1'") == 3)
        #expect(try F.text(other, """
            SELECT group_concat(source_id || ':' || role || ':' || COALESCE(span_slot, 1) || ':' || COALESCE(locator, '-'), ',')
            FROM (SELECT i.*, u.locator FROM course_lecture_items i LEFT JOIN source_units u ON u.id = i.source_unit_id
                  WHERE i.lecture_id = 'lec-1' ORDER BY i.sort_index) AS i
        """) == "src-video:video:1:-,src-chapter:reading:1:3-9,src-chapter:reading:2:20-31", "the order, the slots and the page units come back")
        #expect(try F.text(other, "SELECT questions_json FROM course_quizzes WHERE id = 'cq-1'") == "[]", "the questions wait for their satellite")
        #expect(try F.count(other, "SELECT COUNT(*) FROM ck_backfill_queue WHERE kind = 'quizSatellites' AND target = 'cq-1'") == 1)
        #expect(try F.pending(other).isEmpty, "an apply sends nothing back")
    }

    @Test("A lesson Entry whose pages are already a unit under another id uses that unit and does not throw")
    func pageUnitHeldUnderAnotherID() throws {
        let (root, store) = try F.makeStore("crs-unit-taken")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try C.addCourse(store, "crs-1")
        try C.addLecture(store, "lec-1", course: "crs-1", number: 1)
        try F.addSource(store, "src-chapter")
        // Pages 3 to 9 as the learner counts them are PDF pages 2 to 8.
        let unit = LessonItemSpan.pageUnit(sourceID: "src-chapter", pages: 3...9)
        try store.execute("INSERT INTO source_units (id, source_id, kind, locator, title) VALUES ('older-unit', 'src-chapter', ?, ?, NULL)",
                          [.text(LessonItemSpan.pageUnitKind), .text(unit.locator)])
        try F.apply(store, [try C.lessonEntryRecord("lec-1", "src-chapter", span: C.pageSpan(2, 8))])
        #expect(try F.text(store, "SELECT source_unit_id FROM course_lecture_items WHERE lecture_id = 'lec-1' AND source_id = 'src-chapter'") == "older-unit")
        #expect(try F.count(store, "SELECT COUNT(*) FROM source_units WHERE source_id = 'src-chapter'") == 1)
    }

    @Test("A course lives in no notebook: no home is sent or projected, and the notebook's follow Entry is the one tie")
    func courseLivesInNoNotebook() throws {
        let (root, store) = try F.makeStore("crs-no-home")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-1")
        try C.addCourse(store, "crs-1", homeNotebook: "nb-1")
        try store.execute("INSERT INTO notebook_course_links (goal_id, course_id) VALUES ('nb-1', 'crs-1')")
        let pending = try F.pending(store)
        let course = try #require(F.savedFields(pending["Course:crs-1"]))
        #expect(course["notebookID"] == nil && course["homing"] == nil, "the retired home is never sent")
        let follow = try #require(F.savedFields(pending["Entry:\(SyncIdentity.entryID(containerID: "nb-1", itemKind: "course", itemID: "crs-1"))"]))
        #expect(follow["containerKind"] == .string("notebook") && follow["itemKind"] == .string("course") && follow["state"] == .string("active"))
        try F.sendAll(store)

        // Another client's home stays in the replica and touches no row.
        try F.apply(store, [try Self.courseHoldingRetiredHome("crs-1", notebook: "nb-1")])
        #expect(try F.text(store, "SELECT home_notebook_id FROM courses WHERE id = 'crs-1'") == "nb-1", "written by generation 1, never read or written again")
        try F.apply(store, [try Self.courseHoldingRetiredHome("crs-2", notebook: "nb-1")])
        #expect(try F.text(store, "SELECT COALESCE(home_notebook_id, '-') FROM courses WHERE id = 'crs-2'") == "-")
        #expect(try F.held(store, .course, "crs-2")?.fields["notebookID"] == .string("nb-1"), "kept for the client that wrote it")
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_notebook_children WHERE child_type = 'Course'") == 0)
    }

    /// Another client's Course that still carries the retired `notebookID`. `notebookID` and `homing`
    /// are reserved since spec revision 9, so no RecordPatch can name them; the key is set on the
    /// envelope directly, with the title's stamp, as an older writer would have sent it.
    static func courseHoldingRetiredHome(_ id: String, notebook: String) throws -> ReplicaRecord {
        var record = try C.courseRecord(id)
        var envelope = try SyncEnvelope(storedPayload: record.payload)
        envelope.fields["notebookID"] = .string(notebook)
        envelope.stamps["notebookID"] = envelope.stamps["title"]
        record.payload = try envelope.storedPayload()
        return record
    }

    @Test("A lesson Entry applied before its Lesson and its Source waits for both, then projects")
    func lessonEntryBeforeLessonAndSource() throws {
        let (root, store) = try F.makeStore("crs-order")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.apply(store, [try C.lessonEntryRecord("lec-9", "src-a", orderKey: "a1", span: C.pageSpan(0, 4))])
        #expect(try F.count(store, "SELECT COUNT(*) FROM course_lecture_items") == 0)
        #expect(try F.count(store, """
            SELECT COUNT(*) FROM ck_unprojected WHERE (waiting_on_type = 'Lesson' AND waiting_on_id = 'lec-9') OR (waiting_on_type = 'Source' AND waiting_on_id = 'src-a')
        """) == 2)

        // The Lesson before its Course waits too; the Course frees it, and the Entry still waits for its source.
        try F.apply(store, [try C.lessonRecord("lec-9", course: "crs-9", orderKey: "a0")])
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_unprojected WHERE waiting_on_type = 'Course' AND waiting_on_id = 'crs-9'") == 1)
        try F.apply(store, [try C.courseRecord("crs-9")])
        #expect(try F.count(store, "SELECT COUNT(*) FROM course_lectures WHERE id = 'lec-9' AND course_id = 'crs-9' AND lecture_number = 1") == 1)
        #expect(try F.count(store, "SELECT COUNT(*) FROM course_lecture_items") == 0)
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_unprojected WHERE waiting_on_type = 'Source' AND waiting_on_id = 'src-a'") == 1)

        // The source arrives by a local import: its readiness frees the Entry.
        try F.addSource(store, "src-a")
        #expect(try store.drainReadyProjections() > 0)
        #expect(try F.count(store, """
            SELECT COUNT(*) FROM course_lecture_items i JOIN source_units u ON u.id = i.source_unit_id
            WHERE i.lecture_id = 'lec-9' AND i.source_id = 'src-a' AND i.order_key = 'a1' AND u.locator = '1-5'
        """) == 1)
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_unprojected") == 0)
        #expect(try F.pending(store).values.allSatisfy { $0.recordType == .source }, "only the local source is new here")
    }

    @Test("A source deleted here cascades its lesson item while the server's Entry stays, and a re-import projects it again")
    func sourceDeleteKeepsLessonEntry() throws {
        let (root, store) = try F.makeStore("crs-source-delete")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try C.addSampleCourse(store)
        try F.sendAll(store)
        let entryID = C.lessonEntryID("lec-2", "src-video-2")
        let held = try #require(try F.held(store, .entry, entryID))
        #expect(held.fields["state"] == .string("active"))

        try store.deleteSourceRows("src-video-2")
        #expect(try F.count(store, "SELECT COUNT(*) FROM course_lecture_items WHERE source_id = 'src-video-2'") == 0, "the foreign key cascades the item")
        #expect(try F.pending(store)["Entry:\(entryID)"] == nil, "the Entry is not written")
        try F.sendAll(store)
        #expect(try F.held(store, .entry, entryID)?.fields == held.fields, "the server's Entry stays as it was")
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_unprojected WHERE waiting_on_type = 'Source' AND waiting_on_id = 'src-video-2'") == 1)

        try F.addSource(store, "src-video-2")
        #expect(try store.drainReadyProjections() == 1)
        #expect(try F.text(store, "SELECT role || ':' || order_key FROM course_lecture_items WHERE lecture_id = 'lec-2' AND source_id = 'src-video-2'")
                == "video:" + (held.fields["orderKey"]?.stringValue ?? "?"))
        #expect(try F.pending(store)["Entry:\(entryID)"] == nil, "projected back as it was, so nothing to send")
    }

    @Test("A course deleted here deletes its Lessons, Quizzes and lesson Entries, and the member's Enrollment stays")
    func courseDelete() throws {
        let (root, store) = try F.makeStore("crs-delete")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try C.addSampleCourse(store)
        try store.setCourseFocus(courseID: "crs-1", focus: "The feed-forward loop")
        try F.sendAll(store)
        // As `deleteCourseGroup` deletes them.
        try store.execute("DELETE FROM course_lecture_items WHERE lecture_id IN (SELECT id FROM course_lectures WHERE course_id = 'crs-1')")
        try store.execute("DELETE FROM course_lectures WHERE course_id = 'crs-1'")
        try store.execute("DELETE FROM courses WHERE id = 'crs-1'")
        try store.execute("DELETE FROM course_quizzes WHERE course_id = 'crs-1'")
        let pending = try F.pending(store)
        for key in ["Course:crs-1", "Lesson:lec-1", "Lesson:lec-2", "Quiz:cq-1", "Entry:\(C.lessonEntryID("lec-1", "src-chapter", slot: 2))"] {
            if case .delete? = pending[key]?.action {} else { Issue.record("\(key) is not deleted") }
        }
        #expect(pending["Enrollment:enr:crs-1"] == nil)
        #expect(try F.count(store, "SELECT COUNT(*) FROM course_enrollments WHERE course_id = 'crs-1'") == 1)
    }

    @Test("The member's Enrollment round-trips, and an inbound one writes the row")
    func enrollment() throws {
        let (root, store) = try F.makeStore("crs-enrollment")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try store.setCourseFocus(courseID: "crs-1", focus: "  Robustness, for my thesis ")
        let fields = try #require(F.savedFields(try F.pending(store)["Enrollment:enr:crs-1"]))
        #expect(fields["courseID"] == .string("crs-1") && fields["status"] == .string("enrolled"))
        #expect(fields["focus"] == .string("Robustness, for my thesis"))
        try F.sendAll(store)
        try store.setCourseFocus(courseID: "crs-1", focus: "")
        #expect(F.savedFields(try F.pending(store)["Enrollment:enr:crs-1"])?["focus"] == .null, "a blank focus clears it")
        #expect(try F.count(store, "SELECT COUNT(*) FROM course_enrollments WHERE course_id = 'crs-1'") == 1, "and keeps the Enrollment")
        try store.setCourseFocus(courseID: "crs-2", focus: "")
        #expect(try F.count(store, "SELECT COUNT(*) FROM course_enrollments WHERE course_id = 'crs-2'") == 0, "no Enrollment from nothing")

        try F.apply(store, [try F.record(.enrollment, "enr:crs-3", [
            "courseID": .string("crs-3"), "status": .string("paused"), "focus": .string("Later"), "pace": .object(["lessonsPerWeek": SyncJSON(2)]),
        ])])
        #expect(try F.text(store, "SELECT status || '|' || focus || '|' || pace_json FROM course_enrollments WHERE course_id = 'crs-3'")
                == #"paused|Later|{"lessonsPerWeek":2}"#)
        #expect(try store.courseFocusSnapshot() == ["crs-3": "Later"])
    }

    @Test("A team's course, its lessons, items and quizzes wait for their space instead of going to Library")
    func teamCourseWaitsForItsSpace() throws {
        let (root, store) = try F.makeStore("crs-team")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try store.execute("""
            INSERT INTO teams (id, name, role, permission, zone_scope, zone_name, created_at, joined_at, updated_at)
            VALUES ('team-1', 'Lab', 'owner', 'readWrite', 'private', 'Team-team-1', 1, 1, 1)
        """)
        try store.execute("INSERT INTO courses (id, title, team_id) VALUES ('crs-t', 'Team course', 'team-1')")
        try store.deriveWireIDs()
        try C.addLecture(store, "lec-t", course: "crs-t", number: 1)
        try F.addSource(store, "src-t")
        try C.addItem(store, "cli-t", lecture: "lec-t", source: "src-t", sortIndex: 0)
        try C.addQuiz(store, "cq-t", course: "crs-t", after: "lec-t", covers: ["lec-t"])
        let zone = "private/Space-team-1"
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_identity WHERE zone_key = ? AND record_type IN ('Course', 'Lesson', 'Quiz', 'Entry')", [.text(zone)]) == 4)
        let pending = try F.pending(store)
        #expect(pending.keys.filter { !$0.hasPrefix("Source:") }.isEmpty, "nothing of the team's course goes into the personal library")
    }
}
