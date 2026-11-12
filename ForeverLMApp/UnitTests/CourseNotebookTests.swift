import CloudKit
import Foundation
import SQLite3
import Testing
@testable import ForeverLM

// MARK: - Fixtures

private enum CourseNotebookFixtures {
    static func temporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseNotebookTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func scalar(at root: URL, _ sql: String) -> String? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("knowledge.db").path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { return nil }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    /// A course of one lecture holding `sourceIDs` as videos, each a library
    /// source of its own.
    static func seedCourse(
        _ store: KnowledgeStore,
        id: String,
        title: String,
        sourceIDs: [String],
        institution: String? = nil,
        instructors: String? = nil,
        hidden: Bool = false
    ) throws {
        try store.saveCourseGroup(
            name: id,
            metadata: CourseMetadata(title: title, institution: institution, instructors: instructors, isHidden: hidden)
        )
        for sourceID in sourceIDs where try store.loadSourceWithoutContent(sourceID) == nil {
            var source = StudioArticle(url: "https://example.com/\(sourceID)", title: sourceID, sourceType: .article, id: sourceID)
            source.content = "Readable text for \(sourceID)."
            source.state = .ready
            try store.saveSource(source)
        }
        let lecture = CourseSession(id: "\(id)-lecture", courseName: id, number: 1)
        try store.saveCourseOutline(
            courseName: id,
            lectures: [lecture],
            items: sourceIDs.enumerated().map { index, sourceID in
                CourseLectureItem(id: "\(id)-item-\(index)", lectureId: lecture.id, sourceId: sourceID, role: .video, sortIndex: index)
            }
        )
    }

    @discardableResult
    static func makeNotebook(
        _ store: KnowledgeStore,
        title: String,
        sources: [String] = [],
        teamID: String? = nil
    ) throws -> LearningGoalRecord {
        try store.createCompanionGoal(
            title: title,
            topic: title,
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: sources,
            teamID: teamID
        )
    }

    static func makeTeam(_ store: KnowledgeStore, id: String = "team-1", permission: TeamPermission = .readWrite) throws -> TeamRecord {
        let now = Date()
        // An owner always edits; a team this account can only read is one it joined, in the shared zone
        // (saving an owned team that is read-only is refused as a write the sync would never send).
        let role: TeamRole = permission == .readOnly ? .member : .owner
        let team = TeamRecord(
            id: id,
            name: "Nexus",
            role: role,
            permission: permission,
            zoneScope: role == .owner ? .privateScope : .shared,
            zoneName: TeamRecord.zoneName(forTeamID: id),
            zoneOwnerRecordName: role == .owner ? nil : "_parent",
            shareRecordName: nil,
            shareURL: nil,
            createdAt: now,
            joinedAt: now,
            updatedAt: now
        )
        try store.saveTeam(team)
        return team
    }

    static func approved(_ notebookID: String, in store: KnowledgeStore) throws -> Set<String> {
        Set(try store.loadLearningGoal(notebookID)?.approvedSourceIDs ?? [])
    }

    static func links(_ courseID: String, in store: KnowledgeStore) throws -> Set<String> {
        Set(try store.notebookIDsFollowingCourse(courseID))
    }
}

// MARK: - A course and its notebooks

/// A course lives in no notebook (docs/courses-design.md, "A course is its own
/// thing"): a notebook may follow it (`notebook_course_links`), and that is the
/// only tie. Following adds its sources and the ones it gains; leaving, or the
/// notebook's deletion, leaves the course as it was.
@Suite("A course and its notebooks")
struct CourseNotebookTests {
    fileprivate typealias F = CourseNotebookFixtures

    @Test("Following a course makes the notebook follow it and adds its sources, in one write; the course itself is not touched")
    func followLinksAndSeeds() throws {
        let store = try KnowledgeStore(inMemory: true)
        try F.seedCourse(store, id: "course-1", title: "Systems Biology", sourceIDs: ["src-a", "src-b"])
        let notebook = try F.makeNotebook(store, title: "Systems Biology")

        let added = try store.followCourse(courseID: "course-1", notebookID: notebook.id)
        #expect(added == 2)
        #expect(try F.links("course-1", in: store) == [notebook.id])
        #expect(try F.approved(notebook.id, in: store) == ["src-a", "src-b"])

        // A lecture the course gains joins the notebook that follows it.
        try F.seedCourse(store, id: "course-1", title: "Systems Biology", sourceIDs: ["src-a", "src-b", "src-c"])
        #expect(try F.approved(notebook.id, in: store).contains("src-c"))
    }

