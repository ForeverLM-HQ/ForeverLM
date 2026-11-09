import Foundation
import Testing
@testable import ForeverLM

/// The Source record's projection (docs/cloudkit-schema-design.md §3.5.4, §6.6, WP7): every field and
/// role round-trips through the local tables with its id unchanged, member-local columns never reach
/// the record, `ingest` never goes back, and the satellite layout names the bytes this Mac holds.
@Suite("Source projection")
struct SourceProjectionTests {
    private typealias Fixture = SourceSyncFixture

    private static let paperID = "6A0D2A43-1B6C-4E0E-9C8B-3F2D1E0A9B87"
    private static let bookID = "BFD0CD37-6840-4D47-9CEB-3EC7A1E36747"

    private static func fileRef(_ role: String, _ text: String) -> FileRef {
        FileRef(owner: paperID, role: role, hash: SyncIdentity.sha256Hex(Data(text.utf8)), size: Int64(text.utf8.count),
                mime: role == "pdf" ? "application/pdf" : "text/plain", encoding: role == "pdf" ? "identity" : "gzip",
                storedParts: [Data(text.utf8)])
    }

    /// A paper with every field the schema gives a Source, as another device would send it.
    private static func fullPaper() -> [String: SyncJSON] {
        [
            "primaryKey": "doi:10.1038/s41586-020-2649-2",
            "workKeys": .object(["doi:10.1038/s41586-020-2649-2": true, "url:nature.com/articles/s41586-020-2649-2": true]),
            "type": "paper",
            "typeLocked": true,
            "title": "Array programming with NumPy",
            "subtitle": "A review",
            "venue": "Nature",
            "language": "en",
            "authors": .array(["Charles R. Harris", "K. Jarrod Millman"]),
            "url": "https://www.nature.com/articles/s41586-020-2649-2",
            "doi": "10.1038/s41586-020-2649-2",
            "publishedAt": SyncJSON(Int64(1_600_214_400_000)),
            "collectionID": .string(bookID),
            "collectionOrder": .string(SourceOrderKeys.key(forIndex: 2) ?? ""),
            "status": "active",
            "ingest": .object(["ord": .array([1, 4]), "state": "ready", "at": SyncJSON(Int64(1_759_000_000_000)), "device": "macbbbbb"]),
            "contentHash": .string(String(repeating: "c", count: 64)),
            "summary": "NumPy is the primary array programming library for Python.",
            "metrics": .object(["wordCount": 5_200, "pageCount": 11, "textChars": 33_000]),
            "files": .object(["pdf": fileRef("pdf", "%PDF").value, "text": fileRef("text", "The text.").value]),
            "derived": .object(["reviewGuide": fileRef("reviewGuide", "# Guide").value]),
            "meta": .object(["journal": "Nature", "pmid": "32939066", "publisher": "Springer Nature"]),
            "addedAt": SyncJSON(Int64(1_759_100_000_000)),
            "madeBy": .object(["route": "web", "device": "webaaaaa", "at": SyncJSON(Int64(1_759_100_000_000))]),
            "copiedFrom": .object(["zone": "personal", "at": SyncJSON(Int64(1_759_200_000_000))]),
            "mergedInto": "src_winner",
        ]
    }

    private static func applyFullPaper(_ store: KnowledgeStore) throws {
        try store.execForTesting("INSERT INTO books (id, title) VALUES ('\(bookID)', 'Cell Biology by the Numbers')")
        try Fixture.apply(store, [try Fixture.record(.source, paperID, fullPaper())])
    }

    private static func encoded(_ store: KnowledgeStore, _ id: String) throws -> [String: SyncJSON] {
        let rows = try #require(try SourceProjection.loadRows(localID: id, connection: store))
        return SourceProjection.encodeRows(rows)
    }

