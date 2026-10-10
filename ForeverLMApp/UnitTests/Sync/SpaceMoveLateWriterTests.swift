import Foundation
import Testing
@testable import ForeverLM

/// Writers that had not seen a move (docs/cloudkit-schema-design.md §4.4, §5.2, §5.3, §6.2, §9.2, PD-2,
/// R3-m8, R3-m9, R5-m1): what a second device writes while the move runs, and what a stale device writes
/// after it, reaches the space; private chats stay in `Library` whole; any of the owner's Macs re-homes
/// a late child from `moveMaps`, two at once losing nothing; a Doc's late Comment follows the Doc; and a
/// pending write for a space a move back deleted lands on the `Library` record.
@Suite("Space move late writers", .serialized)
struct SpaceMoveLateWriterTests {
    typealias F = SpaceMoveFixture

    private static func entryID(_ source: String) -> String {
        SyncIdentity.entryID(containerID: F.notebook, itemKind: "source", itemID: source)
    }

    private static func movingMac(_ name: String) async throws -> F.Mac {
        let mac = try await F.Mac(EngineTestDriver.server(), name: name, deviceID: "macaaaaa")
        try await F.seed(mac)
        try await mac.makeSpace()
        return mac
    }

    @Test("The notebook's private chats stay in Library whole, a misfiled scored chat with them, and every Entry keeps its stamps")
    func privateChatsStayAndStampsTravel() async throws {
        let mac = try await Self.movingMac("late-private")
        let before = try Self.sources(mac)
        try await mac.job().moveNotebook(F.notebook, into: F.spaceID)
        try await F.expectMoved(mac)
        // The member's exclusions name Entry stamps (D16): the space's Entries carry the same ones.
        for source in F.sources {
            let copy = try #require(try F.inSpace(mac, .entry, Self.entryID(source)))
            #expect(copy.stamps["state"] == before[source]?.stamps["state"] && copy.stamps["approval"] == before[source]?.stamps["approval"], "\(source)")
        }
        let kept = try F.count(mac, "SELECT COUNT(*) FROM ck_move_items WHERE state = 'kept'")
        #expect(kept == 10, "six private chats and their four Exchanges stay, each closed as kept")
    }

    private static func sources(_ mac: F.Mac) throws -> [String: SyncEnvelope] {
        var held: [String: SyncEnvelope] = [:]
        for source in F.sources { held[source] = try F.inLibrary(mac, .entry, entryID(source)) }
        return held
    }

    @Test("A second device appends an Exchange and unticks a source after the copy, and both survive in the space")
    func secondDeviceDuringTheMove() async throws {
        let mac = try await Self.movingMac("late-second")
        let job = mac.job()
        await job.stop(before: .catchUp)
        await #expect(throws: SpaceMoveError.stopped(.catchUp)) { try await job.moveNotebook(F.notebook, into: F.spaceID) }
        #expect(try F.inSpace(mac, .chat, F.chat) != nil, "copied")

        // Alice's iPhone has not seen movingTo: it writes into Library.
        let entry = try #require(try F.inLibrary(mac, .entry, Self.entryID("src-a")))
        guard case .value(let state)? = entry.stamps["state"], case .value(let approval)? = entry.stamps["approval"] else {
            Issue.record("the Entry has no stamps"); return
        }
        let pair = "\(state.rawValue)|\(approval.rawValue)"
        // It also renames the chat it already wrote, which the move has copied.
        var renamed = try #require(try F.inLibrary(mac, .chat, F.chat))
        try renamed.apply(RecordPatch(.chat, id: F.chat, changes: ["title": .value("Renamed mid-move")])) { _, policy, _ in
            SyncStamp(policy: policy, milliseconds: F.base + 60_000, counter: 1, deviceID: "iphoneaa")
        }
        mac.server.put([
            CloudRecord(id: CloudRecordID(RecordNaming.recordName(type: .chat, id: F.chat, salt: F.personalSalt), in: CloudZoneID("Library")),
                        recordType: "Chat", encryptedFields: [CloudRecord.payloadKey: .bytes(try renamed.storedPayload())]),
            try F.exchangeRecord("exc-late", chat: F.chat, seq: 3, ms: F.base + 60_000),
            try F.record(.notebookState, "ns:\(F.notebook)", ["notebookID": .string(F.notebook), "excluded": .object(["src-a": .string(pair)])],
                         ms: F.base + 60_000),
        ], zone: "Library", owner: F.user)

        _ = await mac.job().afterRound()
        try await F.expectMoved(mac)
        #expect(try F.inSpace(mac, .exchange, "exc-late")?.fields["question"] == .string("Question 3?"))
        #expect(try F.inSpace(mac, .chat, F.chat)?.fields["title"] == .string("Renamed mid-move"), "a write to a copied original reaches its copy")
        #expect(try F.inLibrary(mac, .exchange, "exc-late") == nil)
        // The untick is the member's own and stays in Library; it still names the space Entry's stamps.
        let exclusions = try #require(try F.inLibrary(mac, .notebookState, "ns:\(F.notebook)"))
        #expect(exclusions.fields["excluded"]?["src-a"] == .string(pair))
        let copy = try #require(try F.inSpace(mac, .entry, Self.entryID("src-a")))
        #expect(copy.stamps["state"] == .value(state) && copy.stamps["approval"] == .value(approval))
        #expect(try F.inSpace(mac, .notebookState, "ns:\(F.notebook)") == nil)
    }

