import Foundation
import Testing
@testable import ForeverLM

/// A second Mac takes the ingestion another Mac already did (docs/backend-storage-sync.md, "A source another
/// Mac finished"): a Source that arrives `ready` is attested, its text and a paper's PDF are fetched from the
/// satellites that Mac published, and the sweeps that look for unprocessed sources leave it alone, so nothing
/// is downloaded, extracted, cleaned or attested by a model a second time.
@Suite("Source ingest adoption", .serialized)
struct SourceIngestAdoptionTests {
    typealias F = SourceSyncFixture

    private static let paperID = "src_2f9b0b1c5c1d4a1c9d7e3a0b6f4e8d21"
    private static let articleID = "src_a1b2c3d4e5f60718293a4b5c6d7e8f90"
    private static let text = "Mitochondria make most of the cell's ATP. " + String(repeating: "Canonical text of the paper. ", count: 30)
    private static let pdf = Data("%PDF-1.7 a paper another Mac downloaded".utf8)

    private static func hash(_ text: String) -> String { SyncIdentity.sha256Hex(Data(text.utf8)) }

    private static func file(_ id: String, _ role: String, text: String? = nil, bytes: Data? = nil) -> FileRef {
        let body = bytes ?? Data((text ?? "").utf8)
        return FileRef(
            owner: id, role: role, hash: SyncIdentity.sha256Hex(body), size: Int64(body.count),
            mime: role == "pdf" ? "application/pdf" : role == "figures" ? "application/json" : "text/plain",
            encoding: role == "pdf" ? "identity" : "gzip", storedParts: [body]
        )
    }

    /// A Source record as the Mac that finished the work sent it.
    private static func record(
        _ id: String, type: String = "paper", ingest: String = "ready", text: String? = Self.text, pdf: Bool = true,
        figures: Data? = nil
    ) throws -> ReplicaRecord {
        var files: [String: SyncJSON] = [:]
        if let text { files["text"] = file(id, "text", text: text).value }
        if pdf { files["pdf"] = file(id, "pdf", bytes: Self.pdf).value }
        var fields: [String: SyncJSON] = [
            "primaryKey": .string("native:\(id)"),
            "workKeys": .object(["native:\(id)": true]),
            "type": .string(type),
            "title": "Mitochondrial inference",
            "authors": .array(["Ada Researcher"]),
            "url": .string("https://example.org/\(id)"),
            "publishedAt": SyncJSON(Int64(1_767_225_600_000)),
            "status": "active",
            "ingest": .object(["ord": .array([1, ingest == "ready" ? 4 : 1]), "state": .string(ingest), "at": SyncJSON(Int64(1_759_000_000_000)), "device": "macaaaaa"]),
            "meta": .object(type == "paper" ? ["journal": "Nature"] : [:]),
            "addedAt": SyncJSON(Int64(1_759_100_000_000)),
            "madeBy": .object(["route": "app", "device": "macaaaaa", "at": SyncJSON(Int64(1_759_100_000_000))]),
            "files": .object(files),
        ]
        if let text { fields["contentHash"] = .string(hash(text)) }
        if let figures { fields["derived"] = .object(["figures": file(id, "figures", bytes: figures).value]) }
        return try F.record(.source, id, fields)
    }

    private static func makeStore(_ name: String) throws -> (root: URL, store: KnowledgeStore) {
        let (root, store) = try F.makeStore(name)
        try F.prepareReplica(store)
        return (root, store)
    }

    private static func waiting(_ store: KnowledgeStore, _ id: String = paperID) throws -> [String: SyncJSON] {
        try InboundSourceFiles.waiting(sourceID: id, connection: store)
    }

    // MARK: The record

    @Test("A paper that arrives ready is attested, and its text and PDF are queued for the reader, with nothing sent back")
    func readyPaperIsAttestedAndQueued() throws {
        let (root, store) = try Self.makeStore("ingest-attest")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.apply(store, [try Self.record(Self.paperID)])

        #expect(try F.text(store, "SELECT paper_ingestion_method FROM papers WHERE source_id = ?", [.text(Self.paperID)]) == "synced")
        let waiting = try Self.waiting(store)
        #expect(waiting["text"].flatMap(FileRef.init(json:))?.hash == Self.hash(Self.text))
        #expect(waiting["pdf"].flatMap(FileRef.init(json:))?.hash == SyncIdentity.sha256Hex(Self.pdf))
        #expect(waiting[InboundSourceFiles.zoneField] == nil, "the learner's own Content zone is the default")
        #expect(try F.pending(store)["Source:\(Self.paperID)"] == nil, "an applied record has nothing to send back")
        #expect(try store.sourceIDsIngestedOnAnotherDevice().contains(Self.paperID))
    }

    @Test("A paper another Mac has not finished is not attested, and a source this Mac made is not one the sweeps skip")
    func unfinishedAndOwnSourcesAreNotAdopted() throws {
        let (root, store) = try Self.makeStore("ingest-unfinished")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.apply(store, [try Self.record(Self.paperID, ingest: "queued", text: nil, pdf: false)])
        try NotebookSyncFixture.addSource(store, "own-source")

        #expect(try F.text(store, "SELECT paper_ingestion_method FROM papers WHERE source_id = ?", [.text(Self.paperID)]) == nil)
        #expect(try Self.waiting(store).isEmpty)
        #expect(try store.sourceIDsIngestedOnAnotherDevice().isEmpty)
    }

