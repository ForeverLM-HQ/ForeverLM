import Foundation
import os

private let logger = Logger(subsystem: "com.foreverlm", category: "ArticleChromeRefilter")

struct ArticleChromeRefilterDrainResult: Sendable {
    let processedCount: Int
    let processedSourceIDs: [String]
    let remainingCount: Int
}

/// Rewrites reader documents that were archived before `ArticleChromeFilter`.
///
/// `article.html` is written once, at fetch time, and never revised — so every
/// article ingested before the filter existed still opens with the publisher's
/// navigation, share bars, comment form, and footer, even though Source Content
/// Cleanup took those out of its canonical text. Fixing that means going back
/// to the live page, because the original markup was never stored.
///
/// That text is clean, but it is not always whole: an article extracted before
/// 06271e382 stops at 50,000 characters, so after this pass its archived page
/// can hold more than its text. The canonical cleanup reads the page and
/// cleans the complete text when it next runs for such an article
/// (`CanonicalContentCleanupService.withCompleteArticleExtraction`).
///
/// Deliberately narrow: this refetches, refilters, and re-archives, and touches
/// nothing else. It does not re-derive `source_content`, does not re-run Source
/// Content Cleanup, and cannot move a source out of `ready`. That keeps the pass
/// cheap — one small classification call per article rather than a full
/// reingestion — and keeps a page that has since changed, moved behind a wall,
/// or died from damaging text the learner already has.
actor ArticleChromeRefilterService {
    /// Each item is one page fetch plus one small model call. Kept well below
    /// the cleanup drain's twelve because these also download article images.
    static let maxCandidatesPerDrain = 4

    private let storage: StorageService
    private let sourceService: SourceService
    private var isDraining = false

    init(storage: StorageService, sourceService: SourceService = .shared) {
        self.storage = storage
        self.sourceService = sourceService
    }

    func drain() async -> ArticleChromeRefilterDrainResult {
        guard !isDraining else {
            return await result(processed: [])
        }
        isDraining = true
        defer { isDraining = false }

        // This is a one-time backfill, not steady-state upkeep, so one
        // invocation works the queue down rather than clearing four items and
        // waiting for the next unrelated trigger. Each batch is bounded and the
        // loop honours cancellation, so quitting the app stops it mid-pass and
        // the next launch resumes from the queue.
        var processed: [String] = []
        while !Task.isCancelled {
            let candidates: [ArticleChromeRefilterCandidate]
            do {
                candidates = try await storage.articleChromeRefilterCandidates(
                    limit: Self.maxCandidatesPerDrain
                )
            } catch {
                logger.error(
                    "Could not read the article chrome refilter queue: \(error.localizedDescription)"
                )
                break
            }
            if candidates.isEmpty { break }

            let batch = await withTaskGroup(of: String?.self) { group in
                for candidate in candidates {
                    group.addTask { await self.refilter(candidate) }
                }
                var done: [String] = []
                for await sourceID in group {
                    if let sourceID { done.append(sourceID) }
                }
                return done
            }
            processed.append(contentsOf: batch)
            if !batch.isEmpty {
                NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
            }
            // Every item in a batch that fails would otherwise spin this loop
            // through the whole queue at network speed.
            if batch.isEmpty { break }
            try? await Task.sleep(for: .seconds(1))
        }
        return await result(processed: processed)
    }

    /// Refetch, refilter, re-archive, and republish one article. Returns its ID
    /// on success; a failure is recorded against the queue row and swallowed, so
    /// one dead page never stops the pass.
    private func refilter(_ candidate: ArticleChromeRefilterCandidate) async -> String? {
        do {
            guard try await sourceService.refreshArchivedArticleHTML(
                url: candidate.url,
                sourceId: candidate.sourceID
            ) != nil else {
                throw SourceError.fetchFailed
            }
            // The archive is rewritten in place, so the stored path is already
            // right and only the synced asset needs invalidating.
            try await storage.republishArticleReaderDocument(sourceID: candidate.sourceID)
            try await storage.completeArticleChromeRefilter(sourceID: candidate.sourceID)
            return candidate.sourceID
        } catch {
            // An interrupted pass is not a dead page: leave the queue row as it
            // is so the next drain tries this article again from the top.
            if AITransientErrorClassifier.isCancellation(error) { return nil }
            let message = error.localizedDescription
            logger.warning(
                "Could not refilter \(candidate.title, privacy: .public): \(message, privacy: .public)"
            )
            do {
                try await storage.recordArticleChromeRefilterFailure(
                    sourceID: candidate.sourceID,
                    message: message
                )
            } catch {
                logger.error("Could not record the article chrome refilter failure: \(error.localizedDescription, privacy: .public)")
            }
            return nil
        }
    }

    private func result(processed: [String]) async -> ArticleChromeRefilterDrainResult {
        let remaining = (try? await storage.articleChromeRefilterQueueCount()) ?? 0
        if !processed.isEmpty {
            logger.info(
                "Refiltered \(processed.count) archived article(s); \(remaining) remaining"
            )
        }
        return ArticleChromeRefilterDrainResult(
            processedCount: processed.count,
            processedSourceIDs: processed,
            remainingCount: remaining
        )
    }
}
