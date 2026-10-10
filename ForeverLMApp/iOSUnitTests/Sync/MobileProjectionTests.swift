import Foundation
import Testing
@testable import ForeverLM

/// The iPhone's query layer (docs/cloudkit-schema-design.md D33, §3.5.8, §5.2, §5.3, §9.7, §14.2 WP19)
/// over a fixture of new records applied to the replica: the structure kept in memory with the spaces'
/// names, redirects followed and stubs left out, paged sources and entries read from the index alone,
/// and payloads decoded only for what a page shows.
@Suite("iPhone projection", .serialized)
struct MobileProjectionTests {
    static let library = "private/Library"
    static let catalog = "private/Catalog"
    static let space = "private/Space-s1"

    static func notebook(_ id: String, _ title: String, edited: Int64, _ extra: [String: SyncJSON] = [:]) throws -> SyncEnvelope {
        var fields: [String: SyncJSON] = ["title": .string(title), "status": .string("active"), "createdAt": SyncJSON(edited), "editedAt": SyncJSON(edited)]
        fields.merge(extra) { $1 }
        return try MobileSyncFixture.envelope(.notebook, id, fields)
    }

    static func entry(_ notebook: String, _ kind: String, _ item: String, order: String, _ extra: [String: SyncJSON] = [:]) throws -> SyncEnvelope {
        var fields: [String: SyncJSON] = [
            "containerKind": .string("notebook"), "containerID": .string(notebook), "itemKind": .string(kind), "itemID": .string(item),
            "state": .string("active"), "orderKey": .string(order), "origin": .string("added"), "addedAt": SyncJSON(1_000),
        ]
        fields.merge(extra) { $1 }
        return try MobileSyncFixture.envelope(.entry, "en:\(notebook):\(kind):\(item)", fields)
    }

    static func source(_ id: String, _ title: String, added: Int64, type: String = "paper", _ extra: [String: SyncJSON] = [:]) throws -> SyncEnvelope {
        var fields: [String: SyncJSON] = [
            "primaryKey": .string("native:\(id)"), "type": .string(type), "title": .string(title), "status": .string("active"), "addedAt": SyncJSON(added),
        ]
        fields.merge(extra) { $1 }
        return try MobileSyncFixture.envelope(.source, id, fields)
    }

    static func chat(_ id: String, notebook: String, kind: String = "chat", edited: Int64) throws -> SyncEnvelope {
        try MobileSyncFixture.envelope(.chat, id, [
            "kind": .string(kind), "notebookID": .string(notebook), "title": .string(id), "status": .string("active"),
            "contextMode": .string("notebook"), "createdAt": SyncJSON(edited), "editedAt": SyncJSON(edited),
        ])
    }

