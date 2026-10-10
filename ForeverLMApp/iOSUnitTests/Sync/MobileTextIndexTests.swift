import Foundation
import Testing
@testable import ForeverLM

/// The iPhone's search index under generation 2 (docs/cloudkit-schema-design.md D27, §7.1, §8a, §14.2
/// WP21): FTS5 over every held source's metadata, written by the apply that writes the Source, and over
/// the canonical text of the text set (notebook sources, sources read in the last 30 days, sources saved
/// offline, the whole library when chosen), fetched by name and dropped when it leaves the set.
@Suite("iPhone text index", .serialized)
struct MobileTextIndexTests {
    typealias F = MobileReadModelFixture
    static let now = Date(timeIntervalSince1970: 1_759_500_000)

    static func search(_ replica: MobileReplica, _ query: String) async throws -> [MobileTextIndex.Hit] {
        try await replica.read { try MobileTextIndex.search(query, limit: 20, in: $0.connection) }
    }

    @Test("A source's title, authors, venue, DOI and summary are searchable from the apply that wrote it, folded and with the last word as a prefix")
    func metadata() async throws {
        let replica = try await F.replica()
        try await MobileSyncFixture.apply([
            (F.catalog, try F.source("src-1", "Mitochondrial fission", added: 1, [
                "authors": .array([.string("Picard M"), .string("Shirihai O")]), "venue": .string("Nature Metabolism"),
                "doi": .string("10.1038/s42255"), "summary": .string("How a cell divides its power plants."),
            ])),
            (F.catalog, try F.source("src-2", "Café science", added: 2)),
            (F.catalog, try F.source("src-loser", "Mitochondrial fission (duplicate)", added: 3, ["mergedInto": .string("src-1")])),
        ], to: replica)

        #expect(try await Self.search(replica, "fission").map(\.sourceID) == ["src-1"], "a merged duplicate is never a hit")
        #expect(try await Self.search(replica, "shirihai").map(\.sourceID) == ["src-1"])
        #expect(try await Self.search(replica, "nature metab").map(\.sourceID) == ["src-1"], "the last word is a prefix while it is typed")
        #expect(try await Self.search(replica, "s42255").map(\.sourceID) == ["src-1"])
        #expect(try await Self.search(replica, "power plants").map(\.sourceID) == ["src-1"])
        #expect(try await Self.search(replica, "CAFE").map(\.sourceID) == ["src-2"], "case and accents folded")
        #expect(try await Self.search(replica, "fission cafe").isEmpty, "every word must match")
        #expect(try await Self.search(replica, "  ;; ").isEmpty)
    }

    @Test("A source edited, merged or forgotten moves its metadata row with it")
    func metadataFollowsTheReplica() async throws {
        let replica = try await F.replica()
        try await MobileSyncFixture.apply([(F.catalog, try F.source("src-1", "Old title", added: 1))], to: replica)
        try await MobileSyncFixture.apply([(F.catalog, try F.source("src-1", "New title", added: 1))], to: replica)
        #expect(try await Self.search(replica, "old").isEmpty)
        #expect(try await Self.search(replica, "new").map(\.sourceID) == ["src-1"])

        // A purge, a space that went, a record a move took elsewhere: the replica forgets the record.
        try await replica.perform { try $0.connection.execute("DELETE FROM ck_records WHERE wire_id = 'src-1'", []) }
        #expect(try await Self.search(replica, "new").isEmpty)
        #expect(try await replica.read { try $0.connection.scalarInteger("SELECT COUNT(*) FROM m_text_keys") } == 0)
    }

