import CloudKit
import Foundation

/// The one pacer of a container's database (docs/cloudkit-schema-design.md §2.3, D43). CloudKit
/// throttles the client (account × container), not the zone, so the private engine's feeder,
/// SpaceSync and BlobStore share one token bucket: a satellite storm can never stall small-record
/// sync again (the 2026-08-30 failure, 555 refusals in a row).
///
/// - Every request takes one token; tokens come back at `refillPerSecond` up to `capacity`.
/// - Small records have strict priority: while the engine or SpaceSync waits for a token, BlobStore
///   takes none, and BlobStore uploads only while the small-record backlog is under 200 records.
/// - Batch sizes move by AIMD: each success adds `additiveStep` records up to the stream's maximum;
///   any `retryAfter` halves every stream's batch, pauses BlobStore for the interval, and holds the
///   stream that saw it until then (every stream, when CloudKit throttled the whole account).
/// - 20 refusals in a row with no success between them pause every stream for `refusalPause`.
/// - `quotaExceeded` stops every write until `resumeAfterQuota()` (the learner freed space) or
///   `quotaPause` has passed; reads go on, so the library still arrives.
///
/// `SyncPacerState` is the rule, a value with the clock passed in; `SyncPacer` is the actor the
/// streams share, which sleeps a caller until its turn.
struct SyncPacerState: Sendable, Equatable {
    enum Stream: String, Sendable, CaseIterable, Comparable {
        /// The private engine's feeder: small records.
        case engine
        /// SpaceSync's walks and sends: small records.
        case spaces
        /// BlobStore: satellites, the bytes.
        case blobs

        var carriesSmallRecords: Bool { self != .blobs }

        static func < (lhs: Stream, rhs: Stream) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    /// Why a stream is held, for `SyncStatus`.
    enum PauseReason: Sendable, Equatable {
        /// The server asked the client to wait (`retryAfter`).
        case retryAfter
        /// 20 refusals in a row.
        case repeatedRefusals
        /// The iCloud storage writes count against is full; `owner` names a space's owner when the
        /// write went to someone else's space (§2.5), nil for the learner's own.
        case quotaExceeded(owner: String?)
        /// BlobStore waits while small records are queued (strict priority).
        case smallRecordsFirst
    }

    struct Configuration: Sendable, Equatable {
        var capacity: Double = 40
        var refillPerSecond: Double = 10
        var additiveStep = 10
        var refusalLimit = 20
        var refusalPause: TimeInterval = 10 * 60
        var quotaPause: TimeInterval = 60 * 60
        /// BlobStore uploads only while fewer small records than this wait.
        var smallRecordBacklogLimit = 200
        /// A retryAfter the server did not give a value for.
        var defaultRetryAfter: TimeInterval = 30

        static let standard = Configuration()

        func maximumBatch(_ stream: Stream) -> Int {
            stream == .blobs ? SyncSchema.Limits.assetsPerOperationMax : SyncSchema.Limits.batchMaxRecords
        }
    }

    /// What a stream may do now.
    enum Decision: Sendable, Equatable {
        /// Send or fetch one request of at most `batch` items.
        case go(batch: Int)
        /// Ask again at `until`.
        case wait(until: Date, reason: PauseReason?)
    }

    let configuration: Configuration
    private(set) var tokens: Double
    private(set) var refilledAt: Date
    private(set) var batch: [Stream: Int]
    private(set) var heldUntil: [Stream: (until: Date, reason: PauseReason)] = [:]
    private(set) var consecutiveRefusals = 0
    private(set) var quotaHold: (until: Date, owner: String?)?
    /// Small records waiting in the engine's and SpaceSync's queues.
    var smallRecordBacklog = 0
    /// Streams that asked for a token and did not get one yet: a small-record stream here keeps
    /// BlobStore from taking tokens (strict priority).
    private(set) var waiting: Set<Stream> = []