    /// A library with one owned space, "Acme Lab".
    static func fixture() async throws -> (replica: MobileReplica, projection: MobileProjection) {
        let replica = try MobileReplica(path: ":memory:")
        try await MobileSyncFixture.holdSpace(replica, zoneKey: space, zoneName: "Space-s1", owned: true, name: "Acme Lab")
        let L = library, C = catalog, S = space
        try await MobileSyncFixture.apply([
            (L, try notebook("nb-a", "🧬 Alpha", edited: 300)),
            (L, try notebook("nb-b", "Beta", edited: 200, ["status": .string("archived")])),
            (L, try notebook("nb-merged", "Old", edited: 500, ["status": .string("merged"), "mergedInto": .string("nb-a"), "foldKind": .string("merge")])),
            (L, try notebook("nb-moved", "Moved", edited: 400, ["status": .string("moved"), "movedTo": .string("s1")])),
            (L, try notebook("nb-moving", "Moving, copy not here", edited: 100, ["movingTo": .string("s2")])),
            (L, try notebook("nb-moving2", "Moving, copy here", edited: 110, ["movingTo": .string("s1")])),
            (L, try MobileSyncFixture.envelope(.notebookState, "ns:nb-a", ["notebookID": .string("nb-a"), "pinned": .bool(true), "sidebarKey": .string("a1")])),
            (L, try MobileSyncFixture.envelope(.mark, "mk:hidden:nb:nb-b", ["kind": .string("hidden"), "target": .string("nb:nb-b"), "on": .bool(true), "at": SyncJSON(1)])),
            (L, try chat("ch-a", notebook: "nb-a", edited: 10)),
            (L, try chat("ch-merged", notebook: "nb-merged", edited: 20)),
            (L, try chat("ch-review", notebook: "nb-team", kind: "review", edited: 30)),
            (L, try chat("ch-moved", notebook: "nb-moved", edited: 40)),
            (L, try MobileSyncFixture.envelope(.card, "cd1", ["status": .string("kept"), "deckSourceID": .string("src-1"), "origin": .string("manual")])),
            (L, try MobileSyncFixture.envelope(.card, "cd2", ["status": .string("draft"), "deckSourceID": .string("src-2"), "origin": .string("idea")])),
            (L, try entry("nb-a", "source", "src-1", order: "a1")),
            (L, try entry("nb-a", "source", "src-2", order: "a0", ["approval": .string("pending")])),
            (L, try entry("nb-a", "source", "src-3", order: "a2", ["state": .string("removed")])),
            (L, try entry("nb-a", "source", "src-missing", order: "a3")),
            (L, try entry("nb-a", "artifact", "art-1", order: "a4")),
            (L, try entry("nb-a", "artifact", "art-missing", order: "a5")),
            (L, try MobileSyncFixture.envelope(.artifact, "art-1", ["kind": .string("doc"), "title": .string("Notes"), "notebookID": .string("nb-a"),
                                                                   "status": .string("active"), "editedAt": SyncJSON(5)])),
            (L, try MobileSyncFixture.envelope(.course, "crs1", ["title": .string("Cells 101"), "status": .string("active"), "createdAt": SyncJSON(1)])),
            (L, try MobileSyncFixture.envelope(.course, "crs2", ["title": .string("Unfollowed"), "status": .string("active"), "createdAt": SyncJSON(2)])),
            (L, try entry("nb-a", "course", "crs1", order: "a6")),
            (L, try entry("nb-a", "course", "crs2", order: "a7", ["state": .string("removed")])),
            (L, try MobileSyncFixture.envelope(.lesson, "les2", ["courseID": .string("crs1"), "orderKey": .string("b"), "kind": .string("lecture"), "title": .string("Two")])),
            (L, try MobileSyncFixture.envelope(.lesson, "les1", ["courseID": .string("crs1"), "orderKey": .string("a"), "kind": .string("lecture"), "title": .string("One")])),
            (L, try MobileSyncFixture.envelope(.setting, "review.minutes", ["key": .string("review.minutes"), "value": SyncJSON(20)])),
            (L, try MobileSyncFixture.envelope(.exchange, "x3", ["chatID": .string("ch-a"), "seq": SyncJSON(3), "createdAt": SyncJSON(3), "question": .string("third")])),
            (L, try MobileSyncFixture.envelope(.exchange, "x1", ["chatID": .string("ch-a"), "seq": SyncJSON(1), "createdAt": SyncJSON(1), "question": .string("first")])),
            (L, try MobileSyncFixture.envelope(.exchange, "x2", ["chatID": .string("ch-a"), "seq": SyncJSON(2), "createdAt": SyncJSON(2), "question": .string("second")])),
            (C, try source("src-1", "Éclair physics", added: 100)),
            (C, try source("src-2", "apple biology", added: 300, type: "article")),
            (C, try source("src-3", "Zebra stripes", added: 200)),
            (C, try source("src-old", "Archived one", added: 50, ["status": .string("archived")])),
            (C, try source("src-c1", "Chapter 2", added: 60, type: "book", ["collectionID": .string("col1"), "collectionOrder": .string("b")])),
            (C, try source("src-c2", "Chapter 1", added: 70, type: "book", ["collectionID": .string("col1"), "collectionOrder": .string("a")])),
            (S, try notebook("nb-team", "Team notebook", edited: 250)),
            (S, try notebook("nb-moved", "Moved", edited: 400)),
            (S, try notebook("nb-moving2", "Moving, copy here", edited: 110)),
            (S, try entry("nb-team", "source", "src-t", order: "a0")),
            (S, try source("src-t", "Team paper", added: 10)),
        ], to: replica)
        return (replica, MobileProjection(replica: replica))
    }

