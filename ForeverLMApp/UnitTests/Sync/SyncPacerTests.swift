import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// The one pacer per container and database (docs/cloudkit-schema-design.md §2.3, D43).
@Suite("Sync pacer")
struct SyncPacerTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 812_000_000)
    private typealias State = SyncPacerState

    private static func state(capacity: Double = 3, refill: Double = 1) -> State {
        var configuration = State.Configuration()
        configuration.capacity = capacity
        configuration.refillPerSecond = refill
        return State(configuration: configuration, now: start)
    }

    private static func isGo(_ decision: State.Decision) -> Bool {
        if case .go = decision { return true }
        return false
    }

    @Test("One bucket across the three streams: what the engine takes, BlobStore and SpaceSync cannot")
    func oneBucket() {
        var pacer = Self.state(capacity: 3, refill: 1)
        #expect(Self.isGo(pacer.request(.engine, writes: true, at: Self.start)))
        #expect(Self.isGo(pacer.request(.spaces, writes: true, at: Self.start)))
        #expect(Self.isGo(pacer.request(.blobs, writes: true, at: Self.start)))
        #expect(!Self.isGo(pacer.request(.blobs, writes: true, at: Self.start)), "three tokens, three requests, whatever stream asked")
        #expect(!Self.isGo(pacer.request(.engine, writes: true, at: Self.start)))
        // One second later one token is back, and it goes to the engine first (it is waiting).
        let later = Self.start.addingTimeInterval(1)
        #expect(!Self.isGo(pacer.request(.blobs, writes: true, at: later)), "BlobStore yields while a small-record stream waits")
        #expect(Self.isGo(pacer.request(.engine, writes: true, at: later)))
    }

    @Test("Strict priority: BlobStore waits while the small-record backlog is 200 or more, and SpaceSync after the engine")
    func strictPriority() {
        var pacer = Self.state(capacity: 100, refill: 10)
        pacer.smallRecordBacklog = 200
        #expect(pacer.request(.blobs, writes: true, at: Self.start) == .wait(until: Self.start.addingTimeInterval(0.1), reason: .smallRecordsFirst))
        #expect(pacer.pause(of: .blobs, writes: true, at: Self.start) == .smallRecordsFirst)
        pacer.smallRecordBacklog = 199
        pacer.withdraw(.blobs)
        #expect(Self.isGo(pacer.request(.blobs, writes: true, at: Self.start)))

        var empty = Self.state(capacity: 1, refill: 1)
        #expect(Self.isGo(empty.request(.spaces, writes: false, at: Self.start)))
        #expect(!Self.isGo(empty.request(.engine, writes: true, at: Self.start)))
        let later = Self.start.addingTimeInterval(1)
        #expect(!Self.isGo(empty.request(.spaces, writes: false, at: later)), "the engine waited first")
        #expect(Self.isGo(empty.request(.engine, writes: true, at: later)))
    }

    @Test("Any retryAfter pauses BlobStore for the interval and halves every stream's batch; an account throttle holds every stream")
    func retryAfter() {
        var pacer = Self.state(capacity: 100, refill: 10)
        #expect(pacer.batchSize(.engine) == 200 && pacer.batchSize(.blobs) == 20)
        let resume = pacer.refused(.engine, with: CloudError(.zoneBusy, retryAfter: 30), at: Self.start)
        #expect(resume == Self.start.addingTimeInterval(30))
        #expect(pacer.batchSize(.engine) == 100 && pacer.batchSize(.spaces) == 100 && pacer.batchSize(.blobs) == 10)
        #expect(pacer.request(.blobs, writes: true, at: Self.start.addingTimeInterval(5)) == .wait(until: resume, reason: .retryAfter))
        #expect(Self.isGo(pacer.request(.spaces, writes: true, at: Self.start.addingTimeInterval(5))), "a busy zone holds only the stream that met it")
        #expect(Self.isGo(pacer.request(.blobs, writes: true, at: resume)))

        var throttled = Self.state(capacity: 100, refill: 10)
        throttled.refused(.blobs, with: CloudError(.requestRateLimited, retryAfter: 12), at: Self.start)
        for stream in State.Stream.allCases {
            #expect(throttled.request(stream, writes: false, at: Self.start.addingTimeInterval(1)) == .wait(until: Self.start.addingTimeInterval(12), reason: .retryAfter))
        }
        #expect(Self.isGo(throttled.request(.engine, writes: true, at: Self.start.addingTimeInterval(12.2))))
    }

    @Test("AIMD: each success adds 10 up to the maximum, each throttle halves, never below one")
    func aimd() {
        var pacer = Self.state(capacity: 1_000, refill: 100)
        for _ in 0..<10 { pacer.refused(.engine, with: CloudError(.zoneBusy, retryAfter: 0.001), at: Self.start) }
        #expect(pacer.batchSize(.engine) == 1)
        pacer.succeeded(.engine)
        #expect(pacer.batchSize(.engine) == 11)
        for _ in 0..<30 { pacer.succeeded(.engine) }
        #expect(pacer.batchSize(.engine) == 200)
        pacer.refused(.spaces, with: CloudError(.serviceUnavailable, retryAfter: 1), at: Self.start)
        #expect(pacer.batchSize(.engine) == 100)
    }

    @Test("20 refusals in a row pause every stream; a success between them starts the count again")
    func refusalsPause() {
        var pacer = Self.state(capacity: 1_000, refill: 100)
        for _ in 0..<19 { pacer.refused(.engine, with: CloudError(.networkFailure), at: Self.start) }
        #expect(pacer.consecutiveRefusals == 19)
        pacer.succeeded(.engine)
        #expect(pacer.consecutiveRefusals == 0)
        for _ in 0..<19 { pacer.refused(.engine, with: CloudError(.networkFailure), at: Self.start) }
        #expect(Self.isGo(pacer.request(.spaces, writes: true, at: Self.start)))
        let resume = pacer.refused(.engine, with: CloudError(.networkFailure), at: Self.start)
        #expect(resume == Self.start.addingTimeInterval(600))
        for stream in State.Stream.allCases {
            #expect(pacer.request(stream, writes: false, at: Self.start.addingTimeInterval(60)) == .wait(until: resume, reason: .repeatedRefusals))
        }
    }

    @Test("A full iCloud stops every write and names whose storage it is, while reads go on")
    func quota() {
        var pacer = Self.state(capacity: 100, refill: 10)
        pacer.refused(.spaces, with: CloudError(.quotaExceeded), owner: "_owner", at: Self.start)
        let soon = Self.start.addingTimeInterval(5)
        #expect(pacer.request(.engine, writes: true, at: soon) == .wait(until: Self.start.addingTimeInterval(3_600), reason: .quotaExceeded(owner: "_owner")))
        #expect(pacer.pause(of: .blobs, writes: true, at: soon) == .quotaExceeded(owner: "_owner"))
        #expect(Self.isGo(pacer.request(.engine, writes: false, at: soon)), "the library still arrives")
        pacer.resumeAfterQuota()
        #expect(Self.isGo(pacer.request(.engine, writes: true, at: soon)))
    }

    @Test("The streams of one container's database share one pacer; another database has its own")
    func sharedPerDatabase() async {
        let container = "iCloud.test.\(UUID().uuidString)"
        let engine = await SyncPacer.shared(container: container, database: .private)
        let blobs = await SyncPacer.shared(container: container, database: .private)
        let spaces = await SyncPacer.shared(container: container, database: .shared)
        #expect(engine === blobs)
        #expect(engine !== spaces)
    }

    @Test("A caller sleeps until its turn")
    func acquireWaits() async throws {
        var configuration = State.Configuration()
        configuration.capacity = 1
        configuration.refillPerSecond = 20
        let pacer = SyncPacer(configuration: configuration)
        let began = Date()
        #expect(try await pacer.acquire(.engine, writes: true) == 200)
        _ = try await pacer.acquire(.engine, writes: true)
        #expect(Date().timeIntervalSince(began) >= 0.04, "the second token is 50 ms away")
    }
}