    @Test("A late chat and its Exchange in Library naming the moved notebook are re-homed, a late private chat stays")
    func lateChildIsRehomed() async throws {
        let mac = try await Self.movingMac("late-rehome")
        try await mac.job().moveNotebook(F.notebook, into: F.spaceID)
        mac.server.put([
            try F.chatRecord("cht-late", kind: "chat"),
            try F.exchangeRecord("exc-late", chat: "cht-late", seq: 1, ms: F.base + 90_000),
            try F.chatRecord("cht-late-review", kind: "review"),
            try F.record(.entry, Self.entryID("src-d"), [
                "containerKind": "notebook", "containerID": .string(F.notebook), "itemKind": "source", "itemID": "src-d",
                "state": "active", "approval": "approved", "orderKey": "a3", "origin": "added", "addedAt": SyncJSON(F.base),
            ]),
        ], zone: "Library", owner: F.user)
        EngineTestDriver.follow(mac.server)
        try await mac.device.fetch()

        let reports = try await mac.job().rehome()
        #expect(reports.count == 2, "the chat and the Entry first, the Exchange once its chat is listed")
        for (type, id) in [(SyncRecordType.chat, "cht-late"), (.exchange, "exc-late"), (.entry, Self.entryID("src-d"))] {
            #expect(try F.inSpace(mac, type, id) != nil, "\(id) is in the space")
            #expect(try F.inLibrary(mac, type, id) == nil, "\(id) left Library")
        }
        #expect(try F.inLibrary(mac, .chat, "cht-late-review") != nil && F.inSpace(mac, .chat, "cht-late-review") == nil)
        let listed = Set(try await F.listedMoves(mac).map(\.id))
        #expect(listed.isSuperset(of: ["cht-late", "exc-late", Self.entryID("src-d")]))
    }

