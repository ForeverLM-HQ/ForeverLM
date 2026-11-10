import Testing
import Foundation
import SQLite3
@testable import ForeverLM

@MainActor
private func makeCoursePersistenceHarness() -> (StudioViewModel, StorageService, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CoursePersistenceTests_\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let service = StorageService(storeRoot: root)
    return (StudioViewModel(storageService: service), service, root)
}

@Suite("Course Persistence")
@MainActor
struct CoursePersistenceTests {

    @Test("Course metadata round-trips playlist URL through SQLite")
    func playlistURLRoundTrip() async throws {
        let (_, service, root) = makeCoursePersistenceHarness()
        defer { try? FileManager.default.removeItem(at: root) }

        let metadata = CourseMetadata(
            courseCode: "6.S184",
            title: "Flow Matching and Diffusion Models",
            institution: "MIT",
            instructors: "Peter Holderrieth",
            playlistURL: "https://www.youtube.com/playlist?list=PL-flow"
        )

        try await service.saveCourseGroup(name: "MIT: FlowMatching Diffusion", metadata: metadata)
        let loaded = try await service.loadCourseMetadata()

        #expect(loaded["MIT: FlowMatching Diffusion"] == metadata)
    }

    @Test("Hidden course setting persists through SQLite")
    func hiddenCourseRoundTrip() async throws {
        let (_, service, root) = makeCoursePersistenceHarness()
        defer { try? FileManager.default.removeItem(at: root) }

        var metadata = CourseMetadata(title: "Mechanistic Interpretability")
        metadata.isHidden = true

        try await service.saveCourseGroup(name: "Mech Interp", metadata: metadata)
        let loaded = try await service.loadCourseMetadata()

        #expect(loaded["Mech Interp"]?.isHidden == true)
    }

    @Test("Creating an empty course persists metadata without assuming lecture one")
    func emptyCoursePersists() async throws {
        let (vm, service, root) = makeCoursePersistenceHarness()
        defer { try? FileManager.default.removeItem(at: root) }

        let courseName = "Systems Biology of Aging & Longevity"
        await vm.createCourse(name: courseName)

        let loaded = try await service.loadCourseMetadata()
        #expect(loaded.values.contains(where: { $0.title == courseName }))

        let lectures = try await service.loadCourseLectures()
        #expect(lectures.isEmpty)
    }

    @Test("Course lecture rename persists to SQLite")
    func courseLectureRenamePersists() async throws {
        let (vm, service, root) = makeCoursePersistenceHarness()
        defer { try? FileManager.default.removeItem(at: root) }

        let courseName = "Systems Biology"
        guard let lecture = await vm.createLecture(in: courseName) else {
            Issue.record("Expected lecture to be created")
            return
        }

        await vm.renameCourseLecture(lecture.id, title: "Feedback Loops")

        let loadedLectures = try await service.loadCourseLectures()
        #expect(loadedLectures.first(where: { $0.id == lecture.id })?.title == "Feedback Loops")
    }

    @Test("Clearing metadata fields does not delete the course group")
    func clearingMetadataKeepsCourseGroup() async throws {
        let (vm, service, root) = makeCoursePersistenceHarness()
        defer { try? FileManager.default.removeItem(at: root) }

        let courseName = "MIT: FlowMatching Diffusion"
        await vm.createCourse(name: courseName)

        await vm.updateCourseMetadata(groupName: courseName) { $0.title = "Flow Matching and Diffusion Models" }

        await vm.updateCourseMetadata(groupName: courseName) { $0.title = nil }

        let loaded = try await service.loadCourseMetadata()
        #expect(loaded.keys.contains(courseName))
    }

    @Test("Course lectures can attach arbitrary source materials")
    func courseLectureMaterialsPersist() async throws {
        let (_, service, root) = makeCoursePersistenceHarness()
        defer { try? FileManager.default.removeItem(at: root) }

        let courseName = "Systems Biology"
        try await service.saveCourseGroup(name: courseName, metadata: CourseMetadata())

        var article = StudioArticle(
            url: "https://example.com/systems-biology-reading",
            title: "Oscillators in Biology",
            sourceType: .article
        )
        _ = try await service.insertSourceIfNew(&article)

        let lecture = CourseSession(courseName: courseName, number: 1, title: "Feedback Loops")
        let item = CourseLectureItem(
            lectureId: lecture.id,
            sourceId: article.id,
            role: .reading,
            sortIndex: 0
        )

        try await service.saveCourseOutline(courseName: courseName, lectures: [lecture], items: [item])

        let loadedLectures = try await service.loadCourseLectures()
        let loadedItems = try await service.loadCourseLectureItems()

        #expect(loadedLectures == [lecture])
        #expect(loadedItems == [item])
    }

