import Foundation
import Testing
@testable import ForeverLM

/// Notebooks under generation 2 (docs/cloudkit-schema-design.md D16, D52, §3.5.6, §3.5.8, §3.5.13, §3.5.15,
/// §3.5.20, §5.6, §14.2 WP19b): a notebook's own sources from its Entries with their approval, this
/// member's ticks read from NotebookState and held only while their stamps are the Entry's, a listed
/// notebook reaching the chats only once this member ticks it and never the Studio, and the chats and
/// Docs each notebook lists.
@Suite("iPhone notebook read models", .serialized)
struct MobileNotebookModelTests {
    typealias F = MobileReadModelFixture
    static let later = MobileSyncFixture.stampMilliseconds + 5_000

    struct Library {
        let replica: MobileReplica
        let projection: MobileProjection
        let entries: [String: SyncEnvelope]
    }

    /// Notebook A (own sources a1, a2, a pending a3, a rejected a4, a removed a5, an archived a6, a hidden
    /// a7) lists notebook B ("Uses context from") and a merged notebook M that was folded into C.
    static func fixture(state: [String: SyncJSON]? = nil) async throws -> Library {
        let replica = try await F.replica()
        let L = F.library, C = F.catalog, S = F.space
        var entries: [String: SyncEnvelope] = [:]
        func entry(_ container: String, _ item: String, order: String, _ extra: [String: SyncJSON] = [:], zone: String = L) throws -> (String, SyncEnvelope) {
            let envelope = try F.entry(container, "source", item, order: order, extra)
            entries["\(container):\(item)"] = envelope
            return (zone, envelope)
        }
        var records: [(zoneKey: String, envelope: SyncEnvelope)] = [
            (L, try F.notebook("nb-a", "🧬 Alpha", edited: 300, [
                "instructions": .string("Be terse"), "summary": .string("Cells"),
                "repository": .object(["url": .string("https://github.com/ForeverLM-HQ/cells.git")]),
                "relatedNotebookIDs": F.set(["nb-b", "nb-m"]),
            ])),
            (L, try F.notebook("nb-b", "Beta", edited: 200)),
            (L, try F.notebook("nb-c", "Gamma", edited: 100)),
            (L, try F.notebook("nb-m", "Merged", edited: 50, ["status": .string("merged"), "mergedInto": .string("nb-c"), "foldKind": .string("merge")])),
            (L, try F.notebook("nb-archived", "Old", edited: 40, ["status": .string("archived")])),
            (L, try F.notebook("nb-hidden", "Hidden", edited: 30)),
            (L, try F.mark("hidden", "nb:nb-hidden")),
            (S, try F.notebook("nb-team", "Team notebook", edited: 250)),
            (S, try MobileSyncFixture.envelope(.entry, "en:nb-team:source:t1", [
                "containerKind": .string("notebook"), "containerID": .string("nb-team"), "itemKind": .string("source"), "itemID": .string("t1"),
                "state": .string("active"), "orderKey": .string("a"), "origin": .string("added"), "addedAt": SyncJSON(1),
            ], salt: MobileSyncFixture.spaceSalt)),
            (S, try MobileSyncFixture.envelope(.source, "t1", ["primaryKey": .string("native:t1"), "type": .string("paper"), "title": .string("Team paper"),
                                                                "status": .string("active"), "addedAt": SyncJSON(1)], salt: MobileSyncFixture.spaceSalt)),
            try entry("nb-a", "a2", order: "a2"),
            try entry("nb-a", "a1", order: "a1"),
            try entry("nb-a", "a3", order: "a3", ["approval": .string("pending")]),
            try entry("nb-a", "a4", order: "a4", ["approval": .string("rejected")]),
            try entry("nb-a", "a5", order: "a5", ["state": .string("removed")]),
            try entry("nb-a", "a6", order: "a6"),
            try entry("nb-a", "a7", order: "a7"),
            try entry("nb-a", "a-missing", order: "a8"),
            try entry("nb-b", "b1", order: "b1"),
            try entry("nb-b", "a1", order: "b0"),
            try entry("nb-c", "c1", order: "c1"),
            (L, try MobileSyncFixture.envelope(.course, "crs1", ["title": .string("Cells 101"), "status": .string("active"), "createdAt": SyncJSON(1)])),
            (L, try MobileSyncFixture.envelope(.course, "crs2", ["title": .string("Unfollowed"), "status": .string("active"), "createdAt": SyncJSON(2)])),
            (L, try F.entry("nb-a", "course", "crs1", order: "z1")),
            (L, try F.entry("nb-a", "course", "crs2", order: "z0", ["state": .string("removed")])),
            (L, try F.entry("nb-b", "course", "crs1", order: "z0")),
        ]
        for id in ["a1", "a2", "a3", "a4", "a5", "a7", "b1", "c1"] {
            records.append((C, try F.source(id, "Source \(id)", added: 1_000)))
        }
        records.append((C, try F.source("a6", "Source a6", added: 1_000, ["status": .string("archived")])))
        records.append((L, try F.mark("hidden", "src:a7")))
        if let state {
            records.append((L, try MobileSyncFixture.envelope(.notebookState, "ns:nb-a", state.merging(["notebookID": .string("nb-a")]) { $1 })))
        }
        try await MobileSyncFixture.apply(records, to: replica)
        return Library(replica: replica, projection: MobileProjection(replica: replica), entries: entries)
    }

