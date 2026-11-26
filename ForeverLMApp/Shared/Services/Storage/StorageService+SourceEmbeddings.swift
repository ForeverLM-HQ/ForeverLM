// StorageService: the chunk vector index and source embeddings.
import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

extension StorageService {

    // MARK: - Chunk Vector Index

    /// Nearest source chunks from the process-shared vector index, loading it from SQLite
    /// the first time it is used this session. Kept current afterwards by
    /// `saveSourceChunkEmbeddings`, so an ingest never forces a full reload.
    ///
    /// Static and nonisolated so the MCP tools — which reach the database through their
    /// own `KnowledgeStore` rather than this actor — search the same in-memory copy
    /// instead of re-reading every vector per query. Must not be called from the main
    /// actor: the first call reads every vector out of SQLite.
    nonisolated static func searchChunkVectors(
        queryVector: [Float],
        topK: Int,
        threshold: Float,
        restrictedTo: Set<String>? = nil,
        excludedSources: Set<String> = [],
        using ks: KnowledgeStore
    ) -> [(sourceId: String, chunkId: String, score: Float)] {
        guard let policyExcludedSources = try? ks.knowledgeSearchExcludedSourceIDs() else {
            return []
        }
        let effectiveExcludedSources = excludedSources.union(policyExcludedSources)
        let results = SharedSourceVectorIndex.shared.withIndex(storePath: ks.dbPath, dimensions: sourceEmbeddingDimensions) { index in
            if index.rowCount == 0,
               let embeddings = try? ks.loadAllEmbeddings(
                   entityType: .sourceChunk,
                   model: sourceEmbeddingModel
               ), !embeddings.isEmpty {
                // Only the chunks of sources search covers. An archive or a delete takes its
                // vectors from the store, but one that arrived by sync can
                // leave them there, and a vector once loaded is searched until the index is
                // rebuilt.
                let inSearch = try? ks.sourceIDsInSearch()
                index.load(
                    inSearch.map { chunkVectors(embeddings, ofSourcesIn: $0) } ?? embeddings,
                    sourceIDForChunk: sourceId(fromSourceChunkEmbeddingId:)
                )
            }
            return index.search(
                queryVector: queryVector,
                topK: topK,
                threshold: threshold,
                allowedSources: restrictedTo,
                excludedSources: effectiveExcludedSources
            )
        }
        return results.compactMap { result in
            guard let source = sourceId(fromSourceChunkEmbeddingId: result.id) else { return nil }
            return (sourceId: source, chunkId: result.id, score: result.score)
        }
    }

    /// The chunk vectors, by chunk id, whose source is one of `sourceIDs`.
    nonisolated static func chunkVectors(_ embeddings: [String: [Float]], ofSourcesIn sourceIDs: Set<String>) -> [String: [Float]] {
        embeddings.filter { chunk in
            sourceId(fromSourceChunkEmbeddingId: chunk.key).map(sourceIDs.contains) == true
        }
    }

    /// How far back "Read next" looks for what the learner has been reading,
    /// and how many of those sources it measures the library against.
    static let readNextLookback: TimeInterval = 30 * MemoryTutorScheduler.secondsPerDay
    static let readNextSeedLimit = 10

