import Foundation
import SQLite3
import OSLog
import CloudKit

extension KnowledgeStore {

    // MARK: - Embeddings

    func saveEmbedding(entityType: KnowledgeEntityType, entityId: String, vector: [Float], model: String = "default") throws {
        let data = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        let now = Date().timeIntervalSinceReferenceDate
        try execBind("""
            INSERT OR REPLACE INTO embeddings (entity_type, entity_id, model, vector, updated_at)
            VALUES (?,?,?,?,?)
        """) { stmt in
            bind(stmt, 1, entityType.rawValue)
            bind(stmt, 2, entityId)
            bind(stmt, 3, model)
            bind(stmt, 4, data)
            sqlite3_bind_double(stmt, 5, now)
        }
    }

    /// Delete the embeddings of `entityType` whose id begins with `entityIdPrefix`, of every model
    /// or of `model` alone. A source's chunk vectors are `<sourceID>::chunk::NNNN`, so
    /// `StorageService.sourceChunkEmbeddingPrefix(for:)` names one source's and no other's.
    ///
    /// The prefix is matched exactly, case and all, as a range on the primary key: every id that
    /// begins with it sorts at or after it and before `textPrefixUpperBound(_:)` of it, and no
    /// other id does. A `LIKE 'prefix%'` cannot seek the key, since SQLite's LIKE ignores ASCII
    /// case and the key compares bytes, so it read every chunk id in the store: 1.7 s cold for
    /// one source on the production library's 462,000 vectors, against 0.04 s for the range.
    func deleteEmbeddings(entityType: KnowledgeEntityType, entityIdPrefix: String, model: String? = nil) throws {
        var conditions = ["entity_type = ?", "entity_id >= ?"]
        var values = [entityType.rawValue, entityIdPrefix]
        if let upperBound = Self.textPrefixUpperBound(entityIdPrefix) {
            conditions.append("entity_id < ?")
            values.append(upperBound)
        }
        if let model {
            conditions.append("model = ?")
            values.append(model)
        }
        try execBind("DELETE FROM embeddings WHERE \(conditions.joined(separator: " AND "))") { stmt in
            for (offset, value) in values.enumerated() {
                bind(stmt, offset + 1, value)
            }
        }
    }

    /// The least text that sorts after every text beginning with `prefix` in SQLite's BINARY
    /// order, or nil when there is none (an empty prefix, or one of U+10FFFF alone). BINARY
    /// compares UTF-8 bytes, which order as the code points do, so the bound is `prefix` with its
    /// last scalar raised by one: past the surrogates, which no string holds, and with a last
    /// U+10FFFF dropped and the scalar before it raised instead.
    static func textPrefixUpperBound(_ prefix: String) -> String? {
        var scalars = Array(prefix.unicodeScalars)
        while let last = scalars.popLast() {
            let next = last.value == 0xD7FF ? 0xE000 : last.value + 1
            guard let raised = Unicode.Scalar(next) else { continue }
            scalars.append(raised)
            var bound = String.UnicodeScalarView()
            bound.append(contentsOf: scalars)
            return String(bound)
        }
        return nil
    }

    func loadEmbedding(entityType: KnowledgeEntityType, entityId: String, model: String = "default") throws -> [Float]? {
        var result: [Float]?
        try queryBind("SELECT vector FROM embeddings WHERE entity_type = ? AND entity_id = ? AND model = ?", bind: { stmt in
            self.bind(stmt, 1, entityType.rawValue)
            self.bind(stmt, 2, entityId)
            self.bind(stmt, 3, model)
        }) { stmt in
            let bytes = sqlite3_column_blob(stmt, 0)
            let length = Int(sqlite3_column_bytes(stmt, 0))
            guard let bytes, length > 0 else { return }
            let count = length / MemoryLayout<Float>.size
            var floats = [Float](repeating: 0, count: count)
            memcpy(&floats, bytes, length)
            result = floats
        }
        return result
    }

    /// Return just the entity IDs that have embeddings (no vector data loaded).
    func embeddedEntityIds(entityType: KnowledgeEntityType, model: String = EmbeddingSettings.modelID) throws -> Set<String> {
        var result = Set<String>()
        try queryBind("SELECT entity_id FROM embeddings WHERE entity_type = ? AND model = ?", bind: { stmt in
            self.bind(stmt, 1, entityType.rawValue)
            self.bind(stmt, 2, model)
        }) { stmt in
            guard let idPtr = sqlite3_column_text(stmt, 0) else { return }
            result.insert(String(cString: idPtr))
        }
        return result
    }

    /// Load all embeddings for a given entity type as a dictionary.
    func loadAllEmbeddings(entityType: KnowledgeEntityType, model: String = EmbeddingSettings.modelID) throws -> [String: [Float]] {
        var result: [String: [Float]] = [:]
        try queryBind("SELECT entity_id, vector FROM embeddings WHERE entity_type = ? AND model = ?", bind: { stmt in
            self.bind(stmt, 1, entityType.rawValue)
            self.bind(stmt, 2, model)
        }) { stmt in
            guard let idPtr = sqlite3_column_text(stmt, 0) else { return }
            let entityId = String(cString: idPtr)
            let bytes = sqlite3_column_blob(stmt, 1)
            let length = Int(sqlite3_column_bytes(stmt, 1))
            guard let bytes, length > 0 else { return }
            let count = length / MemoryLayout<Float>.size
            var floats = [Float](repeating: 0, count: count)
            memcpy(&floats, bytes, length)
            result[entityId] = floats
        }
        return result
    }

