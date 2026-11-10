// Search index row tests: embedding prefix deletes, full-text rows and out-of-search sources.

import Testing
import CloudKit
import Foundation
import SQLite3
@testable import ForeverLM

/// Creates an in-memory KnowledgeStore for unit testing.
private func makeInMemoryStore() throws -> KnowledgeStore {
    try KnowledgeStore(inMemory: true)
}

/// Helper: create a StudioArticle with sensible defaults for testing.
private func makeArticle(url: String, title: String? = nil) -> StudioArticle {
    var article = StudioArticle(url: url, title: title)
    article.normalizedURL = URLNormalizer.normalize(url)
    return article
}

// MARK: - Search index rows found by key (schema 168)

/// A source's chunk vectors go as a range on the embeddings key, which matches the prefix
/// exactly: an id that only shares the source's leading characters, differs from it in case
/// or holds LIKE's wildcards keeps its vectors.
@Suite("Embedding prefix deletes")
struct EmbeddingPrefixDeleteTests {
    private static func chunk(_ sourceID: String, _ index: Int = 0) -> String {
        StorageService.sourceChunkEmbeddingId(sourceId: sourceID, index: index)
    }

    private static func save(_ store: KnowledgeStore, _ entityID: String, type: KnowledgeEntityType = .sourceChunk, model: String = "m") throws {
        try store.saveEmbedding(entityType: type, entityId: entityID, vector: [1, 0], model: model)
    }

    /// Every embedding left, as `type/id/model`.
    private static func left(_ store: KnowledgeStore) throws -> Set<String> {
        var rows: Set<String> = []
        try store.query("SELECT entity_type || '/' || entity_id || '/' || model FROM embeddings") { stmt in
            if let row = store.string(stmt, 0) { rows.insert(row) }
        }
        return rows
    }

    @Test("One source's chunks go; an id sharing its leading characters or differing in case keeps its own")
    func deletesOneSourceExactly() throws {
        let store = try makeInMemoryStore()
        let neighbours = ["src_ab", "src_A", "SRC_A", "src_", "src_a_"]
        for id in ["src_a"] + neighbours {
            try Self.save(store, Self.chunk(id, 0))
            try Self.save(store, Self.chunk(id, 1))
        }
        // At the range's edges: a proper prefix of the prefix, its bound, and an id past the bound.
        for edge in ["src_a::chunk:", "src_a::chunk:;", "src_a::chunk:;0000"] {
            try Self.save(store, edge)
        }
        // The same id as another kind of entity.
        try Self.save(store, Self.chunk("src_a"), type: .concept)

        try store.deleteEmbeddings(entityType: .sourceChunk, entityIdPrefix: StorageService.sourceChunkEmbeddingPrefix(for: "src_a"))

        var expected: Set<String> = [
            "source_chunk/src_a::chunk:/m", "source_chunk/src_a::chunk:;/m", "source_chunk/src_a::chunk:;0000/m",
            "concept/\(Self.chunk("src_a"))/m",
        ]
        for id in neighbours {
            expected.insert("source_chunk/\(Self.chunk(id, 0))/m")
            expected.insert("source_chunk/\(Self.chunk(id, 1))/m")
        }
        #expect(try Self.left(store) == expected)
    }

    @Test("A source id holding LIKE's wildcards matches only itself")
    func wildcardsAreLiteral() throws {
        let store = try makeInMemoryStore()
        for id in ["a_b%c", "aXbYYc", "a_b%cd"] {
            try Self.save(store, Self.chunk(id))
        }

        try store.deleteEmbeddings(entityType: .sourceChunk, entityIdPrefix: StorageService.sourceChunkEmbeddingPrefix(for: "a_b%c"))

        #expect(try Self.left(store) == ["source_chunk/\(Self.chunk("aXbYYc"))/m", "source_chunk/\(Self.chunk("a_b%cd"))/m"])
    }