    @Test("A notebook that already follows the course keeps its pool as the learner left it")
    func followerKeepsItsPool() throws {
        let store = try KnowledgeStore(inMemory: true)
        try F.seedCourse(store, id: "aging", title: "Systems Aging", sourceIDs: ["src-1", "src-2"])
        let landscape = try F.makeNotebook(store, title: "Landscape of Aging")
        try store.linkCourseToNotebook(goalID: landscape.id, courseID: "aging", sourceIDs: [])
        try store.removeCompanionSources(goalID: landscape.id, sourceIDs: ["src-2"])

        try store.followCourse(courseID: "aging", notebookID: landscape.id)
        #expect(try F.links("aging", in: store) == [landscape.id])
        #expect(try F.approved(landscape.id, in: store).contains("src-1"))
    }

    @Test("Any number of notebooks follow a course, and one stopping leaves the course and the others as they were")
    func manyFollowersAndUnfollowing() throws {
        let store = try KnowledgeStore(inMemory: true)
        try F.seedCourse(store, id: "course-1", title: "CS336", sourceIDs: ["src-a"])
        let first = try F.makeNotebook(store, title: "First")
        let second = try F.makeNotebook(store, title: "Second")
        try store.followCourse(courseID: "course-1", notebookID: first.id)
        try store.followCourse(courseID: "course-1", notebookID: second.id)
        #expect(try F.links("course-1", in: store) == [first.id, second.id])

        #expect(try store.unlinkCourseFromNotebook(goalID: first.id, courseID: "course-1"))
        #expect(try F.links("course-1", in: store) == [second.id])
        #expect(try F.approved(first.id, in: store) == ["src-a"], "it keeps the sources it holds")
        #expect(try !store.unlinkCourseFromNotebook(goalID: first.id, courseID: "course-1"), "a second stop changes nothing")
    }

    @Test("A notebook follows a course only when it is a live Notebook of the course's library that takes new things")
    func refusals() throws {
        let store = try KnowledgeStore(inMemory: true)
        try F.seedCourse(store, id: "course-1", title: "CS336", sourceIDs: [])
        let notebook = try F.makeNotebook(store, title: "Notebook")
        let goal = try store.createCompanionGoal(
            title: "Finish it", topic: "t", startAt: Date(), endAt: Date().addingTimeInterval(7 * 86_400),
            dailyTarget: 1, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: notebook.id
        )
        let archived = try F.makeNotebook(store, title: "Archived")
        try store.setLearningGoalStatus(goalID: archived.id, status: .archived)
        let team = try F.makeTeam(store)
        let teamNotebook = try F.makeNotebook(store, title: "Team's", teamID: team.id)

        #expect(throws: (any Error).self) { try store.followCourse(courseID: "no-such-course", notebookID: notebook.id) }
        #expect(throws: (any Error).self) { try store.followCourse(courseID: "course-1", notebookID: goal.id) }
        #expect(throws: (any Error).self) { try store.followCourse(courseID: "course-1", notebookID: archived.id) }
        #expect(throws: (any Error).self) { try store.followCourse(courseID: "course-1", notebookID: teamNotebook.id) }
        #expect(throws: (any Error).self) { try store.followCourse(courseID: "course-1", notebookID: "missing") }
        #expect(try F.links("course-1", in: store).isEmpty)
    }