    /// Unread sources nearest to what the learner has been reading lately.
    ///
    /// Deterministic and free: no model call. Each recently read source
    /// (`recentReadingSourceIDs`) is reduced to the mean of its chunk vectors,
    /// and every candidate is scored by its best chunk against the nearest of
    /// those. `candidateIDs` is the caller's pool (the active library's ready
    /// sources, less what is already planned); anything the learner has
    /// already opened, read or marked consumed is removed here, as is anything
    /// the knowledge policy keeps out of AI discovery. Empty when there is no
    /// recent reading or none of it is embedded yet: there is nothing to
    /// measure against, and nothing is guessed in its place.
    nonisolated static func readNextSuggestions(
        candidateIDs: Set<String>,
        limit: Int,
        now: Date = Date(),
        using ks: KnowledgeStore
    ) throws -> [ReadNextSuggestion] {
        let seeds = try ks.recentReadingSourceIDs(
            since: now.addingTimeInterval(-readNextLookback),
            limit: readNextSeedLimit
        )
        guard !seeds.isEmpty, limit > 0 else { return [] }
        let excluded = try ks.touchedSourceIDs().union(ks.knowledgeSearchExcludedSourceIDs())
        let pool = candidateIDs.subtracting(excluded)
        guard !pool.isEmpty else { return [] }

        let scored = SharedSourceVectorIndex.shared.withIndex(storePath: ks.dbPath, dimensions: sourceEmbeddingDimensions) { index -> (seeds: [String], best: [String: (score: Float, query: Int)]) in
            if index.rowCount == 0,
               let embeddings = try? ks.loadAllEmbeddings(entityType: .sourceChunk, model: sourceEmbeddingModel),
               !embeddings.isEmpty {
                index.load(embeddings, sourceIDForChunk: sourceId(fromSourceChunkEmbeddingId:))
            }
            let centroids = index.centroids(forSources: Set(seeds))
            let embeddedSeeds = seeds.filter { centroids[$0] != nil }
            let best = index.bestSourceScores(
                queries: embeddedSeeds.compactMap { centroids[$0] },
                allowedSources: pool
            )
            return (embeddedSeeds, best)
        }

        return scored.best
            .map { ReadNextSuggestion(sourceID: $0.key, nearestReadSourceID: scored.seeds[$0.value.query], score: $0.value.score) }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score { return lhs.sourceID < rhs.sourceID }
                return lhs.score > rhs.score
            }
            .prefix(limit)
            .map { $0 }
    }

    func readNextSuggestions(candidateIDs: Set<String>, limit: Int) throws -> [ReadNextSuggestion] {
        try Self.readNextSuggestions(candidateIDs: candidateIDs, limit: limit, using: knowledgeStore())
    }

    /// Hybrid source search against an arbitrary store — the one ranking shared by the
    /// in-app Studio search and the MCP `search_sources_semantic` tool.
    /// See `SourceSearchEngine`.
    ///
    /// `restrictedTo` narrows every branch to an explicit source set, for
    /// callers ranking within a pool they already hold — a chat's attached
    /// sources, say. Passing nil searches the whole library.
    nonisolated static func searchSources(
        queryText: String,
        queryVector: [Float]?,
        limit: Int,
        threshold: Float,
        restrictedTo: Set<String>? = nil,
        using ks: KnowledgeStore
    ) -> [SourceSearchHit] {
        guard let excludedSources = try? ks.knowledgeSearchExcludedSourceIDs() else {
            return []
        }
        return (try? SourceSearchEngine.search(
            queryText: queryText,
            queryVector: queryVector,
            limit: limit,
            threshold: threshold,
            store: ks,
            restrictedTo: restrictedTo,
            excludedSources: excludedSources,
            semanticChunkSearch: { vector, topK, threshold, allowed, excluded in
                searchChunkVectors(
                    queryVector: vector,
                    topK: topK,
                    threshold: threshold,
                    restrictedTo: allowed,
                    excludedSources: excluded,
                    using: ks
                )
            }
        )) ?? []
    }

    // MARK: - Source Embeddings

    /// Active source counts per user-built plugin label, for the Settings
    /// plugins list.
    func activePluginSourceCounts() throws -> [String: Int] {
        try knowledgeStore().activePluginSourceCounts()
    }

    func saveAIUsageEvent(_ event: AIUsageEvent) throws {
        if let aiUsagePrimaryFailure {
            try KnowledgeStore.appendAIUsageEventForwardCompatibly(
                event,
                storeDirectory: storeRoot,
                after: aiUsagePrimaryFailure
            )
            return
        }
        do {
            try knowledgeStore().saveAIUsageEvent(event)
        } catch {
            // A lock another writer held past the busy timeout is not a schema
            // problem: the store opened fine. Latching the narrow path here sent
            // every later billed call around it, and that path takes the same
            // lock. The caller retries a lock instead.
            if KnowledgeStoreError.isTransientLock(error) { throw error }
            // A Mac that is one release behind must reject the newer knowledge
            // schema for normal reads and writes, but it must not lose spend
            // while doing so. The usage table is append-only and additive, so a
            // narrowly scoped writer can safely insert the columns this build
            // recognizes without migrating, downgrading, or otherwise opening
            // the newer store for application work.
            // Do not call ensureStoreExists() here: it also initializes the
            // CloudKit engine, which opens KnowledgeStore and would repeat the
            // same schema-version failure before accounting got its chance.
            try fileManager.createDirectory(at: storeRoot, withIntermediateDirectories: true)
            let primaryFailure = error.localizedDescription
            aiUsagePrimaryFailure = primaryFailure
            try KnowledgeStore.appendAIUsageEventForwardCompatibly(
                event,
                storeDirectory: storeRoot,
                after: primaryFailure
            )
        }
    }

    func cachedAIResponse(for requestKey: String, notOlderThan cutoff: Date) throws -> String? {
        try knowledgeStore().cachedAIResponse(for: requestKey, notOlderThan: cutoff)
    }

    func saveCachedAIResponse(_ response: String, for requestKey: String) throws {
        try knowledgeStore().saveCachedAIResponse(response, for: requestKey)
    }

    /// Recorded spend for one chat/review session, over rows created before
    /// `cutoff` (see KnowledgeStore.aiUsageCost for the live/persisted split).
    func aiUsageCost(sessionID: String, before cutoff: Date) throws -> KnowledgeStore.AIUsageSessionCost {
        try knowledgeStore().aiUsageCost(sessionID: sessionID, before: cutoff)
    }

    func aiUsageTaskActivities(
        filter: KnowledgeStore.AIUsageEventFilter = .init()
    ) throws -> [AIUsageTaskActivitySummary] {
        try knowledgeStore().loadAIUsageTaskActivities(filter: filter)
    }

    func aiUsageSubjectActivities(
        task: String?,
        filter: KnowledgeStore.AIUsageEventFilter = .init(),
        limit: Int = Int.max,
        offset: Int = 0
    ) throws -> [AIUsageSubjectActivitySummary] {
        try knowledgeStore().loadAIUsageSubjectActivities(
            task: task,
            filter: filter,
            limit: limit,
            offset: offset
        )
    }

    /// Count, total spend, unpriced-call count, and prompt-cache read/write
    /// tokens for the AI Usage pane.
    func aiUsageEventTotals(
        filter: KnowledgeStore.AIUsageEventFilter = .init()
    ) throws -> AIUsageEventTotals {
        try knowledgeStore().aiUsageEventTotals(filter: filter)
    }

    /// Prices stored usage rows that have no cost yet but can now get one.
    /// See `KnowledgeStore.repriceUnpricedAIUsageEvents`.
    @discardableResult
    func repriceUnpricedAIUsageEvents() throws -> Int {
        try knowledgeStore().repriceUnpricedAIUsageEvents()
    }

    /// See `KnowledgeStore.unpricedImageUsageEventCount`.
    func unpricedImageUsageEventCount() throws -> Int {
        try knowledgeStore().unpricedImageUsageEventCount()
    }

    /// See `KnowledgeStore.aiUsageEventsAwaitingGenerationCost`.
    func aiUsageEventsAwaitingGenerationCost(limit: Int) throws -> [(id: String, rawUsageJSON: String)] {
        try knowledgeStore().aiUsageEventsAwaitingGenerationCost(limit: limit)
    }

    /// See `KnowledgeStore.setAIUsageEventGenerationCost`.
    func setAIUsageEventGenerationCost(id: String, costUSD: Double) throws {
        try knowledgeStore().setAIUsageEventGenerationCost(id: id, costUSD: costUSD)
    }

    /// Zeroes stored estimates OpenRouter says it never billed.
    /// See `KnowledgeStore.zeroEstimatesOpenRouterDidNotBill`.
    @discardableResult
    func zeroEstimatesOpenRouterDidNotBill() throws -> Int {
        try knowledgeStore().zeroEstimatesOpenRouterDidNotBill()
    }

    /// Save chunk-level embeddings for a source, replacing any older chunks for that source.
    func saveSourceChunkEmbeddings(sourceId: String, embeddings: [(chunkId: String, vector: [Float])]) throws {
        let ks = try knowledgeStore()
        try ks.deleteEmbeddings(
            entityType: .sourceChunk,
            entityIdPrefix: Self.sourceChunkEmbeddingPrefix(for: sourceId),
            model: Self.sourceEmbeddingModel
        )
        guard !embeddings.isEmpty else { return }
        let keyed = Dictionary(uniqueKeysWithValues: embeddings.map { ($0.chunkId, $0.vector) })
        try ks.saveEmbeddingsBatch(entityType: .sourceChunk, embeddings: keyed, model: Self.sourceEmbeddingModel)

        // Keep the in-memory index in step with the write, so the backfill never forces
        // a full reload and a search right after an ingest sees the new vectors.
        // `replace` no-ops while the index is still unloaded, so this does not fault in
        // 184 MB of vectors during a backfill that nobody has searched yet.
        SharedSourceVectorIndex.shared.withIndex(storePath: ks.dbPath, dimensions: Self.sourceEmbeddingDimensions) { index in
            index.replace(
                sourceID: sourceId,
                chunks: embeddings,
                sourceIDForChunk: Self.sourceId(fromSourceChunkEmbeddingId:)
            )
        }
    }

    /// Active, ready sources missing either index (chunk vectors or full text) — the
    /// work list for the background indexer. Empty on any store error (the indexer
    /// treats that as "nothing to do" and retries on its next trigger).
    func sourcesMissingIndex() -> [KnowledgeStore.EmbeddingCandidate] {
        guard let ks = try? knowledgeStore() else { return [] }
        return (try? ks.sourcesMissingIndex(model: Self.sourceEmbeddingModel)) ?? []
    }

    /// Sources whose record says another device finished their ingestion (`Source.ingest` arrived `ready`). The
    /// automatic sweeps for unprocessed sources skip these: the work is done and its satellites are on their
    /// way (`InboundSourceFiles`). Empty on any store error.
    func sourceIDsIngestedOnAnotherDevice() -> Set<String> {
        guard let ks = try? knowledgeStore() else { return [] }
        return (try? ks.sourceIDsIngestedOnAnotherDevice()) ?? []
    }

    /// Sources whose full-text row predates the current index-time analysis. Text-only
    /// maintenance: repairing this gap rewrites rows and never embeds.
    func sourcesNeedingFTSRebuild() -> [KnowledgeStore.EmbeddingCandidate] {
        guard let ks = try? knowledgeStore() else { return [] }
        return (try? ks.sourcesNeedingFTSRebuild(
            analyzerVersion: SourceSearchEngine.indexAnalyzerVersion
        )) ?? []
    }

    /// Write a source's full-text row. Fed the same resolved text used for embedding, so
    /// both halves of search always describe the same content.
    func replaceSourceFTS(sourceID: String, title: String, author: String, body: String) throws {
        try knowledgeStore().replaceSourceFTS(sourceID: sourceID, title: title, author: author, body: body)
    }

    /// Record the rowids of up to `limit` full-text rows written before schema 168; whether
    /// rows remain (`KnowledgeStore.recordSourceFTSRows`).
    func recordSourceFTSRows(limit: Int) throws -> Bool {
        try knowledgeStore().recordSourceFTSRows(limit: limit)
    }

    /// Record that a source is fully indexed against the current version of its text.
    func recordSourceIndexed(sourceID: String) throws {
        try knowledgeStore().recordSourceIndexed(sourceID: sourceID, model: Self.sourceEmbeddingModel)
    }

    /// Coverage of the search index: active sources vs sources actually indexed.
    func searchIndexCoverage() -> (activeSources: Int, indexedSources: Int, ftsRows: Int, chunkVectors: Int)? {
        guard let ks = try? knowledgeStore() else { return nil }
        return try? ks.indexCoverage(model: Self.sourceEmbeddingModel)
    }

    /// Raw podcast transcript for a source, when its text lives only in `podcasts`.
    func podcastRawTTML(forSourceID sourceID: String) -> String? {
        guard let ks = try? knowledgeStore() else { return nil }
        return (try? ks.podcastRawTTML(forSourceID: sourceID)) ?? nil
    }

    /// Return the source IDs that already have at least one chunk embedding.
    func embeddedChunkSourceIds() -> Set<String> {
        guard let ks = try? knowledgeStore(),
              let chunkIds = try? ks.embeddedEntityIds(entityType: .sourceChunk, model: Self.sourceEmbeddingModel) else {
            return []
        }
        return Set(chunkIds.compactMap(Self.sourceId(fromSourceChunkEmbeddingId:)))
    }

    /// Find the nearest source chunks. Callers can use this when they need chunk-level evidence.
    /// Served from the in-memory `SourceVectorIndex` — one BLAS pass, no per-query SQLite read.
    func findSimilarSourceChunks(queryVector: [Float], topK: Int = 120, threshold: Float = EmbeddingSettings.similarityThreshold) -> [(sourceId: String, chunkId: String, score: Float)] {
        guard let ks = try? knowledgeStore() else { return [] }
        return Self.searchChunkVectors(queryVector: queryVector, topK: topK, threshold: threshold, using: ks)
    }

    /// Hybrid source search — the one ranking used by both the in-app Studio search and
    /// the MCP `search_sources_semantic` tool. See `SourceSearchEngine`.
    func searchSources(
        queryText: String,
        queryVector: [Float]?,
        limit: Int,
        threshold: Float = EmbeddingSettings.similarityThreshold,
        restrictedTo: Set<String>? = nil
    ) -> [SourceSearchHit] {
        guard let ks = try? knowledgeStore() else { return [] }
        return Self.searchSources(
            queryText: queryText,
            queryVector: queryVector,
            limit: limit,
            threshold: threshold,
            restrictedTo: restrictedTo,
            using: ks
        )
    }

    /// Strict indexed-content matches for list-filter UIs. Unlike hybrid source
    /// discovery, every returned source contains every typed term.
    func strictSourceContentMatchIDs(
        queryText: String,
        limit: Int,
        restrictedTo: Set<String>? = nil
    ) -> Set<String> {
        guard let ks = try? knowledgeStore(),
              let excludedSources = try? ks.knowledgeSearchExcludedSourceIDs() else {
            return []
        }
        return (try? SourceSearchEngine.strictContentMatchIDs(
            queryText: queryText,
            limit: limit,
            store: ks,
            restrictedTo: restrictedTo,
            excludedSources: excludedSources
        )) ?? []
    }

    /// Find sources most similar to a query vector, scoring each source by its best chunk.
    func findSimilarSources(queryVector: [Float], topK: Int = 30, threshold: Float = EmbeddingSettings.similarityThreshold) -> [(id: String, score: Float)] {
        let chunkResults = findSimilarSourceChunks(
            queryVector: queryVector,
            topK: max(topK * 4, 80),
            threshold: threshold
        )
        guard !chunkResults.isEmpty else { return [] }

        var bestBySource: [String: Float] = [:]
        for result in chunkResults {
            bestBySource[result.sourceId] = max(bestBySource[result.sourceId] ?? -.greatestFiniteMagnitude, result.score)
        }
        return bestBySource
            .map { (id: $0.key, score: $0.value) }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score { return lhs.id < rhs.id }
                return lhs.score > rhs.score
            }
            .prefix(topK)
            .map { $0 }
    }

    /// Whether the source has durable readable text. Cheaper than
    /// `loadSourceContent` — it never pulls the body into memory — and it is the
    /// same predicate `saveSource` enforces before admitting a source as ready.
    func hasReadableSourceContent(_ sourceId: String) -> Bool {
        guard let ks = try? knowledgeStore() else { return false }
        return (try? ks.hasReadableSourceContent(sourceId)) ?? false
    }

    /// The X posts whose saved capture holds only the opening of a post.
    func xPostSourceIDsSavedCutShort() async -> [String] {
        guard let ks = try? knowledgeStore() else { return [] }
        return (try? ks.xPostSourceIDsSavedCutShort()) ?? []
    }

    /// Load persisted source content from SQLite.
    ///
    /// Stored text wins. Deriving text from a local file — a book chapter's
    /// PDF, a course handout — happens only for a source that has nothing
    /// stored yet, and it runs off this actor. Running it here on every
    /// read of a PDF-backed source would re-extract the whole file to compare it
    /// against the stored copy, holding the single storage lane for as long
    /// as the extraction took while every chat send, sync hop and reader open
    /// queued behind it (see `ChatSendPreparationTrace`). A stale derived copy
    /// is refreshed by the ingestion paths that replace the file, not by reads.
    /// The stored text of several sources at once, by id; a source with none
    /// is absent. A plain read of `source_content`, for comparing texts.
    func loadSourceContents(for sourceIDs: [String]) async -> [String: String] {
        guard !sourceIDs.isEmpty, let ks = try? knowledgeStore() else { return [:] }
        return (try? ks.loadSourceContents(for: sourceIDs)) ?? [:]
    }

    func loadSourceContent(_ sourceId: String) async -> String? {
        guard let ks = try? knowledgeStore() else { return nil }

        let article = try? ks.loadSourceForSync(sourceId)
        // Deferred upgrades may temporarily leave the pre-v18 extraction in
        // source_content. It is ingestion input, not canonical paper content,
        // until the paper is ready and cleanup has committed.
        if article?.sourceType == .paper, article?.state != .ready {
            return nil
        }
        if let cached = try? ks.loadSourceContent(sourceId),
           !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cached
        }
        // A paper without canonical content is still in ingestion. Never bypass
        // the cleanup boundary by extracting its local PDF in a read path.
        if article?.sourceType == .paper { return nil }
        guard let article else { return nil }
        let derived = await Task.detached(priority: .userInitiated) {
            Self.deriveLocalSourceContent(for: article)
        }.value
        guard let derived else { return nil }
        // Another caller may have stored this source's text during the
        // extraction; the stored copy stays authoritative.
        if let cached = try? ks.loadSourceContent(sourceId),
           !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cached
        }
        try? ks.saveDerivedSourceContent(sourceId, content: derived)
        return derived
    }

    /// Stored text for many sources in one read. No derivation and no network:
    /// this is what a chat send hydrates attached sources from, so it must be
    /// as cheap as the query.
    func loadStoredSourceContents(for sourceIDs: [String]) -> [String: String] {
        guard !sourceIDs.isEmpty, let ks = try? knowledgeStore() else { return [:] }
        return (try? ks.loadSourceContents(for: sourceIDs)) ?? [:]
    }

    /// What a website refresh measures its capture against. Unlike
    /// `loadSourceContent`, nothing is derived from the archived page, and a
    /// failed read throws, so a refresh never takes an unreadable copy for a
    /// missing one.
    func savedArticleCopy(_ sourceID: String) throws -> ArticleRefreshSavedCopy {
        let store = try knowledgeStore()
        return ArticleRefreshSavedCopy(
            text: try store.loadSourceContent(sourceID),
            stagedRaw: try store.loadArticleContentPreparation(sourceID)?.raw
        )
    }

    /// Raw paper extraction for the ingestion pipeline only. Downstream source
    /// readers intentionally have no equivalent API.
    func loadRawPaperContent(_ sourceID: String) -> String? {
        guard let store = try? knowledgeStore() else { return nil }
        return try? store.loadPaperContentPreparation(sourceID)?.raw
    }

    /// The staged extraction of a source whose canonical cleanup has not run,
    /// whichever preparation table holds it. Ingestion-only, for the same
    /// reason as `loadRawPaperContent`: it is pre-cleanup text, so no reading
    /// surface may take this path to the content.
    func loadStagedRawContent(_ sourceID: String) -> String? {
        guard let store = try? knowledgeStore() else { return nil }
        return (try? store.loadPaperContentPreparation(sourceID)?.raw)
            ?? (try? store.loadArticleContentPreparation(sourceID)?.raw)
            ?? (try? store.loadSourceContent(sourceID))
    }

    func articleChromeRefilterCandidates(limit: Int) throws -> [ArticleChromeRefilterCandidate] {
        try ensureStoreExists()
        return try knowledgeStore().articleChromeRefilterCandidates(limit: limit)
    }

    func articleChromeRefilterQueueCount() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().articleChromeRefilterQueueCount()
    }

    func completeArticleChromeRefilter(sourceID: String) throws {
        try ensureStoreExists()
        try knowledgeStore().completeArticleChromeRefilter(sourceID: sourceID)
    }

    func recordArticleChromeRefilterFailure(sourceID: String, message: String) throws {
        try ensureStoreExists()
        try knowledgeStore().recordArticleChromeRefilterFailure(sourceID: sourceID, message: message)
    }

    func republishArticleReaderDocument(sourceID: String) throws {
        try ensureStoreExists()
        try knowledgeStore().republishArticleReaderDocument(sourceID: sourceID)
    }

}
