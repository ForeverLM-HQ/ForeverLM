import Foundation
import Testing
@testable import ForeverLM

/// The Practice record and the rule engine (docs/cloudkit-schema-design.md §3.5.25, §8c): a rule's
/// proposal has one deterministic id per rule, scope and period, so two Macs never propose it twice; the
/// minimum sample holds; a decision is never overwritten; and the engine ships dark.
@Suite("Practice identity")
struct PracticeIdentityTests {
    private typealias F = MemorySyncFixture

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// A week of answers: 30 to walkthrough cards, mostly missed, and 30 to guide cards, mostly right.
    private static func snapshot(walkMisses: Int = 20) -> PracticeEngine.Snapshot {
        let now = Date(timeIntervalSince1970: 1_759_500_000)
        var snapshot = PracticeEngine.Snapshot()
        for index in 0..<30 {
            let at = now.addingTimeInterval(-Double(index) * 3_600 - 600)
            snapshot.answers.append(.init(cardID: "walk-\(index % 10)", at: at, rating: index < walkMisses ? .again : .good))
            snapshot.answers.append(.init(cardID: "guide-\(index % 10)", at: at, rating: index < 3 ? .again : .good))
        }
        for index in 0..<10 {
            snapshot.cardOrigins["walk-\(index)"] = "walkthrough"
            snapshot.cardOrigins["guide-\(index)"] = "guide"
        }
        return snapshot
    }

    private static let now = Date(timeIntervalSince1970: 1_759_500_000)

    @Test("A proposal's id is pr:<rule>:<scope>:<period>, and two devices derive the same records")
    func deterministic() throws {
        let first = PracticeEngine.evaluate(Self.snapshot(), now: Self.now, calendar: Self.calendar)
        let second = PracticeEngine.evaluate(Self.snapshot(), now: Self.now, calendar: Self.calendar)
        #expect(first == second)
        let retention = try #require(first.first { $0.ruleID == "retention-by-origin" })
        #expect(retention.id == "pr:retention-by-origin:all:\(PracticeEngine.week(of: Self.now, calendar: Self.calendar))")
        #expect(retention.id == SyncIdentity.practiceID(ruleID: "retention-by-origin", scope: "all", period: retention.period ?? ""))
        #expect(retention.period?.range(of: #"^\d{4}-W\d{2}$"#, options: .regularExpression) != nil)
        #expect(retention.origin == "rule" && retention.status == "proposed" && retention.minSampleMet == true)
        #expect(retention.rule?["kind"] == "draftSeeds" && retention.rule?["params"]?["origin"] == "walkthrough")
        #expect(retention.evidence?.arrayValue?.first?["n"] == 30)
    }

    @Test("Below a rule's minimum sample nothing is proposed")
    func minimumSample() {
        var small = Self.snapshot()
        small.answers = Array(small.answers.prefix(30))   // 15 answers of each origin
        #expect(PracticeEngine.evaluate(small, now: Self.now, calendar: Self.calendar).allSatisfy { $0.ruleID != "retention-by-origin" })
        // Enough answers but no real difference: nothing either.
        #expect(PracticeEngine.evaluate(Self.snapshot(walkMisses: 4), now: Self.now, calendar: Self.calendar).allSatisfy { $0.ruleID != "retention-by-origin" })
    }

    @Test("A proposal never overwrites a decision, and the record round-trips")
    func decisionsStand() throws {
        let (root, store) = try F.makeStore("practice")
        defer { try? FileManager.default.removeItem(at: root) }
        let proposal = try #require(PracticeEngine.evaluate(Self.snapshot(), now: Self.now, calendar: Self.calendar).first)
        #expect(try store.proposePractice(proposal))
        let fields = try #require(F.fields(try F.pending(store)["Practice:\(proposal.id)"]))
        #expect(fields["status"] == "proposed" && fields["origin"] == "rule" && fields["title"] == .string(proposal.title))
        try F.sendAll(store)

        var dismissed = proposal
        dismissed.status = "dismissed"
        dismissed.decidedAt = 780_000_000
        try store.savePractice(dismissed)
        #expect(try store.proposePractice(proposal) == false, "the next run, here or on another Mac, leaves the decision")
        #expect(try store.loadPractice(id: proposal.id)?.status == "dismissed")
        let decided = try #require(try F.pending(store)["Practice:\(proposal.id)"])
        #expect(F.changed(decided) == ["decidedAt", "status"] && F.fields(decided)?["status"] == "dismissed")

        // Another device adopts it: the record lands as it is.
        try F.apply(store, [try F.record(.practice, proposal.id, ["status": "adopted", "decidedAt": 1_759_600_000_000])])
        #expect(try store.loadPractice(id: proposal.id)?.status == "adopted")
        #expect(try store.loadPractice(id: proposal.id)?.title == proposal.title)
    }

    @Test("The engine ships dark, and practices need generation 2")
    func darkAndGeneration2() throws {
        #expect(PracticeEngine.isEnabled == false)
        let (root, store) = try F.makeStore("practice-dark")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try store.runPracticeEngine(now: Self.now, newCardsPerDay: 10).isEmpty)
        #expect(try F.count(store, "SELECT COUNT(*) FROM practices") == 0)

        let generation1Root = try Schema154Fixture.temporaryRoot("practice-g1")
        defer { try? FileManager.default.removeItem(at: generation1Root) }
        let generation1 = try KnowledgeStore(storeDirectory: generation1Root, syncGeneration: .one, freeSpace: Schema154Fixture.roomy)
        #expect(throws: PracticeError.generation1) { _ = try generation1.loadPractices() }
    }
}