    static func notebook(_ id: String, in snapshot: MobileReadModels.Snapshot) throws -> MobileCloudNotebook {
        try #require(snapshot.notebooks.first { $0.id == id })
    }

    @Test("A notebook lists its own approved active sources in study order; pending, rejected and removed ones never")
    func entriesWithApproval() async throws {
        let library = try await Self.fixture()
        let snapshot = try await MobileReadModels.snapshot(library.projection)
        let alpha = try Self.notebook("nb-a", in: snapshot)
        #expect(alpha.sourceIDs == ["a1", "a2"], "approved, active and listed here, in order; archived and hidden ones and one not held stay out")
        #expect(alpha.poolSourceIDs == ["a1", "a2", "a6", "a7", "a-missing"], "the pool the ticks name keeps every approved active id")
        #expect(alpha.approvedSourceCount == 5)
        #expect(alpha.contextSourceIDs == alpha.sourceIDs)
        #expect(alpha.title == "🧬 Alpha" && alpha.instructions == "Be terse" && alpha.summary == "Cells")
        #expect(alpha.repository == "ForeverLM-HQ/cells")
        #expect(alpha.linkedCourseIDs == ["crs1"], "the courses it follows; one it stopped following is not listed")
        #expect(try Self.notebook("nb-b", in: snapshot).linkedCourseIDs == ["crs1"], "a course lives in no notebook, so two can follow it")
        #expect(alpha.relatedNotebookIDs == ["nb-b", "nb-c"], "a link to a merged notebook leads to its survivor")
        #expect(alpha.contextNotebooks.map(\.id) == ["nb-b", "nb-c"])
        #expect(alpha.contextNotebooks.first?.sourceIDs == ["a1", "b1"])

        let ids = snapshot.notebooks.map(\.id)
        #expect(ids == ["nb-a", "nb-team", "nb-b", "nb-c"], "newest first; archived, hidden and merged notebooks left out")
        #expect(try Self.notebook("nb-team", in: snapshot).sourceIDs == ["t1"], "a space notebook's sources are the space's own")
    }

    @Test("An untick holds while its stamps are the Entry's; a re-add ticks it again with no write to NotebookState")
    func ticks() async throws {
        let first = try await Self.fixture()
        let a1 = try #require(first.entries["nb-a:a1"])
        let a2 = try #require(first.entries["nb-a:a2"])
        let state: [String: SyncJSON] = ["excluded": .object([
            "a1": .string(try F.stampPair(a1)),
            "a2": .string("v0000000000001.0001.otheraaa|-"),
        ])]
        let library = try await Self.fixture(state: state)
        var snapshot = try await MobileReadModels.snapshot(library.projection)
        var selection = try #require(snapshot.selections["nb-a"])
        #expect(selection.excluded == ["a1"], "an untick naming stamps the Entry no longer has is read past")
        var alpha = try Self.notebook("nb-a", in: snapshot)
        #expect(MobileNotebookChatSelection.chatSourceIDs(of: alpha, selection: selection) == ["a2", "a6", "a7", "a-missing"])
        _ = a2

        // Someone removes a1 and adds it back: its state stamp moves, so it is ticked again.
        try await MobileSyncFixture.apply([(F.library, try F.entry("nb-a", "source", "a1", order: "a1", at: Self.later, ["state": .string("active")]))],
                                          to: library.replica)
        snapshot = try await MobileReadModels.snapshot(library.projection)
        selection = try #require(snapshot.selections["nb-a"])
        #expect(selection.excluded.isEmpty)
        alpha = try Self.notebook("nb-a", in: snapshot)
        #expect(MobileNotebookChatSelection.chatSourceIDs(of: alpha, selection: selection).contains("a1"))
    }

