import Foundation
import SQLite3
import Testing
@testable import ForeverLM

@Suite("Learning Goal Persistence")
struct LearningGoalPersistenceTests {
    @Test("A Goal's deadline moves on its own, and a Notebook's does not")
    func goalDeadlineMoves() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date()
        let goal = try store.createCompanionGoal(
            title: "Understand the heart and Na/K work", topic: "Na/K", startAt: now, endAt: now.addingTimeInterval(7 * 86_400),
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
        )
        let later = Calendar.current.startOfDay(for: now.addingTimeInterval(21 * 86_400))
        try store.setLearningGoalDeadline(goalID: goal.id, endAt: later)
        let moved = try #require(try store.loadLearningGoal(goal.id))
        #expect(moved.endAt == later)
        #expect(moved.title == goal.title && moved.startAt == goal.startAt, "nothing else on the row changes")
        #expect(throws: KnowledgeStoreError.self, "an end before the start is refused") {
            try store.setLearningGoalDeadline(goalID: goal.id, endAt: now.addingTimeInterval(-86_400))
        }
        let notebook = try store.createCompanionGoal(
            title: "Mitochondria", topic: "mitochondria", startAt: now, endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
        )
        #expect(throws: KnowledgeStoreError.self, "a Notebook has no deadline to move") {
            try store.setLearningGoalDeadline(goalID: notebook.id, endAt: later)
        }
    }


    @MainActor
    private func makeGoalsFeatureViewModel() -> StudioViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoalsFeatureTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return StudioViewModel(storageService: StorageService(storeRoot: root))
    }

    private func makeNotebook(at date: Date) -> LearningGoalRecord {
        LearningGoalRecord(
            id: "notebook",
            title: "Biology",
            startAt: date,
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: date,
            updatedAt: date,
            status: LearningGoalStatus.active.rawValue,
            items: [],
            kind: LearningGoalRecord.companionKind
        )
    }

    private func makeNotebookGoal(id: String, title: String, date: Date) -> LearningGoalRecord {
        LearningGoalRecord(
            id: id,
            title: title,
            startAt: date,
            endAt: date,
            createdAt: date,
            updatedAt: date,
            status: LearningGoalStatus.active.rawValue,
            items: [],
            kind: LearningGoalRecord.companionKind,
            parentNotebookID: "notebook"
        )
    }

    @Test("Startup migrates an older version to the current schema")
    func olderSchemaMigratesOnStartup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoalsSchemaTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let path = root.appendingPathComponent("knowledge.db").path
        var database: OpaquePointer?
        #expect(sqlite3_open(path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "PRAGMA user_version = 6", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)

        let store = try KnowledgeStore(storeDirectory: root)
        var migratedVersion: Int32 = 0
        try store.query("PRAGMA user_version") { statement in
            migratedVersion = sqlite3_column_int(statement, 0)
        }
        #expect(migratedVersion == KnowledgeStore.schemaVersion)
        #expect(try store.tableColumnNames("sources").contains("connector_label"))
    }

    @Test("Version-1 current-shape store migrates without losing sources")
    func versionOneCurrentShapeStorePreservesSources() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoalsSchemaV1Tests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let store = try KnowledgeStore(storeDirectory: root)
            let source = StudioArticle(
                url: "https://example.com/migration",
                title: "Migration source",
                sourceType: .article,
                id: "migration-source"
            )
            try store.saveSource(source)
        }

        let path = root.appendingPathComponent("knowledge.db").path
        var database: OpaquePointer?
        #expect(sqlite3_open(path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "PRAGMA user_version = 1", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)

        let migratedStore = try KnowledgeStore(storeDirectory: root)
        let sources = try migratedStore.loadSources()
        var migratedVersion: Int32 = 0
        try migratedStore.query("PRAGMA user_version") { statement in
            migratedVersion = sqlite3_column_int(statement, 0)
        }

        #expect(migratedVersion == KnowledgeStore.schemaVersion)
        #expect(sources.map(\.id) == ["migration-source"])
    }

    @Test("Version-10 migration adds Notebook course links without losing goals")
    func versionTenMigrationAddsNotebookCourseLinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookCourseLinkMigrationTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let notebookID: String
        do {
            let store = try KnowledgeStore(storeDirectory: root)
            let now = Date()
            notebookID = try store.createCompanionGoal(
                title: "Migration Notebook",
                topic: "Migration",
                startAt: now,
                endAt: LearningGoalRecord.openEndedEndAt,
                dailyTarget: 3,
                discoveryEnabled: false,
                seedSourceIDs: []
            ).id
            try store.execForTesting("DROP TABLE notebook_course_links")
            try store.execForTesting("PRAGMA user_version = 10")
        }

        let migratedStore = try KnowledgeStore(storeDirectory: root)
        var migratedVersion: Int32 = 0
        var linkTableCount = 0
        try migratedStore.query("PRAGMA user_version") { statement in
            migratedVersion = sqlite3_column_int(statement, 0)
        }
        try migratedStore.query("""
            SELECT COUNT(*)
            FROM sqlite_master
            WHERE type = 'table' AND name = 'notebook_course_links'
        """) { statement in
            linkTableCount = Int(sqlite3_column_int64(statement, 0))
        }

        #expect(migratedVersion == KnowledgeStore.schemaVersion)
        #expect(linkTableCount == 1)
        #expect(try migratedStore.loadLearningGoal(notebookID)?.title == "Migration Notebook")
    }

    @Test("Version-11 migration adds the Notebook file projection without losing Notebooks")
    func versionElevenMigrationAddsNotebookFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookFileMigrationTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let notebookID: String
        do {
            let store = try KnowledgeStore(storeDirectory: root)
            let now = Date()
            notebookID = try store.createCompanionGoal(
                title: "Migration Notebook",
                topic: "Migration",
                startAt: now,
                endAt: LearningGoalRecord.openEndedEndAt,
                dailyTarget: 3,
                discoveryEnabled: false,
                seedSourceIDs: []
            ).id
            try store.execForTesting("""
                DROP TABLE notebook_files;
                CREATE TABLE notebook_files (
                    id TEXT PRIMARY KEY,
                    legacy_path TEXT NOT NULL
                );
                INSERT INTO notebook_files (id, legacy_path)
                VALUES ('legacy-row', '/tmp/legacy')
            """)
            try store.execForTesting("PRAGMA user_version = 11")
        }

        let migratedStore = try KnowledgeStore(storeDirectory: root)
        var migratedVersion: Int32 = 0
        var fileTableCount = 0
        try migratedStore.query("PRAGMA user_version") { statement in
            migratedVersion = sqlite3_column_int(statement, 0)
        }
        try migratedStore.query("""
            SELECT COUNT(*)
            FROM sqlite_master
            WHERE type = 'table' AND name = 'notebook_files'
        """) { statement in
            fileTableCount = Int(sqlite3_column_int64(statement, 0))
        }

        #expect(migratedVersion == KnowledgeStore.schemaVersion)
        #expect(fileTableCount == 1)
        #expect(try migratedStore.tableColumnNames("notebook_files").contains("relative_path"))
        #expect(try migratedStore.loadLearningGoal(notebookID)?.title == "Migration Notebook")
    }

    @Test("Failed migration rolls back schema and version")
    func failedMigrationRollsBack() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoalsSchemaRollbackTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let path = root.appendingPathComponent("knowledge.db").path
        var database: OpaquePointer?
        #expect(sqlite3_open(path, &database) == SQLITE_OK)
        #expect(
            sqlite3_exec(
                database,
                "CREATE TABLE sources (id TEXT PRIMARY KEY); PRAGMA user_version = 1",
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )
        sqlite3_close(database)

        #expect(throws: (any Error).self) {
            _ = try KnowledgeStore(storeDirectory: root)
        }

        #expect(sqlite3_open(path, &database) == SQLITE_OK)
        var versionAfterFailure: Int32 = 0
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
        if sqlite3_step(statement) == SQLITE_ROW {
            versionAfterFailure = sqlite3_column_int(statement, 0)
        }
        sqlite3_finalize(statement)

        var articlesTableCount: Int32 = -1
        #expect(
            sqlite3_prepare_v2(
                database,
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'articles'",
                -1,
                &statement,
                nil
            ) == SQLITE_OK
        )
        if sqlite3_step(statement) == SQLITE_ROW {
            articlesTableCount = sqlite3_column_int(statement, 0)
        }
        sqlite3_finalize(statement)
        sqlite3_close(database)

        #expect(versionAfterFailure == 1)
        #expect(articlesTableCount == 0)
    }

    @Test("Startup rejects a database from a newer app version")
    func newerSchemaStillFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoalsFutureSchemaTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let path = root.appendingPathComponent("knowledge.db").path
        var database: OpaquePointer?
        #expect(sqlite3_open(path, &database) == SQLITE_OK)
        #expect(
            sqlite3_exec(
                database,
                "PRAGMA user_version = \(KnowledgeStore.schemaVersion + 1)",
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )
        sqlite3_close(database)

        #expect(throws: (any Error).self) {
            _ = try KnowledgeStore(storeDirectory: root)
        }
    }

    @Test("Closed Goals stop contributing unfinished Schedule placements")
    @MainActor
    func closedGoalHidesUnfinishedPlacement() {
        let calendar = Calendar.current
        let date = calendar.startOfDay(for: Date())
        let vm = makeGoalsFeatureViewModel()
        let source = StudioArticle(
            url: "https://example.com/source",
            title: "Background paper",
            sourceType: .article,
            id: "source"
        )
        var closed = makeNotebookGoal(id: "goal", title: "Article", date: date)
        closed.status = LearningGoalStatus.done.rawValue
        vm.articles = [source]
        vm.learningGoals = [makeNotebook(at: date), closed]
        vm.scheduledSources = [
            ScheduledSourceEntry(
                placement: ScheduledSource(
                    id: "placement",
                    sourceID: source.id,
                    plannedAt: date,
                    addedAt: date,
                    completedAt: nil,
                    createdAt: date,
                    updatedAt: date
                ),
                goalTags: [],
                goalIDs: [closed.id]
            )
        ]

        let day = vm.unifiedScheduleDays(containing: date)
            .first { calendar.isDate($0.date, inSameDayAs: date) }

        #expect(day?.items.isEmpty == true)
    }

    @Test("Schedule planner includes Monday after a Sunday")
    @MainActor
    func schedulePlannerIncludesFollowingMonday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let sunday = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 9))
        )
        let vm = makeGoalsFeatureViewModel()

        let days = vm.scheduleWeekDayStarts(
            containing: sunday,
            calendar: calendar,
            includesFollowingDay: true
        )

        #expect(days.count == 8)
        #expect(calendar.component(.weekday, from: days[6]) == 1)
        #expect(calendar.component(.weekday, from: days[7]) == 2)
        #expect(calendar.component(.day, from: days[7]) == 10)
    }

    @Test("Archived Notebooks leave active views without being deleted")
    @MainActor
    func archivedNotebooksStayAvailableForRestore() {
        let now = Date()
        let vm = makeGoalsFeatureViewModel()
        let active = makeNotebook(at: now)
        let archivedSource = LearningGoalItem(
            id: "archived-item",
            goalID: "archived-notebook",
            sourceID: "preserved-source",
            addedAt: now,
            origin: LearningGoalItemOrigin.seed.rawValue,
            reviewState: LearningGoalItemReviewState.approved.rawValue
        )
        let archived = LearningGoalRecord(
            id: "archived-notebook",
            title: "Archived Biology",
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: now,
            updatedAt: now,
            status: LearningGoalStatus.archived.rawValue,
            items: [archivedSource],
            kind: LearningGoalRecord.companionKind
        )

        vm.learningGoals = [active, archived]

        #expect(vm.notebooks.map(\.id) == [active.id])
        #expect(vm.archivedNotebooks.map(\.id) == [archived.id])
        #expect(vm.notebook(id: archived.id)?.approvedSourceIDs == ["preserved-source"])
    }

    @Test("Companion goal settings can be edited in place")
    func updateCompanionGoalSettings() throws {
        let store = try KnowledgeStore(inMemory: true)
        let startAt = Date()
        let goal = try store.createCompanionGoal(
            title: "Linear Algebra",
            description: "Vectors, matrices, and eigenvalues",
            topic: "linear algebra",
            startAt: startAt,
            endAt: startAt.addingTimeInterval(7 * 24 * 60 * 60),
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["source-1"]
        )
        try store.clearAllPendingSyncChanges()

        let newEnd = startAt.addingTimeInterval(21 * 24 * 60 * 60)
        try store.updateCompanionGoalSettings(
            goalID: goal.id,
            title: "Linear Algebra Deep Dive",
            description: "Focused pass on eigenvalues and eigenvectors",
            topic: "eigenvalues and eigenvectors",
            endAt: newEnd,
            dailyTarget: 5,
            discoveryEnabled: true
        )

        let updated = try #require(try store.loadLearningGoal(goal.id))
        #expect(updated.title == "Linear Algebra Deep Dive")
        #expect(updated.description == "Focused pass on eigenvalues and eigenvectors")
        #expect(updated.topic == "eigenvalues and eigenvectors")
        #expect(abs(updated.endAt.timeIntervalSince(newEnd)) < 1)
        #expect(updated.dailyTarget == 5)
        #expect(updated.discoveryEnabled == true)
        // Items and their states are untouched by a settings edit.
        #expect(updated.items.count == 1)
        #expect(updated.items.first?.isApproved == true)
        #expect(try store.pendingSyncChanges().contains {
            $0.entity == .learningGoal
                && $0.logicalKey == goal.id
                && $0.operation == .save
        })
    }

    @Test("Renaming a Notebook changes only its title and queues sync")
    func renameNotebook() throws {
        let store = try KnowledgeStore(inMemory: true)
        let startAt = Date()
        let goal = try store.createCompanionGoal(
            title: "Reinforcement Learning",
            description: "Learn modern policy optimization",
            topic: "reinforcement learning",
            startAt: startAt,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: true,
            seedSourceIDs: ["source-1"]
        )
        try store.clearAllPendingSyncChanges()

        try store.setLearningGoalTitle(goalID: goal.id, title: "  Deep Reinforcement Learning  ")

        let renamed = try #require(try store.loadLearningGoal(goal.id))
        #expect(renamed.title == "Deep Reinforcement Learning")
        #expect(renamed.description == goal.description)
        #expect(renamed.topic == goal.topic)
        #expect(renamed.endAt == goal.endAt)
        #expect(renamed.dailyTarget == goal.dailyTarget)
        #expect(renamed.discoveryEnabled == goal.discoveryEnabled)
        #expect(renamed.items == goal.items)
        #expect(try store.pendingSyncChanges().contains {
            $0.entity == .learningGoal
                && $0.logicalKey == goal.id
                && $0.operation == .save
        })
    }

    @Test("Notebook instructions update and clear through the synced description field")
    func setNotebookInstructions() throws {
        let store = try KnowledgeStore(inMemory: true)
        let startAt = Date()
        let goal = try store.createCompanionGoal(
            title: "Mitochondrial Transplantation",
            description: nil,
            topic: "mitochondrial transplantation",
            startAt: startAt,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )
        try store.clearAllPendingSyncChanges()

        try store.setLearningGoalDescription(
            goalID: goal.id,
            description: "Prioritize primary research and flag disputed claims."
        )

        let updated = try #require(try store.loadLearningGoal(goal.id))
        #expect(updated.description == "Prioritize primary research and flag disputed claims.")
        #expect(try store.pendingSyncChanges().contains {
            $0.entity == .learningGoal
                && $0.logicalKey == goal.id
                && $0.operation == .save
        })

        try store.setLearningGoalDescription(goalID: goal.id, description: "   ")
        let cleared = try #require(try store.loadLearningGoal(goal.id))
        #expect(cleared.description == nil)
    }

    @Test("Notebook summary is stored single-line, syncs, and clears")
    func setNotebookSummary() throws {
        let store = try KnowledgeStore(inMemory: true)
        let goal = try store.createCompanionGoal(
            title: "Mitochondria",
            description: "Prefer primary research.",
            summary: "  How organelles  age,\nand what slows it  ",
            topic: "mitochondria",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )
        // Created with a summary: whitespace runs and the newline collapse.
        #expect(goal.summary == "How organelles age, and what slows it")
        #expect(goal.description == "Prefer primary research.")
        try store.clearAllPendingSyncChanges()

        try store.setLearningGoalSummary(goalID: goal.id, summary: "Ageing organelles, measured")
        let updated = try #require(try store.loadLearningGoal(goal.id))
        #expect(updated.summary == "Ageing organelles, measured")
        #expect(updated.displaySummary == "Ageing organelles, measured")
        // The card description never touches the chat Instructions.
        #expect(updated.description == "Prefer primary research.")
        #expect(try store.pendingSyncChanges().contains {
            $0.entity == .learningGoal
                && $0.logicalKey == goal.id
                && $0.operation == .save
        })

        // Over-long text is capped rather than refused.
        try store.setLearningGoalSummary(goalID: goal.id, summary: String(repeating: "x", count: 500))
        #expect(try #require(try store.loadLearningGoal(goal.id)).summary?.count == LearningGoalRecord.summaryMaxLength)

        try store.setLearningGoalSummary(goalID: goal.id, summary: "   ")
        let cleared = try #require(try store.loadLearningGoal(goal.id))
        #expect(cleared.summary == nil)
        #expect(cleared.displaySummary == nil)

        // A full record save round-trips the column.
        var record = cleared
        record.summary = "Round trip"
        try store.saveLearningGoalRecord(record)
        #expect(try #require(try store.loadLearningGoal(goal.id)).summary == "Round trip")
    }

    /// Schema 100 adds `learning_goals.summary`. A store already stamped at the
    /// current version takes the fast path and runs no column migration, so the
    /// bump is what makes an existing library gain the column; without it every
    /// Notebook load fails on the unknown column and the gallery reads "No notebooks".
    @Test("Schema 100 adds the Notebook summary column to a schema-99 library")
    func summaryColumnMigratesFromSchema99() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-summary-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let notebookID: String
        do {
            let store = try KnowledgeStore(storeDirectory: root)
            let goal = try store.createCompanionGoal(
                title: "Alzheimer's",
                topic: "alzheimer's disease",
                startAt: Date(),
                endAt: LearningGoalRecord.openEndedEndAt,
                dailyTarget: 3,
                discoveryEnabled: false,
                seedSourceIDs: []
            )
            notebookID = goal.id
            // Back to the exact shape build 76 (schema 99) wrote: no summary column.
            try store.execForTesting("ALTER TABLE learning_goals DROP COLUMN summary")
            try store.execForTesting("PRAGMA user_version = 99")
        }
        #expect(Self.userVersion(at: root) == 99)
        #expect(!Self.columnExists(at: root, table: "learning_goals", column: "summary"))

        let migrated = try KnowledgeStore(storeDirectory: root)
        #expect(Self.userVersion(at: root) == KnowledgeStore.schemaVersion)
        #expect(Self.columnExists(at: root, table: "learning_goals", column: "summary"))

        let goals = try migrated.loadLearningGoals()
        #expect(goals.map(\.id) == [notebookID])
        #expect(goals.first?.summary == nil)

        try migrated.setLearningGoalSummary(goalID: notebookID, summary: "Plaques, tangles, and what the trials taught")
        #expect(try migrated.loadLearningGoal(notebookID)?.summary == "Plaques, tangles, and what the trials taught")
    }

    @Test("A Goal links to the Doc or Site it is for, unlinks with an explicit clear, and refuses an unknown id or a Notebook")
    func goalArtifactLink() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date()
        try store.saveArtifactRecord(ArtifactRecord(
            id: "site-1",
            title: "Rare mitochondrial diseases",
            homeNotebookID: nil,
            linkedNotebookIDs: [],
            createdAt: now,
            updatedAt: now
        ))
        let notebook = try store.createCompanionGoal(
            title: "Mitochondria", topic: "mitochondria",
            startAt: now, endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
        )
        let goal = try store.createCompanionGoal(
            title: "Make a site of the rare mitochondrial diseases", topic: "rare mitochondrial diseases",
            startAt: now, endAt: now.addingTimeInterval(7 * 86_400),
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [],
            artifactID: "site-1"
        )
        #expect(try store.loadLearningGoal(goal.id)?.linkedArtifactID == "site-1")
        try store.clearAllPendingSyncChanges()

        try store.setLearningGoalArtifact(goalID: goal.id, artifactID: nil)
        let unlinked = try #require(try store.loadLearningGoal(goal.id))
        #expect(unlinked.artifactID == "", "an unlink travels as an explicit clear, not as no opinion")
        #expect(unlinked.linkedArtifactID == nil)
        #expect(try store.pendingSyncChanges().contains {
            $0.entity == .learningGoal && $0.logicalKey == goal.id && $0.operation == .save
        })

        try store.setLearningGoalArtifact(goalID: goal.id, artifactID: " site-1 ")
        #expect(try store.loadLearningGoal(goal.id)?.linkedArtifactID == "site-1")

        #expect(throws: KnowledgeStoreError.self) {
            try store.setLearningGoalArtifact(goalID: goal.id, artifactID: "missing")
        }
        #expect(try store.loadLearningGoal(goal.id)?.linkedArtifactID == "site-1", "a refused id changes nothing")
        #expect(throws: KnowledgeStoreError.self) {
            try store.setLearningGoalArtifact(goalID: notebook.id, artifactID: "site-1")
        }
        #expect(try store.loadLearningGoal(notebook.id)?.linkedArtifactID == nil)
        #expect(throws: KnowledgeStoreError.self) {
            _ = try store.createCompanionGoal(
                title: "Typo", topic: "typo",
                startAt: now, endAt: now.addingTimeInterval(86_400),
                dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [],
                artifactID: "missing"
            )
        }
        #expect(try store.loadLearningGoals().map(\.title).contains("Typo") == false, "a refused creation writes nothing")
    }

    @Test("An inbound goal payload with no opinion on the artifact keeps the local link; an explicit clear wins")
    func goalArtifactSyncMerge() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date()
        try store.saveArtifactRecord(ArtifactRecord(
            id: "site-1", title: "Rare mitochondrial diseases",
            homeNotebookID: nil, linkedNotebookIDs: [], createdAt: now, updatedAt: now
        ))
        let goal = try store.createCompanionGoal(
            title: "Make the site", topic: "site",
            startAt: now, endAt: now.addingTimeInterval(7 * 86_400),
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [],
            artifactID: "site-1"
        )

        // An older device's record: it does not know the field.
        var older = try #require(try store.loadLearningGoal(goal.id))
        older.artifactID = nil
        older.updatedAt = now.addingTimeInterval(60)
        try store.saveLearningGoalRecord(older)
        #expect(try store.loadLearningGoal(goal.id)?.linkedArtifactID == "site-1", "NULL is no opinion")

        // A device that unlinked on purpose.
        var cleared = older
        cleared.artifactID = ""
        cleared.updatedAt = now.addingTimeInterval(120)
        try store.saveLearningGoalRecord(cleared)
        #expect(try store.loadLearningGoal(goal.id)?.artifactID == "", "an explicit clear wins")
        #expect(try store.loadLearningGoal(goal.id)?.linkedArtifactID == nil)
    }

    @Test("Goals take the learner's order: the listed first, the rest by deadline, only a moved row published, an empty list back to deadline order, and a Notebook, a finished Goal or an unknown id refused")
    func goalsReorder() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date()
        func goal(_ title: String, days: Double) throws -> LearningGoalRecord {
            try store.createCompanionGoal(
                title: title, topic: title, startAt: now, endAt: now.addingTimeInterval(days * 86_400),
                dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
            )
        }
        let soon = try goal("Due soon", days: 1)
        let week = try goal("Due in a week", days: 7)
        let month = try goal("Due in a month", days: 30)
        let done = try goal("Done already", days: 3)
        try store.setLearningGoalStatus(goalID: done.id, status: .done)
        let notebook = try store.createCompanionGoal(
            title: "Mitochondria", topic: "mitochondria",
            startAt: now, endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
        )
        func order() throws -> [String] {
            try store.loadLearningGoals().filter { $0.isGoal && !$0.isDone }.sorted(by: LearningGoalRecord.listOrder).map(\.id)
        }
        #expect(try order() == [soon.id, week.id, month.id], "never placed, the list reads by deadline")
        try store.clearAllPendingSyncChanges()

        // A subset places itself first; the rest keep the order they read.
        #expect(try store.reorderLearningGoals(goalIDs: [month.id]) == [month.id, soon.id, week.id])
        #expect(try order() == [month.id, soon.id, week.id])
        #expect(try store.loadLearningGoal(month.id)?.sortOrder == 0)
        #expect(try store.loadLearningGoal(soon.id)?.sortOrder == 1)
        #expect(try store.loadLearningGoal(week.id)?.sortOrder == 2)
        #expect(try store.loadLearningGoal(done.id)?.sortOrder == nil, "finished work is not placed")
        let published = Set(try store.pendingSyncChanges().filter { $0.entity == .learningGoal }.map(\.logicalKey))
        #expect(published == [month.id, soon.id, week.id])

        // The same order again writes nothing.
        try store.clearAllPendingSyncChanges()
        #expect(try store.reorderLearningGoals(goalIDs: [month.id, soon.id, week.id]) == [month.id, soon.id, week.id])
        #expect(try store.pendingSyncChanges().isEmpty, "a row whose place did not move is not republished")

        // One step down moves two rows and publishes two.
        #expect(try store.reorderLearningGoals(goalIDs: [soon.id, month.id, week.id]) == [soon.id, month.id, week.id])
        #expect(Set(try store.pendingSyncChanges().map(\.logicalKey)) == [soon.id, month.id])

        // A placed Goal keeps its place whatever its deadline does.
        var overdue = try #require(try store.loadLearningGoal(week.id))
        overdue.endAt = now.addingTimeInterval(-86_400)
        try store.saveLearningGoalRecord(overdue)
        #expect(try order() == [soon.id, month.id, week.id], "overdue, and still third")

        // A Goal set after the placement reads by deadline, below the placed ones.
        let newcomer = try goal("Set today, due tomorrow", days: 1.5)
        #expect(try order() == [soon.id, month.id, week.id, newcomer.id])
        #expect(try store.loadLearningGoal(newcomer.id)?.sortOrder == nil)

        // An empty list forgets every placement.
        try store.clearAllPendingSyncChanges()
        #expect(try store.reorderLearningGoals(goalIDs: []) == [week.id, soon.id, newcomer.id, month.id])
        #expect(try store.loadLearningGoals().filter { $0.isGoal }.allSatisfy { $0.sortOrder == nil })
        #expect(try order() == [week.id, soon.id, newcomer.id, month.id], "by deadline again, the overdue one first")
        #expect(Set(try store.pendingSyncChanges().map(\.logicalKey)) == [soon.id, month.id, week.id], "the newcomer had no placement to forget")

        for refused in [notebook.id, done.id, "missing"] {
            #expect(throws: KnowledgeStoreError.self) {
                try store.reorderLearningGoals(goalIDs: [soon.id, refused])
            }
        }
        #expect(try order() == [week.id, soon.id, newcomer.id, month.id], "a refusal changes nothing")
        #expect(try store.loadLearningGoal(soon.id)?.sortOrder == nil)
    }

    @Test("An inbound goal payload with no opinion on the order keeps the local placement; a placement made elsewhere travels")
    func goalOrderSyncMerge() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date()
        let goal = try store.createCompanionGoal(
            title: "Make the site", topic: "site",
            startAt: now, endAt: now.addingTimeInterval(7 * 86_400),
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
        )
        try store.reorderLearningGoals(goalIDs: [goal.id])
        #expect(try store.loadLearningGoal(goal.id)?.sortOrder == 0)

        // An older device's record: it does not know the field.
        var older = try #require(try store.loadLearningGoal(goal.id))
        older.sortOrder = nil
        older.updatedAt = now.addingTimeInterval(60)
        try store.saveLearningGoalRecord(older)
        #expect(try store.loadLearningGoal(goal.id)?.sortOrder == 0, "NULL is no opinion")

        // A device that placed the Goal elsewhere.
        var moved = older
        moved.sortOrder = 4
        moved.updatedAt = now.addingTimeInterval(120)
        try store.saveLearningGoalRecord(moved)
        #expect(try store.loadLearningGoal(goal.id)?.sortOrder == 4, "a placement travels")

        // The key rides the Codable payload and an older decoder ignores it.
        let data = try JSONEncoder().encode(moved)
        #expect(String(data: data, encoding: .utf8)?.contains("\"sortOrder\":4") == true)
        let decoded = try JSONDecoder().decode(LearningGoalRecord.self, from: data)
        #expect(decoded.sortOrder == 4)
    }

    @Test("Schema 125 adds the Goal order column to a schema-124 library, every row reading by deadline, with nothing queued")
    func sortOrderColumnMigratesFromSchema124() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-goal-order-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let soonID: String, laterID: String
        do {
            let store = try KnowledgeStore(storeDirectory: root)
            let now = Date()
            let later = try store.createCompanionGoal(
                title: "Understand the heart and Na/K work", topic: "heart",
                startAt: now, endAt: now.addingTimeInterval(14 * 86_400),
                dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
            )
            let soon = try store.createCompanionGoal(
                title: "Make a page of the mito biotech investors", topic: "investors",
                startAt: now, endAt: now.addingTimeInterval(2 * 86_400),
                dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
            )
            (soonID, laterID) = (soon.id, later.id)
            try store.clearAllPendingSyncChanges()
            // Back to the exact shape builds 121 and 122 (schema 124) wrote: no order column.
            try store.execForTesting("DROP VIEW IF EXISTS source_projection")
            try store.execForTesting("ALTER TABLE learning_goals DROP COLUMN sort_order")
            try store.execForTesting("PRAGMA user_version = 124")
        }
        #expect(Self.userVersion(at: root) == 124)
        #expect(!Self.columnExists(at: root, table: "learning_goals", column: "sort_order"))

        let started = Date()
        let migrated = try KnowledgeStore(storeDirectory: root)
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 1.0, "the DDL-only migration took \(elapsed)s")
        #expect(Self.userVersion(at: root) == KnowledgeStore.schemaVersion)
        #expect(Self.columnExists(at: root, table: "learning_goals", column: "sort_order"))
        #expect(try migrated.pendingSyncChanges().isEmpty, "a schema-only migration republishes no record")
        #expect(Self.scalarInt(at: root, "SELECT COUNT(*) FROM learning_goals WHERE sort_order IS NULL") == 2, "NULL is the truth about every old row")

        let goals = try migrated.loadLearningGoals().sorted(by: LearningGoalRecord.listOrder)
        #expect(goals.map(\.id) == [soonID, laterID], "by deadline, as before")
        #expect(goals.allSatisfy { $0.sortOrder == nil })

        // The column works at once.
        #expect(try migrated.reorderLearningGoals(goalIDs: [laterID]) == [laterID, soonID])
        #expect(Self.scalarInt(at: root, "SELECT sort_order FROM learning_goals WHERE id = '\(laterID)'") == 0)
        #expect(try migrated.loadLearningGoals().sorted(by: LearningGoalRecord.listOrder).map(\.id) == [laterID, soonID])
    }

    @Test("A failure later in the v125 transaction takes the order column with it and leaves the store at 124")
    func sortOrderColumnRollsBackFromSchema124() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-goal-order-rollback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let store = try KnowledgeStore(storeDirectory: root)
            let now = Date()
            _ = try store.createCompanionGoal(
                title: "Understand the heart and Na/K work", topic: "heart",
                startAt: now, endAt: now.addingTimeInterval(14 * 86_400),
                dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
            )
            try store.execForTesting("DROP VIEW IF EXISTS source_projection")
            try store.execForTesting("ALTER TABLE learning_goals DROP COLUMN sort_order")
            try store.execForTesting("PRAGMA user_version = 124")
            // The 125 step is one ALTER TABLE, which cannot fail on its own
            // once the column is missing, so the failure is put after it: a
            // same-named table of another shape, whose index the installer
            // cannot create. The ALTER ran inside the same transaction and
            // has to go with it.
            try store.execForTesting("DROP INDEX IF EXISTS idx_learning_bouts_plan")
            try store.execForTesting("DROP TABLE IF EXISTS learning_bouts")
            try store.execForTesting("CREATE TABLE learning_bouts (foo TEXT)")
        }

        #expect(throws: (any Error).self) {
            _ = try KnowledgeStore(storeDirectory: root)
        }
        #expect(Self.userVersion(at: root) == 124, "the stamp is the last write, so it never landed")
        #expect(!Self.columnExists(at: root, table: "learning_goals", column: "sort_order"), "the column was added inside the transaction and went with it")
        #expect(Self.scalarInt(at: root, "SELECT COUNT(*) FROM learning_goals") == 1, "the Goal is as the older build left it")
    }

    @Test("Schema 121 adds the Goal artifact column to a schema-120 library")
    func artifactColumnMigratesFromSchema120() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-goal-artifact-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let goalID: String
        do {
            let store = try KnowledgeStore(storeDirectory: root)
            let now = Date()
            let goal = try store.createCompanionGoal(
                title: "Make a site of the rare mitochondrial diseases",
                topic: "rare mitochondrial diseases",
                startAt: now,
                endAt: now.addingTimeInterval(7 * 86_400),
                dailyTarget: 3,
                discoveryEnabled: false,
                seedSourceIDs: []
            )
            goalID = goal.id
            // Back to the exact shape build 114 (schema 120) wrote: no artifact column.
            try store.execForTesting("ALTER TABLE learning_goals DROP COLUMN artifact_id")
            try store.execForTesting("PRAGMA user_version = 120")
        }
        #expect(Self.userVersion(at: root) == 120)
        #expect(!Self.columnExists(at: root, table: "learning_goals", column: "artifact_id"))

        let migrated = try KnowledgeStore(storeDirectory: root)
        #expect(Self.userVersion(at: root) == KnowledgeStore.schemaVersion)
        #expect(Self.columnExists(at: root, table: "learning_goals", column: "artifact_id"))

        let goals = try migrated.loadLearningGoals()
        #expect(goals.map(\.id) == [goalID])
        #expect(goals.first?.artifactID == nil)
        #expect(goals.first?.linkedArtifactID == nil)

        let now = Date()
        try migrated.saveArtifactRecord(ArtifactRecord(
            id: "site-1", title: "Rare mitochondrial diseases",
            homeNotebookID: nil, linkedNotebookIDs: [], createdAt: now, updatedAt: now
        ))
        try migrated.setLearningGoalArtifact(goalID: goalID, artifactID: "site-1")
        #expect(try migrated.loadLearningGoal(goalID)?.linkedArtifactID == "site-1")
    }

    private static func scalarInt(at root: URL, _ sql: String) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("knowledge.db").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        var value = -1
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            value = Int(sqlite3_column_int64(statement, 0))
        }
        sqlite3_finalize(statement)
        return value
    }

    private static func userVersion(at root: URL) -> Int32 {
        Int32(scalarInt(at: root, "PRAGMA user_version"))
    }

    private static func columnExists(at root: URL, table: String, column: String) -> Bool {
        scalarInt(at: root, "SELECT COUNT(*) FROM pragma_table_info('\(table)') WHERE name = '\(column)'") == 1
    }

    @Test("A Goal's sources are always part of its parent Notebook")
    func goalSourcesCascadeToParentNotebook() throws {
        let store = try KnowledgeStore(inMemory: true)
        let start = Date()
        let notebook = try store.createCompanionGoal(
            title: "Mitochondria",
            topic: "mitochondria",
            startAt: start,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["notebook-only"]
        )
        let goal = try store.createCompanionGoal(
            title: "Write the briefing",
            topic: "mitochondrial transplantation",
            startAt: start,
            endAt: start.addingTimeInterval(7 * 86_400),
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["goal-seed"],
            parentNotebookID: notebook.id
        )

        #expect(throws: (any Error).self) {
            _ = try store.createCompanionGoal(
                title: "Invalid nested Goal",
                topic: "nesting",
                startAt: start,
                endAt: start.addingTimeInterval(7 * 86_400),
                dailyTarget: 3,
                discoveryEnabled: false,
                seedSourceIDs: [],
                parentNotebookID: goal.id
            )
        }

        var reloadedNotebook = try #require(try store.loadLearningGoal(notebook.id))
        #expect(Set(reloadedNotebook.approvedSourceIDs) == ["notebook-only", "goal-seed"])

        try store.addCompanionSeedSources(goalID: goal.id, sourceIDs: ["goal-added"])
        reloadedNotebook = try #require(try store.loadLearningGoal(notebook.id))
        #expect(Set(reloadedNotebook.approvedSourceIDs) == ["notebook-only", "goal-seed", "goal-added"])

        let otherNotebook = try store.createCompanionGoal(
            title: "Writing",
            topic: "writing",
            startAt: start,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )
        try store.setLearningGoalParentNotebook(goalID: goal.id, parentNotebookID: otherNotebook.id)
        let reparentedPool = try #require(try store.loadLearningGoal(otherNotebook.id))
        #expect(Set(reparentedPool.approvedSourceIDs) == ["goal-seed", "goal-added"])
    }

    @Test("A Notebook cannot be deleted while it owns Goals")
    func notebookDeletionCannotOrphanGoals() throws {
        let store = try KnowledgeStore(inMemory: true)
        let start = Date()
        let notebook = try store.createCompanionGoal(
            title: "Mitochondria",
            topic: "mitochondria",
            startAt: start,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )
        let goal = try store.createCompanionGoal(
            title: "Write the review",
            topic: "mitochondria",
            startAt: start,
            endAt: start.addingTimeInterval(7 * 86_400),
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: [],
            parentNotebookID: notebook.id
        )

        #expect(throws: (any Error).self) {
            try store.deleteLearningGoal(notebook.id)
        }
        #expect(try store.loadLearningGoal(notebook.id) != nil)
        #expect(try store.loadLearningGoal(goal.id)?.parentNotebookID == notebook.id)

        try store.deleteLearningGoal(goal.id)
        try store.deleteLearningGoal(notebook.id)
        #expect(try store.loadLearningGoal(notebook.id) == nil)
    }

    @Test("Deleting a Notebook with cascade takes its Goals with it")
    func notebookDeletionCascadesToGoals() throws {
        let store = try KnowledgeStore(inMemory: true)
        let start = Date()
        let notebook = try store.createCompanionGoal(
            title: "Mitochondria",
            topic: "mitochondria",
            startAt: start,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )
        let goalIDs = try (1...2).map { index in
            try store.createCompanionGoal(
                title: "Goal \(index)",
                topic: "mitochondria",
                startAt: start,
                endAt: start.addingTimeInterval(7 * 86_400),
                dailyTarget: 3,
                discoveryEnabled: false,
                seedSourceIDs: [],
                parentNotebookID: notebook.id
            ).id
        }
        // A Goal outside the Notebook is a bystander: the cascade is scoped to
        // `parent_notebook_id`, not to every Goal that shares the topic.
        let unrelated = try store.createCompanionGoal(
            title: "Unrelated",
            topic: "mitochondria",
            startAt: start,
            endAt: start.addingTimeInterval(7 * 86_400),
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )

        #expect(try store.childGoalIDs(ofNotebook: notebook.id).count == 2)
        try store.deleteLearningGoal(notebook.id, cascadeChildGoals: true)

        #expect(try store.loadLearningGoal(notebook.id) == nil)
        for goalID in goalIDs {
            #expect(try store.loadLearningGoal(goalID) == nil)
        }
        #expect(try store.loadLearningGoal(unrelated.id) != nil)
    }

    @Test("Deleting a Notebook tombstones it and every Goal it cascades")
    func notebookDeletionTombstonesItselfAndItsGoals() throws {
        let store = try KnowledgeStore(inMemory: true)
        let start = Date()
        let notebook = try store.createCompanionGoal(
            title: "Mitochondria",
            topic: "mitochondria",
            startAt: start,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )
        let childGoal = try store.createCompanionGoal(
            title: "Write the review",
            topic: "mitochondria",
            startAt: start,
            endAt: start.addingTimeInterval(7 * 86_400),
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: [],
            parentNotebookID: notebook.id
        )
        try store.clearAllPendingSyncChanges()

        try store.deleteLearningGoal(notebook.id, cascadeChildGoals: true)

        // The tombstone is the only thing standing between a deleted Notebook and
        // the copy CloudKit still holds. Every deleted row gets one, and each one
        // is queued as a delete so the server copy goes too.
        let pending = try store.pendingSyncChanges()
        for goalID in [notebook.id, childGoal.id] {
            let loaded = try store.loadSyncMetadata(entity: .learningGoal, logicalKey: goalID)
            let metadata = try #require(loaded)
            #expect(metadata.isDeleted)
            #expect(pending.contains {
                $0.entity == .learningGoal && $0.logicalKey == goalID && $0.operation == .delete
            })
        }
    }

    @Test("A deleted Notebook cannot be written back by a stale copy")
    func deletedNotebookIsNotResurrectedByAStaleSave() throws {
        let store = try KnowledgeStore(inMemory: true)
        let notebook = try store.createCompanionGoal(
            title: "Mitochondria",
            topic: "mitochondria",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )
        let staleCopy = try #require(try store.loadLearningGoal(notebook.id))
        try store.deleteLearningGoal(notebook.id)

        // A view that outlived its Notebook, or an inbound merge adopting a
        // server record this device already deleted, both land here. The upsert
        // would otherwise re-create the row and republish it to every device.
        try store.saveLearningGoalRecord(staleCopy)

        #expect(try store.loadLearningGoal(notebook.id) == nil)
        let loaded = try store.loadSyncMetadata(entity: .learningGoal, logicalKey: notebook.id)
        let metadata = try #require(loaded)
        #expect(metadata.isDeleted)
        #expect(try store.pendingSyncChanges().contains {
            $0.entity == .learningGoal && $0.logicalKey == notebook.id && $0.operation == .delete
        })
    }

    @Test("Marking a deleted Notebook changed leaves its deletion queued")
    func markingDeletedNotebookChangedKeepsTheDeletion() throws {
        let store = try KnowledgeStore(inMemory: true)
        let notebook = try store.createCompanionGoal(
            title: "Mitochondria",
            topic: "mitochondria",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )
        try store.deleteLearningGoal(notebook.id)

        // A save queued for a row that no longer exists can only recreate the
        // record on the server; it must not displace the pending delete.
        try store.markRecordChanged(entity: .learningGoal, logicalKey: notebook.id)

        let loaded = try store.loadSyncMetadata(entity: .learningGoal, logicalKey: notebook.id)
        let metadata = try #require(loaded)
        #expect(metadata.isDeleted)
        let changes = try store.pendingSyncChanges().filter {
            $0.entity == .learningGoal && $0.logicalKey == notebook.id
        }
        #expect(changes.count == 1)
        #expect(changes.first?.operation == .delete)
    }

    @Test("Deleting a Notebook keeps its chats ungrouped by default")
    func notebookDeletionKeepsChatsUngroupedByDefault() throws {
        let store = try KnowledgeStore(inMemory: true)
        let start = Date()
        let notebook = try store.createCompanionGoal(
            title: "Mitochondria",
            topic: "mitochondria",
            startAt: start,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )
        let childGoal = try store.createCompanionGoal(
            title: "Write the review",
            topic: "mitochondria",
            startAt: start,
            endAt: start.addingTimeInterval(7 * 86_400),
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: [],
            parentNotebookID: notebook.id
        )
        try store.createReviewSession(
            id: "notebook-chat",
            topic: "Notebook chat",
            sourceIDs: [],
            goalID: notebook.id
        )
        try store.createReviewSession(
            id: "goal-chat",
            topic: "Goal chat",
            sourceIDs: [],
            goalID: childGoal.id
        )
        try store.createReviewSession(
            id: "loose-chat",
            topic: "Loose chat",
            sourceIDs: []
        )
        try store.clearAllPendingSyncChanges()

        try store.deleteLearningGoal(notebook.id, cascadeChildGoals: true)

        let sessions = Dictionary(
            uniqueKeysWithValues: try store.loadReviewSessionLinks().map { ($0.id, $0) }
        )
        #expect(sessions["notebook-chat"]?.goalID == nil)
        #expect(sessions["goal-chat"]?.goalID == nil)
        #expect(sessions["loose-chat"] != nil)
        let pending = try store.pendingSyncChanges()
        for sessionID in ["notebook-chat", "goal-chat"] {
            #expect(pending.contains {
                $0.entity == .reviewSession
                    && $0.logicalKey == sessionID
                    && $0.operation == .save
            })
        }
    }

    @Test("Deleting a Notebook can delete all of its chats")
    func notebookDeletionCanDeleteChats() throws {
        let store = try KnowledgeStore(inMemory: true)
        let start = Date()
        let notebook = try store.createCompanionGoal(
            title: "Mitochondria",
            topic: "mitochondria",
            startAt: start,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )
        let childGoal = try store.createCompanionGoal(
            title: "Write the review",
            topic: "mitochondria",
            startAt: start,
            endAt: start.addingTimeInterval(7 * 86_400),
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: [],
            parentNotebookID: notebook.id
        )
        try store.createReviewSession(
            id: "notebook-chat",
            topic: "Notebook chat",
            sourceIDs: [],
            goalID: notebook.id
        )
        try store.createReviewSession(
            id: "goal-chat",
            topic: "Goal chat",
            sourceIDs: [],
            goalID: childGoal.id
        )
        try store.createReviewSession(
            id: "loose-chat",
            topic: "Loose chat",
            sourceIDs: []
        )
        try store.clearAllPendingSyncChanges()

        try store.deleteLearningGoal(
            notebook.id,
            cascadeChildGoals: true,
            deleteLinkedChats: true
        )

        let sessionIDs = Set(try store.loadReviewSessionLinks().map(\.id))
        #expect(!sessionIDs.contains("notebook-chat"))
        #expect(!sessionIDs.contains("goal-chat"))
        #expect(sessionIDs.contains("loose-chat"))
        let pending = try store.pendingSyncChanges()
        for sessionID in ["notebook-chat", "goal-chat"] {
            #expect(pending.contains {
                $0.entity == .reviewSession
                    && $0.logicalKey == sessionID
                    && $0.operation == .delete
            })
        }
    }

    @Test("Reordering a companion pool persists a study order and queues sync")
    func reorderCompanionPool() throws {
        let store = try KnowledgeStore(inMemory: true)
        let startAt = Date()
        let goal = try store.createCompanionGoal(
            title: "Sequencing",
            description: nil,
            topic: "sequencing",
            startAt: startAt,
            endAt: startAt.addingTimeInterval(7 * 24 * 60 * 60),
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["s-a", "s-b", "s-c", "s-d"]
        )
        try store.clearAllPendingSyncChanges()

        // Partial reorder: listed sources go first, the rest keep their relative order.
        try store.reorderCompanionSources(goalID: goal.id, orderedSourceIDs: ["s-c", "s-a"])

        let reordered = try #require(try store.loadLearningGoal(goal.id))
        #expect(reordered.approvedSourceIDs == ["s-c", "s-a", "s-b", "s-d"])
        #expect(try store.pendingSyncChanges().contains {
            $0.entity == .learningGoal
                && $0.logicalKey == goal.id
                && $0.operation == .save
        })

        // A source added later is unsequenced and lands after the sequenced pool.
        try store.addCompanionSeedSources(goalID: goal.id, sourceIDs: ["s-e"])
        let appended = try #require(try store.loadLearningGoal(goal.id))
        #expect(appended.approvedSourceIDs == ["s-c", "s-a", "s-b", "s-d", "s-e"])

        // Sources outside the approved pool are rejected.
        #expect(throws: (any Error).self) {
            try store.reorderCompanionSources(goalID: goal.id, orderedSourceIDs: ["not-in-pool"])
        }
    }

    @Test("Editing settings of a legacy Schedule goal is rejected")
    func updateSettingsRejectsLegacyGoal() throws {
        let store = try KnowledgeStore(inMemory: true)
        let goal = try store.createLearningGoal(
            title: "This Week",
            startAt: Date(),
            endAt: Date().addingTimeInterval(7 * 24 * 60 * 60),
            sourceIDs: ["source-1"]
        )

        #expect(throws: (any Error).self) {
            try store.updateCompanionGoalSettings(
                goalID: goal.id,
                title: "Renamed",
                description: nil,
                topic: "topic",
                endAt: Date().addingTimeInterval(14 * 24 * 60 * 60),
                dailyTarget: 3,
                discoveryEnabled: false
            )
        }
    }

    @Test("Recent companion sessions list completed reviews newest first")
    func companionRecentSessions() throws {
        let store = try KnowledgeStore(inMemory: true)
        let startAt = Date()
        let source = StudioArticle(
            url: "https://example.com/source",
            title: "Test Source",
            sourceType: .article,
            id: "source-1"
        )
        try store.saveSource(source)
        let goal = try store.createCompanionGoal(
            title: "Linear Algebra",
            topic: "linear algebra",
            startAt: startAt,
            endAt: startAt.addingTimeInterval(7 * 24 * 60 * 60),
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["source-1"]
        )

        try store.createReviewSession(id: "session-old", topic: "Day 1", sourceIDs: ["source-1"], startedAt: startAt, goalID: goal.id)
        try store.completeReviewSession(sessionID: "session-old", overallScore: 0.6, summary: "Shaky on rank", endedAt: startAt.addingTimeInterval(60))
        try store.createReviewSession(id: "session-new", topic: "Day 2", sourceIDs: ["source-1"], startedAt: startAt.addingTimeInterval(86_400), goalID: goal.id)
        try store.completeReviewSession(sessionID: "session-new", overallScore: 0.9, summary: "Solid", endedAt: startAt.addingTimeInterval(86_460))
        // Active sessions and sessions for other goals are excluded.
        try store.createReviewSession(id: "session-active", topic: "Day 3", sourceIDs: ["source-1"], startedAt: startAt.addingTimeInterval(172_800), goalID: goal.id)
        try store.createReviewSession(id: "session-unlinked", topic: "Other", sourceIDs: ["source-1"], startedAt: startAt)
        try store.completeReviewSession(sessionID: "session-unlinked", overallScore: 0.5, summary: "Other goal", endedAt: startAt.addingTimeInterval(120))

        let sessions = try store.companionRecentSessions(goalID: goal.id, limit: 4)

        #expect(sessions.map(\.id) == ["session-new", "session-old"])
        #expect(sessions.first?.overallScore == 0.9)
        #expect(sessions.first?.summary == "Solid")
    }

    @Test("Split companion goal moves sources and linked gaps into child notebooks")
    func splitCompanionGoalMovesState() throws {
        let store = try KnowledgeStore(inMemory: true)
        let startAt = Date()
        let parent = try store.createCompanionGoal(
            title: "Mitochondria",
            topic: "mitochondria",
            startAt: startAt,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["src-a", "src-b", "src-c"]
        )
        try store.recordCompanionQuiz(goalID: parent.id, sourceIDs: ["src-a"], score: 0.8, quizDate: "2026-06-22")
        let gap = LearningGoalGap(
            id: "gap-1",
            goalID: parent.id,
            summary: "How does OXPHOS couple proton flow to ATP?",
            sourceID: "src-b",
            status: "open",
            severity: 0.7,
            firstSeenAt: startAt,
            lastSeenAt: startAt,
            resolvedAt: nil,
            sessionID: nil
        )
        try store.upsertCompanionGaps(goalID: parent.id, gaps: [gap])

        let result = try store.splitCompanionGoal(
            sourceGoalID: parent.id,
            splits: [
                CompanionGoalSplitSpec(title: "OXPHOS", topic: nil, sourceIDs: ["src-b"], gapIDs: []),
                CompanionGoalSplitSpec(title: "Biogenesis", topic: nil, sourceIDs: ["src-c"], gapIDs: []),
            ],
            keepParent: true
        )

        #expect(result.parentGoalID == parent.id)
        #expect(result.childGoalIDs.count == 2)

        let refreshedParent = try store.loadLearningGoal(parent.id)
        #expect(refreshedParent?.approvedSourceIDs == ["src-a"])

        let children = try result.childGoalIDs.compactMap { try store.loadLearningGoal($0) }
        #expect(Set(children.map(\.title)) == ["OXPHOS", "Biogenesis"])
        let oxphos = try #require(children.first { $0.title == "OXPHOS" })
        let biogenesis = try #require(children.first { $0.title == "Biogenesis" })
        #expect(Set(oxphos.approvedSourceIDs) == ["src-b"])
        #expect(Set(biogenesis.approvedSourceIDs) == ["src-c"])

        let oxphosGaps = try store.loadLearningGoalGaps(goalID: oxphos.id)
        #expect(oxphosGaps.map(\.id) == ["gap-1"])
        #expect(try store.loadLearningGoalGaps(goalID: biogenesis.id).isEmpty)

        let oxphosItem = oxphos.items.first { $0.sourceID == "src-b" }
        #expect(oxphosItem?.sourceID == "src-b")
    }

    // Pins generation 1: it deletes the merged notebook and an emptied parent and queues their rows in
    // sync_changes. Generation 2 keeps a redirect stub instead (NotebookMergeSplitTests); this goes with
    // generation 1 at the post-soak cleanup.
    @Test("Merge companion goals unions pools and deletes merged notebooks")
    func mergeCompanionGoalsUnionsPools() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let startAt = Date()
        let survivor = try store.createCompanionGoal(
            title: "Mitochondria",
            topic: "mitochondria",
            startAt: startAt,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["src-a"]
        )
        try store.setLearningGoalNotes(goalID: survivor.id, notes: "Parent notes")
        let other = try store.createCompanionGoal(
            title: "OXPHOS",
            topic: "oxphos",
            startAt: startAt,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["src-b"]
        )
        try store.setLearningGoalNotes(goalID: other.id, notes: "Child notes")
        try store.upsertCompanionGaps(goalID: other.id, gaps: [
            LearningGoalGap(
                id: "gap-2",
                goalID: other.id,
                summary: "What is complex I?",
                sourceID: "src-b",
                status: "open",
                severity: 0.5,
                firstSeenAt: startAt,
                lastSeenAt: startAt,
                resolvedAt: nil,
                sessionID: nil
            ),
        ])

        let result = try store.mergeCompanionGoals(
            notebookIDs: [survivor.id, other.id],
            title: "Mitochondria (merged)",
            mergeNotes: true
        )

        #expect(result.survivorGoalID == survivor.id)
        #expect(result.mergedGoalIDs == [other.id])
        #expect(result.sourcesAdded == 1)
        #expect(result.gapsAdded == 1)
        #expect(try store.loadLearningGoal(other.id) == nil)

        let merged = try store.loadLearningGoal(survivor.id)
        #expect(merged?.title == "Mitochondria (merged)")
        #expect(Set(merged?.approvedSourceIDs ?? []) == ["src-a", "src-b"])
        let mergedNotes = merged?.notes ?? ""
        #expect(mergedNotes.contains("Parent notes"))
        #expect(mergedNotes.contains("Child notes"))
        #expect(try store.loadLearningGoalGaps(goalID: survivor.id).map(\.id) == ["gap-2"])
    }

    // Pins generation 1: it deletes the merged notebook and an emptied parent and queues their rows in
    // sync_changes. Generation 2 keeps a redirect stub instead (NotebookMergeSplitTests); this goes with
    // generation 1 at the post-soak cleanup.
    @Test("Merging Notebooks carries chats, Goals, tasks, Docs, planner records and links to the survivor")
    func mergeCompanionGoalsMovesEverything() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let startAt = Date()
        let survivor = try store.createCompanionGoal(
            title: "Mito Phenotyping",
            topic: "mito phenotyping",
            startAt: startAt,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["src-a"]
        )
        try store.setLearningGoalResearchQuestions(
            goalID: survivor.id,
            questions: ["How can we measure mitochondrial function in vivo?"]
        )
        let other = try store.createCompanionGoal(
            title: "Mitochondria",
            topic: "mitochondria",
            startAt: startAt,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["src-a", "src-b"]
        )
        try store.setLearningGoalResearchQuestions(
            goalID: other.id,
            questions: [
                "how can we measure mitochondrial function in vivo?",
                "Are mtDNA mutations important in aging?",
            ]
        )
        try store.setLearningGoalDescription(goalID: other.id, description: "Understand mitochondria")
        let bystander = try store.createCompanionGoal(
            title: "GDF15",
            topic: "gdf15",
            startAt: startAt,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["src-c"]
        )

        try store.createReviewSession(id: "chat-1", topic: "Uncouplers", sourceIDs: [], goalID: other.id)
        try store.createReviewSession(id: "chat-2", topic: "Elsewhere", sourceIDs: [], goalID: bystander.id)
        let childGoal = try store.createCompanionGoal(
            title: "Read Picard",
            topic: "picard",
            startAt: startAt,
            endAt: startAt.addingTimeInterval(7 * 86_400),
            dailyTarget: 1,
            discoveryEnabled: false,
            seedSourceIDs: [],
            parentNotebookID: other.id
        )
        try store.saveNotebookTask(NotebookTaskRecord(id: "task-1", notebookID: other.id, title: "Draft the crosswalk"))
        try store.saveArtifactRecord(ArtifactRecord(
            id: "doc-1",
            title: "Crosswalk",
            homeNotebookID: other.id,
            linkedNotebookIDs: [other.id, survivor.id],
            createdAt: startAt,
            updatedAt: startAt
        ))
        let scheduled = try store.saveScheduledTask(
            ScheduledTask(title: "Weekly digest", instruction: "Summarise the week.", notebookID: other.id)
        )
        var placed = StudioArticle(url: "https://example.org/uncouplers", title: "Uncouplers", sourceType: .article)
        try store.insertSourceIfNew(&placed)
        try store.addSourceToGoal(sourceID: placed.id, goalID: other.id, plannedAt: startAt)
        let block = try store.addTimeBlock(
            TimeBlock(dayPlanID: "2026-09-19", startMinute: 540, endMinute: 600, title: "Read", notebookID: other.id)
        )
        try store.saveMemoryItem(MemoryItem(
            id: "memory-1",
            kind: .concept,
            target: "Explain proton leak.",
            rubricJSON: "{}",
            goalID: other.id,
            sources: [
                MemoryItemSource(
                    id: "anchor-memory-1",
                    memoryItemID: "memory-1",
                    sourceID: placed.id,
                    locatorJSON: #"{"kind":"text","start":0,"end":40}"#,
                    excerpt: "Uncouplers dissipate the proton gradient.",
                    sourceSHA256: String(repeating: "a", count: 64),
                    sortIndex: 0
                ),
            ]
        ))
        try store.setRelatedNotebooks(notebookID: other.id, relatedNotebookIDs: [bystander.id])
        try store.setRelatedNotebooks(notebookID: bystander.id, relatedNotebookIDs: [other.id])
        try store.setJournalWatchNotebookExcluded(other.id, excluded: true)
        try store.clearAllPendingSyncChanges()

        let result = try store.mergeCompanionGoals(notebookIDs: [survivor.id, other.id])

        #expect(result.survivorGoalID == survivor.id)
        #expect(result.mergedGoalIDs == [other.id])
        #expect(result.sourcesAdded == 1)
        #expect(result.chatsMoved == 1)
        #expect(result.childGoalsMoved == 1)
        #expect(result.tasksMoved == 1)
        #expect(result.docsMoved == 1)
        #expect(try store.loadLearningGoal(other.id) == nil)

        let merged = try #require(try store.loadLearningGoal(survivor.id))
        #expect(merged.title == "Mito Phenotyping")
        #expect(Set(merged.approvedSourceIDs) == ["src-a", "src-b"])
        #expect(merged.researchQuestions == [
            "How can we measure mitochondrial function in vivo?",
            "Are mtDNA mutations important in aging?",
        ])
        #expect(merged.description == "Understand mitochondria")
        #expect(merged.relatedNotebookIDs == [bystander.id])
        #expect(try store.loadLearningGoal(bystander.id)?.relatedNotebookIDs == [survivor.id])

        let sessions = Dictionary(uniqueKeysWithValues: try store.loadReviewSessionLinks().map { ($0.id, $0) })
        #expect(sessions["chat-1"]?.goalID == survivor.id)
        #expect(sessions["chat-2"]?.goalID == bystander.id)
        #expect(try store.loadLearningGoal(childGoal.id)?.parentNotebookID == survivor.id)
        #expect(try store.loadNotebookTasks(notebookID: survivor.id).map(\.id) == ["task-1"])
        let doc = try #require(try store.loadArtifact("doc-1"))
        #expect(doc.homeNotebookID == survivor.id)
        #expect(doc.linkedNotebookIDs == [survivor.id])
        #expect(try store.loadScheduledTask(scheduled.id)?.notebookID == survivor.id)
        #expect(try store.scheduledSourceGoalIDs(sourceID: placed.id) == [survivor.id])
        #expect(try store.loadTimeBlock(block.id)?.notebookID == survivor.id)
        #expect(try store.loadMemoryItem("memory-1")?.goalID == survivor.id)
        #expect(!(try store.journalWatchExcludedNotebookIDs()).contains(other.id))

        // Every re-pointed record is republished, and the merged Notebook gets
        // its tombstone, in the same transaction.
        let changes = try store.pendingSyncChanges()
        #expect(changes.contains { $0.entity == .reviewSession && $0.logicalKey == "chat-1" && $0.operation == .save })
        #expect(!changes.contains { $0.entity == .reviewSession && $0.logicalKey == "chat-2" })
        #expect(changes.contains { $0.entity == .learningGoal && $0.logicalKey == other.id && $0.operation == .delete })
        #expect(changes.contains { $0.entity == .learningGoal && $0.logicalKey == survivor.id && $0.operation == .save })
        #expect(changes.contains { $0.entity == .learningGoal && $0.logicalKey == bystander.id && $0.operation == .save })
        #expect(changes.contains { $0.entity == .learningGoal && $0.logicalKey == childGoal.id && $0.operation == .save })
        #expect(changes.contains { $0.entity == .notebookTask && $0.logicalKey == "task-1" && $0.operation == .save })
        #expect(changes.contains { $0.entity == .artifact && $0.logicalKey == "doc-1" && $0.operation == .save })
        #expect(changes.contains { $0.entity == .scheduledTask && $0.logicalKey == scheduled.id && $0.operation == .save })
        #expect(changes.contains { $0.entity == .dayPlan && $0.logicalKey == "2026-09-19" && $0.operation == .save })
        #expect(changes.contains { $0.entity == .memoryItem && $0.logicalKey == "memory-1" && $0.operation == .save })
    }

    @Test("Notebooks in different libraries refuse to merge")
    func mergeCompanionGoalsRefusesAcrossLibraries() throws {
        let store = try KnowledgeStore(inMemory: true)
        let startAt = Date()
        try store.saveTeam(TeamRecord(
            id: "team-1",
            name: "Nexus",
            role: .owner,
            permission: .readWrite,
            zoneScope: .privateScope,
            zoneName: TeamRecord.zoneName(forTeamID: "team-1"),
            zoneOwnerRecordName: nil,
            shareRecordName: nil,
            shareURL: nil,
            createdAt: startAt,
            joinedAt: startAt,
            updatedAt: startAt
        ))
        let own = try store.createCompanionGoal(
            title: "Mitochondria",
            topic: "mitochondria",
            startAt: startAt,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["src-a"]
        )
        let teamNotebook = try store.createCompanionGoal(
            title: "Mitochondria",
            topic: "mitochondria",
            startAt: startAt,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["src-b"],
            teamID: "team-1"
        )

        #expect(throws: KnowledgeStoreError.self) {
            try store.mergeCompanionGoals(notebookIDs: [own.id, teamNotebook.id])
        }
        #expect(try store.loadLearningGoal(own.id)?.approvedSourceIDs == ["src-a"])
        #expect(try store.loadLearningGoal(teamNotebook.id)?.approvedSourceIDs == ["src-b"])
    }

    // MARK: Merging and splitting leave nothing on the removed notebook

    // Pins generation 1: it deletes the merged notebook and an emptied parent and queues their rows in
    // sync_changes. Generation 2 keeps a redirect stub instead (NotebookMergeSplitTests); this goes with
    // generation 1 at the post-soak cleanup.
    @Test("Merging moves everything the merged notebook held, its courses, Ideas' links and Directions included, and deletes it the ordinary way")
    func mergeLeavesNothingOnTheMergedNotebook() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let survivor = try NotebookHoldings.makeNotebook(store, title: "Mito Phenotyping", sources: ["src-a"])
        let mergee = try NotebookHoldings.makeNotebook(store, title: "Mitochondria", sources: ["src-a", "src-b"])
        let bystander = try NotebookHoldings.makeNotebook(store, title: "GDF15")
        let held = try NotebookHoldings.file(under: mergee.id, in: store, tag: "merged", day: "2026-09-18")
        try store.setRelatedNotebooks(notebookID: bystander.id, relatedNotebookIDs: [mergee.id])
        try store.clearAllPendingSyncChanges()

        let result = try store.mergeCompanionGoals(notebookIDs: [survivor.id, mergee.id])

        #expect(result.mergedGoalIDs == [mergee.id])
        #expect(result.chatsMoved == 1)
        #expect(result.childGoalsMoved == 1)
        #expect(result.tasksMoved == 1)
        #expect(result.docsMoved == 1)
        #expect(try store.loadLearningGoal(mergee.id) == nil)
        #expect(try NotebookHoldings.references(to: mergee.id, in: store).isEmpty, "nothing points at the merged id")
        try held.expectFiled(under: survivor.id, in: store)
        #expect(try store.loadLearningGoal(bystander.id)?.relatedNotebookIDs == [survivor.id])

        let changes = try store.pendingSyncChanges()
        try held.expectQueued(in: changes)
        #expect(changes.contains { $0.entity == .learningGoal && $0.logicalKey == mergee.id && $0.operation == .delete })
        #expect(try store.loadSyncMetadata(entity: .learningGoal, logicalKey: mergee.id)?.isDeleted == true)
    }

    // Pins generation 1: it deletes the merged notebook and an emptied parent and queues their rows in
    // sync_changes. Generation 2 keeps a redirect stub instead (NotebookMergeSplitTests); this goes with
    // generation 1 at the post-soak cleanup.
    @Test("A split that empties its parent moves everything else the parent held to the child that took the most sources, and deletes the parent the ordinary way")
    func splitHandsTheEmptiedParentToItsHeir() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let startAt = Date()
        let parent = try NotebookHoldings.makeNotebook(store, title: "Mitochondria", sources: ["src-a", "src-b", "src-c"])
        let bystander = try NotebookHoldings.makeNotebook(store, title: "GDF15")
        let held = try NotebookHoldings.file(under: parent.id, in: store, tag: "parent", day: "2026-09-17")
        try store.setRelatedNotebooks(notebookID: bystander.id, relatedNotebookIDs: [parent.id])
        try store.setRelatedNotebooks(notebookID: parent.id, relatedNotebookIDs: [bystander.id])
        // An open question tied to no source, which no split names.
        try store.upsertCompanionGaps(goalID: parent.id, gaps: [
            LearningGoalGap(
                id: "gap-unassigned", goalID: parent.id, summary: "Why does supercomplex assembly vary by tissue?",
                sourceID: nil, status: "open", severity: 0.5, firstSeenAt: startAt, lastSeenAt: startAt,
                resolvedAt: nil, sessionID: nil
            ),
        ])
        // The parent's own words, columns of the row the split deletes.
        try store.setLearningGoalNotes(goalID: parent.id, notes: "Supercomplexes look tissue-specific.")
        try store.setLearningGoalDescription(goalID: parent.id, description: "Answer from primary papers only.")
        try store.setLearningGoalResearchQuestions(goalID: parent.id, questions: ["Do supercomplexes raise OXPHOS flux?"])
        try store.setLearningGoalSummary(goalID: parent.id, summary: "Respiratory chain structure")
        try store.setNotebookRepository(notebookID: parent.id, repository: "example/mito-notes")
        try store.clearAllPendingSyncChanges()

        let result = try store.splitCompanionGoal(
            sourceGoalID: parent.id,
            splits: [
                CompanionGoalSplitSpec(title: "OXPHOS", topic: nil, sourceIDs: ["src-a"], gapIDs: []),
                CompanionGoalSplitSpec(title: "Biogenesis", topic: nil, sourceIDs: ["src-b", "src-c"], gapIDs: []),
            ],
            keepParent: false
        )

        #expect(result.parentGoalID == nil)
        #expect(result.childGoalIDs.count == 2)
        let heir = try #require(result.heirGoalID)
        #expect(heir == result.childGoalIDs[1], "Biogenesis took two sources")
        #expect(try store.loadLearningGoal(parent.id) == nil)
        #expect(try NotebookHoldings.references(to: parent.id, in: store).isEmpty, "nothing points at the removed parent")
        try held.expectFiled(under: heir, in: store)
        #expect(Set(try store.loadLearningGoal(heir)?.approvedSourceIDs ?? []) == ["src-b", "src-c"])
        #expect(try store.loadLearningGoalGaps(goalID: heir).map(\.id) == ["gap-unassigned"])
        #expect(try store.loadLearningGoal(heir)?.relatedNotebookIDs == [bystander.id])
        #expect(try store.loadLearningGoal(bystander.id)?.relatedNotebookIDs == [heir])
        // The parent's words are the heir's, by the merge rule: the notes
        // under the parent's title, the rest as written. The heir keeps its
        // own title.
        let heirRecord = try #require(try store.loadLearningGoal(heir))
        #expect(heirRecord.title == "Biogenesis")
        #expect(heirRecord.notes == "## Mitochondria\n\nSupercomplexes look tissue-specific.")
        #expect(heirRecord.description == "Answer from primary papers only.")
        #expect(heirRecord.researchQuestions == ["Do supercomplexes raise OXPHOS flux?"])
        #expect(heirRecord.summary == "Respiratory chain structure")
        #expect(heirRecord.repository == "example/mito-notes")
        // The other child got its sources and nothing else.
        let other = try #require(try store.loadLearningGoal(result.childGoalIDs[0]))
        #expect(other.approvedSourceIDs == ["src-a"])
        #expect(other.notes == nil && other.description == nil && (other.researchQuestions ?? []).isEmpty)
        #expect(try store.loadReviewSessionLinks().allSatisfy { $0.goalID != result.childGoalIDs[0] })

        let changes = try store.pendingSyncChanges()
        try held.expectQueued(in: changes)
        #expect(changes.contains { $0.entity == .learningGoal && $0.logicalKey == parent.id && $0.operation == .delete })
        #expect(changes.contains { $0.entity == .learningGoal && $0.logicalKey == heir && $0.operation == .save })
        #expect(changes.contains { $0.entity == .learningGoal && $0.logicalKey == bystander.id && $0.operation == .save })
        #expect(try store.loadSyncMetadata(entity: .learningGoal, logicalKey: parent.id)?.isDeleted == true)
    }

    @Test("Of children that took as many sources, the first split listed takes the emptied parent's place; a kept parent hands nothing on")
    func splitHeirTiesGoToTheFirstChild() throws {
        let store = try KnowledgeStore(inMemory: true)
        let emptied = try NotebookHoldings.makeNotebook(store, title: "Emptied", sources: ["src-a", "src-b"])
        try store.createReviewSession(id: "chat-emptied", topic: "Uncouplers", sourceIDs: [], goalID: emptied.id)
        let tie = try store.splitCompanionGoal(
            sourceGoalID: emptied.id,
            splits: [
                CompanionGoalSplitSpec(title: "First", topic: nil, sourceIDs: ["src-a"], gapIDs: []),
                CompanionGoalSplitSpec(title: "Second", topic: nil, sourceIDs: ["src-b"], gapIDs: []),
            ],
            keepParent: false
        )
        #expect(tie.heirGoalID == tie.childGoalIDs.first)
        #expect(try store.loadReviewSessionLinks().first { $0.id == "chat-emptied" }?.goalID == tie.childGoalIDs.first)

        let kept = try NotebookHoldings.makeNotebook(store, title: "Kept", sources: ["src-c", "src-d"])
        try store.createReviewSession(id: "chat-kept", topic: "Mitophagy", sourceIDs: [], goalID: kept.id)
        let stays = try store.splitCompanionGoal(
            sourceGoalID: kept.id,
            splits: [CompanionGoalSplitSpec(title: "Part", topic: nil, sourceIDs: ["src-c"], gapIDs: [])],
            keepParent: false
        )
        #expect(stays.parentGoalID == kept.id, "a parent with a source left is kept")
        #expect(stays.heirGoalID == nil)
        #expect(try store.loadReviewSessionLinks().first { $0.id == "chat-kept" }?.goalID == kept.id)
    }

    // Pins generation 1: it deletes the merged notebook and an emptied parent and queues their rows in
    // sync_changes. Generation 2 keeps a redirect stub instead (NotebookMergeSplitTests); this goes with
    // generation 1 at the post-soak cleanup.
    @Test("A team's Notebook splits into that team: the children live in its zone, and an emptied parent's deletion is queued there")
    func splitKeepsTheTeam() throws {
        let store = try KnowledgeStore(inMemory: true, syncGeneration: .one)
        let team = try NotebookHoldings.makeTeam(store)
        let parent = try NotebookHoldings.makeNotebook(store, title: "Nexus reading", sources: ["src-a", "src-b"], teamID: team.id)
        try store.createReviewSession(id: "chat-team", topic: "Complex I", sourceIDs: [], goalID: parent.id)
        try store.saveNotebookTask(NotebookTaskRecord(id: "task-team", notebookID: parent.id, title: "Summarise Picard"))
        try store.clearAllPendingSyncChanges()

        let result = try store.splitCompanionGoal(
            sourceGoalID: parent.id,
            splits: [
                CompanionGoalSplitSpec(title: "Complex I", topic: nil, sourceIDs: ["src-a"], gapIDs: []),
                CompanionGoalSplitSpec(title: "Complex III", topic: nil, sourceIDs: ["src-b"], gapIDs: []),
            ],
            keepParent: false
        )

        let children = try result.childGoalIDs.compactMap { try store.loadLearningGoal($0) }
        #expect(children.count == 2)
        #expect(children.allSatisfy { $0.teamID == team.id && $0.isNotebook })
        let changes = try store.pendingSyncChanges()
        for child in children {
            let change = try #require(changes.first { $0.entity == .learningGoal && $0.logicalKey == child.id })
            #expect(change.operation == .save)
            #expect(change.home.zoneName == team.home.zoneName, "a team's child is filed in the team's zone")
        }
        let deletion = try #require(changes.first { $0.entity == .learningGoal && $0.logicalKey == parent.id })
        #expect(deletion.operation == .delete)
        #expect(deletion.home.zoneName == team.home.zoneName)
        let heir = try #require(result.heirGoalID)
        #expect(try store.loadReviewSessionLinks().first { $0.id == "chat-team" }?.goalID == heir)
        let task = try #require(try store.loadNotebookTasks(notebookID: heir).first)
        #expect(task.id == "task-team")
        #expect(task.teamID == team.id)
    }

    @Test("A read-only team's Notebook does not split, and nothing is written")
    func splitRefusesAReadOnlyTeam() throws {
        let store = try KnowledgeStore(inMemory: true)
        let team = try NotebookHoldings.makeTeam(store)
        let parent = try NotebookHoldings.makeNotebook(store, title: "Nexus reading", sources: ["src-a", "src-b"], teamID: team.id)
        _ = try NotebookHoldings.makeTeam(store, permission: .readOnly)
        let before = try store.loadLearningGoals().count

        let refused = #expect(throws: KnowledgeStoreError.self) {
            try store.splitCompanionGoal(
                sourceGoalID: parent.id,
                splits: [CompanionGoalSplitSpec(title: "Complex I", topic: nil, sourceIDs: ["src-a"], gapIDs: [])],
                keepParent: true
            )
        }
        // The split's own guard refuses it, before its transaction opens. A
        // split that got past it would still fail later, on the sync queue's
        // read-only zone check ("This team is read-only for you; ask its
        // owner…"), and roll back, so only the message tells the two apart.
        if case .invalidData(let message)? = refused {
            #expect(message == "\(team.name) is read-only for you.")
        } else {
            Issue.record("expected the split's read-only refusal, got \(String(describing: refused))")
        }
        #expect(try store.loadLearningGoals().count == before)
        #expect(Set(try store.loadLearningGoal(parent.id)?.approvedSourceIDs ?? []) == ["src-a", "src-b"])
    }

    @Test("Related Notebooks provide directional context without copying membership")
    func relatedNotebooksProvideDirectionalContext() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date()
        let broad = try store.createCompanionGoal(
            title: "Mitochondria and aging",
            topic: "mitochondria and aging",
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["landscape-source"]
        )
        let focused = try store.createCompanionGoal(
            title: "GDF15",
            topic: "GDF15",
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["gdf15-source"]
        )

        try store.setRelatedNotebooks(notebookID: broad.id, relatedNotebookIDs: [focused.id])

        let loadedBroad = try store.loadLearningGoal(broad.id)
        let loadedFocused = try store.loadLearningGoal(focused.id)
        let refreshedBroad = try #require(loadedBroad)
        let refreshedFocused = try #require(loadedFocused)
        #expect(refreshedBroad.relatedNotebookIDs == [focused.id])
        #expect(refreshedBroad.approvedSourceIDs == ["landscape-source"])
        #expect(refreshedFocused.relatedNotebookIDs == [])
        #expect(try store.notebookContextSourceIDs(notebookID: broad.id) == [
            "landscape-source", "gdf15-source",
        ])
        #expect(try store.notebookContextSourceIDs(notebookID: focused.id) == ["gdf15-source"])
        #expect(try store.loadLearningGoalForSync(broad.id)?.goal.relatedNotebookIDs == [focused.id])

        try store.deleteLearningGoal(focused.id, cascadeChildGoals: true)
        #expect(try store.loadLearningGoal(broad.id)?.relatedNotebookIDs == [])
        #expect(try store.pendingSyncChanges().contains {
            $0.entity == .learningGoal && $0.logicalKey == broad.id
        })
    }

    @Test("Related Notebook links keep the order they were given, not the ids' order")
    func relatedNotebookLinksKeepTheirOrder() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date()
        func notebook(_ title: String) throws -> LearningGoalRecord {
            try store.createCompanionGoal(
                title: title,
                topic: title,
                startAt: now,
                endAt: LearningGoalRecord.openEndedEndAt,
                dailyTarget: 3,
                discoveryEnabled: false,
                seedSourceIDs: []
            )
        }
        let base = try notebook("Base")
        // Descending ids: the opposite of the order a single stamp fell back to.
        let linked = try [notebook("One"), notebook("Two"), notebook("Three")].map(\.id).sorted(by: >)

        try store.setRelatedNotebooks(notebookID: base.id, relatedNotebookIDs: linked)
        #expect(try store.loadLearningGoal(base.id)?.relatedNotebookIDs == linked)

        // A notebook added to context goes last.
        let added = try notebook("Four").id
        try store.setRelatedNotebooks(notebookID: base.id, relatedNotebookIDs: linked + [added])
        #expect(try store.loadLearningGoal(base.id)?.relatedNotebookIDs == linked + [added])
    }

}