    @Test("The text set is the notebooks' sources, the sources read in the last 30 days and the ones saved offline, or every source when chosen; only copies naming a text satellite, the learner's own first")
    func textSet() async throws {
        let replica = try await F.replica()
        func text(_ owner: String, _ body: String) -> SyncJSON {
            .object(["text": MobileSyncFixture.fileRef(owner: owner, role: "text", bytes: Data(body.utf8)).value])
        }
        let day: Int64 = 86_400_000
        let nowMilliseconds = Int64(Self.now.timeIntervalSince1970 * 1_000)
        try await MobileSyncFixture.apply([
            (F.catalog, try F.source("src-nb", "In a notebook", added: 1, ["files": text("src-nb", "a")])),
            (F.catalog, try F.source("src-read", "Read last week", added: 1, ["files": text("src-read", "b")])),
            (F.catalog, try F.source("src-old", "Read last year", added: 1, ["files": text("src-old", "c")])),
            (F.catalog, try F.source("src-pin", "Saved offline", added: 1, ["files": text("src-pin", "d")])),
            (F.catalog, try F.source("src-none", "No text yet", added: 1)),
            (F.catalog, try F.source("src-rest", "Elsewhere", added: 1, ["files": text("src-rest", "e")])),
            (F.catalog, try F.source("src-both", "Mine and the team's", added: 1, ["files": text("src-both", "mine")])),
            (F.space, try MobileSyncFixture.envelope(.source, "src-both", ["title": .string("Mine and the team's"), "status": .string("active"),
                                                                           "files": text("src-both", "theirs")], salt: MobileSyncFixture.spaceSalt)),
            (F.library, try F.entry("nb1", "source", "src-nb", order: "a")),
            (F.library, try F.entry("nb1", "source", "src-none", order: "b")),
            (F.library, try F.entry("nb1", "source", "src-both", order: "c")),
            (F.library, try F.entry("nb1", "source", "src-rest", order: "d", ["state": .string("removed")])),
            (F.library, try MobileSyncFixture.envelope(.readingState, "rs:src-read", ["targetKind": .string("source"), "targetID": .string("src-read"),
                                                                                      "lastReadAt": SyncJSON(nowMilliseconds - 7 * day)])),
            (F.library, try MobileSyncFixture.envelope(.readingState, "rs:src-old", ["targetKind": .string("source"), "targetID": .string("src-old"),
                                                                                     "lastReadAt": SyncJSON(nowMilliseconds - 300 * day)])),
        ], to: replica)

        let set = try await replica.read { try MobileTextIndex.textSet(pinned: ["src-pin"], wholeLibrary: false, now: Self.now, in: $0.connection) }
        #expect(set.map(\.sourceID) == ["src-both", "src-nb", "src-pin", "src-read"])
        let mine = MobileSyncFixture.fileRef(owner: "src-both", role: "text", bytes: Data("mine".utf8)).hash
        #expect(set.first?.hash == mine, "the learner's own copy's text before the team's")
        let whole = try await replica.read { try MobileTextIndex.textSet(pinned: [], wholeLibrary: true, now: Self.now, in: $0.connection) }
        #expect(whole.map(\.sourceID) == ["src-both", "src-nb", "src-old", "src-pin", "src-read", "src-rest"], "every source naming a text")
    }

    @Test("A refresh fetches the text set's text by name and makes it searchable; a second fetches nothing; text that left the set goes unless it was opened in the last 30 days")
    func refresh() async throws {
        let phone = try await MobileBlobOnDemandTests.Phone()
        defer { phone.cleanUp() }
        let nb = try await phone.blobs.upload(Data("Cristae remodel under stress.".utf8), owner: "src-nb", ownerType: .source, role: "text",
                                              mime: "text/plain", encoding: .gzip, into: phone.personal)
        let other = try await phone.blobs.upload(Data("Cardiolipin anchors the respiratory chain.".utf8), owner: "src-2", ownerType: .source,
                                                 role: "text", mime: "text/plain", encoding: .gzip, into: phone.personal)
        try await MobileSyncFixture.apply([
            (F.catalog, try F.source("src-nb", "Membranes", added: 1, ["files": .object(["text": nb.value])])),
            (F.catalog, try F.source("src-2", "Lipids", added: 2, ["files": .object(["text": other.value])])),
            (F.library, try F.entry("nb1", "source", "src-nb", order: "a")),
        ], to: phone.device.replica)
        let indexer = MobileTextIndexer(satellites: phone.satellites)

        #expect(await indexer.refresh(pinned: [], wholeLibrary: false, now: Self.now) == 1)
        let hit = try #require(try await indexer.search("cristae").first)
        #expect(hit.sourceID == "src-nb")
        #expect(hit.inText)
        #expect(hit.snippet?.contains("Cristae remodel") == true)
        #expect(try await indexer.search("cardiolipin").isEmpty, "a source outside the text set has only its metadata indexed")
        #expect(try await indexer.search("lipids").map(\.sourceID) == ["src-2"])
        let fetched = phone.fetches()
        #expect(await indexer.refresh(pinned: [], wholeLibrary: false, now: Self.now) == 0)
        #expect(phone.fetches() == fetched, "text already indexed from the same hash is not fetched again")

        // Opened in the Reader: indexed at once, and kept for 30 days although it is in no notebook.
        try await indexer.index("Cardiolipin anchors the respiratory chain.", sourceID: "src-2", hash: other.hash, now: Self.now)
        #expect(try await indexer.search("cardiolipin").map(\.sourceID) == ["src-2"])
        #expect(await indexer.refresh(pinned: [], wholeLibrary: false, now: Self.now.addingTimeInterval(86_400)) == 0)
        #expect(try await indexer.search("cardiolipin").map(\.sourceID) == ["src-2"], "opened yesterday, still searchable")
        #expect(await indexer.refresh(pinned: [], wholeLibrary: false, now: Self.now.addingTimeInterval(31 * 86_400)) == 0)
        #expect(try await indexer.search("cardiolipin").isEmpty, "opened a month ago and in no notebook: its text goes")
        #expect(try await indexer.search("lipids").map(\.sourceID) == ["src-2"], "its metadata stays")
    }

