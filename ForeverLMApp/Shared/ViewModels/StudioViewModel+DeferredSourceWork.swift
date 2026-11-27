// Source embedding indexing and the deferred repair, audit and cleanup runs.

import Foundation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif
import Darwin

extension StudioViewModel {

    /// Ask the background indexer to bring embedding coverage up to date. Cheap and
    /// coalesced — safe to call from any change-triggered path.
    ///
    /// Utility priority, explicitly. A plain `Task` inherits the priority of the
    /// main-actor code that spawned it, which made a library-wide re-index rank as
    /// user-interactive work on the storage actor's queue and hold a chat send at
    /// "Getting your sources ready" behind every batch of embedding rows. Actor
    /// queues are priority-ordered, so naming the priority is what lets the send
    /// go first.
    func kickSourceEmbeddingIndexing() {
        Task(priority: .utility) { await sourceEmbeddingIndexer.requestIndexing() }
    }

    /// `kickSourceEmbeddingIndexing` after a short quiet, for the paths that run once per
    /// source: a source saved or fetched is searchable by its title and text within
    /// seconds, not at the next launch, while an import saving hundreds of them asks
    /// for one pass rather than one per save.
    func kickSourceEmbeddingIndexingSoon() {
        sourceIndexingKickTask?.cancel()
        sourceIndexingKickTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.kickSourceEmbeddingIndexing()
        }
    }

    /// Adopt historical Zoom video rows only after the source list is visible.
    /// Bounded batches keep the storage actor available; the final reload
    /// publishes type, series relationship, and provider together.
    func runDeferredZoomMeetingAdoption() async {
        guard !zoomMeetingAdoptionInFlight else { return }
        zoomMeetingAdoptionInFlight = true
        defer { zoomMeetingAdoptionInFlight = false }
        var adoptedIDs: [String] = []
        do {
            while !Task.isCancelled {
                let batch = try await storage.drainZoomMeetingAdoptionBatch(limit: 50)
                guard !batch.isEmpty else { break }
                adoptedIDs.append(contentsOf: batch)
                await Task.yield()
            }
        } catch {
            logger.error("Deferred Zoom meeting adoption paused: \(error.localizedDescription)")
        }
        guard !adoptedIDs.isEmpty else { return }
        let refreshed = (await loggedRead("persisted sources") { try await storage.loadPersistedSources(ids: adoptedIDs) }) ?? []
        let byID = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.id, $0) })
        var updated = articles
        var changed = false
        for index in updated.indices {
            guard let replacement = byID[updated[index].id] else { continue }
            updated[index] = replacement
            changed = true
        }
        if changed { articles = updated }
    }

    /// Decode the HTML character references that older ingestion left in stored
    /// source text. Small batches keep SQLite available and make the work
    /// resumable if the app closes midway through an upgrade.
    func runDeferredSourceTextReferenceRepair() async {
        guard !sourceTextReferenceRepairInFlight else { return }
        sourceTextReferenceRepairInFlight = true
        defer { sourceTextReferenceRepairInFlight = false }
        var repairedIDs: Set<String> = []
        do {
            while !Task.isCancelled {
                let repaired = try await storage.drainSourceTextReferenceRepairBatch(limit: 50)
                guard !repaired.isEmpty else { break }
                repairedIDs.formUnion(repaired)
                await Task.yield()
            }
        } catch {
            logger.error("Deferred source text repair paused: \(error.localizedDescription)")
        }
        guard !repairedIDs.isEmpty else { return }
        // A loaded article still holds the pre-repair extraction. Assign once:
        // mutating `articles[index]` runs the array's didSet and rebuilds the
        // sidebar indexes for every element touched.
        var updatedArticles = articles
        var didChange = false
        for index in updatedArticles.indices
        where repairedIDs.contains(updatedArticles[index].id) && updatedArticles[index].content != nil {
            updatedArticles[index].content = nil
            didChange = true
        }
        if didChange { articles = updatedArticles }
    }

    /// Drop the soft hyphens left in stored source text (schema
    /// 166), keeping what was derived from the old text with the repaired text's
    /// hash. Waits for the library to load: the launch runs it then, before sync
    /// starts, so this Mac repairs its own copy — and keeps its Listen text,
    /// review guides and ideas — before another Mac's repaired text arrives as a
    /// new text for them. App activation runs it again for a source a paid pass
    /// held back, or text an older build on another Mac published since. A call
    /// while it runs waits for that run.
    func runDeferredStoredSoftHyphenRepair() async {
        guard hasCompletedInitialQueueLoad else { return }
        if let running = storedSoftHyphenRepairTask {
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.drainStoredSoftHyphenRepairQueue()
        }
        storedSoftHyphenRepairTask = task
        await task.value
        storedSoftHyphenRepairTask = nil
    }

    private func drainStoredSoftHyphenRepairQueue() async {
        var repairedIDs: Set<String> = []
        do {
            while !Task.isCancelled {
                let batch = try await storage.drainStoredSoftHyphenRepairBatch(limit: 50)
                repairedIDs.formUnion(batch.repairedSourceIDs)
                // A batch of clean sources is progress too; only an empty one ends it.
                guard batch.processedCount > 0 else { break }
                await Task.yield()
            }
        } catch {
            logger.error("Deferred soft hyphen repair paused: \(error.localizedDescription)")
        }
        guard !repairedIDs.isEmpty else { return }
        logger.notice("Removed soft hyphens from the stored text of \(repairedIDs.count) source(s)")
        // A loaded source still holds the old text, and a paper the hash of its old
        // extraction (`paperContentSHA256`, one of its identity keys). Assign once:
        // mutating `articles[index]` runs the array's didSet and rebuilds the
        // sidebar indexes for every element touched.
        let refreshed = (await loggedRead("persisted sources") { try await storage.loadPersistedSources(ids: Array(repairedIDs)) }) ?? []
        let byID = Dictionary(refreshed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var updatedArticles = articles
        var didChange = false
        for index in updatedArticles.indices where repairedIDs.contains(updatedArticles[index].id) {
            if updatedArticles[index].content != nil {
                updatedArticles[index].content = nil
                didChange = true
            }
            guard let source = byID[updatedArticles[index].id] else { continue }
            if updatedArticles[index].title != source.title {
                updatedArticles[index].title = source.title
                didChange = true
            }
            if updatedArticles[index].paperContentSHA256 != source.paperContentSHA256 {
                updatedArticles[index].paperContentSHA256 = source.paperContentSHA256
                didChange = true
            }
        }
        if didChange { articles = updatedArticles }
        // The repaired sources lost their full-text rows and embeddings.
        kickSourceEmbeddingIndexing()
    }

    /// Count the words of every source whose text is stored but whose count is
    /// missing (`drainSourceWordCountRepairBatch`): a source with text and no
    /// count reads as "no text yet" to the chat catalog and `filter_sources`.
    /// A no-op once nothing is missing, so launch and activation
    /// both run it; activation also counts text another device sent uncounted.
    func runDeferredSourceWordCountRepair() async {
        guard !sourceWordCountRepairInFlight else { return }
        sourceWordCountRepairInFlight = true
        defer { sourceWordCountRepairInFlight = false }
        var counts: [String: Int] = [:]
        var cursor: String?
        do {
            while !Task.isCancelled {
                let batch = try await storage.drainSourceWordCountRepairBatch(after: cursor, limit: 50)
                guard let last = batch.lastSourceID else { break }
                counts.merge(batch.counts) { _, new in new }
                cursor = last
                await Task.yield()
            }
        } catch {
            logger.error("Deferred word count repair paused: \(error.localizedDescription)")
        }
        guard !counts.isEmpty else { return }
        logger.notice("Counted the words of \(counts.count) source(s) whose stored text had no count")
        // A loaded row still holds the missing count, and a later save of it
        // would write that back. Assign once: mutating `articles[index]` runs
        // the array's didSet and rebuilds the sidebar indexes for every
        // element touched.
        var updatedArticles = articles
        var didChange = false
        for index in updatedArticles.indices {
            guard let count = counts[updatedArticles[index].id],
                  updatedArticles[index].wordCount != count else { continue }
            updatedArticles[index].wordCount = count
            didChange = true
        }
        if didChange { articles = updatedArticles }
    }

    /// Check staged papers' titles against the titles their DOIs are
    /// registered under (schema 144) and show a restored title at once: the
    /// store already holds it, the loaded row still has the damaged copy.
    /// Assign once, like the other deferred repairs, so the sidebar indexes
    /// rebuild a single time.
    func runRegisteredPaperTitleCheck() async {
        let result = await registeredPaperTitleCheckService.drain()
        guard !result.restored.isEmpty else { return }
        var titles: [String: String] = [:]
        for restored in result.restored {
            titles[restored.sourceID] = restored.title
        }
        var updatedArticles = articles
        var didChange = false
        for index in updatedArticles.indices {
            guard let title = titles[updatedArticles[index].id],
                  updatedArticles[index].title != title else { continue }
            updatedArticles[index].title = title
            didChange = true
        }
        if didChange { articles = updatedArticles }
        // The restored rows lost their full-text state; rewrite them.
        kickSourceEmbeddingIndexing()
    }

    /// Hold staged YouTube transcripts to their captions (schema 148) and
    /// show a rewritten one at once: the store already holds it, the loaded
    /// row still has the old text. Assign once, like the other deferred
    /// repairs, so the sidebar indexes rebuild a single time.
    func runYouTubeTranscriptCheck() async {
        let result = await youTubeTranscriptCheckService.drain()
        guard !result.rewritten.isEmpty else { return }
        var contents: [String: String] = [:]
        for transcript in result.rewritten {
            contents[transcript.sourceID] = transcript.content
        }
        var updatedArticles = articles
        var didChange = false
        for index in updatedArticles.indices {
            // A row whose text was never loaded reads the new one when it is.
            guard let content = contents[updatedArticles[index].id],
                  let loaded = updatedArticles[index].content, loaded != content else { continue }
            updatedArticles[index].content = content
            updatedArticles[index].wordCount = content.split(separator: " ").count
            didChange = true
        }
        if didChange { articles = updatedArticles }
        // The rewritten rows lost their full-text and embedding state.
        kickSourceEmbeddingIndexing()
    }

    /// Remove the rendered figure JPEGs that PDF indexing wrote before schema 75.
    ///
    /// One traversal of the content roots, once per device, entirely off the main
    /// actor. It is gated on a local flag rather than a synced preference because
    /// the files are this Mac's — the other Mac has its own copies to clear.
    func runDeferredPaperFigureImageSweep() async {
        guard !paperFigureImageSweepInFlight else { return }
        paperFigureImageSweepInFlight = true
        defer { paperFigureImageSweepInFlight = false }
        do {
            guard try await storage.paperFigureImageSweepIsPending() else { return }
            let removed = await PaperFigureImageSweeper.sweep()
            guard !Task.isCancelled else { return }
            try await storage.completePaperFigureImageSweep(removedDirectoryCount: removed)
            if removed > 0 {
                logger.notice("Removed \(removed) stale figure image directory(ies)")
            }
        } catch {
            logger.error("Figure image sweep paused: \(error.localizedDescription)")
            do {
                try await storage.recordPaperFigureImageSweepFailure(
                    message: error.localizedDescription
                )
            } catch {
                logger.error("recordPaperFigureImageSweepFailure failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Build the figure index of every paper that has none, or one built under
    /// older rules, so a figure mention in any paper's text opens its figure
    /// (product owner, 2026-11-08: "make that the case for all figures in the
    /// library", "backfill that in our library of papers"). The structural
    /// read only: the PDF's caption lines, no model and no credits. One paper
    /// at a time, at the launch's utility priority; a paper finished is
    /// current and is not read again, so the sweep ends itself and resumes
    /// where a quit left it.
    func runDeferredPaperFigureIndexBackfill() async {
        guard !paperFigureIndexBackfillInFlight else { return }
        paperFigureIndexBackfillInFlight = true
        defer { paperFigureIndexBackfillInFlight = false }
        let ids: [String]
        do {
            ids = try await storage.papersNeedingFigureIndex()
        } catch {
            logger.error("Figure index backfill could not list papers: \(error.localizedDescription)")
            return
        }
        guard !ids.isEmpty else { return }
        var indexed = 0
        var failed = 0
        for id in ids {
            guard !Task.isCancelled else { break }
            do {
                _ = try await paperFigureIndexer.prepareStructure(sourceID: id)
                indexed += 1
            } catch {
                // The indexer files the failure against the paper; three and
                // the backfill leaves it alone.
                failed += 1
            }
            await Task.yield()
        }
        logger.notice("Figure index backfill read \(indexed) paper(s); \(failed) could not be read")
    }

    /// Write each stored Page's source web addresses into its source links,
    /// once per Mac, so a teammate whose library lacks a source the Page cites
    /// is sent to where it came from (`SourceLinkOrigin`; product owner,
    /// 2026-11-26). Pages saved from here on get them on every save; this is
    /// for the Pages saved before. Done once the pass finishes; a quit before
    /// that runs it again, and a Page already stamped is skipped.
    func runDeferredSourceLinkOriginStamp() async {
        let key = "sourceLinkOrigins.storedPagesStamped.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            let stamped = try await storage.stampSourceLinkOriginsInStoredPages()
            UserDefaults.standard.set(true, forKey: key)
            logger.notice("Source link addresses written into \(stamped) stored page(s)")
            if stamped > 0, let refreshed = try? await loadScopedArtifacts() { artifacts = refreshed }
        } catch {
            logger.error("Source link address pass failed: \(error.localizedDescription)")
        }
    }

    /// Drain canonical cleanup and prepare already-eligible Listen derivatives
    /// concurrently. The listenable candidate query excludes anything still in
    /// canonical cleanup, so the two bounded stages never race on one source.
    func runCanonicalContentCleanup() async {
        #if DEBUG
        // An explicit maintenance process owns the podcast queue directly;
        // suppress the ordinary Studio observer so it cannot duplicate paid
        // requests for the same first batch.
        if ProcessInfo.processInfo.arguments.contains("--run-podcast-cleanup") {
            return
        }
        #endif
        if !PaidSourceCleanupPolicy.runsPaidCleanup, !hasLoggedPaidCleanupSkip {
            hasLoggedPaidCleanupSkip = true
            logger.notice(
                """
                Dev build: paid source clean-up is off. New sources are published with their \
                raw text and historical clean-up rows stay queued. Launch with \
                \(PaidSourceCleanupPolicy.optInEnvironmentKey, privacy: .public)=1 to run it.
                """
            )
        }
        // A transient cleanup failure stored as a terminal source error is
        // re-staged before every event-driven drain so an update,
        // relaunch, activation, or remote change repairs the row automatically.
        await resumeSourcesAfterTransientCleanupFailures()
        // The one-time chrome refilter rides the same trigger points but is
        // independent of both: it rewrites reader documents and never touches
        // canonical text, so it cannot race the two content stages.
        Task(priority: .utility) { _ = await self.articleChromeRefilterService.drain() }
        // So does schema 144's registered-title check: catalog requests and a
        // title write, no model and no text.
        Task(priority: .utility) { await self.runRegisteredPaperTitleCheck() }
        // And schema 174's read of each paper's references: the PDF's text and free
        // catalog requests, no model, so it needs no spend control and no opt-in.
        Task(priority: .utility) { await self.runPaperReferenceLinking() }
        // And schema 148's transcript check: caption requests and a text
        // write, no model.
        Task(priority: .utility) { await self.runYouTubeTranscriptCheck() }
        // Ahead of the two content stages, and awaited rather than detached: an
        // episode still holding the part of itself that survived the retired
        // 50,000-character cap must be restored before the ad pass runs, or
        // that pass spends a model on text that is about to be replaced.
        let detruncationResult = await runPodcastTranscriptAudit()
        // Spend control: a bulk re-queue waits for the learner,
        // and past the daily background cap only a source the learner added
        // is still cleaned; the rest waits for the next local day.
        await refreshPendingBackgroundAIBulkJobs()
        let backgroundSpendAllowed = await backgroundAISpendAllowed()
        async let cleanupDrain = canonicalContentCleanupService.drain(
            backgroundSpendAllowed: backgroundSpendAllowed
        )
        async let podcastCleanupDrain = podcastTranscriptCleanupService.drain(
            backgroundSpendAllowed: backgroundSpendAllowed
        )
        async let listenableDrain = sourceListenableContentPreparationService.drain(
            backgroundSpendAllowed: backgroundSpendAllowed
        )
        let (result, podcastResult, listenableResult) = await (
            cleanupDrain,
            podcastCleanupDrain,
            listenableDrain
        )
        await refreshLoadedSourcesAfterDerivedWrites(
            Set(
                result.processedSourceIDs
                    + podcastResult.processedSourceIDs
                    + listenableResult.processedSourceIDs
            ),
            rewrittenText: Set(result.processedSourceIDs + podcastResult.processedSourceIDs)
        )
        if let error = result.errorMessage {
            logger.error("Source cleanup failed: \(error)")
        }

        if let error = podcastResult.errorMessage {
            logger.error("Podcast transcript clean-up failed: \(error)")
        }

        if let error = listenableResult.errorMessage {
            logger.error("Listenable-content preparation failed: \(error)")
        }

        let cleanupHasAnotherBatch = result.processedCount > 0
            && result.remainingCount > 0
        let podcastCleanupHasAnotherBatch = podcastResult.processedCount > 0
            && podcastResult.remainingCount > 0
        // Canonical cleanup enqueues Listen work after the concurrent Listen
        // drain has already selected its candidates. A completed cleanup batch
        // is therefore also a concrete next-work event for that second stage.
        let listenableHasAnotherBatch = listenableResult.remainingCount > 0
            && (listenableResult.processedCount > 0 || result.processedCount > 0)
        // The completeness audit settles a few episodes a batch; a batch that
        // settled any is the event for the next, until none is due (a failed
        // fetch waits for its retry time, so it never keeps this going).
        let auditHasAnotherBatch = detruncationResult.auditedCount > 0
            && detruncationResult.remainingCount > 0
        if result.processedCount > 0 || podcastResult.processedCount > 0 || listenableResult.processedCount > 0 {
            derivedSourceWorkRetryRound = 0
        }
        if cleanupHasAnotherBatch || podcastCleanupHasAnotherBatch || listenableHasAnotherBatch
            || auditHasAnotherBatch {
            derivedSourceWorkRetryTask?.cancel()
            // Batch completion is the next-work event. The existing observer
            // coalesces it before starting another bounded off-main batch.
            NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
        } else {
            let transientFailure = result.failedTransiently
                || podcastResult.failedTransiently
                || [result.errorMessage, podcastResult.errorMessage, listenableResult.errorMessage]
                    .compactMap { $0 }
                    .contains { AITransientErrorClassifier.isTransient(AIError.apiError($0)) }
            let hasRemainingWork = result.remainingCount > 0
                || podcastResult.remainingCount > 0
                || listenableResult.remainingCount > 0
            if transientFailure && hasRemainingWork {
                // A provider limit or timeout is a future-work event, not a
                // reason to strand the durable tail. One coalesced retry
                // resumes the drain without turning the feature into polling;
                // it backs off while nothing gets through, and never comes
                // sooner than the provider said it would take requests again.
                let serverWait = [result.retryAfterSeconds, podcastResult.retryAfterSeconds]
                    .compactMap { $0 }
                    .max()
                let delay = Self.derivedSourceWorkRetryDelay(
                    round: derivedSourceWorkRetryRound,
                    serverWait: serverWait
                )
                derivedSourceWorkRetryRound += 1
                logger.notice("Source cleanup waits \(Int(delay), privacy: .public)s before retrying (round \(self.derivedSourceWorkRetryRound, privacy: .public))")
                derivedSourceWorkRetryTask?.cancel()
                derivedSourceWorkRetryTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled, self != nil else { return }
                    NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
                }
            } else if let wait = result.nextRetryInSeconds {
                // A source waiting out its cleanup retry delay
                // (`CanonicalContentCleanupRetry`) is due then; nothing else
                // may ask for a drain before it is.
                logger.notice("Source cleanup's next retry is due in \(Int(wait), privacy: .public)s")
                derivedSourceWorkRetryTask?.cancel()
                derivedSourceWorkRetryTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(1, wait)))
                    guard !Task.isCancelled, self != nil else { return }
                    NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
                }
            }
        }
    }

    /// The podcast transcript completeness audit's next batch (schema 167),
    /// with every row it restored brought back to what storage holds.
    ///
    /// The loaded copy of a restored episode still holds the cut transcript,
    /// and `saveSource` writes a loaded podcast's `content` into
    /// `source_content` whole, so any later save of that row — a rename, a
    /// hide, a reading mark — would have written the cut text back over the
    /// restore. Clearing it sends every reader back to storage, as the
    /// clean-up stages do, and the word count is taken from storage for the
    /// same reason.
    @discardableResult
    func runPodcastTranscriptAudit() async -> PodcastTranscriptDetruncationDrainResult {
        let result = await podcastTranscriptDetruncationService.drain()
        guard !result.restoredSourceIDs.isEmpty else { return result }
        let restored = Set(result.restoredSourceIDs)
        await refreshLoadedSourcesAfterDerivedWrites(restored, rewrittenText: restored)
        logger.notice(
            """
            Restored \(result.restoredCount) podcast transcript(s) the retired cap had cut; \
            \(result.remainingCount) left to audit
            """
        )
        // The restored rows lost their full-text and embedding state.
        kickSourceEmbeddingIndexing()
        return result
    }

    /// Brings loaded rows a background stage rewrote in storage back in line
    /// with it: state, error, the paper hashes and Listen's readiness, and for
    /// `rewrittenText`, the text itself (cleared, so consumers read storage)
    /// and the word count beside it.
    func refreshLoadedSourcesAfterDerivedWrites(
        _ sourceIDs: Set<String>,
        rewrittenText: Set<String>
    ) async {
        guard !sourceIDs.isEmpty else { return }
        let refreshedSources = (await loggedRead("persisted sources") { try await storage.loadPersistedSources(ids: Array(sourceIDs)) }) ?? []
        let refreshedByID = Dictionary(refreshedSources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var updatedArticles = articles
        var didChange = false
        for index in updatedArticles.indices where sourceIDs.contains(updatedArticles[index].id) {
            let sourceID = updatedArticles[index].id
            if rewrittenText.contains(sourceID), updatedArticles[index].content != nil {
                // Force every ordinary consumer back through canonical storage;
                // a loaded article may still hold the text from before.
                updatedArticles[index].content = nil
                didChange = true
            }
            if let refreshed = refreshedByID[sourceID] {
                if rewrittenText.contains(sourceID),
                   updatedArticles[index].wordCount != refreshed.wordCount {
                    updatedArticles[index].wordCount = refreshed.wordCount
                    didChange = true
                }
                if updatedArticles[index].state != refreshed.state {
                    updatedArticles[index].state = refreshed.state
                    didChange = true
                }
                if updatedArticles[index].errorMessage != refreshed.errorMessage {
                    updatedArticles[index].errorMessage = refreshed.errorMessage
                    didChange = true
                }
                if updatedArticles[index].paperContentSHA256 != refreshed.paperContentSHA256 {
                    updatedArticles[index].paperContentSHA256 = refreshed.paperContentSHA256
                    didChange = true
                }
                if updatedArticles[index].paperListenableContentReady
                    != refreshed.paperListenableContentReady {
                    updatedArticles[index].paperListenableContentReady = refreshed.paperListenableContentReady
                    didChange = true
                }
            }
        }
        if didChange {
            // Assign once: mutating `articles[index]` invokes the array's
            // didSet, rebuilds sidebar indexes, and invalidates SwiftUI. A
            // cleanup batch would repeat that O(library) main-actor work
            // for every processed source.
            articles = updatedArticles
        }
    }

    /// How long the drain waits before retrying after a batch that got nothing
    /// done: a minute, doubling each round up to half an hour, and at least as
    /// long as the provider named (a daily free-model quota can name hours).
    nonisolated static func derivedSourceWorkRetryDelay(round: Int, serverWait: Double?) -> Double {
        let backoff = min(30 * 60, 60 * pow(2, Double(min(max(0, round), 10))))
        return max(backoff, serverWait ?? 0)
    }

}