    @Test("Unassigned course sources remain visible as course materials")
    func unassignedCourseSourcesRemainVisibleAsMaterials() {
        let (vm, _, root) = makeCoursePersistenceHarness()
        defer { try? FileManager.default.removeItem(at: root) }

        let courseName = "Language Modeling from Scratch"
        let lecture = CourseSession(id: "lecture-1", courseName: courseName, number: 1)
        let video = StudioArticle(
            url: "https://example.com/lecture-1",
            title: "Overview, Tokenization",
            sourceType: .video,
            parentGroup: courseName,
            id: "video-1"
        )
        let assignment = StudioArticle(
            url: "https://example.com/assignment-1",
            title: "Assignment 1: Basics",
            sourceType: .course,
            parentGroup: courseName,
            id: "assignment-1"
        )

        vm.articles = [video, assignment]
        vm.courseLecturesByCourse[courseName] = [lecture]
        vm.courseLectureItemsByLectureId[lecture.id] = [
            CourseLectureItem(
                id: "video-item",
                lectureId: lecture.id,
                sourceId: video.id,
                role: .video
            ),
        ]

        #expect(vm.unassignedCourseArticles(for: courseName).map(\.id) == [assignment.id])
    }

    @Test("Course membership index refreshes after lecture associations change")
    func courseMembershipIndexRefreshesAfterAssociationChanges() {
        let (vm, _, root) = makeCoursePersistenceHarness()
        defer { try? FileManager.default.removeItem(at: root) }

        let courseName = "Dynamic Systems"
        let linkedSource = StudioArticle(
            url: "https://example.com/paper",
            title: "Linked Paper",
            sourceType: .paper,
            id: "linked-paper"
        )
        let lecture = CourseSession(id: "lecture-1", courseName: courseName, number: 1)

        vm.articles = [linkedSource]
        vm.courseMetadata[courseName] = CourseMetadata(title: courseName)
        #expect(vm.courseGroupIDs(for: linkedSource).isEmpty)

        vm.courseLecturesByCourse[courseName] = [lecture]
        vm.courseLectureItemsByLectureId[lecture.id] = [
            CourseLectureItem(
                id: "paper-item",
                lectureId: lecture.id,
                sourceId: linkedSource.id,
                role: .reading
            ),
        ]
        #expect(vm.courseGroupIDs(for: linkedSource) == [courseName])

        vm.courseLectureItemsByLectureId[lecture.id] = []
        #expect(vm.courseGroupIDs(for: linkedSource).isEmpty)
    }

    @Test("Linked courses keep adding new sources to their Notebook")
    func linkedCourseKeepsAddingSourcesToNotebook() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkedCourseNotebookTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try KnowledgeStore(storeDirectory: root)
        let courseID = "systems-biology"
        try store.saveCourseGroup(
            name: courseID,
            metadata: CourseMetadata(title: "Systems Biology")
        )

        let initialSource = StudioArticle(
            url: "https://example.com/lecture-1",
            title: "Lecture 1",
            sourceType: .video,
            id: "lecture-1"
        )
        try store.saveSource(initialSource)
        let lecture = CourseSession(id: "lecture", courseName: courseID, number: 1)
        try store.saveCourseOutline(
            courseName: courseID,
            lectures: [lecture],
            items: [
                CourseLectureItem(
                    id: "initial-item",
                    lectureId: lecture.id,
                    sourceId: initialSource.id,
                    role: .video
                ),
            ]
        )

