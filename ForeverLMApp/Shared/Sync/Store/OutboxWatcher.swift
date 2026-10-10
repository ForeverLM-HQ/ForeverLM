import Foundation

/// What the outbox holds, as one cheap look: how many rows wait and when the newest was written (pins
/// aside). Two looks that differ mean the learner (or another connection of this process, such as the MCP
/// store's) wrote since, which no notification covers: the generated triggers fire on every connection.
struct OutboxSignature: Equatable, Sendable {
    var rows: Int64
    var newest: Double

    static func read(in connection: SQLiteConnection) throws -> OutboxSignature {
        var signature = OutboxSignature(rows: 0, newest: 0)
        try connection.query("""
            SELECT (SELECT COUNT(*) FROM ck_outbox) + (SELECT COUNT(*) FROM ck_outbox_fields WHERE source_table <> ?),
                   MAX(COALESCE((SELECT MAX(dirty_at) FROM ck_outbox), 0),
                       COALESCE((SELECT MAX(dirty_at) FROM ck_outbox_fields WHERE source_table <> ?), 0))
        """, [.text(OutboxFeeder.pinSource), .text(OutboxFeeder.pinSource)]) { row in
            signature = OutboxSignature(rows: row.integer(0) ?? 0, newest: row.real(1) ?? 0)
        }
        return signature
    }
}

/// The local changes the outbox still holds for the server, due or not: each local row with a change or a
/// removal waiting counts once however many of its fields changed, and each record with a patch waiting
/// (`ck_patches`: late import's, listen positions) once. Pinned stamps are not changes. Zero means
/// everything this Mac wrote has reached iCloud; rows a refusal or a conflict parked until the next launch
/// still count, since they have not.
struct OutboxBacklog: Equatable, Sendable {
    var changes: Int
    /// When the newest of them was written (Cocoa seconds); 0 when none waits.
    var newest: Double

    static func read(in connection: SQLiteConnection) throws -> OutboxBacklog {
        var backlog = OutboxBacklog(changes: 0, newest: 0)
        try connection.query("""
            SELECT (SELECT COUNT(*) FROM (SELECT source_table, local_key FROM ck_outbox_fields WHERE source_table <> ?
                                          UNION SELECT source_table, local_key FROM ck_outbox))
                   + (SELECT COUNT(*) FROM ck_patches),
                   MAX(COALESCE((SELECT MAX(dirty_at) FROM ck_outbox_fields WHERE source_table <> ?), 0),
                       COALESCE((SELECT MAX(dirty_at) FROM ck_outbox), 0),
                       COALESCE((SELECT MAX(dirty_at) FROM ck_patches), 0))
        """, [.text(OutboxFeeder.pinSource), .text(OutboxFeeder.pinSource)]) { row in
            backlog = OutboxBacklog(changes: Int(row.integer(0) ?? 0), newest: row.real(1) ?? 0)
        }
        return backlog
    }
}

/// "Sync now and wait" (a finished course import, Settings, MCP): pushes what the outbox holds and waits until
/// it is empty, or until a push stops making progress, and returns how many changes still wait. Zero only
/// when the outbox is empty.
///
/// A change is due once its projection's debounce has passed (2 seconds for most, `OutboxFeeder`), so the
/// first push waits until the newest change is due. CKSyncEngine and the pacers own failure backoff: a push
/// that leaves as much waiting as before ends the wait, since asking again at once would defeat them and
/// could amplify CloudKit throttling (`CloudKitSyncDrainPolicy`).
struct OutboxDrain {
    /// One push: in the app the Mac's sync round (`MacSyncSession.round`), which sends the private zones and
    /// the spaces.
    let push: @Sendable () async -> Void
    let backlog: @Sendable () async -> OutboxBacklog?
    var sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }
    var now: @Sendable () -> Date = { Date() }
    /// How long a push waits after a write, and between pushes: past the outbox's default debounce.
    var settle: TimeInterval = SyncCoordinator.sendSoonDelay

    func run(maxAttempts: Int = 4) async -> Int {
        guard let first = await backlog(), first.changes > 0 else { return 0 }
        let untilDue = first.newest + settle - now().timeIntervalSinceReferenceDate
        if untilDue > 0 { await sleep(min(untilDue, settle)) }

        var remaining = first.changes
        let attempts = max(1, maxAttempts)
        for attempt in 0..<attempts {
            guard !Task.isCancelled else { break }
            let previousRemaining = remaining
            await push()
            // An unreadable store tells nothing new: what waited before still waits.
            remaining = await backlog()?.changes ?? remaining
            if remaining == 0 { return 0 }
            guard CloudKitSyncDrainPolicy.shouldAttemptAgain(
                previousRemaining: previousRemaining,
                currentRemaining: remaining,
                attempt: attempt,
                maxAttempts: attempts
            ) else { break }
            await sleep(settle)
        }
        return remaining
    }
}

/// Looks at the outbox now and then and says when something new was written to it: the backstop behind the
/// writes that announce themselves (`StorageService.scheduleCloudKitSync`, which asks the Mac's session to send
/// soon). It covers what writes the store without telling anyone, such as the MCP store's connection, whose
/// triggers fire as every other's (§2.3). Under generation 2 a write only records outbox rows (the triggers).
actor OutboxWatcher {
    /// Low, since it is a backstop (AGENTS.md "Event-driven over polling"): a write that announces itself is
    /// sent a few seconds after it is made, and the 15-minute round sends whatever this missed.
    static let interval: TimeInterval = 60

    private let interval: TimeInterval
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let read: @Sendable () async -> OutboxSignature?
    private let changed: @Sendable () async -> Void
    private var last: OutboxSignature?
    private var task: Task<Void, Never>?

    init(interval: TimeInterval = OutboxWatcher.interval,
         sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) },
         read: @escaping @Sendable () async -> OutboxSignature?,
         changed: @escaping @Sendable () async -> Void) {
        self.interval = interval
        self.sleep = sleep
        self.read = read
        self.changed = changed
    }

    func start() {
        guard task == nil else { return }
        let interval = interval
        task = Task { [weak self, sleep] in
            while !Task.isCancelled {
                await sleep(interval)
                guard !Task.isCancelled else { return }
                await self?.look()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// One look. The first only learns what is there (the launch round sends it); later ones call `changed`
    /// when the outbox holds rows and differs from the look before. Returns whether it did.
    @discardableResult
    func look() async -> Bool {
        guard let now = await read() else { return false }
        defer { last = now }
        guard let last, last != now, now.rows > 0 else { return false }
        await changed()
        return true
    }
}