    @Test("Deleting a notebook leaves its courses as they were; merging one unions the courses followed")
    func deleteAndMerge() throws {
        let store = try KnowledgeStore(inMemory: true)
        try F.seedCourse(store, id: "course-1", title: "One", sourceIDs: ["src-a"])
        try F.seedCourse(store, id: "course-2", title: "Two", sourceIDs: ["src-b"])
        let doomed = try F.makeNotebook(store, title: "Doomed")
        let mergee = try F.makeNotebook(store, title: "Mergee")
        let survivor = try F.makeNotebook(store, title: "Survivor")
        try store.followCourse(courseID: "course-1", notebookID: doomed.id)
        try store.followCourse(courseID: "course-2", notebookID: mergee.id)

        try store.deleteLearningGoal(doomed.id)
        #expect(try F.links("course-1", in: store).isEmpty)
        #expect(try store.loadCourseGroups()["course-1"] != nil, "the course itself stays")

        _ = try store.mergeCompanionGoals(notebookIDs: [survivor.id, mergee.id])
        #expect(try F.links("course-2", in: store) == [survivor.id])
    }
}

// MARK: - Schema 150

/// Schema 150 adds `courses.home_notebook_id` and its index: DDL only, no
/// row read, nothing republished.
@Suite("Schema 150 migration")
struct Schema150MigrationTests {
    fileprivate typealias F = CourseNotebookFixtures

    /// A released library at `version`: today's shape without the column and
    /// its index, and for 148 without the two `review_sessions` columns 149
    /// added. Dropping them rather than lowering the stamp is what makes each
    /// step run.
    private static func createReleasedLibrary(at root: URL, version: Int32, extraSources: Int = 0, extraCourses: Int = 0) throws {
        let store = try KnowledgeStore(storeDirectory: root)
        try F.seedCourse(store, id: "aging", title: "Systems Aging", sourceIDs: ["src-1", "src-2"])
        let landscape = try F.makeNotebook(store, title: "Landscape of Aging")
        try store.linkCourseToNotebook(goalID: landscape.id, courseID: "aging", sourceIDs: [])
        if extraSources > 0 || extraCourses > 0 {
            try store.execForTesting("""
                BEGIN IMMEDIATE;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < \(max(extraSources, 1)))
                INSERT INTO sources (id, date_added, state, source_type, status)
                SELECT printf('source-%05d', n), n, 'ready', 'article', 'active' FROM seq WHERE \(extraSources) > 0;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < \(max(extraSources, 1)))
                INSERT INTO articles (source_id, url, normalized_url, title, domain)
                SELECT printf('source-%05d', n), printf('https://example.com/%05d', n),
                       printf('example.com/%05d', n), printf('Source %05d', n), 'example.com'
                FROM seq WHERE \(extraSources) > 0;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < \(max(extraCourses, 1)))
                INSERT INTO courses (id, title) SELECT printf('course-%05d', n), printf('Course %05d', n)
                FROM seq WHERE \(extraCourses) > 0;
                COMMIT;
            """)
        }
        try store.execForTesting("""
            DROP INDEX IF EXISTS idx_courses_home_notebook;
            ALTER TABLE courses DROP COLUMN home_notebook_id;
            \(version < 149 ? "ALTER TABLE review_sessions DROP COLUMN model_speed; ALTER TABLE review_sessions DROP COLUMN model_effort;" : "")
            PRAGMA user_version = \(version);
        """)
    }

    private static let homeColumn = "SELECT COUNT(*) FROM pragma_table_info('courses') WHERE name = 'home_notebook_id'"

    @Test("A fresh store has the column and its index")
    func freshStoreHasColumn() throws {
        let root = try F.temporaryRoot("fresh")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try KnowledgeStore(storeDirectory: root)
        #expect(F.scalar(at: root, Self.homeColumn) == "1")
        #expect(F.scalar(at: root, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_courses_home_notebook'") == "1")
    }

    @Test("A production-sized library migrates to 150 in well under a second")
    func version150Scales() throws {
        let root = try F.temporaryRoot("v150-scale")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.createReleasedLibrary(at: root, version: 149, extraSources: 20_000, extraCourses: 2_000)

        let started = ContinuousClock.now
        let migrated = try KnowledgeStore(storeDirectory: root)
        let elapsed = started.duration(to: .now)
        // One ALTER TABLE ADD COLUMN with no default and one index over a
        // small table: no row is read or rewritten per course or source.
        #expect(elapsed < .seconds(1))
        #expect(F.scalar(at: root, "PRAGMA user_version") == "\(KnowledgeStore.schemaVersion)")
        var visible = 0
        try migrated.query("SELECT COUNT(*) FROM source_projection") { visible = Int(sqlite3_column_int($0, 0)) }
        #expect(visible == 20_002, "sources stay visible")
        #expect(F.scalar(at: root, "SELECT COUNT(*) FROM courses WHERE home_notebook_id IS NULL") == "2001")
    }
}