    @Test("Given a model, only that model's chunks of the source go")
    func deletesOneModel() throws {
        let store = try makeInMemoryStore()
        for model in ["m", "n"] {
            try Self.save(store, Self.chunk("src_a"), model: model)
            try Self.save(store, Self.chunk("src_ab"), model: model)
        }

        try store.deleteEmbeddings(entityType: .sourceChunk, entityIdPrefix: StorageService.sourceChunkEmbeddingPrefix(for: "src_a"), model: "m")

        #expect(try Self.left(store) == [
            "source_chunk/\(Self.chunk("src_a"))/n", "source_chunk/\(Self.chunk("src_ab"))/m", "source_chunk/\(Self.chunk("src_ab"))/n",
        ])
    }

    @Test("The bound sorts, in SQLite's own order, after every text that begins with the prefix and before every other above it")
    func upperBound() throws {
        #expect(KnowledgeStore.textPrefixUpperBound("src_a::chunk::") == "src_a::chunk:;")
        #expect(KnowledgeStore.textPrefixUpperBound("é") == "ê")
        #expect(KnowledgeStore.textPrefixUpperBound("a\u{D7FF}") == "a\u{E000}")
        #expect(KnowledgeStore.textPrefixUpperBound("a\u{10FFFF}") == "b")
        #expect(KnowledgeStore.textPrefixUpperBound("\u{10FFFF}") == nil)
        #expect(KnowledgeStore.textPrefixUpperBound("") == nil)

        let store = try makeInMemoryStore()
        let texts = ["", "a", "A", "ab", "a\u{D7FF}", "a\u{D7FF}x", "a\u{E000}", "a\u{FFFF}", "a\u{10000}",
                     "a\u{10FFFF}", "a\u{10FFFF}z", "b", "e", "e\u{301}", "é", "ê"]
        for prefix in ["a", "a\u{D7FF}", "a\u{10FFFF}", "e", "é", ""] {
            let bound = KnowledgeStore.textPrefixUpperBound(prefix)
            for text in texts {
                var values: [SQLiteValue] = [.text(text), .text(prefix)]
                if let bound { values.append(.text(bound)) }
                let inRange = try store.scalarInteger(
                    bound == nil ? "SELECT ?1 >= ?2" : "SELECT ?1 >= ?2 AND ?1 < ?3", values
                ) == 1
                #expect(inRange == text.unicodeScalars.starts(with: prefix.unicodeScalars), "\(prefix.debugDescription) / \(text.debugDescription)")
            }
        }
    }
}

/// A source's full-text row is found by the rowid `source_fts_rows` keeps for it (schema 168),
/// not by reading every row for the UNINDEXED `source_id`.
@Suite("Full-text rows by rowid")
struct SourceFTSRowTests {
    /// The full-text rows' sources, in order.
    static func rows(_ store: KnowledgeStore) throws -> [String] {
        var ids: [String] = []
        try store.query("SELECT source_id FROM source_fts ORDER BY source_id") { stmt in
            if let id = store.string(stmt, 0) { ids.append(id) }
        }
        return ids
    }

    /// Whether the map holds one rowid for each row, and each rowid is its source's row.
    static func mapIsExact(_ store: KnowledgeStore) throws -> Bool {
        try store.scalarInteger("""
            SELECT (SELECT COUNT(*) FROM source_fts_rows) = (SELECT COUNT(*) FROM source_fts)
               AND NOT EXISTS (
                    SELECT 1 FROM source_fts_rows r
                    WHERE NOT EXISTS (SELECT 1 FROM source_fts f WHERE f.rowid = r.fts_rowid AND f.source_id = r.source_id)
               )
        """) == 1
    }

    static func matches(_ store: KnowledgeStore, _ term: String) throws -> [String] {
        try store.searchSourceFTS(matchExpression: "\"\(term)\"", limit: 20).map { $0.id }.sorted()
    }

    @Test("Deleting one source's row leaves every other source's, an id sharing its leading characters or differing in case included")
    func deleteLeavesOtherSources() throws {
        let store = try makeInMemoryStore()
        for id in ["src_a", "src_ab", "src_A", "src_"] {
            try store.replaceSourceFTS(sourceID: id, title: "Title of \(id)", author: "", body: "mitochondria")
        }

        try store.deleteSourceFTS(sourceID: "src_a")

        #expect(try Self.rows(store) == ["src_", "src_A", "src_ab"])
        #expect(try Self.matches(store, "mitochondria") == ["src_", "src_A", "src_ab"])
        #expect(try Self.mapIsExact(store))
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM source_fts_state WHERE source_id = 'src_a'") == 0)
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM source_fts_state") == 3)
    }

