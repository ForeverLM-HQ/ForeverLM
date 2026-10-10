import Foundation
import Testing
@testable import ForeverLM

/// `StoreOldContainerImporter`: the removal gate's and Settings' view of late import (WP16b), over a real
/// store and the base's watermark. The facts come from the watermark and the lists a pass keeps, the
/// answer is stored where the pass reads it, and the final pass maps a pass's outcome onto the gate's.
@Suite("Store old container importer", .serialized)
struct StoreOldContainerImporterTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 812_000_000)

    private final class Rig: @unchecked Sendable {
        let root: URL
        let store: KnowledgeStore
        let local: MacPrivateSyncStore
        let base = InMemoryMigrationBase()
        var outcome: MigrationPassOutcome = .imported(MigrationPassReport(passID: "p"))
        private(set) var passes = 0

        init() throws {
            (root, store) = try NotebookSyncFixture.makeStore("old-container-importer")
            try NotebookSyncFixture.prepareReplica(store)
            local = MacPrivateSyncStore.direct(store)
        }

        func importer() -> StoreOldContainerImporter {
            StoreOldContainerImporter(store: local, base: base, runPass: { [self] in
                passes += 1
                return outcome
            })
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("The facts are the watermark's times and the lists a pass keeps, and a question that waits")
    func facts() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        var mark = MigrationImportWatermark(container: "iCloud.com.foreverlm", zones: ["Knowledge"])
        mark.lastOldWriteAt = SyncTime.milliseconds(Self.now.addingTimeInterval(-9 * 86_400))
        mark.quietSince = SyncTime.milliseconds(Self.now.addingTimeInterval(-8 * 86_400))
        mark.finishedAt = SyncTime.milliseconds(Self.now.addingTimeInterval(-86_400))
        rig.base.setWatermark(mark)
        try await rig.local.perform { state in
            try MigrationImportState.appendKept([MigrationLogEntry(oldRecord: "Knowledge/abc", type: "Card", id: "card-1", reason: .neverRemoved, at: Self.now)], state.connection)
            try MigrationImportState.appendNotApplied([MigrationLogEntry(oldRecord: "Knowledge/def", type: "Source", id: "src-1", reason: .waitedTooLong, at: Self.now)], state.connection)
            try MigrationImportState.saveWaitingSince(["Knowledge/ghi": Self.now.addingTimeInterval(-3 * 86_400)], state.connection)
        }
        let facts = try await rig.importer().facts()
        #expect(facts.lastOldZoneWriteAt == SyncTime.date(milliseconds: try #require(mark.lastOldWriteAt)))
        #expect(facts.quietSince != nil && facts.finishedAt != nil && facts.removedAt == nil)
        #expect(facts.waiting.map(\.recordName) == ["Knowledge/ghi"])
        #expect(facts.keptRemovals.count == 1 && facts.keptRemovals[0].what.contains("Card card-1"))
        #expect(facts.notApplied.count == 1 && facts.notApplied[0].what.contains("waited 30 days"))
        #expect(facts.question == nil)

        try await rig.local.perform {
            try MigrationImportState.ask(MigrationImportGuardQuestion(removing: 40, of: 100, askedAt: Self.now, answer: nil), $0.connection)
        }
        #expect(try await rig.importer().facts().question == .init(pass: .importPass, deleting: 40, of: 100))
        // The gate sees the facts as they are.
        #expect(!OldContainerRemovalGate.evaluate(facts: try await rig.importer().facts(), parity: ByteParityReport(checked: 0), now: Self.now).isOpen)
    }

    @Test("Apply and Keep are stored on the question for the pass that asked, and the question stops being asked")
    func answers() async throws {
        for (answer, stored) in [(ImportQuestionAnswer.apply, MigrationImportGuardQuestion.Answer.apply), (.keep, .keep)] {
            let rig = try Rig()
            defer { rig.cleanUp() }
            rig.base.setWatermark(MigrationImportWatermark(zones: ["Knowledge"]))
            try await rig.local.perform {
                try MigrationImportState.ask(MigrationImportGuardQuestion(removing: 9, of: 10, askedAt: Self.now, answer: nil), $0.connection)
            }
            let importer = rig.importer()
            let question = try #require(try await importer.facts().question)
            try await importer.answer(question, answer)
            let kept = try await rig.local.perform { try MigrationImportState.guardQuestion($0.connection) }
            #expect(kept?.answer == stored)
            #expect(try await importer.facts().question == nil, "an answered question asks no more")
        }
    }

    @Test("The final pass: a quiet pass is quiet, one that imported writes is found, a question and a blocked pass are told apart")
    func finalPass() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let importer = rig.importer()
        #expect(try await importer.runFinalPass() == .quiet)

        var report = MigrationPassReport(passID: "p")
        report.changed = 2
        report.deleted = 1
        rig.outcome = .imported(report)
        #expect(try await importer.runFinalPass() == .foundWrites(count: 3))

        var sawOnly = MigrationPassReport(passID: "p")
        sawOnly.sawOldWrite = true
        rig.outcome = .imported(sawOnly)
        #expect(try await importer.runFinalPass() == .foundWrites(count: 1))

        rig.outcome = .guardTripped(MigrationImportGuardQuestion(removing: 9, of: 10, askedAt: Self.now))
        #expect(try await importer.runFinalPass() == .asksQuestion)
        rig.outcome = .waitingForQuestion
        #expect(try await importer.runFinalPass() == .asksQuestion)

        for blocked in [MigrationPassOutcome.notReady, .accountChanged, .waitingForAcknowledgement] {
            rig.outcome = blocked
            await #expect(throws: StoreOldContainerImporter.Unavailable.self) { _ = try await importer.runFinalPass() }
        }
        #expect(rig.passes == 8)
    }

    @Test("Restarting the wait clears finishedAt and starts the quiet stretch again; a removal is recorded")
    func watermarkWrites() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        var mark = MigrationImportWatermark(container: "iCloud.com.foreverlm", zones: ["Knowledge"], tokens: ["Knowledge": "dG9rZW4="])
        mark.quietSince = SyncTime.milliseconds(Self.now.addingTimeInterval(-8 * 86_400))
        mark.finishedAt = SyncTime.milliseconds(Self.now.addingTimeInterval(-86_400))
        rig.base.setWatermark(mark)
        let importer = rig.importer()

        try await importer.restartQuietWait(at: Self.now)
        let restarted = try #require(rig.base.current)
        #expect(restarted.finishedAt == nil)
        #expect(restarted.quietSince == SyncTime.milliseconds(Self.now))
        #expect(restarted.tokens == mark.tokens && restarted.zones == mark.zones, "the tokens and zones stay")
        #expect(restarted.pollInterval == MigrationImportWatermark.hour, "hourly polling again")

        try await importer.recordRemoval(at: Self.now)
        #expect(try #require(rig.base.current).removedAt == SyncTime.milliseconds(Self.now))
        #expect(try await importer.facts().removedAt != nil)
        #expect(rig.base.advances == 2)
    }

    @Test("A root with no base yet cannot be written, and says so")
    func noBase() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        await #expect(throws: StoreOldContainerImporter.Unavailable.self) { try await rig.importer().recordRemoval(at: Self.now) }
        rig.base.setWatermark(MigrationImportWatermark(zones: ["Knowledge"]))
        rig.base.losesNextAdvance = true
        await #expect(throws: StoreOldContainerImporter.Unavailable.self) { try await rig.importer().restartQuietWait(at: Self.now) }
        #expect(try await rig.importer().facts().lastOldZoneWriteAt == nil)
    }
}