        let now = Date()
        let notebook = try store.createCompanionGoal(
            title: "Cellular Systems",
            topic: "Cellular Systems",
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )
        #expect(
            try store.linkCourseToNotebook(
                goalID: notebook.id,
                courseID: courseID,
                sourceIDs: []
            ) == 1
        )
        #expect(try store.linkedCourseIDsForNotebook(goalID: notebook.id) == [courseID])
        #expect(try store.loadLearningGoal(notebook.id)?.approvedSourceIDs == [initialSource.id])

        try store.removeCompanionSources(goalID: notebook.id, sourceIDs: [initialSource.id])
        try store.saveCourseOutline(
            courseName: courseID,
            lectures: [lecture],
            items: [
                CourseLectureItem(
                    id: "initial-item",
                    lectureId: lecture.id,
                    sourceId: initialSource.id,
                    role: .video
                ),
            ]
        )
        #expect(try store.loadLearningGoal(notebook.id)?.approvedSourceIDs.isEmpty == true)

        let laterSource = StudioArticle(
            url: "https://example.com/lecture-2-slides",
            title: "Lecture 2 slides",
            sourceType: .course,
            id: "lecture-2-slides"
        )
        try store.saveSource(laterSource)
        try store.saveCourseLectureItem(
            CourseLectureItem(
                id: "later-item",
                lectureId: lecture.id,
                sourceId: laterSource.id,
                role: .slides,
                sortIndex: 1
            )
        )

        let reloadedNotebook = try store.loadLearningGoal(notebook.id)
        #expect(reloadedNotebook?.approvedSourceIDs == [laterSource.id])
        #expect(
            reloadedNotebook?.items.first(where: { $0.sourceID == initialSource.id })?.reviewState
                == LearningGoalItemReviewState.rejected.rawValue
        )

        let groupedSource = StudioArticle(
            url: "Courses/systems-biology/problem-set.pdf",
            title: "Problem set",
            sourceType: .course,
            parentGroup: courseID,
            id: "problem-set"
        )
        try store.saveSource(groupedSource)
        #expect(
            try store.loadLearningGoal(notebook.id)?.approvedSourceIDs
                == [laterSource.id, groupedSource.id]
        )
        #expect(try store.linkedCourseIDsForNotebook(goalID: notebook.id) == [courseID])

        try store.deleteCourseGroup(name: courseID)
        #expect(try store.linkedCourseIDsForNotebook(goalID: notebook.id).isEmpty)
        #expect(
            try store.loadLearningGoal(notebook.id)?.approvedSourceIDs
                == [laterSource.id, groupedSource.id]
        )
    }

    @Test("Archived course sources cannot return to a Notebook through sync ordering")
    func archivedCourseSourcesStayOutOfNotebooks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchivedCourseNotebookTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try KnowledgeStore(storeDirectory: root)
        let courseID = "archived-course"
        try store.saveCourseGroup(name: courseID, metadata: CourseMetadata(title: "Archived Course"))

        var source = StudioArticle(
            url: "https://example.com/archived-course-source",
            title: "Archived Course Source",
            sourceType: .course,
            parentGroup: courseID,
            id: "archived-course-source"
        )
        try store.saveSource(source)

        let now = Date()
        let notebook = try store.createCompanionGoal(
            title: "Archive Ordering",
            topic: "Archive Ordering",
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )
        _ = try store.linkCourseToNotebook(goalID: notebook.id, courseID: courseID, sourceIDs: [])
        let staleGoal = try #require(try store.loadLearningGoal(notebook.id))
        #expect(staleGoal.approvedSourceIDs == [source.id])

        try store.archiveSource(source.id)
        #expect(try store.sourceIDsForCourse(courseID).isEmpty)
        #expect(try store.loadLearningGoal(notebook.id)?.approvedSourceIDs.isEmpty == true)

        // A stale Learning Goal record arriving after the archived Source must
        // not restore the relationship.
        try store.saveLearningGoalRecord(
            CloudKitLearningGoalPayload(
                goal: staleGoal,
                linkedCourseIDs: [courseID]
            )
        )
        #expect(try store.loadLearningGoal(notebook.id)?.approvedSourceIDs.isEmpty == true)

        // Nor may the archived Source arriving after the Notebook's course link
        // rematerialize itself through group membership.
        source.status = .archived
        source.archivedAt = now
        try store.saveSource(source)
        #expect(try store.loadLearningGoal(notebook.id)?.approvedSourceIDs.isEmpty == true)
    }

    @Test("Older Learning Goal payloads preserve course links while an explicit empty list clears them")
    func learningGoalSyncCourseLinkCompatibility() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseLinkSyncTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try KnowledgeStore(storeDirectory: root)
        let now = Date()
        let notebook = try store.createCompanionGoal(
            title: "Physics",
            topic: "Physics",
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )
        try store.saveCourseGroup(name: "physics-course", metadata: CourseMetadata(title: "Physics"))
        _ = try store.linkCourseToNotebook(
            goalID: notebook.id,
            courseID: "physics-course",
            sourceIDs: []
        )

        let legacyPayload = CloudKitLearningGoalPayload(
            goal: try #require(try store.loadLearningGoal(notebook.id)),
            sourceIdentities: []
        )
        try store.saveLearningGoalRecord(legacyPayload)
        #expect(try store.linkedCourseIDsForNotebook(goalID: notebook.id) == ["physics-course"])

        let clearingPayload = CloudKitLearningGoalPayload(
            goal: try #require(try store.loadLearningGoal(notebook.id)),
            sourceIdentities: [],
            linkedCourseIDs: []
        )
        try store.saveLearningGoalRecord(clearingPayload)
        #expect(try store.linkedCourseIDsForNotebook(goalID: notebook.id).isEmpty)
    }

    @Test("Archived video lectures still provide course artwork")
    func archivedVideoProvidesCourseArtwork() async throws {
        let (_, service, root) = makeCoursePersistenceHarness()
        defer { try? FileManager.default.removeItem(at: root) }

        let courseName = "Systems Medicine"
        try await service.saveCourseGroup(name: courseName, metadata: CourseMetadata())

        var video = StudioArticle(
            url: "https://www.youtube.com/watch?v=a7DvXjUp7cE",
            title: "The insulin-glucose circuit",
            sourceType: .video
        )
        _ = try await service.insertSourceIfNew(&video)

        let lecture = CourseSession(courseName: courseName, number: 1)
        let item = CourseLectureItem(
            lectureId: lecture.id,
            sourceId: video.id,
            role: .video,
            sortIndex: 0
        )
        try await service.saveCourseOutline(courseName: courseName, lectures: [lecture], items: [item])
        try await service.archiveSource(video.id)

        let artworkURLs = try await service.loadCourseArtworkURLs()
        #expect(artworkURLs[courseName] == "https://img.youtube.com/vi/a7DvXjUp7cE/mqdefault.jpg")
    }

}

