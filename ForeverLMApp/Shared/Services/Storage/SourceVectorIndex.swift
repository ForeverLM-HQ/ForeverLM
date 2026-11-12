import Foundation
import Accelerate
import OSLog

/// In-memory nearest-neighbour index over source chunk embeddings.
///
/// Chunk search reads every vector from memory here; re-reading every vector from
/// SQLite on *every query* and scoring them with a scalar cosine loop would cost, at
/// full coverage (~90k chunks), ~175 MB of SQLite reads and ~46M scalar
/// float ops per search.
///
/// Measured on this corpus size (90k x 512), the alternatives are:
///
///   scalar loop                       35.9 ms/query
///   Accelerate sgemv                  18.8 ms/query
///   sgemv + partial top-k selection    6.9 ms/query   <- what this does
///
/// An approximate index (HNSW) buys nothing at this scale: exact brute force is
/// already single-digit milliseconds, and it costs no recall, no index build, no
/// on-disk store to keep in sync, and no third-party dependency.
///
/// Vectors are held as one contiguous row-major `Float` matrix so the entire search is
/// a single BLAS matrix-vector multiply. Rows are L2-normalized at load, which makes
/// the dot product exactly cosine similarity.
///
/// Not thread-safe by itself — it is owned by the `StorageService` actor, which
/// serializes all access.
final class SourceVectorIndex {
    private let dimensions: Int
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "SourceVectorIndex")

    /// Row-major `rowCount x dimensions`, L2-normalized rows.
    private var matrix: [Float] = []
    /// Chunk embedding id for each row, parallel to `matrix`.
    private var ids: [String] = []
    /// Owning source id for each row, parallel to `ids`.
    ///
    /// Held rather than parsed on demand so a scoped search can reject a row
    /// with one set lookup. Re-deriving the source from 90k chunk ids per
    /// query would cost more than the matrix multiply the search is built
    /// around. Empty string for a chunk id that does not parse, which simply
    /// never matches a caller's allow-set.
    private var sourceIDs: [String] = []
    /// Sources currently represented, so a re-embed can skip the O(n) removal scan
    /// when the source isn't in the index yet (the common case while backfilling).
    private var presentSources: Set<String> = []

    private var isLoaded = false

    init(dimensions: Int) {
        self.dimensions = dimensions
    }

    var rowCount: Int { ids.count }

    /// Drop the index so the next search rebuilds it from SQLite.
    func invalidate() {
        matrix = []
        ids = []
        sourceIDs = []
        presentSources = []
        isLoaded = false
    }

    /// Build from the full vector set. Rows with the wrong dimension are skipped rather
    /// than corrupting the matrix stride.
    func load(_ embeddings: [String: [Float]], sourceIDForChunk: (String) -> String?) {
        matrix = []
        ids = []
        sourceIDs = []
        presentSources = []
        matrix.reserveCapacity(embeddings.count * dimensions)
        ids.reserveCapacity(embeddings.count)
        sourceIDs.reserveCapacity(embeddings.count)

        for (id, vector) in embeddings {
            guard vector.count == dimensions else { continue }
            append(id: id, vector: vector, sourceIDForChunk: sourceIDForChunk)
        }
        isLoaded = true
        logger.info("Loaded \(self.ids.count) chunk vectors into memory (\(self.ids.count * self.dimensions * 4 / 1_048_576) MB)")
    }

    /// Replace a source's rows in place. Cheap when the source is new (pure append);
    /// when it already has rows they are filtered out first, which is an O(n) compaction
    /// of the matrix — still far cheaper than re-reading every vector from SQLite.
    func replace(
        sourceID: String,
        chunks: [(chunkId: String, vector: [Float])],
        sourceIDForChunk: (String) -> String?
    ) {
        guard isLoaded else { return }

        if presentSources.contains(sourceID) {
            var keptIDs: [String] = []
            var keptSourceIDs: [String] = []
            var keptMatrix: [Float] = []
            keptIDs.reserveCapacity(ids.count)
            keptSourceIDs.reserveCapacity(ids.count)
            keptMatrix.reserveCapacity(matrix.count)
            for row in ids.indices where sourceIDs[row] != sourceID {
                keptIDs.append(ids[row])
                keptSourceIDs.append(sourceIDs[row])
                keptMatrix.append(contentsOf: matrix[(row * dimensions)..<((row + 1) * dimensions)])
            }
            ids = keptIDs
            sourceIDs = keptSourceIDs
            matrix = keptMatrix
            presentSources.remove(sourceID)
        }

        for chunk in chunks {
            guard chunk.vector.count == dimensions else { continue }
            append(id: chunk.chunkId, vector: chunk.vector, sourceIDForChunk: sourceIDForChunk)
        }
    }

    private func append(id: String, vector: [Float], sourceIDForChunk: (String) -> String?) {
        guard let row = Self.l2Normalized(vector) else { return }
        let sourceID = sourceIDForChunk(id)
        matrix.append(contentsOf: row)
        ids.append(id)
        sourceIDs.append(sourceID ?? "")
        if let sourceID { presentSources.insert(sourceID) }
    }

    /// L2-normalize a vector, or nil if it has zero magnitude. Normalizing both the
    /// rows and the query is what lets the search use a plain matrix-vector product
    /// and still get exact cosine similarity.
    ///
    /// The scaling is done through an explicit mutable buffer pointer rather than
    /// passing the array as both an input and an `inout` argument in one call, which
    /// would be overlapping access.
    private static func l2Normalized(_ vector: [Float]) -> [Float]? {
        var normSq: Float = 0
        vDSP_svesq(vector, 1, &normSq, vDSP_Length(vector.count))
        guard normSq > 0, normSq.isFinite else { return nil }
        var inverseNorm = 1.0 / normSq.squareRoot()

        var row = vector
        row.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_vsmul(base, 1, &inverseNorm, base, 1, vDSP_Length(buffer.count))
        }
        return row
    }

    /// Exact top-K by cosine similarity. One BLAS pass, then a bounded partial
    /// selection — no full sort of the score vector.
    ///
    /// `allowedSources` restricts the search to a subset of the library, for
    /// callers ranking within an already-chosen set (a chat's attached
    /// sources, a Notebook's pool). It has to be applied *before* selection,
    /// not after: this returns a global top-K, so filtering the results of an
    /// unrestricted search would leave a 71-source subset almost entirely
    /// unrepresented — its chunks never make the buffer in the first place.
    /// Scoring only the requested rows is also far cheaper than multiplying
    /// the whole corpus to then throw 97% of it away.
    func search(
        queryVector: [Float],
        topK: Int,
        threshold: Float,
        allowedSources: Set<String>? = nil,
        excludedSources: Set<String> = []
    ) -> [(id: String, score: Float)] {
        guard isLoaded, !ids.isEmpty, queryVector.count == dimensions, topK > 0 else { return [] }
        guard let query = Self.l2Normalized(queryVector) else { return [] }

        // When scoped, gather the requested rows into a compact matrix and
        // multiply that. `selectedRows` maps a score position back to the row
        // it came from; nil means the score vector already is the full matrix.
        let selectedRows: [Int]?
        let scoreMatrix: [Float]
        if let allowedSources {
            let selected = ids.indices.filter { row in
                allowedSources.contains(sourceIDs[row]) && !excludedSources.contains(sourceIDs[row])
            }
            guard !selected.isEmpty else { return [] }
            selectedRows = selected
            scoreMatrix = gatheredRows(selected)
        } else {
            selectedRows = nil
            scoreMatrix = matrix
        }

        let rows = selectedRows?.count ?? ids.count
        var scores = [Float](repeating: 0, count: rows)
        // scores[rows x 1] = matrix[rows x dims] * query[dims x 1]. vDSP_mmul rather
        // than cblas_sgemv: the classic CBLAS interface is deprecated and its ILP64
        // replacement would force new-LAPACK compile flags on the whole target.
        scoreMatrix.withUnsafeBufferPointer { m in
            query.withUnsafeBufferPointer { q in
                vDSP_mmul(
                    m.baseAddress!, 1,
                    q.baseAddress!, 1,
                    &scores, 1,
                    vDSP_Length(rows), 1, vDSP_Length(dimensions)
                )
            }
        }

        // Bounded partial selection rather than sorting every hit. The similarity
        // threshold is effectively zero (mean-pooled contextual vectors are anisotropic,
        // so even unrelated text scores ~0.8), which means nearly every row "passes" and
        // a full sort of 90k hits would dominate the query. Instead keep a small buffer
        // and raise a running cutoff to the k-th best once it fills, so the vast majority
        // of rows are rejected by a single float compare.
        var hits: [(id: String, score: Float)] = []
        let bufferLimit = max(topK * 2, 32)
        hits.reserveCapacity(bufferLimit)
        var cutoff = threshold

        func compact() {
            hits.sort { lhs, rhs in
                if lhs.score == rhs.score { return lhs.id < rhs.id }
                return lhs.score > rhs.score
            }
            if hits.count > topK { hits.removeLast(hits.count - topK) }
            if hits.count == topK, let last = hits.last { cutoff = max(cutoff, last.score) }
        }

        for position in 0..<rows where scores[position] >= cutoff {
            let row = selectedRows?[position] ?? position
            guard !excludedSources.contains(sourceIDs[row]) else { continue }
            hits.append((id: ids[row], score: scores[position]))
            if hits.count >= bufferLimit { compact() }
        }
        compact()
        return hits
    }

    /// The unit-length mean of each requested source's chunk rows: one vector
    /// standing for what the source is about. A source with no rows is absent
    /// from the result. One pass over the row list, whatever the set's size.
    func centroids(forSources requested: Set<String>) -> [String: [Float]] {
        guard isLoaded, !requested.isEmpty else { return [:] }
        var sums: [String: [Float]] = [:]
        for row in ids.indices where requested.contains(sourceIDs[row]) {
            let sourceID = sourceIDs[row]
            var sum = sums[sourceID] ?? [Float](repeating: 0, count: dimensions)
            matrix.withUnsafeBufferPointer { rows in
                guard let origin = rows.baseAddress else { return }
                sum.withUnsafeMutableBufferPointer { accumulator in
                    guard let target = accumulator.baseAddress else { return }
                    vDSP_vadd(target, 1, origin.advanced(by: row * dimensions), 1, target, 1, vDSP_Length(dimensions))
                }
            }
            sums[sourceID] = sum
        }
        return sums.compactMapValues(Self.l2Normalized)
    }

    /// Each allowed source's best chunk score against any of `queries`, with
    /// the index of the query that produced it. One matrix-matrix multiply
    /// scores every allowed row against every query at once, so ten queries
    /// cost one pass over the rows rather than ten.
    ///
    /// Unlike `search`, nothing is cut to a top-K: the caller wants a score for
    /// every allowed source, and ranks them itself. The allowed set is usually
    /// most of the library (everything not yet opened), so the whole matrix is
    /// multiplied in place and the filter applied to the scores; gathering the
    /// allowed rows first would copy nearly the full index per call.
    func bestSourceScores(
        queries: [[Float]],
        allowedSources: Set<String>
    ) -> [String: (score: Float, query: Int)] {
        let normalized = queries.map { $0.count == dimensions ? Self.l2Normalized($0) : nil }
        let usable = normalized.indices.filter { normalized[$0] != nil }
        guard isLoaded, !ids.isEmpty, !usable.isEmpty, !allowedSources.isEmpty else { return [:] }
        let rowCount = ids.count

        // queryMatrix is dims x q row-major, so column j is query usable[j].
        let queryCount = usable.count
        var queryMatrix = [Float](repeating: 0, count: dimensions * queryCount)
        for (column, queryIndex) in usable.enumerated() {
            guard let query = normalized[queryIndex] else { continue }
            for dimension in 0..<dimensions {
                queryMatrix[dimension * queryCount + column] = query[dimension]
            }
        }

        // scores[rows x q] = matrix[rows x dims] * queryMatrix[dims x q]
        var scores = [Float](repeating: 0, count: rowCount * queryCount)
        matrix.withUnsafeBufferPointer { m in
            queryMatrix.withUnsafeBufferPointer { q in
                vDSP_mmul(
                    m.baseAddress!, 1,
                    q.baseAddress!, 1,
                    &scores, 1,
                    vDSP_Length(rowCount), vDSP_Length(queryCount), vDSP_Length(dimensions)
                )
            }
        }

        var best: [String: (score: Float, query: Int)] = [:]
        for row in 0..<rowCount where allowedSources.contains(sourceIDs[row]) {
            let sourceID = sourceIDs[row]
            for column in 0..<queryCount {
                let score = scores[row * queryCount + column]
                if let current = best[sourceID], current.score >= score { continue }
                best[sourceID] = (score, usable[column])
            }
        }
        return best
    }

    /// Copy the given rows into a compact row-major matrix, preserving order.
    private func gatheredRows(_ rows: [Int]) -> [Float] {
        var gathered = [Float](repeating: 0, count: rows.count * dimensions)
        gathered.withUnsafeMutableBufferPointer { destination in
            guard let target = destination.baseAddress else { return }
            matrix.withUnsafeBufferPointer { source in
                guard let origin = source.baseAddress else { return }
                for (position, row) in rows.enumerated() {
                    target.advanced(by: position * dimensions)
                        .update(from: origin.advanced(by: row * dimensions), count: dimensions)
                }
            }
        }
        return gathered
    }
}