    /// Find entities most similar to a query vector using cosine similarity.
    /// Returns (entityId, score) pairs sorted by descending similarity.
    func findSimilar(
        queryVector: [Float],
        entityType: KnowledgeEntityType,
        model: String = EmbeddingSettings.modelID,
        topK: Int = 50,
        threshold: Float = 0.0
    ) throws -> [(id: String, score: Float)] {
        let all = try loadAllEmbeddings(entityType: entityType, model: model)
        guard !all.isEmpty else { return [] }

        // Precompute query norm
        var queryNormSq: Float = 0
        for v in queryVector { queryNormSq += v * v }
        let queryNorm = sqrt(queryNormSq)
        guard queryNorm > 0 else { return [] }

        var results: [(id: String, score: Float)] = []
        results.reserveCapacity(all.count)

        for (id, vec) in all {
            guard vec.count == queryVector.count else { continue }
            var dot: Float = 0
            var normSq: Float = 0
            for i in 0..<vec.count {
                dot += queryVector[i] * vec[i]
                normSq += vec[i] * vec[i]
            }
            let norm = sqrt(normSq)
            guard norm > 0 else { continue }
            let score = dot / (queryNorm * norm)
            if score >= threshold {
                results.append((id: id, score: score))
            }
        }

        results.sort { $0.score > $1.score }
        if results.count > topK {
            results = Array(results.prefix(topK))
        }
        return results
    }

