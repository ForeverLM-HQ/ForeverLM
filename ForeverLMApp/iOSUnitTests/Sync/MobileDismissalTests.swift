import Foundation
import Testing
@testable import ForeverLM

/// A dismissal is one Mark on every client (docs/cloudkit-schema-design.md §3.5.19, §10): `Mark(dismissed)`
/// on the address's work key (`wk:url:<normalized>`), the record the Mac writes for a dismissed URL. The
/// phone's archive writes that record, a Mac's un-dismiss flips it off, and the phone's explicit re-add of
/// the address flips a Mac's dismissal off, whichever side wrote it first. The Mac's half is
/// `DismissalMarkTests`, which pins the same id.
@Suite("iPhone dismissals", .serialized)
struct MobileDismissalTests {
    typealias Fixture = MobileWriterFixture

    static let url = "https://www.example.com/paper?utm_source=x"
    /// The Mac's `MarkKey.dismissed(url:)` for it, spelled out so a change to the form fails on both sides.
    static let markID = "mk:dismissed:wk:url:example.com/paper"
    static let library = CloudZoneID(SyncZone.library.rawValue)
    static let catalog = CloudZoneID(SyncZone.catalog.rawValue)

    /// A phone that holds a web source and has synced it, and its writer.
    static func phoneHoldingTheSource() async throws -> (server: FakeCloudKit, phone: MobileTestDevice, writer: MobileRecordWriter) {
        let (server, phone, writer) = try await MobileRecordWriterTests.syncedPhone()
        server.put([
            try MobileSyncFixture.record(.source, "srcU", [
                "primaryKey": .string("url:example.com/paper"), "type": .string("article"), "title": .string("A paper"), "status": .string("active"),
                "url": .string(url), "workKeys": .object(["url:example.com/paper": .bool(true)]), "addedAt": SyncJSON(1_759_050_000_000),
            ], in: catalog),
        ], zone: SyncZone.catalog.rawValue, owner: MobileRecordWriterTests.alice)
        try await phone.sync()
        return (server, phone, writer)
    }

    /// The Mark as a Mac writes it: `on` for its dismissal of the address, off for its un-dismiss, at `at`.
    static func macMark(on: Bool, at milliseconds: Int64) throws -> CloudRecord {
        try MobileSyncFixture.record(.mark, markID, [
            "kind": .string("dismissed"), "target": .string("wk:url:example.com/paper"), "on": .bool(on), "at": SyncJSON(milliseconds),
            "value": .object(["url": .string(url), "title": .string("A paper")]),
        ], in: library, at: milliseconds)
    }

    static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    @Test("Archiving writes the Mark a Mac writes for the address, and a Mac's un-dismiss flips that record off")
    func phoneArchiveThenMacUndismiss() async throws {
        let (server, phone, writer) = try await Self.phoneHoldingTheSource()
        try await writer.transaction { try $0.archiveSource("srcU") }
        let mark = try #require(try await Fixture.held(phone.replica, .mark, Self.markID, in: Fixture.library))
        #expect(mark.fields["target"] == .string("wk:url:example.com/paper"))
        #expect(mark.fields["on"] == .bool(true))
        #expect(mark.fields["value"] == .object(["url": .string(Self.url), "title": .string("A paper")]))
        #expect(try await Fixture.held(phone.replica, .mark, "mk:dismissed:src:srcU", in: Fixture.library) == nil, "never keyed by the source's id")
        try await phone.sync()
        #expect(try MobileRecordWriterTests.stored(server, .mark, Self.markID, zone: "Library")?.fields["on"] == .bool(true))

        // The Mac's un-dismiss: its dismissed row gone sends `on = false` on the same record, and the source active again.
        server.put([try Self.macMark(on: false, at: Self.now())], zone: SyncZone.library.rawValue, owner: MobileRecordWriterTests.alice)
        try await phone.sync()
        #expect(try await Fixture.held(phone.replica, .mark, Self.markID, in: Fixture.library)?.fields["on"] == .bool(false))
        #expect(try await phone.count("SELECT COUNT(*) FROM m_marks WHERE kind = 'dismissed' AND on_flag = 1") == 0, "nothing else keeps it on")

        // Archiving again flips the one record back on; it never makes a second.
        try await writer.transaction { try $0.archiveSource("srcU") }
        #expect(try await Fixture.held(phone.replica, .mark, Self.markID, in: Fixture.library)?.fields["on"] == .bool(true))
        #expect(try await phone.count("SELECT COUNT(*) FROM m_marks WHERE kind = 'dismissed'") == 1)
    }

    @Test("A Mac dismisses the address, then the phone's explicit re-add of it turns the Mac's Mark off")
    func macDismissThenPhoneReAdd() async throws {
        let (server, phone, writer) = try await Self.phoneHoldingTheSource()
        server.put([try Self.macMark(on: true, at: Self.now() - 120_000)], zone: SyncZone.library.rawValue, owner: MobileRecordWriterTests.alice)
        try await phone.sync()
        #expect(try await Fixture.held(phone.replica, .mark, Self.markID, in: Fixture.library)?.fields["on"] == .bool(true))

        // Another spelling of the same address.
        let added = try #require(URL(string: "https://example.com/paper"))
        _ = try await writer.transaction { try $0.captureURL(added, title: "A paper", sourceType: "article", target: nil) }
        #expect(try await Fixture.held(phone.replica, .mark, Self.markID, in: Fixture.library)?.fields["on"] == .bool(false))
        try await phone.sync()
        #expect(try MobileRecordWriterTests.stored(server, .mark, Self.markID, zone: "Library")?.fields["on"] == .bool(false), "sent, for the Mac to turn its row off")
    }

    @Test("A dismissal that is not on is left alone by a re-add, and an address with no work key is dismissed as it is")
    func reAddWritesNothingForNothingDismissed() async throws {
        let (_, phone, writer) = try await Self.phoneHoldingTheSource()
        let added = try #require(URL(string: "https://example.com/never-dismissed"))
        _ = try await writer.transaction { try $0.captureURL(added, title: "New", sourceType: "article", target: nil) }
        #expect(try await phone.count("SELECT COUNT(*) FROM m_marks WHERE kind = 'dismissed'") == 0)
        #expect(WorkKey.dismissalTarget(url: "/papers/a.pdf") == "wk:url:/papers/a.pdf")
        #expect(WorkKey.dismissalTarget(url: Self.url) == "wk:url:example.com/paper")
    }
}