/// A production-shaped pre-v73 database carrying the state a removed course used
/// to leave behind: `source_type = 'course'` rows attached to no course at all.
/// Only the tables version 73 reads are hand-installed here, in their released
/// shape, plus version 72's own tables when the fixture is stamped 72; the schema
/// installer creates the rest. This deliberately does not create today's schema
/// and lower `user_version`.
///
/// `orphanCount` course sources have no attachment of any kind, plus one whose
/// group membership names a course that is gone entirely — equally unreachable.
/// The rows that must survive untouched: material in an existing course by
/// membership, by lecture item, and by a lecture item naming one of its units;
/// material in a course the sidebar derives from its lectures alone; a course
/// source already hidden; an archived one; and an article.
private func createCourselessCourseSourceFixture(
    at root: URL,
    orphanCount: Int,
    stampedVersion: Int32 = 71,
    refuseHiding: Bool = false
) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let dbPath = root.appendingPathComponent("knowledge.db").path
    var database: OpaquePointer?
    guard sqlite3_open(dbPath, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "CourselessCourseSourceFixture", code: 1)
    }
    defer { sqlite3_close(database) }

    func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "SQLite fixture error"
            sqlite3_free(message)
            throw NSError(
                domain: "CourselessCourseSourceFixture",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }

    try exec("""
        PRAGMA foreign_keys = ON;
        BEGIN IMMEDIATE;
        CREATE TABLE sources (
            id TEXT PRIMARY KEY, date_added REAL NOT NULL,
            state TEXT NOT NULL DEFAULT 'queued', error_message TEXT,
            source_type TEXT NOT NULL DEFAULT 'article', existing_card_count INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL DEFAULT 'active', archived_at TEXT, public_url TEXT,
            is_consumed INTEGER, reading_position_page INTEGER, reading_position_locator TEXT,
            connector_label TEXT, read_at REAL
        );
        CREATE TABLE source_content (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            content TEXT NOT NULL
        );
        CREATE TABLE articles (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            url TEXT NOT NULL, local_file_path TEXT, normalized_url TEXT, title TEXT,
            domain TEXT NOT NULL DEFAULT '', discovery_origin TEXT, word_count INTEGER,
            artwork_url TEXT, author TEXT
        );
        CREATE TABLE course_sources (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            url TEXT NOT NULL, local_file_path TEXT, normalized_url TEXT, title TEXT,
            domain TEXT NOT NULL DEFAULT '', discovery_origin TEXT, word_count INTEGER,
            artwork_url TEXT
        );
        CREATE TABLE courses (
            id TEXT PRIMARY KEY, title TEXT NOT NULL, course_code TEXT, institution TEXT,
            instructors TEXT, playlist_url TEXT, is_hidden INTEGER NOT NULL DEFAULT 0,
            pending_playlist_import INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE course_lectures (
            id TEXT PRIMARY KEY, course_id TEXT NOT NULL, lecture_number INTEGER NOT NULL,
            title TEXT, created_at REAL NOT NULL, UNIQUE(course_id, lecture_number)
        );
        CREATE TABLE source_units (
            id TEXT PRIMARY KEY,
            source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
            kind TEXT NOT NULL, locator TEXT NOT NULL, title TEXT,
            UNIQUE(source_id, kind, locator)
        );
        CREATE TABLE course_lecture_items (
            id TEXT PRIMARY KEY,
            lecture_id TEXT NOT NULL REFERENCES course_lectures(id) ON DELETE CASCADE,
            source_id TEXT REFERENCES sources(id) ON DELETE CASCADE,
            source_unit_id TEXT REFERENCES source_units(id) ON DELETE CASCADE,
            role TEXT NOT NULL, label TEXT, sort_index INTEGER NOT NULL, created_at REAL NOT NULL,
            CHECK (source_id IS NOT NULL OR source_unit_id IS NOT NULL),
            UNIQUE(lecture_id, source_id, source_unit_id)
        );
        CREATE TABLE group_members (
            source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
            group_id TEXT NOT NULL, sort_index INTEGER, lecture_group_id TEXT,
            PRIMARY KEY (source_id, group_id)
        );
        CREATE TABLE hidden_sources (
            source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
            hidden_at REAL NOT NULL
        );
        CREATE TABLE sync_changes (
            entity_type TEXT NOT NULL, logical_key TEXT NOT NULL, record_name TEXT NOT NULL,
            operation TEXT NOT NULL, changed_at REAL NOT NULL,
            tutor_only INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (entity_type, logical_key)
        );
        CREATE TABLE sync_metadata (
            entity_type TEXT NOT NULL, logical_key TEXT NOT NULL, record_name TEXT NOT NULL,
            system_fields BLOB, user_modification_at REAL NOT NULL,
            is_deleted INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (entity_type, logical_key), UNIQUE(record_name)
        );

        INSERT INTO courses (id, title) VALUES ('course-live', 'Systems Biology');

        WITH RECURSIVE ids(n) AS (
            SELECT 1 UNION ALL SELECT n + 1 FROM ids WHERE n < \(orphanCount)
        )
        INSERT INTO sources (id, date_added, state, source_type, status)
        SELECT 'orphan-' || printf('%05d', n), n, 'ready', 'course', 'active' FROM ids;

        INSERT INTO sources (id, date_added, state, source_type, status) VALUES
            ('orphan-deleted-course', 1, 'ready', 'course', 'active'),
            ('member-of-course', 1, 'ready', 'course', 'active'),
            ('member-of-lecture-only-course', 1, 'ready', 'course', 'active'),
            ('item-of-course', 1, 'ready', 'course', 'active'),
            ('unit-of-course', 1, 'ready', 'course', 'active'),
            ('already-hidden', 1, 'ready', 'course', 'active'),
            ('archived-orphan', 1, 'queued', 'course', 'archived'),
            ('plain-article', 1, 'ready', 'article', 'active');

        INSERT INTO course_sources (source_id, url, normalized_url, title, domain, discovery_origin)
        SELECT id, '/Courses/' || id || '.pdf', '/Courses/' || id || '.pdf',
               'Worksheet ' || id, 'Math 21 B: Linear Algebra', 'localCourses'
        FROM sources WHERE source_type = 'course';
        INSERT INTO articles (source_id, url, normalized_url, title, domain)
        VALUES ('plain-article', 'https://example.com/a', 'https://example.com/a', 'An article', 'example.com');
        INSERT INTO source_content (source_id, content)
        SELECT id, 'Stored text for ' || id FROM sources;

        INSERT INTO group_members (source_id, group_id) VALUES
            ('member-of-course', 'course-live'),
            ('member-of-lecture-only-course', 'course-lectures-only'),
            ('orphan-deleted-course', 'course-gone');

        -- A course the sidebar derives from its lectures alone, with no row in
        -- `courses`: still a course, so its member is still reachable.
        INSERT INTO course_lectures (id, course_id, lecture_number, title, created_at)
        VALUES
            ('lecture-1', 'course-live', 1, 'Week 1', 1),
            ('lecture-2', 'course-lectures-only', 1, 'Week 1', 1);
        INSERT INTO source_units (id, source_id, kind, locator)
        VALUES ('unit-1', 'unit-of-course', 'page', '1');
        INSERT INTO course_lecture_items
            (id, lecture_id, source_id, source_unit_id, role, sort_index, created_at)
        VALUES
            ('item-1', 'lecture-1', 'item-of-course', NULL, 'exercise', 0, 1),
            ('item-2', 'lecture-1', NULL, 'unit-1', 'reading', 1, 1);

        INSERT INTO hidden_sources (source_id, hidden_at) VALUES ('already-hidden', 1);
        INSERT INTO sync_metadata (
            entity_type, logical_key, record_name, user_modification_at, is_deleted
        ) VALUES ('source', 'plain-article', 'source-plain-article', 1, 0);
        INSERT INTO sync_changes (
            entity_type, logical_key, record_name, operation, changed_at, tutor_only
        ) VALUES ('source', 'plain-article', 'source-plain-article', 'save', 1, 0);
        PRAGMA user_version = \(stampedVersion);
        COMMIT;
        """)

    // Version 72's own tables, so a fixture stamped 72 is the shape that release
    // actually shipped rather than 71's with a higher number written on it.
    if stampedVersion >= 72 {
        try exec("""
            BEGIN IMMEDIATE;
            CREATE TABLE scheduled_tasks (
                id TEXT PRIMARY KEY, title TEXT NOT NULL, instruction TEXT NOT NULL,
                notebook_id TEXT, source_ids TEXT NOT NULL DEFAULT '[]',
                cadence TEXT NOT NULL DEFAULT 'daily', weekday INTEGER, day_of_month INTEGER,
                hour INTEGER NOT NULL DEFAULT 8, minute INTEGER NOT NULL DEFAULT 0,
                time_zone TEXT, start_date REAL, is_enabled INTEGER NOT NULL DEFAULT 1,
                created_at REAL NOT NULL, updated_at REAL NOT NULL, last_occurrence_at REAL,
                last_run_at REAL, last_run_status TEXT, run_now_requested_at REAL
            );
            CREATE INDEX idx_scheduled_tasks_enabled ON scheduled_tasks(is_enabled);
            CREATE INDEX idx_scheduled_tasks_notebook ON scheduled_tasks(notebook_id);
            CREATE TABLE scheduled_task_runs (
                id TEXT PRIMARY KEY,
                task_id TEXT NOT NULL REFERENCES scheduled_tasks(id) ON DELETE CASCADE,
                occurrence_at REAL NOT NULL, started_at REAL NOT NULL, finished_at REAL,
                status TEXT NOT NULL, session_id TEXT, message TEXT, device_name TEXT,
                UNIQUE(task_id, occurrence_at)
            );
            CREATE INDEX idx_scheduled_task_runs_task
            ON scheduled_task_runs(task_id, occurrence_at DESC);
            COMMIT;
            """)
    }

    // Poison pill for the rollback case: hiding a source fails, and it fails
    // after the version-gated migrations have run, so the assertions can tell
    // "the hide rolled back" from "the hide never started".
    if refuseHiding {
        try exec("""
            CREATE TRIGGER refuse_hidden_sources BEFORE INSERT ON hidden_sources
            BEGIN
                SELECT RAISE(ABORT, 'hidden source insert refused');
            END
            """)
    }
}

