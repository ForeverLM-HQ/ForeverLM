// Source persistence tests: canonical cleanup, listenable content and reader anchors.

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

extension SourcePersistenceTests {
    @Test("Legacy ready articles enter the resumable canonical cleanup queue")
    func legacyArticleQueuesCanonicalCleanup() throws {
        let store = try makeInMemoryStore()
        var article = StudioArticle(
            url: "https://example.com/legacy-article",
            title: "Legacy Article",
            sourceType: .article
        )
        article.content = "Legacy Article\n\nUseful body\n\nWebsite footer"
        article.state = .ready
        try store.saveSource(article)

        #expect(try store.sourceReviewGuideCandidate(sourceID: article.id) == nil)
        try store.ensureSourceReviewGuidePreparation(sourceID: article.id)
        #expect(try store.sourceReviewGuideQueueCount() == 0)

        let candidate = try #require(try store.nextCanonicalContentCleanupCandidate())
        #expect(candidate.sourceID == article.id)
        #expect(candidate.sourceType == .article)
        #expect(candidate.raw == article.content)

        let clean = "Legacy Article\n\nUseful body"
        let prepared = PreparedPaperContent(
            raw: candidate.raw,
            clean: clean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: candidate.rawSHA256,
                cleanSHA256: PaperContentPreparationService.sha256(clean),
                preparedAt: Date()
            )
        )
        try store.applyCanonicalContentCleanup(candidate: candidate, prepared: prepared)

