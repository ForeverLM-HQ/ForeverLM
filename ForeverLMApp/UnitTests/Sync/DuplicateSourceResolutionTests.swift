import Foundation
import Testing
@testable import ForeverLM

/// Duplicate resolution (docs/cloudkit-schema-design.md §4.2, D22, PD-13, IC-20): a paper with its PDF
/// wins; the loser is kept for ever as a redirect; the winner gains its work keys and the files and
/// derived outputs it lacks; Entries get twins; the learner's exclusions, reading state and marks move
/// onto the winner, so nothing that named the loser is stranded.
@Suite("Duplicate source resolution", .serialized)
struct DuplicateSourceResolutionTests {
    private typealias F = MaintenanceFixture
    private static let catalog = "Catalog"

    private static func envelope(_ server: FakeCloudKit, _ a: EngineTestDevice, _ type: SyncRecordType, _ id: String, zone: String = "Library") throws -> SyncEnvelope? {
        try F.stored(server, try a.recordName(type, id), zone: zone)
    }

    @Test("The loser redirects; the winner gets its PDF-less twin's text, guide and work keys; Entries, exclusions, reading state and marks follow")
    func resolvesOnePair() async throws {
        let server = EngineTestDriver.server()
        let a = try EngineTestDevice(server, name: "dup-a", deviceID: "macaaaaa")
        try await a.bootstrap()
        try await a.sync()
        let pdf = F.body("%PDF of the published paper", owner: "src_z", role: "pdf").file
        let text = F.body("The preprint's text", owner: "src_a", role: "text").file
        let guide = F.body("A review guide", owner: "src_a", role: "reviewGuide").file
        // src_a sorts first, but src_z is the paper with its PDF.
        try F.put(a, .source, "src_z", [
            "type": .value(.string("paper")), "status": .value(.string("active")), "title": .value(.string("Mitochondria")),
            "workKeys": .elements(["doi:10.1/x": .bool(true), "url:https://journal.example/x": .bool(true)]), "files": .elements(["pdf": pdf.value]),
        ], zone: Self.catalog)
        try F.put(a, .source, "src_a", [
            "type": .value(.string("paper")), "status": .value(.string("active")), "title": .value(.string("Mitochondria (preprint)")),
            "workKeys": .elements(["doi:10.1/x": .bool(true), "url:https://preprint.example/x": .bool(true)]),
            "files": .elements(["text": text.value]), "derived": .elements(["reviewGuide": guide.value]),
        ], zone: Self.catalog)
        try F.put(a, .notebook, "nb1", ["title": .value(.string("Cells")), "status": .value(.string("active"))])
        try F.put(a, .entry, "en:nb1:source:src_a", [
            "containerKind": .value(.string("notebook")), "containerID": .value(.string("nb1")), "itemKind": .value(.string("source")),
            "itemID": .value(.string("src_a")), "state": .value(.string("active")), "approval": .value(.string("approved")),
            "orderKey": .value(.string("a5")), "origin": .value(.string("added")), "addedAt": .value(SyncJSON(1_759_000_000_000)),
        ], at: 1_759_300_000_000)
        let loserEntry = try #require(try Self.envelope(server, a, .entry, "en:nb1:source:src_a").flatMap(SyncNotebookChatContext.Entry.init))
        try F.put(a, .notebookState, "ns:nb1", [
            "notebookID": .value(.string("nb1")), "excluded": .elements(["src_a": .string(SyncNotebookChatContext.stampPair(loserEntry))]),
        ])
        try F.put(a, .highlight, "hl1", [
            "sourceID": .value(.string("src_a")), "locator": .value(.object(["t": .string("web"), "fraction": SyncJSON(0.2)])),
            "text": .value(.string("ATP synthase")), "createdAt": .value(SyncJSON(1_759_000_000_000)),
        ])
        try F.put(a, .readingState, "rs:src_a", [
            "targetKind": .value(.string("source")), "targetID": .value(.string("src_a")),
            "locator": .value(.object(["t": .string("web"), "fraction": SyncJSON(0.4)])),
        ])
        try F.put(a, .mark, "mk:liked:src:src_a", [
            "kind": .value(.string("liked")), "target": .value(.string("src:src_a")), "on": .value(.bool(true)), "at": .value(SyncJSON(1_759_000_000_000)),
        ])
        try await a.sync()

        let service = F.service(a, clock: { server.now })
        #expect(try await service.resolveDuplicates() == 1)

        let loser = try #require(try Self.envelope(server, a, .source, "src_a", zone: Self.catalog))
        #expect(loser.fields["mergedInto"] == .string("src_z"))
        #expect(loser.fields["status"] == .string("archived"))
        let winner = try #require(try Self.envelope(server, a, .source, "src_z", zone: Self.catalog))
        #expect(winner.fields["workKeys"]?.objectValue?["url:https://preprint.example/x"] == .bool(true))
        #expect(winner.fields["files"]?.objectValue?["text"] == text.value, "the loser's FileRef, verbatim, owner included")
        #expect(winner.fields["files"]?.objectValue?["pdf"] == pdf.value)
        #expect(winner.fields["derived"]?.objectValue?["reviewGuide"] == guide.value)

        let twinEnvelope = try #require(try Self.envelope(server, a, .entry, "en:nb1:source:src_z"))
        let twin = try #require(SyncNotebookChatContext.Entry(twinEnvelope))
        #expect(twin.itemID == "src_z")
        #expect(twin.stateStamp == loserEntry.stateStamp && twin.approvalStamp == loserEntry.approvalStamp, "copied with their stamps")
        #expect(twinEnvelope.stamps["orderKey"] == (try Self.envelope(server, a, .entry, "en:nb1:source:src_a"))?.stamps["orderKey"])
        let removed = try #require(try Self.envelope(server, a, .entry, "en:nb1:source:src_a").flatMap(SyncNotebookChatContext.Entry.init))
        #expect(removed.state == "removed")

        let state = try #require(try Self.envelope(server, a, .notebookState, "ns:nb1"))
        let excluded = state.fields["excluded"]?.objectValue ?? [:]
        #expect(excluded["src_a"] == .null)
        #expect(SyncNotebookChatContext.chatSourceIDs(notebookID: "nb1", contextNotebookIDs: [], entries: [twin, removed], excluded: excluded).isEmpty,
                "the excluded loser stays unticked on the winner")