@Suite("Courseless course sources")
struct CourselessCourseSourceTests {

    @Test("Deleting a course hides the material it was the only home for")
    func deletingCourseHidesItsOwnMaterial() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseDeletionHidesMaterial_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try KnowledgeStore(storeDirectory: root)
        let courseID = "course-1"
        try store.saveCourseGroup(name: courseID, metadata: CourseMetadata(title: "Systems Biology"))
        let lecture = CourseSession(id: "lecture-1", courseName: courseID, number: 1)
        try store.saveCourseLecture(lecture)

        var handout = StudioArticle(
            url: "/Courses/handout.pdf",
            title: "Handout",
            sourceType: .course,
            id: "handout"
        )
        handout.parentGroup = courseID
        handout.content = "Handout text"
        handout.state = .ready
        try store.saveSource(handout)

        var notes = StudioArticle(
            url: "/Courses/notes.pdf",
            title: "Lecture notes",
            sourceType: .course,
            id: "notes"
        )
        notes.content = "Notes text"
        notes.state = .ready
        try store.saveSource(notes)
        try store.saveCourseLectureItem(
            CourseLectureItem(id: "item-1", lectureId: lecture.id, sourceId: notes.id, role: .exercise)
        )

        var video = StudioArticle(
            url: "https://www.youtube.com/watch?v=abc",
            title: "Week 1",
            sourceType: .video,
            id: "video"
        )
        video.content = "Transcript"
        video.state = .ready
        try store.saveSource(video)
        try store.saveCourseLectureItem(
            CourseLectureItem(id: "item-2", lectureId: lecture.id, sourceId: video.id, role: .video)
        )

