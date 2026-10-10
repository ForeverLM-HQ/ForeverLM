import Foundation

/// When one device's sync rounds run (docs/cloudkit-schema-design.md §2.3): once at launch, whenever the app
/// comes forward, every 15 minutes, and a moment after the learner's own write, so an edit leaves without
/// waiting for the next timer. Push is never relied on. The iPhone (`MobileSyncSession`) and the Mac
/// (`MacSyncSession`) both run their rounds through one of these; what a round does is theirs (`round`).
///
/// A round that is asked for while another runs is the coordinator's to fold (`SyncCoordinator.runRound`),
/// so a timer that fires during a long round costs nothing.
actor SyncRoundLoop {
    static let refreshInterval: TimeInterval = 15 * 60
    /// How long a write's round waits past the write's own debounce, so writes in quick succession share one.
    static let writeGrace: TimeInterval = 0.5

    typealias Sleep = @Sendable (TimeInterval) async -> Void

    private let interval: TimeInterval
    private let sleep: Sleep
    private let work: @Sendable () async -> Void
    private var refresh: Task<Void, Never>?
    private var send: Task<Void, Never>?

    init(interval: TimeInterval = SyncRoundLoop.refreshInterval,
         sleep: @escaping Sleep = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) },
         round: @escaping @Sendable () async -> Void) {
        self.interval = interval
        self.sleep = sleep
        self.work = round
    }

    /// Whether the 15-minute timer is running.
    var isTiming: Bool { refresh != nil }

    /// The app came forward: a round now (unless `roundNow` is false, for a caller that just ran one), and
    /// the timer starts, or starts over.
    func foreground(roundNow: Bool = true) async {
        startTimer()
        if roundNow { await work() }
    }

    /// A round now, the timer left as it is.
    func requestRound() async {
        await work()
    }

    /// The timer and any waiting write round stop (the iPhone, when the app leaves the foreground).
    func background() {
        refresh?.cancel()
        refresh = nil
        send?.cancel()
        send = nil
    }

    /// Something was written: a round once the newest of it is due, so it goes out without waiting for the
    /// next timer; writes in quick succession share one.
    func wrote(dueIn seconds: TimeInterval) {
        send?.cancel()
        let wait = max(0, seconds) + Self.writeGrace
        send = Task { [weak self, sleep] in
            await sleep(wait)
            guard !Task.isCancelled else { return }
            await self?.sentRound()
        }
    }

    private func sentRound() async {
        await work()
    }

    private func startTimer() {
        refresh?.cancel()
        let interval = interval
        refresh = Task { [weak self, sleep] in
            while !Task.isCancelled {
                await sleep(interval)
                guard !Task.isCancelled else { return }
                await self?.round()
            }
        }
    }

    private func round() async {
        await work()
    }
}
