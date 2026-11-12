import Foundation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif

/// Keeps the invariant "every source in the library has a chunk embedding" true, so
/// semantic search never silently misses a source. Papers are indexed from the
/// canonical clean derivative only; while cleanup is pending they receive the
/// normal metadata/header embedding rather than a raw-PDF body embedding.
///
/// This is not a startup migration. It is permanent index maintenance that runs
/// *in reaction to* changes — new ingests, sources arriving over CloudKit sync (which
/// never pass through the ingest path, and whose vectors are local-only derived data
/// that never sync), or an explicit rebuild — never on a launch hot path. Its work
/// list is the coverage gap `sources − sources-with-vectors`; draining it once fills
/// any historical backlog and thereafter only the delta.
///
/// Design properties that make it robust:
/// - **Off-main.** Every step (gap query, PDF/text extraction, embedding, DB write)
///   runs on this actor's executor or `StorageService`'s, never the main actor.
/// - **Idempotent + resumable.** It writes per source as it goes and recomputes the
///   gap on each pass, so an interruption just leaves a smaller gap next time; there
///   is no cursor to corrupt.
/// - **Coalesced.** Overlapping triggers collapse into one drain; a trigger that
///   arrives mid-drain sets a "rescan when done" flag instead of racing.
/// - **Yielding.** It embeds in small batches and sleeps between them so a large
///   backfill cannot monopolize the CPU or starve interactive embedding.
actor SourceEmbeddingIndexer {
    private let storage: StorageService
    private let embed: @Sendable (String) async throws -> [Float]
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "SourceEmbeddingIndexer")

    /// Sources indexed before pausing to yield the CPU.
    private static let batchSize = 8
    /// Chunks embedded within one source before pausing. Bounds how long a single large
    /// source can monopolize the embedding model.
    private static let chunkYieldStride = 32
    /// Pause between batches, so a multi-thousand-source backfill stays a background
    /// citizen rather than pinning a core for minutes.
    private static let interBatchPause = Duration.milliseconds(150)
    /// Full-text rows whose rowid one storage call records (schema 168). FTS5 reads each row
    /// whole, and 64 rows held at most 7.6 MB of text on the production library, so other storage
    /// work runs between batches.
    private static let fullTextRowRecordBatch = 64
    /// Sources one storage call takes out of search when they are out of it yet hold a part of
    /// it, and the most batches one pass runs (each batch takes its sources off the list, so this
    /// only bounds a pass if a row could not be taken).
    private static let searchSweepBatch = 64
    private static let searchSweepMaximumBatches = 200

    private var isDraining = false
    private var rescanRequested = false

    init(storage: StorageService, embed: @escaping @Sendable (String) async throws -> [Float]) {
        self.storage = storage
        self.embed = embed
    }

    /// Ask the indexer to bring coverage up to date. Safe to call from anywhere, as
    /// often as you like: calls coalesce, and one already in flight is not restarted.
    func requestIndexing() {
        if isDraining {
            rescanRequested = true
            return
        }
        // Maintenance, so it must never outrank a learner's chat send for the
        // storage actor. Set here as well as at the callers: whichever task
        // reaches this actor first decides the priority the drain runs at.
        Task(priority: .utility) { await self.drain() }
    }

    private func drain() async {
        guard !isDraining else { rescanRequested = true; return }
        isDraining = true
        defer { isDraining = false }

        await recordFullTextRows()
        // Before the embedding gap, which after an upgrade can take minutes: an archived
        // source should stop being found at once, not when the backlog is done.
        await dropSearchRowsOfSourcesOutOfSearch()

        repeat {
            rescanRequested = false
            let candidates = await storage.sourcesMissingIndex()
            if !candidates.isEmpty {
                logger.info("Search index backlog: \(candidates.count) source(s) unindexed")

                var indexed = 0
                var batchInFlight = 0
                for candidate in candidates {
                    do {
                        try await indexOne(candidate)
                        indexed += 1
                    } catch is CancellationError {
                        return
                    } catch {
                        // A single bad source (unreadable PDF, transient model error) must
                        // not stall the whole backlog. Log and move on; the gap query will
                        // resurface it on the next pass.
                        logger.error("Failed to index source \(candidate.id): \(error.localizedDescription)")
                    }

                    batchInFlight += 1
                    if batchInFlight >= Self.batchSize {
                        batchInFlight = 0
                        try? await Task.sleep(for: Self.interBatchPause)
                    }
                }
                if indexed > 0 {
                    logger.info("Indexed \(indexed) source(s)")
                }
            }

            // Runs after the embedding gap, not instead of it: `indexOne` writes a
            // current full-text row on its way through, so anything it just handled is
            // already off this list.
            await reanalyzeStaleFullTextRows()

            // Last, so a source archived while this pass indexed it leaves search too.
            await dropSearchRowsOfSourcesOutOfSearch()
        } while rescanRequested

        // Report coverage rather than assuming it. A non-zero remainder means some sources
        // failed to index repeatedly (unreadable file, embedding error) and would otherwise
        // be invisible to search forever without anyone noticing.
        if let coverage = await storage.searchIndexCoverage() {
            let pending = max(0, coverage.activeSources - coverage.indexedSources)
            if pending == 0 {
                logger.info("Search index complete: \(coverage.indexedSources) source(s), \(coverage.chunkVectors) chunk vectors")
            } else {
                logger.error("Search index incomplete: \(pending) of \(coverage.activeSources) active source(s) still unindexed")
            }
        }
    }

    /// Record where the full-text rows written before schema 168 are, a batch at a time, so a
    /// row is deleted by its rowid instead of by reading every row (`KnowledgeStore.recordSourceFTSRows`).
    /// Done once per store; a store with nothing to record answers at once. A delete that comes
    /// before the last batch records the rest itself, so stopping early loses nothing.
    private func recordFullTextRows() async {
        do {
            while try await storage.recordSourceFTSRows(limit: Self.fullTextRowRecordBatch) {
                if Task.isCancelled { return }
                try? await Task.sleep(for: Self.interBatchPause)
            }
        } catch {
            logger.error("Recording full-text rowids paused: \(error.localizedDescription)")
        }
    }

    /// Take out of search what an archive or a delete left in it: one that arrived by sync took
    /// nothing with it, an index written while its source was being archived lands after the
    /// archive, and a writer that did not drop them left full-text rows and vectors behind
    /// (`StorageService.dropSearchRowsOfSourcesOutOfSearch`). The check reads only small tables,
    /// so it runs on every pass and costs next to nothing once nothing is left.
    private func dropSearchRowsOfSourcesOutOfSearch() async {
        var dropped = 0
        do {
            for _ in 0..<Self.searchSweepMaximumBatches {
                if Task.isCancelled { break }
                let count = try await storage.dropSearchRowsOfSourcesOutOfSearch(limit: Self.searchSweepBatch)
                dropped += count
                guard count == Self.searchSweepBatch else { break }
                try? await Task.sleep(for: Self.interBatchPause)
            }
        } catch {
            logger.error("Taking archived and deleted sources out of search paused: \(error.localizedDescription)")
        }
        if dropped > 0 {
            logger.info("Took \(dropped) archived or deleted source(s) out of search")
        }
    }

    /// Rewrite full-text rows written by an older analyzer.
    ///
    /// Text-only maintenance, and the reason the analyzer can be improved at all: no
    /// embedding runs here, so raising `SourceSearchEngine.indexAnalyzerVersion` costs a
    /// pass over stored text rather than the price of re-embedding the library. Text is
    /// resolved the same way indexing resolves it, so a paper whose words only exist
    /// inside its PDF keeps its body in the index instead of dropping to title-only.
    private func reanalyzeStaleFullTextRows() async {
        let stale = await storage.sourcesNeedingFTSRebuild()
        guard !stale.isEmpty else { return }
        logger.info("Full-text reanalysis: \(stale.count) source(s) on an older analyzer")

        var rewritten = 0
        var batchInFlight = 0
        for candidate in stale {
            if Task.isCancelled { return }
            do {
                let content = await resolveText(for: candidate)
                try await storage.replaceSourceFTS(
                    sourceID: candidate.id,
                    title: candidate.title,
                    author: candidate.author,
                    body: content ?? ""
                )
                rewritten += 1
            } catch is CancellationError {
                return
            } catch {
                // Same contract as the embedding gap: one unreadable source must not
                // stall the rest, and the gap query resurfaces it next pass.
                logger.error("Failed to reanalyze source \(candidate.id): \(error.localizedDescription)")
            }

            batchInFlight += 1
            if batchInFlight >= Self.batchSize {
                batchInFlight = 0
                try? await Task.sleep(for: Self.interBatchPause)
            }
        }
        if rewritten > 0 {
            logger.info("Reanalyzed \(rewritten) full-text row(s)")
        }
    }

    /// Resolve a source's text once, then build *both* halves of search from it: chunk
    /// vectors for meaning, and a full-text row for exact terms. A source with no
    /// recoverable text still gets a title/domain vector and a title/author full-text row,
    /// so the invariant is "every source is at least findable by name".
    ///
    /// The full-text row is written from the same resolved text — including text extracted
    /// on the fly from a paper's PDF. That is what makes a GDF15 paper findable by the
    /// literal term without ever writing the extracted text back into `source_content`
    /// (which would re-push every paper to CloudKit as a new asset).
    private func indexOne(_ candidate: KnowledgeStore.EmbeddingCandidate) async throws {
        let content = await resolveText(for: candidate)

        let inputs = SourceEmbeddingText.chunkInputs(
            sourceID: candidate.id,
            title: candidate.title,
            domain: candidate.domain,
            content: content
        )
        var vectors: [(chunkId: String, vector: [Float])] = []
        vectors.reserveCapacity(inputs.count)
        for (offset, input) in inputs.enumerated() {
            try Task.checkCancellation()
            let vector = try await embed(input.embeddingText)
            vectors.append((chunkId: input.id, vector: vector))

            // Yield inside the source, not just between sources. A long book runs to a few
            // thousand chunks; at ~42ms each that would hold the embedding model's lock for
            // minutes on end and stall an interactive search waiting to embed its query.
            if (offset + 1) % Self.chunkYieldStride == 0 {
                try? await Task.sleep(for: Self.interBatchPause)
            }
        }
        try await storage.saveSourceChunkEmbeddings(sourceId: candidate.id, embeddings: vectors)

        try await storage.replaceSourceFTS(
            sourceID: candidate.id,
            title: candidate.title,
            author: candidate.author,
            body: content ?? ""
        )

        // Stamp last: if anything above threw, the source stays in the gap set and is
        // retried, rather than being recorded as done when it isn't.
        try await storage.recordSourceIndexed(sourceID: candidate.id)
    }

    /// Best available text for a source: stored content, else on-the-fly extraction
    /// from its local file (PDF/text), else a podcast's raw transcript. Returns nil
    /// when none exists — the caller falls back to a header-only embedding.
    ///
    /// Extraction is read-only and never persisted here: writing recovered PDF text
    /// back into `source_content` would re-push every paper to CloudKit as a new asset,
    /// so that is left as a separate, deliberate decision.
    private func resolveText(for candidate: KnowledgeStore.EmbeddingCandidate) async -> String? {
        if let stored = await storage.loadSourceContent(candidate.id),
           !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stored
        }

        // Papers may only be indexed from their canonical cleaned derivative.
        // Falling back to the PDF here would reintroduce references/furniture
        // into embeddings while chat and voice see different text.
        if candidate.sourceType != StudioSourceType.paper.rawValue,
           let path = candidate.localFilePath,
           let extracted = Self.extractTextFromLocalFile(path, pages: candidate.bookPages),
           !extracted.isEmpty {
            return extracted
        }

        if candidate.sourceType == "podcast",
           let ttml = await storage.podcastRawTTML(forSourceID: candidate.id),
           !ttml.isEmpty,
           let text = try? SourceService.extractTextFromTTMLContent(ttml),
           !text.isEmpty {
            return text
        }

        return nil
    }

    /// PDF/text extraction mirroring the MCP `get_source_content` fallback. Static and
    /// nonisolated so it runs on the calling actor's executor without hopping.

    private static func extractTextFromLocalFile(_ path: String, pages: Range<Int>?) -> String? {
        guard let resolved = SourceService.resolveLocalFileURL(path),
              FileManager.default.fileExists(atPath: resolved.path) else { return nil }

        #if canImport(PDFKit)
        if resolved.path.lowercased().hasSuffix(".pdf") {
            guard let document = PDFDocument(url: resolved) else { return nil }
            // Every page so a term appearing late in a long document remains findable;
            // a book chapter's pages of its book's file.
            let range = pages ?? 0..<document.pageCount
            guard range.upperBound <= document.pageCount else { return nil }
            let text = PDFTextExtractor.textWithFigureReferences(from: document, pages: range)
            return text.isEmpty ? nil : text
        }
        #endif

        return try? String(contentsOfFile: resolved.path, encoding: .utf8)
    }
}
