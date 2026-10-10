import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// The Schedule on the phone (docs/cloudkit-schema-design.md §3.5.21, §3.5.24, §10;
/// §14.2 WP20c): one Placement per source written as the web writes it and read in the shape the Mac's
/// `PlacementProjection` reads, completion as the placement's and the source's, activity days folded from
/// every device's ActivityLog.
@Suite("iPhone Schedule records", .serialized)
struct MobileScheduleRecordTests {
    typealias Fixture = MobileWriterFixture

    static let monday = Date(timeIntervalSince1970: 1_799_000_000)
    static var wednesday: Date { monday.addingTimeInterval(2 * 86_400) }

    static func library() async throws -> MobileReplica {
        let replica = try await Fixture.replica()
        try await Fixture.apply(replica, [
            (Fixture.library, try MobileReadModelFixture.notebook("nb1", "Cells", edited: 1)),
            (Fixture.library, try MobileReadModelFixture.notebook("nb2", "Old", edited: 1, ["status": .string("archived")])),
            (Fixture.catalog, try MobileReadModelFixture.source("srcA", "Membranes", added: 1)),
            (Fixture.catalog, try MobileReadModelFixture.source("srcB", "Fission", added: 2)),
            (Fixture.catalog, try MobileReadModelFixture.source("srcC", "Cristae", added: 3)),
        ])
        return replica
    }

    static func snapshot(_ replica: MobileReplica) async throws -> MobileReadModels.Snapshot {
        try await replica.read { try MobileReadModels.snapshot(in: $0) }
    }

    static func source(_ id: String) -> MobileCloudSource {
        MobileCloudSource(id: id, title: id, subtitle: nil, sourceType: "paper", dateAdded: monday, hasAudio: false, isArchived: false)
    }

    static func log(_ day: String, device: String, _ sources: [String: SyncJSON]) throws -> SyncEnvelope {
        try MobileSyncFixture.envelope(.activityLog, "al:\(day):\(device)", ["day": .string(day), "deviceID": .string(device), "sources": .object(sources)])
    }

    @Test("Deleting a notebook takes its tag off the Schedule: a placement tagged with nothing else stays as the source's activity, or is released")
    func deletedNotebookLeavesTheSchedule() async throws {
        let replica = try await Self.library()
        let writer = Fixture.writer(replica, at: Self.monday)
        try await writer.transaction { write in
            try write.schedule("srcA", on: Self.wednesday, order: 0, goalID: "nb1")
            try write.schedule("srcB", on: Self.wednesday, order: 1, goalID: "nb1")
            try write.schedule("srcB", on: Self.wednesday, order: 1, goalID: "nb2")
            try write.schedule("srcC", on: Self.wednesday, order: 2, goalID: "nb2")
        }
        try await writer.transaction { try $0.deleteNotebook("nb1", deleteLinkedChats: false) }

        let a = try #require(try await Fixture.held(replica, .placement, "pl:srcA", in: Fixture.library))
        #expect(a.fields["goalIDs"] == .object(["nb1": .bool(false)]), "its only tag went")
        #expect(a.fields["state"] == .string("removed"), "with no activity to keep it, the placement is released")
        let b = try #require(try await Fixture.held(replica, .placement, "pl:srcB", in: Fixture.library))
        #expect(b.fields["goalIDs"] == .object(["nb1": .bool(false), "nb2": .bool(true)]), "the other tag stays")
        #expect(b.fields["state"] == .string("active"))
        let c = try #require(try await Fixture.held(replica, .placement, "pl:srcC", in: Fixture.library))
        #expect(c.fields["goalIDs"] == .object(["nb2": .bool(true)]), "a placement that never named it is untouched")

        let snapshot = try await Self.snapshot(replica)
        #expect(snapshot.placements.map(\.sourceID).sorted() == ["srcB", "srcC"], "the Schedule no longer lists the notebook's tag")
        #expect(snapshot.placements.first { $0.sourceID == "srcB" }?.goalIDs == ["nb2"])
    }

