import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// Schema 96 adds Teams: a `team_id` on the four content tables, the `teams`,
/// `team_members` and `notebook_tasks` tables, zone columns on the three sync
/// bookkeeping tables, and a keyed engine-state table in place of the
/// singleton. What has to hold: a released-v95 store comes up at 96 with every
/// row intact and every existing record reading as the private Knowledge zone,
/// the one engine-state row becomes the private scope's, a same-named foreign
/// table rolls the whole migration back, and a production-sized library opens
/// in well under a second because the migration reads no application row.
@Suite("Team approval schema migration")
struct TeamApprovalSchemaMigrationTests {

    private static func temporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func scalar(at root: URL, _ sql: String) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("knowledge.db").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        var value: String?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW,
           let text = sqlite3_column_text(statement, 0) {
            value = String(cString: text)
        }
        sqlite3_finalize(statement)
        return value
    }

    @discardableResult
    private static func makeTeam(
        _ store: KnowledgeStore,
        id: String,
        role: TeamRole = .owner,
        permission: TeamPermission = .readWrite
    ) throws -> TeamRecord {
        let now = Date()
        let team = TeamRecord(
            id: id,
            name: "Team \(id)",
            role: role,
            permission: permission,
            zoneScope: role == .owner ? .privateScope : .shared,
            zoneName: TeamRecord.zoneName(forTeamID: id),
            zoneOwnerRecordName: role == .owner ? nil : "_owner-\(id)",
            shareRecordName: nil,
            shareURL: nil,
            createdAt: now,
            joinedAt: now,
            updatedAt: now
        )
        try store.saveTeam(team)
        return team
    }

    private static func notebook(_ id: String, teamID: String?, states: [String?]) -> LearningGoalRecord {
        let at = Date(timeIntervalSinceReferenceDate: 500)
        return LearningGoalRecord(
            id: id,
            title: "Notebook \(id)",
            startAt: at,
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: at,
            updatedAt: at,
            status: "active",
            items: states.enumerated().map { index, state in
                LearningGoalItem(
                    id: "\(id)-item-\(index)",
                    goalID: id,
                    sourceID: "\(id)-src-\(index)",
                    addedAt: at,
                    completedAt: index == 0 ? Date(timeIntervalSinceReferenceDate: 900) : nil,
                    origin: state == nil ? nil : LearningGoalItemOrigin.discovered.rawValue,
                    reviewState: state
                )
            },
            kind: LearningGoalRecord.companionKind,
            teamID: teamID
        )
    }

    private static let staged = ["team-member-rejected", "team-pending", "team-tutor-only"]

    /// A released library at `version`. Schema 152 adds no table or column,
    /// so the v150 shape is today's tables with the fixture's own queued
    /// changes cleared and the stamp at 150; the v149 shape also drops schema
    /// 150's `courses.home_notebook_id` and its index, so both steps run.
    private static func createReleasedLibrary(at root: URL, version: Int32) throws {
        let store = try KnowledgeStore(storeDirectory: root)
        var article = StudioArticle(url: "https://example.com/a", title: "A", sourceType: .article, discoveryOrigin: .manual, id: "src-a")
        article.domain = "example.com"
        try store.saveSource(article)

        try makeTeam(store, id: "rw")
        try makeTeam(store, id: "member", role: .member)
        try makeTeam(store, id: "ro")
        let pending = LearningGoalItemReviewState.pending.rawValue
        let rejected = LearningGoalItemReviewState.rejected.rawValue
        let approved = LearningGoalItemReviewState.approved.rawValue
        // The learner's own notebook: its verdicts were never stripped.
        try store.saveLearningGoalRecord(notebook("own", teamID: nil, states: [approved, pending, rejected]))
        // Team notebooks this Mac holds a verdict the team never received in.
        try store.saveLearningGoalRecord(notebook("team-pending", teamID: "rw", states: [approved, pending]))
        try store.saveLearningGoalRecord(notebook("team-member-rejected", teamID: "member", states: [nil, rejected]))
        try store.saveLearningGoalRecord(notebook("team-tutor-only", teamID: "rw", states: [approved, pending]))
        // Team notebooks with nothing new to tell, or no right to tell it.
        try store.saveLearningGoalRecord(notebook("team-approved", teamID: "rw", states: [approved, nil]))
        try store.saveLearningGoalRecord(notebook("team-read-only", teamID: "ro", states: [rejected]))
        try store.saveLearningGoalRecord(notebook("team-conflicted", teamID: "rw", states: [rejected]))
        try store.saveLearningGoalRecord(notebook("team-untracked", teamID: "rw", states: [pending]))
        try store.execForTesting("UPDATE teams SET permission = 'readOnly' WHERE id = 'ro'")

        // Everything acknowledged by CloudKit at an old edit date; then the
        // states the selection has to see through.
        try store.clearAllPendingSyncChanges()
        try store.execForTesting("UPDATE sync_metadata SET system_fields = X'01', user_modification_at = 100")
        try store.execForTesting("DELETE FROM sync_metadata WHERE entity_type = 'learningGoal' AND logical_key = 'team-untracked'")
        try store.execForTesting("""
            INSERT INTO sync_changes (entity_type, logical_key, record_name, operation, changed_at, tutor_only,
                                      zone_scope, zone_name, zone_owner_record_name)
            SELECT entity_type, logical_key, record_name, 'save', 150, 1, zone_scope, zone_name, zone_owner_record_name
            FROM sync_metadata WHERE entity_type = 'learningGoal' AND logical_key = 'team-tutor-only'
        """)
        try store.execForTesting("""
            INSERT INTO sync_conflicts (entity_type, logical_key, record_name, reason, local_modification_at,
                                        server_modification_at, detected_at, zone_scope, zone_name)
            SELECT entity_type, logical_key, record_name, 'fixture', 100, 100, 100, zone_scope, zone_name
            FROM sync_metadata WHERE entity_type = 'learningGoal' AND logical_key = 'team-conflicted'
        """)
        if version < 150 {
            try store.execForTesting("DROP INDEX IF EXISTS idx_courses_home_notebook")
            try store.execForTesting("ALTER TABLE courses DROP COLUMN home_notebook_id")
        }
        try store.execForTesting("PRAGMA user_version = \(version)")
    }

    private static let itemStates = """
        SELECT group_concat(goal_id || ':' || source_id || ':' || COALESCE(review_state, '-') || ':' || COALESCE(completed_at, '-'), ',')
        FROM (SELECT * FROM learning_goal_items ORDER BY goal_id, source_id)
    """

    @Test(
        "A released store stages exactly the team Notebooks holding a verdict the team never received",
        arguments: [Int32(149), Int32(150)]
    )
    func version152StagesTeamApproval(from released: Int32) throws {
        let root = try Self.temporaryRoot("v152-from-\(released)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.createReleasedLibrary(at: root, version: released)
        #expect(Self.scalar(at: root, "PRAGMA user_version") == "\(released)")
        let metadataBefore = Self.scalar(at: root, "SELECT COUNT(*) FROM sync_metadata")
        let itemsBefore = Self.scalar(at: root, Self.itemStates)
        let goalsBefore = Self.scalar(at: root, "SELECT group_concat(id || ':' || updated_at || ':' || COALESCE(team_id, '-'), ',') FROM (SELECT * FROM learning_goals ORDER BY id)")

        let migrated = try KnowledgeStore(storeDirectory: root)
        #expect(Self.scalar(at: root, "PRAGMA user_version") == "\(KnowledgeStore.schemaVersion)")
        #expect(KnowledgeStore.schemaVersion == 169)

        // Exactly the three, and nothing else queued.
        #expect(Self.scalar(at: root, "SELECT group_concat(logical_key, ',') FROM (SELECT logical_key FROM sync_changes ORDER BY logical_key)") == Self.staged.joined(separator: ","))
        #expect(Self.scalar(at: root, "SELECT COUNT(*) FROM sync_changes WHERE entity_type = 'learningGoal' AND operation = 'save' AND tutor_only = 0") == "3")
        // The save that was already waiting takes the new change date, as
        // `upsertSyncSave` would give it.
        #expect(Self.scalar(at: root, "SELECT COUNT(*) FROM sync_changes WHERE logical_key = 'team-tutor-only' AND changed_at > 150") == "1")
        // Each save goes to its record's own zone under its own record name.
        #expect(Self.scalar(at: root, """
            SELECT COUNT(*) FROM sync_changes c
            JOIN sync_metadata m ON m.entity_type = c.entity_type AND m.logical_key = c.logical_key
            WHERE c.record_name = m.record_name
              AND c.zone_scope = m.zone_scope AND c.zone_name = m.zone_name
              AND COALESCE(c.zone_owner_record_name, '') = COALESCE(m.zone_owner_record_name, '')
        """) == "3")
        let homes = Dictionary(uniqueKeysWithValues: try migrated.pendingSyncChanges().map { ($0.logicalKey, $0.home) })
        #expect(homes["team-pending"] == CloudKitZoneHome(scope: .privateScope, zoneName: "Team-rw", ownerRecordName: nil))
        #expect(homes["team-member-rejected"] == CloudKitZoneHome(scope: .shared, zoneName: "Team-member", ownerRecordName: "_owner-member"))
        // Sync bookkeeping parity: no metadata row added or lost, the staged
        // records' edit date moved and their change tags kept, every other
        // record's left alone.
        #expect(Self.scalar(at: root, "SELECT COUNT(*) FROM sync_metadata") == metadataBefore)
        #expect(Self.scalar(at: root, "SELECT COUNT(*) FROM sync_metadata WHERE user_modification_at > 100") == "3")
        #expect(Self.scalar(at: root, """
            SELECT COUNT(*) FROM sync_metadata
            WHERE entity_type = 'learningGoal' AND user_modification_at > 100 AND system_fields = X'01'
              AND logical_key IN ('team-member-rejected', 'team-pending', 'team-tutor-only')
        """) == "3")
        #expect(Self.scalar(at: root, "SELECT COUNT(*) FROM sync_conflicts") == "1")
        // The rows are the learner's and stay exactly as they were.
        #expect(Self.scalar(at: root, Self.itemStates) == itemsBefore)
        #expect(Self.scalar(at: root, "SELECT group_concat(id || ':' || updated_at || ':' || COALESCE(team_id, '-'), ',') FROM (SELECT * FROM learning_goals ORDER BY id)") == goalsBefore)
        #expect(try migrated.loadActiveSources().map(\.id) == ["src-a"], "sources stay visible")

        // The staged save carries the verdicts this time.
        let change = try #require(try migrated.pendingSyncChanges().first { $0.logicalKey == "team-member-rejected" })
        let record = try #require(try CloudKitRecordMapper.makeRecord(for: change, store: migrated))
        let payload = try JSONDecoder().decode(
            CloudKitLearningGoalPayload.self,
            from: try #require(record.encryptedValues[.payload] as? Data)
        )
        #expect(payload.goal.items.map { $0.reviewState ?? "-" } == ["-", LearningGoalItemReviewState.rejected.rawValue])
        #expect(payload.goal.items.allSatisfy { $0.completedAt == nil })

        // A current store's launch stages nothing again.
        try migrated.clearAllPendingSyncChanges()
        let reopened = try KnowledgeStore(storeDirectory: root)
        #expect(try reopened.pendingSyncChanges().isEmpty)
    }

    @Test("A schema 152 migration that fails leaves the v150 store and its sync bookkeeping as they were")
    func version152RollsBack() throws {
        let root = try Self.temporaryRoot("v152-rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.createReleasedLibrary(at: root, version: 150)
        // The staging INSERT is refused after the metadata UPDATE has run.
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("knowledge.db").path, &database) == SQLITE_OK)
        if let database {
            #expect(sqlite3_exec(database, """
                CREATE TRIGGER refuse_staging BEFORE INSERT ON sync_changes
                BEGIN SELECT RAISE(ABORT, 'refused'); END;
            """, nil, nil, nil) == SQLITE_OK)
            sqlite3_close(database)
        }
        let itemsBefore = Self.scalar(at: root, Self.itemStates)

        #expect(throws: (any Error).self) {
            _ = try KnowledgeStore(storeDirectory: root)
        }
        #expect(Self.scalar(at: root, "PRAGMA user_version") == "150")
        #expect(Self.scalar(at: root, "SELECT COUNT(*) FROM sync_metadata WHERE user_modification_at <> 100") == "0")
        #expect(Self.scalar(at: root, "SELECT group_concat(logical_key || ':' || tutor_only, ',') FROM sync_changes") == "team-tutor-only:1")
        #expect(Self.scalar(at: root, Self.itemStates) == itemsBefore)
        #expect(Self.scalar(at: root, "SELECT COUNT(*) FROM sources") == "1")
    }

    @Test("A production-sized library migrates to 152 in well under a second")
    func version152Scales() throws {
        let root = try Self.temporaryRoot("v152-scale")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try KnowledgeStore(storeDirectory: root)
            try Self.makeTeam(store, id: "rw")
            // 20,000 sources with their sync rows, 3,000 Notebooks of 20 items
            // each — every tenth a team's, every seventh item a suggestion and
            // every eleventh a removal — each Notebook tracked by sync.
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
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 20000)
                INSERT INTO sync_metadata (entity_type, logical_key, record_name, system_fields, user_modification_at, is_deleted)
                SELECT 'source', printf('source-%05d', n), printf('source-rec-%05d', n), X'01', 100, 0 FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 3000)
                INSERT INTO learning_goals (id, title, start_at, end_at, created_at, updated_at, status, kind, team_id)
                SELECT printf('goal-%05d', n), printf('Notebook %05d', n), 0, 4102444800, 0, 0, 'active', 'companion',
                       CASE WHEN n % 10 = 0 THEN 'rw' END
                FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 0 UNION ALL SELECT n + 1 FROM seq WHERE n < 59999)
                INSERT INTO learning_goal_items (id, goal_id, source_id, added_at, review_state)
                SELECT printf('item-%05d', n), printf('goal-%05d', n / 20 + 1), printf('source-%05d', n % 20000 + 1), 0,
                       CASE WHEN n % 7 = 0 THEN 'pending' WHEN n % 11 = 0 THEN 'rejected' WHEN n % 2 = 0 THEN 'approved' END
                FROM seq;
                INSERT INTO sync_metadata (entity_type, logical_key, record_name, system_fields, user_modification_at, is_deleted,
                                           zone_scope, zone_name)
                SELECT 'learningGoal', id, 'goal-rec-' || id, X'01', 100, 0,
                       'private', CASE WHEN team_id IS NULL THEN 'Knowledge' ELSE 'Team-rw' END
                FROM learning_goals;
                COMMIT;
            """)
            try store.clearAllPendingSyncChanges()
            try store.execForTesting("PRAGMA user_version = 150")
        }
        let teamNotebooks = Self.scalar(at: root, "SELECT COUNT(*) FROM learning_goals WHERE team_id = 'rw'")
        #expect(teamNotebooks == "300")

        let started = ContinuousClock.now
        let migrated = try KnowledgeStore(storeDirectory: root)
        let elapsed = started.duration(to: .now)
        print("Schema 150 → 152 over 20,000 sources and 3,000 Notebooks took \(elapsed)")
        // Two statements over the Notebooks' sync rows, each Notebook's items
        // probed through the goal index; no per-row loop, no source read.
        #expect(elapsed < .seconds(1))
        #expect(Self.scalar(at: root, "PRAGMA user_version") == "\(KnowledgeStore.schemaVersion)")
        // Every team Notebook here holds a suggestion, so all 300 go up once.
        #expect(Self.scalar(at: root, "SELECT COUNT(*) FROM sync_changes WHERE entity_type = 'learningGoal' AND zone_name = 'Team-rw'") == "300")
        #expect(Self.scalar(at: root, "SELECT COUNT(*) FROM sync_changes") == "300")
        var visible = 0
        try migrated.query("SELECT COUNT(*) FROM source_projection") { visible = Int(sqlite3_column_int($0, 0)) }
        #expect(visible == 20_000, "sources stay visible")
    }
}
