import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// Two Macs of one account claiming one Job on FakeCloudKit (docs/cloudkit-schema-design.md §3.5.28, D8,
/// WP14): `claim` is first-writer, so the claim the server accepts first wins and the other Mac's save
/// merges into it; a Mac starts a Job only once the server holds its claim; a lease that ran out is
/// taken over with a compare-and-set save, and the Mac that lost it never starts.
@Suite("Job claims", .serialized)
struct JobClaimTests {
    private typealias Device = EngineTestDevice
    private typealias J = JobSyncFixture

    private static func pair() async throws -> (Device, Device) {
        let server = EngineTestDriver.server()
        let a = try Device(server, name: "jobs-a", deviceID: "macaaaaa", registry: KnowledgeStore.projectionRegistry)
        try await a.bootstrap()
        let b = try Device(server, name: "jobs-b", deviceID: "macbbbbb", registry: KnowledgeStore.projectionRegistry)
        try await b.bootstrap(.macWithoutLibrary)
        return (a, b)
    }

    /// A report the web asked for (`Job(makeDerived)` running MCP `generate_report`), written to the server
    /// and fetched by both Macs.
    private static func requestReport(_ a: Device, _ b: Device) async throws -> String {
        let requested = Date().timeIntervalSinceReferenceDate
        let job = JobRow(
            id: "job-report", kind: "makeDerived", target: "nb:nb-1",
            params: ["tool": .string("generate_report"), "arguments": .object(["notebook_id": .string("nb-1")])],
            requestedBy: ["device": .string("webaaaaa"), "platform": .string("web")], requestedAt: requested,
            expiresAt: requested + MacJobRequests.lifetime
        )
        try job.save(a.store)
        await EngineTestDriver.pause()
        try await a.sync()
        try await b.sync()
        #expect(try b.text("SELECT status FROM jobs WHERE id = 'job-report'") == "queued")
        return job.id
    }

    private static func claimant(_ device: Device, _ id: String) throws -> String? {
        try device.serverEnvelope(.job, id)?.fields["claim"]?["device"]?.stringValue
    }

    @Test("Two Macs claim one Job: the second claim loses, its Mac never starts, and both converge on the winner's outcome")
    func secondClaimLoses() async throws {
        let (a, b) = try await Self.pair()
        let id = try await Self.requestReport(a, b)
        let workA = FakeJobWork(store: a.store)
        let workB = FakeJobWork(store: b.store)
        let runnerA = J.runner(a.store, work: workA)
        let runnerB = J.runner(b.store, work: workB)

        #expect(await runnerA.pass() == [.claim(id)])
        #expect(await runnerB.pass() == [.claim(id)])
        // Neither starts before the server took its claim.
        #expect(await runnerA.pass().isEmpty && workA.recorded.isEmpty)
        await EngineTestDriver.pause()
        try await a.send()
        try await b.send()
        #expect(try Self.claimant(a, id) == "macaaaaa", "the first acknowledged claim stands")
        #expect(try b.text("SELECT json_extract(claim_json, '$.device') FROM jobs WHERE id = ?", [.text(id)]) == "macaaaaa",
                "the losing Mac's row holds the winner's claim")

        #expect(await runnerB.pass().isEmpty, "the second claim never starts")
        #expect(await runnerA.pass() == [.start(id)])
        #expect(try await J.settled(a.store, id) == "done")
        await EngineTestDriver.pause()
        try await a.sync()
        try await b.sync()
        #expect(await runnerB.pass().isEmpty)
        #expect(workA.recorded == ["callTool generate_report"])
        #expect(workB.recorded.isEmpty)
        #expect(try b.text("SELECT status FROM jobs WHERE id = ?", [.text(id)]) == "done")
        #expect(try a.outboxRows() == 0 && b.outboxRows() == 0)
    }

    @Test("A lease that ran out is taken over by a compare-and-set claim, and the Mac that held it never starts")
    func expiredLeaseIsTakenOver() async throws {
        let (a, b) = try await Self.pair()
        let id = try await Self.requestReport(a, b)
        let workA = FakeJobWork(store: a.store)
        let workB = FakeJobWork(store: b.store)
        let runnerA = J.runner(a.store, work: workA)
        #expect(await runnerA.pass() == [.claim(id)])
        await EngineTestDriver.pause()
        try await a.sync()
        try await b.sync()
        // A's claim is the server's; A went away before it started, so no lease was ever renewed.
        #expect(try Self.claimant(b, id) == "macaaaaa")
        let runnerB = J.runner(b.store, work: workB)
        #expect(await runnerB.pass().isEmpty, "a lease that has not run out is left alone")

        let later = J.runner(b.store, work: workB, now: { Date().addingTimeInterval(MacJobRunner.lease + 60) })
        #expect(await later.pass() == [.claim(id)])
        await EngineTestDriver.pause()
        try await b.send()
        #expect(try Self.claimant(b, id) == "macbbbbb", "the takeover's save names A's claim as its base, so it wins")
        #expect(await later.pass() == [.start(id)])
        #expect(try await J.settled(b.store, id) == "done")

        await EngineTestDriver.pause()
        try await b.sync()
        try await a.sync()
        #expect(await runnerA.pass().isEmpty, "the Mac whose lease ran out never starts")
        #expect(workA.recorded.isEmpty && workB.recorded == ["callTool generate_report"])
        #expect(try a.text("SELECT status || ':' || json_extract(claim_json, '$.device') FROM jobs WHERE id = ?", [.text(id)]) == "done:macbbbbb")
    }
}