// MARK: - Study notebooks

@Suite("Study notebooks")
struct StudyNotebookTests {
    fileprivate typealias F = CourseNotebookFixtures

    @Test("Make Study Notebook makes a notebook named after the course, holding its sources and following it, under a fixed id")
    func makesTheStudyNotebook() throws {
        let store = try KnowledgeStore(inMemory: true)
        try F.seedCourse(
            store, id: "bio", title: "Mitochondrial Bioenergetics", sourceIDs: ["b1", "b2"],
            institution: "USP", instructors: "Alicia Kowaltowski"
        )
        let goalsBefore = try store.loadLearningGoals().count

        let made = try store.makeStudyNotebook(courseID: "bio")
        let notebookID = TeamContentIdentity.courseNotebookID(courseID: "bio")
        #expect(made == CourseStudyNotebook(courseID: "bio", notebookID: notebookID, created: true, sourcesAdded: 2))
        #expect(try store.loadLearningGoals().count == goalsBefore + 1)
        let notebook = try #require(try store.loadLearningGoal(notebookID))
        #expect(notebook.isNotebook)
        #expect(notebook.title == "Mitochondrial Bioenergetics")
        #expect(notebook.summary == "USP · Alicia Kowaltowski")
        #expect(try F.approved(notebookID, in: store) == ["b1", "b2"])
        #expect(try F.links("bio", in: store) == [notebookID])

        // Asked again, it links the one it made again and makes no second notebook.
        let again = try store.makeStudyNotebook(courseID: "bio")
        #expect(!again.created && again.sourcesAdded == 0 && again.notebookID == notebookID)
        #expect(try store.loadLearningGoals().count == goalsBefore + 1)

        // Another Mac asking makes the same notebook.
        let otherMac = try KnowledgeStore(inMemory: true)
        try F.seedCourse(otherMac, id: "bio", title: "Mitochondrial Bioenergetics", sourceIDs: ["b1"])
        #expect(try otherMac.makeStudyNotebook(courseID: "bio").notebookID == notebookID)
    }

    @Test("A study notebook is refused for a course that is not here or a team's course this account can only read")
    func studyNotebookRefusals() throws {
        let store = try KnowledgeStore(inMemory: true)
        #expect(throws: CourseNotebookError.courseNotFound(courseID: "nope")) { try store.makeStudyNotebook(courseID: "nope") }
        let team = try F.makeTeam(store, permission: .readOnly)
        try store.execForTesting("INSERT INTO courses (id, title, team_id) VALUES ('team-course', 'Team Course', '\(team.id)')")
        #expect(throws: CourseNotebookError.readOnlyTeamCourse(courseTitle: "Team Course")) {
            try store.makeStudyNotebook(courseID: "team-course")
        }
    }
}

// MARK: - The view model's side

@Suite("A course and its notebooks in the view model")
@MainActor
struct CourseNotebookViewModelTests {
    fileprivate typealias F = CourseNotebookFixtures

    @Test("Linking, unlinking and making a study notebook update which notebooks follow a course")
    func followersFollowTheWrites() async throws {
        let restoreLibrary = capturingOpenLibrary()
        defer { restoreLibrary() }
        let root = try F.temporaryRoot("vm")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)
        vm.activeTeamID = nil
        let store = try await storage.notebookFilesKnowledgeStore()
        try F.seedCourse(store, id: "bio", title: "Bioenergetics", sourceIDs: ["b1"])
        let other = try F.makeNotebook(store, title: "Elsewhere")
        await vm.loadLearningGoals()

        #expect(vm.notebooksFollowingCourse("bio").isEmpty)
        await vm.followCourseFromMenu("bio", inNotebook: other.id)
        #expect(vm.courseFollowerNotebookIDs["bio"] == [other.id])
        #expect(vm.notebooksFollowingCourse("bio").map(\.id) == [other.id])