    @Test("Every field and role round-trips through the local tables, the id unchanged")
    func roundTrip() throws {
        let (root, store) = try Fixture.makeStore("source-round-trip")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        try Self.applyFullPaper(store)

        #expect(try Fixture.text(store, "SELECT id || '|' || wire_id || '|' || source_type || '|' || state FROM sources") == "\(Self.paperID)|\(Self.paperID)|paper|ready")
        #expect(try Fixture.text(store, "SELECT title || '|' || journal || '|' || published_year || '|' || author FROM papers WHERE source_id = ?", [.text(Self.paperID)])
                == "Array programming with NumPy|Nature|2020|Charles R. Harris, K. Jarrod Millman")
        #expect(try Fixture.text(store, "SELECT group_id || '|' || sort_index FROM group_members WHERE source_id = ?", [.text(Self.paperID)]) == "\(Self.bookID)|2")
        let encoded = try Self.encoded(store, Self.paperID)
        for (field, value) in Self.fullPaper() {
            #expect(encoded[field] == value, "\(field)")
        }
        #expect(try Fixture.pending(store)["Source:\(Self.paperID)"] == nil, "an applied record has nothing to send back")
    }

    @Test("A local edit sends that field alone, at its own column's time")
    func localEditSendsItsField() throws {
        let (root, store) = try Fixture.makeStore("source-edit")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        try Self.applyFullPaper(store)
        try store.execForTesting("UPDATE papers SET title = 'NumPy, renamed' WHERE source_id = '\(Self.paperID)'")
        let change = try #require(try Fixture.pending(store)["Source:\(Self.paperID)"])
        #expect(change.stamps.keys.map(\.field).sorted() == ["title"])
        #expect(Fixture.savedFields(change)?["title"] == "NumPy, renamed")
        #expect(Fixture.savedFields(change)?["authors"] == Self.fullPaper()["authors"], "the authors it came with, untouched")
    }

    @Test("The type lock travels with the record")
    func typeLocked() throws {
        let (root, store) = try Fixture.makeStore("source-type-lock")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        var fields = Self.fullPaper()
        fields["typeLocked"] = false
        try store.execForTesting("INSERT INTO books (id, title) VALUES ('\(Self.bookID)', 'A book')")
        try Fixture.apply(store, [try Fixture.record(.source, Self.paperID, fields)])
        #expect(try Fixture.count(store, "SELECT type_locked FROM source_wire_fields WHERE source_id = ?", [.text(Self.paperID)]) == 0)
        try store.execForTesting("UPDATE source_wire_fields SET type_locked = 1 WHERE source_id = '\(Self.paperID)'")
        let change = try Fixture.pending(store)["Source:\(Self.paperID)"]
        #expect(Fixture.savedFields(change)?["typeLocked"] == true)
        #expect(change?.stamps.keys.map(\.field) == ["typeLocked"])
    }

    @Test("Each type's meta keys land in its columns, and keys no column holds come back as they went")
    func metaPerType() throws {
        let (root, store) = try Fixture.makeStore("source-meta")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        let cases: [(id: String, type: String, url: String, meta: [String: SyncJSON], check: String, expected: String)] = [
            ("src-podcast", "podcast", "https://podcasts.example.org/ep/1",
             ["showName": "Huberman Lab", "feedURL": "https://feeds.example.org/huberman", "guid": "ep-1"],
             "SELECT show_name || '|' || domain FROM podcasts WHERE source_id = 'src-podcast'", "Huberman Lab|Huberman Lab"),
            ("src-video", "video", "https://www.youtube.com/watch?v=abcdefghijk",
             ["channelName": "Alon Lab", "youtubeID": "abcdefghijk"],
             "SELECT domain FROM videos WHERE source_id = 'src-video'", "Alon Lab"),
            ("src-meeting", "meeting", "zoom://meeting/1",
             ["startAt": SyncJSON(Int64(1_759_000_000_000)), "platform": "zoom", "zoomID": "123"],
             "SELECT CAST(occurred_at AS INTEGER) FROM meeting_sources WHERE source_id = 'src-meeting'", "\(Int(SyncTime.cocoaSeconds(milliseconds: 1_759_000_000_000)))"),
            ("src-post", "xPost", "https://x.com/someone/status/1234567890",
             ["handle": "someone", "postID": "1234567890"],
             "SELECT author_handle FROM x_posts WHERE source_id = 'src-post'", "someone"),
            ("src-article", "article", "https://example.org/essay",
             ["siteName": "example.org", "archivedAt": SyncJSON(Int64(1_759_000_000_000))],
             "SELECT domain FROM articles WHERE source_id = 'src-article'", "example.org"),
        ]
        for item in cases {
            try Fixture.apply(store, [try Fixture.record(.source, item.id, [
                "type": .string(item.type), "title": .string("A \(item.type)"), "url": .string(item.url), "status": "active",
                "ingest": .object(["ord": .array([0, 1]), "state": "queued"]), "meta": .object(item.meta),
                "addedAt": SyncJSON(Int64(1_759_000_000_000)),
            ])])
            #expect(try Fixture.text(store, item.check) == item.expected, "\(item.type)")
            let meta = try Self.encoded(store, item.id)["meta"]?.objectValue ?? [:]
            for (key, value) in item.meta {
                #expect(meta[key] == value, "\(item.type).\(key)")
            }
        }
        #expect(try Fixture.pending(store).isEmpty)
    }

    @Test("No member-local column reaches the record, and writing one sends nothing")
    func noMemberLocalField() throws {
        let (root, store) = try Fixture.makeStore("source-member-local")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        var video = StudioArticle(url: "https://www.youtube.com/watch?v=abcdefghijk", title: "Liked talk", sourceType: .video, discoveryOrigin: .safari)
        video.likedAt = Date()
        video.domain = "Alon Lab"
        video.readingPositionLocator = "{\"seconds\":120}"
        try store.saveSource(video)
        let fields = try Self.encoded(store, video.id)
        for field in fields.keys {
            let spec = try #require(SyncRecordType.source.spec.field(field), "\(field) is a Source field")
            #expect(!spec.isMemberLocal, "\(field)")
        }
        #expect(fields.keys.allSatisfy { !$0.lowercased().contains("liked") && !$0.lowercased().contains("discover") })
        try Fixture.sendAll(store)
        try store.execForTesting("""
            UPDATE videos SET discovery_origin = 'chrome', liked_at = 1, legacy_cap_verified_at = 2 WHERE source_id = '\(video.id)';
            UPDATE sources SET reading_position_page = 3, read_at = 4, review_depth = 'deep', is_consumed = 1 WHERE id = '\(video.id)';
        """)
        // The Source record is not written; the member's own columns feed their own records, the Marks (provenance, like).
        let pending = try Fixture.pending(store)
        #expect(pending.keys.filter { $0.hasPrefix("Source:") }.isEmpty, "\(pending.keys.sorted())")
        #expect(pending.keys.allSatisfy { $0.hasPrefix("Mark:") }, "\(pending.keys.sorted())")
    }

    @Test("A space's copy gets its own local id beside the personal copy and keeps the wire id")
    func spaceCopyKeepsItsWireID() throws {
        let (root, store) = try Fixture.makeStore("source-space")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        let fields: [String: SyncJSON] = [
            "type": "article", "title": "Shared", "url": "https://example.org/shared", "status": "active",
            "ingest": .object(["ord": .array([0, 1]), "state": "queued"]), "addedAt": SyncJSON(Int64(1_759_000_000_000)),
        ]
        let wireID = SourceIdentity.stableID(for: "https://example.org/shared")
        try Fixture.apply(store, [try Fixture.record(.source, wireID, fields)])
        let spaceZone = "private/Space-0b9f0e8a-0b8d-4d5c-9f5e-3f0e1c2b9a77"
        try Fixture.apply(store, [try Fixture.record(.source, wireID, fields, zoneKey: spaceZone)])
        let local = SpaceLocalID.localID(spaceID: "0b9f0e8a-0b8d-4d5c-9f5e-3f0e1c2b9a77", type: .source, wireID: wireID)
        #expect(try Fixture.text(store, "SELECT wire_id || '|' || team_id FROM sources WHERE id = ?", [.text(local)]) == "\(wireID)|0b9f0e8a-0b8d-4d5c-9f5e-3f0e1c2b9a77")
        #expect(try Fixture.text(store, "SELECT COALESCE(team_id, 'mine') FROM sources WHERE id = ?", [.text(wireID)]) == "mine")
        #expect(try Fixture.text(store, "SELECT local_id FROM ck_identity WHERE zone_key = ? AND wire_id = ?", [.text(spaceZone), .text(wireID)]) == local)
    }

    @Test("Ingest never goes back: a re-fetch here is the next generation, and a paywall is its own state")
    func ingestIsMonotonic() throws {
        let (root, store) = try Fixture.makeStore("source-ingest")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        try Self.applyFullPaper(store)
        // A deliberate re-fetch on this Mac: back to queued.
        try store.execForTesting("UPDATE sources SET state = 'queued' WHERE id = '\(Self.paperID)'")
        let change = try Fixture.pending(store)["Source:\(Self.paperID)"]
        #expect(Fixture.savedFields(change)?["ingest"]?["ord"] == .array([2, 1]), "generation 1 + 1, ranked queued")
        // X keeps the larger ord: the re-fetch wins over the ready it replaces.
        guard case .save(let local)? = change?.action else { Issue.record("no save"); return }
        let server = try SyncEnvelope(storedPayload: try Fixture.record(.source, Self.paperID, Self.fullPaper()).payload)
        #expect(FieldMerge.merge(server: server, local: local, base: nil).merged.fields["ingest"]?["state"] == "queued")
        try store.execForTesting("UPDATE sources SET state = 'error' WHERE id = '\(Self.paperID)'; UPDATE papers SET is_paywalled = 1 WHERE source_id = '\(Self.paperID)'")
        #expect(Fixture.savedFields(try Fixture.pending(store)["Source:\(Self.paperID)"])?["ingest"]?["state"] == "paywalled")
    }

    @Test("A paywalled paper that reads ready on its abstract goes out paywalled, and the device applying it keeps the flag")
    func paywalledPaperWithoutPDFIsNeverSentReady() throws {
        let (root, store) = try Fixture.makeStore("source-paywalled-ready")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        var abstractOnly = Self.fullPaper()
        for field in ["collectionID", "collectionOrder", "mergedInto"] { abstractOnly.removeValue(forKey: field) }
        abstractOnly["files"] = .object(["text": Self.fileRef("text", "The abstract.").value])
        try Fixture.apply(store, [try Fixture.record(.source, Self.paperID, abstractOnly)])
        // Generation 1's shape: ready on the abstract, marked paywalled, no PDF.
        try store.execForTesting("UPDATE papers SET is_paywalled = 1 WHERE source_id = '\(Self.paperID)'")
        let ingest = try #require(Fixture.savedFields(try Fixture.pending(store)["Source:\(Self.paperID)"])?["ingest"])
        #expect(ingest["state"] == "paywalled")
        #expect(ingest["ord"] == .array([2, 3]), "ranked below the ready it was held at, so the next generation")

        // Another Mac applies it: still paywalled, so it stays out of Papers that need attention.
        let (otherRoot, other) = try Fixture.makeStore("source-paywalled-ready-other")
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        try Fixture.prepareReplica(other)
        abstractOnly["ingest"] = ingest
        try Fixture.apply(other, [try Fixture.record(.source, Self.paperID, abstractOnly)])
        #expect(try Fixture.text(other, "SELECT s.state || '|' || p.is_paywalled FROM sources s JOIN papers p ON p.source_id = s.id") == "error|1")

        // Holding its PDF, the paper is ready and the paywall no longer needs the wire.
        try store.execForTesting("UPDATE papers SET local_file_path = 'Papers/abstract-only.pdf' WHERE source_id = '\(Self.paperID)'")
        #expect(SourceProjection.wireIngestState(try #require(try SourceProjection.loadRows(localID: Self.paperID, connection: store))) == "ready")
    }

    @Test("Marking a failed paper paywalled, and clearing the mark, reach the other Mac")
    func paywallMarkOnFailedPaperSyncs() throws {
        let (root, store) = try Fixture.makeStore("source-paywall-failed")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        var failed = Self.fullPaper()
        for field in ["collectionID", "collectionOrder", "mergedInto"] { failed.removeValue(forKey: field) }
        failed["ingest"] = .object(["ord": .array([1, 3]), "state": .string("error"), "error": .string("No PDF found")])
        try Fixture.apply(store, [try Fixture.record(.source, Self.paperID, failed)])

        // Marked paywalled here: the same rank as the error, so it must be the next generation, or the
        // server's equal `ord` keeps the error.
        try store.execForTesting("UPDATE papers SET is_paywalled = 1 WHERE source_id = '\(Self.paperID)'")
        let change = try Fixture.pending(store)["Source:\(Self.paperID)"]
        let marked = try #require(Fixture.savedFields(change)?["ingest"])
        #expect(marked["state"] == "paywalled")
        #expect(marked["ord"] == .array([2, 3]))
        guard case .save(let local)? = change?.action else { Issue.record("no save"); return }
        let server = try SyncEnvelope(storedPayload: try Fixture.record(.source, Self.paperID, failed).payload)
        #expect(FieldMerge.merge(server: server, local: local, base: nil).merged.fields["ingest"]?["state"] == "paywalled")

        // The other Mac takes the mark, then takes it off again when it is cleared.
        let (otherRoot, other) = try Fixture.makeStore("source-paywall-failed-other")
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        try Fixture.prepareReplica(other)
        var sent = failed
        sent["ingest"] = marked
        try Fixture.apply(other, [try Fixture.record(.source, Self.paperID, sent)])
        #expect(try Fixture.text(other, "SELECT s.state || '|' || p.is_paywalled FROM sources s JOIN papers p ON p.source_id = s.id") == "error|1")
        sent["ingest"] = .object(["ord": .array([3, 3]), "state": .string("error"), "error": .string("No PDF found")])
        try Fixture.apply(other, [try Fixture.record(.source, Self.paperID, sent)])
        #expect(try Fixture.text(other, "SELECT s.state || '|' || p.is_paywalled FROM sources s JOIN papers p ON p.source_id = s.id") == "error|0")
    }

    @Test("A deleted source deletes its record; the member's own rows about it stay")
    func deleteKeepsPersonalRows() throws {
        let (root, store) = try Fixture.makeStore("source-delete")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        try Self.applyFullPaper(store)
        try Schema154Fixture.addPerMemberRows(store, sourceID: Self.paperID)
        let name = RecordNaming.recordName(type: .source, id: Self.paperID, salt: Fixture.salt)
        try store.replica.apply { replica in
            try ProjectionApply(store: store, registry: Fixture.registry)
                .projectDeletion(zoneKey: Fixture.catalogZoneKey, recordName: name, type: .source, wireID: Self.paperID)
            try replica.deleteRecord(zoneKey: Fixture.catalogZoneKey, recordName: name)
        }
        #expect(try Fixture.count(store, "SELECT COUNT(*) FROM sources") == 0)
        #expect(try Fixture.count(store, "SELECT COUNT(*) FROM source_files") == 0)
        #expect(try Fixture.count(store, "SELECT COUNT(*) FROM source_highlights WHERE source_id = ?", [.text(Self.paperID)]) == 1, "D18")
        #expect(try Fixture.pending(store)["Source:\(Self.paperID)"] == nil, "an inbound delete is not sent back")
    }

    @Test("The satellite layout names this Mac's file and texts, owned by the source, as BlobStore lays them out")
    func satelliteLayout() throws {
        let (root, store) = try Fixture.makeStore("source-satellites")
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("paper.pdf")
        let pdfBytes = Data("%PDF-1.7 a local paper".utf8)
        try pdfBytes.write(to: pdf)
        var paper = StudioArticle(url: "https://example.org/paper", title: "A paper", sourceType: .article, localFilePath: pdf.path)
        paper.content = "The canonical text of the paper."
        try store.saveSource(paper)
        try store.execForTesting("""
            INSERT INTO source_review_guides (source_id, source_sha256, guide, generator_version, generated_at)
            VALUES ('\(paper.id)', 'abc123', '# What to look for', 1, 1)
        """)
        try store.queueSourceFilesBackfill()
        #expect(try store.runSourceFilesBackfill() == 1)
        #expect(try store.runSourceFilesBackfill() == 0, "resumable: nothing left")

        let rows = try #require(try SourceProjection.loadRows(localID: paper.id, connection: store))
        let pdfRef = try #require(rows.files["pdf"].flatMap(FileRef.init(json:)))
        #expect(pdfRef.owner == paper.id && pdfRef.hash == SyncIdentity.sha256Hex(pdfBytes) && pdfRef.isWellFormed)
        #expect(pdfRef.encoding == "identity" && pdfRef.isInline && pdfRef.parts == [FileRef.partHash32(pdfBytes)])
        let textRef = try #require(rows.files["text"].flatMap(FileRef.init(json:)))
        #expect(textRef.encoding == "gzip" && textRef.hash == SyncIdentity.sha256Hex(Data("The canonical text of the paper.".utf8)))
        let staged = try #require(try Fixture.text(store, "SELECT local_path FROM source_files WHERE source_id = ? AND role = 'text'", [.text(paper.id)]))
        let stagedBytes = try Data(contentsOf: root.appendingPathComponent(staged))
        #expect(FileRef.partHash32(stagedBytes) == textRef.parts.first, "the staged bytes are the part it names")
        #expect(String(decoding: try SyncGzip.decompress(stagedBytes, maxBytes: 1 << 20), as: UTF8.self) == "The canonical text of the paper.")
        let guide = try #require(rows.derived["reviewGuide"].flatMap(FileRef.init(json:)))
        #expect(guide.value["gen"]?["input"] == "abc123", "a machine output names what it was made from")
        #expect(try store.sourceID(forWorkKeys: ["file:" + pdfRef.hash], teamID: nil) == paper.id)
        #expect(SourceProjection.encodeRows(rows)["files"]?["pdf"] == pdfRef.value)
    }
}

