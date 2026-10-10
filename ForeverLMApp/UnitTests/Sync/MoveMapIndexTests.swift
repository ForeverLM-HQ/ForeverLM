import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// The `moveMaps` lookup (docs/cloudkit-schema-design.md §4.4, §6.2, D51), Swift's twin of
/// `schema/js/move-maps.js`: the same list bytes, the same order, the same re-targeting rule.
@Suite("Move map index")
struct MoveMapIndexTests {
    private static func move(_ id: String, _ from: String, _ to: String, at: Int64, type: String = "Notebook") -> MoveMapMove {
        MoveMapMove(type: type, id: id, from: from, to: to, at: at)
    }

    @Test("A list round-trips through gzip of compact JSON with sorted keys, as move-maps.js writes it")
    func listBytes() throws {
        let moves = [Self.move("nb1", "Library", "Space-s1", at: 1_759_400_000_000)]
        let stored = try MoveMapIndex.encodeList(moves)
        #expect(SyncGzip.isGzip(stored))
        let text = String(decoding: try SyncGzip.decompress(stored, maxBytes: 1 << 20), as: UTF8.self)
        #expect(text == #"{"moves":[{"at":1759400000000,"from":"Library","id":"nb1","to":"Space-s1","type":"Notebook"}],"v":1}"#)
        #expect(try MoveMapIndex.decodeList(stored) == moves)
    }

    @Test("A list of another version, or bytes that are no list, throw; a move it cannot read is skipped")
    func unreadableLists() throws {
        let otherVersion = try SyncGzip.compress(Data(#"{"v":2,"moves":[]}"#.utf8))
        #expect(throws: MoveListError.self) { try MoveMapIndex.decodeList(otherVersion) }
        #expect(throws: MoveListError.self) { try MoveMapIndex.decodeList(Data(#"{"v":1,"moves":[]}"#.utf8)) }
        let mixed = try SyncGzip.compress(Data("""
            {"v":1,"moves":[{"type":"Notebook","id":"a","from":"Library","to":"Space-s","at":5},
            {"type":"Notebook","id":"b","from":"Library","to":"Library","at":5},
            {"type":"Notebook","id":"c","from":"Nowhere","to":"Space-s","at":5},
            {"type":"Notebook","id":"d","from":"Library","to":"Space-s","at":1.5}]}
            """.utf8))
        #expect(try MoveMapIndex.decodeList(mixed).map(\.id) == ["a"])
        #expect(throws: MoveListError.self) { try MoveMapIndex.encodeList([Self.move("x", "Library", "Library", at: 1)]) }
    }

    @Test("A record's latest move counts: by time, then entry key, then place in the list")
    func retarget() {
        let index = MoveMapIndex()
        index.add(key: "job2.0", moves: [Self.move("nb1", "Space-s1", "Library", at: 20)])
        index.add(key: "job1.0", moves: [Self.move("nb1", "Library", "Space-s1", at: 10), Self.move("ch1", "Library", "Space-s1", at: 10, type: "Chat")])
        // Moved into the space and back: a write aimed at the space goes to Library, one aimed at
        // Library stays (the record is there again, and its absence there would be a deletion).
        #expect(index.retarget(type: "Notebook", id: "nb1", from: "Space-s1") == "Library")
        #expect(index.retarget(type: "Notebook", id: "nb1", from: "Library") == nil)
        #expect(index.retarget(type: "Chat", id: "ch1", from: "Library") == "Space-s1")
        #expect(index.retarget(type: "Chat", id: "ch1", from: "Catalog") == nil, "it never left Catalog")
        #expect(index.retarget(type: "Chat", id: "ch2", from: "Library") == nil, "never moved: the delete wins")
        #expect(index.moved(type: "Chat", id: "ch1"))
        #expect(!index.moved(type: "Chat", id: "ch2"))
        // The same moves listed again under a folded key change nothing.
        index.add(key: "folded.1", moves: [Self.move("nb1", "Library", "Space-s1", at: 10), Self.move("nb1", "Space-s1", "Library", at: 20)])
        #expect(index.retarget(type: "Notebook", id: "nb1", from: "Space-s1") == "Library")
        #expect(index.moves(type: "Notebook", id: "nb1").map(\.at) == [10, 10, 20, 20])
    }

    @Test("Refreshing from the root reads each listed entry once through the transport, checks its part hash, and retries one it could not read")
    func refreshFromTheRoot() async throws {
        let server = FakeCloudKit()
        let transport = server.transport(user: "alice", device: "mac")
        let salt = Data((0..<32).map { UInt8($0) })
        let stored = try MoveMapIndex.encodeList([Self.move("nb1", "Library", "Space-s1", at: 10)])
        let file = FileRef(owner: "root", role: MoveMapIndex.role(forKey: "job1.0"), hash: SyncIdentity.sha256Hex(stored),
                           size: Int64(stored.count), mime: "application/json", encoding: "gzip", storedParts: [stored])
        let missing = FileRef(owner: "root", role: MoveMapIndex.role(forKey: "job2.0"), hash: SyncIdentity.sha256Hex(Data([1])),
                              size: 1, mime: "application/json", encoding: "gzip", storedParts: [Data([1])])
        let contentID = SyncIdentity.contentID(owner: "root", role: file.role, partHash32: file.parts[0])
        _ = server.put([CloudRecord(
            id: CloudRecordID(RecordNaming.recordName(type: .content, id: contentID, salt: salt), in: CloudZoneID("Content")),
            recordType: "Content", encryptedFields: [CloudRecord.dataKey: .bytes(stored)]
        )], zone: "Content", owner: "alice")

        var root = SyncEnvelope.new(.zoneRoot, id: "root", saltID: RecordNaming.saltID(salt))
        var patch = RecordPatch(.zoneRoot, id: "root")
        patch.changes["moveMaps"] = .elements(["job1.0": file.value, "job2.0": missing.value, "job0.0": .null])
        try root.apply(patch) { _, policy, _ in SyncStamp(policy: policy, milliseconds: 1_759_400_000_000, counter: 0, deviceID: "macaaaaa") }
        #expect(MoveMapIndex.entries(of: root).map(\.key) == ["job1.0", "job2.0"], "a key a fold cleared names nothing")

        let index = MoveMapIndex()
        let fetch = MoveMapIndex.transportFetch(transport, salt: salt)
        #expect(await index.refresh(from: root, fetch: fetch) == ["job2.0"])
        #expect(index.retarget(type: "Notebook", id: "nb1", from: "Library") == "Space-s1")
        server.resetCalls()
        #expect(await index.refresh(from: root, fetch: fetch) == ["job2.0"])
        #expect(server.calls.count == 1, "the entry read already is not fetched again; the missing one is retried")
    }
}