    @Test("Writing a source's row again replaces it: one row, the new words, under its new rowid")
    func replaceKeepsOneRow() throws {
        let store = try makeInMemoryStore()
        try store.replaceSourceFTS(sourceID: "src_a", title: "First", author: "", body: "glycolysis")
        try store.replaceSourceFTS(sourceID: "src_ab", title: "Neighbour", author: "", body: "glycolysis")
        try store.replaceSourceFTS(sourceID: "src_a", title: "Second", author: "", body: "oxphos")

        #expect(try Self.rows(store) == ["src_a", "src_ab"])
        #expect(try Self.matches(store, "glycolysis") == ["src_ab"])
        #expect(try Self.matches(store, "oxphos") == ["src_a"])
        #expect(try Self.mapIsExact(store))
    }

    @Test("A stamp dropped to have the row written again keeps the rowid, so the rewrite replaces the row")
    func droppedStampKeepsTheRowid() throws {
        let store = try makeInMemoryStore()
        try store.replaceSourceFTS(sourceID: "src_a", title: "A <i>marked</i> title", author: "", body: "")
        // What a repaired title does (`restoreRegisteredPaperTitle`, the schema-144 folds).
        try store.execute("DELETE FROM source_fts_state WHERE source_id = 'src_a'")

        try store.replaceSourceFTS(sourceID: "src_a", title: "A plain title", author: "", body: "")

        #expect(try Self.rows(store) == ["src_a"])
        #expect(try Self.matches(store, "marked").isEmpty)
        #expect(try Self.mapIsExact(store))
    }

    @Test("A rowid the map should not hold takes no other source's row")
    func staleRowidTakesNothing() throws {
        let store = try makeInMemoryStore()
        try store.replaceSourceFTS(sourceID: "src_a", title: "A", author: "", body: "")
        try store.replaceSourceFTS(sourceID: "src_b", title: "B", author: "", body: "")
        try store.execute("""
            UPDATE source_fts_rows SET fts_rowid = (SELECT fts_rowid FROM source_fts_rows WHERE source_id = 'src_b')
            WHERE source_id = 'src_a'
        """)

        try store.deleteSourceFTS(sourceID: "src_a")

        #expect(try Self.rows(store).contains("src_b"))
    }

    @Test("Inside a caller's transaction the row, its rowid and its stamp roll back together")
    func joinsTheCallersTransaction() throws {
        let store = try makeInMemoryStore()
        try store.replaceSourceFTS(sourceID: "src_a", title: "Kept", author: "", body: "")
        try store.replaceSourceFTS(sourceID: "src_b", title: "Also kept", author: "", body: "")

        try store.execute("BEGIN IMMEDIATE")
        try store.replaceSourceFTS(sourceID: "src_a", title: "Rolled back", author: "", body: "")
        try store.deleteSourceFTS(sourceID: "src_b")
        try store.execute("ROLLBACK")

        #expect(try Self.rows(store) == ["src_a", "src_b"])
        #expect(try Self.matches(store, "kept") == ["src_a", "src_b"])
        #expect(try Self.matches(store, "rolled").isEmpty)
        #expect(try Self.mapIsExact(store))
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM source_fts_state") == 2)
    }

    @Test("A rewrite that fails partway leaves the old row, its rowid and its stamp as they were")
    func failedRewriteChangesNothing() throws {
        let store = try makeInMemoryStore()
        try store.replaceSourceFTS(sourceID: "src_a", title: "Kept", author: "", body: "")
        try store.execute("CREATE TEMP TRIGGER refuse_stamp BEFORE INSERT ON source_fts_state BEGIN SELECT RAISE(ABORT, 'refused'); END")

        #expect(throws: (any Error).self) {
            try store.replaceSourceFTS(sourceID: "src_a", title: "Lost", author: "", body: "")
        }

        #expect(try Self.matches(store, "kept") == ["src_a"])
        #expect(try Self.matches(store, "lost").isEmpty)
        #expect(try Self.mapIsExact(store))
        #expect(sqlite3_get_autocommit(store.db) != 0, "no transaction is left open")
    }
}

