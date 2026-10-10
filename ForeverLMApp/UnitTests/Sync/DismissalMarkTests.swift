import Foundation
import Testing
@testable import ForeverLM

/// A dismissal is one Mark on every client (docs/cloudkit-schema-design.md §3.5.19, §10): `Mark(dismissed)`
/// on the address's work key (`wk:url:<normalized>`) with `value {url, title?}`, the form the Mac's
/// projection and the cutover mapping write, and the form the iPhone and the web write when they archive
/// a source. So an archive on the phone and an un-dismiss on the Mac flip the same record, either way
/// round. The iPhone's half is `MobileDismissalTests`.
@Suite("Dismissal Marks")
struct DismissalMarkTests {
    typealias F = NotebookSyncFixture

    static let url = "https://www.example.com/paper?utm_source=x"
    /// What the phone writes for it (`WorkKey.dismissalTarget`, spelled out so a change to the form fails here).
    static let markID = "mk:dismissed:wk:url:example.com/paper"

    /// The record the phone's archive writes, or its re-add's off flip once the Mark is the Mac's own.
    static func phoneMark(on: Bool, ms: Int64, withValue: Bool = true) throws -> ReplicaRecord {
        var fields: [String: SyncJSON] = ["kind": .string("dismissed"), "target": .string("wk:url:example.com/paper"), "on": .bool(on), "at": SyncJSON(ms)]
        if withValue { fields["value"] = .object(["url": .string(url), "title": .string("A paper")]) }
        return try F.record(.mark, markID, fields, ms: ms)
    }

    static func marks(_ pending: [String: OutboxChange]) -> [String] {
        pending.keys.filter { $0.hasPrefix("Mark:") }.sorted()
    }

    @Test("The Mac, the cutover mapping and the iPhone name one address by one Mark")
    func oneTargetForOneAddress() {
        #expect(MarkKey.dismissed(url: Self.url).id == Self.markID)
        #expect(MarkKey.dismissed(url: "https://example.com/paper").id == Self.markID, "another spelling of the address is the same Mark")
        #expect(MarkKey.dismissed(url: Self.url).target == WorkKey.dismissalTarget(url: Self.url))
        #expect(MarkKey.dismissed(url: "/papers/a.pdf").target == "wk:url:/papers/a.pdf", "an address with no work key is kept as it is")
    }

    @Test("The iPhone archives, then the Mac un-dismisses: the Mac's off Mark is the phone's record, and no Mark is keyed by a source")
    func phoneArchiveThenMacUndismiss() throws {
        let (root, store) = try F.makeStore("dismissal-phone-then-mac")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.apply(store, [try Self.phoneMark(on: true, ms: 1_759_400_000_000)])
        #expect(try F.text(store, "SELECT title FROM dismissed_sources WHERE url = ?", [.text(Self.url)]) == "A paper", "the Mac holds the phone's dismissal")
        #expect(Self.marks(try F.pending(store)).isEmpty, "an apply sends nothing back")

        try store.undismissSource(url: Self.url)
        #expect(try F.count(store, "SELECT COUNT(*) FROM dismissed_sources") == 0)
        let pending = try F.pending(store)
        #expect(Self.marks(pending) == ["Mark:" + Self.markID], "the one Mark there is, the phone's")
        #expect(F.savedFields(pending["Mark:" + Self.markID])?["on"] == .bool(false))
    }

    @Test("The Mac dismisses, then the iPhone's re-add turns it off: every spelling the Mac holds goes, even with no value")
    func macDismissThenPhoneReAdd() throws {
        let (root, store) = try F.makeStore("dismissal-mac-then-phone")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try store.dismissSource(url: Self.url, title: "A paper")
        // The other spelling of the address, as a feed's dismissal leaves one.
        try store.execute("INSERT INTO dismissed_sources (url, title, dismissed_at) VALUES ('https://example.com/paper', 'A paper', 5000)")
        let sent = try F.pending(store)
        let mark = try #require(F.savedFields(sent["Mark:" + Self.markID]), "the phone's record, by its id")
        #expect(mark["target"] == .string("wk:url:example.com/paper") && mark["on"] == .bool(true))
        #expect(Self.marks(sent) == ["Mark:" + Self.markID])
        try F.sendAll(store)

        // The phone's explicit Add writes only `on = false`; the record keeps the value it had, or not.
        try F.apply(store, [try Self.phoneMark(on: false, ms: 1_759_500_000_000, withValue: false)])
        #expect(try F.count(store, "SELECT COUNT(*) FROM dismissed_sources") == 0)
    }

    @Test("A dismissal with no value is the address its work key names, and one of another address is left alone")
    func markWithoutValue() throws {
        let (root, store) = try F.makeStore("dismissal-no-value")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try store.execute("INSERT INTO dismissed_sources (url, title, dismissed_at) VALUES ('https://other.example.org/x', 'Other', 5000)")
        try F.apply(store, [try Self.phoneMark(on: true, ms: 1_759_400_000_000, withValue: false)])
        #expect(try F.count(store, "SELECT COUNT(*) FROM dismissed_sources WHERE url = 'example.com/paper'") == 1)
        try F.apply(store, [try Self.phoneMark(on: false, ms: 1_759_500_000_000, withValue: false)])
        #expect(try F.count(store, "SELECT COUNT(*) FROM dismissed_sources WHERE url = 'example.com/paper'") == 0)
        #expect(try F.count(store, "SELECT COUNT(*) FROM dismissed_sources WHERE url = 'https://other.example.org/x'") == 1)
    }

    @Test("A dismissal keyed by a source's id is no dismissal: it lands in no table")
    func sourceKeyedMarkIsIgnored() throws {
        let (root, store) = try F.makeStore("dismissal-src-keyed")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.apply(store, [try F.record(.mark, "mk:dismissed:src:src-a", [
            "kind": .string("dismissed"), "target": .string("src:src-a"), "on": .bool(true), "at": SyncJSON(Int64(1_759_400_000_000)),
            "value": .object(["url": .string(Self.url), "title": .string("A paper")]),
        ])])
        #expect(try F.count(store, "SELECT COUNT(*) FROM dismissed_sources") == 0)
    }
}