    @Test("The structure holds the notebooks to show, with their space's name and this member's state, from the index alone")
    func structure() async throws {
        let (replica, projection) = try await Self.fixture()
        replica.resetDecodeCount()
        let structure = try await projection.loadStructure()
        #expect(replica.decodedRecords == 1, "only the space's root is decoded, for its name")

        #expect(structure.notebooks.map(\.notebookID) == ["nb-moved", "nb-a", "nb-team", "nb-b", "nb-moving2", "nb-moving"],
                "stubs, and an original whose space copy has arrived, are left out; newest edit first")
        let team = try #require(structure.notebooks.first { $0.notebookID == "nb-team" })
        #expect(team.spaceName == "Acme Lab")
        #expect(team.space?.isOwned == true && team.space?.kind == "team")
        let moved = try #require(structure.notebooks.first { $0.notebookID == "nb-moved" })
        #expect(moved.zoneKey == Self.space, "a moved notebook shows as its space copy")
        #expect(structure.notebooks.first { $0.notebookID == "nb-moving2" }?.zoneKey == Self.space, "a moving one too, once the copy is here")
        let alpha = try #require(structure.notebooks.first { $0.notebookID == "nb-a" })
        #expect(alpha.pinned && alpha.sidebarKey == "a1" && alpha.spaceName == nil)
        #expect(structure.notebooks.first { $0.notebookID == "nb-b" }?.hidden == true)
        #expect(structure.notebooks.first { $0.notebookID == "nb-b" }?.isArchived == true)
        #expect(structure.spaces.map(\.name) == ["Acme Lab"])
        #expect(structure.chats.count == 4 && structure.cards.map(\.id) == ["cd1", "cd2"])
    }

    @Test("Redirects lead to the survivor and the space copy, and chats land in the notebook they resolve to")
    func redirectsAndChats() async throws {
        let (_, projection) = try await Self.fixture()
        let structure = try await projection.loadStructure()
        #expect(structure.resolve("nb-merged")?.notebookID == "nb-a")
        #expect(structure.resolve("nb-moved")?.zoneKey == Self.space)
        #expect(structure.resolve("nb-unknown") == nil)

        let alpha = try #require(structure.resolve("nb-a"))
        #expect(structure.chats(in: alpha).map(\.chatID) == ["ch-merged", "ch-a"], "a chat filed in a merged notebook shows in the survivor")
        let team = try #require(structure.notebooks.first { $0.notebookID == "nb-team" })
        #expect(structure.chats(in: team).map(\.chatID) == ["ch-review"], "a private review of a space notebook stays in Library and shows there")
        let moved = try #require(structure.resolve("nb-moved"))
        #expect(structure.chats(in: moved).map(\.chatID) == ["ch-moved"])
    }

    @Test("Sources page from the index by date or folded title, with type, status and collection filters")
    func sourcesPaged() async throws {
        let (replica, projection) = try await Self.fixture()
        replica.resetDecodeCount()
        let newest = try await projection.sources(page: .first(2))
        #expect(newest.map(\.id) == ["src-2", "src-3"])
        #expect(try await projection.sources(page: MobileProjection.Page.first(2).next).map(\.id) == ["src-1", "src-c2"])
        #expect(try await projection.sources(order: .title, page: .first(3)).map(\.title) == ["apple biology", "Chapter 1", "Chapter 2"])
        #expect(try await projection.sources(type: "paper").map(\.id) == ["src-3", "src-1"])
        #expect(try await projection.sources(status: "archived").map(\.id) == ["src-old"])
        #expect(try await projection.sourceCount() == 5)
        #expect(try await projection.sources(inCollection: "col1").map(\.id) == ["src-c2", "src-c1"])
        #expect(try await projection.sources(in: Self.space).map(\.title) == ["Team paper"])
        #expect(try await projection.sources(order: .title).first { $0.id == "src-1" }?.title == "Éclair physics")
        #expect(replica.decodedRecords == 0)
    }

    @Test("A notebook's entries come in study order with their sources; removed, missing and unheld items are left out")
    func entries() async throws {
        let (replica, projection) = try await Self.fixture()
        let structure = try await projection.loadStructure()
        let alpha = try #require(structure.resolve("nb-a"))
        replica.resetDecodeCount()
        let rows = try await projection.entries(of: alpha)
        #expect(rows.map(\.itemID) == ["src-2", "src-1", "art-1", "crs1"])
        #expect(rows.first?.isApproved == false && rows.first?.approval == "pending")
        #expect(rows.first?.source?.title == "apple biology")
        #expect(rows[2].source == nil && rows[2].itemKind == "artifact")
        #expect(rows.last?.itemKind == "course", "a followed course is the notebook's Entry, not its child")
        #expect(rows.allSatisfy { $0.stateStamp.flatMap(SyncStamp.init) != nil })
        #expect(try await projection.entries(of: alpha, includeRemoved: true).map(\.itemID) == ["src-2", "src-1", "src-3", "art-1", "crs1", "crs2"])
        #expect(try await projection.entries(of: alpha, page: MobileProjection.Page(offset: 1, limit: 1)).map(\.itemID) == ["src-1"])

        let team = try #require(structure.notebooks.first { $0.notebookID == "nb-team" })
        let teamRows = try await projection.entries(of: team)
        #expect(teamRows.map { $0.source?.title } == ["Team paper"], "a space notebook's sources are the space's own")
        #expect(replica.decodedRecords == 0)

        #expect(try await projection.artifacts(of: alpha).map(\.title) == ["Notes"])
        #expect(try await projection.courses(of: alpha).map(\.id) == ["crs1"], "the courses it follows; an unfollowed one is not listed")
        #expect(try await projection.courses().map(\.id) == ["crs2", "crs1"], "every course lives in the library")
        #expect(try await projection.courses(of: team).isEmpty)
        #expect(try await projection.lessons(ofCourse: "crs1").map(\.title) == ["One", "Two"])
    }

    @Test("A chat's exchanges page in display order, and only the page is decoded")
    func exchangesPaged() async throws {
        let (replica, projection) = try await Self.fixture()
        replica.resetDecodeCount()
        let page = try await projection.exchanges(ofChat: "ch-a", zoneKey: Self.library, page: .first(2))
        #expect(page.map { $0.fields["question"]?.stringValue } == ["first", "second"])
        #expect(replica.decodedRecords == 2)
        #expect(try await projection.exchanges(ofChat: "ch-a", zoneKey: Self.library, page: MobileProjection.Page.first(2).next).map(\.id) == ["x3"])
    }

    @Test("Settings, the library's seed and one record read as the phone holds them")
    func recordsAndSettings() async throws {
        let (replica, projection) = try await Self.fixture()
        #expect(try await projection.setting("review.minutes") == SyncJSON(20))
        #expect(try await projection.setting("missing") == nil)
        #expect(try await projection.librarySeed() == nil, "no personal root held yet")
        let root = try MobileSyncFixture.rootRecord(["kind": .string("personal"), "seed": .object(["state": .string("complete"), "metadataCompleteAt": SyncJSON(42)])],
                                                    salt: MobileSyncFixture.librarySalt, in: PrivateSyncZones.library)
        try await replica.perform { try $0.replica.upsertRecord(ReplicaRecord(root, zoneKey: Self.library, wireID: SyncSchema.rootRecordName, seenPass: nil)) }
        #expect(try await projection.librarySeed() == MobileProjection.LibrarySeed(state: "complete", metadataCompleteAt: 42))
        #expect(try await projection.envelope(.notebook, id: "nb-a", zoneKey: Self.library)?.fields["title"] == .string("🧬 Alpha"))
        #expect(try await projection.envelope(.notebook, id: "nb-none", zoneKey: Self.library) == nil)
    }

    @Test("A space that went leaves the structure at once, and the sweep drops its rows")
    func goneSpace() async throws {
        let (replica, projection) = try await Self.fixture()
        try await replica.perform { try $0.replica.setEngineState(SpaceSync.StateScope.gone(Self.space), Data("{\"reason\":\"left\"}".utf8)) }
        let structure = try await projection.loadStructure()
        #expect(structure.spaces.isEmpty)
        #expect(!structure.notebooks.contains { $0.zoneKey == Self.space })
        #expect(structure.notebooks.first { $0.notebookID == "nb-moving2" }?.zoneKey == Self.library,
                "with its space gone, an original that was moving shows again")
        let removed = try await replica.read { try $0.sweepIndexIfNeeded() }
        #expect(removed == 5)
        // A stray row stays until what the sweep depends on moves again.
        try await replica.read { try $0.connection.execute("INSERT INTO m_cards (zone_key, id) VALUES ('private/Library', 'stray')") }
        #expect(try await replica.read { try $0.sweepIndexIfNeeded() } == 0, "the sweep runs again only when a stop or a gone space moves")
        try await replica.perform { try $0.replica.setEngineState(ReplicaStore.EngineScope.privateStop, Data("signedOut".utf8)) }
        #expect(try await replica.read { try $0.sweepIndexIfNeeded() } == 1)
        #expect(try await replica.read { try $0.connection.scalarInteger("SELECT COUNT(*) FROM m_notebooks WHERE zone_key = ?", [.text(Self.space)]) } == 0)
    }
}