/// Full-text rows written before schema 168 kept no rowid. The migration stages their record
/// (`source_fts_row_backfill`); the indexer records them in batches after launch, and a write
/// that comes first records the rest before it looks for its row.
@Suite("Full-text rows written before schema 168")
struct SourceFTSRowBackfillTests {
    /// Rows as builds before 168 wrote them, straight into `source_fts` with a stamp and no rowid
    /// kept, `stampless` ones with their stamp dropped since, and the record staged as the
    /// migration stages it.
    private static func storeWithOldRows(_ ids: [String], stampless: Set<String> = []) throws -> KnowledgeStore {
        let store = try makeInMemoryStore()
        for id in ids {
            try store.execute(
                "INSERT INTO source_fts (source_id, title, author, body) VALUES (?, ?, '', 'mitochondria')",
                [.text(id), .text("Title of \(id)")]
            )
            guard !stampless.contains(id) else { continue }
            try store.execute(
                "INSERT OR REPLACE INTO source_fts_state (source_id, analyzer_version, written_at) VALUES (?, ?, 0)",
                [.text(id), .integer(Int64(SourceSearchEngine.indexAnalyzerVersion))]
            )
        }
        try store.enqueueSourceFTSRowBackfill()
        return store
    }

    private static func pending(_ store: KnowledgeStore) throws -> Bool {
        try store.scalarInteger("SELECT COUNT(*) FROM source_fts_row_backfill") == 1
    }

    @Test("A delete before the record is done records every old row first, then takes only its own")
    func deleteRecordsTheOldRowsFirst() throws {
        let store = try Self.storeWithOldRows(["src_a", "src_ab", "src_A", "src_b"], stampless: ["src_b"])

        try store.deleteSourceFTS(sourceID: "src_a")

        #expect(try SourceFTSRowTests.rows(store) == ["src_A", "src_ab", "src_b"])
        #expect(try SourceFTSRowTests.mapIsExact(store))
        #expect(try !Self.pending(store))

        // A row whose stamp was dropped since is found all the same.
        try store.deleteSourceFTS(sourceID: "src_b")
        #expect(try SourceFTSRowTests.rows(store) == ["src_A", "src_ab"])
        #expect(try SourceFTSRowTests.mapIsExact(store))
    }

    @Test("A source's row written while old rows wait leaves no old row of it behind")
    func writeWhileOldRowsWait() throws {
        let store = try Self.storeWithOldRows(["src_a", "src_b"])

        try store.replaceSourceFTS(sourceID: "src_new", title: "New", author: "", body: "oxphos")
        try store.replaceSourceFTS(sourceID: "src_a", title: "A again", author: "", body: "oxphos")

        #expect(try SourceFTSRowTests.rows(store) == ["src_a", "src_b", "src_new"])
        #expect(try SourceFTSRowTests.matches(store, "mitochondria") == ["src_b"])
        #expect(try SourceFTSRowTests.matches(store, "oxphos") == ["src_a", "src_new"])
        #expect(try SourceFTSRowTests.mapIsExact(store))
        #expect(try !Self.pending(store))
    }

    @Test("Batches record the old rows in rowid order, pass over rows written meanwhile, and the last retires the record")
    func batches() throws {
        let store = try Self.storeWithOldRows((0..<5).map { "src_\($0)" })

        #expect(try store.recordSourceFTSRows(limit: 2))
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM source_fts_rows") == 2)
        #expect(try store.scalarInteger("SELECT after_rowid FROM source_fts_row_backfill") == 2)
        // A source already recorded is written again between batches.
        try store.replaceSourceFTS(sourceID: "src_0", title: "Again", author: "", body: "oxphos")
        #expect(try store.recordSourceFTSRows(limit: 2))
        #expect(try store.recordSourceFTSRows(limit: 2))
        #expect(try !store.recordSourceFTSRows(limit: 2))

        #expect(try !Self.pending(store))
        #expect(try SourceFTSRowTests.rows(store) == (0..<5).map { "src_\($0)" })
        #expect(try SourceFTSRowTests.mapIsExact(store))
        // Nothing left to record: an answer at once.
        #expect(try !store.recordSourceFTSRows(limit: 2))
    }