/// An inbound change reaches the models that hold the rows in memory (`AppliedRemoteChanges`). Regression of
/// 2026-10-06: on build 189 a source's title and author fixed on another device reached `knowledge.db` and
/// never the view model, so the Mac's lists and MCP's `filter_sources` kept "… - by Alex Plesa", by
/// "Substack", and the next save of that copy would have sent them back.
@Suite("Inbound changes reach the loaded models")
struct AppliedRemoteChangesTests {
    private typealias Fixture = SourceSyncFixture

    static let staleTitle = "AI for Bio Doesn’t Need More Data - by Alex Plesa"
    static let fixedTitle = "AI for Bio Doesn’t Need More Data"

    /// What a store's handler was told, one entry per committed apply.
    final class Told: @unchecked Sendable {
        private let lock = NSLock()
        private var changes: [AppliedRemoteChanges] = []
        func append(_ change: AppliedRemoteChanges) { lock.withLock { changes.append(change) } }
        var all: [AppliedRemoteChanges] { lock.withLock { changes } }
    }

    private struct Missing: Error {}

    /// The article as the Mac that kept the old copy held it: saved, sent and acknowledged. Not queued, so a
    /// view model's reload starts no fetch.
    static func staleArticle() -> StudioArticle {
        var article = StudioArticle(url: "https://substack.com/home/post/p-214954598", title: staleTitle, sourceType: .article, author: "Substack")
        article.state = .error
        article.errorMessage = "Not fetched in this test"
        return article
    }

