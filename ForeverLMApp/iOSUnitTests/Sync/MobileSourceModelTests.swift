import Foundation
import Testing
@testable import ForeverLM

/// The library's sources under generation 2 (docs/cloudkit-schema-design.md §3.5.4, §3.5.5, §3.5.18,
/// §3.5.19, §14.2 WP19b): the screens' `MobileCloudSource` rows read from the index, one per id, with this
/// member's reading state and marks, and the collections' hidden sets, without decoding a source.
@Suite("iPhone source read models", .serialized)
struct MobileSourceModelTests {
    typealias F = MobileReadModelFixture

    static func fixture() async throws -> MobileReplica {
        let replica = try await F.replica()
        let L = F.library, C = F.catalog, S = F.space
        let audio = MobileSyncFixture.fileRef(owner: "src-1", role: "audio.alloy", bytes: Data("manifest".utf8)).value
        try await MobileSyncFixture.apply([
            (C, try F.source("src-1", "Mitochondrial fission", added: 1_700_000_000_000, [
                "authors": .array([.string("Picard M"), .string("Shirihai O")]), "venue": .string("Nature Metabolism"),
                "publishedAt": SyncJSON(Int64(1_704_067_200_000)), "doi": .string("10.1/abc"), "url": .string("https://www.nature.com/x"),
                "metrics": .object(["wordCount": SyncJSON(4_200)]), "files": .object(["audio.alloy": audio]),
                "ingest": .object(["ord": .array([SyncJSON(0), SyncJSON(4)]), "state": .string("ready")]),
            ])),
            (C, try F.source("src-q", "Queued link", added: 1_700_000_100_000, type: "article", [
                "url": .string("https://example.org/post"), "ingest": .object(["ord": .array([SyncJSON(0), SyncJSON(2)]), "state": .string("fetching")]),
            ])),
            (C, try F.source("src-p", "Paywalled", added: 1_700_000_200_000, [
                "ingest": .object(["ord": .array([SyncJSON(0), SyncJSON(3)]), "state": .string("paywalled")]),
            ])),
            (C, try F.source("src-e", "Broken", added: 1_700_000_300_000, [
                "ingest": .object(["ord": .array([SyncJSON(0), SyncJSON(3)]), "state": .string("error")]),
            ])),
            (C, try F.source("src-old", "Archived", added: 1_600_000_000_000, ["status": .string("archived")])),
            (C, try F.source("src-loser", "Duplicate", added: 1_600_000_000_001, ["mergedInto": .string("src-1")])),
            (C, try F.source("src-c2", "Chapter 2", added: 1_650_000_000_000, type: "book", ["collectionID": .string("bk1"), "collectionOrder": .string("b")])),
            (C, try F.source("src-c1", "Chapter 1", added: 1_650_000_000_001, type: "book", ["collectionID": .string("bk1"), "collectionOrder": .string("a")])),
            (C, try MobileSyncFixture.envelope(.collection, "bk1", ["kind": .string("book"), "externalKey": .string("isbn"), "title": .string("The Cell"),
                                                                    "author": .string("Alberts"), "status": .string("active"), "addedAt": SyncJSON(1)])),
            (C, try MobileSyncFixture.envelope(.collection, "show1", ["kind": .string("podcastShow"), "externalKey": .string("feed"),
                                                                      "title": .string("Huberman Lab"), "status": .string("active"), "addedAt": SyncJSON(1)])),
            (C, try MobileSyncFixture.envelope(.collection, "mtg1", ["kind": .string("meetingSeries"), "externalKey": .string("zoom"),
                                                                     "title": .string("Standup"), "status": .string("active"), "addedAt": SyncJSON(1)])),
            (C, try F.source("src-ep1", "Episode 1", added: 1_650_000_000_002, type: "podcast", ["venue": .string("Huberman Lab"), "collectionID": .string("show1")])),
            (C, try F.source("src-ep2", "Episode 2", added: 1_650_000_000_003, type: "podcast", ["venue": .string("Huberman Lab"), "collectionID": .string("show1")])),
            (C, try F.source("src-m1", "Monday standup", added: 1_650_000_000_004, type: "meeting", ["collectionID": .string("mtg1")])),
            (C, try F.source("src-shared", "Held twice", added: 1_650_000_000_005, ["venue": .string("Mine")])),
            (S, try MobileSyncFixture.envelope(.source, "src-shared", ["primaryKey": .string("native:src-shared"), "type": .string("paper"),
                                                                        "title": .string("Held twice"), "venue": .string("The team's"),
                                                                        "status": .string("active"), "addedAt": SyncJSON(Int64(1_750_000_000_000))],
                                                salt: MobileSyncFixture.spaceSalt)),
            (S, try MobileSyncFixture.envelope(.source, "src-team", ["primaryKey": .string("native:src-team"), "type": .string("paper"),
                                                                      "title": .string("Team only"), "status": .string("active"), "addedAt": SyncJSON(Int64(1_650_000_000_006))],
                                                salt: MobileSyncFixture.spaceSalt)),
            (L, try MobileSyncFixture.envelope(.readingState, "rs:src-1", ["targetKind": .string("source"), "targetID": .string("src-1"),
                                                                            "readAt": SyncJSON(Int64(1_759_000_000_000))])),
            (L, try F.mark("hidden", "src:src-e")),
            (L, try F.mark("hidden", "col:show1")),
            (L, try F.mark("visibleOverride", "src:src-ep2")),
            (L, try F.mark("hidden", "col:mtg1")),
            (L, try F.mark("hidden", "src:src-q", on: false)),
        ], to: replica)
        return replica
    }