        // The highlight keeps naming the loser and shows on the winner through the redirect.
        let mergedInto = try a.store.replica.record(zoneKey: "private/Catalog", recordType: "Source", wireID: "src_a")
            .flatMap { try? SyncEnvelope(storedPayload: $0.payload) }?.fields["mergedInto"]?.stringValue
        #expect(try Self.envelope(server, a, .highlight, "hl1")?.fields["sourceID"] == .string("src_a"))
        #expect(SourceResolution.resolve("src_a") { id in id == "src_a" ? .some(mergedInto) : id == "src_z" ? .some(nil) : nil } == "src_z")

        #expect(try Self.envelope(server, a, .readingState, "rs:src_z")?.fields["locator"]?.objectValue?["fraction"] == SyncJSON(0.4))
        #expect(try Self.envelope(server, a, .readingState, "rs:src_z")?.fields["targetID"] == .string("src_z"))
        #expect(try Self.envelope(server, a, .mark, "mk:liked:src:src_z")?.fields["on"] == .bool(true))

        // A later import of the loser's address finds the winner: it is the only live source with the key.
        try await a.sync()
        var live: [String] = []
        try a.store.query("SELECT wire_id, payload FROM ck_records WHERE zone_key = 'private/Catalog' AND record_type = 'Source'", []) { row in
            guard let envelope = row.blob(1).flatMap({ try? SyncEnvelope(storedPayload: $0) }) else { return }
            let candidate = DuplicateSources.Candidate(id: row.text(0) ?? "", envelope: envelope)
            if candidate.isLive, candidate.workKeys.contains("url:https://preprint.example/x") { live.append(candidate.id) }
        }
        #expect(live == ["src_z"])
        #expect(try await service.resolveDuplicates() == 0, "a resolved pair is not resolved again")
    }

    @Test("The winner: a paper with its PDF, then one with text, then the post's own address over an app link, then the smaller id; groups join through any shared key")
    func winnerAndGroups() throws {
        func source(_ id: String, type: String = "paper", files: [String: SyncJSON] = [:], keys: [String], status: String = "active",
                    mergedInto: String? = nil, url: String? = nil) throws -> DuplicateSources.Candidate {
            var fields: [String: RecordPatch.Change] = [
                "type": .value(.string(type)), "status": .value(.string(status)),
                "workKeys": .elements(Dictionary(uniqueKeysWithValues: keys.map { ($0, SyncJSON.bool(true)) })),
            ]
            if let url { fields["url"] = .value(.string(url)) }
            if !files.isEmpty { fields["files"] = .elements(files) }
            if let mergedInto { fields["mergedInto"] = .value(.string(mergedInto)) }
            return DuplicateSources.Candidate(id: id, envelope: try F.envelope(.source, id, fields, saltID: "00000000"))
        }
        let pdf = F.body("pdf", owner: "src_b", role: "pdf").file.value
        let text = F.body("text", owner: "x", role: "text").file.value
        let uppercase = try source("0A1B2C3D-0000-4000-8000-000000000000", keys: ["doi:1"])
        let withPDF = try source("src_b", files: ["pdf": pdf], keys: ["doi:1"])
        #expect(DuplicateSources.winner([uppercase, withPDF])?.id == "src_b", "never a paper without its PDF over one with it")
        let article = try source("src_c", type: "article", files: ["pdf": pdf], keys: ["url:x"])
        let withText = try source("src_d", type: "article", files: ["text": text], keys: ["url:x"])
        #expect(DuplicateSources.winner([article, withText])?.id == "src_d", "a PDF counts only for a paper")
        #expect(DuplicateSources.winner([try source("src_f", keys: []), try source("src_e", keys: [])])?.id == "src_e")

        // One Substack post saved from the reader and from its own page: the copy under the post's own
        // address wins although its id is the larger, and only when text does not already decide.
        let appLink = "https://substack.com/home/post/p-194171938"
        let ownPage = "https://lettersfromthelab.substack.com/p/metabolism-as-inference"
        let postKeys = ["url:lettersfromthelab.substack.com/p/metabolism-as-inference"]
        let fromReader = try source("src_8", type: "article", files: ["text": text], keys: postKeys, url: appLink)
        let fromOwnPage = try source("src_c", type: "article", files: ["text": text], keys: postKeys, url: ownPage)
        #expect(DuplicateSources.winner([fromReader, fromOwnPage])?.id == "src_c", "the copy with the post's own title is kept")
        let ownPageWithoutText = try source("src_c", type: "article", keys: postKeys, url: ownPage)
        #expect(DuplicateSources.winner([fromReader, ownPageWithoutText])?.id == "src_8", "text still comes first")
        let otherReaderLink = try source("src_9", type: "article", files: ["text": text], keys: postKeys, url: "https://substack.com/inbox/post/194171938")
        #expect(DuplicateSources.winner([otherReaderLink, fromReader])?.id == "src_8", "two app-link copies fall to the smaller id")

        let groups = DuplicateSources.groups([
            try source("s1", keys: ["doi:1"]), try source("s2", keys: ["doi:1", "url:2"]), try source("s3", keys: ["url:2"]),
            try source("s4", keys: ["doi:9"]), try source("s5", keys: ["doi:1"], status: "archived"),
            try source("s6", keys: ["doi:1"], mergedInto: "s1"),
        ])
        #expect(groups.map { $0.map(\.id) } == [["s1", "s2", "s3"]])
        #expect(DuplicateSources.twinID(of: "en:nb1:source:s2#2", loser: "s2", winner: "s1") == "en:nb1:source:s1#2")
    }

    @Test("The first acknowledged resolution stands: a loser another Mac already redirected is left as it is, and nothing follows")
    func firstResolutionStands() async throws {
        let server = EngineTestDriver.server()
        let a = try EngineTestDevice(server, name: "dup-race", deviceID: "macaaaaa")
        try await a.bootstrap()
        try await a.sync()
        let other = try EngineTestDevice(server, name: "dup-race-o", deviceID: "macbbbbb")
        try await other.bootstrap(.macWithoutLibrary)
        // src_z wins (it has text), so src_a, which another Mac redirected elsewhere meanwhile, would be the loser.
        try F.put(a, .source, "src_z", ["type": .value(.string("article")), "status": .value(.string("active")),
                                        "files": .elements(["text": F.body("text", owner: "src_z", role: "text").file.value]),
                                        "workKeys": .elements(["url:x": .bool(true)])], zone: Self.catalog)
        try F.put(a, .source, "src_a", ["type": .value(.string("article")), "status": .value(.string("active")),
                                        "workKeys": .elements(["url:x": .bool(true), "url:a": .bool(true)])], zone: Self.catalog)
        try F.put(a, .entry, "en:nb1:source:src_a", [
            "containerKind": .value(.string("notebook")), "containerID": .value(.string("nb1")), "itemKind": .value(.string("source")),
            "itemID": .value(.string("src_a")), "state": .value(.string("active")), "orderKey": .value(.string("a0")),
            "origin": .value(.string("added")), "addedAt": .value(SyncJSON(1_759_000_000_000)),
        ])
        try await a.sync()
        // Meanwhile another resolution of src_a landed first, before this Mac fetched it.
        try F.put(other, .source, "src_a", ["type": .value(.string("article")), "status": .value(.string("archived")),
                                            "mergedInto": .value(.string("src_y")), "workKeys": .elements(["url:x": .bool(true), "url:a": .bool(true)])],
                  zone: Self.catalog, at: 1_759_500_000_000)
        #expect(try await F.service(a, clock: { server.now }).resolveDuplicates() == 0)
        #expect(try Self.envelope(server, a, .source, "src_a", zone: Self.catalog)?.fields["mergedInto"] == .string("src_y"))
        #expect(try Self.envelope(server, a, .source, "src_z", zone: Self.catalog)?.fields["workKeys"]?.objectValue?["url:a"] == nil)
        #expect(try Self.envelope(server, a, .entry, "en:nb1:source:src_z") == nil, "no twin")
    }

    @Test("A resolution whose redirect landed and nothing else is finished by the next pass, and the loser is archived last (F11)")
    func finishesACutShortResolution() async throws {
        let server = EngineTestDriver.server()
        let a = try EngineTestDevice(server, name: "dup-cut", deviceID: "macaaaaa")
        try await a.bootstrap()
        try await a.sync()
        try F.put(a, .source, "src_z", ["type": .value(.string("article")), "status": .value(.string("active")),
                                        "files": .elements(["text": F.body("text", owner: "src_z", role: "text").file.value]),
                                        "workKeys": .elements(["url:x": .bool(true)])], zone: Self.catalog)
        // The state a pass that stopped after its first write leaves: the redirect, the loser still active.
        try F.put(a, .source, "src_a", ["type": .value(.string("article")), "status": .value(.string("active")),
                                        "mergedInto": .value(.string("src_z")),
                                        "workKeys": .elements(["url:x": .bool(true), "url:a": .bool(true)])], zone: Self.catalog)
        try F.put(a, .entry, "en:nb1:source:src_a", [
            "containerKind": .value(.string("notebook")), "containerID": .value(.string("nb1")), "itemKind": .value(.string("source")),
            "itemID": .value(.string("src_a")), "state": .value(.string("active")), "orderKey": .value(.string("a0")),
            "origin": .value(.string("added")), "addedAt": .value(SyncJSON(1_759_000_000_000)),
        ])
        try await a.sync()

        #expect(try await F.service(a, clock: { server.now }).resolveDuplicates() == 1)
        #expect(try Self.envelope(server, a, .source, "src_a", zone: Self.catalog)?.fields["status"] == .string("archived"))
        #expect(try Self.envelope(server, a, .source, "src_z", zone: Self.catalog)?.fields["workKeys"]?.objectValue?["url:a"] == .bool(true), "the winner got the loser's key")
        #expect(try Self.envelope(server, a, .entry, "en:nb1:source:src_z") != nil, "the twin exists")
        try await a.sync()
        #expect(try await F.service(a, clock: { server.now }).resolveDuplicates() == 0, "a finished resolution is not run again")
    }
}