    /// A store holding the stale article as sent, with a handler that records what each apply changed.
    static func makeStore(_ name: String) throws -> (root: URL, store: KnowledgeStore, article: StudioArticle, told: Told) {
        let (root, store) = try Fixture.makeStore(name)
        try Fixture.prepareReplica(store)
        let article = staleArticle()
        try store.saveSource(article)
        try Fixture.sendAll(store)
        let told = Told()
        store.appliedRemoteChangesHandler = { told.append($0) }
        return (root, store, article, told)
    }

    private static func recordName(_ id: String) -> String {
        RecordNaming.recordName(type: .source, id: id, salt: Fixture.salt)
    }

    private static func cloudRecord(_ id: String, payload: Data) -> CloudRecord {
        CloudRecord(id: CloudRecordID(recordName(id), in: CloudZoneID("Catalog")), recordType: SyncRecordType.source.rawValue,
                    encryptedFields: [CloudRecord.payloadKey: .bytes(payload)], systemFields: Data([8]))
    }

    /// The server's copy once another device fixed the title and the author: the version this Mac sent, with the
    /// two fields stamped later by that device.
    static func fixedOnAnotherDevice(_ store: KnowledgeStore, _ id: String) throws -> CloudRecord {
        guard let held = try store.replica.record(zoneKey: Fixture.catalogZoneKey, recordName: recordName(id)) else { throw Missing() }
        var envelope = try SyncEnvelope(storedPayload: held.payload)
        var patch = RecordPatch(.source, id: id)
        patch.changes["title"] = .value(.string(fixedTitle))
        patch.changes["authors"] = .value(.array(["Alex Plesa"]))
        let later = Int64(Date().timeIntervalSince1970 * 1000) + 60_000
        var counter = 0
        try envelope.apply(patch) { _, policy, _ in
            counter += 1
            return SyncStamp(policy: policy, milliseconds: later, counter: counter, deviceID: "otheraaa")
        }
        return cloudRecord(id, payload: try envelope.storedPayload())
    }