    @Test("Each held source becomes the screens' row from its index columns alone, once per id, merged losers left out")
    func rows() async throws {
        let replica = try await Self.fixture()
        replica.resetDecodeCount()
        let snapshot = try await MobileReadModels.snapshot(MobileProjection(replica: replica))
        #expect(replica.decodedRecords == 1, "only the space's root is decoded, for its name")

        let ids = snapshot.sources.map(\.id)
        #expect(!ids.contains("src-loser"), "a merged duplicate is a redirect, never a row")
        #expect(ids.filter { $0 == "src-shared" }.count == 1)
        #expect(ids.contains("src-team"), "a source only a space holds is listed too")
        #expect(ids == snapshot.sources.sorted { $0.dateAdded > $1.dateAdded }.map(\.id), "newest first, as generation 1 lists them")

        let byID = Dictionary(uniqueKeysWithValues: snapshot.sources.map { ($0.id, $0) })
        let paper = try #require(byID["src-1"])
        #expect(paper.title == "Mitochondrial fission")
        #expect(paper.sourceType == "paper")
        #expect(paper.subtitle == "Nature Metabolism")
        #expect(paper.author == "Picard M, Shirihai O")
        #expect(paper.journal == "Nature Metabolism")
        #expect(paper.publishedYear == "2024")
        #expect(paper.citationSubtitle == "Picard M, Shirihai O · Nature Metabolism · 2024")
        #expect(paper.wordCount == 4_200)
        #expect(paper.doi == "10.1/abc")
        #expect(paper.url == "https://www.nature.com/x")
        #expect(paper.hasAudio, "a narration satellite in files.audio.* means it has audio")
        #expect(paper.state == "ready" && !paper.isPaywalled && !paper.isArchived && !paper.isHidden)
        #expect(paper.dateAdded == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(paper.readAt == Date(timeIntervalSince1970: 1_759_000_000), "this member's ReadingState says it was read")
        #expect(byID["src-shared"]?.subtitle == "Mine", "the learner's own copy wins over a space's")

        let queued = try #require(byID["src-q"])
        #expect(queued.state == "queued" && queued.subtitle == "example.org" && !queued.hasAudio && queued.readAt == nil)
        #expect(!queued.isHidden, "a hide turned off again shows")
        #expect(byID["src-p"]?.isPaywalled == true && byID["src-p"]?.state == "ready")
        #expect(byID["src-e"]?.state == "error" && byID["src-e"]?.isHidden == true)
        #expect(byID["src-old"]?.isArchived == true)
        #expect(byID["src-c1"]?.courseSortIndex == 0 && byID["src-c2"]?.courseSortIndex == 1, "a book's chapters in their collection order")
        #expect(byID["src-c1"]?.parentGroup == "bk1")
    }