        await vm.unfollowCourseFromMenu("bio", inNotebook: other.id)
        #expect(vm.notebooksFollowingCourse("bio").isEmpty)

        let window = StudioWindowState()
        await vm.makeStudyNotebook(forCourse: "bio", in: window)
        let studyID = TeamContentIdentity.courseNotebookID(courseID: "bio")
        #expect(vm.notebooksFollowingCourse("bio").map(\.id) == [studyID])
        #expect(window.NotebookID == studyID, "the study notebook opens in the window that asked")
    }

    @Test("A course opens in the window's Courses pane and never moves the window into a notebook")
    func openingACourseStaysPut() async throws {
        let root = try F.temporaryRoot("vm-open")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage)
        let store = try await storage.notebookFilesKnowledgeStore()
        try F.seedCourse(store, id: "aging", title: "Systems Aging", sourceIDs: ["a1"])
        let notebook = try F.makeNotebook(store, title: "Landscape of Aging")
        try store.followCourse(courseID: "aging", notebookID: notebook.id)
        await vm.loadLearningGoals()

        let window = StudioWindowState()
        vm.openCourse("aging", in: window)
        #expect(window.coursePageID == "aging")
        #expect(window.notebook == nil, "a notebook following the course does not pull the window into it")
    }
}

// MARK: - Organize Course

/// Organize Course used to fall back to a natural title sort when its model
/// call failed and write that over the learner's order without a word. A
/// failed call is shown and changes nothing.
@Suite("Organize Course")
@MainActor
struct OrganizeCourseTests {
    private struct ModelDown: LocalizedError {
        var errorDescription: String? { "The model timed out" }
    }

    /// Two materials of course "bio" in the learner's order: "Lecture 2"
    /// first, which a title sort would move after "Lecture 1".
    private func seed(_ name: String) async throws -> (StudioViewModel, KnowledgeStore, URL) {
        let root = try CourseNotebookFixtures.temporaryRoot(name)
        let storage = StorageService(storeRoot: root)
        let vm = StudioViewModel(storageService: storage, observeCloudKitChanges: false)
        let store = try await storage.notebookFilesKnowledgeStore()
        for (index, (id, title)) in [("second", "Lecture 2"), ("first", "Lecture 1")].enumerated() {
            var source = StudioArticle(url: "https://example.org/\(id)", title: title, sourceType: .article, id: id)
            source.parentGroup = "bio"
            source.courseSortIndex = index
            try store.saveSource(source)
            vm.articles.append(source)
        }
        return (vm, store, root)
    }

    @Test("A failed model call is shown and leaves the learner's order, in memory and stored")
    func failedModelCallChangesNothing() async throws {
        let (vm, store, root) = try await seed("organize-fail")
        defer { try? FileManager.default.removeItem(at: root) }

        await vm.organizeCourse(name: "bio", modelOrder: { _ in throw ModelDown() })

        #expect(vm.articles.first { $0.id == "second" }?.courseSortIndex == 0)
        #expect(vm.articles.first { $0.id == "first" }?.courseSortIndex == 1)
        #expect(try store.loadSourceWithoutContent("second")?.courseSortIndex == 0)
        #expect(try store.loadSourceWithoutContent("first")?.courseSortIndex == 1)
        #expect(vm.toastMessage?.contains("The model timed out") == true)
    }

    @Test("The model's order is stored, then shown")
    func modelOrderIsApplied() async throws {
        let (vm, store, root) = try await seed("organize-ok")
        defer { try? FileManager.default.removeItem(at: root) }

        await vm.organizeCourse(name: "bio", modelOrder: { items in
            #expect(Set(items.map(\.id)) == ["first", "second"])
            return ["first", "second"]
        })

        #expect(try store.loadSourceWithoutContent("first")?.courseSortIndex == 0)
        #expect(try store.loadSourceWithoutContent("second")?.courseSortIndex == 1)
        #expect(vm.articles.first { $0.id == "first" }?.courseSortIndex == 0)
        #expect(vm.articles.first { $0.id == "second" }?.courseSortIndex == 1)
    }
}