    init(configuration: Configuration = .standard, now: Date) {
        self.configuration = configuration
        tokens = configuration.capacity
        refilledAt = now
        batch = Dictionary(uniqueKeysWithValues: Stream.allCases.map { ($0, configuration.maximumBatch($0)) })
    }

    static func == (lhs: SyncPacerState, rhs: SyncPacerState) -> Bool {
        lhs.tokens == rhs.tokens && lhs.batch == rhs.batch && lhs.consecutiveRefusals == rhs.consecutiveRefusals
            && lhs.smallRecordBacklog == rhs.smallRecordBacklog && lhs.waiting == rhs.waiting
    }

    func batchSize(_ stream: Stream) -> Int { batch[stream] ?? 1 }

    /// The reason a stream is held at `now`, if it is.
    func pause(of stream: Stream, writes: Bool, at now: Date) -> PauseReason? {
        if writes, let quotaHold, quotaHold.until > now { return .quotaExceeded(owner: quotaHold.owner) }
        if let held = heldUntil[stream], held.until > now { return held.reason }
        if stream == .blobs, smallRecordBacklog >= configuration.smallRecordBacklogLimit { return .smallRecordsFirst }
        return nil
    }

    /// Asks for one request's token. `writes` is whether the request saves or deletes anything.
    mutating func request(_ stream: Stream, writes: Bool, at now: Date) -> Decision {
        refill(at: now)
        if writes, let quotaHold, quotaHold.until > now {
            return .wait(until: quotaHold.until, reason: .quotaExceeded(owner: quotaHold.owner))
        }
        if let held = heldUntil[stream], held.until > now {
            return .wait(until: held.until, reason: held.reason)
        }
        if stream == .blobs {
            if smallRecordBacklog >= configuration.smallRecordBacklogLimit
                || waiting.contains(where: \.carriesSmallRecords) {
                waiting.insert(stream)
                return .wait(until: now.addingTimeInterval(1 / configuration.refillPerSecond), reason: .smallRecordsFirst)
            }
        } else if stream == .spaces, waiting.contains(.engine) {
            // The engine and SpaceSync both carry small records; the engine's feeder goes first.
            waiting.insert(stream)
            return .wait(until: now.addingTimeInterval(1 / configuration.refillPerSecond), reason: nil)
        }
        guard tokens >= 1 else {
            waiting.insert(stream)
            return .wait(until: now.addingTimeInterval((1 - tokens) / configuration.refillPerSecond), reason: nil)
        }
        tokens -= 1
        waiting.remove(stream)
        return .go(batch: batchSize(stream))
    }

    /// A stream gave up its place in line (it has nothing to send any more).
    mutating func withdraw(_ stream: Stream) {
        waiting.remove(stream)
    }

    /// The request went through: the stream's batch grows by the additive step.
    mutating func succeeded(_ stream: Stream) {
        consecutiveRefusals = 0
        batch[stream] = min(batchSize(stream) + configuration.additiveStep, configuration.maximumBatch(stream))
    }

    /// The server refused a request of `stream` with `error`. Returns when the stream may ask again.
    @discardableResult
    mutating func refused(_ stream: Stream, with error: CloudError, owner: String? = nil, at now: Date) -> Date {
        consecutiveRefusals += 1
        var resume = now
        switch error.code {
        case .quotaExceeded:
            quotaHold = (now.addingTimeInterval(configuration.quotaPause), owner)
            resume = now.addingTimeInterval(configuration.quotaPause)
        case .requestRateLimited, .serviceUnavailable, .zoneBusy:
            let interval = error.retryAfter ?? configuration.defaultRetryAfter
            let until = now.addingTimeInterval(interval)
            // Every stream sends smaller batches, and BlobStore yields for the interval.
            for stream in Stream.allCases { batch[stream] = max(1, batchSize(stream) / 2) }
            hold(.blobs, until: until, reason: .retryAfter)
            if error.code == .zoneBusy {
                hold(stream, until: until, reason: .retryAfter)
            } else {
                // The account is throttled, not the zone: nobody asks before it says.
                for other in Stream.allCases { hold(other, until: until, reason: .retryAfter) }
                tokens = 0
                refilledAt = until
            }
            resume = until
        default:
            if let retryAfter = error.retryAfter {
                resume = now.addingTimeInterval(retryAfter)
                hold(stream, until: resume, reason: .retryAfter)
            }
        }
        if consecutiveRefusals >= configuration.refusalLimit {
            let until = now.addingTimeInterval(configuration.refusalPause)
            for other in Stream.allCases { hold(other, until: until, reason: .repeatedRefusals) }
            consecutiveRefusals = 0
            resume = max(resume, until)
        }
        return resume
    }