    @Test("Collections give books their titles and hide what this member hid, keeping an episode shown by its override")
    func collections() async throws {
        let replica = try await Self.fixture()
        let snapshot = try await MobileReadModels.snapshot(MobileProjection(replica: replica))
        let collections = snapshot.collections
        #expect(collections.booksByID["bk1"] == MobileCloudBook(id: "bk1", title: "The Cell", author: "Alberts", recordName: "bk1"), "the cover's handle is the Collection's id")
        #expect(collections.hiddenPodcastShowNames == ["Huberman Lab"])
        #expect(collections.hiddenMeetingGroupIDs == ["mtg1"])
        let byID = Dictionary(uniqueKeysWithValues: snapshot.sources.map { ($0.id, $0) })
        #expect(MobileSourceVisibility.isHidden(try #require(byID["src-ep1"]), collections: collections))
        #expect(!MobileSourceVisibility.isHidden(try #require(byID["src-ep2"]), collections: collections), "a visible override keeps the episode")
        #expect(MobileSourceVisibility.isHidden(try #require(byID["src-m1"]), collections: collections))
        #expect(!MobileSourceVisibility.isHidden(try #require(byID["src-1"]), collections: collections))
        #expect(collections.groupTitle(of: try #require(byID["src-c1"])) == "The Cell")
    }

    @Test("The Reader's text is the source's text satellite, fetched by name from Content, or from a space for a space's copy")
    func readerText() async throws {
        let server = FakeCloudKit()
        try MobileSyncFixture.makeLibrary(server, owner: "u1")
        try MobileSyncFixture.makeSpace(server, owner: "u1", name: "Acme Lab")
        let phone = try MobileTestDevice(server, user: "u1")
        _ = try await phone.bootstrap()
        try await MobileSyncFixture.holdSpace(phone.replica, zoneKey: F.space, zoneName: "Space-s1", owned: true, name: "Acme Lab")
        var pacing = SyncPacerState.Configuration()
        pacing.capacity = 1_000_000
        pacing.refillPerSecond = 1_000_000
        let pacer = SyncPacer(configuration: pacing)
        let blobs = BlobStore(transport: phone.transport, store: phone.replica, deviceID: phone.deviceID, pacer: { _ in pacer })

        let personal = try #require(try await phone.replica.perform { try BlobZone.resolve(zoneKey: PrivateSyncZones.key(PrivateSyncZones.content), in: $0) })
        let team = try #require(try await phone.replica.perform { try BlobZone.resolve(zoneKey: F.space, in: $0) })
        let mine = try await blobs.upload(Data("Mitochondria divide by fission.".utf8), owner: "src-1", ownerType: .source, role: "text",
                                          mime: "text/plain", encoding: .gzip, into: personal)
        let theirs = try await blobs.upload(Data("The team's own text.".utf8), owner: "src-team", ownerType: .source, role: "text",
                                            mime: "text/plain", encoding: .gzip, into: team)
        try await MobileSyncFixture.apply([
            (F.catalog, try F.source("src-1", "Fission", added: 1, ["files": .object(["text": mine.value])])),
            (F.space, try MobileSyncFixture.envelope(.source, "src-team", ["primaryKey": .string("native:src-team"), "type": .string("paper"),
                                                                            "title": .string("Team only"), "status": .string("active"), "addedAt": SyncJSON(1),
                                                                            "files": .object(["text": theirs.value])], salt: MobileSyncFixture.spaceSalt)),
            (F.catalog, try F.source("src-none", "No text yet", added: 1)),
        ], to: phone.replica)

        let text = try await MobileReadModels.sourceSatellite("src-1", matching: { $0 == "text" }, projection: phone.projection, blobs: blobs)
        #expect(text.map { String(decoding: $0, as: UTF8.self) } == "Mitochondria divide by fission.")
        let team1 = try await MobileReadModels.sourceSatellite("src-team", matching: { $0 == "text" }, projection: phone.projection, blobs: blobs)
        #expect(team1.map { String(decoding: $0, as: UTF8.self) } == "The team's own text.")
        #expect(try await MobileReadModels.sourceSatellite("src-none", matching: { $0 == "text" }, projection: phone.projection, blobs: blobs) == nil)
        #expect(MobileReadModels.satelliteZoneKey(forSourceIn: F.catalog) == "private/Content")
    }

    @Test("Generation 1's states from the ingest's: fetching is queued, paywalled is ready and marked")
    func ingestStates() {
        #expect(MobileReadModels.state(ofIngest: "queued") == "queued")
        #expect(MobileReadModels.state(ofIngest: "fetching") == "queued")
        #expect(MobileReadModels.state(ofIngest: "error") == "error")
        #expect(MobileReadModels.state(ofIngest: "paywalled") == "ready")
        #expect(MobileReadModels.state(ofIngest: "ready") == "ready")
        #expect(MobileReadModels.state(ofIngest: nil) == "ready")
    }
}