    @Test("A listed notebook reaches the chats only once this member ticks it, and never the Studio (D52)")
    func contextNotebooks() async throws {
        let unticked = try await Self.fixture()
        var snapshot = try await MobileReadModels.snapshot(unticked.projection)
        var alpha = try Self.notebook("nb-a", in: snapshot)
        var selection = try #require(snapshot.selections["nb-a"])
        #expect(selection.contextNotebookIDs.isEmpty, "a link made before the tick starts unticked")
        #expect(!MobileNotebookChatSelection.chatSourceIDs(of: alpha, selection: selection).contains("b1"))

        let ticked = try await Self.fixture(state: ["contextNotebooks": F.set(["nb-b", "nb-m", "nb-unlisted"])])
        snapshot = try await MobileReadModels.snapshot(ticked.projection)
        alpha = try Self.notebook("nb-a", in: snapshot)
        selection = try #require(snapshot.selections["nb-a"])
        #expect(selection.contextNotebookIDs == ["nb-b", "nb-c"], "ticks are resolved, and only listed notebooks count")
        let chat = MobileNotebookChatSelection.chatSourceIDs(of: alpha, selection: selection)
        #expect(chat.contains("b1") && chat.contains("c1"), "the ticked notebooks' sources reach the chats")
        #expect(!alpha.sourceIDs.contains("b1") && !alpha.sourceIDs.contains("c1"), "the Studio reads the notebook's own sources only")

        // The rule the Mac, the web and the hosted MCP run says the same of the same records.
        let records = try await ticked.replica.read { replica -> [SyncNotebookChatContext.Entry] in
            var rows: [SyncNotebookChatContext.Entry] = []
            try replica.connection.query("SELECT zone_key, record_type, wire_id FROM ck_records WHERE record_type = 'Entry'", []) { row in
                if let record = try replica.replica.record(zoneKey: row.text(0) ?? "", recordType: "Entry", wireID: row.text(2) ?? ""),
                   let envelope = replica.decode(record.payload), let entry = SyncNotebookChatContext.Entry(envelope) { rows.append(entry) }
            }
            return rows
        }
        let studio = SyncNotebookChatContext.studioSourceIDs(notebookID: "nb-a", entries: records, excluded: [:])
        #expect(!studio.contains("b1") && !studio.contains("c1"))
        let chatRule = SyncNotebookChatContext.chatSourceIDs(notebookID: "nb-a", contextNotebookIDs: ["nb-b", "nb-c"], entries: records, excluded: [:])
        #expect(Set(chatRule).isSuperset(of: ["b1", "c1", "a1", "a2"]))
    }

    @Test("Each notebook lists its chats newest first: hidden and empty ones left out, a private review of a space notebook under it")
    func chats() async throws {
        let library = try await Self.fixture()
        try await MobileSyncFixture.apply([
            (F.library, try F.chat("ch-1", notebook: "nb-a", title: "First", edited: 10)),
            (F.library, try F.chat("ch-2", notebook: "nb-m", title: "Filed in the merged one", edited: 20, ["model": .object(["provider": .string("openrouter"), "id": .string("m1")])])),
            (F.library, try F.chat("ch-empty", notebook: "nb-a", edited: 30)),
            (F.library, try F.chat("ch-hidden", notebook: "nb-a", edited: 40)),
            (F.library, try F.mark("hidden", "cht:ch-hidden")),
            (F.library, try F.chat("ch-review", notebook: "nb-team", kind: "review", edited: 50)),
            (F.library, try F.chat("ch-walk", notebook: "nb-a", kind: "walkthrough", edited: 5, ["contextMode": .string("explicit"), "contextSourceIDs": F.set(["a2", "a1"])])),
            (F.library, try F.exchange("x1", chat: "ch-1", seq: 1, question: "Why?", reply: "Because.")),
            (F.library, try F.exchange("x2", chat: "ch-2", seq: 1, question: "How?")),
            (F.library, try F.exchange("x3", chat: "ch-hidden", seq: 1, question: "Hidden")),
            (F.library, try F.exchange("x4", chat: "ch-review", seq: 1, question: "Q", answer: "A")),
            (F.library, try F.exchange("x5", chat: "ch-walk", seq: 1, question: "Step")),
        ], to: library.replica)
        let snapshot = try await MobileReadModels.snapshot(library.projection)
        #expect(snapshot.notebookChats["nb-a"]?.map(\.id) == ["ch-1", "ch-walk"])
        #expect(snapshot.notebookChats["nb-c"]?.map(\.id) == ["ch-2"], "a chat filed in a merged notebook lists under its survivor")
        #expect(snapshot.notebookChats["nb-c"]?.first?.modelID == "m1")
        let review = try #require(snapshot.notebookChats["nb-team"]?.first)
        #expect(review.id == "ch-review" && review.shape == .tutoredReview && review.kind == .text)
        let walk = try #require(snapshot.notebookChats["nb-a"]?.last)
        #expect(walk.shape == .walkthrough && walk.sourceIDs == ["a1", "a2"])
        #expect(snapshot.chatZones["ch-review"] == F.library)

        let turns = try #require(try await MobileReadModels.transcript(chatID: "ch-1", zoneKey: F.library, projection: library.projection))
        #expect(turns.map(\.content) == ["Why?", "Because."])
        #expect(try await MobileReadModels.transcript(chatID: "ch-none", zoneKey: F.library, projection: library.projection) == nil)
    }