    @Test("After the stub, a stale device's Exchange, rename of the stub and retitle of a moved Doc all reach the space copy")
    func staleDeviceAfterTheStub() async throws {
        let server = EngineTestDriver.server()
        let mac = try await F.Mac(server, name: "late-stale-a", deviceID: "macaaaaa")
        try await F.seed(mac)
        let stale = try await F.Mac(server, name: "late-stale-b", deviceID: "macbbbbb")
        try await stale.sync()
        #expect(try F.text(stale, "SELECT title FROM global_artifacts WHERE id = ?", [.text(F.doc)]) == "Cell notes")
        try await mac.makeSpace()
        try await mac.job().moveNotebook(F.notebook, into: F.spaceID)

        // A stale iPhone appends to the moved chat, and renames the stub, in Library.
        let stub = try #require(try F.inLibrary(mac, .notebook, F.notebook))
        var renamed = stub
        try renamed.apply(RecordPatch(.notebook, id: F.notebook, changes: ["title": .value("🧬 Cells and organelles")])) { _, policy, _ in
            SyncStamp(policy: policy, milliseconds: SyncTime.milliseconds(Date()), counter: 1, deviceID: "iphoneaa")
        }
        let stubName = RecordNaming.recordName(type: .notebook, id: F.notebook, salt: F.personalSalt)
        server.put([
            CloudRecord(id: CloudRecordID(stubName, in: CloudZoneID("Library")), recordType: "Notebook",
                        encryptedFields: [CloudRecord.payloadKey: .bytes(try renamed.storedPayload())]),
            try F.exchangeRecord("exc-late", chat: F.chat, seq: 3, ms: F.base + 120_000),
        ], zone: "Library", owner: F.user)
        // A stale Mac retitles the moved Doc: its save meets unknownItem and goes to the copy.
        await EngineTestDriver.pause()
        try stale.device.exec("UPDATE global_artifacts SET title = 'Cell notes, revised' WHERE id = '\(F.doc)'")
        try await stale.sync()
        try await stale.sync()

        EngineTestDriver.follow(server)
        try await mac.device.fetch()
        _ = await mac.job().afterRound()
        #expect(try F.inSpace(mac, .exchange, "exc-late") != nil && F.inLibrary(mac, .exchange, "exc-late") == nil)
        #expect(try F.inSpace(mac, .notebook, F.notebook)?.fields["title"] == .string("🧬 Cells and organelles"))
        #expect(try F.inLibrary(mac, .notebook, F.notebook)?.fields["status"] == .string("moved"), "the stub stays a stub")
        #expect(try F.inSpace(mac, .artifact, F.doc)?.fields["title"] == .string("Cell notes, revised"))
        #expect(try F.inLibrary(mac, .artifact, F.doc) == nil, "nothing is made again in Library")
        // Forwarded once: another pass sends nothing more.
        #expect(try await mac.job().forwardStubEdits() == 0)
    }

    @Test("A second Mac of the owner with no journal re-homes from moveMaps, and two Macs re-homing at once lose no id")
    func twoMacsRehomeAtOnce() async throws {
        let server = EngineTestDriver.server()
        let mac = try await F.Mac(server, name: "late-two-a", deviceID: "macaaaaa")
        try await F.seed(mac)
        try await mac.makeSpace()
        try await mac.job().moveNotebook(F.notebook, into: F.spaceID)
        let other = try await F.Mac(server, name: "late-two-b", deviceID: "macbbbbb")
        try await other.sync()
        #expect(try F.count(other, "SELECT COUNT(*) FROM ck_move_jobs") == 0, "no journal on the second Mac")

        server.put([
            try F.exchangeRecord("exc-late", chat: F.chat, seq: 3, ms: F.base + 150_000),
            try F.record(.comment, "cmt-late", ["artifactID": .string(F.doc), "body": "A late note", "author": F.owner.value,
                                                "createdAt": SyncJSON(F.base + 150_000), "editedAt": SyncJSON(F.base + 150_000)]),
        ], zone: "Library", owner: F.user)
        EngineTestDriver.follow(server)
        try await mac.device.fetch()
        try await other.device.fetch()

        let first = mac.job()
        let second = other.job()
        async let fromFirst = first.rehome()
        async let fromSecond = second.rehome()
        let reports = try await fromFirst + fromSecond
        #expect(!reports.isEmpty)
        for (type, id) in [(SyncRecordType.exchange, "exc-late"), (.comment, "cmt-late")] {
            #expect(try F.inSpace(mac, type, id) != nil, "\(id) is in the space")
            #expect(try F.inLibrary(mac, type, id) == nil, "\(id) left Library")
        }
        let root = try #require(try F.server(mac, .zoneRoot, "root", zone: "Library"))
        let keys = MoveMapIndex.entries(of: root).map(\.key)
        #expect(keys.contains { $0.hasPrefix("rehome.") }, "the re-homing passes wrote entries of their own")
        let listed = try await F.listedMoves(mac)
        for id in ["exc-late", "cmt-late"] {
            #expect(listed.contains { $0.id == id && $0.from == "Library" && $0.to == "Space-s1" }, "\(id) is listed")
        }
        // The first move's entry is still there, whole: nothing rewrote it.
        #expect(keys.contains("nb.\(F.notebook).\(F.spaceID).0"))
        #expect(listed.contains { $0.id == F.chat })
    }

