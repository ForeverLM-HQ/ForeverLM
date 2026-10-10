import Foundation
import OSLog

// MARK: - Draining the activation's backfill queues (docs/cloudkit-schema-design.md §13.3 step 4)

extension KnowledgeStore {
    /// How far the satellite queues the activation filled have got: the rows left that can still be tried
    /// and the attempts spent on them. A batch that moves either has made progress, even when every
    /// source in it failed (its attempts count), so a drain never stops on a run of bad rows while
    /// good ones wait behind them.
    func satelliteBackfillProgress() throws -> (rows: Int64, attempts: Int64) {
        var progress: (rows: Int64, attempts: Int64) = (0, 0)
        try query("""
            SELECT COUNT(*), COALESCE(SUM(attempts), 0) FROM ck_backfill_queue
            WHERE kind IN (?, ?) AND attempts < 5
        """, [.text(Self.sourceFilesBackfillKind), .text(Self.understandingBackfillKind)]) { row in
            progress = (row.integer(0) ?? 0, row.integer(1) ?? 0)
        }
        return progress
    }

    /// One bounded batch of the two satellite queues (source files and Understanding documents): the
    /// sources and documents it laid out. Generation 2 only; both are resumable.
    @discardableResult
    func runSatelliteBackfillBatch(limit: Int = 50) throws -> Int {
        try runSourceFilesBackfill(limit: limit) + runUnderstandingBackfill(limit: limit)
    }
}

/// Runs the activation's queues on the Mac: every source's files and text laid out as pointers before the
/// seed sends the records that carry them, every Understanding document, and the narration positions an
/// evicted file held back. Without it a Source is seeded with empty `files` and `derived` and no PDF,
/// text or guide ever reaches the phone or the web. In bounded batches, each its own turn on the store,
/// at `.utility`, so nothing else waits on it for long; resumable, since each item leaves its queue with
/// its rows.
enum SyncBackfillDrain {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "SyncBackfillDrain")

    /// Drains until a batch moves nothing. Returns the items laid out.
    @discardableResult
    static func run(store: MacPrivateSyncStore, batch: Int = 50) async -> Int {
        await Task.detached(priority: .utility) { () -> Int in
            var laid = 0
            do {
                while true {
                    let before = try await store.onStore { try $0.satelliteBackfillProgress() }
                    laid += try await store.onStore { try $0.runSatelliteBackfillBatch(limit: batch) }
                    let after = try await store.onStore { try $0.satelliteBackfillProgress() }
                    if before == after { break }
                    await Task.yield()
                }
                // A narration file iCloud Drive had not downloaded is asked for and read when it lands: one
                // pass per drain, since each look at a file still evicted spends one of its attempts.
                laid += try await store.onStore { try $0.runListenFileBackfill(limit: batch) }
            } catch {
                logger.error("A backfill batch failed: \(String(describing: error), privacy: .public)")
            }
            return laid
        }.value
    }
}