/// Process-wide owner of the chunk vector index.
///
/// The index is ~184 MB at full coverage, and both the in-app search and the MCP tools
/// need it. They reach storage by different routes — `StorageService` for the app, a
/// separate `KnowledgeStore` for MCP — so an index owned by either one would leave the
/// other re-reading every vector from SQLite on every query, which is precisely the
/// slow path `SourceVectorIndex` exists to remove. Holding it here means one copy, one
/// build, and the same search cost from both surfaces. It also removes a latent hazard:
/// `StorageService` is constructed in several places, and a per-instance index would let
/// a second instance quietly build a second 184 MB copy.
///
/// Access is serialized with a lock rather than by making this an actor: `SourceVectorIndex`
/// is not thread-safe, and the callers include synchronous paths that have no `await` to
/// spend. Never touch this from the main actor — the first access loads every vector
/// from SQLite.
final class SharedSourceVectorIndex: @unchecked Sendable {
    static let shared = SharedSourceVectorIndex()

    private let lock = NSLock()
    private var index: SourceVectorIndex?
    private var indexDimensions: Int?
    private var indexStorePath: String?

    private init() {}

    /// Run `body` against the shared index, rebuilding it if the embedding dimensions or
    /// the backing database changed since it was created.
    ///
    /// Keying on `storePath` is what keeps a single shared index honest: the app only
    /// ever opens one knowledge.db, but tests open a fresh temporary one per case, and an
    /// index that outlived its database would answer queries with another store's
    /// vectors. Rebuilding on a path change costs nothing in the app and makes the
    /// process-wide cache safe everywhere else.
    func withIndex<T>(storePath: String, dimensions: Int, _ body: (SourceVectorIndex) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        if index == nil || indexDimensions != dimensions || indexStorePath != storePath {
            index = SourceVectorIndex(dimensions: dimensions)
            indexDimensions = dimensions
            indexStorePath = storePath
        }
        return body(index!)
    }
}