    @Test("Two rows for one source keep the later")
    func twoRowsKeepTheLater() throws {
        let store = try makeInMemoryStore()
        try store.execute("""
            INSERT INTO source_fts (source_id, title, author, body) VALUES
                ('src_a', 'Earlier', '', 'glycolysis'),
                ('src_b', 'Other', '', 'glycolysis'),
                ('src_a', 'Later', '', 'oxphos')
        """)
        try store.enqueueSourceFTSRowBackfill()

        #expect(try !store.recordSourceFTSRows(limit: nil))

        #expect(try SourceFTSRowTests.rows(store) == ["src_a", "src_b"])
        #expect(try SourceFTSRowTests.matches(store, "glycolysis") == ["src_b"])
        #expect(try SourceFTSRowTests.matches(store, "oxphos") == ["src_a"])
        #expect(try SourceFTSRowTests.mapIsExact(store))
    }

    @Test("With nothing staged, a source with no rowid kept has no row, and no row is read to look for one")
    func nothingStagedLooksNowhere() throws {
        let store = try makeInMemoryStore()
        // Planted: a row no rowid names, which only a write outside `replaceSourceFTS` leaves. A
        // delete that still read every row's id would find and take it.
        try store.execute("INSERT INTO source_fts (source_id, title, author, body) VALUES ('planted', 'Planted', '', 'glycolysis')")

        try store.deleteSourceFTS(sourceID: "planted")
        try store.replaceSourceFTS(sourceID: "planted", title: "Written", author: "", body: "oxphos")

        #expect(try SourceFTSRowTests.matches(store, "glycolysis") == ["planted"])
        #expect(try SourceFTSRowTests.matches(store, "oxphos") == ["planted"])
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM source_fts_rows") == 1)
    }
}

/// An archived or deleted source leaves search whole: its full-text row, the stamps and rowid kept
/// for it, the record of being indexed and its vectors of every model. Before 2026-10-06 an
/// archive or delete arriving by sync took none of it, a duplicate's archive left its vectors, a
/// delete left its full-text row, and the vector index loaded every stored chunk at launch: on the
/// production library 391 archived or deleted sources held some of it, among them 263 full-text rows
/// and 36,705 vectors.
@Suite("A source out of search")
struct SourceOutOfSearchTests {
    private static let model = StorageService.sourceEmbeddingModel

    /// A source as the indexer leaves one: a full-text row holding `word`, its stamps, two chunk
    /// vectors of the current model, one of an older model and a source-level vector.
    private static func indexedSource(_ store: KnowledgeStore, _ name: String, word: String) throws -> String {
        var article = makeArticle(url: "https://example.com/\(name)", title: "Title of \(name)")
        _ = try store.insertSourceIfNew(&article)
        try store.replaceSourceFTS(sourceID: article.id, title: "Title of \(name)", author: "", body: word)
        for index in 0..<2 {
            try store.saveEmbedding(
                entityType: .sourceChunk,
                entityId: StorageService.sourceChunkEmbeddingId(sourceId: article.id, index: index),
                vector: [1, 0],
                model: model
            )
        }
        try store.saveEmbedding(
            entityType: .sourceChunk,
            entityId: StorageService.sourceChunkEmbeddingId(sourceId: article.id, index: 0),
            vector: [0, 1],
            model: "an-older-model"
        )
        try store.saveEmbedding(entityType: .source, entityId: article.id, vector: [1, 1], model: model)
        try store.recordSourceIndexed(sourceID: article.id, model: model)
        return article.id
    }

    /// What search still holds of `id`.
    private static func held(_ store: KnowledgeStore, _ id: String) throws -> Set<String> {
        var parts: Set<String> = []
        let checks: [(String, String)] = [
            ("full-text row", "SELECT COUNT(*) FROM source_fts WHERE source_id = ?1"),
            ("rowid", "SELECT COUNT(*) FROM source_fts_rows WHERE source_id = ?1"),
            ("analyzer stamp", "SELECT COUNT(*) FROM source_fts_state WHERE source_id = ?1"),
            ("indexed record", "SELECT COUNT(*) FROM source_index_state WHERE source_id = ?1"),
            ("chunk vectors", "SELECT COUNT(*) FROM embeddings WHERE entity_type = 'source_chunk' AND entity_id >= ?1 || '::chunk::' AND entity_id < ?1 || '::chunk:;'"),
            ("source vector", "SELECT COUNT(*) FROM embeddings WHERE entity_type = 'source' AND entity_id = ?1"),
        ]
        for (part, sql) in checks {
            if (try store.scalarInteger(sql, [.text(id)]) ?? 0) > 0 { parts.insert(part) }
        }
        return parts
    }