    /// Bulk-save embeddings (used during migration from JSON).
    func saveEmbeddingsBatch(entityType: KnowledgeEntityType, embeddings: [String: [Float]], model: String = EmbeddingSettings.modelID) throws {
        let now = Date().timeIntervalSinceReferenceDate
        try exec("BEGIN IMMEDIATE")
        do {
            for (entityId, vector) in embeddings {
                let data = vector.withUnsafeBufferPointer { Data(buffer: $0) }
                try execBind("""
                    INSERT OR REPLACE INTO embeddings (entity_type, entity_id, model, vector, updated_at)
                    VALUES (?,?,?,?,?)
                """) { stmt in
                    bind(stmt, 1, entityType.rawValue)
                    bind(stmt, 2, entityId)
                    bind(stmt, 3, model)
                    bind(stmt, 4, data)
                    sqlite3_bind_double(stmt, 5, now)
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        logger.info("Saved \(embeddings.count) \(entityType.rawValue) embeddings")
    }

    /// Count embeddings for a given entity type and model.
    func embeddingCount(entityType: KnowledgeEntityType, model: String = EmbeddingSettings.modelID) throws -> Int {
        var count = 0
        try queryBind("SELECT COUNT(*) FROM embeddings WHERE entity_type = ? AND model = ?", bind: { stmt in
            self.bind(stmt, 1, entityType.rawValue)
            self.bind(stmt, 2, model)
        }) { stmt in
            count = Int(sqlite3_column_int(stmt, 0))
        }
        return count
    }

    // MARK: - Embedding Coverage

    /// Metadata for a source that the indexer needs to resolve its text and embed it.
    /// Deliberately lightweight — no content is loaded here so the full candidate list
    /// (thousands of sources) stays cheap to hold in memory; the indexer pulls content
    /// per source, in batches, as it drains.
    struct EmbeddingCandidate: Sendable {
        let id: String
        let sourceType: String
        let title: String
        let domain: String
        let author: String
        let localFilePath: String?
        /// A book chapter's pages of its book's file (`localFilePath`).
        var bookPages: Range<Int>? = nil
    }

    /// Whether a tool that opens one named source may read it: the ambient
    /// boundary (`knowledgeSearchExcludedSourceIDs`) keeps a family out of what
    /// search and discovery surface on their own, but a source the learner put
    /// into a chat is named, and the chat works with it fully, as Claude or
    /// Codex does with a file handed to them.
    static func isBlockedFromOpening(_ id: String, excluded: Set<String>) -> Bool {
        excluded.contains(id) && !ChatNamedSources.shared.contains(id)
    }

    /// Source ids that must not participate in ambient search or AI discovery.
    /// Two things draw this boundary: the per-family knowledge preference, and
    /// a hidden podcast show or YouTube channel (`is_collection_hidden`), whose
    /// episodes are muted for the AI as well as the list unless one carries a
    /// visible override. Hiding a single source is presentation state like tab
    /// pinning (product owner, 2026-09-11: "make hide purely visual", then "the shows
    /// that are hidden … remain hidden; … unhide specific episodes"), so
    /// `is_hidden` is deliberately not read here.
    ///
    /// Screen record mode (`ScreenRecordScope`, admin only) draws a third
    /// line: while it is on, every source outside the recording Notebook that
    /// was added before the take is excluded too. This is the one boundary
    /// every library-reading MCP tool and the app's own source search already
    /// consult, so a filmed connector take sees the same subset as the window.
    func knowledgeSearchExcludedSourceIDs(
        excludedTabs: Set<StudioSidebarTab> = StudioSidebarTab.excludedKnowledgeTabs(),
        includeArchived: Bool = false
    ) throws -> Set<String> {
        var excluded = try screenRecordExcludedSourceIDs(scope: screenRecordScope())
        let statusClause = includeArchived ? "" : " WHERE status = 'active'"
        try queryBind("""
            SELECT id, source_type, COALESCE(url, ''), is_collection_hidden
            FROM source_projection\(statusClause)
        """, bind: { _ in }) { stmt in
            guard let id = self.string(stmt, 0),
                  let rawType = self.string(stmt, 1),
                  let sourceType = StudioSourceType(rawValue: rawType) else { return }
            let url = self.string(stmt, 2) ?? ""
            let collectionHidden = sqlite3_column_int(stmt, 3) != 0
            let tab = StudioSidebarTab.knowledgeTab(sourceType: sourceType, url: url)
            if collectionHidden || tab.map(excludedTabs.contains) == true {
                excluded.insert(id)
            }
        }
        return excluded
    }

    /// Sources whose search index is missing or out of date — the indexer's work list.
    ///
    /// Covers **every active source**, not just `ready` ones: a queued or errored source is
    /// still in the user's library and must be findable, at minimum by title. Archived
    /// sources are excluded on purpose — archiving deliberately removes a source from
    /// search, and `archiveSource` drops its rows from both indexes.
    ///
    /// A source is out of date when the text it was indexed from has changed: its stored
    /// content grew (a transcript arrived) or a local file appeared (a PDF was attached).
    /// Comparing against the recorded fingerprint — rather than merely asking "does it have
    /// an embedding?" — is what stops a source indexed while title-only from looking
    /// finished forever. Because `source_index_state` is keyed by model, switching embedding
    /// models makes every source out of date and rebuilds the whole index.
    ///
    /// An audio overview's script is never indexed: it retells its notebook's sources,
    /// and a search hit or a citation must land on those sources, not on the retelling.
    func sourcesMissingIndex(model: String = EmbeddingSettings.modelID) throws -> [EmbeddingCandidate] {
        var candidates: [EmbeddingCandidate] = []
        try queryBind("""
            SELECT sp.id, sp.source_type, COALESCE(sp.title, ''), COALESCE(sp.domain, ''),
                   COALESCE(sp.author, ''), sp.local_file_path, sp.book_page_start, sp.book_page_count
            FROM source_projection sp
            LEFT JOIN source_content sc ON sc.source_id = sp.id
            LEFT JOIN source_index_state st ON st.source_id = sp.id AND st.model = ?
            WHERE sp.status = 'active'
              AND \(Self.notAudioOverviewScriptURL("sp.url"))
              AND (
                    st.source_id IS NULL
                 OR st.content_length != COALESCE(length(sc.content), 0)
                 OR st.file_path != COALESCE(sp.local_file_path, '')
                 -- A stamp with no vectors behind it. Every indexed source has a
                 -- chunk 0 (a source with no text gets a header-only one), so its
                 -- absence means the vectors were removed after the stamp — text
                 -- cleared and restored at the same length — and the stamp alone
                 -- would otherwise hide the source from search forever.
                 OR NOT EXISTS (
                        SELECT 1 FROM embeddings e
                        WHERE e.entity_type = ?
                          AND e.entity_id = sp.id || ?
                          AND e.model = ?
                    )
              )
        """, bind: { stmt in
            self.bind(stmt, 1, model)
            self.bind(stmt, 2, KnowledgeEntityType.sourceChunk.rawValue)
            self.bind(stmt, 3, StorageService.sourceChunkEmbeddingId(sourceId: "", index: 0))
            self.bind(stmt, 4, model)
        }) { stmt in
            guard let id = self.string(stmt, 0) else { return }
            candidates.append(
                EmbeddingCandidate(
                    id: id,
                    sourceType: self.string(stmt, 1) ?? "",
                    title: self.string(stmt, 2) ?? "",
                    domain: self.string(stmt, 3) ?? "",
                    author: self.string(stmt, 4) ?? "",
                    localFilePath: self.string(stmt, 5),
                    bookPages: self.bookPages(stmt, startColumn: 6)
                )
            )
        }
        return candidates
    }

    /// Record that a source has been indexed against the current version of its text.
    /// The fingerprint is read back from the DB rather than passed in, so it always
    /// reflects what is actually stored and can't drift from the gap query's view.
    func recordSourceIndexed(sourceID: String, model: String = EmbeddingSettings.modelID) throws {
        try execBind("""
            INSERT OR REPLACE INTO source_index_state (source_id, model, content_length, file_path, indexed_at)
            SELECT sp.id, ?, COALESCE(length(sc.content), 0), COALESCE(sp.local_file_path, ''), ?
            FROM source_projection sp
            LEFT JOIN source_content sc ON sc.source_id = sp.id
            WHERE sp.id = ?
        """) { stmt in
            bind(stmt, 1, model)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSinceReferenceDate)
            bind(stmt, 3, sourceID)
        }
    }

    /// Forget a source's index state (archive/delete), so it is not resurrected as "done".
    func deleteSourceIndexState(sourceID: String) throws {
        try execBind("DELETE FROM source_index_state WHERE source_id = ?") { stmt in
            bind(stmt, 1, sourceID)
        }
    }

    /// Coverage report: how many active sources are indexed, and how many chunk vectors
    /// exist. Used to verify the "every source is searchable" invariant actually holds.
    func indexCoverage(model: String = EmbeddingSettings.modelID) throws -> (activeSources: Int, indexedSources: Int, ftsRows: Int, chunkVectors: Int) {
        var active = 0, indexed = 0, fts = 0, chunks = 0
        // The sources the indexer covers: an audio overview's script is never indexed
        // (`sourcesMissingIndex`), so it is not counted as owed.
        try queryBind("""
            SELECT count(*) FROM source_projection
            WHERE status = 'active' AND \(Self.notAudioOverviewScriptURL("url"))
        """, bind: { _ in }) { stmt in
            active = Int(sqlite3_column_int(stmt, 0))
        }
        try queryBind("SELECT count(*) FROM source_index_state WHERE model = ?", bind: { stmt in
            self.bind(stmt, 1, model)
        }) { stmt in
            indexed = Int(sqlite3_column_int(stmt, 0))
        }
        fts = try sourceFTSDocumentCount()
        chunks = try embeddingCount(entityType: .sourceChunk, model: model)
        return (active, indexed, fts, chunks)
    }

    // MARK: - Full-Text Index

    /// Replace a source's full-text row. Called by the indexer with the same resolved
    /// text used for embedding, so both indexes always describe the same content.
    ///
    /// The text is analyzed on the way in — see `SourceSearchEngine.indexAnalyzedText` —
    /// so a term written with a separator is also stored closed up, and "GDF15" and
    /// "GDF-15" are one term to BM25 rather than two the query has to guess between.
    /// `source_content` keeps the original text; nothing reads excerpts from here.
    ///
    /// The old row goes by the rowid `source_fts_rows` holds for it, and the new row's rowid
    /// takes its place there, in one transaction with the row and its stamp.
    func replaceSourceFTS(sourceID: String, title: String, author: String, body: String) throws {
        try inWriteTransaction(savepoint: "replace_source_fts") {
            try deleteSourceFTSRow(sourceID: sourceID)
            try execBind("INSERT INTO source_fts (source_id, title, author, body) VALUES (?,?,?,?)") { stmt in
                bind(stmt, 1, sourceID)
                bind(stmt, 2, SourceSearchEngine.indexAnalyzedText(title))
                bind(stmt, 3, SourceSearchEngine.indexAnalyzedText(author))
                bind(stmt, 4, SourceSearchEngine.indexAnalyzedText(body))
            }
            try recordSourceFTSRow(sourceID: sourceID, rowid: sqlite3_last_insert_rowid(db))
            try execBind("""
                INSERT OR REPLACE INTO source_fts_state (source_id, analyzer_version, written_at)
                VALUES (?, ?, ?)
            """) { stmt in
                bind(stmt, 1, sourceID)
                sqlite3_bind_int(stmt, 2, Int32(SourceSearchEngine.indexAnalyzerVersion))
                sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
            }
        }
    }

    /// Sources whose full-text row was written by an older analyzer, or never written.
    ///
    /// Deliberately not folded into `sourcesMissingIndex`: this gap is repaired by
    /// rewriting text, and answering it separately is what keeps an analyzer change from
    /// re-embedding a library. Returns the same candidate shape so the indexer can reuse
    /// its text resolution, including a paper's on-the-fly PDF extraction — otherwise a
    /// reanalysis would quietly reduce those papers to a title-only row.
    func sourcesNeedingFTSRebuild(analyzerVersion: Int) throws -> [EmbeddingCandidate] {
        var candidates: [EmbeddingCandidate] = []
        try queryBind("""
            SELECT sp.id, sp.source_type, COALESCE(sp.title, ''), COALESCE(sp.domain, ''),
                   COALESCE(sp.author, ''), sp.local_file_path, sp.book_page_start, sp.book_page_count
            FROM source_projection sp
            LEFT JOIN source_fts_state fs ON fs.source_id = sp.id
            WHERE sp.status = 'active'
              AND \(Self.notAudioOverviewScriptURL("sp.url"))
              AND (fs.source_id IS NULL OR fs.analyzer_version < ?)
        """, bind: { stmt in
            sqlite3_bind_int(stmt, 1, Int32(analyzerVersion))
        }) { stmt in
            guard let id = self.string(stmt, 0) else { return }
            candidates.append(
                EmbeddingCandidate(
                    id: id,
                    sourceType: self.string(stmt, 1) ?? "",
                    title: self.string(stmt, 2) ?? "",
                    domain: self.string(stmt, 3) ?? "",
                    author: self.string(stmt, 4) ?? "",
                    localFilePath: self.string(stmt, 5),
                    bookPages: self.bookPages(stmt, startColumn: 6)
                )
            )
        }
        return candidates
    }

    /// Drop a source's full-text row (archive/delete), its stamp and the rowid kept for it.
    func deleteSourceFTS(sourceID: String) throws {
        try inWriteTransaction(savepoint: "delete_source_fts") {
            try deleteSourceFTSRow(sourceID: sourceID)
            try execBind("DELETE FROM source_fts_state WHERE source_id = ?") { stmt in
                bind(stmt, 1, sourceID)
            }
        }
    }

    // MARK: - A source out of search

    /// Take a source out of search in this store: its full-text row with the stamp and rowid kept
    /// for it, the record of the text it was indexed from, and its vectors of every model. An
    /// archive, a delete and a cleared text all call it, so none of them leaves a part behind:
    /// keyword search reads no status, so a full-text row left there is found, and the vector index
    /// loads every stored chunk at launch, so vectors left there come back (2026-10-06: 391
    /// archived or deleted sources on the production library held some of it, among them 263
    /// full-text rows and 36,705 vectors). The vectors already in memory are the caller's (`StorageService.removeFromSearchIndexes`).
    /// Joins a caller's transaction.
    func dropSourceSearchRows(sourceID: String) throws {
        try inWriteTransaction(savepoint: "drop_source_search_rows") {
            try deleteSourceFTS(sourceID: sourceID)
            try deleteSourceIndexState(sourceID: sourceID)
            try deleteEmbeddings(
                entityType: .sourceChunk,
                entityIdPrefix: StorageService.sourceChunkEmbeddingPrefix(for: sourceID)
            )
            try execBind("DELETE FROM embeddings WHERE entity_type = ? AND entity_id = ?") { stmt in
                bind(stmt, 1, KnowledgeEntityType.source.rawValue)
                bind(stmt, 2, sourceID)
            }
        }
    }

    /// Sources out of search that still hold a part of it, in id order: not active (archived, or
    /// with no row at all) yet holding a full-text row, a stamp, a record of being indexed, or,
    /// for an archived source, vectors. Archives and deletes that arrive by sync take nothing
    /// with them, an index written while its source was being archived lands after the archive,
    /// and builds before 2026-10-06 left them (`dropSourceSearchRows`). Reads the small side
    /// tables and one probe of the vectors' key per archived source, never a vector or a row's
    /// text. A full-text row is found by its recorded rowid, so one written before schema 168
    /// is found once the indexer has recorded it (`recordSourceFTSRows`).
    func sourcesOutOfSearchHoldingSearchRows(limit: Int) throws -> [String] {
        let delimiter = StorageService.sourceChunkEmbeddingPrefix(for: "")
        guard limit > 0, let delimiterBound = Self.textPrefixUpperBound(delimiter) else { return [] }
        var ids: [String] = []
        try queryBind("""
            WITH held(source_id) AS (
                SELECT source_id FROM source_fts_rows
                UNION SELECT source_id FROM source_fts_state
                UNION SELECT source_id FROM source_index_state
                UNION SELECT sp.id FROM source_projection sp
                    WHERE sp.status = 'archived'
                      AND EXISTS (
                        SELECT 1 FROM embeddings e
                        WHERE e.entity_type = ?
                          AND e.entity_id >= sp.id || ?
                          AND e.entity_id < sp.id || ?
                      )
            )
            SELECT source_id FROM held
            WHERE NOT EXISTS (
                SELECT 1 FROM source_projection active
                WHERE active.id = held.source_id AND active.status = 'active'
            )
            ORDER BY source_id
            LIMIT ?
        """, bind: { stmt in
            self.bind(stmt, 1, KnowledgeEntityType.sourceChunk.rawValue)
            self.bind(stmt, 2, delimiter)
            self.bind(stmt, 3, delimiterBound)
            sqlite3_bind_int64(stmt, 4, Int64(limit))
        }) { stmt in
            if let id = self.string(stmt, 0) { ids.append(id) }
        }
        return ids
    }

    /// The sources search covers: every active one. The vector index keeps only these sources'
    /// chunks when it loads (`StorageService.searchChunkVectors`).
    func sourceIDsInSearch() throws -> Set<String> {
        var ids: Set<String> = []
        try query("SELECT id FROM source_projection WHERE status = 'active'") { stmt in
            if let id = self.string(stmt, 0) { ids.insert(id) }
        }
        return ids
    }

    /// Delete a source's full-text row by the rowid `source_fts_rows` holds for it, and forget the
    /// rowid. `source_id` is UNINDEXED, so `WHERE source_id = ?` reads every row's text: 3.6 s
    /// cold on the production library's 252 MB, against 0.03 s by rowid. A source with no rowid
    /// recorded has no row once the rows written before schema 168 are recorded; while some are
    /// not, the rest are recorded first (`recordSourceFTSRows`), which is one such read.
    ///
    /// The source id is matched with the rowid, so a rowid the map should no longer hold never
    /// takes another source's row with it.
    private func deleteSourceFTSRow(sourceID: String) throws {
        var rowid = try recordedSourceFTSRowid(sourceID: sourceID)
        if rowid == nil, try sourceFTSRowBackfillCursor() != nil {
            try recordSourceFTSRows(limit: nil)
            rowid = try recordedSourceFTSRowid(sourceID: sourceID)
        }
        guard let rowid else { return }
        try execBind("DELETE FROM source_fts WHERE rowid = ? AND source_id = ?") { stmt in
            sqlite3_bind_int64(stmt, 1, rowid)
            bind(stmt, 2, sourceID)
        }
        try execBind("DELETE FROM source_fts_rows WHERE source_id = ?") { stmt in
            bind(stmt, 1, sourceID)
        }
    }

    /// A source's full-text row as the index holds it: its title and the opening
    /// `maxCharacters` of its body, analyzed (`SourceSearchEngine.indexAnalyzedText`). Read by
    /// the rowid `source_fts_rows` holds, for the reason `deleteSourceFTSRow` gives. Nil when no
    /// row is recorded for the source: not indexed yet, or written before schema 168 and not yet
    /// reached by `recordSourceFTSRows`.
    func sourceFTSText(sourceID: String, maxCharacters: Int) throws -> (title: String, body: String)? {
        guard let rowid = try recordedSourceFTSRowid(sourceID: sourceID) else { return nil }
        var text: (title: String, body: String)?
        try queryBind("SELECT title, substr(body, 1, ?) FROM source_fts WHERE rowid = ? AND source_id = ?", bind: { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(maxCharacters))
            sqlite3_bind_int64(stmt, 2, rowid)
            self.bind(stmt, 3, sourceID)
        }) { stmt in
            text = (self.string(stmt, 0) ?? "", self.string(stmt, 1) ?? "")
        }
        return text
    }

    private func recordedSourceFTSRowid(sourceID: String) throws -> Int64? {
        var rowid: Int64?
        try queryBind("SELECT fts_rowid FROM source_fts_rows WHERE source_id = ?", bind: { stmt in
            self.bind(stmt, 1, sourceID)
        }) { stmt in
            rowid = sqlite3_column_int64(stmt, 0)
        }
        return rowid
    }

    private func recordSourceFTSRow(sourceID: String, rowid: Int64) throws {
        try execBind("""
            INSERT INTO source_fts_rows (source_id, fts_rowid) VALUES (?, ?)
            ON CONFLICT(source_id) DO UPDATE SET fts_rowid = excluded.fts_rowid
        """) { stmt in
            bind(stmt, 1, sourceID)
            sqlite3_bind_int64(stmt, 2, rowid)
        }
    }

    /// The last rowid recorded of the rows written before schema 168, or nil once all of them are.
    private func sourceFTSRowBackfillCursor() throws -> Int64? {
        var cursor: Int64?
        try query("SELECT after_rowid FROM source_fts_row_backfill WHERE singleton = 1") { stmt in
            cursor = sqlite3_column_int64(stmt, 0)
        }
        return cursor
    }

    /// Record the rowids of the full-text rows written before schema 168, which kept none:
    /// `limit` rows a call, in rowid order from where the last call stopped, or all that remain
    /// when nil. Returns whether rows remain. The ids are read through FTS5, which reads each row
    /// whole: on the production library a batch of 64 took 0.05 s cold at the median and 0.6 s at
    /// most, all 4,664 rows 3.7–4.1 s. The indexer records them in batches (`SourceEmbeddingIndexer`); a delete that comes first
    /// records the rest itself.
    ///
    /// Two rows for one source (none on the production library) keep the later one.
    @discardableResult
    func recordSourceFTSRows(limit: Int?) throws -> Bool {
        // Read before taking the write lock: once the record is done, this is all a call costs.
        guard try sourceFTSRowBackfillCursor() != nil else { return false }
        return try inWriteTransaction(savepoint: "record_source_fts_rows") {
            guard let cursor = try sourceFTSRowBackfillCursor() else { return false }
            let batch = limit.map { max($0, 1) }
            var rows: [(rowid: Int64, sourceID: String?)] = []
            try queryBind("SELECT rowid, source_id FROM source_fts WHERE rowid > ? ORDER BY rowid LIMIT ?", bind: { stmt in
                sqlite3_bind_int64(stmt, 1, cursor)
                sqlite3_bind_int64(stmt, 2, Int64(batch ?? -1))
            }) { stmt in
                rows.append((sqlite3_column_int64(stmt, 0), self.string(stmt, 1)))
            }
            for row in rows {
                guard let sourceID = row.sourceID else { continue }
                let recorded = try recordedSourceFTSRowid(sourceID: sourceID)
                if recorded == row.rowid { continue }
                if let recorded {
                    try execBind("DELETE FROM source_fts WHERE rowid = ?") { stmt in
                        sqlite3_bind_int64(stmt, 1, min(recorded, row.rowid))
                    }
                    if recorded > row.rowid { continue }
                }
                try recordSourceFTSRow(sourceID: sourceID, rowid: row.rowid)
            }
            if let batch, rows.count == batch, let last = rows.last {
                try execBind("UPDATE source_fts_row_backfill SET after_rowid = ? WHERE singleton = 1") { stmt in
                    sqlite3_bind_int64(stmt, 1, last.rowid)
                }
                return true
            }
            try exec("DELETE FROM source_fts_row_backfill")
            return false
        }
    }

    /// Run `body` as one write: in a `BEGIN IMMEDIATE` transaction of its own when none is open,
    /// so it waits its turn for the write lock rather than starting as a read that another
    /// connection's write can strand, or in a savepoint of the caller's.
    private func inWriteTransaction<T>(savepoint name: String, _ body: () throws -> T) throws -> T {
        guard sqlite3_get_autocommit(db) != 0 else {
            try exec("SAVEPOINT \(name)")
            do {
                let result = try body()
                try exec("RELEASE SAVEPOINT \(name)")
                return result
            } catch {
                try? exec("ROLLBACK TO SAVEPOINT \(name)")
                try? exec("RELEASE SAVEPOINT \(name)")
                throw error
            }
        }
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Number of sources in the full-text index. Zero means the indexer has not run yet,
    /// and callers should fall back to a substring scan rather than return nothing.
    ///
    /// Counted from FTS5's own one-row-per-document table, `source_fts_docsize`, which
    /// holds as many rows as `source_fts`: `count(*)` over `source_fts` walks every row of
    /// its content, 52 ms on a library of 4,800 sources against under 1 ms here, and every
    /// search asks.
    func sourceFTSDocumentCount() throws -> Int {
        var count = 0
        try queryBind("SELECT count(*) FROM source_fts_docsize", bind: { _ in }) { stmt in
            count = Int(sqlite3_column_int(stmt, 0))
        }
        return count
    }

    /// How many sources contain `term`. Used to decide how much to trust the lexical
    /// signal: a term appearing in a handful of sources (a gene symbol, an acronym) is
    /// strong evidence, while one appearing everywhere ("the", "study") is not.
    func sourceFTSDocumentFrequency(term: String) throws -> Int {
        var count = 0
        try queryBind("SELECT count(*) FROM source_fts WHERE source_fts MATCH ?", bind: { stmt in
            self.bind(stmt, 1, "\"\(term)\"")
        }) { stmt in
            count = Int(sqlite3_column_int(stmt, 0))
        }
        return count
    }

    /// BM25-ranked full-text search. Returns `(sourceID, score)` with score ascending in
    /// relevance rank order — bm25() returns *negative* values where more-negative is a
    /// better match, so it is negated here to make larger mean better, matching the
    /// convention used by the semantic side.
    ///
    /// Title and author are weighted above body: a paper *about* GDF15 names it in the
    /// title, while a passing mention in a 10k-word body is weaker evidence.
    ///
    /// bm25() takes one weight per column *positionally, including UNINDEXED columns*, so
    /// the leading 0.0 belongs to `source_id`. Omitting it silently shifts the title
    /// weight onto the id column.
    ///
    /// `restrictedTo` narrows the search to an explicit set of sources, for
    /// callers ranking within an already-chosen pool. It is applied in SQL
    /// rather than by filtering the results, so a small subset still gets its
    /// own top-`limit` instead of whatever survives a corpus-wide ranking.
    /// The set is bound as parameters, so callers pass a bounded pool (a
    /// Notebook's sources), not the whole library.
    func searchSourceFTS(
        matchExpression: String,
        limit: Int,
        restrictedTo: Set<String>? = nil,
        excludedSources: Set<String> = []
    ) throws -> [(id: String, score: Float)] {
        var results: [(id: String, score: Float)] = []
        let restriction = restrictedTo.map(Array.init) ?? []
        let restrictionClause = restriction.isEmpty
            ? ""
            : " AND source_id IN (\(restriction.map { _ in "?" }.joined(separator: ", ")))"

        if let restrictedTo, restrictedTo.isEmpty { return [] }

        // Over-fetch enough to replace filtered rows without letting a large
        // opted-out plugin turn one query into an unbounded result walk.
        let retrievalLimit = min(limit + excludedSources.count, max(limit * 8, 800))
        try queryBind("""
            SELECT source_id, bm25(source_fts, 0.0, 10.0, 5.0, 1.0) AS rank
            FROM source_fts
            WHERE source_fts MATCH ?\(restrictionClause)
            ORDER BY rank
            LIMIT ?
        """, bind: { stmt in
            self.bind(stmt, 1, matchExpression)
            for (offset, sourceID) in restriction.enumerated() {
                self.bind(stmt, offset + 2, sourceID)
            }
            self.bind(stmt, restriction.count + 2, retrievalLimit)
        }) { stmt in
            guard let id = self.string(stmt, 0) else { return }
            guard !excludedSources.contains(id), results.count < limit else { return }
            let rank = sqlite3_column_double(stmt, 1)
            results.append((id: id, score: Float(-rank)))
        }
        return results
    }

    /// Resolve a complete DOI through indexed paper identity columns.
    ///
    /// Token search cannot preserve punctuation-rich identity: a DOI such as
    /// `10.1038/s41586-023-06004-9` becomes several unrelated tokens. A direct lookup
    /// is both more accurate and cheaper. The NOCASE predicates match the dedicated
    /// case-insensitive DOI indexes installed with the paper schema.
    func searchPaperDOI(
        _ doi: String,
        limit: Int,
        restrictedTo: Set<String>? = nil,
        excludedSources: Set<String> = []
    ) throws -> [String] {
        guard limit > 0 else { return [] }
        if let restrictedTo, restrictedTo.isEmpty { return [] }

        let restriction = restrictedTo.map(Array.init) ?? []
        let restrictionClause = restriction.isEmpty
            ? ""
            : " AND p.source_id IN (\(restriction.map { _ in "?" }.joined(separator: ", ")))"
        var results: [String] = []
        var seen = Set<String>()
        let retrievalLimit = min(limit + excludedSources.count, max(limit * 8, 800))

        // Keep each identity lookup on one explicit index. An OR across identity
        // columns is currently optimized as a multi-index query by SQLite, but that is
        // plan-dependent and previously turned other identity reconciliation paths into
        // scans as their tables grew. Two tiny probes make the performance invariant.
        func collect(column: String, index: String) throws {
            try queryBind("""
                SELECT p.source_id
                FROM papers p INDEXED BY \(index)
                JOIN sources s ON s.id = p.source_id
                LEFT JOIN hidden_sources hs ON hs.source_id IN (s.id, s.wire_key)
                WHERE p.\(column) = ? COLLATE NOCASE
                  AND s.status = 'active'
                  AND hs.source_id IS NULL\(restrictionClause)
                LIMIT ?
            """, bind: { stmt in
                self.bind(stmt, 1, doi)
                for (offset, sourceID) in restriction.enumerated() {
                    self.bind(stmt, offset + 2, sourceID)
                }
                self.bind(stmt, restriction.count + 2, retrievalLimit)
            }) { stmt in
                guard let id = self.string(stmt, 0),
                      !excludedSources.contains(id),
                      seen.insert(id).inserted else { return }
                results.append(id)
            }
        }
        try collect(column: "doi", index: "idx_papers_doi_nocase")
        try collect(column: "published_doi", index: "idx_papers_published_doi_nocase")
        return results.sorted().prefix(limit).map { $0 }
    }

    /// Lexical match over source *metadata* — title, author, domain, journal, year,
    /// URL/DOI identity, and the parent group (book, course, or podcast show) title.
    ///
    /// The full-text index covers title, author, and body, but not domain or parent
    /// group, and adding columns to `source_fts` would mean reindexing every source. So
    /// those two fields are matched here instead, keeping "find everything from
    /// nature.com" and "find the chapters of this book" working.
    ///
    /// Scans metadata columns of active, non-hidden sources rather than building a
    /// dynamic LIKE predicate: these are short strings over a few thousand rows, so the
    /// scan is cheap, and scoring in Swift keeps the match rules in one readable place.
    ///
    /// `terms` should be the caller's *informative* terms. Matching is per whole word,
    /// not substring: "on" must not match "London", and an ordinary word carried along
    /// by a question ("what sources do I have on GDF15?") must not pull in every source
    /// whose title happens to contain it. Both would fill the candidate pool with noise
    /// that the fusion step then has to rank around.
    func searchSourceMetadata(
        terms: [String],
        query: String,
        limit: Int,
        restrictedTo: Set<String>? = nil,
        excludedSources: Set<String> = []
    ) throws -> [(id: String, score: Float, matchedTerms: Set<String>)] {
        guard limit > 0, !terms.isEmpty else { return [] }
        if let restrictedTo, restrictedTo.isEmpty { return [] }
        let loweredQuery = query.lowercased()
        let termSet = Set(terms)
        var scored: [(id: String, score: Float, matchedTerms: Set<String>)] = []

        try queryBind("""
            SELECT sp.id,
                   lower(COALESCE(sp.title, '')),
                   lower(COALESCE(sp.author, '')),
                   lower(COALESCE(sp.domain, '')),
                   lower(COALESCE(sp.parent_group_title, sp.parent_group, '')),
                   lower(COALESCE(sp.journal, '')),
                   lower(CAST(COALESCE(sp.published_year, '') AS TEXT)),
                   lower(COALESCE(sp.url, '')),
                   lower(COALESCE(sp.normalized_url, '')),
                   lower(COALESCE(sp.doi, '')),
                   lower(COALESCE(sp.published_doi, ''))
            FROM source_projection sp
            WHERE sp.status = 'active'
        """, bind: { _ in }) { stmt in
            guard let id = self.string(stmt, 0) else { return }
            guard !excludedSources.contains(id) else { return }
            // Filtered in Swift rather than SQL: this branch already scans and
            // scores every active row, so an IN clause would add bound
            // parameters without removing the scan.
            if let restrictedTo, !restrictedTo.contains(id) { return }
            let title = self.string(stmt, 1) ?? ""
            let author = self.string(stmt, 2) ?? ""
            let domain = self.string(stmt, 3) ?? ""
            let group = self.string(stmt, 4) ?? ""
            let journal = self.string(stmt, 5) ?? ""
            let year = self.string(stmt, 6) ?? ""
            let url = self.string(stmt, 7) ?? ""
            let normalizedURL = self.string(stmt, 8) ?? ""
            let doi = self.string(stmt, 9) ?? ""
            let publishedDOI = self.string(stmt, 10) ?? ""

            var score: Float = 0
            // A whole-query match on a metadata field is a strong signal: the learner
            // typed the domain or the book name.
            if domain.contains(loweredQuery) || group.contains(loweredQuery) { score += 2.0 }
            if title.contains(loweredQuery) { score += 1.5 }
            if author.contains(loweredQuery) { score += 1.5 }
            if journal.contains(loweredQuery) { score += 1.25 }
            if year == loweredQuery { score += 1.25 }
            if [url, normalizedURL, doi, publishedDOI].contains(where: { $0 == loweredQuery }) {
                score += 3.0
            }

            let words = Set(
                [title, author, domain, group, journal, year]
                    .joined(separator: " ")
                    .split { !$0.isLetter && !$0.isNumber }
                    .map(String.init)
            )
            let matchedTerms = termSet.intersection(words)
            score += Float(matchedTerms.count) / Float(termSet.count)

            guard score > 0 else { return }
            scored.append((id: id, score: score, matchedTerms: matchedTerms))
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score == rhs.score { return lhs.id < rhs.id }
                return lhs.score > rhs.score
            }
            .prefix(limit)
            .map { $0 }
    }

    /// The raw podcast transcript (TTML) for a source, when the source is a podcast
    /// whose text lives only in the `podcasts` table rather than `source_content`.
    func podcastRawTTML(forSourceID sourceID: String) throws -> String? {
        var ttml: String?
        try queryBind("SELECT raw_ttml FROM podcasts WHERE source_id = ? LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, sourceID)
        }) { stmt in
            ttml = self.string(stmt, 0)
        }
        return ttml
    }

    // MARK: - Schema 168: where each full-text row is

    /// `source_fts_rows` holds the rowid of each source's full-text row, so `replaceSourceFTS` and
    /// `deleteSourceFTS`, the only writers of `source_fts`, find the row by rowid. It is a table
    /// of its own rather than a column of `source_fts_state` because a source's stamp is dropped
    /// to have its row written again (a title or an author repaired) while the row stays.
    ///
    /// `source_fts_row_backfill` holds one row while rows written before schema 168 may have no
    /// rowid recorded: the migration stages it, `recordSourceFTSRows` records those rows in rowid
    /// order from `after_rowid` (FTS5 numbers rows from 1) and deletes it at the end. Both tables
    /// are this Mac's derived data and never sync.
    func createSourceFTSRowTables() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS source_fts_rows (
                source_id TEXT PRIMARY KEY,
                fts_rowid INTEGER NOT NULL
            )
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS source_fts_row_backfill (
                singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                after_rowid INTEGER NOT NULL,
                enqueued_at REAL NOT NULL
            )
        """)
    }

}


/// Sources the learner named in a chat (dropped, uploaded, picked), for as long
/// as the app runs. The per-family "kept from AI" switch does not refuse these
/// when a tool opens or edits them by id; it still keeps the family out of
/// search, lists and discovery. In memory only: a relaunch asks the chat again.
final class ChatNamedSources: @unchecked Sendable {
    static let shared = ChatNamedSources()
    private let lock = NSLock()
    private var ids = Set<String>()

    func grant(_ newIDs: some Sequence<String>) {
        lock.lock(); defer { lock.unlock() }
        ids.formUnion(newIDs)
    }

    func revoke(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        ids.remove(id)
    }

    func contains(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ids.contains(id)
    }
}
