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

        try store.setLearningGoalTitle(goalID: goal.id, title: "  Deep Reinforcement Learning  ")

        let renamed = try #require(try store.loadLearningGoal(goal.id))
        #expect(renamed.title == "Deep Reinforcement Learning")
        #expect(renamed.description == goal.description)
        #expect(renamed.topic == goal.topic)
        #expect(renamed.endAt == goal.endAt)
        #expect(renamed.dailyTarget == goal.dailyTarget)
        #expect(renamed.discoveryEnabled == goal.discoveryEnabled)
        #expect(renamed.items == goal.items)
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

        try store.setLearningGoalDescription(
            goalID: goal.id,
            description: "Prioritize primary research and flag disputed claims."
        )

        let updated = try #require(try store.loadLearningGoal(goal.id))
        #expect(updated.description == "Prioritize primary research and flag disputed claims.")

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

        try store.setLearningGoalSummary(goalID: goal.id, summary: "Ageing organelles, measured")
        let updated = try #require(try store.loadLearningGoal(goal.id))
        #expect(updated.summary == "Ageing organelles, measured")
        #expect(updated.displaySummary == "Ageing organelles, measured")
        // The card description never touches the chat Instructions.
        #expect(updated.description == "Prefer primary research.")

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

        try store.setLearningGoalArtifact(goalID: goal.id, artifactID: nil)
        let unlinked = try #require(try store.loadLearningGoal(goal.id))
        #expect(unlinked.artifactID == "", "an unlink travels as an explicit clear, not as no opinion")
        #expect(unlinked.linkedArtifactID == nil)

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

        // A subset places itself first; the rest keep the order they read.
        #expect(try store.reorderLearningGoals(goalIDs: [month.id]) == [month.id, soon.id, week.id])
        #expect(try order() == [month.id, soon.id, week.id])
        #expect(try store.loadLearningGoal(month.id)?.sortOrder == 0)
        #expect(try store.loadLearningGoal(soon.id)?.sortOrder == 1)
        #expect(try store.loadLearningGoal(week.id)?.sortOrder == 2)
        #expect(try store.loadLearningGoal(done.id)?.sortOrder == nil, "finished work is not placed")

        // The same order again writes nothing.
        #expect(try store.reorderLearningGoals(goalIDs: [month.id, soon.id, week.id]) == [month.id, soon.id, week.id])

        // One step down moves two rows and publishes two.
        #expect(try store.reorderLearningGoals(goalIDs: [soon.id, month.id, week.id]) == [soon.id, month.id, week.id])

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
        #expect(try store.reorderLearningGoals(goalIDs: []) == [week.id, soon.id, newcomer.id, month.id])
        #expect(try store.loadLearningGoals().filter { $0.isGoal }.allSatisfy { $0.sortOrder == nil })
        #expect(try order() == [week.id, soon.id, newcomer.id, month.id], "by deadline again, the overdue one first")

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

        try store.deleteLearningGoal(notebook.id, cascadeChildGoals: true)

        let sessions = Dictionary(
            uniqueKeysWithValues: try store.loadReviewSessionLinks().map { ($0.id, $0) }
        )
        #expect(sessions["notebook-chat"]?.goalID == nil)
        #expect(sessions["goal-chat"]?.goalID == nil)
        #expect(sessions["loose-chat"] != nil)
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

        try store.deleteLearningGoal(
            notebook.id,
            cascadeChildGoals: true,
            deleteLinkedChats: true
        )

        let sessionIDs = Set(try store.loadReviewSessionLinks().map(\.id))
        #expect(!sessionIDs.contains("notebook-chat"))
        #expect(!sessionIDs.contains("goal-chat"))
        #expect(sessionIDs.contains("loose-chat"))
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

        // Partial reorder: listed sources go first, the rest keep their relative order.
        try store.reorderCompanionSources(goalID: goal.id, orderedSourceIDs: ["s-c", "s-a"])

        let reordered = try #require(try store.loadLearningGoal(goal.id))
        #expect(reordered.approvedSourceIDs == ["s-c", "s-a", "s-b", "s-d"])

        // A source added later is unsequenced and lands after the sequenced pool.
        try store.addCompanionSeedSources(goalID: goal.id, sourceIDs: ["s-e"])
        let appended = try #require(try store.loadLearningGoal(goal.id))
        #expect(appended.approvedSourceIDs == ["s-c", "s-a", "s-b", "s-d", "s-e"])

        // Sources outside the approved pool are rejected.
        #expect(throws: (any Error).self) {
            try store.reorderCompanionSources(goalID: goal.id, orderedSourceIDs: ["not-in-pool"])
        }
    }

    @Test("Editing settings of a plain Schedule goal is rejected")
    func updateSettingsRejectsPlainGoal() throws {
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

        try store.deleteLearningGoal(focused.id, cascadeChildGoals: true)
        #expect(try store.loadLearningGoal(broad.id)?.relatedNotebookIDs == [])
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

// MARK: - Plain-goal fixture

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