    @Test("A text this Mac made since is kept; an untouched copy of the old pointer's text is replaced by the new one")
    func localTextIsKeptUnlessItIsTheOldPointers() throws {
        let (root, store) = try Self.makeStore("ingest-keep")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = "The first canonical text. " + String(repeating: "alpha ", count: 40)
        let second = "The second canonical text. " + String(repeating: "beta ", count: 40)
        try F.apply(store, [try Self.record(Self.paperID, text: first, pdf: false)])

        // This Mac made a text of its own: the newer pointer does not replace it.
        try store.execute("INSERT INTO source_content (source_id, content) VALUES (?, ?)", [.text(Self.paperID), .text("My own cleaned text.")])
        try store.execute("DELETE FROM ck_backfill_queue")
        try F.apply(store, [try Self.record(Self.paperID, text: second, pdf: false)])
        #expect(try Self.waiting(store).isEmpty)

        // This Mac holds exactly the text the pointer names now (the second): a third is the newer version of it.
        let third = "The third canonical text. " + String(repeating: "gamma ", count: 40)
        try store.execute("UPDATE source_content SET content = ? WHERE source_id = ?", [.text(second), .text(Self.paperID)])
        try F.apply(store, [try Self.record(Self.paperID, text: third, pdf: false)])
        let waiting = try Self.waiting(store)
        #expect(waiting["text"].flatMap(FileRef.init(json:))?.hash == Self.hash(third))
        #expect(waiting[InboundSourceFiles.replacesField] == .string(Self.hash(second)))
    }

    @Test("Deleting a source takes its queued satellites with it")
    func deletedSourceLeavesNoWish() throws {
        let (root, store) = try Self.makeStore("ingest-delete")
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try Self.record(Self.paperID)
        try F.apply(store, [record])
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_backfill_queue WHERE kind = 'sourceSatellites'") == 1)
        try store.replica.apply { _ in
            try ProjectionApply(store: store, registry: F.registry).projectDeletion(
                zoneKey: record.zoneKey, recordName: record.recordName, type: .source, wireID: Self.paperID
            )
        }
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_backfill_queue WHERE kind = 'sourceSatellites'") == 0)
    }

    // MARK: Rows applied before this Mac took their work

    @Test("The adoption pass catches a ready source applied before: it attests the paper and queues what it lacks, once")
    func adoptionPassCatchesEarlierRows() throws {
        let (root, store) = try Self.makeStore("ingest-gap")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.apply(store, [try Self.record(Self.paperID)])
        // A library as an earlier build left it: attestation and queue never written.
        try store.execute("UPDATE papers SET paper_ingestion_method = NULL")
        try store.execute("DELETE FROM ck_backfill_queue")

        #expect(try store.adoptSyncedSources() >= 1)
        #expect(try F.text(store, "SELECT paper_ingestion_method FROM papers WHERE source_id = ?", [.text(Self.paperID)]) == "synced")
        #expect(try Self.waiting(store)["text"] != nil && Self.waiting(store)["pdf"] != nil)
        #expect(try store.adoptSyncedSources() == 0, "nothing is left to do")
        #expect(try F.pending(store)["Source:\(Self.paperID)"] == nil)
    }