        // A course source belonging to another course is untouched by this
        // deletion, however many other courses go away.
        let otherCourseID = "course-2"
        try store.saveCourseGroup(name: otherCourseID, metadata: CourseMetadata(title: "Stat 110"))
        var otherMaterial = StudioArticle(
            url: "/Courses/other.pdf",
            title: "Other worksheet",
            sourceType: .course,
            id: "other"
        )
        otherMaterial.parentGroup = otherCourseID
        otherMaterial.content = "Other text"
        otherMaterial.state = .ready
        try store.saveSource(otherMaterial)

        let hidden = try store.deleteCourseGroup(name: courseID)
        #expect(hidden.sorted() == ["handout", "notes"])

        let sources = try store.loadSourcesWithoutContent()
        #expect(sources.first { $0.id == "handout" }?.isHidden == true)
        #expect(sources.first { $0.id == "notes" }?.isHidden == true)
        // The video has its own tab to live in, so it stays visible.
        #expect(sources.first { $0.id == "video" }?.isHidden == false)
        #expect(sources.first { $0.id == "other" }?.isHidden == false)
        // Hidden, not archived.
        #expect(sources.first { $0.id == "handout" }?.status == .active)
        #expect(try store.loadSourceContent("handout") == "Handout text")
    }

    /// 2026-09-27: a hidden legacy course keyed by a book's own id was deleted,
    /// and every chapter of Molecular Biology of the Cell left the book.
    @Test("Deleting a course that shares a book's id leaves the book's chapters in it")
    func deletingCourseSharingBookIDKeepsChapters() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseDeletionKeepsBook_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try KnowledgeStore(storeDirectory: root)
        let bookID = "F80D8376-60B5-455C-BA82-A8C7301C7108"
        try store.saveBookRecord(CloudKitBookPayload(
            id: bookID,
            title: "Molecular Biology of the Cell",
            author: nil,
            coverPath: nil
        ))
        for (index, title) in ["Chapter 1: Cells", "Chapter 2: Cell Chemistry"].enumerated() {
            var chapter = StudioArticle(
                url: "Books/MBoC/Chapters/0\(index + 1).pdf",
                title: title,
                sourceType: .book,
                parentGroup: bookID,
                id: "chapter-\(index + 1)"
            )
            chapter.courseSortIndex = index
            try store.saveSource(chapter)
        }
        var hiddenMetadata = CourseMetadata(title: "Molecular Biology of the Cell")
        hiddenMetadata.isHidden = true
        try store.saveCourseGroup(name: bookID, metadata: hiddenMetadata)

        let hidden = try store.deleteCourseGroup(name: bookID)

        #expect(hidden.isEmpty)
        #expect(try store.loadCourseGroups()[bookID] == nil)
        let chapters = try store.loadSourcesWithoutContent()
            .filter { $0.sourceType == .book }
            .sorted { $0.id < $1.id }
        #expect(chapters.map(\.parentGroup) == [bookID, bookID])
        #expect(chapters.map(\.courseSortIndex) == [0, 1])
    }
}