    /// The server's copy this Mac sent, coming back unchanged.
    private static func ownSaveComingBack(_ store: KnowledgeStore, _ id: String) throws -> CloudRecord {
        guard let held = try store.replica.record(zoneKey: Fixture.catalogZoneKey, recordName: recordName(id)) else { throw Missing() }
        return cloudRecord(id, payload: held.payload)
    }

    /// Applies fetched records the way the engine does, through the Mac's local half.
    static func absorb(_ records: [CloudRecord], local: MacPrivateSyncStore) async throws {
        try await local.perform { state in
            try state.replica.apply { _ in
                let inbound = try InboundApply(state: state, now: Date(), passStart: Date(), moveMaps: MoveMapIndex())
                for record in records { _ = try inbound.absorbFetched(record, zoneKey: Fixture.catalogZoneKey) }
            }
        }
    }

    @Test("A title and author fixed on another device are told once the apply commits, as generation 1 told them")
    func remoteFixIsTold() async throws {
        let (root, store, article, told) = try Self.makeStore("applied-remote-fix")
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try Self.fixedOnAnotherDevice(store, article.id)
        try await Self.absorb([record], local: .direct(store, registry: Fixture.registry))

        #expect(try Fixture.text(store, "SELECT title || '|' || author FROM articles WHERE source_id = ?", [.text(article.id)])
                == "\(Self.fixedTitle)|Alex Plesa")
        #expect(told.all.count == 1, "one apply, one telling")
        let changes = try #require(told.all.first)
        #expect(changes.types == [.source])
        #expect(changes.entities.contains(.source), "the view model reloads the sources on it")
        let note = try #require(AppliedRemoteChangesAnnouncer.notification(for: changes))
        #expect(note.name == .cloudKitSyncRemoteStoreDidChange)
        let entities = note.userInfo?[CloudKitSyncNotificationInfo.affectedEntitiesKey] as? [String] ?? []
        #expect(entities.contains(CloudKitSyncEntity.source.rawValue))
        #expect(note.userInfo?[CloudKitSyncNotificationInfo.requiresFullRefreshKey] as? Bool == false)
        #expect(store.appliedRemoteChanges.isEmpty, "the note is handed on, not kept for the next apply")
        #expect(try Fixture.pending(store)["Source:\(article.id)"] == nil, "an applied record has nothing to send back")
    }

    @Test("This Mac's own save coming back changes nothing on screen and is not told")
    func ownSaveIsNotTold() async throws {
        let (root, store, article, told) = try Self.makeStore("applied-remote-echo")
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.absorb([try Self.ownSaveComingBack(store, article.id)], local: .direct(store, registry: Fixture.registry))
        #expect(told.all.isEmpty)
        #expect(try Fixture.text(store, "SELECT title FROM articles WHERE source_id = ?", [.text(article.id)]) == Self.staleTitle)
    }

    @Test("A deletion from another device is told; a rolled-back apply is not")
    func deletionToldRollbackNot() async throws {
        let (root, store, article, told) = try Self.makeStore("applied-remote-delete")
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try Self.fixedOnAnotherDevice(store, article.id)
        struct Abandoned: Error {}
        #expect(throws: Abandoned.self) {
            try store.replica.apply { replica in
                try replica.upsertRecord(ReplicaRecord(record, zoneKey: Fixture.catalogZoneKey, wireID: article.id, seenPass: nil))
                guard let row = try replica.record(zoneKey: Fixture.catalogZoneKey, recordName: Self.recordName(article.id)) else { throw Missing() }
                try ProjectionApply(store: store, registry: Fixture.registry).project(row)
                throw Abandoned()
            }
        }
        #expect(told.all.isEmpty, "nothing committed, nothing told")
        #expect(store.appliedRemoteChanges.isEmpty, "and nothing left over for the next apply")
        #expect(try Fixture.text(store, "SELECT title FROM articles WHERE source_id = ?", [.text(article.id)]) == Self.staleTitle)

        try await MacPrivateSyncStore.direct(store, registry: Fixture.registry).perform { state in
            try state.replica.apply { _ in
                let inbound = try InboundApply(state: state, now: Date(), passStart: nil, moveMaps: MoveMapIndex())
                try inbound.absorbDeletion(CloudRecordDeletion(id: CloudRecordID(Self.recordName(article.id), in: CloudZoneID("Catalog")),
                                                               recordType: SyncRecordType.source.rawValue),
                                           zoneKey: Fixture.catalogZoneKey)
            }
        }
        #expect(try Fixture.count(store, "SELECT COUNT(*) FROM sources WHERE id = ?", [.text(article.id)]) == 0)
        #expect(told.all.map(\.types) == [[.source]])
    }

    @Test("Every record type the Mac projects names what reloads it, or is silent on purpose")
    func everyProjectedTypeNamesItsSurfaces() {
        let silent: Set<SyncRecordType> = [.practice, .job, .device]
        for projection in KnowledgeStore.projectionRegistry.projections where !silent.contains(projection.recordType) {
            #expect(!AppliedRemoteChanges.entities(for: projection.recordType).isEmpty, "\(projection.recordType.rawValue)")
        }
        // The source list reads each of these with the source's own rows.
        for type in [SyncRecordType.readingState, .mark, .entry, .collection, .course, .lesson] {
            #expect(AppliedRemoteChanges.entities(for: type).contains(.source), "\(type.rawValue)")
        }
        var artifact = AppliedRemoteChanges()
        artifact.note(.artifact, localID: "art-1")
        let note = AppliedRemoteChangesAnnouncer.notification(for: artifact)
        #expect(note?.userInfo?[CloudKitSyncNotificationInfo.changedArtifactIDsKey] as? [String] == ["art-1"], "an open Page reads its body again")
        var silentOnly = AppliedRemoteChanges()
        silentOnly.note(.job, localID: "job-1")
        #expect(AppliedRemoteChangesAnnouncer.notification(for: silentOnly) == nil)
    }

    @Test("The view model's stale copy takes the fix, and saving it afterwards sends no title or author")
    @MainActor
    func viewModelTakesTheFix() async throws {
        let root = try Schema154Fixture.temporaryRoot("WP7-applied-remote-vm")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root, syncGeneration: .two)
        let told = Told()
        try await storage.performSync { store in
            try store.installOutboxTriggers(Fixture.registry)
            try Fixture.prepareReplica(store)
            store.appliedRemoteChangesHandler = { told.append($0) }
        }
        let article = Self.staleArticle()
        try await storage.saveSource(article)
        try await storage.performSync { try Fixture.sendAll($0) }
        let vm = StudioViewModel(storageService: storage, observeCloudKitChanges: false)
        vm.articles = [article]

        let id = article.id
        let record = try await storage.performStoreWork { try Self.fixedOnAnotherDevice($0, id) }
        try await Self.absorb([record], local: .onStorage(storage, registry: Fixture.registry))
        #expect(vm.articles.first?.title == Self.staleTitle, "nothing reloads the view model by itself")

        let changes = try #require(told.all.first)
        let note = try #require(AppliedRemoteChangesAnnouncer.notification(for: changes))
        let entities = Set((note.userInfo?[CloudKitSyncNotificationInfo.affectedEntitiesKey] as? [String] ?? []).compactMap(CloudKitSyncEntity.init(rawValue:)))
        await vm.refreshAfterCloudKitRemoteChange(affectedEntities: entities, requiresFullRefresh: false)
        let refreshed = try #require(vm.articles.first { $0.id == article.id })
        #expect(refreshed.title == Self.fixedTitle)
        #expect(refreshed.author == "Alex Plesa")

        try await storage.saveSource(refreshed)
        let pendingFields = try await storage.performStoreWork { store -> [String] in
            try Fixture.pending(store)["Source:\(id)"]?.stamps.keys.map(\.field) ?? []
        }
        #expect(!pendingFields.contains("title") && !pendingFields.contains("authors"), "\(pendingFields)")
    }
}

