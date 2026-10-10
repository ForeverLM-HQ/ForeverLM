import Foundation
import Testing
@testable import ForeverLM

/// Where the learner is in a source on the phone under generation 2 (docs/cloudkit-schema-design.md
/// §3.5.18; §14.2 WP20): the Reader's place is the member's `ReadingState` (`rs:<sourceID>`, in
/// `Library`), not a UserDefaults row, created on the first real change, never moved by opening, and
/// sent after its 30-second debounce.
@Suite("iPhone reading state", .serialized)
struct MobileReadingStateTests {
    typealias Fixture = MobileWriterFixture

    @Test("The Reader's place is a ReadingState: locator, last read and furthest; reading it back gives the place")
    func savesThePlace() async throws {
        let replica = try await Fixture.replica(space: nil)
        let writer = Fixture.writer(replica)
        #expect(try await writer.readingFraction(of: "src1") == nil, "nothing before the first real change")
        try await writer.saveReadingPosition("src1", fraction: 0.42)
        let state = try #require(try await Fixture.held(replica, .readingState, "rs:src1", in: Fixture.library))
        #expect(state.fields["targetKind"] == .string("source"))
        #expect(state.fields["targetID"] == .string("src1"))
        #expect(state.fields["locator"] == .object(["t": .string("web"), "fraction": .number(0.42)]))
        #expect(state.fields["furthest"] == .array([.number(0), .number(0.42)]))
        #expect(state.fields["lastReadAt"]?.int64Value != nil)
        #expect(try await writer.readingFraction(of: "src1") == 0.42)
        #expect(try await replica.read { try $0.connection.scalarText("SELECT target_id FROM m_reading_states WHERE id = 'rs:src1'") } == "src1")
    }

    @Test("Restoring the same place stamps nothing; going back keeps the furthest point; a clamp keeps 0…1")
    func sameAndBackwards() async throws {
        let replica = try await Fixture.replica(space: nil)
        let writer = Fixture.writer(replica)
        try await writer.saveReadingPosition("src1", fraction: 0.8)
        let first = try #require(try await Fixture.patch(replica, .readingState, "rs:src1", in: Fixture.library))
        try await writer.saveReadingPosition("src1", fraction: 0.8001)
        #expect(try await Fixture.patch(replica, .readingState, "rs:src1", in: Fixture.library) == first, "a restored place writes nothing")
        try await writer.saveReadingPosition("src1", fraction: 0.3)
        let state = try #require(try await Fixture.held(replica, .readingState, "rs:src1", in: Fixture.library))
        #expect(state.fields["locator"]?["fraction"] == .number(0.3))
        #expect(state.fields["furthest"] == .array([.number(0), .number(0.8)]), "the furthest point never walks back")
        try await writer.saveReadingPosition("src1", fraction: 7)
        #expect(try await writer.readingFraction(of: "src1") == 1)
    }

    @Test("Reaching the end marks it read once, and listening to the end consumed; the first time stands")
    func markRead() async throws {
        let replica = try await Fixture.replica(space: nil)
        let writer = Fixture.writer(replica)
        let first = Date(timeIntervalSince1970: 1_759_400_000)
        try await writer.transaction { try $0.markRead("src1", at: first, consumed: false) }
        try await writer.transaction { try $0.markRead("src1", at: first.addingTimeInterval(600), consumed: true) }
        let state = try #require(try await Fixture.held(replica, .readingState, "rs:src1", in: Fixture.library))
        #expect(state.fields["readAt"]?.int64Value == SyncTime.milliseconds(first))
        #expect(state.fields["consumedAt"]?.int64Value == SyncTime.milliseconds(first.addingTimeInterval(600)))
        let patch = try await Fixture.patch(replica, .readingState, "rs:src1", in: Fixture.library)
        try await writer.transaction { try $0.markRead("src1", at: first.addingTimeInterval(900), consumed: true) }
        #expect(try await Fixture.patch(replica, .readingState, "rs:src1", in: Fixture.library) == patch, "nothing to change")
    }

    @Test("A ReadingState waits its 30 seconds before it is sent, on the private engine's stream")
    func sentAfterItsDebounce() async throws {
        let replica = try await Fixture.replica(space: nil)
        let now = Date()
        let writer = Fixture.writer(replica, at: now)
        try await writer.saveReadingPosition("src1", fraction: 0.5)
        #expect(try await Fixture.changes(replica, at: now.addingTimeInterval(20)).isEmpty)
        let changes = try await Fixture.changes(replica, scope: .privateZones, at: now.addingTimeInterval(31))
        #expect(changes.map(\.wireID) == ["rs:src1"])
        #expect(changes.first?.priority == .personal)
        #expect(try await Fixture.changes(replica, scope: .spaces, at: now.addingTimeInterval(31)).isEmpty)
    }

}