/// Attaching a playlist's videos to a course, with the playlist already
/// fetched. Regression coverage for 2026-09-11, when re-importing a course
/// removed weeks earlier produced an empty course: every video carried a
/// removal tombstone, `insertSourceIfNew` refused each one, and the loop
/// skipped them silently.
@Suite("Playlist import attachment")
@MainActor
struct PlaylistImportAttachmentTests {

    @Test("A re-imported playlist brings back videos the learner removed earlier")
    func reimportRevivesRemovedVideos() async throws {
        let (vm, service, root) = makeCoursePersistenceHarness()
        defer { try? FileManager.default.removeItem(at: root) }

        // Removed in-app: the row is archived and its URL carries a tombstone.
        var removed = StudioArticle(
            url: "https://www.youtube.com/watch?v=aaaaaaaaaaa",
            title: "Lecture 1",
            sourceType: .video,
            discoveryOrigin: .youtubePlaylist
        )
        #expect(try await service.insertSourceIfNew(&removed))
        try await service.dismissSources([removed])
        #expect(await service.isSourceDismissed(url: removed.url))

        // Removed on another Mac before this one ever stored it: tombstone only.
        let ghostURL = "https://www.youtube.com/watch?v=bbbbbbbbbbb"
        try await service.dismissSources([
            StudioArticle(url: ghostURL, title: "Lecture 2", sourceType: .video)
        ])
        #expect(await service.isSourceDismissed(url: ghostURL))

        let freshURL = "https://www.youtube.com/watch?v=ccccccccccc"
        let items = [
            YouTubePlaylistItem(videoId: "aaaaaaaaaaa", title: "Lecture 1", playlistIndex: 1),
            YouTubePlaylistItem(videoId: "bbbbbbbbbbb", title: "Lecture 2", playlistIndex: 2),
            YouTubePlaylistItem(videoId: "ccccccccccc", title: "Lecture 3", playlistIndex: 3),
        ]
        let course = UUID().uuidString
        await vm.persistCoursePlaylist("https://www.youtube.com/playlist?list=PLtest", for: course, defaultTitle: "Test Course")

        let tally = await vm.attachPlaylistItems(
            items,
            to: course,
            courseTitle: "Test Course",
            cleanedLectureTitles: [:],
            sourceTitles: [:]
        )

        #expect(tally.added == 3)
        #expect(tally.revived == 2)
        #expect(tally.failures.isEmpty)
        #expect(tally.lectureIdsInOrder.count == 3)
        #expect(vm.courseLectures(for: course).count == 3)
        #expect(await service.isSourceDismissed(url: removed.url) == false)
        #expect(await service.isSourceDismissed(url: ghostURL) == false)
        let activeURLs = Set(try await service.loadActiveSources().map(\.url))
        #expect(activeURLs.isSuperset(of: [removed.url, ghostURL, freshURL]))
    }