    @Test("A source whose text changed is indexed again from the new text, and the old words go")
    func changedText() async throws {
        let phone = try await MobileBlobOnDemandTests.Phone()
        defer { phone.cleanUp() }
        let first = try await phone.blobs.upload(Data("First draft about fission.".utf8), owner: "src-1", ownerType: .source, role: "text",
                                                 mime: "text/plain", encoding: .gzip, into: phone.personal)
        try await MobileSyncFixture.apply([(F.catalog, try F.source("src-1", "Paper", added: 1, ["files": .object(["text": first.value])]))],
                                          to: phone.device.replica)
        let indexer = MobileTextIndexer(satellites: phone.satellites)
        #expect(await indexer.refresh(pinned: ["src-1"], wholeLibrary: false, now: Self.now) == 1)
        let second = try await phone.blobs.upload(Data("Final text about fusion.".utf8), owner: "src-1", ownerType: .source, role: "text",
                                                  mime: "text/plain", encoding: .gzip, into: phone.personal)
        try await MobileSyncFixture.apply([(F.catalog, try F.source("src-1", "Paper", added: 1, ["files": .object(["text": second.value])]))],
                                          to: phone.device.replica)
        #expect(await indexer.refresh(pinned: ["src-1"], wholeLibrary: false, now: Self.now) == 1)
        #expect(try await indexer.search("fusion").map(\.sourceID) == ["src-1"])
        #expect(try await indexer.search("draft").isEmpty)
    }

    @Test("A replica built before the index fills its metadata once at open, and a rebuilt index keeps search in step with what it holds")
    func fillAndRebuild() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MobileTextIndex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("replica.sqlite").path
        do {
            let replica = try MobileReplica(path: path)
            try await MobileSyncFixture.apply([
                (F.catalog, try F.source("src-1", "Mitochondrial fission", added: 1)),
                (F.catalog, try F.source("src-2", "Cardiolipin", added: 2)),
            ], to: replica)
            // As a build before the text index left it.
            try await replica.perform { state in
                try state.connection.executeScript("""
                    DROP TRIGGER mobile_text_forget; DROP TABLE m_text_keys; DROP TABLE m_source_meta_fts;
                    DROP TABLE m_text_bodies; DROP TABLE m_source_text_fts;
                """)
                try state.replica.setEngineState(MobileTextIndex.versionScope, nil)
            }
        }
        let reopened = try MobileReplica(path: path)
        #expect(try await Self.search(reopened, "fission").map(\.sourceID) == ["src-1"], "filled from the held records at open")
        let decoded = reopened.decodedRecords
        #expect(decoded == 2, "each held Source decoded once")