    @Test("A Doc moved into its Doc space takes its Comments, keeps its notebook, and a late Comment follows it")
    func docMoveAndLateComment() async throws {
        let mac = try await F.Mac(EngineTestDriver.server(), name: "late-doc", deviceID: "macaaaaa")
        try await F.seed(mac)
        try await mac.makeSpace(kind: "doc", primaryID: F.doc, id: "d1")
        try await mac.job().moveDoc(F.doc, into: "d1")
        let moved = try #require(try F.inSpace(mac, .artifact, F.doc, zone: "Space-d1"))
        #expect(moved.fields["notebookID"] == .string(F.notebook), "the owner's notebook still lists it (D5)")
        #expect(try F.inSpace(mac, .comment, F.comment, zone: "Space-d1") != nil)
        #expect(try F.inLibrary(mac, .artifact, F.doc) == nil && F.inLibrary(mac, .comment, F.comment) == nil)
        #expect(try F.inLibrary(mac, .notebook, F.notebook)?.fields["status"] == .string("active"), "the notebook does not move")

        mac.server.put([try F.record(.comment, "cmt-late", ["artifactID": .string(F.doc), "body": "Seen late", "author": F.owner.value,
                                                            "createdAt": SyncJSON(F.base + 200_000), "editedAt": SyncJSON(F.base + 200_000)])],
                       zone: "Library", owner: F.user)
        EngineTestDriver.follow(mac.server)
        try await mac.device.fetch()
        try await mac.job().rehome()
        #expect(try F.inSpace(mac, .comment, "cmt-late", zone: "Space-d1")?.fields["body"] == .string("Seen late"))
        #expect(try F.inLibrary(mac, .comment, "cmt-late") == nil)
    }

    @Test("A stale Mac's pending write for a space that a move back deleted lands on the Library record")
    func pendingWriteAfterTheMoveBack() async throws {
        let server = EngineTestDriver.server()
        let mac = try await F.Mac(server, name: "late-back-a", deviceID: "macaaaaa")
        try await F.seed(mac)
        try await mac.makeSpace()
        try await mac.job().moveNotebook(F.notebook, into: F.spaceID)
        let stale = try await F.Mac(server, name: "late-back-b", deviceID: "macbbbbb")
        try await stale.sync()
        try await stale.sync()
        #expect(try F.text(stale, "SELECT team_id FROM learning_goals WHERE id = ?", [.text(F.notebook)]) == F.spaceID,
                "the second Mac's own row became the space's notebook")
        #expect(try F.count(stale, "SELECT COUNT(*) FROM learning_goals WHERE wire_key = ?", [.text(F.notebook)]) == 1)

        // The stale Mac renames the notebook while it is in the space, and has not sent it yet.
        await EngineTestDriver.pause()
        try stale.device.exec("UPDATE learning_goals SET title = '🧬 Cells, renamed late' WHERE id = '\(F.notebook)'")