    @Test("Scheduling writes one Placement per source on its day and order, tagged with the notebook; the Schedule reads it back")
    func schedule() async throws {
        let replica = try await Self.library()
        let writer = Fixture.writer(replica, at: Self.monday)
        try await writer.transaction { try $0.schedule("srcA", on: Self.wednesday, order: 3, goalID: "nb1") }
        let placement = try #require(try await Fixture.held(replica, .placement, "pl:srcA", in: Fixture.library))
        #expect(placement.fields["sourceID"] == .string("srcA"))
        #expect(placement.fields["state"] == .string("active"))
        #expect(placement.fields["day"] == .string(MemoryReviewGoal.dayKey(for: Self.wednesday)))
        #expect(placement.fields["orderKey"] == .string(try #require(MobilePlacementDay.orderKey(3))))
        #expect(placement.fields["origin"] == .string("goal"))
        #expect(placement.fields["goalIDs"] == .object(["nb1": .bool(true)]))
        let added = try #require(placement.fields["addedAt"])
        #expect(placement.fields["editedAt"] != nil)

        let row = try #require(try await Self.snapshot(replica).placements.first)
        #expect(row.id == "pl:srcA")
        #expect(row.plannedAt == Calendar.current.startOfDay(for: Self.wednesday).addingTimeInterval(3), "the day plus order")
        #expect(row.goalIDs == ["nb1"])
        #expect(!row.isAutomatic)
        let snapshot = try await Self.snapshot(replica)
        let items = MobileCloudSourceCatalog.scheduleItems(placements: snapshot.placements, sources: snapshot.sources,
                                                           collections: snapshot.collections, goals: snapshot.scheduleGoals)
        #expect(items.map(\.source.id) == ["srcA"])
        #expect(items.first?.goalTitles == ["Cells"])

        // Planned again: the one record moves, keeps its tag and when it was added.
        try await writer.transaction { try $0.schedule("srcA", on: Self.monday, order: 0, goalID: nil) }
        let moved = try #require(try await Fixture.held(replica, .placement, "pl:srcA", in: Fixture.library))
        #expect(moved.fields["day"] == .string(MemoryReviewGoal.dayKey(for: Self.monday)))
        #expect(moved.fields["origin"] == .string("manual"))
        #expect(moved.fields["goalIDs"] == .object(["nb1": .bool(true)]))
        #expect(moved.fields["addedAt"] == added)
        #expect(try await Fixture.patched(replica) == ["private/Library Placement pl:srcA"])

        // A placement serving only an archived notebook is not shown until it is done.
        try await writer.transaction { try $0.schedule("srcB", on: Self.monday, order: 1, goalID: "nb2") }
        let shown = try await Self.snapshot(replica)
        #expect(MobileCloudSourceCatalog.scheduleItems(placements: shown.placements, sources: shown.sources, collections: shown.collections,
                                                       goals: shown.scheduleGoals).map(\.source.id) == ["srcA"])
    }

    @Test("Completing marks the placement done and the source completed and read once; reopening clears both completions")
    func completeAndReopen() async throws {
        let replica = try await Self.library()
        let writer = Fixture.writer(replica, at: Self.monday)
        try await writer.transaction { try $0.schedule("srcA", on: Self.monday, order: 0, goalID: "nb1") }
        try await writer.transaction { try $0.completePlacement("srcA", at: Self.monday) }
        let done = SyncJSON(SyncTime.milliseconds(Self.monday))
        #expect(try await Fixture.held(replica, .placement, "pl:srcA", in: Fixture.library)?.fields["completedAt"] == done)
        let reading = try #require(try await Fixture.held(replica, .readingState, "rs:srcA", in: Fixture.library))
        #expect(reading.fields["completedAt"] == done, "a notebook item's completion is the source's (§10)")
        #expect(reading.fields["readAt"] == done)
        #expect(try await Self.snapshot(replica).placements.first?.completedAt == Self.monday)

        // Done again later changes nothing: the first completion stands.
        let later = Fixture.writer(replica, at: Self.wednesday)
        try await later.transaction { try $0.completePlacement("srcA", at: Self.wednesday) }
        #expect(try await Fixture.held(replica, .placement, "pl:srcA", in: Fixture.library)?.fields["completedAt"] == done)

        try await later.transaction { try $0.reopenPlacement("srcA") }
        #expect(try await Fixture.held(replica, .placement, "pl:srcA", in: Fixture.library)?.fields["completedAt"] == .null)
        let reopened = try #require(try await Fixture.held(replica, .readingState, "rs:srcA", in: Fixture.library))
        #expect(reopened.fields["completedAt"] == .null)
        #expect(reopened.fields["readAt"] == done, "it was still read")

        // A source not on the Schedule is left alone.
        try await later.transaction { try $0.completePlacement("srcC", at: Self.wednesday) }
        #expect(try await Fixture.held(replica, .placement, "pl:srcC", in: Fixture.library) == nil)
        #expect(try await Fixture.held(replica, .readingState, "rs:srcC", in: Fixture.library) == nil)
    }

    @Test("A placement whose last tag goes stays as the automatic entry on its latest activity day, else its state flips to removed")
    func release() async throws {
        let replica = try await Self.library()
        try await Fixture.apply(replica, [
            (Fixture.library, try Self.log("2026-12-20", device: "macaaaaa", ["srcA": .object(["kinds": .array(["read"]), "firstAt": 1, "lastAt": 2])])),
            (Fixture.library, try Self.log("2026-12-28", device: "phonebbb", ["srcA": .object(["kinds": .array(["listen"]), "firstAt": 3, "lastAt": 4])])),
        ])
        let writer = Fixture.writer(replica, at: Self.monday)
        try await writer.transaction { write in
            try write.schedule("srcA", on: Self.wednesday, order: 0, goalID: "nb1")
            try write.schedule("srcB", on: Self.wednesday, order: 1, goalID: "nb1")
            try write.schedule("srcB", on: Self.wednesday, order: 1, goalID: "nb2")
        }
        #expect(try await writer.read { try $0.latestActivityDay("srcA") } == "2026-12-28")

        try await writer.transaction { try $0.releasePlacement("srcB", goalIDs: ["nb1"]) }
        let untagged = try #require(try await Fixture.held(replica, .placement, "pl:srcB", in: Fixture.library))
        #expect(untagged.fields["goalIDs"] == .object(["nb1": .bool(false), "nb2": .bool(true)]))
        #expect(untagged.fields["state"] == .string("active"), "another tag keeps it")

        try await writer.transaction { try $0.releasePlacement("srcA", goalIDs: ["nb1"]) }
        let kept = try #require(try await Fixture.held(replica, .placement, "pl:srcA", in: Fixture.library))
        #expect(kept.fields["state"] == .string("active"))
        #expect(kept.fields["origin"] == .string("automatic"))
        #expect(kept.fields["day"] == .string("2026-12-28"))

        try await writer.transaction { try $0.releasePlacement("srcB", goalIDs: nil) }
        #expect(try await Fixture.held(replica, .placement, "pl:srcB", in: Fixture.library)?.fields["state"] == .string("removed"),
                "no activity: off the Schedule, never deleted")
        #expect(try await Self.snapshot(replica).placements.map(\.sourceID) == ["srcA"])
    }

    @Test("Activity days fold every device's log of the day: kinds unioned, the deepest point, seconds added")
    func activityDays() async throws {
        let replica = try await Self.library()
        try await Fixture.apply(replica, [
            (Fixture.library, try Self.log("2026-12-28", device: "macaaaaa", ["srcA": .object([
                "kinds": .array(["read"]), "completedKinds": .array([]), "maxFraction": 0.4, "engagedSeconds": 120, "firstAt": 1_000, "lastAt": 2_000,
            ])])),
            (Fixture.library, try Self.log("2026-12-28", device: "phonebbb", ["srcA": .object([
                "kinds": .array(["listen"]), "completedKinds": .array(["listen"]), "maxFraction": 0.9, "engagedSeconds": 60, "firstAt": 500, "lastAt": 1_500,
            ])])),
            (Fixture.library, try Self.log("2026-12-29", device: "phonebbb", ["srcB": .object(["kinds": .array(["review"]), "firstAt": 9, "lastAt": 9])])),
        ])
        let days = try await replica.read { try MobileReadModels.activityDays(in: $0.connection) }
        let day = try #require(days["srcA"]?.first)
        #expect(days["srcA"]?.count == 1)
        #expect(day.kinds == [.reading, .listening])
        #expect(day.completedKinds == [.listening])
        #expect(day.maxFraction == 0.9)
        #expect(day.engagedSeconds == 180)
        #expect(day.firstActivityAt == Date(timeIntervalSince1970: 0.5))
        #expect(day.lastActivityAt == Date(timeIntervalSince1970: 2))
        #expect(day.dayStart == MobilePlacementDay.start(of: "2026-12-28"))
        #expect(days["srcB"]?.first?.kinds == [.review])

        try await Fixture.writer(replica).transaction { try $0.schedule("srcA", on: Self.monday, order: 0, goalID: nil) }
        #expect(try await Self.snapshot(replica).placements.first?.activityDays == [day])
    }

    @Test("Logged activity puts a source on the Schedule as an automatic placement that follows its day; a deliberate one stays; a finished one is done")
    func activityAndConsumption() async throws {
        let replica = try await Self.library()
        let writer = Fixture.writer(replica, at: Self.monday)
        let service = MobileCloudMutationService(writer: { writer })
        let source = Self.source("srcC")

        // Under 30 s of use nothing is written (P9).
        _ = try await service.recordSourceActivity(source: source, existingPlacement: nil, startedAt: Self.monday, order: 2, kind: .reading,
                                                   fraction: 0.1, engagedSeconds: 10)
        #expect(try await Fixture.held(replica, .placement, "pl:srcC", in: Fixture.library) == nil)
        let placed = try await service.recordSourceActivity(source: source, existingPlacement: nil, startedAt: Self.monday, order: 2, kind: .reading,
                                                            fraction: 0.2, engagedSeconds: 25)
        #expect(placed.id == "pl:srcC")
        #expect(placed.isAutomatic)
        let automatic = try #require(try await Fixture.held(replica, .placement, "pl:srcC", in: Fixture.library))
        #expect(automatic.fields["origin"] == .string("automatic"))
        #expect(automatic.fields["day"] == .string(MemoryReviewGoal.dayKey(for: Self.monday)))

        // It follows the learner to the next day of activity.
        _ = try await service.recordSourceActivity(source: source, existingPlacement: placed, startedAt: Self.wednesday, order: 0, kind: .listening,
                                                   engagedSeconds: 40)
        #expect(try await Fixture.held(replica, .placement, "pl:srcC", in: Fixture.library)?.fields["day"] == .string(MemoryReviewGoal.dayKey(for: Self.wednesday)))

        // A deliberate placement keeps its day.
        try await service.schedule(source: source, on: Self.monday, notebookID: "nb1", existing: placed, order: 5)
        _ = try await service.recordSourceActivity(source: source, existingPlacement: placed, startedAt: Self.wednesday, order: 0, kind: .reading,
                                                   engagedSeconds: 40)
        #expect(try await Fixture.held(replica, .placement, "pl:srcC", in: Fixture.library)?.fields["day"] == .string(MemoryReviewGoal.dayKey(for: Self.monday)))

        // Finished elsewhere with no placement: an automatic one on the day, done, and the source completed.
        let finished = try await service.recordSourceConsumption(source: Self.source("srcB"), existingPlacement: nil, completedAt: Self.wednesday,
                                                                 order: 1, kind: .listening)
        #expect(finished.completedAt == Self.wednesday)
        #expect(finished.isAutomatic)
        #expect(try await Fixture.held(replica, .readingState, "rs:srcB", in: Fixture.library)?.fields["completedAt"] == SyncJSON(SyncTime.milliseconds(Self.wednesday)))

        try await service.completeScheduledSource(sourceID: "srcC")
        #expect(try await Fixture.held(replica, .placement, "pl:srcC", in: Fixture.library)?.fields["completedAt"] != .null)
        try await service.reopen(try #require(try await Self.snapshot(replica).placements.first { $0.sourceID == "srcC" }))
        #expect(try await Fixture.held(replica, .placement, "pl:srcC", in: Fixture.library)?.fields["completedAt"] == .null)
        try await service.removePlacement(try #require(try await Self.snapshot(replica).placements.first { $0.sourceID == "srcC" }), fromNotebookID: "nb1")
        #expect(try await Fixture.held(replica, .placement, "pl:srcC", in: Fixture.library)?.fields["origin"] == .string("automatic"),
                "its activity keeps it on the Schedule")
    }

}
