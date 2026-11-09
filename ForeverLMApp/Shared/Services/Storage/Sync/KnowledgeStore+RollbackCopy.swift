import Darwin
import Foundation
import OSLog
import SQLite3

/// The verified copy of `knowledge.db` that a store keeps before it migrates into schema v2
/// (docs/cloudkit-schema-design.md §13.3 step 1, D35, D46).
///
/// Two moments take one, for a store that holds a library (an empty store has nothing to roll back):
/// - **any build that runs migration 154**, a generation-1 hotfix included, on a store below 154:
///   `knowledge.pre-154.db`;
/// - **a store's first generation-2 launch**, whatever its version, while it is not activated and
///   its `ck_activation` names no copy: `knowledge.pre-v2.db`, the store exactly as the last
///   generation-1 build left it. A `knowledge.pre-v2.db` that nothing names (a launch that stopped
///   before the activation recorded it) is replaced at the next launch.
///
/// A launch decides once per store, takes one copy at most and checks it once, however many times it
/// opens the store (`KnowledgeStoreOpening`).
///
/// The copy is a `clonefile(2)` of the store after `PRAGMA wal_checkpoint(TRUNCATE)` came back clean,
/// taken while this connection holds the write lock, so no writer anywhere can commit, or checkpoint
/// into the file, while it is cloned. When the checkpoint is not clean (a reader on an older
/// snapshot), or the volume cannot clone, SQLite's online backup copies one read snapshot instead.
/// Either way the copy is consistent with a committed state of the store and is never written once
/// made: its `user_version` is read back from the copy itself, `PRAGMA quick_check` runs on it on one
/// serial `.utility` queue while the migrations proceed, and both land in `<copy>.json` beside it. When
/// neither a clone nor a backup is possible the migration still runs; the store simply has no rollback
/// copy.
///
/// No copy starts that could fill the disk. A clone costs nothing at first, but every page the live
/// store rewrites afterwards is then held twice, and a backup writes the whole file, so a copy needs
/// the volume's capacity for important usage to cover the store, its WAL and a margin of 2 GB or a
/// tenth of the store, whichever is larger. Short of that, generation 1 holds the store below 154 this
/// launch: every earlier step still runs, as none of them ever needed a copy, and the store is stamped
/// 153, which generation 1 reads and writes exactly as the build before (154's tables and columns are
/// only generation 2's); the learner is told how much to free (`LibraryUpgradeSpace`). Generation 2
/// cannot run on a store it could not copy, so its open refuses with the same figure. A copy that
/// fails midway leaves no partial file.
enum KnowledgeRollbackCopy {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case beforeSchema154 = "knowledge.pre-154.db"
        case beforeGeneration2 = "knowledge.pre-v2.db"