    @Test("A course created for an import that attached nothing is discarded")
    func emptyImportDiscardsItsCourse() async throws {
        let (vm, service, root) = makeCoursePersistenceHarness()
        defer { try? FileManager.default.removeItem(at: root) }

        let course = UUID().uuidString
        await vm.persistCoursePlaylist("https://www.youtube.com/playlist?list=PLtest", for: course, defaultTitle: "Empty Course")
        #expect(try await service.loadCourseMetadata()[course] != nil)
        #expect(vm.userCourseNames.contains(course))

        await vm.discardEmptyPlaylistCourse(course)

        #expect(try await service.loadCourseMetadata()[course] == nil)
        #expect(vm.courseMetadata[course] == nil)
        #expect(!vm.userCourseNames.contains(course))
    }

    @Test("The outcome message names the storage failure instead of claiming the videos exist")
    func outcomeMessages() {
        #expect(
            StudioViewModel.emptyPlaylistImportMessage(courseTitle: "MIT 7.05", itemCount: 15, failures: ["disk full"])
                == "Couldn’t add any of the 15 videos from “MIT 7.05”: disk full"
        )
        #expect(
            StudioViewModel.emptyPlaylistImportMessage(courseTitle: "MIT 7.05", itemCount: 1, failures: ["disk full"])
                == "Couldn’t add the video from “MIT 7.05”: disk full"
        )
        #expect(
            StudioViewModel.emptyPlaylistImportMessage(courseTitle: "MIT 7.05", itemCount: 15, failures: [])
                == "All videos from this playlist are already in your library."
        )
        #expect(
            StudioViewModel.partialPlaylistImportMessage(courseTitle: "MIT 7.05", added: 12, itemCount: 15, failures: ["x", "y", "z"])
                == "Added 12 of 15 videos to “MIT 7.05”. 3 couldn’t be added: x"
        )
    }
}