        #expect(try store.loadSourceContent(article.id) == clean)
        #expect(try store.loadArticleContentPreparation(article.id)?.raw == article.content)
        #expect(try store.canonicalContentCleanupQueueCount() == 0)
        // Once cleanup commits, the next review request can use the cleaned
        // article without ever exposing the legacy raw extraction.
        try store.ensureSourceReviewGuidePreparation(sourceID: article.id)
        let review = try #require(try store.sourceReviewGuideCandidate(sourceID: article.id))
        #expect(review.content == clean)
        #expect(!review.content.contains("Website footer"))
        #expect(try store.sourceReviewGuideQueueCount() == 1)
    }

    @Test("Transcript-backed sources can prepare a review from canonical content")
    func transcriptBackedSourceCanPrepareReviewGuide() throws {
        let store = try makeInMemoryStore()
        let transcript = "A complete transcript explaining the experiment and its result."
        var video = StudioArticle(
            url: "https://www.youtube.com/watch?v=reviewable",
            title: "Reviewable Video",
            sourceType: .video
        )
        video.content = transcript
        video.state = .ready
        try store.saveSource(video)

        try store.ensureSourceReviewGuidePreparation(sourceID: video.id)
        let review = try #require(try store.sourceReviewGuideCandidate(sourceID: video.id))
        #expect(review.sourceType == .video)
        #expect(review.title == video.title)
        #expect(review.content == transcript)
        #expect(review.sourceSHA256 == PaperContentPreparationService.sha256(transcript))
    }

    @Test("Canonical cleanup selects a distinct bounded batch for parallel preparation")
    func canonicalCleanupSelectsDistinctBatch() throws {
        let store = try makeInMemoryStore()
        for index in 1...5 {
            var article = StudioArticle(
                url: "https://example.com/cleanup-batch-\(index)",
                title: "Cleanup Batch \(index)",
                sourceType: .article
            )
            article.content = "Useful body \(index).\nWebsite footer."
            article.state = .ready
            try store.saveSource(article)
        }

        let candidates = try store.canonicalContentCleanupCandidates(limit: 4)
        #expect(candidates.count == 4)
        #expect(Set(candidates.map(\.sourceID)).count == 4)
        #expect(candidates.allSatisfy { $0.sourceType == .article })
        #expect(try store.canonicalContentCleanupQueueCount() == 5)
    }

    @Test("Canonical cleanup prioritizes the newest eligible sources")
    func canonicalCleanupPrioritizesNewestSources() throws {
        let store = try makeInMemoryStore()
        var older = StudioArticle(
            url: "https://example.com/older-cleanup",
            title: "Older Cleanup",
            sourceType: .article
        )
        older.content = "Older useful body."
        older.state = .ready
        older.dateAdded = Date(timeIntervalSinceReferenceDate: 100)
        try store.saveSource(older)

        var newer = StudioArticle(
            url: "https://example.com/newer-cleanup",
            title: "Newer Cleanup",
            sourceType: .article
        )
        newer.content = "Newer useful body."
        newer.state = .ready
        newer.dateAdded = Date(timeIntervalSinceReferenceDate: 200)
        try store.saveSource(newer)

        #expect(try store.nextCanonicalContentCleanupCandidate()?.sourceID == newer.id)
    }

    @Test("Transient article cleanup is durable pending work and promotes only after cleanup")
    func transientArticleCleanupRetriesDurably() throws {
        let store = try makeInMemoryStore()
        let raw = "Running head\nThe useful article body.\nPublisher footer"
        var article = StudioArticle(
            url: "https://example.com/transient-cleanup",
            title: "Transient Cleanup",
            sourceType: .article
        )
        article.stageArticleContentCleanup(raw: raw)
        article.state = .queued
        article.errorMessage = nil
        try store.saveSource(article)

        #expect(try store.loadSourceContent(article.id) == nil)
        let candidate = try #require(try store.nextCanonicalContentCleanupCandidate())
        #expect(candidate.sourceID == article.id)
        #expect(candidate.raw == raw)
        #expect(candidate.isPendingIngestion)

        let clean = "Transient Cleanup\n\nThe useful article body."
        let prepared = PreparedPaperContent(
            raw: raw,
            clean: clean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                cleanSHA256: PaperContentPreparationService.sha256(clean),
                preparedAt: Date()
            )
        )
        try store.applyCanonicalContentCleanup(candidate: candidate, prepared: prepared)

        let completed = try #require(try store.loadSourceForSync(article.id))
        #expect(completed.state == .ready)
        #expect(completed.errorMessage == nil)
        #expect(try store.loadSourceContent(article.id) == clean)
        #expect(try store.canonicalContentCleanupQueueCount() == 0)
    }

    @Test("Paid source clean-up runs in production and in an opted-in Dev launch only")
    func paidSourceCleanupPolicy() {
        #expect(PaidSourceCleanupPolicy.runsPaidCleanup(isDevelopment: false, environment: [:]))
        #expect(!PaidSourceCleanupPolicy.runsPaidCleanup(isDevelopment: true, environment: [:]))
        #expect(!PaidSourceCleanupPolicy.runsPaidCleanup(
            isDevelopment: true,
            environment: [PaidSourceCleanupPolicy.optInEnvironmentKey: "0"]
        ))
        #expect(PaidSourceCleanupPolicy.runsPaidCleanup(
            isDevelopment: true,
            environment: [PaidSourceCleanupPolicy.optInEnvironmentKey: "1"]
        ))
    }

    @Test("The pending-only candidate batch leaves historical re-clean rows behind")
    func pendingOnlyCandidatesSkipHistoricalRows() throws {
        let store = try makeInMemoryStore()
        var historical = StudioArticle(
            url: "https://example.com/historical-cleanup",
            title: "Historical Cleanup",
            sourceType: .article
        )
        historical.content = "Already readable body.\nWebsite footer."
        historical.state = .ready
        historical.dateAdded = Date(timeIntervalSinceReferenceDate: 200)
        try store.saveSource(historical)

        var pending = StudioArticle(
            url: "https://example.com/pending-cleanup",
            title: "Pending Cleanup",
            sourceType: .article
        )
        pending.stageArticleContentCleanup(raw: "Navigation\nA new article body.\nFooter")
        pending.state = .queued
        pending.dateAdded = Date(timeIntervalSinceReferenceDate: 100)
        try store.saveSource(pending)

        #expect(try store.canonicalContentCleanupCandidates(limit: 10).count == 2)
        let pendingOnly = try store.canonicalContentCleanupCandidates(
            limit: 10,
            pendingIngestionOnly: true
        )
        #expect(pendingOnly.map(\.sourceID) == [pending.id])
        #expect(pendingOnly.first?.isPendingIngestion == true)
    }

    @Test("Publishing without clean-up makes a queued article readable from its raw text")
    func publishingWithoutCleanupPromotesAQueuedArticle() throws {
        let store = try makeInMemoryStore()
        let raw = "Running head\nThe useful article body.\nPublisher footer"
        var article = StudioArticle(
            url: "https://example.com/dev-raw-publish",
            title: "Dev Raw Publish",
            sourceType: .article
        )
        article.stageArticleContentCleanup(raw: raw)
        article.state = .queued
        try store.saveSource(article)
        let candidate = try #require(try store.nextCanonicalContentCleanupCandidate())
        #expect(candidate.isPendingIngestion)

        try store.publishCanonicalContentWithoutCleanup(candidate: candidate)

        let published = try #require(try store.loadSourceForSync(article.id))
        #expect(published.state == .ready)
        #expect(published.errorMessage == nil)
        #expect(try store.loadSourceContent(article.id) == raw)
        #expect(try store.canonicalContentCleanupQueueCount() == 0)
        // Honest attribution: no model touched this text, and a later save still
        // sees a version below the current contract.
        let preparation = try #require(try store.loadArticleContentPreparation(article.id))
        #expect(preparation.metadata.cleanerVersion == PaperContentPreparationMetadata.deterministicVersion)
        #expect(preparation.metadata.cleanSHA256 == PaperContentPreparationService.sha256(raw))
    }

    @Test("Publishing without clean-up counts a queued paper as ingested")
    func publishingWithoutCleanupCompletesAPaper() throws {
        let store = try makeInMemoryStore()
        let raw = "## Abstract\nA complete paper body long enough to publish.\nReferences"
        var paper = StudioArticle(
            url: "https://example.com/dev-raw-paper.pdf",
            title: "Dev Raw Paper",
            sourceType: .paper
        )
        paper.stagePaperContentCleanup(raw: raw)
        // A queued paper is enqueued for clean-up only once its metadata stage
        // has attested it, as the ingestion pipeline does before this point.
        paper.author = "A. Author"
        paper.journal = "Journal of Tests"
        paper.publishedYear = "2026"
        let attested = paper.attestPaperMetadataExtractionAfterLLM()
        #expect(attested)
        paper.state = .queued
        try store.saveSource(paper)
        let candidate = try #require(try store.nextCanonicalContentCleanupCandidate())
        #expect(candidate.sourceType == .paper)
        #expect(candidate.isPendingIngestion)

        try store.publishCanonicalContentWithoutCleanup(candidate: candidate)

        let published = try #require(try store.loadSourceForSync(paper.id))
        #expect(published.state == .ready)
        // Honest attribution, as for an article: no model produced this text, so
        // the paper does not claim a completed clean-up and a later save re-queues it.
        #expect(!published.hasCompletedPaperContentCleanup)
        let preparation = try #require(try store.loadPaperContentPreparation(paper.id))
        #expect(preparation.metadata.cleanerVersion == PaperContentPreparationMetadata.deterministicVersion)
        #expect(try store.loadSourceContent(paper.id) == raw)
        #expect(try store.canonicalContentCleanupQueueCount() == 0)
    }

    @Test("Publishing without clean-up never touches a historical re-clean row")
    func publishingWithoutCleanupIgnoresHistoricalRows() throws {
        let store = try makeInMemoryStore()
        let clean = "Already readable body."
        var historical = StudioArticle(
            url: "https://example.com/historical-untouched",
            title: "Historical Untouched",
            sourceType: .article
        )
        historical.content = clean
        historical.state = .ready
        try store.saveSource(historical)
        let candidate = try #require(try store.nextCanonicalContentCleanupCandidate())
        #expect(!candidate.isPendingIngestion)

        try store.publishCanonicalContentWithoutCleanup(candidate: candidate)

        #expect(try store.loadSourceContent(historical.id) == clean)
        #expect(try store.canonicalContentCleanupQueueCount() == 1)
        #expect(try store.loadArticleContentPreparation(historical.id) == nil)
    }

    @Test("A drain that may not spend a model publishes pending sources raw and leaves history queued")
    func unpaidDrainPublishesPendingAndKeepsHistory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-unpaid-drain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)

        var historical = StudioArticle(
            url: "https://example.com/unpaid-historical",
            title: "Unpaid Historical",
            sourceType: .article
        )
        historical.content = "Readable body.\nWebsite footer."
        historical.state = .ready
        historical.dateAdded = Date(timeIntervalSinceReferenceDate: 200)
        try await storage.saveSource(historical)

        let raw = "Navigation\nA new article body.\nFooter"
        var pending = StudioArticle(
            url: "https://example.com/unpaid-pending",
            title: "Unpaid Pending",
            sourceType: .article
        )
        pending.stageArticleContentCleanup(raw: raw)
        pending.state = .queued
        pending.dateAdded = Date(timeIntervalSinceReferenceDate: 100)
        try await storage.saveSource(pending)
        #expect(try await storage.canonicalContentCleanupQueueCount() == 2)

        let service = CanonicalContentCleanupService(
            storage: storage,
            aiService: AIService(),
            runsPaidCleanup: false
        )
        let result = await service.drain()

        #expect(result.errorMessage == nil)
        #expect(result.processedSourceIDs == [pending.id])
        #expect(result.remainingCount == 1)
        let published = try #require(try await storage.loadSourceWithoutContent(pending.id))
        #expect(published.state == .ready)
        #expect(try await storage.loadSourceContent(pending.id) == raw)
        let remaining = try await storage.canonicalContentCleanupCandidates(limit: 10)
        #expect(remaining.map(\.sourceID) == [historical.id])
        // The Listen derivative is paid too, so the raw publish queues none.
        #expect(try await storage.sourceListenableContentQueueCount() == 0)
    }

    @Test("Permanent pending cleanup failure becomes an explicit source error")
    func permanentPendingCleanupFailureIsVisible() throws {
        let store = try makeInMemoryStore()
        var article = StudioArticle(
            url: "https://example.com/permanent-cleanup",
            title: "Permanent Cleanup",
            sourceType: .article
        )
        article.stageArticleContentCleanup(raw: "Useful article body")
        article.state = .queued
        try store.saveSource(article)

        let candidate = try #require(try store.nextCanonicalContentCleanupCandidate())
        try store.failPendingCanonicalContentCleanup(
            candidate: candidate,
            message: "Source Content Cleanup is not configured."
        )

        let failed = try #require(try store.loadSourceForSync(article.id))
        #expect(failed.state == .error)
        #expect(failed.errorMessage?.contains("not configured") == true)
        #expect(try store.canonicalContentCleanupQueueCount() == 0)
    }

    @Test("Completed canonical cleanup clears a stale timeout without another AI pass")
    func completedCleanupClearsStaleTimeout() throws {
        let store = try makeInMemoryStore()
        let raw = "Navigation\nA complete article body.\nPublisher footer"
        let clean = "A Return to the Beginning\n\nA complete article body."
        var article = StudioArticle(
            url: "https://example.com/already-cleaned",
            title: "A Return to the Beginning",
            sourceType: .article
        )
        article.installPreparedArticleContent(
            raw: raw,
            clean: clean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                cleanSHA256: PaperContentPreparationService.sha256(clean),
                preparedAt: Date()
            )
        )
        article.state = .ready
        article.errorMessage =
            "Article ingestion failed during Source Content Cleanup: The request timed out."
        try store.saveSource(article)

        #expect(try store.clearCompletedCanonicalContentCleanupFailure(sourceID: article.id))
        let repaired = try #require(try store.loadSourceForSync(article.id))
        #expect(repaired.state == .ready)
        #expect(repaired.errorMessage == nil)
        #expect(try store.loadSourceContent(article.id) == clean)
        #expect(try !store.clearCompletedCanonicalContentCleanupFailure(sourceID: article.id))
    }

    @Test("Canonical cleanup prunes historical work after a source is archived")
    func canonicalCleanupPrunesArchivedQueueRows() throws {
        let store = try makeInMemoryStore()
        var article = StudioArticle(
            url: "https://example.com/stale-archived-cleanup",
            title: "Stale Archived Cleanup",
            sourceType: .article
        )
        article.content = "Useful body followed by publisher noise."
        article.state = .ready
        try store.saveSource(article)
        #expect(try store.canonicalContentCleanupQueueCount() == 1)

        // Reproduce an old/synced status-only archive that bypassed the modern
        // archive transaction and therefore left its local durable work behind.
        try store.execForTesting("UPDATE sources SET status = 'archived' WHERE id = '\(article.id)'")

        #expect(try store.pruneIneligibleCanonicalContentCleanupQueue() == 1)
        #expect(try store.canonicalContentCleanupQueueCount() == 0)
    }

    @Test("Cleanup failures never retire source text by attempt count")
    func canonicalCleanupFailuresRemainRetriable() throws {
        let store = try makeInMemoryStore()
        var article = StudioArticle(
            url: "https://example.com/paywalled-post",
            title: "Paywalled Post",
            sourceType: .article
        )
        article.content = "Paywalled Post\n\nJoin to unlock\n\nBecome a member"
        article.state = .ready
        try store.saveSource(article)

        let candidate = try #require(try store.nextCanonicalContentCleanupCandidate())
        #expect(candidate.sourceID == article.id)
        try store.recordCanonicalContentCleanupFailure(
            sourceID: article.id,
            message: "Provider unavailable",
            consumesAttempt: false
        )
        #expect(try store.nextCanonicalContentCleanupCandidate()?.sourceID == article.id)
        #expect(try store.canonicalContentCleanupQueueCount() == 1)

        // Re-saving metadata leaves the same text to fail the same way.
        article.title = "Paywalled Post (renamed)"
        try store.saveSource(article)
        #expect(try store.nextCanonicalContentCleanupCandidate()?.sourceID == article.id)

        // Re-extracted text is genuinely new work, so it earns a fresh budget.
        article.content = "Paywalled Post\n\nThe full essay finally extracted."
        try store.saveSource(article)
        let revived = try #require(try store.nextCanonicalContentCleanupCandidate())
        #expect(revived.sourceID == article.id)
    }

    @Test("A failed cleanup waits out its retry delay, and its attempts run out")
    func canonicalCleanupRetriesAreBounded() throws {
        let store = try makeInMemoryStore()
        var article = StudioArticle(
            url: "https://example.com/rate-limited-paper",
            title: "Rate Limited Paper",
            sourceType: .article
        )
        article.content = "Rate Limited Paper\n\nA body the free model never finishes."
        article.state = .ready
        try store.saveSource(article)

        // A transient round (a 429 from the backup) spends an attempt too.
        let before = Date()
        #expect(try store.recordCanonicalContentCleanupFailure(
            sourceID: article.id,
            message: "Rate limited (429)"
        ) == 1)
        #expect(try store.canonicalContentCleanupCandidates(limit: 10).isEmpty)
        let due = try #require(try store.nextCanonicalContentCleanupRetryDate())
        #expect(abs(due.timeIntervalSince(before) - CanonicalContentCleanupRetry.baseDelay) < 60)
        #expect(try store.canonicalContentCleanupQueueCount() == 1)
        #expect(try store.canonicalContentCleanupCandidates(
            limit: 10,
            now: due.addingTimeInterval(1)
        ).map(\.sourceID) == [article.id])

        var attempts = 1
        while attempts < CanonicalContentCleanupRetry.maximumAttempts {
            attempts = try store.recordCanonicalContentCleanupFailure(
                sourceID: article.id,
                message: "Rate limited (429)"
            )
        }
        // Spent: never picked again, not counted, no retry to wake for.
        #expect(try store.canonicalContentCleanupCandidates(
            limit: 10,
            now: Date().addingTimeInterval(30 * 24 * 60 * 60)
        ).isEmpty)
        #expect(try store.canonicalContentCleanupQueueCount() == 0)
        #expect(try store.nextCanonicalContentCleanupRetryDate() == nil)

        // New text is new work with a fresh budget.
        article.content = "Rate Limited Paper\n\nThe full text, extracted again."
        try store.saveSource(article)
        #expect(try store.nextCanonicalContentCleanupCandidate()?.sourceID == article.id)
    }

    @Test("Cleanup retry delays double from 15 minutes to 12 hours over about a day")
    func canonicalCleanupRetryDelays() {
        let retry = CanonicalContentCleanupRetry.self
        #expect(retry.delay(afterAttempts: 0) == 0)
        #expect(retry.delay(afterAttempts: 1) == 15 * 60)
        #expect(retry.delay(afterAttempts: 2) == 30 * 60)
        #expect(retry.delay(afterAttempts: 7) == 12 * 60 * 60)
        #expect(retry.delay(afterAttempts: 60) == 12 * 60 * 60)
        let span = (1..<retry.maximumAttempts).map { retry.delay(afterAttempts: $0) }.reduce(0, +)
        #expect(span > 24 * 60 * 60 && span < 30 * 60 * 60)

        // A parked source is not re-staged as transient, though its last
        // error was a 429.
        let parked = StudioArticle.paperContentCleanupFailureMessage(
            retry.exhaustedMessage(attempts: 8, lastError: "Rate limited (429)")
        )
        #expect(!PaperContentPreparationService.isTransientIngestionFailure(parked))
        #expect(PaperContentPreparationService.isTransientIngestionFailure(
            StudioArticle.paperContentCleanupFailureMessage("Rate limited (429)")
        ))
    }

    @Test("Canonical cleanup commits before listenable-content preparation is queued, for an automatic-audio kind")
    func canonicalCleanupQueuesSecondListenableSave() throws {
        let store = try makeInMemoryStore()
        store.automaticAudioSourceTypes = { ["article"] }
        var article = StudioArticle(
            url: "https://example.com/two-stage-source",
            title: "Two Stage Source",
            sourceType: .article
        )
        article.content = "Publisher navigation\n\nThe canonical body remains."
        article.state = .ready
        try store.saveSource(article)

        #expect(try store.canonicalContentCleanupQueueCount() == 1)
        #expect(try store.sourceListenableContentQueueCount() == 0)

        let cleanup = try #require(try store.nextCanonicalContentCleanupCandidate())
        try Self.commitCleanup(cleanup, clean: "Two Stage Source\n\nThe canonical body remains.", in: store)

        #expect(try store.canonicalContentCleanupQueueCount() == 0)
        #expect(try store.nextSourceListenableContentCandidate()?.sourceID == article.id)
    }

    @Test("A clean-up commit queues no paid Listen preparation unless automatic audio covers the kind")
    func cleanupCommitDoesNotQueueListenPreparation() throws {
        let store = try makeInMemoryStore()
        // Automatic audio covers papers only: the article must not be queued.
        store.automaticAudioSourceTypes = { ["paper"] }
        var article = StudioArticle(
            url: "https://example.com/lazy-listen-source",
            title: "Lazy Listen Source",
            sourceType: .article
        )
        article.content = "Publisher navigation\n\nThe body nobody has listened to."
        article.state = .ready
        try store.saveSource(article)

        let cleanup = try #require(try store.nextCanonicalContentCleanupCandidate())
        let clean = "Lazy Listen Source\n\nThe body nobody has listened to."
        try Self.commitCleanup(cleanup, clean: clean, in: store)
        #expect(try store.sourceListenableContentQueueCount() == 0)
        #expect(try store.nextSourceListenableContentCandidate() == nil)

        // Pressing Listen prepares it then; the narration is bound to the
        // cleaned text like any other.
        let listen = SourceListenableContentCandidate(
            sourceID: article.id,
            title: article.title,
            sourceType: .article,
            canonicalText: clean,
            sourceSHA256: PaperContentPreparationService.sha256(clean)
        )
        try store.applySourceListenableContent(
            candidate: listen,
            text: "Lazy Listen Source. The body nobody has listened to.",
            preparationSignature: nil
        )
        #expect(try store.loadSourceListenableContent(article.id) != nil)

        // A later change to the text retires that narration instead of
        // re-buying it.
        try store.execForTesting("UPDATE source_content SET content = 'Changed elsewhere.' WHERE source_id = '\(article.id)'")
        try store.enqueueSourceListenableContentPreparation(
            sourceID: article.id,
            content: "Changed elsewhere."
        )
        #expect(try store.loadSourceListenableContent(article.id) == nil)
        #expect(try store.sourceListenableContentQueueCount() == 0)
    }

    @Test("An import queues no paid Listen preparation until automatic audio asks for it")
    func importDoesNotQueueListenPreparation() throws {
        let store = try makeInMemoryStore()
        store.automaticAudioSourceTypes = { [] }
        var paper = StudioArticle(
            url: "https://example.com/read-not-heard",
            title: "Read Not Heard",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Journal",
            publishedYear: "2026"
        )
        installPreparedPaperText("Read Not Heard\n\nA body nobody listens to.", on: &paper)
        let completedMetadata = paper.completePaperMetadataExtractionAfterLLM()
        #expect(completedMetadata)
        paper.state = .ready
        try store.saveSource(paper)
        #expect(try store.sourceListenableContentQueueCount() == 0)

        // Automatic audio switched on afterwards finds the paper unprepared
        // and queues it from the stored text.
        store.automaticAudioSourceTypes = { ["paper"] }
        #expect(try store.queueSourceListenableContentPreparation(sourceID: paper.id))
        let candidate = try #require(try store.nextSourceListenableContentCandidate())
        #expect(candidate.sourceID == paper.id)
        #expect(candidate.canonicalText == "Read Not Heard\n\nA body nobody listens to.")
    }

    private static func commitCleanup(
        _ cleanup: CanonicalContentCleanupCandidate,
        clean: String,
        in store: KnowledgeStore
    ) throws {
        try store.applyCanonicalContentCleanup(
            candidate: cleanup,
            prepared: PreparedPaperContent(
                raw: cleanup.raw,
                clean: clean,
                metadata: PaperContentPreparationMetadata(
                    cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                    rawSHA256: cleanup.rawSHA256,
                    cleanSHA256: PaperContentPreparationService.sha256(clean),
                    preparedAt: Date()
                )
            )
        )
    }

    @Test("Listenable content is source-bound, persisted, and invalidated by new canonical text")
    func listenableContentLifecycle() throws {
        let store = try makeInMemoryStore()
        // Listen is queued ahead of a listener only for automatic-audio kinds.
        store.automaticAudioSourceTypes = { ["paper"] }
        var paper = StudioArticle(
            url: "https://example.com/source-bound-paper",
            title: "Source-Bound Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Journal",
            publishedYear: "2026"
        )
        installPreparedPaperText("Source-Bound Paper\n\nFirst canonical body.", on: &paper)
        let completedInitialMetadata = paper.completePaperMetadataExtractionAfterLLM()
        #expect(completedInitialMetadata)
        paper.state = .ready
        try store.saveSource(paper)

        let candidate = try #require(try store.nextSourceListenableContentCandidate())
        try store.applySourceListenableContent(
            candidate: candidate,
            text: "Source-Bound Paper. First canonical body.",
            preparationSignature: "luna-route"
        )
        let stored = try #require(try store.loadSourceListenableContent(paper.id))
        #expect(stored.text == "Source-Bound Paper. First canonical body.")
        #expect(stored.metadata.sourceSHA256 == candidate.sourceSHA256)
        #expect(stored.metadata.characterCount == stored.text.count)
        #expect(
            try store.sourceListenableContentSummaries(for: [paper.id])[paper.id]
                == SourceListenableContentSummary(
                    characterCount: stored.text.count,
                    preparationSignature: "luna-route"
                )
        )
        #expect(try store.sourceListenableContentQueueCount() == 0)

        installPreparedPaperText("Source-Bound Paper\n\nSecond canonical body.", on: &paper)
        let completedReplacementMetadata = paper.completePaperMetadataExtractionAfterLLM()
        #expect(completedReplacementMetadata)
        try store.saveSource(paper)
        #expect(try store.loadSourceListenableContent(paper.id) == nil)
        let replacement = try #require(try store.nextSourceListenableContentCandidate())
        #expect(replacement.sourceSHA256 != candidate.sourceSHA256)

        do {
            try store.applySourceListenableContent(
                candidate: candidate,
                text: "Stale narration must not be saved.",
                preparationSignature: "luna-route"
            )
            Issue.record("Expected stale listenable content to be rejected")
        } catch KnowledgeStoreError.sourceContentChanged {
            // The reader distinguishes this expected race from real preparation
            // failures so it can refresh the canonical snapshot once.
        }
        #expect(try store.loadSourceListenableContent(paper.id) == nil)
        #expect(try store.nextSourceListenableContentCandidate()?.sourceSHA256 == replacement.sourceSHA256)
    }

    @Test("An unchanged cleaned paper still replaces a stale narration contract")
    func unchangedPaperRequeuesStaleNarrationContract() throws {
        let store = try makeInMemoryStore()
        // Listen is queued ahead of a listener only for automatic-audio kinds.
        store.automaticAudioSourceTypes = { ["paper"] }
        var paper = StudioArticle(
            url: "https://example.com/unchanged-paper-contract",
            title: "Unchanged Paper Contract",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Journal",
            publishedYear: "2026"
        )
        installPreparedPaperText(
            "Unchanged Paper Contract\n\nThe canonical body needs no textual edits.",
            on: &paper
        )
        let completedMetadata = paper.completePaperMetadataExtractionAfterLLM()
        #expect(completedMetadata)
        paper.state = .ready
        try store.saveSource(paper)

        let original = try #require(try store.nextSourceListenableContentCandidate())
        try store.applySourceListenableContent(
            candidate: original,
            text: original.canonicalText,
            preparationSignature: "pre-v4-paper-contract"
        )
        #expect(try store.sourceListenableContentQueueCount() == 0)

        try store.enqueueSourceListenableContentPreparation(
            sourceID: paper.id,
            content: original.canonicalText
        )

        #expect(try store.loadSourceListenableContent(paper.id) == nil)
        #expect(try store.nextSourceListenableContentCandidate()?.sourceID == paper.id)
    }

    @Test("Listenable preparation selects a distinct bounded batch")
    func listenableContentBatchSelection() throws {
        let store = try makeInMemoryStore()
        // Listen is queued ahead of a listener only for automatic-audio kinds.
        store.automaticAudioSourceTypes = { ["paper"] }
        var sourceIDs: [String] = []
        for index in 0..<3 {
            var paper = StudioArticle(
                url: "https://example.com/batched-paper-\(index)",
                title: "Batched Paper \(index)",
                sourceType: .paper,
                author: "Ada Researcher",
                journal: "Journal",
                publishedYear: "2026"
            )
            paper.dateAdded = Date(timeIntervalSinceReferenceDate: Double(index))
            installPreparedPaperText(
                "Batched Paper \(index)\n\nCanonical body \(index).",
                on: &paper
            )
            let completedMetadata = paper.completePaperMetadataExtractionAfterLLM()
            #expect(completedMetadata)
            paper.state = .ready
            try store.saveSource(paper)
            sourceIDs.append(paper.id)
        }

        let batch = try store.sourceListenableContentCandidates(limit: 2)
        #expect(batch.count == 2)
        #expect(Set(batch.map(\.sourceID)).count == 2)
        #expect(batch.map(\.sourceID) == Array(sourceIDs.reversed().prefix(2)))
        #expect(try store.nextSourceListenableContentCandidate()?.sourceID == batch.first?.sourceID)
        #expect(try store.sourceListenableContentCandidates(limit: 0).isEmpty)
    }

    @Test("Books do not queue generated listenable content")
    func booksDoNotQueueListenableContent() throws {
        let store = try makeInMemoryStore()
        var book = StudioArticle(
            url: "Books/chapter.xhtml",
            title: "A Chapter",
            sourceType: .book
        )
        book.content = "A Chapter\n\nAlready suitable for direct narration."
        book.state = .ready
        try store.saveSource(book)

        #expect(try store.sourceListenableContentQueueCount() == 0)
        #expect(try store.nextSourceListenableContentCandidate() == nil)
    }

    @Test("Reader notes persist quote anchors, edits, colors, and deletion")
    func readerNotePersistenceRoundTrip() throws {
        let store = try makeInMemoryStore()
        var article = makeArticle(url: "https://example.com/reader-note", title: "Reader Note")
        article.content = "Before the important result after the important result."
        article.state = .ready
        try store.saveSource(article)

        let quote = "important result"
        let selected = article.content!.range(of: quote)!
        let anchor = ReaderTextAnchor(text: article.content!, range: selected)
        let createdAt = Date(timeIntervalSince1970: 1_000)
        var highlight = SourceHighlight(
            id: "hl-round-trip",
            sourceID: article.id,
            quote: quote,
            note: "First note",
            color: .yellow,
            anchor: anchor,
            pdfAnchor: ReaderPDFAnchor(
                pageIndex: 2,
                rects: [CGRect(x: 10, y: 20, width: 80, height: 12)]
            ),
            createdAt: createdAt,
            updatedAt: createdAt
        )
        try store.saveSourceHighlight(highlight)

        var loaded = try #require(store.sourceHighlights(sourceID: article.id).first)
        #expect(loaded == highlight)
        #expect(loaded.anchor.resolve(in: article.content!) == selected)

        highlight.note = "Revised note"
        highlight.color = .blue
        highlight.updatedAt = Date(timeIntervalSince1970: 2_000)
        try store.saveSourceHighlight(highlight)
        loaded = try #require(store.sourceHighlights(sourceID: article.id).first)
        #expect(loaded.note == "Revised note")
        #expect(loaded.color == .blue)
        #expect(loaded.createdAt == createdAt)

        try store.deleteSourceHighlight(id: highlight.id)
        #expect(try store.sourceHighlights(sourceID: article.id).isEmpty)
    }

    @Test("Reader text anchors use context to resolve repeated passages after reflow")
    func readerTextAnchorResolvesRepeatedPassage() throws {
        let original = "Alpha lead important result alpha tail. Beta lead important result beta tail."
        let second = try #require(original.range(of: "important result", options: [], range: original.range(of: "Beta lead")!.lowerBound..<original.endIndex))
        let anchor = ReaderTextAnchor(text: original, range: second)
        let reflowed = "Alpha lead\nimportant   result alpha tail. Beta lead\nimportant result beta tail."
        let resolved = try #require(anchor.resolve(in: reflowed))
        #expect(String(reflowed[resolved]) == "important result")
        #expect(reflowed[..<resolved.lowerBound].contains("Beta lead"))
    }
}