        var fileName: String { rawValue }
        /// Where the copy's facts are kept: never in the store (generation 1 writes no `ck_*` row).
        var recordFileName: String { rawValue + ".json" }
    }

    enum Method: String, Codable, Sendable {
        case clone
        case backup
    }

    /// What was taken. `fileName` is relative to the store's folder, as `ck_activation.clone_path`
    /// records it, so a cloned data folder never names another store's copy.
    struct Record: Codable, Equatable, Sendable {
        var kind: Kind
        var fileName: String
        /// Read back from the copy, never assumed from the store.
        var userVersion: Int32
        var method: Method
        var takenAt: Date
        /// `ok`, or what `PRAGMA quick_check` found first; nil until the check has run.
        var quickCheck: String?
        var checkedAt: Date?

        var passedQuickCheck: Bool { quickCheck == "ok" }
    }

    /// What decides whether a launch takes a copy, read from the store before it migrates.
    struct StoreState: Equatable, Sendable {
        enum Activation: Equatable, Sendable {
            /// `ck_activation` names no copy and the store is not activated (or the table does not
            /// exist yet, below 154).
            case notRecorded
            /// `ck_activation.clone_path` names the copy this store's first generation-2 launch took.
            case copyRecorded(String)
            /// `ck_activation.activated_at` is set: generation 2 already runs on this store.
            case activated
        }

        var userVersion: Int32
        var holdsLibrary: Bool
        var activation: Activation
    }

    /// What a launch decided about a store's copy, once per store per process
    /// (`KnowledgeStoreOpening.copyDecision`): every later open of the store in this launch, a retry
    /// after a migration that failed included, follows it and copies and checks nothing of its own.
    enum LaunchDecision: Equatable, Sendable {
        /// The copy was taken, tried and not made, or owed by nothing: the store migrates. Generation
        /// 2 counts the launch's copy as recorded until the activation records it (§13.3 step 3a).
        case settled
        /// The disk had no room for it: generation 1 migrates no further than 153 this launch, and
        /// generation 2 refuses the store.
        case waitingForRoom(SpaceCheck)
    }

    enum Failure: Error, LocalizedError, Equatable {
        case cannotOpenStore(String)
        case backupFailed(String)
        case unreadableCopy(String)

        var errorDescription: String? {
            switch self {
            case .cannotOpenStore(let message): return "Could not open the store to copy it: \(message)"
            case .backupFailed(let message): return "The online backup of the store failed: \(message)"
            case .unreadableCopy(let message): return "The rollback copy could not be read back: \(message)"
            }
        }
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "RollbackCopy")

    // MARK: - Room for the copy

    /// The room a copy needs against the room the volume has.
    struct SpaceCheck: Equatable, Sendable {
        let neededBytes: Int64
        let availableBytes: Int64

        var isEnough: Bool { availableBytes >= neededBytes }
        var bytesToFree: Int64 { max(0, neededBytes - availableBytes) }
    }

    /// The store, its WAL, and a margin of 2 GB or a tenth of the store, whichever is larger.
    static func requiredFreeBytes(databaseBytes: Int64, walBytes: Int64) -> Int64 {
        databaseBytes + walBytes + max(2_000_000_000, databaseBytes / 10)
    }

    /// The volume's available capacity for important usage at `url`, as the system counts it (purgeable
    /// space included); the plain available capacity where a volume does not report that one.
    static func availableCapacity(at url: URL) throws -> Int64? {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values.volumeAvailableCapacityForImportantUsage { return important }
        return values.volumeAvailableCapacity.map(Int64.init)
    }

    /// Whether the store in `storeDirectory` can be copied now; nil when the volume reports no capacity
    /// at all, which the store's own volume always does.
    static func spaceCheck(forStoreAt storeDirectory: URL, freeSpace: (URL) throws -> Int64?) -> SpaceCheck? {
        func size(_ url: URL) -> Int64 {
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        let database = storeDirectory.appendingPathComponent("knowledge.db")
        let needed = requiredFreeBytes(
            databaseBytes: size(database),
            walBytes: size(URL(fileURLWithPath: database.path + "-wal"))
        )
        guard let available = try? freeSpace(storeDirectory) else { return nil }
        return SpaceCheck(neededBytes: needed, availableBytes: available)
    }

    /// "6.2 GB", rounded up to a tenth, as the learner reads disk space in the Finder.
    static func readableBytes(_ bytes: Int64) -> String {
        let tenths = (Double(bytes) / 100_000_000).rounded(.up) / 10
        return String(format: "%.1f GB", max(tenths, 0.1))
    }

    /// The copy a launch takes, or nil: `knowledge.pre-v2.db`, at the first launch of a store whose
    /// activation has recorded none, at any version. A store newer than this build is refused by
    /// `createSchema` anyway.
    static func kindToTake(_ state: StoreState, schemaVersion: Int32) -> Kind? {
        guard state.holdsLibrary, state.userVersion > 0, state.userVersion <= schemaVersion else { return nil }
        return state.activation == .notRecorded ? .beforeGeneration2 : nil
    }

    /// Whether any copy could be owed at `userVersion`, before anything else about the store is read:
    /// none is to a brand-new store, so its open costs one version read.
    static func copyMayBeDue(atVersion userVersion: Int32, schemaVersion: Int32) -> Bool {
        let anyLibrary = StoreState(userVersion: userVersion, holdsLibrary: true, activation: .notRecorded)
        return kindToTake(anyLibrary, schemaVersion: schemaVersion) != nil
    }

    // MARK: - Taking the copy

    /// The name a copy is made under until it is whole; nothing else ever reads it.
    static func stagingURL(_ kind: Kind, in storeDirectory: URL) -> URL {
        storeDirectory.appendingPathComponent(kind.fileName + ".taking")
    }

    /// Removes a copy that was not finished, and the journal a backup into it may have left.
    static func removePartialCopy(_ kind: Kind, in storeDirectory: URL) {
        let staging = stagingURL(kind, in: storeDirectory)
        for path in [staging.path, staging.path + "-journal", staging.path + "-wal", staging.path + "-shm"] {
            removeIfPresent(URL(fileURLWithPath: path))
        }
    }

    /// Takes `kind` of the store in `storeDirectory`, replacing an earlier copy of that kind, and
    /// records it in `<copy>.json`. The caller holds the store's open gate, so no other connection
    /// of this process exists or writes while it runs; another process may, and cannot tear it. The
    /// copy is made under its staging name and moved into place only when whole: any failure on the
    /// way (and `beforeMovingIntoPlace`, a test's stand-in for one) removes the partial file.
    static func take(
        _ kind: Kind,
        ofStoreAt storeDirectory: URL,
        now: Date = Date(),
        beforeMovingIntoPlace: () throws -> Void = {}
    ) throws -> Record {
        let source = storeDirectory.appendingPathComponent("knowledge.db")
        let destination = storeDirectory.appendingPathComponent(kind.fileName)
        let staging = stagingURL(kind, in: storeDirectory)
        removePartialCopy(kind, in: storeDirectory)

        var handle: OpaquePointer?
        guard sqlite3_open_v2(source.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            let message = SQLiteStatements.message(handle)
            sqlite3_close(handle)
            throw Failure.cannotOpenStore(message)
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 2_000)

        let method: Method
        do {
            method = try cloneOrBackUp(handle, source: source, staging: staging)
            try beforeMovingIntoPlace()
        } catch {
            removePartialCopy(kind, in: storeDirectory)
            throw error
        }

        // A copy made earlier, and any side file a reader left beside it, give way to this one.
        for suffix in ["-wal", "-shm", "-journal"] {
            removeIfPresent(URL(fileURLWithPath: destination.path + suffix))
        }
        guard rename(staging.path, destination.path) == 0 else {
            let message = String(cString: strerror(errno))
            removePartialCopy(kind, in: storeDirectory)
            throw Failure.backupFailed("could not move the copy into place: \(message)")
        }
        excludeFromBackups(destination)
        let record = Record(
            kind: kind,
            fileName: kind.fileName,
            userVersion: try userVersion(ofCopyAt: destination),
            method: method,
            takenAt: now
        )
        try write(record, in: storeDirectory)
        return record
    }

    private static func cloneOrBackUp(_ handle: OpaquePointer, source: URL, staging: URL) throws -> Method {
        // A writer that commits between the checkpoint and the write lock leaves the WAL non-empty;
        // the checkpoint is tried again a few times before the backup takes over.
        for _ in 0..<3 {
            guard let result = checkpoint(handle), result.busy == 0, result.log == result.checkpointed else { break }
            guard (try? SQLiteStatements.executeScript(handle, "BEGIN IMMEDIATE")) != nil else { break }
            let cloned: Bool? = walIsEmpty(source)
                ? clonefile(source.path, staging.path, UInt32(CLONE_NOFOLLOW)) == 0
                : nil
            try? SQLiteStatements.executeScript(handle, "ROLLBACK")
            switch cloned {
            case true?: return .clone
            case false?: return try backUp(handle, to: staging)
            case nil: continue
            }
        }
        return try backUp(handle, to: staging)
    }

    /// `PRAGMA wal_checkpoint(TRUNCATE)`: (busy, log, checkpointed). A rollback-journal store answers
    /// (0, -1, -1), which is as clean as it gets.
    private static func checkpoint(_ handle: OpaquePointer) -> (busy: Int64, log: Int64, checkpointed: Int64)? {
        var result: (Int64, Int64, Int64)?
        try? SQLiteStatements.run(handle, "PRAGMA wal_checkpoint(TRUNCATE)", [], { row in
            result = (row.integer(0) ?? 1, row.integer(1) ?? -2, row.integer(2) ?? -3)
        })
        return result.map { (busy: $0.0, log: $0.1, checkpointed: $0.2) }
    }

    private static func walIsEmpty(_ source: URL) -> Bool {
        let wal = source.path + "-wal"
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: wal) else { return true }
        return (attributes[.size] as? NSNumber)?.int64Value == 0
    }

    /// The online backup API over one read snapshot: the read transaction stays open across every
    /// step, so a writer on another connection neither tears the copy nor restarts it.
    private static func backUp(_ handle: OpaquePointer, to staging: URL) throws -> Method {
        removeIfPresent(staging)
        var target: OpaquePointer?
        guard sqlite3_open_v2(staging.path, &target, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let target else {
            let message = SQLiteStatements.message(target)
            sqlite3_close(target)
            throw Failure.backupFailed(message)
        }
        defer { sqlite3_close(target) }

        try SQLiteStatements.executeScript(handle, "BEGIN")
        defer { try? SQLiteStatements.executeScript(handle, "ROLLBACK") }
        try SQLiteStatements.run(handle, "SELECT COUNT(*) FROM sqlite_master", [], { _ in })

        guard let backup = sqlite3_backup_init(target, "main", handle, "main") else {
            throw Failure.backupFailed(SQLiteStatements.message(target))
        }
        var code = SQLITE_OK
        var waits = 0
        repeat {
            code = sqlite3_backup_step(backup, 4_096)
            if code == SQLITE_BUSY || code == SQLITE_LOCKED {
                waits += 1
                guard waits < 200 else { break }
                usleep(10_000)
            }
        } while code == SQLITE_OK || code == SQLITE_BUSY || code == SQLITE_LOCKED
        let finished = sqlite3_backup_finish(backup)
        guard code == SQLITE_DONE, finished == SQLITE_OK else {
            throw Failure.backupFailed(SQLiteStatements.message(target))
        }
        return .backup
    }

    // MARK: - Reading and checking the copy, read-only

    /// Opens the copy immutable and read-only: no lock, no WAL, no side file, never a write.
    private static func openCopy(_ url: URL) throws -> OpaquePointer {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#%")
        let path = url.path.addingPercentEncoding(withAllowedCharacters: allowed) ?? url.path
        var handle: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?immutable=1", &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let handle else {
            let message = SQLiteStatements.message(handle)
            sqlite3_close(handle)
            throw Failure.unreadableCopy(message)
        }
        return handle
    }

    static func userVersion(ofCopyAt url: URL) throws -> Int32 {
        let handle = try openCopy(url)
        defer { sqlite3_close(handle) }
        var version: Int64?
        do {
            try SQLiteStatements.run(handle, "PRAGMA user_version", [], { version = $0.integer(0) })
        } catch {
            throw Failure.unreadableCopy(error.localizedDescription)
        }
        guard let version else { throw Failure.unreadableCopy("no user_version") }
        return Int32(version)
    }

    /// Runs `PRAGMA quick_check` on the copy and records its answer, and when it came, beside it,
    /// unless a newer copy replaced this one meanwhile. Blocking: the launch runs it through
    /// `queueCheck`, never on the main actor or the cooperative pool.
    @discardableResult
    static func check(_ record: Record, in storeDirectory: URL) -> Record {
        var checked = record
        do {
            let handle = try openCopy(storeDirectory.appendingPathComponent(record.fileName))
            defer { sqlite3_close(handle) }
            var lines: [String] = []
            try SQLiteStatements.run(handle, "PRAGMA quick_check", [], { row in
                if lines.count < 5, let line = row.text(0) { lines.append(line) }
            })
            checked.quickCheck = lines == ["ok"] ? "ok" : lines.joined(separator: "; ")
        } catch {
            checked.quickCheck = "could not check: \(error.localizedDescription)"
        }
        checked.checkedAt = Date()
        if let current = recorded(record.kind, in: storeDirectory),
           abs(current.takenAt.timeIntervalSince(record.takenAt)) < 0.001 {
            do {
                try write(checked, in: storeDirectory)
            } catch {
                logger.error("Could not record the rollback copy's check: \(error.localizedDescription, privacy: .public)")
            }
        }
        if checked.passedQuickCheck {
            logger.notice("Rollback copy \(record.fileName, privacy: .public) passed quick_check")
            // The older generation-1 copy goes the moment the one that replaces it is known good: the launch
            // that took the copy asked before the check had run, and nothing asked again (F30).
            if record.kind == .beforeGeneration2 { GenerationActivation.removeStalePre154Copy(in: storeDirectory) }
        } else {
            logger.error("Rollback copy \(record.fileName, privacy: .public) failed quick_check: \(checked.quickCheck ?? "", privacy: .public)")
        }
        return checked
    }

    /// The one queue every copy's `quick_check` runs on, in turn, at `.utility`. A check reads the
    /// whole copy (about 20 s for 4.4 GB), so it holds a thread of its own rather than one of Swift's
    /// cooperative pool, and two checks never read two copies at once.
    private static let checkQueue = DispatchQueue(label: "ForeverLM.KnowledgeRollbackCopy.quickCheck", qos: .utility)

    /// A check's answer, written and read only on `checkQueue`.
    private final class CheckAnswer: @unchecked Sendable {
        var record: Record?
    }

    /// Queues the check of a copy just taken and hands back its answer to await. Only the open that
    /// takes a copy calls this, once per copy: the launch's other opens take none
    /// (`KnowledgeStoreOpening.copyDecision`).
    static func queueCheck(_ record: Record, in storeDirectory: URL) -> Task<Record, Never> {
        let answer = CheckAnswer()
        checkQueue.async {
            answer.record = check(record, in: storeDirectory)
        }
        #if DEBUG
        noteCheckQueued(in: storeDirectory)
        #endif
        return Task.detached(priority: .utility) {
            await withCheckedContinuation { continuation in
                // Behind the check on the serial queue, so its answer is there.
                checkQueue.async {
                    continuation.resume(returning: answer.record ?? record)
                }
            }
        }
    }

    #if DEBUG
    private static let checksQueuedLock = NSLock()
    nonisolated(unsafe) private static var checksQueued: [String: Int] = [:]

    private static func noteCheckQueued(in storeDirectory: URL) {
        let key = storeDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        checksQueuedLock.lock()
        checksQueued[key, default: 0] += 1
        checksQueuedLock.unlock()
    }

    /// How many checks this process has queued for the store in `storeDirectory`.
    static func checksQueuedForTesting(in storeDirectory: URL) -> Int {
        let key = storeDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        checksQueuedLock.lock()
        defer { checksQueuedLock.unlock() }
        return checksQueued[key] ?? 0
    }

    /// Returns once every check queued so far has run.
    static func queuedChecksForTesting() async {
        await withCheckedContinuation { continuation in
            checkQueue.async { continuation.resume() }
        }
    }
    #endif

    /// The copy of `kind` this store's folder holds, as recorded beside it, if both are there.
    static func recorded(_ kind: Kind, in storeDirectory: URL) -> Record? {
        let copy = storeDirectory.appendingPathComponent(kind.fileName)
        guard FileManager.default.fileExists(atPath: copy.path),
              let data = try? Data(contentsOf: storeDirectory.appendingPathComponent(kind.recordFileName)) else {
            return nil
        }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private static func write(_ record: Record, in storeDirectory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: storeDirectory.appendingPathComponent(record.kind.recordFileName), options: .atomic)
    }

    private static func removeIfPresent(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Keeps the copy out of Time Machine, which holds the store's own history already: backed up, the
    /// copy would be a second whole library on the backup disk, while on this Mac it starts as a clone
    /// that costs nothing.
    private static func excludeFromBackups(_ url: URL) {
        var copy = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try copy.setResourceValues(values)
        } catch {
            logger.error("Could not keep the rollback copy out of backups: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// One open of a store file at a time in this process, and one rollback-copy decision per store file
/// per process. A store's open decides and takes its rollback copy and runs its migrations under this
/// gate, so a second `KnowledgeStore` on the same file (the app holds several) waits and then finds
/// the store current, instead of copying a store another connection is migrating or running the same
/// migration twice. The first open that asks whether a library is owed a copy decides for the whole
/// launch: a later open, and every retry of an open whose migration failed (storage calls retry a
/// failed open), takes no second copy and starts no second check, and generation 2 never copies a
/// store it has already migrated this launch. A store that is already current holds the gate only
/// for the version read.
enum KnowledgeStoreOpening {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var gates: [String: NSRecursiveLock] = [:]
    nonisolated(unsafe) private static var copyDecisions: [String: KnowledgeRollbackCopy.LaunchDecision] = [:]

    private static func key(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func gate(forDatabaseAt path: String) -> NSRecursiveLock {
        let key = key(path)
        registryLock.lock()
        defer { registryLock.unlock() }
        if let gate = gates[key] { return gate }
        let gate = NSRecursiveLock()
        gate.name = "KnowledgeStoreOpening \(key)"
        gates[key] = gate
        return gate
    }

    /// This launch's decision about the store's rollback copy, once an open of it has made one.
    static func copyDecision(forDatabaseAt path: String) -> KnowledgeRollbackCopy.LaunchDecision? {
        let key = key(path)
        registryLock.lock()
        defer { registryLock.unlock() }
        return copyDecisions[key]
    }

    static func recordCopyDecision(_ decision: KnowledgeRollbackCopy.LaunchDecision, forDatabaseAt path: String) {
        let key = key(path)
        registryLock.lock()
        defer { registryLock.unlock() }
        copyDecisions[key] = decision
    }

    #if DEBUG
    /// Forgets the store's decision, so its next open decides as the next launch's first would.
    static func startNewLaunchForTesting(databaseAt path: String) {
        let key = key(path)
        registryLock.lock()
        defer { registryLock.unlock() }
        copyDecisions[key] = nil
    }
    #endif
}

/// A library update this launch put off because the disk had no room for its rollback copy, for the
/// learner's corner card (`StoreUpgradeSpaceCard`). Process-wide: the store open that finds it runs
/// on the storage actor, the card on the main actor, and either may come first.
enum LibraryUpgradeSpace {
    static let didChange = Notification.Name("ForeverLMLibraryUpgradeSpaceDidChange")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var waiting: KnowledgeRollbackCopy.SpaceCheck?

    /// The room the update still waits for, nil when it waits for nothing.
    static var current: KnowledgeRollbackCopy.SpaceCheck? {
        lock.lock()
        defer { lock.unlock() }
        return waiting
    }

    static func record(_ check: KnowledgeRollbackCopy.SpaceCheck?) {
        lock.lock()
        let changed = waiting != check
        waiting = check
        lock.unlock()
        // Posted from the main queue, never from here: the open that records this holds the
        // store's open gate, and a post waits for its main-queue observers.
        if changed {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: didChange, object: nil)
            }
        }
    }

    /// The card's one line.
    static func message(for check: KnowledgeRollbackCopy.SpaceCheck) -> String {
        "Free up \(KnowledgeRollbackCopy.readableBytes(check.bytesToFree)) on this Mac so ForeverLM can finish updating your library."
    }
}

extension KnowledgeStore {
    /// §13.3 step 1, between opening the connection and `createSchema()`, under the open gate.
    /// Returns whether the open may migrate through 154. A copy that cannot be made for another reason
    /// still lets the store migrate, and says so in the log. Short of room for it, generation 1 migrates
    /// no further than 153 this launch (false) and generation 2 refuses to open it (it throws).
    func takeRollbackCopyBeforeMigrating(storeDirectory: URL, freeSpace: (URL) throws -> Int64?) throws -> Bool {
        // Decided once per store in this process: a later open, and a retry after a failed migration,
        // follow the first decision instead of copying and checking again.
        if let decided = KnowledgeStoreOpening.copyDecision(forDatabaseAt: dbPath) {
            return try follow(decided)
        }
        var state: KnowledgeRollbackCopy.StoreState
        do {
            var version: Int32 = 0
            try query("PRAGMA user_version") { version = sqlite3_column_int($0, 0) }
            guard KnowledgeRollbackCopy.copyMayBeDue(atVersion: version, schemaVersion: Self.schemaVersion) else {
                return true
            }
            state = try rollbackCopyStoreState(userVersion: version)
        } catch {
            KnowledgeStoreOpening.recordCopyDecision(.settled, forDatabaseAt: dbPath)
            rollbackCopyFailure = error.localizedDescription
            logger.error("Could not read the store before migrating, so no rollback copy: \(error.localizedDescription, privacy: .public)")
            return true
        }
        // A copy an earlier launch took whose journal never got to record it, and which the store has been
        // migrated past since (and whose check has not failed), is the store as the last generation-1 build left it: replacing it would copy a
        // store at today's schema, which no rollback build reads. It stays, and the journal records it (F29).
        if state.activation == .notRecorded,
           let held = KnowledgeRollbackCopy.recorded(.beforeGeneration2, in: storeDirectory), held.quickCheck == nil || held.passedQuickCheck,
           held.userVersion < state.userVersion,
           FileManager.default.fileExists(atPath: storeDirectory.appendingPathComponent(held.fileName).path) {
            state.activation = .copyRecorded(held.fileName)
        }
        // An empty store has nothing to roll back, and decides nothing for the launch.
        guard state.holdsLibrary else { return true }
        guard let kind = KnowledgeRollbackCopy.kindToTake(state, schemaVersion: Self.schemaVersion) else {
            KnowledgeStoreOpening.recordCopyDecision(.settled, forDatabaseAt: dbPath)
            return true
        }
        // A copy a crash left half made is no copy.
        for kind in KnowledgeRollbackCopy.Kind.allCases {
            KnowledgeRollbackCopy.removePartialCopy(kind, in: storeDirectory)
        }

        if let space = KnowledgeRollbackCopy.spaceCheck(forStoreAt: storeDirectory, freeSpace: freeSpace), !space.isEnough {
            logger.error(
                "No room for the rollback copy \(kind.fileName, privacy: .public): it needs \(space.neededBytes) bytes free and the volume has \(space.availableBytes); schema 154 waits"
            )
            KnowledgeStoreOpening.recordCopyDecision(.waitingForRoom(space), forDatabaseAt: dbPath)
            return try follow(.waitingForRoom(space))
        }

        KnowledgeStoreOpening.recordCopyDecision(.settled, forDatabaseAt: dbPath)
        do {
            let started = ContinuousClock.now
            let record = try KnowledgeRollbackCopy.take(kind, ofStoreAt: storeDirectory)
            rollbackCopy = record
            logger.notice(
                "Took the rollback copy \(record.fileName, privacy: .public) (\(record.method.rawValue, privacy: .public), schema \(record.userVersion)) in \(started.duration(to: .now).description, privacy: .public)"
            )
            rollbackCopyCheck = KnowledgeRollbackCopy.queueCheck(record, in: storeDirectory)
        } catch {
            rollbackCopyFailure = error.localizedDescription
            logger.error("No rollback copy before migrating: \(error.localizedDescription, privacy: .public)")
        }
        LibraryUpgradeSpace.record(nil)
        return true
    }

    /// What the launch's decision means for this open.
    private func follow(_ decision: KnowledgeRollbackCopy.LaunchDecision) throws -> Bool {
        switch decision {
        case .settled:
            return true
        case .waitingForRoom(let space):
            throw KnowledgeStoreError.noRoomForRollbackCopy(bytesToFree: space.bytesToFree)
        }
    }

    /// The store as the copy decision reads it, on this connection, before any migration.
    func rollbackCopyStoreState(userVersion version: Int32) throws -> KnowledgeRollbackCopy.StoreState {
        var tables = Set<String>()
        try query("SELECT name FROM sqlite_master WHERE type = 'table'") { statement in
            if let name = self.string(statement, 0) { tables.insert(name) }
        }
        var holdsLibrary = false
        for table in ["sources", "learning_goals", "review_sessions", "global_artifacts", "memory_items"]
        where !holdsLibrary && tables.contains(table) {
            try query("SELECT EXISTS(SELECT 1 FROM \(table))") { holdsLibrary = sqlite3_column_int($0, 0) != 0 }
        }
        var activation = KnowledgeRollbackCopy.StoreState.Activation.notRecorded
        // Only generation 2 reads the journal. One that cannot be read names no copy, so the launch
        // takes a fresh one, and the migration's probe refuses the table's shape.
        if tables.contains("ck_activation") {
            try? query("SELECT clone_path, activated_at FROM ck_activation WHERE id = 1") { statement in
                if sqlite3_column_type(statement, 1) != SQLITE_NULL {
                    activation = .activated
                } else if let clonePath = self.string(statement, 0) {
                    activation = .copyRecorded(clonePath)
                }
            }
        }
        return KnowledgeRollbackCopy.StoreState(userVersion: version, holdsLibrary: holdsLibrary, activation: activation)
    }
}