    private static let everything: Set<String> = ["full-text row", "rowid", "analyzer stamp", "indexed record", "chunk vectors", "source vector"]

    private static func keywordHits(_ store: KnowledgeStore, _ word: String) throws -> Set<String> {
        Set(try store.searchSourceFTS(matchExpression: "\"\(word)\"", limit: 20).map(\.id))
    }

    @Test("Archiving takes the whole of a source out of search, and another source keeps all of its own")
    func archiveTakesItAll() throws {
        let store = try makeInMemoryStore()
        let archived = try Self.indexedSource(store, "archived", word: "telomere")
        let kept = try Self.indexedSource(store, "kept", word: "telomere")
        #expect(try Self.held(store, archived) == Self.everything)

        try store.archiveSource(archived)

        #expect(try Self.held(store, archived).isEmpty)
        #expect(try Self.held(store, kept) == Self.everything)
        #expect(try Self.keywordHits(store, "telomere") == [kept])
        #expect(try store.sourcesOutOfSearchHoldingSearchRows(limit: 10).isEmpty)
    }

    @Test("Deleting takes the full-text row and the stamps too, not only the vectors")
    func deleteTakesItAll() throws {
        let store = try makeInMemoryStore()
        let deleted = try Self.indexedSource(store, "deleted", word: "mitophagy")

        try store.deleteSourceRows(deleted)

        #expect(try Self.held(store, deleted).isEmpty)
        #expect(try Self.keywordHits(store, "mitophagy").isEmpty)
    }

    @Test("Clearing a source's text takes its full-text row with the vectors, so the old words are not found")
    func clearedTextLeavesNoRow() throws {
        let store = try makeInMemoryStore()
        let cleared = try Self.indexedSource(store, "cleared", word: "glycolysis")

        try store.clearSourceDerivedData(cleared)

        #expect(try Self.held(store, cleared).isEmpty)
        #expect(try Self.keywordHits(store, "glycolysis").isEmpty)
    }

    @Test("An archive or a delete that took nothing with it is found, and dropping its rows leaves the active sources alone")
    func sweepFindsWhatSyncLeft() throws {
        let store = try makeInMemoryStore()
        let active = try Self.indexedSource(store, "active", word: "ketone")
        let archivedBySync = try Self.indexedSource(store, "archived-by-sync", word: "ketone")
        let deletedBySync = try Self.indexedSource(store, "deleted-by-sync", word: "ketone")
        // What an inbound record applies (`SourceProjection.apply`, `applyDeletion`): the row
        // changes and nothing else does.
        try store.execute("UPDATE sources SET status = 'archived' WHERE id = ?", [.text(archivedBySync)])
        try store.execute("DELETE FROM sources WHERE id = ?", [.text(deletedBySync)])
        #expect(try Self.keywordHits(store, "ketone") == [active, archivedBySync, deletedBySync], "keyword search reads no status")

        let found = try store.sourcesOutOfSearchHoldingSearchRows(limit: 10)
        #expect(found == [archivedBySync, deletedBySync].sorted())
        for id in found { try store.dropSourceSearchRows(sourceID: id) }

        #expect(try store.sourcesOutOfSearchHoldingSearchRows(limit: 10).isEmpty)
        #expect(try Self.held(store, archivedBySync).isEmpty)
        #expect(try Self.held(store, deletedBySync).isEmpty)
        #expect(try Self.held(store, active) == Self.everything)
        #expect(try Self.keywordHits(store, "ketone") == [active])
    }

    @Test("An archived source holding only vectors, as older builds left them, is found too, a page at a time")
    func vectorsAloneAreFound() throws {
        let store = try makeInMemoryStore()
        var ids: [String] = []
        for name in ["a", "b", "c"] {
            let id = try Self.indexedSource(store, name, word: "lactate")
            try store.execute("UPDATE sources SET status = 'archived' WHERE id = ?", [.text(id)])
            // The full-text row, its stamps and the indexed record went; the vectors stayed.
            try store.deleteSourceFTS(sourceID: id)
            try store.deleteSourceIndexState(sourceID: id)
            #expect(try Self.held(store, id) == ["chunk vectors", "source vector"])
            ids.append(id)
        }

        #expect(try store.sourcesOutOfSearchHoldingSearchRows(limit: 2) == Array(ids.sorted().prefix(2)))
        #expect(try store.sourcesOutOfSearchHoldingSearchRows(limit: 10) == ids.sorted())
        #expect(try store.sourcesOutOfSearchHoldingSearchRows(limit: 0).isEmpty)
    }