    /// The learner freed space, or the next launch: writes may try again.
    mutating func resumeAfterQuota() {
        quotaHold = nil
    }

    private mutating func hold(_ stream: Stream, until: Date, reason: PauseReason) {
        if let held = heldUntil[stream], held.until >= until { return }
        heldUntil[stream] = (until, reason)
    }

    private mutating func refill(at now: Date) {
        guard now > refilledAt else { return }
        tokens = min(configuration.capacity, tokens + now.timeIntervalSince(refilledAt) * configuration.refillPerSecond)
        refilledAt = now
    }
}

/// The pacer the streams of one container's database share (D43): one per (container, database)
/// for the process, so the engine, SpaceSync and BlobStore always meet in the same bucket.
actor SyncPacer {
    struct Key: Hashable, Sendable {
        let container: String
        let database: CloudDatabaseScope
    }

    private static let registry = PacerRegistry()

    /// The pacer of `container`'s `database`, made on first use.
    static func shared(container: String, database: CloudDatabaseScope) async -> SyncPacer {
        await registry.pacer(for: Key(container: container, database: database))
    }

    private var state: SyncPacerState
    private let clock: @Sendable () -> Date

    init(configuration: SyncPacerState.Configuration = .standard, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
        state = SyncPacerState(configuration: configuration, now: clock())
    }

    /// Waits for `stream`'s turn and returns the batch size it may send or fetch.
    func acquire(_ stream: SyncPacerState.Stream, writes: Bool) async throws -> Int {
        while true {
            try Task.checkCancellation()
            switch state.request(stream, writes: writes, at: clock()) {
            case .go(let batch):
                return batch
            case .wait(let until, _):
                let seconds = max(0.01, until.timeIntervalSince(clock()))
                try await Task.sleep(nanoseconds: UInt64(min(seconds, 60) * 1_000_000_000))
            }
        }
    }

    /// The decision without waiting, for a caller that schedules itself (the engine's batch callback).
    func request(_ stream: SyncPacerState.Stream, writes: Bool) -> SyncPacerState.Decision {
        state.request(stream, writes: writes, at: clock())
    }

    func withdraw(_ stream: SyncPacerState.Stream) { state.withdraw(stream) }
    func succeeded(_ stream: SyncPacerState.Stream) { state.succeeded(stream) }

    @discardableResult
    func refused(_ stream: SyncPacerState.Stream, with error: CloudError, owner: String? = nil) -> Date {
        state.refused(stream, with: error, owner: owner, at: clock())
    }

    func setSmallRecordBacklog(_ count: Int) { state.smallRecordBacklog = count }
    func resumeAfterQuota() { state.resumeAfterQuota() }

    func pause(of stream: SyncPacerState.Stream, writes: Bool) -> SyncPacerState.PauseReason? {
        state.pause(of: stream, writes: writes, at: clock())
    }

    func batchSize(_ stream: SyncPacerState.Stream) -> Int { state.batchSize(stream) }

    private actor PacerRegistry {
        var pacers: [Key: SyncPacer] = [:]

        func pacer(for key: Key) -> SyncPacer {
            if let pacer = pacers[key] { return pacer }
            let pacer = SyncPacer()
            pacers[key] = pacer
            return pacer
        }
    }
}