        // The owner moves it back: the space made for it is deleted.
        try await mac.job().moveNotebookBack(F.notebook, from: F.spaceID)
        #expect(!server.zoneNames(owner: F.user).contains("Space-s1"))
        let live = try #require(try F.inLibrary(mac, .notebook, F.notebook))
        #expect(live.fields["status"] == .string("active") && (live.fields["movedTo"] ?? .null) == .null)
        for source in F.sources { #expect(try F.inLibrary(mac, .entry, Self.entryID(source)) != nil) }
        #expect(try F.inLibrary(mac, .chat, F.chat) != nil && F.inLibrary(mac, .exchange, F.exchanges[0]) != nil)
        #expect(try F.text(mac, "SELECT COALESCE(team_id, 'mine') FROM learning_goals WHERE id = ?", [.text(F.notebook)]) == "mine")
        #expect(try F.count(mac, """
            SELECT COUNT(*) FROM learning_goal_items i JOIN sources s ON s.id = i.source_id WHERE i.goal_id = ? AND s.team_id IS NULL
        """, [.text(F.notebook)]) == 3, "the pool names the learner's own sources again")

        // The stale Mac's send meets zoneNotFound and goes to the Library record, with its stamp.
        EngineTestDriver.follow(server)
        try await stale.spaces.sync()
        #expect(try F.inLibrary(mac, .notebook, F.notebook)?.fields["title"] == .string("🧬 Cells, renamed late"))
        try await stale.sync()
        #expect(try F.text(stale, "SELECT COALESCE(team_id, 'mine') || '|' || title FROM learning_goals WHERE id = ?", [.text(F.notebook)])
                == "mine|🧬 Cells, renamed late")
    }

    @Test("A move back that finds a record in the space that no pass carried keeps the space, and the notebook still comes back (F10)")
    func moveBackKeepsASpaceWithAStranger() async throws {
        let server = EngineTestDriver.server()
        let mac = try await F.Mac(server, name: "back-stranger", deviceID: "macaaaaa")
        try await F.seed(mac)
        try await mac.makeSpace()
        try await mac.job().moveNotebook(F.notebook, into: F.spaceID)
        // A member's shelf that no Entry of the notebook names landed in the shared space.
        let salt = try F.spaceSalt(mac)
        server.put([try F.record(.collection, "col-late", [
            "kind": "book", "externalKey": "late", "title": "A shelf", "status": "active", "addedAt": SyncJSON(F.base), "editedAt": SyncJSON(F.base),
        ], zone: "Space-s1", salt: salt)], zone: "Space-s1", owner: F.user)
        EngineTestDriver.follow(server)

        let report = try await mac.job().moveNotebookBack(F.notebook, from: F.spaceID)
        #expect(report.spaceKept == ["\(SyncRecordType.collection.rawValue)/col-late"], "\(report)")
        #expect(server.zoneNames(owner: F.user).contains("Space-s1"), "the space is not deleted over a record nobody moved")
        #expect(try F.inLibrary(mac, .notebook, F.notebook)?.fields["status"] == .string("active"))
        #expect(try F.inLibrary(mac, .chat, F.chat) != nil, "what the journal carried came back")
    }

    @Test("A late draft of a space Doc is that member's own: it stays in Library whatever notebook it names (F22)")
    func lateDraftStaysInLibrary() async throws {
        let mac = try await Self.movingMac("late-draft")
        try await mac.job().moveNotebook(F.notebook, into: F.spaceID)
        mac.server.put([
            try F.record(.artifact, "doc-draft", [
                "kind": "doc", "title": "A draft", "notebookID": .string(F.notebook), "status": "active", "createdAt": SyncJSON(F.base),
                "draftOf": .object(["artifactID": .string(F.doc)]),
            ], ms: F.base + 90_000),
            try F.chatRecord("cht-late", kind: "chat"),
        ], zone: "Library", owner: F.user)
        EngineTestDriver.follow(mac.server)
        try await mac.device.fetch()

        _ = try await mac.job().rehome()
        #expect(try F.inSpace(mac, .chat, "cht-late") != nil, "an ordinary late child is re-homed")
        #expect(try F.inLibrary(mac, .artifact, "doc-draft") != nil && F.inSpace(mac, .artifact, "doc-draft") == nil, "the draft is not")
    }

    @Test("A satellite the server does not hold yet is no reason to fail a move for ever: the pointer is copied as it is (F21)")
    func missingSatelliteDoesNotFailTheMove() async throws {
        let server = EngineTestDriver.server()
        let mac = try await F.Mac(server, name: "move-missing", deviceID: "macaaaaa")
        try await F.seed(mac)
        // src-a names a file whose satellites were never uploaded (a move during the seed's bytes pass).
        let pointer = MaintenanceFixture.body("the text", owner: "src-a", role: "text").file.value
        server.put([try F.record(.source, "src-a", [
            "type": "article", "title": "Article src-a", "url": "https://example.org/src-a", "status": "active", "addedAt": SyncJSON(F.base),
            "primaryKey": "url:example.org/src-a", "workKeys": .object(["url:example.org/src-a": .bool(true)]),
            "files": .object(["text": pointer]),
        ], zone: "Catalog", ms: F.base + 5_000)], zone: "Catalog", owner: F.user)
        EngineTestDriver.follow(server)
        try await mac.device.fetch()
        try await mac.makeSpace()

        try await mac.job().moveNotebook(F.notebook, into: F.spaceID)
        #expect(try F.inSpace(mac, .source, "src-a")?.fields["files"]?.objectValue?["text"] != nil, "the Source moved with its pointer")
        #expect(try F.inLibrary(mac, .notebook, F.notebook)?.fields["movedTo"] == .string(F.spaceID))
    }
}