    @Test("An audio overview's resume point is this member's ReadingState.listen, when it was saved against this narration")
    func narrationPosition() throws {
        let listen: SyncJSON = .object(["globalTime": .number(42.5), "contentSignature": .string("sig-1"), "at": SyncJSON(1)])
        #expect(MobileReadModels.listenPosition(listen, contentSignature: "sig-1") == 42.5)
        #expect(MobileReadModels.listenPosition(listen, contentSignature: "sig-2") == nil, "a position on other text is not this narration's")
        #expect(MobileReadModels.listenPosition(.object(["globalTime": .number(10)]), contentSignature: "sig-2") == 10, "one that names no text counts")
        #expect(MobileReadModels.listenPosition(.object(["globalTime": .number(0)]), contentSignature: "sig-1") == nil)
        #expect(MobileReadModels.listenPosition(nil, contentSignature: "sig-1") == nil)

        let manifest = MobileSyncFixture.fileRef(owner: "ao-carrier", role: "audio.nova", bytes: Data("{}".utf8))
        let source = try MobileSyncFixture.envelope(.source, "ao-carrier", [
            "files": .object(["pdf": MobileSyncFixture.fileRef(owner: "ao-carrier", role: "pdf", bytes: Data("x".utf8)).value, "audio.nova": manifest.value]),
        ])
        #expect(MobileReadModels.narrationFile(of: source)?.role == "audio.nova")
        #expect(MobileReadModels.narrationFile(of: try MobileSyncFixture.envelope(.source, "plain", ["title": .string("No audio")])) == nil)
    }

    @Test("A notebook's Studio lists its Docs, animations and audio overviews; Notes, drafts, archived and hidden ones stay out")
    func artifacts() async throws {
        let library = try await Self.fixture()
        func artifact(_ id: String, kind: String, _ extra: [String: SyncJSON] = [:]) throws -> SyncEnvelope {
            var fields: [String: SyncJSON] = ["kind": .string(kind), "title": .string(id), "notebookID": .string("nb-a"),
                                              "status": .string("active"), "createdAt": SyncJSON(1_000), "editedAt": SyncJSON(2_000)]
            fields.merge(extra) { $1 }
            return try MobileSyncFixture.envelope(.artifact, id, fields)
        }
        let body = MobileSyncFixture.fileRef(owner: "doc-1", role: "body", bytes: Data("# Hi".utf8)).value
        try await MobileSyncFixture.apply([
            (F.library, try artifact("doc-1", kind: "doc", ["linkedNotebookIDs": F.set(["nb-b"]), "sourceIDs": F.set(["a1"]), "body": body])),
            (F.library, try artifact("anim-1", kind: "animation")),
            (F.library, try artifact("ao-1", kind: "audioOverview")),
            (F.library, try artifact("notes:nb-a", kind: "notes")),
            (F.library, try artifact("draft:doc-9", kind: "doc")),
            (F.library, try artifact("doc-old", kind: "doc", ["status": .string("archived")])),
            (F.library, try artifact("doc-hidden", kind: "doc")),
            (F.library, try F.mark("hidden", "art:doc-hidden")),
            (F.space, try MobileSyncFixture.envelope(.artifact, "doc-team", ["kind": .string("doc"), "title": .string("Team Doc"), "notebookID": .string("nb-team"),
                                                                              "status": .string("active"), "createdAt": SyncJSON(1)], salt: MobileSyncFixture.spaceSalt)),
        ], to: library.replica)
        let snapshot = try await MobileReadModels.snapshot(library.projection)
        #expect(snapshot.artifacts.map(\.id) == ["anim-1", "ao-1", "doc-1", "doc-team"])
        let doc = try #require(snapshot.artifacts.first { $0.id == "doc-1" })
        #expect(doc.kind == nil && doc.isDoc && doc.belongs(toNotebookID: "nb-a") && doc.belongs(toNotebookID: "nb-b"))
        #expect(doc.sourceIDs == ["a1"] && doc.bodyRevision == "00")
        #expect(doc.createdAt == Date(timeIntervalSince1970: 1) && doc.updatedAt == Date(timeIntervalSince1970: 2))
        #expect(snapshot.artifacts.first { $0.id == "anim-1" }?.kind == MobileCloudArtifact.animationKind)
        #expect(snapshot.artifacts.first { $0.id == "doc-team" }?.teamID == "s1")
        #expect(snapshot.audioOverviews.map(\.id) == ["ao-1"])
        #expect(snapshot.audioOverviews.first?.notebookIDs == ["nb-a"])
        #expect(snapshot.audioOverviews.first?.carrierSourceID == MobileCloudMutationService.audioOverviewSourceID(artifactID: "ao-1"))
    }
}