    @Test("The service's sweep takes out a deleted source's full-text row, so search stops finding it")
    func serviceSweep() async throws {
        let svc = try makeInMemoryService()
        var article = makeArticle(url: "https://example.com/kept", title: "Butyrate and the colon")
        try await svc.insertSourceIfNew(&article)
        try await svc.replaceSourceFTS(sourceID: article.id, title: "Butyrate and the colon", author: "", body: "butyrate")
        // A full-text row whose source was deleted by sync.
        try await svc.replaceSourceFTS(sourceID: "src_deleted_elsewhere", title: "Gone", author: "", body: "butyrate")
        let before = await svc.searchSources(queryText: "butyrate", queryVector: nil, limit: 5).map(\.sourceId)
        #expect(Set(before) == [article.id, "src_deleted_elsewhere"])

        #expect(try await svc.dropSearchRowsOfSourcesOutOfSearch(limit: 64) == 1)
        #expect(try await svc.dropSearchRowsOfSourcesOutOfSearch(limit: 64) == 0)

        let after = await svc.searchSources(queryText: "butyrate", queryVector: nil, limit: 5).map(\.sourceId)
        #expect(after == [article.id])
    }

    @Test("The vector index loads only the chunks of sources in search")
    func vectorLoadKeepsSourcesInSearch() {
        let chunk = { (source: String, index: Int) in StorageService.sourceChunkEmbeddingId(sourceId: source, index: index) }
        let embeddings: [String: [Float]] = [
            chunk("src_a", 0): [1], chunk("src_a", 1): [2], chunk("src_ab", 0): [3], chunk("src_gone", 0): [4], "not-a-chunk": [5],
        ]
        let kept = StorageService.chunkVectors(embeddings, ofSourcesIn: ["src_a", "src_ab"])
        #expect(Set(kept.keys) == [chunk("src_a", 0), chunk("src_a", 1), chunk("src_ab", 0)])
        #expect(StorageService.chunkVectors(embeddings, ofSourcesIn: []).isEmpty)
    }
}

/// What three released steps staged once, for the drains these tests exercise: the registered-title
/// check of every paper with a DOI, the transcript check of every YouTube video of the learner's own,
/// and the full-text row backfill. The steps went with schema 174's floor.
extension KnowledgeStore {
    func enqueueRegisteredPaperTitleChecks() throws -> Int {
        try execute("""
            INSERT INTO paper_registered_title_queue (source_id, enqueued_at)
            SELECT p.source_id, ?
            FROM papers p
            JOIN sources s ON s.id = p.source_id
            WHERE TRIM(COALESCE(p.doi, '')) <> ''
              AND TRIM(COALESCE(p.title, '')) <> ''
            ON CONFLICT(source_id) DO NOTHING
        """, [.real(Date().timeIntervalSinceReferenceDate)])
        return try registeredPaperTitleQueueCount()
    }

    func enqueueYouTubeTranscriptChecks() throws -> Int {
        try execute("""
            INSERT INTO youtube_transcript_check_queue (source_id, enqueued_at)
            SELECT v.source_id, ?
            FROM videos v
            JOIN sources s ON s.id = v.source_id
            WHERE s.team_id IS NULL
              AND (v.url LIKE '%youtube.com/%' OR v.url LIKE '%youtu.be/%')
            ON CONFLICT(source_id) DO NOTHING
        """, [.real(Date().timeIntervalSinceReferenceDate)])
        return try youTubeTranscriptCheckQueueCount()
    }

    func enqueueSourceFTSRowBackfill() throws {
        try execute("""
            INSERT INTO source_fts_row_backfill (singleton, after_rowid, enqueued_at)
            VALUES (1, 0, ?)
            ON CONFLICT(singleton) DO NOTHING
        """, [.real(Date().timeIntervalSinceReferenceDate)])
    }
}
