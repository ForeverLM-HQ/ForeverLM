import Foundation
import Testing
@testable import ForeverLM

/// A learning bout is the Sitting of kind `bout` (docs/cloudkit-schema-design.md §10): its notebook and
/// what it was set up with in the scope, the write-up, the break earned and when it ends, an abandoned
/// bout. The phone's bout timer writes `breakEndsAt` on a Mac-run bout (an L field).
@Suite("Learning bout Sitting")
struct LearningBoutSittingTests {
    private typealias F = MemorySyncFixture

    private static func insertBout(_ store: KnowledgeStore, id: String, startedAt: Double) throws {
        let day = F.day(startedAt)
        try store.execute("INSERT INTO day_plans (id, plan_date, created_at, updated_at) VALUES (?, ?, 1, 1) ON CONFLICT(id) DO NOTHING",
                          [.text(day), .text(day)])
        try store.execute("""
            INSERT INTO learning_bouts (id, day_plan_id, title, notebook_id, source_ids, planned_minutes, started_at, created_at, updated_at)
            VALUES (?, ?, 'Complex I', 'nb-1', '["src-1","src-2"]', 25, ?, ?, ?)
        """, [.text(id), .text(day), .real(startedAt), .real(startedAt), .real(startedAt)])
    }

    @Test("A bout goes out as a Sitting of kind bout, its write-up and break with it")
    func boutIsASitting() throws {
        let (root, store) = try F.makeStore("bout-out")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.insertBout(store, id: "bout-1", startedAt: 780_000_000)
        var fields = try #require(F.fields(try F.pending(store)["Sitting:bout-1"]))
        #expect(fields["kind"] == "bout" && fields["deviceID"] == .string(F.deviceID) && fields["part"] == 1)
        #expect(fields["startedAt"] == SyncJSON(SyncTime.milliseconds(cocoaSeconds: 780_000_000)))
        #expect(fields["scope"] == ["title": "Complex I", "plannedMinutes": 25, "notebookID": "nb-1", "sourceIDs": ["src-1", "src-2"]])
        #expect(fields["writeUp"] == nil && fields["breakEndsAt"] == nil)

        try F.sendAll(store)
        try store.execute("""
            UPDATE learning_bouts SET ended_at = ?, learned = 'It pumps protons', unclear = 'The Q cycle', written_at = ?,
                break_minutes = 5, break_started_at = ?, updated_at = ? WHERE id = 'bout-1'
        """, [.real(780_001_500), .real(780_001_560), .real(780_001_600), .real(780_001_600)])
        let change = try F.pending(store)["Sitting:bout-1"]
        fields = try #require(F.fields(change))
        #expect(fields["endedAt"] == SyncJSON(SyncTime.milliseconds(cocoaSeconds: 780_001_500)))
        #expect(fields["writeUp"]?["learned"] == "It pumps protons" && fields["writeUp"]?["unclear"] == "The Q cycle")
        #expect(fields["breakMinutes"] == 5)
        #expect(fields["breakEndsAt"] == SyncJSON(SyncTime.milliseconds(cocoaSeconds: 780_001_900)))
        #expect(F.changed(change) == ["breakEndsAt", "breakMinutes", "endedAt", "writeUp"], "S fields already sent are not sent again")

        // Only updated_at moving (opening the bout's view, a refresh) sends nothing.
        try F.sendAll(store)
        try store.execute("UPDATE learning_bouts SET updated_at = 780009999 WHERE id = 'bout-1'")
        #expect(try F.pending(store)["Sitting:bout-1"] == nil)
    }

    @Test("A bout from another device lands in its day with its break, and the phone's break end moves the break")
    func inboundBout() throws {
        let (root, store) = try F.makeStore("bout-in")
        defer { try? FileManager.default.removeItem(at: root) }
        let started = SyncTime.milliseconds(cocoaSeconds: 780_000_000)
        try F.apply(store, [try F.record(.sitting, "bout-9", [
            "deviceID": "otheraaa", "kind": "bout", "startedAt": SyncJSON(started), "part": 1,
            "scope": ["notebookID": "nb-2", "title": "Supercomplexes", "plannedMinutes": 40],
            "writeUp": ["learned": "They respire", "unclear": ""], "breakMinutes": 8,
            "breakEndsAt": SyncJSON(started + 3_000_000),
        ])])
        #expect(try F.text(store, "SELECT day_plan_id || '|' || title || '|' || notebook_id || '|' || planned_minutes || '|' || break_minutes FROM learning_bouts WHERE id = 'bout-9'")
                == "\(F.day(780_000_000))|Supercomplexes|nb-2|40|8")
        #expect(try F.text(store, "SELECT learned FROM learning_bouts WHERE id = 'bout-9'") == "They respire")
        #expect(try store.scalarText("SELECT CAST(break_started_at AS TEXT) FROM learning_bouts WHERE id = 'bout-9'").flatMap(Double.init)
                == 780_000_000 + 3_000 - 8 * 60, "the break started its minutes before it ends")
        #expect(try F.count(store, "SELECT COUNT(*) FROM day_plans WHERE id = ?", [.text(F.day(780_000_000))]) == 1)
        #expect(try F.count(store, "SELECT COUNT(*) FROM memory_sittings") == 0, "a bout keeps its row in learning_bouts")
        #expect(try F.pending(store).isEmpty, "an inbound apply writes no outbox row")
    }
}