// MARK: - Schema 153: links released from a deleted notebook

/// Schema 153 releases what an older build's merge or split left pointing at
/// the notebook it removed by a raw DELETE. Fixtures are today's tables at the
/// released stamp (151 to 153 added no DDL), and for 149 without the
/// `courses.home_notebook_id` column 150 added. They keep 154's DDL, which this
/// step never reads, so they cover 153's step and not 154's: the released
/// shapes for that are `Schema154Fixture`'s (SyncSchema154MigrationTests).
@Suite("Notebook link release migration")
struct NotebookLinkReleaseMigrationTests {
    private static func temporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookLinkRelease-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func scalar(at root: URL, _ sql: String) -> String? {
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

    private struct ReleasedLibrary {
        let keptID: String
        let goneID: String
        let held: NotebookHoldings
    }

    /// A released library at `version` holding two notebooks, everything
    /// filed under the second, and a chat filed under a Notebook CloudKit has
    /// not delivered. When `removeTheSecond` is set the second notebook was
    /// then removed the way merge and split did before 2026-10-02: a raw
    /// DELETE and a tombstone, its records left behind.
    private static func createReleasedLibrary(at root: URL, version: Int32, removeTheSecond: Bool = true) throws -> ReleasedLibrary {
        let store = try KnowledgeStore(storeDirectory: root)
        let kept = try NotebookHoldings.makeNotebook(store, title: "Mito Phenotyping", sources: ["src-a"])
        let gone = try NotebookHoldings.makeNotebook(store, title: "Mitochondria", sources: ["src-b"])
        let held = try NotebookHoldings.file(under: gone.id, in: store, tag: "gone", day: "2026-09-16")
        try store.setRelatedNotebooks(notebookID: kept.id, relatedNotebookIDs: [gone.id])
        try store.createReviewSession(id: "chat-undelivered", topic: "Arrives later", sourceIDs: [], goalID: "notebook-not-delivered-yet")
        if removeTheSecond {
            try store.execForTesting("DELETE FROM learning_goals WHERE id = '\(gone.id)'")
            try store.markRecordDeleted(entity: .learningGoal, logicalKey: gone.id)
        }
        try store.clearAllPendingSyncChanges()
        try store.execForTesting("""
            \(version < 150 ? "DROP INDEX IF EXISTS idx_courses_home_notebook; ALTER TABLE courses DROP COLUMN home_notebook_id;" : "")
            PRAGMA user_version = \(version);
        """)
        return ReleasedLibrary(keptID: kept.id, goneID: gone.id, held: held)
    }

    @Test("A fresh store is at the current schema and has nothing to release")
    func freshStore() throws {
        let root = try Self.temporaryRoot("fresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        #expect(Self.scalar(at: root, "PRAGMA user_version") == "171")
        #expect(KnowledgeStore.schemaVersion == 171)
        let released = try store.releaseLinksToDeletedNotebooks()
        #expect(released.deletedNotebooks == 0 && released.republished == 0)
    }

    @Test(
        "A released store lets go of a deleted notebook: every record it held is kept, unlinked and republished",
        arguments: [Int32(149), Int32(150)]
    )
    func version153ReleasesLinks(from released: Int32) throws {
        let root = try Self.temporaryRoot("v153-from-\(released)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Self.createReleasedLibrary(at: root, version: released)
        let held = library.held
        #expect(Self.scalar(at: root, "PRAGMA user_version") == "\(released)")
        #expect(Self.scalar(at: root, "SELECT COUNT(*) FROM sync_changes") == "0")

        let migrated = try KnowledgeStore(storeDirectory: root)
        #expect(Self.scalar(at: root, "PRAGMA user_version") == "\(KnowledgeStore.schemaVersion)")
        #expect(KnowledgeStore.schemaVersion == 171)

        // Every record is still there, and none of them names the gone notebook.
        let sessions = Dictionary(uniqueKeysWithValues: try migrated.loadReviewSessionLinks().map { ($0.id, $0) })
        #expect(sessions[held.chatID] != nil && sessions[held.chatID]?.goalID == nil)
        #expect(sessions["chat-undelivered"]?.goalID == "notebook-not-delivered-yet", "a Notebook not delivered yet keeps its chats")
        let nested = try #require(try migrated.loadLearningGoal(held.nestedGoalID))
        #expect(nested.parentNotebookID == nil && nested.isStandaloneGoal, "a nested Goal stands alone instead of being deleted")
        let doc = try #require(try migrated.loadArtifact(held.docID))
        #expect(doc.homeNotebookID == nil)
        #expect(doc.linkedNotebookIDs.isEmpty)
        #expect(try migrated.notebookIDsFollowingCourse(held.courseID).isEmpty, "the course stays; no notebook follows it")
        #expect(try migrated.loadScheduledTask(held.scheduledTaskID)?.notebookID == nil)
        #expect(try migrated.scheduledSourceGoalIDs(sourceID: held.placementSourceID).isEmpty)
        #expect(try migrated.scheduledPlacement(forSource: held.placementSourceID) != nil, "the placement keeps its source")
        #expect(try migrated.loadMemoryItem(held.memoryItemID)?.goalID == nil)
        #expect(try migrated.loadMemoryItem(held.memoryItemID)?.target == "Explain proton leak (gone).")
        let idea = try #require(try migrated.loadIdea(held.ideaID))
        #expect(idea.links.isEmpty)
        #expect(idea.title == "Uncouplers as a therapy (gone)")
        #expect(try migrated.loadTimeBlock(held.blockID)?.notebookID == nil)
        #expect(try migrated.loadLearningGoal(library.keptID)?.relatedNotebookIDs == [])
        // What has no other home keeps the dead one rather than being deleted.
        #expect(try migrated.loadResearchDirection(held.directionID)?.homeID == library.goneID)
        #expect(try migrated.loadNotebookTasks(notebookID: library.goneID).map(\.id) == [held.taskID])
        #expect(try NotebookHoldings.references(to: library.goneID, in: migrated).sorted() == [
            "notebook_tasks.notebook_id=1",
            "research_directions.home_id=1",
        ])

        // Each changed record is queued, with its metadata, before the stamp.
        let changes = try migrated.pendingSyncChanges()
        func queued(_ entity: CloudKitSyncEntity, _ key: String) -> Bool {
            changes.contains { $0.entity == entity && $0.logicalKey == key && $0.operation == .save }
        }
        #expect(queued(.reviewSession, held.chatID))
        #expect(!queued(.reviewSession, "chat-undelivered"))
        #expect(queued(.learningGoal, held.nestedGoalID))
        #expect(queued(.learningGoal, library.keptID))
        #expect(queued(.artifact, held.docID))
        #expect(!queued(.course, held.courseID), "a course lives in no notebook, so its record is not touched")
        #expect(queued(.scheduledTask, held.scheduledTaskID))
        #expect(queued(.memoryItem, held.memoryItemID))
        #expect(queued(.idea, held.ideaID))
        #expect(queued(.dayPlan, "2026-09-16"))
        #expect(changes.contains { $0.entity == .scheduledSource })
        #expect(!changes.contains { $0.entity == .researchDirection || $0.entity == .notebookTask })
        #expect(Self.scalar(at: root, """
            SELECT COUNT(*) FROM sync_changes c
            LEFT JOIN sync_metadata m ON m.entity_type = c.entity_type AND m.logical_key = c.logical_key
            WHERE m.logical_key IS NULL OR m.is_deleted = 1
        """) == "0", "every queued save has live metadata")
        #expect(try migrated.loadSyncMetadata(entity: .learningGoal, logicalKey: library.goneID)?.isDeleted == true)

        // Sources stay visible; the kept notebook keeps its pool.
        #expect(Set(try migrated.loadActiveSources().map(\.id)).contains(held.placementSourceID))
        #expect(try migrated.loadLearningGoal(library.keptID)?.approvedSourceIDs == ["src-a"])
    }

    @Test("A library whose notebooks are all alive migrates to 153 without a row changed or queued")
    func version153LeavesALiveLibraryAlone() throws {
        let root = try Self.temporaryRoot("v153-live")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Self.createReleasedLibrary(at: root, version: 150, removeTheSecond: false)
        let metadataBefore = Self.scalar(at: root, "SELECT COUNT(*) FROM sync_metadata")

        let migrated = try KnowledgeStore(storeDirectory: root)
        #expect(Self.scalar(at: root, "PRAGMA user_version") == "171")
        #expect(Self.scalar(at: root, "SELECT COUNT(*) FROM sync_metadata") == metadataBefore)
        #expect(try migrated.pendingSyncChanges().isEmpty)
        try library.held.expectFiled(under: library.goneID, in: migrated)
    }

    @Test("A schema 153 migration that fails leaves the v150 store, its links and its queue as they were")
    func version153RollsBack() throws {
        let root = try Self.temporaryRoot("v153-rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Self.createReleasedLibrary(at: root, version: 150)
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("knowledge.db").path, &database) == SQLITE_OK)
        if let database {
            // The repair's first write refuses, after the steps before it ran.
            #expect(sqlite3_exec(database, """
                CREATE TRIGGER refuse_chat_unlink BEFORE UPDATE OF goal_id ON review_sessions
                BEGIN SELECT RAISE(ABORT, 'refused'); END;
            """, nil, nil, nil) == SQLITE_OK)
            sqlite3_close(database)
        }

        #expect(throws: (any Error).self) {
            _ = try KnowledgeStore(storeDirectory: root)
        }
        #expect(Self.scalar(at: root, "PRAGMA user_version") == "150")
        #expect(Self.scalar(at: root, "SELECT goal_id FROM review_sessions WHERE id = '\(library.held.chatID)'") == library.goneID)
        #expect(Self.scalar(at: root, "SELECT parent_notebook_id FROM learning_goals WHERE id = '\(library.held.nestedGoalID)'") == library.goneID)
        #expect(Self.scalar(at: root, "SELECT COUNT(*) FROM idea_links WHERE target_id = '\(library.goneID)'") == "1")
        #expect(Self.scalar(at: root, "SELECT COUNT(*) FROM sync_changes") == "0")
        #expect(Self.scalar(at: root, "SELECT COUNT(*) FROM sources") == "1")
    }

    @Test("A production-sized library with hundreds of stranded chats migrates to 153 in well under a second")
    func version153Scales() throws {
        let root = try Self.temporaryRoot("v153-scale")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try KnowledgeStore(storeDirectory: root)
            try store.execForTesting("""
                BEGIN IMMEDIATE;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 20000)
                INSERT INTO sources (id, date_added, state, source_type, status)
                SELECT printf('source-%05d', n), n, 'ready', 'article', 'active' FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 20000)
                INSERT INTO articles (source_id, url, normalized_url, title, domain)
                SELECT printf('source-%05d', n), printf('https://example.com/%05d', n),
                       printf('example.com/%05d', n), printf('Source %05d', n), 'example.com'
                FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 500)
                INSERT INTO learning_goals (id, title, start_at, end_at, created_at, updated_at, status, kind)
                SELECT printf('notebook-%04d', n), printf('Notebook %04d', n), 1, 4102444800, 1, 1, 'active', 'companion'
                FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 10000)
                INSERT INTO review_sessions (id, topic, started_at, goal_id)
                SELECT printf('chat-%05d', n), 'Chat', n,
                       CASE WHEN n <= 500 THEN 'gone-notebook' ELSE printf('notebook-%04d', 1 + n % 500) END
                FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 5000)
                INSERT INTO memory_items (id, kind, target, rubric_json, goal_id, created_at, updated_at)
                SELECT printf('memory-%05d', n), 'concept', 'Target', '{}',
                       CASE WHEN n <= 250 THEN 'gone-notebook' ELSE NULL END, 1, 1
                FROM seq;
                INSERT INTO sync_metadata (entity_type, logical_key, record_name, user_modification_at, is_deleted)
                VALUES ('learningGoal', 'gone-notebook', 'LearningGoal-gone-notebook', 1, 1);
                COMMIT;
                PRAGMA user_version = 150;
            """)
        }

        let started = ContinuousClock.now
        let migrated = try KnowledgeStore(storeDirectory: root)
        let elapsed = started.duration(to: .now)
        #expect(elapsed < .seconds(1))
        #expect(Self.scalar(at: root, "PRAGMA user_version") == "171")
        #expect(Self.scalar(at: root, "SELECT COUNT(*) FROM review_sessions WHERE goal_id = 'gone-notebook'") == "0")
        #expect(Self.scalar(at: root, "SELECT COUNT(*) FROM review_sessions WHERE goal_id IS NULL") == "500")
        #expect(Self.scalar(at: root, "SELECT COUNT(*) FROM memory_items WHERE goal_id IS NOT NULL") == "0")
        #expect(Self.scalar(at: root, "SELECT COUNT(*) FROM sync_changes") == "750", "each released chat and Memory item is queued once")
        var visible = 0
        try migrated.query("SELECT COUNT(*) FROM source_projection") { visible = Int(sqlite3_column_int($0, 0)) }
        #expect(visible == 20_000, "sources stay visible")
    }
}

// MARK: - One of everything a notebook holds

/// One of every record a notebook holds by id, filed under one notebook: what
/// a merge and an emptying split must move, and what the schema-153 repair
/// must let go of when the notebook is gone.
fileprivate struct NotebookHoldings {
    let chatID: String
    let nestedGoalID: String
    let taskID: String
    let docID: String
    let courseID: String
    let scheduledTaskID: String
    let placementSourceID: String
    let blockID: String
    let memoryItemID: String
    let ideaID: String
    let directionID: String

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

    @discardableResult
    static func makeTeam(_ store: KnowledgeStore, permission: TeamPermission = .readWrite) throws -> TeamRecord {
        let now = Date()
        let team = TeamRecord(
            id: "team-1",
            name: "Nexus",
            role: permission == .readWrite ? .owner : .member,
            permission: permission,
            zoneScope: .privateScope,
            zoneName: TeamRecord.zoneName(forTeamID: "team-1"),
            zoneOwnerRecordName: nil,
            shareRecordName: nil,
            shareURL: nil,
            createdAt: now,
            joinedAt: now,
            updatedAt: now
        )
        try store.saveTeam(team)
        return team
    }

    /// Files one of everything under `notebookID`. `day` keeps each fixture's
    /// Planner block on a day of its own.
    static func file(under notebookID: String, in store: KnowledgeStore, tag: String, day: String) throws -> NotebookHoldings {
        let now = Date()
        let chatID = "chat-\(tag)"
        try store.createReviewSession(id: chatID, topic: "Uncouplers (\(tag))", sourceIDs: [], goalID: notebookID)
        let nested = try store.createCompanionGoal(
            title: "Read Picard (\(tag))",
            topic: "picard",
            startAt: now,
            endAt: now.addingTimeInterval(7 * 86_400),
            dailyTarget: 1,
            discoveryEnabled: false,
            seedSourceIDs: [],
            parentNotebookID: notebookID
        )
        let taskID = "task-\(tag)"
        try store.saveNotebookTask(NotebookTaskRecord(id: taskID, notebookID: notebookID, title: "Draft the crosswalk (\(tag))"))
        let docID = "doc-\(tag)"
        try store.saveArtifactRecord(ArtifactRecord(
            id: docID,
            title: "Crosswalk (\(tag))",
            homeNotebookID: notebookID,
            linkedNotebookIDs: [notebookID],
            createdAt: now,
            updatedAt: now
        ))
        let courseID = "course-\(tag)"
        try store.saveCourseGroup(name: courseID, metadata: CourseMetadata(title: "Systems Aging (\(tag))"))
        try store.linkCourseToNotebook(goalID: notebookID, courseID: courseID, sourceIDs: [])
        let scheduled = try store.saveScheduledTask(
            ScheduledTask(title: "Weekly digest (\(tag))", instruction: "Summarise the week.", notebookID: notebookID)
        )
        var placed = StudioArticle(url: "https://example.org/uncouplers-\(tag)", title: "Uncouplers (\(tag))", sourceType: .article)
        try store.insertSourceIfNew(&placed)
        try store.addSourceToGoal(sourceID: placed.id, goalID: notebookID, plannedAt: now)
        let block = try store.addTimeBlock(
            TimeBlock(dayPlanID: day, startMinute: 540, endMinute: 600, title: "Read (\(tag))", notebookID: notebookID)
        )
        let memoryItemID = "memory-\(tag)"
        try store.saveMemoryItem(MemoryItem(
            id: memoryItemID,
            kind: .concept,
            target: "Explain proton leak (\(tag)).",
            rubricJSON: "{}",
            goalID: notebookID,
            sources: [
                MemoryItemSource(
                    id: "anchor-\(memoryItemID)",
                    memoryItemID: memoryItemID,
                    sourceID: placed.id,
                    locatorJSON: #"{"kind":"text","start":0,"end":40}"#,
                    excerpt: "Uncouplers dissipate the proton gradient.",
                    sourceSHA256: String(repeating: "a", count: 64),
                    sortIndex: 0
                ),
            ]
        ))
        let idea = try store.createIdea(
            title: "Uncouplers as a therapy (\(tag))",
            links: [IdeaLink(kind: .notebook, targetID: notebookID)]
        )
        let direction = try #require(try store.proposeResearchDirections(homeID: notebookID, drafts: [
            ResearchDirectionDraft(
                title: "Hypoxia for complex I deficiency (\(tag))",
                rationale: "Chronic hypoxia rescued Ndufs4 knockout mice.",
                angle: .enabling,
                evidence: [
                    DirectionEvidence(
                        citation: "Jain et al., Science 2016",
                        doi: "10.1126/science.aad9642",
                        finding: "Breathing 11% oxygen prevented the Leigh-like disease of Ndufs4 knockout mice."
                    ),
                ],
                objection: nil,
                nextStep: nil
            ),
        ]).saved.first)
        return NotebookHoldings(
            chatID: chatID,
            nestedGoalID: nested.id,
            taskID: taskID,
            docID: docID,
            courseID: courseID,
            scheduledTaskID: scheduled.id,
            placementSourceID: placed.id,
            blockID: block.id,
            memoryItemID: memoryItemID,
            ideaID: idea.id,
            directionID: direction.id
        )
    }

    /// Every record names `notebookID`, and each still exists.
    func expectFiled(under notebookID: String, in store: KnowledgeStore) throws {
        #expect(try store.loadReviewSessionLinks().first { $0.id == chatID }?.goalID == notebookID)
        #expect(try store.loadLearningGoal(nestedGoalID)?.parentNotebookID == notebookID)
        #expect(try store.loadNotebookTasks(notebookID: notebookID).map(\.id).contains(taskID))
        let doc = try #require(try store.loadArtifact(docID))
        #expect(doc.homeNotebookID == notebookID)
        #expect(doc.linkedNotebookIDs == [notebookID])
        #expect(try store.notebookIDsFollowingCourse(courseID) == [notebookID])
        #expect(try store.loadScheduledTask(scheduledTaskID)?.notebookID == notebookID)
        #expect(try store.scheduledSourceGoalIDs(sourceID: placementSourceID) == [notebookID])
        #expect(try store.loadTimeBlock(blockID)?.notebookID == notebookID)
        #expect(try store.loadMemoryItem(memoryItemID)?.goalID == notebookID)
        #expect(try store.loadIdea(ideaID)?.links.map(\.targetID) == [notebookID])
        let direction = try #require(try store.loadResearchDirection(directionID))
        #expect(direction.homeID == notebookID)
        #expect(direction.homeKind == .notebook)
    }

    /// Every record was republished.
    func expectQueued(in changes: [CloudKitPendingChange]) throws {
        func queued(_ entity: CloudKitSyncEntity, _ key: String) -> Bool {
            changes.contains { $0.entity == entity && $0.logicalKey == key && $0.operation == .save }
        }
        #expect(queued(.reviewSession, chatID))
        #expect(queued(.learningGoal, nestedGoalID))
        #expect(queued(.notebookTask, taskID))
        #expect(queued(.artifact, docID))
        #expect(queued(.scheduledTask, scheduledTaskID))
        #expect(queued(.memoryItem, memoryItemID))
        #expect(queued(.idea, ideaID))
        #expect(queued(.researchDirection, directionID))
        #expect(changes.contains { $0.entity == .scheduledSource && $0.operation == .save })
        #expect(changes.contains { $0.entity == .dayPlan && $0.operation == .save })
    }

    /// Every table that names a notebook by id, as `table.column=count` for
    /// the ones that name `id`.
    static func references(to id: String, in store: KnowledgeStore) throws -> [String] {
        let probes: [(String, String)] = [
            ("review_sessions.goal_id", "SELECT COUNT(*) FROM review_sessions WHERE goal_id = ?1"),
            ("learning_goals.parent_notebook_id", "SELECT COUNT(*) FROM learning_goals WHERE parent_notebook_id = ?1"),
            ("learning_goal_items.goal_id", "SELECT COUNT(*) FROM learning_goal_items WHERE goal_id = ?1"),
            ("learning_goal_gaps.goal_id", "SELECT COUNT(*) FROM learning_goal_gaps WHERE goal_id = ?1"),
            ("notebook_files.notebook_id", "SELECT COUNT(*) FROM notebook_files WHERE notebook_id = ?1"),
            ("notebook_tasks.notebook_id", "SELECT COUNT(*) FROM notebook_tasks WHERE notebook_id = ?1"),
            ("global_artifacts.home_notebook_id", "SELECT COUNT(*) FROM global_artifacts WHERE home_notebook_id = ?1"),
            ("global_artifact_notebook_links.notebook_id", "SELECT COUNT(*) FROM global_artifact_notebook_links WHERE notebook_id = ?1"),
            ("notebook_course_links.goal_id", "SELECT COUNT(*) FROM notebook_course_links WHERE goal_id = ?1"),
            ("notebook_related_notebook_links", "SELECT COUNT(*) FROM notebook_related_notebook_links WHERE notebook_id = ?1 OR related_notebook_id = ?1"),
            ("scheduled_tasks.notebook_id", "SELECT COUNT(*) FROM scheduled_tasks WHERE notebook_id = ?1"),
            ("scheduled_source_goals.goal_id", "SELECT COUNT(*) FROM scheduled_source_goals WHERE goal_id = ?1"),
            ("time_blocks", "SELECT COUNT(*) FROM time_blocks WHERE notebook_id = ?1 OR goal_id = ?1"),
            ("learning_bouts.notebook_id", "SELECT COUNT(*) FROM learning_bouts WHERE notebook_id = ?1"),
            ("memory_items.goal_id", "SELECT COUNT(*) FROM memory_items WHERE goal_id = ?1"),
            ("idea_links.target_id", "SELECT COUNT(*) FROM idea_links WHERE target_id = ?1"),
            ("research_directions.home_id", "SELECT COUNT(*) FROM research_directions WHERE home_id = ?1"),
            ("journal_article_matches.notebook_id", "SELECT COUNT(*) FROM journal_article_matches WHERE notebook_id = ?1"),
            ("journal_watch_excluded_notebooks.notebook_id", "SELECT COUNT(*) FROM journal_watch_excluded_notebooks WHERE notebook_id = ?1"),
        ]
        var found: [String] = []
        for (name, sql) in probes {
            var count = 0
            try store.queryBind(sql, bind: { store.bind($0, 1, id) }) { count = Int(sqlite3_column_int64($0, 0)) }
            if count > 0 { found.append("\(name)=\(count)") }
        }
        return found
    }
}

// MARK: - Legacy plain-goal fixture

extension KnowledgeStore {
    /// Writes a plain goal (`kind IS NULL`), the shape older builds stored the
    /// retired Schedule goal in. No app path creates one any more, but
    /// libraries keep the rows those builds wrote, so fixtures that model such
    /// a library still make them. Sources are spread across the goal's days
    /// the way those builds did.
    @discardableResult
    func createLearningGoal(title: String, startAt: Date, endAt: Date, sourceIDs: [String]) throws -> LearningGoalRecord {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw KnowledgeStoreError.invalidData("Learning goal title is required.")
        }
        guard startAt < endAt else {
            throw KnowledgeStoreError.invalidData("Learning goal end date must be after the start date.")
        }

        let id = UUID().uuidString
        let now = Date()
        let uniqueSourceIDs = Array(dictUnique(sourceIDs))

        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("""
                INSERT INTO learning_goals (id, title, start_at, end_at, created_at, updated_at, status)
                VALUES (?, ?, ?, ?, ?, ?, 'active')
            """) { stmt in
                bind(stmt, 1, id)
                bind(stmt, 2, trimmedTitle)
                sqlite3_bind_double(stmt, 3, startAt.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(stmt, 4, endAt.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(stmt, 5, now.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(stmt, 6, now.timeIntervalSinceReferenceDate)
            }
            let plannedDates = Self.plainGoalPlannedDates(startAt: startAt, endAt: endAt, count: uniqueSourceIDs.count)
            for (index, sourceID) in uniqueSourceIDs.enumerated() {
                try insertLearningGoalItem(
                    goalID: id,
                    sourceID: sourceID,
                    addedAt: learningGoalItemPlannedDate(index < plannedDates.count ? plannedDates[index] : now, order: index)
                )
            }
            try markRecordChanged(entity: .learningGoal, logicalKey: id)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }

        guard let goal = try loadLearningGoal(id) else {
            throw KnowledgeStoreError.invalidData("Learning goal could not be loaded after creation.")
        }
        return goal
    }

    private static func plainGoalPlannedDates(startAt: Date, endAt: Date, count: Int) -> [Date] {
        guard count > 0 else { return [] }
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: startAt)
        let endDay = calendar.startOfDay(for: endAt)
        var days: [Date] = []
        var cursor = startDay
        while cursor < endDay || days.isEmpty {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return (0..<count).map { index in
            days[min(days.count - 1, Int((Double(index) / Double(count)) * Double(days.count)))]
        }
    }
}