    @Test("Text a Mac already stores for a source another Mac finished is recorded as cleaned; a source it owes a clean-up keeps it")
    func adoptionRecordsTheCleanupOfStoredText() throws {
        let (root, store) = try Self.makeStore("ingest-prep")
        defer { try? FileManager.default.removeItem(at: root) }
        let owed = "src_0e1d2c3b4a5968778695a4b3c2d1e0f1"
        try F.apply(store, [
            try Self.record(Self.paperID, text: nil, pdf: false),
            try Self.record(Self.articleID, type: "article", text: nil, pdf: false),
            try Self.record(owed, type: "article", text: nil, pdf: false),
        ])
        for id in [Self.paperID, Self.articleID, owed] {
            try store.execute("INSERT INTO source_content (source_id, content) VALUES (?, ?)", [.text(id), .text(Self.text)])
        }
        try store.execute("""
            INSERT INTO canonical_content_cleanup_queue (source_id, target_version, enqueued_at, attempt_count, last_error)
            VALUES (?, ?, 1, 0, NULL)
        """, [.text(owed), .integer(Int64(PaperContentPreparationMetadata.currentVersion))])

        try store.adoptSyncedSources()
        let version = Int64(PaperContentPreparationMetadata.currentVersion)
        #expect(try F.count(store, "SELECT COUNT(*) FROM paper_content_preparations WHERE source_id = ? AND cleaner_version = ? AND clean_sha256 = ?",
                            [.text(Self.paperID), .integer(version), .text(PaperContentPreparationService.sha256(Self.text))]) == 1)
        #expect(try F.count(store, "SELECT COUNT(*) FROM article_content_preparations WHERE source_id = ? AND cleaner_version = ?",
                            [.text(Self.articleID), .integer(version)]) == 1)
        #expect(try F.count(store, "SELECT COUNT(*) FROM article_content_preparations WHERE source_id = ?", [.text(owed)]) == 0,
                "a source this Mac's own queue still owes a clean-up keeps it")
    }

    // MARK: The reader

    @Test("The reader installs the text and the PDF, so the paper is ready here without a download, an extraction or a model")
    func readerInstallsTextAndPDF() async throws {
        let (root, store) = try Self.makeStore("ingest-reader")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ingest-pdfs-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: folder)
        }
        try F.apply(store, [try Self.record(Self.paperID)])
        let text = Data(Self.text.utf8)
        let pdf = Self.pdf

        // A body that is not the one the pointer names is not taken, and spends an attempt.
        let wrong = SatelliteReader(store: .direct(store)) { _ in Data("some other bytes".utf8) }
        let wrongTaken = await KnowledgeStore.$installedSourceFileRootOverride.withValue(folder) { await wrong.drain() }
        #expect(wrongTaken == 0)
        #expect(try F.count(store, "SELECT COUNT(*) FROM source_content WHERE source_id = ?", [.text(Self.paperID)]) == 0)
        #expect(try F.count(store, "SELECT attempts FROM ck_backfill_queue WHERE kind = 'sourceSatellites'") == 1)

        let reader = SatelliteReader(store: .direct(store)) { file in file.role == "pdf" ? pdf : text }
        let taken = await KnowledgeStore.$installedSourceFileRootOverride.withValue(folder) { await reader.drain() }
        #expect(taken == 2)

        #expect(try F.text(store, "SELECT content FROM source_content WHERE source_id = ?", [.text(Self.paperID)]) == Self.text)
        let version = Int64(PaperContentPreparationMetadata.currentVersion)
        #expect(try F.count(store, "SELECT COUNT(*) FROM paper_content_preparations WHERE source_id = ? AND cleaner_version = ?",
                            [.text(Self.paperID), .integer(version)]) == 1, "the clean-up is recorded, so the versioned re-clean never queues it")
        let path = try #require(try F.text(store, "SELECT local_file_path FROM papers WHERE source_id = ?", [.text(Self.paperID)]))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == pdf)
        #expect(try F.text(store, "SELECT local_path FROM source_files WHERE source_id = ? AND role = 'pdf'", [.text(Self.paperID)]) == path)
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_backfill_queue WHERE kind = 'sourceSatellites'") == 0)
        #expect(try F.pending(store)["Source:\(Self.paperID)"] == nil, "what the reader installs is never sent back")

        // Read as the app reads it, the paper is final: attested, cleaned, with its text and its file.
        let article = try #require(try store.loadSources().first { $0.id == Self.paperID })
        #expect(article.hasPaperIngestionAttestation && article.hasCompletedPaperContentCleanup && article.isPaperReadyForListenPreparation)
        #expect(try store.hasReadableSourceContent(Self.paperID))
        let takenAgain = await reader.drain()
        #expect(takenAgain == 0, "nothing is fetched twice")
    }

    @Test("An exhausted satellite fetch reuses identical text and PDF already held by another source")
    func readerReusesLocallyHeldSatellites() async throws {
        let (root, store) = try Self.makeStore("ingest-local-reuse")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ingest-local-reuse-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: folder)
        }

        let heldID = "src_11111111111111111111111111111111"
        let wantedID = "src_22222222222222222222222222222222"
        try F.apply(store, [try Self.record(heldID)])
        let first = SatelliteReader(store: .direct(store)) { file in
            file.role == InboundSourceFiles.pdfRole ? Self.pdf : Data(Self.text.utf8)
        }
        let firstTaken = await KnowledgeStore.$installedSourceFileRootOverride.withValue(folder) { await first.drain() }
        #expect(firstTaken == 2)

        try F.apply(store, [try Self.record(wantedID)])
        try store.execute(
            "UPDATE ck_backfill_queue SET attempts = 5, last_error = 'remote parts are gone' WHERE kind = ? AND target = ?",
            [.text(InboundSourceFiles.queueKind), .text(wantedID)]
        )
        let unavailable = SatelliteReader(store: .direct(store)) { file in
            throw BlobStoreError.missingParts(file.parts)
        }
        let reused = await KnowledgeStore.$installedSourceFileRootOverride.withValue(folder) { await unavailable.drain() }

        #expect(reused == 2, "the exhausted wish remains eligible because exact local bodies exist")
        #expect(try F.text(store, "SELECT content FROM source_content WHERE source_id = ?", [.text(wantedID)]) == Self.text)
        let wantedPath = try #require(try F.text(store, "SELECT local_file_path FROM papers WHERE source_id = ?", [.text(wantedID)]))
        let wantedURL = wantedPath.hasPrefix("/")
            ? URL(fileURLWithPath: wantedPath)
            : folder.appendingPathComponent(wantedPath)
        #expect(try Data(contentsOf: wantedURL) == Self.pdf)
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_backfill_queue WHERE kind = ? AND target = ?", [
            .text(InboundSourceFiles.queueKind), .text(wantedID),
        ]) == 0)
    }

    // MARK: A paper never stays "PDF needed" on one Mac while another holds its PDF

    @Test("A paper whose own path names a file that is gone fetches the PDF its record names")
    func goneOwnPathFetchesTheRecordsPDF() async throws {
        let (root, store) = try Self.makeStore("ingest-gone-path")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ingest-gone-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: folder)
        }
        try F.apply(store, [try Self.record(Self.paperID)])
        // This Mac wrote a path of its own (an ingestion it started itself) whose file is not on disk.
        let gonePath = "Papers/gone-\(UUID().uuidString).pdf"
        try store.execute("UPDATE papers SET local_file_path = ? WHERE source_id = ?", [.text(gonePath), .text(Self.paperID)])
        try store.execute("DELETE FROM ck_backfill_queue")
        #expect(try store.papersHoldingAPathInsteadOfTheirPDF().map(\.id) == [Self.paperID])

        let reader = SatelliteReader(store: .direct(store)) { file in file.role == "pdf" ? Self.pdf : Data(Self.text.utf8) }
        _ = await KnowledgeStore.$installedSourceFileRootOverride.withValue(folder) { await reader.drain() }

        let path = try #require(try F.text(store, "SELECT local_file_path FROM papers WHERE source_id = ?", [.text(Self.paperID)]))
        #expect(path != gonePath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Self.pdf)
        #expect(try F.pending(store)["Source:\(Self.paperID)"] == nil, "the repair sends nothing")
        #expect(try store.papersHoldingAPathInsteadOfTheirPDF().isEmpty)
    }

    @Test("A paper whose own path names a file on disk is left alone")
    func presentOwnPathIsKept() async throws {
        let (root, store) = try Self.makeStore("ingest-present-path")
        let held = FileManager.default.temporaryDirectory.appendingPathComponent("held-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: held)
        }
        try F.apply(store, [try Self.record(Self.paperID, text: nil)])
        try Data("%PDF-1.7 this Mac's own copy".utf8).write(to: held)
        try store.execute("UPDATE papers SET local_file_path = ? WHERE source_id = ?", [.text(held.path), .text(Self.paperID)])
        try store.execute("DELETE FROM ck_backfill_queue")

        let reader = SatelliteReader(store: .direct(store)) { _ in Issue.record("nothing is fetched"); return Data() }
        _ = await reader.drain()
        #expect(try F.text(store, "SELECT local_file_path FROM papers WHERE source_id = ?", [.text(Self.paperID)]) == held.path)
    }

    @Test("A wish that failed five times gets one more try a launch, unless the server lacks its parts")
    func exhaustedWishesAreRetriedOnceALaunch() throws {
        let (root, store) = try Self.makeStore("ingest-exhausted")
        defer { try? FileManager.default.removeItem(at: root) }
        let failedID = "src_33333333333333333333333333333333"
        let goneID = "src_44444444444444444444444444444444"
        try F.apply(store, [try Self.record(failedID), try Self.record(goneID)])
        try store.execute("UPDATE ck_backfill_queue SET attempts = 5, last_error = 'failed(write error)' WHERE target = ?", [.text(failedID)])
        try store.execute("UPDATE ck_backfill_queue SET attempts = 5, last_error = 'missingParts([\"ct:x\"])' WHERE target = ?", [.text(goneID)])
        #expect(try store.dueSatelliteWishes().isEmpty)

        #expect(try store.retryExhaustedSatelliteWishes() == 1)
        #expect(try store.dueSatelliteWishes().map(\.target) == [failedID])
    }

    @Test("A fetch that fails for want of a network spends no attempt")
    func transientFailureSpendsNoAttempt() async throws {
        let (root, store) = try Self.makeStore("ingest-offline")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.apply(store, [try Self.record(Self.paperID)])
        let offline = SatelliteReader(store: .direct(store)) { _ in throw CloudError(.networkUnavailable, message: "offline") }
        for _ in 0..<6 { _ = await offline.drain() }
        #expect(try F.count(store, "SELECT attempts FROM ck_backfill_queue WHERE kind = 'sourceSatellites'") == 0)
    }

    @Test("Files in the old iCloud Drive folder move home, a differing one under its own name, and the emptied folders go")
    func strandedFilesMoveHomeAndTheOldFolderGoes() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("stranded-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let content = base.appendingPathComponent("Content", isDirectory: true)
        let documents = base.appendingPathComponent("Container/Documents", isDirectory: true)
        let old = documents.appendingPathComponent("ForeverLM", isDirectory: true)
        let fork = documents.appendingPathComponent("ForeverLM 2", isDirectory: true)
        let fm = FileManager.default
        for folder in [old.appendingPathComponent("Papers"), content.appendingPathComponent("Papers"), fork] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("stranded".utf8).write(to: old.appendingPathComponent("Papers/a.pdf"))
        try Data("current".utf8).write(to: old.appendingPathComponent("Papers/same.pdf"))
        try Data("current".utf8).write(to: content.appendingPathComponent("Papers/same.pdf"))
        try Data("old copy".utf8).write(to: old.appendingPathComponent("Papers/differs.pdf"))
        try Data("new copy".utf8).write(to: content.appendingPathComponent("Papers/differs.pdf"))

        let moved = StrandedSourceFiles.moveIntoContentRoot(
            ["Papers/a.pdf", "Papers/same.pdf", "Papers/differs.pdf", "Papers/missing.pdf", "../escape.pdf"],
            contentRoot: content.path, oldRoot: old.path
        )
        #expect(moved == 3)
        #expect(try Data(contentsOf: content.appendingPathComponent("Papers/a.pdf")) == Data("stranded".utf8))
        #expect(!fm.fileExists(atPath: old.appendingPathComponent("Papers/a.pdf").path))
        #expect(!fm.fileExists(atPath: old.appendingPathComponent("Papers/same.pdf").path))
        #expect(try Data(contentsOf: content.appendingPathComponent("Papers/differs.pdf")) == Data("new copy".utf8), "the file the rows name stays")
        #expect(try Data(contentsOf: content.appendingPathComponent("Papers/differs-from-icloud.pdf")) == Data("old copy".utf8), "the other one is kept")
        #expect(!fm.fileExists(atPath: fork.path), "an empty fork folder goes")
        #expect(!fm.fileExists(atPath: old.path), "nothing is left of the old folder")
        #expect(fm.fileExists(atPath: documents.path), "the container's own folder stays")
    }

    @Test("Text another Mac sends over this Mac's copy drops the search index built from the old words, even at the same length")
    func replacedTextDropsTheOldIndex() async throws {
        let (root, store) = try Self.makeStore("ingest-reindex")
        defer { try? FileManager.default.removeItem(at: root) }
        let second = "The second canonical text. " + String(repeating: "beta ", count: 40)
        let third = "The third canonical text.. " + String(repeating: "gama ", count: 40)
        #expect(second.count == third.count, "the indexer notices a change of length by itself; this one it cannot")
        try F.apply(store, [try Self.record(Self.paperID, text: second, pdf: false)])
        try store.execute("INSERT INTO source_content (source_id, content) VALUES (?, ?)", [.text(Self.paperID), .text(second)])
        // The index this Mac built from the second text, written as the indexer writes it.
        try store.replaceSourceFTS(sourceID: Self.paperID, title: "Mitochondrial inference", author: "", body: second)
        try store.execute("INSERT INTO source_index_state (source_id, model, content_length, file_path, indexed_at) VALUES (?, 'm', ?, '', 1)",
                          [.text(Self.paperID), .integer(Int64(second.count))])
        try store.execute("INSERT INTO embeddings (entity_type, entity_id, model, vector, updated_at) VALUES (?, ?, 'm', x'00', 1)",
                          [.text(KnowledgeEntityType.sourceChunk.rawValue), .text(StorageService.sourceChunkEmbeddingId(sourceId: Self.paperID, index: 0))])
        try store.execute("DELETE FROM ck_backfill_queue")

        try F.apply(store, [try Self.record(Self.paperID, text: third, pdf: false)])
        let reader = SatelliteReader(store: .direct(store)) { _ in Data(third.utf8) }
        #expect(await reader.drain() == 1)

        #expect(try F.text(store, "SELECT content FROM source_content WHERE source_id = ?", [.text(Self.paperID)]) == third)
        #expect(try F.count(store, "SELECT COUNT(*) FROM source_fts WHERE source_id = ?", [.text(Self.paperID)]) == 0)
        #expect(try F.count(store, "SELECT COUNT(*) FROM source_index_state WHERE source_id = ?", [.text(Self.paperID)]) == 0)
        #expect(try F.count(store, "SELECT COUNT(*) FROM embeddings WHERE entity_id LIKE ?", [.text(Self.paperID + "%")]) == 0)
        #expect(try F.pending(store)["Source:\(Self.paperID)"] == nil, "the text the record names is not sent back")
    }

    /// A figure index with the analysis another Mac paid a vision model for.
    private static func figuresBody(for id: String) throws -> (data: Data, figure: SyncedPaperFigure) {
        let analysis = PaperFigureAnalysis(
            summary: "The cristae fold into the inner membrane.", visualEvidence: ["a labelled micrograph"], figureRect: nil, panels: [],
            analysisVersion: PaperFigureAnalysis.currentVersion, generatedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
        let figure = SyncedPaperFigure(id: "fig_made_elsewhere", sourceID: id, figureLabel: "Figure 1", pageIndex: 2, caption: "Mitochondria.", analysis: analysis)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try encoder.encode([figure]), figure)
    }

    @Test("A paper's figure analysis arrives with it, under this Mac's own figure ids, so a review calls no vision model")
    func figureAnalysisIsInstalled() async throws {
        let (root, store) = try Self.makeStore("ingest-figures")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ingest-fig-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: folder)
        }
        let (body, figure) = try Self.figuresBody(for: Self.paperID)
        try F.apply(store, [try Self.record(Self.paperID, figures: body)])
        #expect(try Self.waiting(store)["figures"].flatMap(FileRef.init(json:))?.hash == SyncIdentity.sha256Hex(body))

        let text = Data(Self.text.utf8)
        let pdf = Self.pdf
        let reader = SatelliteReader(store: .direct(store)) { file in
            switch file.role {
            case "pdf": return pdf
            case "figures": return body
            default: return text
            }
        }
        let taken = await KnowledgeStore.$installedSourceFileRootOverride.withValue(folder) { await reader.drain() }
        #expect(taken == 3)
        let rows = try store.paperFigures(sourceID: Self.paperID)
        #expect(rows.count == 1)
        #expect(rows.first?.id == PaperFigureIndexContract.figureID(sourceID: Self.paperID, figureLabel: "Figure 1", pageIndex: 2))
        #expect(rows.first?.analysis == figure.analysis, "the analysis a vision model was paid for is kept")
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_backfill_queue WHERE kind = 'sourceSatellites'") == 0)
    }

    @Test("Figures this Mac indexed itself are kept, and the index this Mac publishes decodes to what it holds")
    func ownFiguresAreKeptAndPublishedAsTheyAre() throws {
        let (root, store) = try Self.makeStore("ingest-figures-own")
        defer { try? FileManager.default.removeItem(at: root) }
        let (body, figure) = try Self.figuresBody(for: Self.paperID)
        try F.apply(store, [try Self.record(Self.paperID, figures: body)])
        try store.execute("DELETE FROM ck_backfill_queue")
        let analysis = try String(decoding: JSONEncoder().encode(figure.analysis), as: UTF8.self)
        try store.execute(
            "INSERT INTO paper_figures (figure_id, source_id, figure_label, page_index, caption, analysis_json) VALUES ('fig_own', ?, 'Figure 1', 2, 'Mitochondria.', ?)",
            [.text(Self.paperID), .text(analysis)]
        )
        try F.apply(store, [try Self.record(Self.paperID, figures: body)])
        #expect(try Self.waiting(store)["figures"] == nil, "a Mac that built its own index does not take another")

        let published = try #require(try SourceSatelliteRoles.figuresBody(sourceID: Self.paperID, connection: store))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let figures = try decoder.decode([SyncedPaperFigure].self, from: published)
        #expect(figures.map(\.figureLabel) == ["Figure 1"] && figures.first?.analysis == figure.analysis)
        #expect(try SourceSatelliteRoles.figuresBody(sourceID: Self.paperID, connection: store) == published, "an unchanged index is the same bytes")
    }

    // MARK: What this Mac publishes

    @Test("A source ingested here after the activation is queued, laid out and pointed at, so the record carries its text and hash")
    func publisherQueuesAndPoints() throws {
        let (root, store) = try Self.makeStore("ingest-publish")
        defer { try? FileManager.default.removeItem(at: root) }
        var article = F.article("https://example.org/own", title: "Own article", state: .ready)
        article.content = Self.text
        try F.save(store, article)
        try store.execute("DELETE FROM ck_backfill_queue")
        // A source that owes a clean-up is not published until it is done.
        try store.execute("""
            INSERT OR IGNORE INTO canonical_content_cleanup_queue (source_id, target_version, enqueued_at, attempt_count, last_error)
            VALUES (?, ?, 1, 0, NULL)
        """, [.text(article.id), .integer(Int64(PaperContentPreparationMetadata.currentVersion))])
        #expect(try store.queueUnpublishedSourceFiles() == 0)
        try store.execute("DELETE FROM canonical_content_cleanup_queue")

        #expect(try store.queueUnpublishedSourceFiles() == 1)
        #expect(try store.queueUnpublishedSourceFiles() == 0, "a queued source is not queued again")
        let due = try store.dueSourcePublishItems(limit: 10)
        #expect(due.map(\.source) == [article.id])
        let plan = try #require(try store.sourcePublishPlan(sourceID: article.id))
        let item = try #require(plan.items.first { $0.role == "text" })
        #expect(item.body == Data(Self.text.utf8) && item.keeping == nil)

        let satellite = SourceLocalSatellite(
            map: item.map, role: item.role, mime: item.mime, encoding: item.encoding, body: item.body, localPath: nil, input: nil
        )
        let file = try SourceSatelliteLayout.layout(satellite, owner: article.id).file
        try store.pointPublishedSourceFiles(sourceID: article.id, files: [(item.map, file, nil)])
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_backfill_queue WHERE kind = ?", [.text(KnowledgeStore.sourcePublishKind)]) == 0)
        #expect(try store.queueUnpublishedSourceFiles() == 0, "a source with its pointer is done")

        let sent = try #require(F.savedFields(try F.pending(store)["Source:\(article.id)"]))
        #expect(sent["files"]?["text"] == file.value)
        #expect(sent["contentHash"] == .string(Self.hash(Self.text)))
    }

    @Test("A source this Mac does not own is never published, and a text that changed is queued again")
    func publisherLeavesOthersAndFollowsChanges() throws {
        let (root, store) = try Self.makeStore("ingest-publish-scope")
        defer { try? FileManager.default.removeItem(at: root) }
        try NotebookSyncFixture.addTeamCopy(store, "team-copy", of: "personal-1")
        try store.execute("INSERT INTO source_content (source_id, content) VALUES (?, ?)", [.text("team-copy"), .text(Self.text)])
        try store.execute("DELETE FROM ck_backfill_queue")
        #expect(try store.queueUnpublishedSourceFiles() == 0, "a team's copy is that space's to publish")
        try store.queueSourceFilesRefresh(sourceID: "team-copy")
        #expect(try store.sourcePublishPlan(sourceID: "team-copy") == nil)

        try store.execute("DELETE FROM ck_backfill_queue")
        try store.invalidateCanonicalContentIndexes(sourceID: "any-source")
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_backfill_queue WHERE kind = ?", [.text(KnowledgeStore.sourcePublishKind)]) == 1,
                "new canonical text queues the source's satellites again")
    }

    /// Points a source at every body its plan names, as the publisher does once they are up.
    private static func point(_ store: KnowledgeStore, _ plan: SourcePublishPlan) throws {
        let files = try plan.items.map { item in
            let satellite = SourceLocalSatellite(
                map: item.map, role: item.role, mime: item.mime, encoding: item.encoding, body: item.body, localPath: nil, input: item.input
            )
            return (map: item.map, file: try SourceSatelliteLayout.layout(satellite, owner: plan.sourceID).file, localPath: String?.none)
        }
        try store.pointPublishedSourceFiles(sourceID: plan.sourceID, files: files, queuedAt: plan.queuedAt)
    }

    private static func queuedForPublish(_ store: KnowledgeStore, _ id: String) throws -> Int64 {
        try F.count(store, "SELECT COUNT(*) FROM ck_backfill_queue WHERE kind = ? AND target = ?", [.text(KnowledgeStore.sourcePublishKind), .text(id)])
    }

    /// The 44 book chapters and 4 course sources of 2026-10-13: their text was rewritten through `saveSource`
    /// (MCP `update_source_content` takes this path) after the publisher had pointed them, and nothing queued them.
    @Test("A save that rewrites a published book chapter's text queues it to be published again; an unchanged save does not")
    func savedTextChangeIsPublishedAgain() throws {
        let (root, store) = try Self.makeStore("ingest-publish-saved-text")
        defer { try? FileManager.default.removeItem(at: root) }
        var chapter = F.article("https://example.org/books/primer/chapter-1", title: "Primer, chapter 1", type: .book, state: .ready)
        chapter.content = Self.text
        try F.save(store, chapter)
        try store.execute("DELETE FROM ck_backfill_queue")
        #expect(try store.queueUnpublishedSourceFiles() == 1)
        try Self.point(store, try #require(try store.sourcePublishPlan(sourceID: chapter.id)))
        #expect(try Self.queuedForPublish(store, chapter.id) == 0)

        try store.saveSource(chapter)
        #expect(try Self.queuedForPublish(store, chapter.id) == 0, "a save that keeps the text owes no upload")
        try store.queuePublishedSourceFilesRefresh(sourceID: "never-published")
        #expect(try Self.queuedForPublish(store, "never-published") == 0, "a source with no pointer is the sweep's")

        // As `update_source_content` does it: the stored copy, its text replaced, saved.
        var edited = try #require(try store.loadSourceForSync(chapter.id))
        edited.content = Self.text + " A closing line the edit added."
        try store.saveSource(edited)
        #expect(try Self.queuedForPublish(store, chapter.id) == 1, "the new text is published again")
        let plan = try #require(try store.sourcePublishPlan(sourceID: chapter.id))
        #expect(plan.items.first { $0.role == "text" }?.body == Data(edited.content!.utf8))
    }

    @Test("A text that changes while its publish is uploading keeps the source queued for the new text")
    func changeDuringPublishStaysQueued() throws {
        let (root, store) = try Self.makeStore("ingest-publish-in-flight")
        defer { try? FileManager.default.removeItem(at: root) }
        var article = F.article("https://example.org/in-flight", title: "In flight", type: .book, state: .ready)
        article.content = Self.text
        try F.save(store, article)
        try store.execute("DELETE FROM ck_backfill_queue")
        #expect(try store.queueUnpublishedSourceFiles() == 1)
        let first = try #require(try store.sourcePublishPlan(sourceID: article.id))

        // While the first plan's bodies are uploading, the text changes and the source is queued again.
        let changed = Self.text + " Written while the upload was under way."
        try store.execute("UPDATE source_content SET content = ? WHERE source_id = ?", [.text(changed), .text(article.id)])
        try store.invalidateCanonicalContentIndexes(sourceID: article.id)

        try Self.point(store, first)
        #expect(try Self.queuedForPublish(store, article.id) == 1, "the pointer names the old text, so the source stays queued")
        let second = try #require(try store.sourcePublishPlan(sourceID: article.id))
        #expect(second.items.first { $0.role == "text" }?.body == Data(changed.utf8))
        try Self.point(store, second)
        #expect(try Self.queuedForPublish(store, article.id) == 0)
        #expect(try F.text(store, "SELECT json_extract(file_ref, '$.hash') FROM source_files WHERE source_id = ? AND role = 'text'", [.text(article.id)])
                == Self.hash(changed))
    }

    // MARK: Two Macs

    /// Two Macs on one FakeCloudKit: A ingests, B only ever receives.
    final class Rig: @unchecked Sendable {
        let server: FakeCloudKit
        let a: EngineTestDevice
        let b: EngineTestDevice
        let clock = NotebookCoverFixture.Clock()
        let pdfFolder: URL
        let pdfFile: URL

        init() async throws {
            let server = EngineTestDriver.server()
            let a = try await NotebookCoverFixture.mac(server, "ingest-a", deviceID: "macaaaaa")
            let b = try EngineTestDevice(server, name: "ingest-b", deviceID: "macbbbbb", registry: KnowledgeStore.projectionRegistry)
            try await b.bootstrap(.macWithoutLibrary)
            try await b.sync()
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ingest-e2e-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.server = server
            self.a = a
            self.b = b
            pdfFolder = folder
            pdfFile = folder.appendingPathComponent("paper.pdf")
        }

        func cleanUp() { try? FileManager.default.removeItem(at: pdfFolder) }

        /// A paper as Mac A leaves one when its ingestion is done: ready, attested, with its PDF and cleaned text.
        func ingestPaper(on mac: EngineTestDevice, _ id: String) throws {
            try Self.pdfBytes.write(to: pdfFile)
            try mac.store.execute("INSERT INTO sources (id, date_added, state, source_type, status) VALUES (?, 1, 'ready', 'paper', 'active')", [.text(id)])
            try mac.store.execute("""
                INSERT INTO papers (source_id, url, normalized_url, title, domain, author, journal, published_year, local_file_path, is_paywalled, paper_ingestion_method)
                VALUES (?, ?, ?, 'Mitochondrial inference', 'example.org', 'Ada Researcher', 'Nature', '2026', ?, 0, 'llm')
            """, [.text(id), .text("https://example.org/\(id)"), .text("example.org/\(id)"), .text(pdfFile.path)])
            try mac.store.execute("INSERT INTO source_content (source_id, content) VALUES (?, ?)", [.text(id), .text(SourceIngestAdoptionTests.text)])
        }

        static let pdfBytes = Data("%PDF-1.7 the paper Mac A downloaded".utf8)

        func publisher(_ mac: EngineTestDevice, wrote: @escaping @Sendable () async -> Void = {}) -> SourceFilePublisher {
            let clock = clock
            return SourceFilePublisher(
                store: mac.local, blobs: MaintenanceFixture.blobs(mac, clock: { clock.now }), pendingCount: { 0 }, wrote: wrote
            )
        }

        func reader(_ mac: EngineTestDevice) -> SatelliteReader {
            let clock = clock
            return SatelliteReader.live(blobs: MaintenanceFixture.blobs(mac, clock: { clock.now }), store: mac.local)
        }
    }

    @Test("Mac B takes the paper Mac A ingested from the synced record and its satellites, and runs none of the ingestion")
    func secondMacTakesTheIngestion() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        let id = Self.paperID
        try rig.ingestPaper(on: rig.a, id)
        await EngineTestDriver.pause()
        try await rig.a.send()

        // The record alone: B is told the paper is finished, attests it, and has nothing to fetch yet.
        try await rig.b.fetch()
        #expect(try rig.b.text("SELECT paper_ingestion_method FROM papers WHERE source_id = ?", [.text(id)]) == "synced")
        #expect(try rig.b.count("SELECT COUNT(*) FROM source_content WHERE source_id = ?", [.text(id)]) == 0)
        #expect(try rig.b.store.sourceIDsIngestedOnAnotherDevice().contains(id), "the sweeps leave it alone")

        // A publishes the satellites it never uploaded (the seed only covers what existed at the cutover).
        let published = await rig.publisher(rig.a).run()
        #expect(published == 1)
        let publishedAgain = await rig.publisher(rig.a).run()
        #expect(publishedAgain == 0, "published once")
        await EngineTestDriver.pause()
        try await rig.a.send()
        let sent = try #require(try rig.a.serverEnvelope(.source, id, zone: "Catalog"))
        #expect(sent.fields["contentHash"]?.stringValue == Self.hash(Self.text))
        #expect(sent.fields["files"]?["text"] != nil && sent.fields["files"]?["pdf"] != nil)

        // B fetches both and installs them.
        try await rig.b.fetch()
        #expect(try rig.b.count("SELECT COUNT(*) FROM ck_backfill_queue WHERE kind = 'sourceSatellites'") == 1)
        let reader = rig.reader(rig.b)
        let taken = await KnowledgeStore.$installedSourceFileRootOverride.withValue(rig.pdfFolder) { await reader.drain() }
        #expect(taken == 2)
        #expect(try rig.b.text("SELECT content FROM source_content WHERE source_id = ?", [.text(id)]) == Self.text)
        let path = try #require(try rig.b.text("SELECT local_file_path FROM papers WHERE source_id = ?", [.text(id)]))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Rig.pdfBytes)
        let article = try #require(try rig.b.store.loadSources().first { $0.id == id })
        #expect(article.isPaperReadyForListenPreparation, "attested and cleaned, so Listen and Explain are open without a model call")
        #expect(try rig.b.count("SELECT COUNT(*) FROM ck_backfill_queue") == 0)
        #expect(try F.pending(rig.b.store)["Source:\(id)"] == nil, "B sends back nothing it took")
        let takenAgain = await reader.drain()
        #expect(takenAgain == 0)
    }
}
