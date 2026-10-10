import Foundation
import Testing
@testable import ForeverLM

/// The Placement projection (docs/cloudkit-schema-design.md §3.5.21, D18, WP12b): a source scheduled under
/// generation 2 is the record `pl:<wire id>` with its day, order key, goals and origin, and another Mac
/// writes it back; a placement taken off the Schedule is removed, never deleted; a source delete leaves
/// it; the activation keys generation 1's placements by their record ids, merging two that meet.
@Suite("Placement projection")
struct PlacementProjectionTests {
    typealias F = NotebookSyncFixture

    /// Noon today, local: a day whose start and end are unambiguous.
    static var today: Date { Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())! }

    @Test("A source scheduled under generation 2 is pl:<wire id> with its day, order, goals and origin, and comes back on another Mac")
    func roundTrip() throws {
        let (root, store) = try F.makeStore("pl-round")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-1")
        try F.addSource(store, "src-a")
        try F.addSource(store, "src-b")
        try store.addSourceToGoal(sourceID: "src-a", goalID: "nb-1", plannedAt: Self.today)
        try store.addSourceToGoal(sourceID: "src-b", goalID: "nb-1", plannedAt: Self.today)
        #expect(try store.scheduledSourceID(forSource: "src-a") == "pl:src-a")
        let pending = try F.pending(store)
        let first = try #require(F.savedFields(pending["Placement:pl:src-a"]))
        let second = try #require(F.savedFields(pending["Placement:pl:src-b"]))
        #expect(first["sourceID"] == .string("src-a") && first["state"] == .string("active") && first["origin"] == .string("manual"))
        #expect(first["day"] == .string(PlacementDay.day(cocoaSeconds: Self.today.timeIntervalSinceReferenceDate)))
        #expect(first["goalIDs"] == .object(["nb-1": .bool(true)]))
        #expect((first["orderKey"]?.stringValue ?? "") < (second["orderKey"]?.stringValue ?? ""), "the day's order, as the Mac keeps it")
        #expect(first["addedAt"] != nil && first["completedAt"] == nil)

        let (otherRoot, other) = try F.makeStore("pl-round-other")
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        try F.prepareReplica(other)
        try F.apply(other, try ["pl:src-a", "pl:src-b"].map { try OutboxTestProjections.serverRecord(for: try #require(pending["Placement:\($0)"])) })
        let rows = "SELECT group_concat(id || '@' || planned_at || '/' || source_id || '/' || is_automatic, ',') FROM (SELECT * FROM scheduled_sources ORDER BY id)"
        #expect(try F.text(other, rows) != nil && F.text(other, rows) == F.text(store, rows), "the same ids, day, order and origin")
        #expect(try other.scheduledSourceGoalIDs(sourceID: "src-a") == ["nb-1"])
        #expect(try F.pending(other).keys.filter { $0.hasPrefix("Placement:") }.isEmpty, "an apply sends nothing back")
    }

    @Test("A placement taken off the Schedule is removed, never deleted, and an inbound removal takes the rows")
    func removalIsAState() throws {
        let (root, store) = try F.makeStore("pl-remove")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-1")
        try F.addSource(store, "src-a")
        try store.addSourceToGoal(sourceID: "src-a", goalID: "nb-1", plannedAt: Self.today)
        try F.sendAll(store)
        try store.removeScheduledSource(sourceID: "src-a")
        let change = try #require(try F.pending(store)["Placement:pl:src-a"])
        guard case .save(let envelope) = change.action else { Issue.record("expected a save"); return }
        #expect(envelope.fields["state"] == .string("removed"))
        try F.sendAll(store)

        try store.addSourceToGoal(sourceID: "src-a", goalID: "nb-1", plannedAt: Self.today)
        #expect(F.savedFields(try F.pending(store)["Placement:pl:src-a"])?["state"] == .string("active"), "scheduled again")
        try F.sendAll(store)
        var held = try #require(try F.held(store, .placement, "pl:src-a"))
        held.fields["state"] = .string("removed")
        held.stamps["state"] = .value(SyncStamp(policy: .lastWriter, milliseconds: 4_000_000_000_000, counter: 0, deviceID: "otheraaa"))
        let record = ReplicaRecord(
            zoneKey: F.libraryZoneKey, recordName: RecordNaming.recordName(type: .placement, id: "pl:src-a", salt: F.salt),
            recordType: "Placement", wireID: "pl:src-a", systemFields: Data([2]), payload: try held.storedPayload(), seenPass: nil
        )
        try F.apply(store, [record])
        #expect(try store.scheduledSourceID(forSource: "src-a") == nil)
        #expect(try F.count(store, "SELECT COUNT(*) FROM scheduled_source_goals") == 0)
    }

    @Test("A source deleted here leaves its placement and record")
    func sourceDeleteKeepsPlacement() throws {
        let (root, store) = try F.makeStore("pl-source-delete")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-1")
        try F.addSource(store, "src-a")
        try store.addSourceToGoal(sourceID: "src-a", goalID: "nb-1", plannedAt: Self.today)
        try F.sendAll(store)
        try store.deleteSourceRows("src-a")
        #expect(try F.count(store, "SELECT COUNT(*) FROM scheduled_sources WHERE id = 'pl:src-a'") == 1)
        #expect(try F.pending(store)["Placement:pl:src-a"] == nil)
    }

    @Test("The activation keys generation 1's placements by record id on the wire id, merging two that meet, twice the same")
    func activationRekeys() throws {
        let (root, store) = try F.makeStore("pl-rekey", triggers: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try F.addSource(store, "src-a")
        try HighlightProjectionTests.addTeamCopy(store, "team-copy-a", of: "src-a")
        try F.addSource(store, "src-b")
        try store.executeScript("""
            INSERT INTO scheduled_sources (id, source_id, planned_at, added_at, created_at, updated_at) VALUES
                ('digest-a', 'src-a', 100, 10, 10, 10), ('digest-team', 'team-copy-a', 200, 20, 20, 20), ('digest-b', 'src-b', 300, 30, 30, 30);
            INSERT INTO scheduled_source_goals (scheduled_source_id, goal_id, added_at) VALUES ('digest-a', 'nb-1', 1), ('digest-team', 'nb-2', 2), ('digest-b', 'nb-1', 3);
            INSERT INTO source_activity_days (id, scheduled_source_id, source_id, day_start, first_activity_at, last_activity_at, kinds, completed_kinds)
                VALUES ('act-1', 'digest-team', 'team-copy-a', 0, 1, 1, 1, 0);
        """)
        try store.inDerivationTransaction { try $0.rekeyPersonalStateRows() }
        let rows = "SELECT group_concat(id || ':' || source_id || ':' || planned_at, ',') FROM (SELECT * FROM scheduled_sources ORDER BY id)"
        #expect(try F.text(store, rows) == "pl:src-a:src-a:100.0,pl:src-b:src-b:300.0", "the copy's meets the personal one, placed first")
        #expect(try F.text(store, "SELECT group_concat(scheduled_source_id || '/' || goal_id, ',') FROM (SELECT * FROM scheduled_source_goals ORDER BY 1, 2)")
                == "pl:src-a/nb-1,pl:src-a/nb-2,pl:src-b/nb-1", "with both's goals")
        #expect(try F.text(store, "SELECT scheduled_source_id FROM source_activity_days WHERE id = 'act-1'") == "pl:src-a")
        try store.inDerivationTransaction { try $0.rekeyPersonalStateRows() }
        #expect(try F.text(store, rows) == "pl:src-a:src-a:100.0,pl:src-b:src-b:300.0")
    }
}
