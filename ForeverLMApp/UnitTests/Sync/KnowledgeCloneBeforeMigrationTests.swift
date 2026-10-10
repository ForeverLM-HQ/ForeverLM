import Foundation
import SQLite3
import Testing
@testable import ForeverLM

/// The verified copy a store keeps before it migrates into schema v2 (docs/cloudkit-schema-design.md
/// §13.3 step 1): when it is taken, how (a clone after a clean checkpoint, else an online backup),
/// that nothing can tear it, its quick_check, and the room it needs on the disk.
@Suite("Rollback copy before migrating")
struct KnowledgeCloneBeforeMigrationTests {
    /// A box a writer thread and the test share.
    private final class Shared: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var committed = 0
        var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
        var commits: Int { lock.lock(); defer { lock.unlock() }; return committed }
        func stop() { lock.lock(); stopped = true; lock.unlock() }
        func didCommit() { lock.lock(); committed += 1; lock.unlock() }
    }

    /// What concurrent opens report back.
    private final class Opens: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var copies: [KnowledgeRollbackCopy.Record] = []
        private(set) var failures = 0
        func record(_ copy: KnowledgeRollbackCopy.Record?) { lock.lock(); if let copy { copies.append(copy) }; lock.unlock() }
        func fail() { lock.lock(); failures += 1; lock.unlock() }
    }

    private static func copyCount(_ root: URL, _ kind: KnowledgeRollbackCopy.Kind, _ sql: String) -> Int {
        Schema154Fixture.count(at: root, sql, file: kind.fileName)
    }

    @Test("Which copy a launch takes")
    func decision() {
        typealias State = KnowledgeRollbackCopy.StoreState
        func kind(_ version: Int32, _ library: Bool, _ activation: State.Activation, _ generation: SyncGeneration) -> KnowledgeRollbackCopy.Kind? {
            KnowledgeRollbackCopy.kindToTake(State(userVersion: version, holdsLibrary: library, activation: activation), generation: generation, schemaVersion: 154)
        }
        #expect(kind(150, true, .notRecorded, .one) == .beforeSchema154)
        #expect(kind(153, true, .notRecorded, .one) == .beforeSchema154)
        #expect(kind(154, true, .notRecorded, .one) == nil)
        #expect(kind(153, true, .notRecorded, .two) == .beforeGeneration2, "one copy per launch: pre-v2 in place of pre-154")
        #expect(kind(154, true, .notRecorded, .two) == .beforeGeneration2)
        #expect(kind(154, true, .copyRecorded("knowledge.pre-v2.db"), .two) == nil)
        #expect(kind(154, true, .activated, .two) == nil)
        #expect(kind(153, false, .notRecorded, .one) == nil)
        #expect(kind(0, false, .notRecorded, .two) == nil)
        #expect(kind(155, true, .notRecorded, .two) == nil, "a store newer than the build is refused, not copied")
    }

    @Test("A clean checkpoint clones the store, its WAL's commits included")
    func cleanCheckpointClones() throws {
        let root = try Schema154Fixture.temporaryRoot("clone")
        defer { try? FileManager.default.removeItem(at: root) }
        try Schema154Fixture.makeLibrary(at: root, version: 153)
        let writer = try SQLiteHandle(path: root.appendingPathComponent("knowledge.db").path)
        try writer.execute("INSERT INTO sources (id, date_added) VALUES ('src-in-the-wal', 9)")
        let record = try KnowledgeRollbackCopy.take(.beforeSchema154, ofStoreAt: root)
        #expect(record.method == .clone)
        #expect(record.userVersion == 153)
        #expect(record.fileName == "knowledge.pre-154.db")
        let copy = root.appendingPathComponent(record.fileName)
        #expect(try copy.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true, "kept out of Time Machine")
        #expect(Self.copyCount(root, .beforeSchema154, "SELECT COUNT(*) FROM sources WHERE id = 'src-in-the-wal'") == 1)
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sources") == Self.copyCount(root, .beforeSchema154, "SELECT COUNT(*) FROM sources"))
        let recorded = try #require(KnowledgeRollbackCopy.recorded(.beforeSchema154, in: root))
        #expect(recorded.method == .clone && recorded.userVersion == 153 && recorded.fileName == record.fileName)
        #expect(abs(recorded.takenAt.timeIntervalSince(record.takenAt)) < 0.001)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("knowledge.pre-154.db-wal").path), "reading the copy leaves no side file")
    }

    @Test("A reader on an old snapshot makes the copy an online backup of the latest commit")
    func busyCheckpointBacksUp() throws {
        let root = try Schema154Fixture.temporaryRoot("backup")
        defer { try? FileManager.default.removeItem(at: root) }
        try Schema154Fixture.makeLibrary(at: root, version: 153)
        let path = root.appendingPathComponent("knowledge.db").path
        let reader = try SQLiteHandle(path: path)
        let writer = try SQLiteHandle(path: path)
        try reader.executeScript("BEGIN")
        _ = try reader.scalarInteger("SELECT COUNT(*) FROM sources")
        try writer.execute("INSERT INTO sources (id, date_added) VALUES ('src-after-the-reader', 9)")
        let record = try KnowledgeRollbackCopy.take(.beforeSchema154, ofStoreAt: root)
        try reader.executeScript("COMMIT")
        #expect(record.method == .backup)
        #expect(Self.copyCount(root, .beforeSchema154, "SELECT COUNT(*) FROM sources WHERE id = 'src-after-the-reader'") == 1)
        #expect(Schema154Fixture.scalar(at: root, "PRAGMA integrity_check", file: record.fileName) == "ok")
        #expect(record.userVersion == 153)
    }

    @Test("A writer committing throughout never tears a copy, cloned or backed up")
    func concurrentWriterCannotTear() throws {
        let root = try Schema154Fixture.temporaryRoot("torn")
        defer { try? FileManager.default.removeItem(at: root) }
        try Schema154Fixture.makeLibrary(at: root, version: 153)
        let path = root.appendingPathComponent("knowledge.db").path
        try SQLiteHandle(path: path).executeScript("CREATE TABLE ledger (id INTEGER PRIMARY KEY, amount INTEGER NOT NULL, pad BLOB)")
        let shared = Shared()
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            defer { finished.signal() }
            guard let writer = try? SQLiteHandle(path: path) else { return }
            var amount: Int64 = 1
            // At most 1,500 commits of 2 KiB: a few MB, whatever the copies cost.
            while !shared.isStopped, shared.commits < 1_500 {
                do {
                    try writer.executeScript("BEGIN IMMEDIATE")
                    try writer.execute("INSERT INTO ledger (amount, pad) VALUES (?, zeroblob(1024))", [.integer(amount)])
                    try writer.execute("INSERT INTO ledger (amount, pad) VALUES (?, zeroblob(1024))", [.integer(-amount)])
                    try writer.executeScript("COMMIT")
                    shared.didCommit()
                    amount += 1
                } catch {
                    try? writer.executeScript("ROLLBACK")
                }
                usleep(500)
            }
        }
        let pinned = try SQLiteHandle(path: path)
        var methods: [KnowledgeRollbackCopy.Method] = []
        for round in 0..<10 {
            usleep(20_000)
            // The second half pins an old snapshot, so the backup copies while the writer commits.
            if round >= 5 {
                try pinned.executeScript("BEGIN")
                _ = try pinned.scalarInteger("SELECT COUNT(*) FROM ledger")
                usleep(10_000)
            }
            let record = try KnowledgeRollbackCopy.take(.beforeSchema154, ofStoreAt: root)
            if round >= 5 { try pinned.executeScript("COMMIT") }
            methods.append(record.method)
            #expect(Schema154Fixture.scalar(at: root, "PRAGMA integrity_check", file: record.fileName) == "ok", "round \(round)")
            #expect(Self.copyCount(root, .beforeSchema154, "SELECT COALESCE(SUM(amount), 0) FROM ledger") == 0, "round \(round): no half transaction")
            #expect(Self.copyCount(root, .beforeSchema154, "SELECT COUNT(*) FROM ledger") % 2 == 0, "round \(round)")
        }
        shared.stop()
        finished.wait()
        #expect(shared.commits > 20, "the writer wrote meanwhile")
        // The pinned rounds always back up. The others clone when the writer leaves the checkpoint a
        // clean moment, which a loaded machine may not give; cleanCheckpointClones pins the clone.
        #expect(methods.contains(.backup))
    }

    @Test("quick_check runs on the copy and is recorded beside it; a damaged copy fails it")
    func quickCheckIsRecorded() throws {
        let root = try Schema154Fixture.temporaryRoot("check")
        defer { try? FileManager.default.removeItem(at: root) }
        try Schema154Fixture.makeLibrary(at: root, version: 153)
        let record = try KnowledgeRollbackCopy.take(.beforeSchema154, ofStoreAt: root)
        #expect(record.quickCheck == nil)
        let checked = KnowledgeRollbackCopy.check(record, in: root)
        #expect(checked.passedQuickCheck)
        #expect(KnowledgeRollbackCopy.recorded(.beforeSchema154, in: root)?.quickCheck == "ok")

        // B-tree page headers overwritten: structure quick_check reads.
        let copy = root.appendingPathComponent(record.fileName)
        var bytes = try Data(contentsOf: copy)
        for page in 3..<min(bytes.count / 4096, 40) {
            let offset = (page - 1) * 4096
            bytes.replaceSubrange(offset..<(offset + 8), with: Data(repeating: 0xFF, count: 8))
        }
        try bytes.write(to: copy)
        let damaged = KnowledgeRollbackCopy.check(record, in: root)
        #expect(!damaged.passedQuickCheck)
        #expect(KnowledgeRollbackCopy.recorded(.beforeSchema154, in: root)?.passedQuickCheck == false)
    }

    @Test("Generation 1 copies a store below 154 before migrating it", arguments: [Int32(148), Int32(150), Int32(153)])
    func generation1CopiesBelow154(_ version: Int32) async throws {
        let root = try Schema154Fixture.temporaryRoot("gen1-\(version)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Schema154Fixture.makeLibrary(at: root, version: version)
        let store = try KnowledgeStore(storeDirectory: root, syncGeneration: .one, freeSpace: Schema154Fixture.roomy)
        #expect(store.rollbackCopy?.kind == .beforeSchema154)
        #expect(store.rollbackCopy?.userVersion == version)
        #expect(Self.copyCount(root, .beforeSchema154, "PRAGMA user_version") == Int(version))
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM pragma_foreign_key_list('hidden_sources')", file: "knowledge.pre-154.db") == 1)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        let checked = await store.rollbackCopyCheck?.value
        #expect(checked?.passedQuickCheck == true)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("knowledge.pre-v2.db").path))
        let again = try KnowledgeStore(storeDirectory: root, syncGeneration: .one, freeSpace: Schema154Fixture.roomy)
        #expect(again.rollbackCopy == nil && again.rollbackCopyCheck == nil, "the launch's other opens take none")
        Schema154Fixture.newLaunch(root)
        let reopened = try KnowledgeStore(storeDirectory: root, syncGeneration: .one, freeSpace: Schema154Fixture.roomy)
        #expect(reopened.rollbackCopy == nil, "a store at 154 takes no copy under generation 1")
        #expect(KnowledgeRollbackCopy.checksQueuedForTesting(in: root) == 1)
    }

    @Test("A store's first generation-2 launch copies it before its migrations", arguments: [Int32(148), Int32(150), Int32(153)])
    func generation2CopiesFirst(_ version: Int32) throws {
        let root = try Schema154Fixture.temporaryRoot("gen2-\(version)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Schema154Fixture.makeLibrary(at: root, version: version)
        let store = try KnowledgeStore(storeDirectory: root, syncGeneration: .two, freeSpace: Schema154Fixture.roomy)
        #expect(store.rollbackCopy?.kind == .beforeGeneration2)
        #expect(store.rollbackCopy?.userVersion == version, "the store as the last generation-1 build left it")
        #expect(Self.copyCount(root, .beforeGeneration2, "PRAGMA user_version") == Int(version))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("knowledge.pre-154.db").path), "one copy per launch")
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        // The launch's other opens find the store at 154 and the copy not yet in ck_activation (the
        // activation records it, WP4c), and copy nothing: the copy stays the store before the launch's
        // migrations.
        let takenAt = try #require(KnowledgeRollbackCopy.recorded(.beforeGeneration2, in: root)?.takenAt)
        let again = try KnowledgeStore(storeDirectory: root, syncGeneration: .two, freeSpace: Schema154Fixture.roomy)
        #expect(again.rollbackCopy == nil)
        #expect(Self.copyCount(root, .beforeGeneration2, "PRAGMA user_version") == Int(version))
        #expect(KnowledgeRollbackCopy.recorded(.beforeGeneration2, in: root)?.takenAt == takenAt)
        #expect(KnowledgeRollbackCopy.checksQueuedForTesting(in: root) == 1)
    }

    @Test("A copy that is not a database is replaced, a good unrecorded copy of an older schema is kept, and a recorded copy and an activated store are left alone")
    func unrecordedCopyIsReplaced() throws {
        let root = try Schema154Fixture.temporaryRoot("stale")
        defer { try? FileManager.default.removeItem(at: root) }
        try Schema154Fixture.makeLibrary(at: root, version: 153)
        let stale = root.appendingPathComponent("knowledge.pre-v2.db")
        try Data("not a database".utf8).write(to: stale)
        try Data("junk".utf8).write(to: URL(fileURLWithPath: stale.path + "-wal"))

        let first = try KnowledgeStore(storeDirectory: root, syncGeneration: .two, freeSpace: Schema154Fixture.roomy)
        #expect(first.rollbackCopy?.userVersion == 153)
        #expect(Self.copyCount(root, .beforeGeneration2, "SELECT COUNT(*) FROM sources") == 3)
        #expect(!FileManager.default.fileExists(atPath: stale.path + "-wal"))

        // The first launch migrated the store and its copy has not been recorded (a launch that stopped
        // before the activation's journal got to it): the copy is still the store as generation 1 left it
        // and the next launch keeps it, since a copy of the migrated store is no rollback (F29).
        Schema154Fixture.newLaunch(root)
        let second = try KnowledgeStore(storeDirectory: root, syncGeneration: .two, freeSpace: Schema154Fixture.roomy)
        #expect(second.rollbackCopy == nil)
        #expect(KnowledgeRollbackCopy.recorded(.beforeGeneration2, in: root)?.userVersion == 153)
        #expect(Self.copyCount(root, .beforeGeneration2, "PRAGMA user_version") == 153)

        try second.execForTesting("INSERT INTO ck_activation (id, clone_path, clone_user_version) VALUES (1, 'knowledge.pre-v2.db', \(KnowledgeStore.schemaVersion))")
        Schema154Fixture.newLaunch(root)
        let recorded = try KnowledgeStore(storeDirectory: root, syncGeneration: .two, freeSpace: Schema154Fixture.roomy)
        #expect(recorded.rollbackCopy == nil)
        try recorded.execForTesting("UPDATE ck_activation SET activated_at = 1")
        Schema154Fixture.newLaunch(root)
        let activated = try KnowledgeStore(storeDirectory: root, syncGeneration: .two, freeSpace: Schema154Fixture.roomy)
        #expect(activated.rollbackCopy == nil)
    }

    @Test("Every retry of an open whose migration 154 fails reuses the launch's one copy and its one check")
    func failingMigrationCopiesOnce() async throws {
        let root = try Schema154Fixture.temporaryRoot("retry")
        defer { try? FileManager.default.removeItem(at: root) }
        try Schema154Fixture.makeLibrary(at: root, version: 153)
        // A same-named table of another shape: 154's probe refuses it, and the migration rolls back.
        try SQLiteHandle(path: root.appendingPathComponent("knowledge.db").path).executeScript("CREATE TABLE ck_records (something_else TEXT)")
        var takenAt: Date?
        for attempt in 0..<5 {
            #expect(throws: (any Error).self, "attempt \(attempt)") {
                _ = try KnowledgeStore(storeDirectory: root, syncGeneration: .one, freeSpace: Schema154Fixture.roomy)
            }
            let copy = try #require(KnowledgeRollbackCopy.recorded(.beforeSchema154, in: root))
            takenAt = takenAt ?? copy.takenAt
            #expect(copy.takenAt == takenAt, "attempt \(attempt) took no copy of its own")
        }
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == 153)
        await KnowledgeRollbackCopy.queuedChecksForTesting()
        #expect(KnowledgeRollbackCopy.checksQueuedForTesting(in: root) == 1)
        #expect(KnowledgeRollbackCopy.recorded(.beforeSchema154, in: root)?.passedQuickCheck == true)
        #expect(Self.copyCount(root, .beforeSchema154, "PRAGMA user_version") == 153)
    }

    @Test("A store with no library, or a brand-new one, is not copied")
    func emptyStoreIsNotCopied() throws {
        let root = try Schema154Fixture.temporaryRoot("empty")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
            #expect(store.rollbackCopy == nil)
            try Schema154Fixture.restoreReleasedShape(store, version: 153)
        }
        let migrated = try KnowledgeStore(storeDirectory: root, syncGeneration: .two, freeSpace: Schema154Fixture.roomy)
        #expect(migrated.rollbackCopy == nil && migrated.rollbackCopyFailure == nil)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("knowledge.pre-v2.db").path))
    }

    @Test("Concurrent opens of one store take one copy, before the one migration")
    func concurrentOpensCopyOnce() throws {
        let root = try Schema154Fixture.temporaryRoot("gate")
        defer { try? FileManager.default.removeItem(at: root) }
        try Schema154Fixture.makeLibrary(at: root, version: 153)
        let opens = Opens()
        DispatchQueue.concurrentPerform(iterations: 6) { _ in
            do {
                let store = try KnowledgeStore(storeDirectory: root, syncGeneration: .one, freeSpace: Schema154Fixture.roomy)
                opens.record(store.rollbackCopy)
            } catch {
                opens.fail()
            }
        }
        #expect(opens.failures == 0)
        #expect(opens.copies.count == 1)
        #expect(opens.copies.first?.userVersion == 153)
    }

    /// Released builds 176 to 178 left 150, older ones 148 or 149, and none has run 151 to 153, so a
    /// Mac short of room must still get every step below 154: none of them ever needed a copy.
    @Test(
        "Without room for the copy, generation 1 runs every step below 154 and waits at 153; with room, it copies, then migrates",
        arguments: [Int32(148), Int32(149), Int32(150), Int32(153)]
    )
    func roomForTheCopy(_ version: Int32) throws {
        let root = try Schema154Fixture.temporaryRoot("room-\(version)")
        defer { try? FileManager.default.removeItem(at: root) }
        // The card's state is the process's: the test host shows no card once this test is done.
        defer { LibraryUpgradeSpace.record(nil) }
        let library = try Schema154Fixture.makeLibrary(at: root, version: version)
        // A chat filed under a notebook an older build's merge deleted, which 153's step releases.
        try SQLiteHandle(path: root.appendingPathComponent("knowledge.db").path).executeScript("""
            INSERT INTO review_sessions (id, topic, started_at, goal_id) VALUES ('chat-in-gone', 'Gone', 1, 'gone-notebook');
            INSERT INTO sync_metadata (entity_type, logical_key, record_name, user_modification_at, is_deleted)
            VALUES ('learningGoal', 'gone-notebook', 'LearningGoal-gone-notebook', 1, 1);
        """)
        let databaseBytes = ((try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("knowledge.db").path))[.size] as? NSNumber)?.int64Value ?? 0

        let waiting = try KnowledgeStore(storeDirectory: root, syncGeneration: .one, freeSpace: { _ in 1_500_000_000 })
        #expect(waiting.rollbackCopy == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("knowledge.pre-154.db").path))
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == 153, "every step below 154 ran")
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM pragma_table_info('review_sessions') WHERE name IN ('model_effort', 'model_speed')") == 2, "149's columns")
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM pragma_table_info('courses') WHERE name = 'home_notebook_id'") == 1, "150's column")
        // 164's rename runs on a held store too (this build's queries name the notebook tables); its stale
        // indexes are dropped and made again by the launch that lays down 154, so 153 still holds the old name.
        let courseIndex = version == 153 ? "idx_courses_home_project" : "idx_courses_home_notebook"
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sqlite_master WHERE name = '\(courseIndex)'") == 1, "and its index")
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM review_sessions WHERE id = 'chat-in-gone' AND goal_id IS NULL") == (version < 153 ? 1 : 0), "153's release, where it was due")
        // None of 154: no ck table, wire column or wire_key index, and the released per-member tables.
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'ck\\_%' ESCAPE '\\' OR name LIKE 'idx\\_%\\_wire\\_key' ESCAPE '\\'") == 0)
        for table in KnowledgeStore.wireKeyedTables {
            #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM pragma_table_xinfo('\(table)') WHERE name IN ('wire_id', 'wire_key')") == 0, "\(table)")
        }
        #expect(Schema154Fixture.count(at: root, "SELECT COUNT(*) FROM pragma_table_info('learning_goals') WHERE name = 'entity_kind'") == 0)
        for table in Schema154Fixture.releasedPerMemberTables.map(\.name) {
            #expect(Schema154Fixture.foreignKeyCount(at: root, table) == 1, "\(table)")
        }
        let space = try #require(waiting.upgradeWaitingForSpace)
        #expect(space.availableBytes == 1_500_000_000)
        #expect(space.neededBytes >= databaseBytes + 2_000_000_000)
        #expect(LibraryUpgradeSpace.message(for: space).hasPrefix("Free up "))
        // Generation 1 runs on the store as the build before did, 149's and 150's columns included.
        #expect(try waiting.loadSourcesWithoutContent().count == 3)
        try waiting.updateReviewSessionModel(
            sessionID: "chat-in-gone", modelProvider: AIProvider.openRouter.rawValue, modelID: "model-under-test",
            modelEffort: "high", modelSpeed: nil
        )
        #expect(try waiting.loadReviewSessionModelRoute(sessionID: "chat-in-gone")?.modelEffort == "high")
        #expect(try waiting.loadCourseFollowers().isEmpty)
        try waiting.deleteSource(library.sourceIDs[1])
        #expect(try Schema154Fixture.count(waiting, "SELECT COUNT(*) FROM hidden_sources WHERE source_id = '\(library.sourceIDs[1])'") == 0)

        // The rest of the launch keeps its first open's decision, whatever the disk says now.
        let sameLaunch = try KnowledgeStore(storeDirectory: root, syncGeneration: .one, freeSpace: Schema154Fixture.roomy)
        #expect(sameLaunch.rollbackCopy == nil)
        #expect(sameLaunch.upgradeWaitingForSpace == space)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == 153)

        Schema154Fixture.newLaunch(root)
        let later = try KnowledgeStore(storeDirectory: root, syncGeneration: .one, freeSpace: Schema154Fixture.roomy)
        #expect(later.rollbackCopy?.userVersion == 153, "the copy is the store as the launch before left it")
        #expect(later.upgradeWaitingForSpace == nil)
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        #expect(Schema154Fixture.foreignKeyCount(at: root, "source_highlights") == 0)
        #expect(try later.loadReviewSessionModelRoute(sessionID: "chat-in-gone")?.modelEffort == "high")
    }

    @Test("Generation 2 refuses a store it has no room to copy, and migrates nothing")
    func generation2RefusesWithoutRoom() throws {
        let root = try Schema154Fixture.temporaryRoot("room-gen2")
        defer { try? FileManager.default.removeItem(at: root) }
        try Schema154Fixture.makeLibrary(at: root, version: 153)
        do {
            _ = try KnowledgeStore(storeDirectory: root, syncGeneration: .two, freeSpace: { _ in 1_000_000_000 })
            Issue.record("generation 2 opened a store it could not copy")
        } catch KnowledgeStoreError.noRoomForRollbackCopy(let bytesToFree) {
            #expect(bytesToFree > 0)
            #expect(KnowledgeStoreError.noRoomForRollbackCopy(bytesToFree: bytesToFree).localizedDescription.hasPrefix("Free up "))
        }
        #expect(Schema154Fixture.count(at: root, "PRAGMA user_version") == 153)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("knowledge.pre-v2.db").path))
        // A retry in the same launch follows the launch's decision.
        #expect(throws: KnowledgeStoreError.self) {
            _ = try KnowledgeStore(storeDirectory: root, syncGeneration: .two, freeSpace: Schema154Fixture.roomy)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("knowledge.pre-v2.db").path))
    }

    @Test("A copy that fails midway leaves no partial file, and a crash's leftover is cleared")
    func partialCopyIsRemoved() throws {
        let root = try Schema154Fixture.temporaryRoot("partial")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { LibraryUpgradeSpace.record(nil) }
        try Schema154Fixture.makeLibrary(at: root, version: 153)
        struct Interrupted: Error {}
        #expect(throws: Interrupted.self) {
            _ = try KnowledgeRollbackCopy.take(.beforeSchema154, ofStoreAt: root, beforeMovingIntoPlace: { throw Interrupted() })
        }
        let staging = KnowledgeRollbackCopy.stagingURL(.beforeSchema154, in: root)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("knowledge.pre-154.db").path))

        try Data(repeating: 1, count: 4096).write(to: staging)
        try Data(repeating: 2, count: 512).write(to: URL(fileURLWithPath: staging.path + "-journal"))
        _ = try KnowledgeStore(storeDirectory: root, syncGeneration: .one, freeSpace: { _ in 1_000_000_000 })
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(!FileManager.default.fileExists(atPath: staging.path + "-journal"))
    }

    @Test("The room a copy needs, and the line that names it")
    func roomArithmetic() {
        #expect(KnowledgeRollbackCopy.requiredFreeBytes(databaseBytes: 4_380_762_112, walBytes: 2_385_512) == 6_383_147_624)
        #expect(KnowledgeRollbackCopy.requiredFreeBytes(databaseBytes: 30_000_000_000, walBytes: 0) == 33_000_000_000)
        #expect(KnowledgeRollbackCopy.readableBytes(6_200_000_000) == "6.2 GB")
        #expect(KnowledgeRollbackCopy.readableBytes(6_210_000_000) == "6.3 GB")
        #expect(KnowledgeRollbackCopy.readableBytes(1) == "0.1 GB")
        let check = KnowledgeRollbackCopy.SpaceCheck(neededBytes: 7_000_000_000, availableBytes: 900_000_000)
        #expect(!check.isEnough && check.bytesToFree == 6_100_000_000)
        #expect(LibraryUpgradeSpace.message(for: check) == "Free up 6.1 GB on this Mac so ForeverLM can finish updating your library.")
    }
}