        // A build that moved the index version rebuilds it; a record forgotten meanwhile leaves no hit.
        try await reopened.perform { state in
            try state.connection.executeScript("PRAGMA user_version = 1")
            try state.connection.execute("DELETE FROM ck_records WHERE wire_id = 'src-2'", [])
        }
        let rebuilt = try MobileReplica(path: path)
        #expect(try await Self.search(rebuilt, "fission").map(\.sourceID) == ["src-1"])
        #expect(try await Self.search(rebuilt, "cardiolipin").isEmpty)
        #expect(rebuilt.decodedRecords == 1, "a filled version is not filled again")
    }

    @Test("What the learner types becomes an FTS5 query of quoted words, the last a prefix")
    func matchExpression() {
        #expect(MobileTextIndex.matchExpression("Mitochondrial  fiss") == "\"mitochondrial\" \"fiss\"*")
        #expect(MobileTextIndex.matchExpression("\"OR\" NEAR(x)") == "\"or\" \"near\" \"x\"*", "operators are only words")
        #expect(MobileTextIndex.matchExpression("Café") == "\"cafe\"*")
        #expect(MobileTextIndex.matchExpression(" - ") == nil)
    }

    @Test("The whole-library choice is this device's, per environment")
    func wholeLibraryChoice() throws {
        let defaults = try #require(UserDefaults(suiteName: "MobileTextIndexTests-\(UUID().uuidString)"))
        let development = MobileTextIndexChoice(defaults: defaults, environment: .development)
        #expect(!development.wholeLibrary)
        development.wholeLibrary = true
        #expect(development.wholeLibrary)
        #expect(!MobileTextIndexChoice(defaults: defaults, environment: .production).wholeLibrary)
    }

    @Test("At 10× the apply that indexes 5,000 sources' metadata and a search over them stay small")
    func scale() async throws {
        let replica = try await F.replica()
        let records = try (0..<5_000).map { index in
            (F.catalog, try F.source("src-\(index)", "Paper \(index) on mitochondrial dynamics \(index % 97)", added: Int64(index), [
                "authors": .array([.string("Author \(index % 300)")]), "venue": .string("Journal \(index % 40)"),
            ]))
        }
        let applied = Date()
        try await MobileSyncFixture.apply(records, to: replica)
        let applyMilliseconds = Date().timeIntervalSince(applied) * 1_000
        let searched = Date()
        let hits = try await Self.search(replica, "dynamics 42")
        let searchMilliseconds = Date().timeIntervalSince(searched) * 1_000
        print("ms: apply 5000 sources with the text index \(Int(applyMilliseconds)), search \(String(format: "%.1f", searchMilliseconds))")
        #expect(!hits.isEmpty)
        #expect(hits.count <= 20)
        #expect(searchMilliseconds < 1_000)
    }

    // MARK: - Search on the phone and on the Mac

    @Test("The Mac's search answer gives its sources best first, each once; a refusal, a signed-out phone or an offline Mac give nothing")
    func macAnswer() throws {
        let text = """
        Found 3 sources for "membranes":
        - [paper] [Cristae \\] and folds](foreverlm://source/src_a1) (similarity: 0.812, 4200 words)
          Evidence: Cristae remodel under stress.
        - [article] [Lipids](foreverlm://source/https%3A%2F%2Fexample.org%2Fx) (text: 0.400)
        - [paper] [Cristae again](foreverlm://source/src_a1) (similarity: 0.700)

        When you present these to the learner, show each source as its [title](foreverlm://source/id) link above.
        """
        let answered = try JSONSerialization.data(withJSONObject: ["text": text])
        #expect(MobileMacSearch.sourceIDs(status: 200, body: answered) == ["src_a1", "https://example.org/x"])
        let refused = try JSONSerialization.data(withJSONObject: ["text": "Error: no host", "is_error": true])
        #expect(MobileMacSearch.sourceIDs(status: 200, body: refused) == nil)
        #expect(MobileMacSearch.sourceIDs(status: 401, body: Data()) == nil)
        #expect(MobileMacSearch.sourceIDs(status: 503, body: try JSONSerialization.data(withJSONObject: ["error": "mac_offline"])) == nil)
    }

    @Test("The phone asks the Mac's search_sources_semantic through the gateway's web call, as Share does, with its managed session and iCloud account")
    func macRequest() throws {
        let request = MobileMacSearch.request(token: "tok", iCloudUser: "_abc", query: "cristae", limit: 20)
        #expect(request.url?.absoluteString == "https://plugin.foreverlm.com/web/call")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.timeoutInterval == MobileMacSearch.timeout)
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["name"] as? String == "search_sources_semantic")
        #expect(body["icloud_user"] as? String == "_abc")
        #expect(body["icloud_environment"] as? String == "production")
        let arguments = try #require(body["arguments"] as? [String: Any])
        #expect(arguments["query"] as? String == "cristae")
        #expect(arguments["limit"] as? Int == 20)
    }

    @Test("Meaning comes first, then words, each source once, and only sources the screen offers")
    func mergedResults() {
        func source(_ id: String) -> MobileCloudSource {
            MobileCloudSource(id: id, title: id, subtitle: nil, sourceType: "paper", dateAdded: Date(timeIntervalSince1970: 0), hasAudio: false,
                              isArchived: false)
        }
        let ids = MobileSemanticSourceSearch.merged(meaning: ["src-b", "src-a"], words: ["src-a", "src-c", "src-hidden"])
        #expect(ids == ["src-b", "src-a", "src-c", "src-hidden"])
        let offered = [source("src-a"), source("src-b"), source("src-c")]
        #expect(MobileSemanticSourceSearch.pick(ids, from: offered, limit: 20).map(\.id) == ["src-b", "src-a", "src-c"])
        #expect(MobileSemanticSourceSearch.pick(ids, from: offered, limit: 2).map(\.id) == ["src-b", "src-a"])
    }
}