/// A save writes what it changes (2026-10-07). Under generation 2 a column a save changes is sent with a
/// new stamp and wins on every device, so a copy of a source taken before another device's change (a long
/// ingestion's snapshot, Refresh from Website's, the view model's before its reload) is written over the
/// row as it is stored by then, with only the fields its holder changed (`StudioArticle.written(over:)`).
/// Regression of src_7ba12412…: its title and author fixed on another device to "AI for Bio Doesn’t Need
/// More Data", by Alex Plesa, which a whole-source save of an older copy would have sent back.
@Suite("A save writes what it changes")
struct StaleSourceSaveTests {
    private typealias Fixture = SourceSyncFixture
    private typealias Remote = AppliedRemoteChangesTests

    @Test("A copy read before another device fixed the title and author keeps the fix and sends only its own change")
    func staleCopyKeepsTheFix() async throws {
        let (root, store, article, told) = try Remote.makeStore("stale-copy-save")
        defer { try? FileManager.default.removeItem(at: root) }
        var held = try #require(try store.loadSourceWithoutContent(article.id), "the copy a long task holds")
        try await Remote.absorb([try Remote.fixedOnAnotherDevice(store, article.id)], local: .direct(store, registry: Fixture.registry))
        let toldByApply = told.all.count

        held.wordCount = 812
        try store.saveSource(held)

        #expect(try Fixture.text(store, "SELECT title || '|' || author || '|' || word_count FROM articles WHERE source_id = ?", [.text(article.id)])
                == "\(Remote.fixedTitle)|Alex Plesa|812")
        let fields = try Fixture.pending(store)["Source:\(article.id)"]?.stamps.keys.map(\.field) ?? []
        #expect(!fields.contains("title") && !fields.contains("authors"), "\(fields)")
        #expect(fields.contains("metrics"), "the copy's own change is sent: \(fields)")
        #expect(told.all.count == toldByApply + 1, "whoever shows the stale copy reads the source again")
        #expect(told.all.last?.types == [.source])
    }

    @Test("A stale copy saved unchanged writes nothing over the fix")
    func untouchedStaleCopy() async throws {
        let (root, store, article, _) = try Remote.makeStore("stale-copy-untouched")
        defer { try? FileManager.default.removeItem(at: root) }
        let held = try #require(try store.loadSourceWithoutContent(article.id))
        try await Remote.absorb([try Remote.fixedOnAnotherDevice(store, article.id)], local: .direct(store, registry: Fixture.registry))

        try store.saveSource(held)

        #expect(try Fixture.text(store, "SELECT title || '|' || author FROM articles WHERE source_id = ?", [.text(article.id)])
                == "\(Remote.fixedTitle)|Alex Plesa")
        let fields = try Fixture.pending(store)["Source:\(article.id)"]?.stamps.keys.map(\.field) ?? []
        #expect(!fields.contains("title") && !fields.contains("authors"), "\(fields)")
    }

    @Test("A field changed and changed back is written: a retry that fails again puts its error back")
    func changedBackIsWritten() throws {
        let (root, store) = try Fixture.makeStore("source-changed-back")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        var article = Fixture.article("https://example.com/retry", title: "Retry")
        article.state = .error
        article.errorMessage = "Network"
        try store.saveSource(article)

        var copy = try #require(try store.loadSourceWithoutContent(article.id))
        copy.state = .queued
        copy.errorMessage = nil
        try store.saveSource(copy)
        copy.state = .error
        copy.errorMessage = "Network"
        try store.saveSource(copy)

        #expect(try Fixture.text(store, "SELECT state || '|' || COALESCE(error_message, '') FROM sources WHERE id = ?", [.text(article.id)])
                == "error|Network")
    }

    @Test("Saving a hidden source again keeps the date it was hidden")
    func hiddenKeepsItsDate() throws {
        let (root, store) = try Fixture.makeStore("source-hidden-date")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        let article = Fixture.article("https://example.com/hidden", title: "Hidden")
        try store.saveSource(article)
        let hiddenAt = Date(timeIntervalSinceReferenceDate: 780_000_000)
        try store.writeSourceHidden(article.id, hidden: true, hiddenAt: hiddenAt)

        var copy = try #require(try store.loadSourceWithoutContent(article.id))
        #expect(copy.isHidden)
        copy.wordCount = 99
        try store.saveSource(copy)

        let key = try store.personalStateSourceKey(article.id)
        #expect(try Fixture.count(store, "SELECT COUNT(*) FROM hidden_sources WHERE source_id = ? AND hidden_at = ?",
                                  [.text(key), .real(hiddenAt.timeIntervalSinceReferenceDate)]) == 1)
    }

    @Test("Generation 1 still writes the whole copy")
    func generationOneWritesWhole() throws {
        let root = try Schema154Fixture.temporaryRoot("WP7-stale-copy-generation-one")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root, syncGeneration: .one, freeSpace: Schema154Fixture.roomy)
        let article = Remote.staleArticle()
        try store.saveSource(article)
        let held = try #require(try store.loadSourceWithoutContent(article.id))
        try store.execForTesting("UPDATE articles SET title = 'Fixed elsewhere' WHERE source_id = '\(article.id)'")

        try store.saveSource(held)

        #expect(try Fixture.text(store, "SELECT title FROM articles WHERE source_id = ?", [.text(article.id)]) == Remote.staleTitle)
    }
}
