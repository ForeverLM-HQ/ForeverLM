// Resolving missing paper PDFs and the automatic fetch and metadata queues.

import Foundation
import CryptoKit
import Observation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif
import SwiftUI
import AppKit
import SQLite3
import WebKit
import Darwin

extension StudioViewModel {

    /// Retry a failed Source Content Cleanup from the paper row. The row moves
    /// back to Processing immediately, while the durable retry continues in the
    /// view model even if that row scrolls offscreen or changes sections.
    @discardableResult
    func fixPaperContentCleanup(for articleId: String) -> Task<Void, Never>? {
        guard !processingPaperIDs.contains(articleId),
              let index = articles.firstIndex(where: { $0.id == articleId }),
              articles[index].isPaperContentCleanupFailure else { return nil }

        let previous = articles[index]
        articles[index].prepareForPaperMetadataExtraction()
        let queued = articles[index]
        pendingPaperProcessingIds.insert(articleId)

        return Task {
            defer { pendingPaperProcessingIds.remove(articleId) }

            guard !Task.isCancelled else {
                if let currentIndex = articles.firstIndex(where: { $0.id == articleId }),
                   articles[currentIndex].state == .queued {
                    articles[currentIndex] = previous
                }
                return
            }

            guard await persistSource(
                queued,
                context: "Restart paper content cleanup",
                showErrorToast: true
            ) else {
                if let currentIndex = articles.firstIndex(where: { $0.id == articleId }),
                   articles[currentIndex].state == .queued {
                    articles[currentIndex] = previous
                }
                return
            }

            let outcome = await resolveMissingPaperPDF(
                for: articleId,
                browserConfig: KeychainService.resolveConfig(for: .paperBrowserAgent)
            )
            if let current = articles.first(where: { $0.id == articleId }),
               current.hasFinishedPaperIngestion {
                showToast(
                    current.isPaperReadyForListenPreparation
                        ? "Paper cleanup fixed"
                        : "Paper metadata saved; its text is being cleaned up in the background"
                )
                return
            }

            // Recovery can restore canonical text but still stop at the required
            // metadata step (for example when credits run out). Never let that
            // incomplete paper fall into the ordinary ready list.
            if let currentIndex = articles.firstIndex(where: { $0.id == articleId }),
               articles[currentIndex].state != .error {
                let message = "Paper ingestion still needs attention: \(stalledPaperIngestionError(for: articleId).localizedDescription)"
                articles[currentIndex].failPaperIngestionMetadata(message)
                PaperIngestionDiagnostics.recordFailure(
                    sourceID: articleId,
                    title: articles[currentIndex].title,
                    message: message
                )
                _ = await persistSource(
                    articles[currentIndex],
                    context: "Save incomplete paper cleanup retry",
                    showErrorToast: false
                )
            }

            switch outcome {
            case .downloaded, .textRecovered:
                showToast("Paper text recovered, but metadata still needs attention")
            case .paywalled:
                showToast("Paper cleanup still needs attention because the source is paywalled")
            case .suspectedPaywall:
                showToast("Paper cleanup still needs attention; the page looks paywalled — Mark as Paywalled is on the row")
            case .reclassifiedAsArticle:
                showToast("This source is an article, not a paper; it moved to Articles")
            case .failed, .skippedNoBrowserConfig:
                showToast("Paper cleanup still needs attention")
            }
        }
    }

    /// Run the full PDF-resolution pipeline for a single paper needing attention:
    /// direct download, then open-access alternative, then (macOS) the AI browser
    /// agent. Shared by the bulk "papers needing attention" pass and the one-shot
    /// automatic attempt for newly added papers. Stays quiet (no toasts) so callers
    /// own user-facing messaging.
    ///
    /// Every PDF it finds is held to `identity`; a batch passes one per paper
    /// so its summary can count the files turned away as other papers.
    func resolveMissingPaperPDF(
        for articleId: String,
        browserConfig: AITaskConfig?,
        recheckingPaywall: Bool = false,
        identity: PaperPDFIdentityGate? = nil,
        onReachingBrowserStep: (() -> Void)? = nil
    ) async -> MissingPaperPDFOutcome {
        resolvingPaperPDFIds.insert(articleId)
        defer { resolvingPaperPDFIds.remove(articleId) }

        // A page the URL already proves is not a paper never had a PDF to
        // find. Settle it here, before any download or browser run, so every
        // library that imported the same link reaches the same state.
        if let article = articles.first(where: { $0.id == articleId }),
           PaperService.isNatureNewsURL(article.url),
           await reclassifyPaperAsArticle(
               articleId: articleId,
               reason: "Nature news article id; the journal's journalism has no paper PDF."
           ) {
            return .reclassifiedAsArticle
        }

        // A terminal cleanup/metadata failure can still have a perfectly good
        // PDF attached. Retrying that attention row must resume ingestion from
        // the saved PDF/raw text, not download the same document again.
        if paperHasLocalPDF(articleId) {
            let recoveredText = await recoverReadablePaperText(for: articleId)
            var metadataComplete = articles.first(where: { $0.id == articleId })?.hasFinishedPaperIngestion == true
            if recoveredText && !metadataComplete {
                metadataComplete = await enrichPaperMetadataAfterPDFAttachment(
                    articleId: articleId,
                    userInitiated: false,
                    forceAIForMissingAuthor: true
                )
            }
            return recoveredText
                ? .textRecovered(metadataComplete: metadataComplete)
                : .failed
        }

        // Every candidate below — open-access copies and the paper's own link
        // alike — is held to the paper as it is now, before any copy's address
        // is swapped onto the row.
        let identity = identity ?? articles.first(where: { $0.id == articleId }).map { PaperPDFIdentityGate(article: $0) }

        // A paper that was closed last month may now have a repository copy or
        // an expired embargo. During a recheck, query the structured OA sources
        // first; this is faster, cheaper, and more reliable than browser driving.
        if recheckingPaywall {
            _ = await adoptOpenAccessAlternativeIfAvailable(
                for: articleId,
                userInitiated: false,
                markFailure: false,
                forceMetadataExtractionForMissingAuthor: true,
                identity: identity
            )
            if paperHasLocalPDF(articleId) {
                let metadataComplete = articles.first(where: { $0.id == articleId })?.hasFinishedPaperIngestion == true
                return .downloaded(metadataComplete: metadataComplete)
            }
        }

        let result = await downloadPaperPDF(
            for: articleId,
            userInitiated: false,
            forceMetadataExtractionForMissingAuthor: true,
            identity: identity
        )
        if result.success { return .downloaded(metadataComplete: result.metadataComplete == true) }
        if paperHasLocalPDF(articleId) {
            return .downloaded(metadataComplete: false)
        }

        if !recheckingPaywall {
            _ = await adoptOpenAccessAlternativeIfAvailable(
                for: articleId,
                userInitiated: false,
                markFailure: false,
                forceMetadataExtractionForMissingAuthor: true,
                identity: identity
            )
        }

        if paperHasLocalPDF(articleId) {
            let metadataComplete = articles.first(where: { $0.id == articleId })?.hasFinishedPaperIngestion == true
            return .downloaded(metadataComplete: metadataComplete)
        }
        if paperIsMarkedPaywalled(articleId), !recheckingPaywall {
            if await recoverReadablePaperText(for: articleId) {
                let complete = articles.first(where: { $0.id == articleId })?.hasFinishedPaperIngestion == true
                return .textRecovered(metadataComplete: complete)
            }
            return .paywalled
        }

        guard let browserConfig else {
            if await recoverReadablePaperText(for: articleId) {
                let complete = articles.first(where: { $0.id == articleId })?.hasFinishedPaperIngestion == true
                return .textRecovered(metadataComplete: complete)
            }
            return .skippedNoBrowserConfig
        }
        onReachingBrowserStep?()
        let browserResult = await attemptPaperPDFDownloadWithAIBrowser(
            for: articleId,
            config: browserConfig,
            showPaywallToast: false,
            identity: identity
        )
        switch browserResult {
        case .downloaded:
            let metadataComplete = articles.first(where: { $0.id == articleId })?.hasFinishedPaperIngestion == true
            return .downloaded(metadataComplete: metadataComplete)
        case .paywalled:
            if await recoverReadablePaperText(for: articleId) {
                let complete = articles.first(where: { $0.id == articleId })?.hasFinishedPaperIngestion == true
                return .textRecovered(metadataComplete: complete)
            }
            return .paywalled
        case .suspectedPaywall:
            if await recoverReadablePaperText(for: articleId) {
                let complete = articles.first(where: { $0.id == articleId })?.hasFinishedPaperIngestion == true
                return .textRecovered(metadataComplete: complete)
            }
            return .suspectedPaywall
        case .notAPaper:
            return .reclassifiedAsArticle
        case .cancelled:
            if paperHasLocalPDF(articleId) {
                let complete = articles.first(where: { $0.id == articleId })?.hasFinishedPaperIngestion == true
                return .downloaded(metadataComplete: complete)
            }
            return .failed
        case .failed:
            if await recoverReadablePaperText(for: articleId) {
                let complete = articles.first(where: { $0.id == articleId })?.hasFinishedPaperIngestion == true
                return .textRecovered(metadataComplete: complete)
            }
            return .failed
        }
    }

    /// Recover a paper's text from a preserved extraction or its saved PDF,
    /// through the same cleanup/metadata gates so CloudKit receives the
    /// canonical `sourceContentAsset` CarPlay uses.
    ///
    /// A paper is a PDF. When every PDF route is blocked this leaves the row
    /// asking for the file: the publisher's page is never read as the paper on
    /// the app's own initiative. Until build 70 it was, and the abstract, the
    /// figure titles and the Extended Data legends of a paper the learner had
    /// no access to were stored as the paper. The one route from a page to a
    /// paper is the reader's **Save Paper from Page**, which the learner asks
    /// for with the page in front of them, and which prints that page to the
    /// PDF as well.
    private func recoverReadablePaperText(for articleId: String) async -> Bool {
        if let stored = await storage.loadSourceContent(articleId),
           !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Text that is the publisher's preview rather than the paper is not
            // "recovered"; it is dropped here so the reader sees a paper without
            // text again, and shows the publisher's page.
            if !(await discardStoredPublisherWallTextIfNeeded(for: articleId, stored: stored)) {
                return true
            }
        }
        guard let article = articles.first(where: { $0.id == articleId }),
              article.sourceType == .paper else { return false }

        let raw: String
        if let preparedRaw = await storage.loadRawPaperContent(articleId),
           !preparedRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            raw = preparedRaw
        } else if article.resolvedPDFPath != nil {
            raw = await Self.fullPaperTextOffMain(for: article)
        } else {
            logger.info("Paper \(articleId) has no PDF and no preserved extraction; the row keeps asking for the PDF")
            return false
        }
        return await installRecoveredPaperText(for: articleId, raw: raw)
    }

    /// Builds before 70 could store a publisher's preview — the abstract, one-line
    /// figure titles and the Extended Data legends, thousands of words with no
    /// Main, Results or Methods — as a paper's text, because the length check ran
    /// on the whole page and the wall check on text the chrome filter had already
    /// stripped of the purchase panel. Such text is worse than none: the row read
    /// as finished, and the reader showed the text instead of the publisher's
    /// page, which is where the learner signs in. Drop it, with everything derived
    /// from it, so the paper asks for its PDF again. Returns whether it did.
    @discardableResult
    func discardStoredPublisherWallTextIfNeeded(for articleId: String, stored: String? = nil) async -> Bool {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }),
              articles[idx].sourceType == .paper,
              articles[idx].resolvedPDFPath == nil else { return false }
        let text: String
        if let stored {
            text = stored
        } else if let loaded = await storage.loadSourceContent(articleId) {
            text = loaded
        } else {
            return false
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !PaperService.looksLikePaperFullText(text) else { return false }

        await storage.clearSourceDerivedData(articleId)
        guard let current = articles.firstIndex(where: { $0.id == articleId }) else { return true }
        articles[current].content = nil
        articles[current].wordCount = nil
        if articles[current].errorMessage?.isEmpty ?? true {
            articles[current].state = .queued
        }
        let wordCount = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        PaperIngestionDiagnostics.recordDiscardedWallText(
            sourceID: articleId,
            title: articles[current].title,
            wordCount: wordCount
        )
        logger.info(
            "Dropped \(wordCount) words of publisher preview stored as the text of paper \(articleId); the paper needs its PDF"
        )
        return true
    }

    /// Save a PDF printed from the publisher's page as the paper's file. The
    /// paper's text, metadata and attestation are already in place from the page,
    /// so unlike a downloaded PDF this neither re-queues metadata extraction nor
    /// re-reads the text: the file is what was missing. Returns whether it saved.
    @discardableResult
    func attachRenderedPublisherPagePDF(to articleId: String, data: Data) async -> Bool {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }),
              articles[idx].sourceType == .paper,
              articles[idx].resolvedPDFPath == nil else { return false }
        guard SourceService.looksLikePDFData(data), await Self.canOpenPDFData(data) else {
            logger.warning("The printed page for \(articleId) is not a readable PDF; not saved")
            return false
        }
        let article = articles[idx]
        let papersDir = (knowledgeBasePath as NSString).appendingPathComponent("Papers")
        await Self.ensureDirectoryExists(at: papersDir)
        let doi = Self.paperDOI(for: article, sourceURL: article.url)
        let filename = Self.preferredPaperFilename(doi: doi, url: article.url)
        let destPath = (papersDir as NSString).appendingPathComponent(filename)
        do {
            try await Self.installDownloadedPDFData(data, at: destPath)
        } catch {
            logger.warning("Could not save the printed page for \(articleId): \(error.localizedDescription)")
            return false
        }
        StudioArticle.recordExistingLocalPath(destPath)

        guard let current = articles.firstIndex(where: { $0.id == articleId }) else { return false }
        articles[current].localFilePath = destPath
        if articles[current].doi == nil, let doi, !doi.isEmpty {
            articles[current].doi = doi
        }
        guard await persistSource(
            articles[current],
            context: "Save PDF printed from the publisher's page",
            showErrorToast: false,
            syncImmediately: true
        ) else { return false }
        let pageCount = await Task.detached(priority: .utility) {
            #if os(macOS)
            return PublisherPagePDFRenderer.pdfPageCount(of: data)
            #else
            return 0
            #endif
        }.value
        PaperIngestionDiagnostics.recordRenderedPublisherPagePDF(
            sourceID: articleId,
            title: articles[current].title,
            pageCount: pageCount
        )
        logger.info("Saved the publisher's page for \(articleId) as a \(pageCount)-page PDF: \(filename)")
        kickSourceEmbeddingIndexing()
        showToast("Saved a PDF of the publisher's page")
        return true
    }

    /// Store text recovered for a paper that has no readable text yet — from a
    /// preserved extraction, its PDF, the publisher's page, or the page the
    /// reader has on screen — through the same cleanup and metadata gates a
    /// downloaded PDF passes. Returns whether the paper came out ready.
    func installRecoveredPaperText(for articleId: String, raw: String) async -> Bool {
        guard var article = articles.first(where: { $0.id == articleId }),
              article.sourceType == .paper else { return false }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            article.state = .error
            article.errorMessage = "Paper ingestion failed: no readable paper text could be recovered."
            PaperIngestionDiagnostics.recordFailure(
                sourceID: article.id,
                title: article.title,
                message: article.errorMessage ?? "No readable paper text could be recovered."
            )
            _ = await persistSource(
                article,
                context: "Save unreadable repaired paper",
                showErrorToast: false
            )
            if let index = articles.firstIndex(where: { $0.id == articleId }) {
                articles[index] = article
            }
            return false
        }

        if article.hasPaperIngestionAttestation {
            do {
                let prepared = try await PaperContentPreparationService(aiService: aiService).prepare(
                    source: AIUsageSource(source: article),
                    rawText: raw
                )
                article.installPreparedPaperContent(
                    raw: prepared.raw,
                    clean: prepared.clean,
                    metadata: prepared.metadata,
                    wordCount: prepared.wordCount
                )
                article.state = .ready
                article.errorMessage = nil
                guard await persistSource(
                    article,
                    context: "Save recovered paper text",
                    showErrorToast: false,
                    syncImmediately: true
                ) else { return false }
                article.discardPersistedPaperContentFromMemory()
                if let index = articles.firstIndex(where: { $0.id == articleId }) {
                    articles[index] = article
                }
                return true
            } catch {
                let failureMessage = error.localizedDescription
                let rawSHA256 = await Self.contentSHA256OffMain(raw)
                article.stagePaperContentCleanup(raw: raw, rawSHA256: rawSHA256)
                let shouldRetryAutomatically =
                    AITransientErrorClassifier.shouldRetryAutomatically(error)
                article.state = shouldRetryAutomatically ? .queued : .error
                article.errorMessage = shouldRetryAutomatically
                    ? nil
                    : StudioArticle.paperContentCleanupFailureMessage(failureMessage)
                PaperIngestionDiagnostics.recordFailure(
                    sourceID: article.id,
                    title: article.title,
                    message: article.errorMessage ?? "Paper cleanup will retry automatically: \(failureMessage)"
                )
                let persisted = await persistSource(
                    article,
                    context: "Save recovered paper cleanup error",
                    showErrorToast: false
                )
                // Raw extraction is ingestion-only. In particular, leaving it
                // in memory on an auto-retry lets the generic queued-content
                // path mistake it for canonical text and promote the paper.
                if shouldRetryAutomatically {
                    article.discardPersistedPaperContentFromMemory()
                } else {
                    article.content = raw
                }
                if persisted, let index = articles.firstIndex(where: { $0.id == articleId }) {
                    articles[index] = article
                }
                return false
            }
        }

        let rawSHA256 = await Self.contentSHA256OffMain(raw)
        article.stagePaperContentCleanup(raw: raw, rawSHA256: rawSHA256)
        article.prepareForPaperMetadataExtraction()
        guard await persistSource(
            article,
            context: "Stage recovered paper text",
            showErrorToast: false
        ) else { return false }
        // The metadata model needs an opening excerpt before the durable raw
        // preparation is loaded later in its pipeline. Restore it only after
        // persistence so the queued save cannot publish raw text as canonical.
        article.content = raw
        if let index = articles.firstIndex(where: { $0.id == articleId }) {
            articles[index] = article
        }
        return await extractPaperMetadataWithAI(id: articleId, showToasts: false)
    }

    nonisolated static func contentSHA256OffMain(_ text: String) async -> String {
        await Task.detached(priority: .utility) {
            PaperContentPreparationService.sha256(text)
        }.value
    }

    /// One-shot automatic PDF resolution for a newly added paper, so the user no
    /// longer has to click "papers needing attention" for every new paper. Runs the
    /// exact same pipeline as the bulk pass — direct download, open-access
    /// alternative, then the AI browser agent — so every paper gets the full
    /// treatment at least once automatically. Returns the outcome so the drain loop
    /// can report a summary; returns `nil` only when the paper no longer needs
    /// attention (already has a PDF, has a terminal paywall error, or isn't fetchable). The
    /// bulk-pass guard lives in the drain loop, which yields its turn without burning
    /// the attempt; this function always runs when called.
    @discardableResult
    func autoResolveNewPaperPDF(for articleId: String) async -> MissingPaperPDFOutcome? {
        defer {
            pendingPaperProcessingIds.remove(articleId)
            queuedPaperPDFResolutionIds.remove(articleId)
        }
        guard let article = articles.first(where: { $0.id == articleId }),
              article.sourceType == .paper,
              (!article.hasPaywallMarker || article.state == .queued) else { return nil }

        if article.resolvedPDFPath != nil {
            guard article.state == .queued,
                  (article.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            else { return nil }
            autoFetchAttemptedPaperIDs.insert(articleId)
            let recovered = await recoverReadablePaperText(for: articleId)
            let metadataComplete = articles.first(where: { $0.id == articleId })?.hasFinishedPaperIngestion == true
            return recovered ? .textRecovered(metadataComplete: metadataComplete) : .failed
        }
        guard article.url.hasPrefix("http") else { return nil }
        // Mark attempted only now that we are actually running the pipeline, so a
        // paper deferred because a manual bulk pass was active keeps its turn and is
        // retried by a later sweep instead of being silently marked done.
        autoFetchAttemptedPaperIDs.insert(articleId)
        let browserConfig = KeychainService.resolveConfig(for: .paperBrowserAgent)
        return await resolveMissingPaperPDF(for: articleId, browserConfig: browserConfig)
    }

    /// True for a paper that still needs a PDF and hasn't already been
    /// queued/attempted for automatic fetch this session. Covers the existing
    /// backlog too, so the user never has to press "papers needing attention" — the
    /// once-per-session `alreadyAttempted` guard keeps us from retrying the same
    /// paper repeatedly within a session. `nonisolated` so the candidate scan can
    /// run off the main actor over a snapshot.
    ///
    /// `dedupKeysWithPDF` is the set of dedup keys of papers that already have a
    /// PDF (see `paperDedupKeysForPapersWithPDF`). A paper whose keys intersect it
    /// is a duplicate of one we already have — the visible "needs attention" list
    /// hides it via the same dedup, so auto-fetch skips it too. Without this guard
    /// the auto check keeps counting and retrying duplicates the user can never see
    /// in the Papers tab.
    ///
    /// `unavailableRecordedPDFIDs` is the storage-degraded set (see
    /// `unavailableRecordedPaperPDFIDs(in:)`): papers whose PDF exists on record
    /// but whose file storage is currently unreachable at scale. Auto-fetch must
    /// not re-download those from publishers. The callers add the papers whose
    /// record says another device finished their ingestion
    /// (`StorageService.sourceIDsIngestedOnAnotherDevice`): their PDF is on that
    /// device and arrives here as a satellite, so a search for it is the same
    /// work done twice.
    nonisolated static func paperNeedsAutoFetch(
        _ article: StudioArticle,
        alreadyAttempted: Set<String>,
        dedupKeysWithPDF: Set<String>,
        unavailableRecordedPDFIDs: Set<String>
    ) -> Bool {
        let needsSavedPDFTextRecovery = article.resolvedPDFPath != nil
            && article.state == .queued
            && (article.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let needsPDFResolution = article.resolvedPDFPath == nil
            && article.url.hasPrefix("http")
            && dedupKeysWithPDF.isDisjoint(with: paperDedupLookupKeys(for: article))
        return article.sourceType == .paper
            && !unavailableRecordedPDFIDs.contains(article.id)
            // Schema v37 deliberately requeues historical paywalled papers
            // that never stored source text. Give that queued repair one
            // automatic pass; terminal paywall errors remain excluded.
            && (!article.hasPaywallMarker || article.state == .queued)
            && article.state != .fetching
            && !alreadyAttempted.contains(article.id)
            && (needsSavedPDFTextRecovery || needsPDFResolution)
    }

    /// Sweep for papers that still need a PDF and enqueue a silent background fetch
    /// for each. Safe to call from any path that loads or replaces `articles`, no
    /// matter how the paper was added (URL bar, browser reading list, suggested
    /// sources, or an MCP write picked up on the next reload). The full-library scan
    /// runs off the main actor over a snapshot so it never costs main-actor time
    /// during a refresh; only the tiny enqueue hops back. Deferred until after
    /// launch by `loadQueue` so startup stays read-only and fast.
    func autoFetchNewlyAddedPapers() {
        let snapshot = articles
        let attempted = autoFetchAttemptedPaperIDs
        let storage = storage
        Task.detached(priority: .utility) { [weak self] in
            let dedupKeysWithPDF = Self.paperDedupKeysForPapersWithPDF(in: snapshot)
            // A paper another device finished ingesting has its PDF on that device and as a satellite on its
            // way here; searching for it again, with the AI browser, is the work being done twice.
            let finishedElsewhere = await storage.sourceIDsIngestedOnAnotherDevice()
            let unavailableIDs = Self.unavailableRecordedPaperPDFIDs(in: snapshot).union(finishedElsewhere)
            let candidates = snapshot
                .filter {
                    Self.paperNeedsAutoFetch(
                        $0,
                        alreadyAttempted: attempted,
                        dedupKeysWithPDF: dedupKeysWithPDF,
                        unavailableRecordedPDFIDs: unavailableIDs
                    )
                }
                .map(\.id)
            guard !candidates.isEmpty else { return }
            await self?.enqueueAutoPaperFetch(
                candidates,
                dedupKeysWithPDF: dedupKeysWithPDF,
                unavailableRecordedPDFIDs: unavailableIDs
            )
        }
    }

    /// Enqueue papers for automatic background PDF resolution, deduplicated per
    /// session so a paper is never auto-fetched twice. Re-validates against live
    /// state because the off-main scan worked from a snapshot. `dedupKeysWithPDF`
    /// and `unavailableRecordedPDFIDs` are threaded through from that scan so the
    /// re-validation reuses them without re-running the stat-heavy
    /// paper-with-PDF scan on the main actor. Cheap main-actor work.
    func enqueueAutoPaperFetch(
        _ articleIds: [String],
        dedupKeysWithPDF: Set<String>,
        unavailableRecordedPDFIDs: Set<String>
    ) {
        var didEnqueue = false
        for id in articleIds {
            guard let article = articlesById[id],
                  Self.paperNeedsAutoFetch(
                      article,
                      alreadyAttempted: autoFetchAttemptedPaperIDs,
                      dedupKeysWithPDF: dedupKeysWithPDF,
                      unavailableRecordedPDFIDs: unavailableRecordedPDFIDs
                  )
            else {
                pendingPaperProcessingIds.remove(id)
                queuedPaperPDFResolutionIds.remove(id)
                continue
            }
            guard !autoFetchPaperQueue.contains(id) else { continue }
            autoFetchPaperQueue.append(id)
            queuedPaperPDFResolutionIds.insert(id)
            didEnqueue = true
        }
        if didEnqueue { drainAutoPaperFetchQueue() }
    }

    /// Convenience for direct add paths (e.g. the URL bar) that enqueue a single
    /// paper. Computes the paper-with-PDF dedup key set off the main actor over a
    /// snapshot so re-adding a paper we already have a PDF for is skipped, just
    /// like the bulk scan.
    func enqueueAutoPaperFetch(_ articleId: String) {
        let snapshot = articles
        let storage = storage
        Task.detached(priority: .utility) { [weak self] in
            let dedupKeysWithPDF = Self.paperDedupKeysForPapersWithPDF(in: snapshot)
            let finishedElsewhere = await storage.sourceIDsIngestedOnAnotherDevice()
            let unavailableIDs = Self.unavailableRecordedPaperPDFIDs(in: snapshot).union(finishedElsewhere)
            await self?.enqueueAutoPaperFetch(
                [articleId],
                dedupKeysWithPDF: dedupKeysWithPDF,
                unavailableRecordedPDFIDs: unavailableIDs
            )
        }
    }

    /// True for a source that has never had its content fetched and can be
    /// fetched without asking the user first.
    ///
    /// Papers are excluded: `autoFetchNewlyAddedPapers` already covers them and
    /// knows about PDF resolution, paywalls, and duplicate detection, none of
    /// which the generic content path understands. Non-http sources are local
    /// documents read from disk, so there is nothing to fetch.
    ///
    /// `nonisolated` so the candidate scan can run off the main actor over a
    /// snapshot.
    nonisolated static func sourceNeedsInitialContentFetch(
        _ article: StudioArticle,
        alreadyAttempted: Set<String>
    ) -> Bool {
        // General failures remain manual retries. This narrow exception heals
        // rows stranded when the old archive path accepted Figshare's empty 202
        // WAF response and never reached its browser fallback.
        let isFigshareWAFRepair = article.state == .error
            && URL(string: article.url).flatMap(SourceService.figshareResource(from:)) != nil

        // An X post is only readable offline once its thread has been captured
        // to disk, and a bookmark arrives `.ready` with the post's text and no
        // capture at all. Those rows need the fetch as much as an empty one
        // does — that is what makes them survive an offline Mac or a Screen
        // Time block — so they qualify on a missing capture rather than on
        // missing text. The capture writes `localFilePath`, so a post that has
        // one is done.
        if article.sourceType == .xPost {
            return article.localFilePath?.isEmpty != false
                && article.state != .fetching
                && article.url.hasPrefix("http")
                && !alreadyAttempted.contains(article.id)
        }

        return (article.state == .queued || isFigshareWAFRepair)
            && article.sourceType != .paper
            && article.url.hasPrefix("http")
            && (article.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && !alreadyAttempted.contains(article.id)
    }

    /// Fetch content for sources that have never had any.
    ///
    /// A source is created `queued` and its content is fetched when the learner
    /// opens it. A source nobody opens is therefore never fetched, never
    /// embedded — `queueSourceEmbeddingRefreshIfReady` requires `.ready` — and
    /// so invisible to search and to the assistant, while still appearing in
    /// the library as though it were part of the knowledge base. 161 Safari
    /// articles had been sitting in exactly that state, the oldest for seven
    /// months. Ingesting a source should leave it readable without waiting for
    /// a click.
    ///
    /// Mirrors `autoFetchNewlyAddedPapers`: the full-library scan runs off the
    /// main actor over a snapshot, only the tiny enqueue hops back, and it is
    /// deferred until after launch by `loadQueue` so startup stays read-only
    /// and fast. It covers the existing backlog for the same reason the paper
    /// sweep does — a source added before this existed is no less invisible.
    func autoFetchUnfetchedSources() {
        let snapshot = articles
        let attempted = autoFetchAttemptedContentIDs
        Task.detached(priority: .utility) { [weak self] in
            let candidates = snapshot
                .filter { Self.sourceNeedsInitialContentFetch($0, alreadyAttempted: attempted) }
                .map(\.id)
            guard !candidates.isEmpty else { return }
            await self?.enqueueInitialContentFetch(candidates)
        }
    }

    /// Enqueue sources for their first content fetch. Re-validates against live
    /// state because the scan worked from a snapshot. Cheap main-actor work.
    func enqueueInitialContentFetch(_ articleIds: [String]) {
        var didEnqueue = false
        for id in articleIds {
            guard let article = articlesById[id],
                  Self.sourceNeedsInitialContentFetch(article, alreadyAttempted: autoFetchAttemptedContentIDs),
                  !autoFetchContentQueue.contains(id)
            else { continue }
            autoFetchContentQueue.append(id)
            didEnqueue = true
        }
        if didEnqueue { drainInitialContentFetchQueue() }
    }

    /// Drain one source at a time.
    ///
    /// Serial on purpose. This walks a backlog that can run to hundreds of URLs
    /// across many hosts, and firing them in parallel is how an app collects
    /// rate limits and blocks. Each id is marked attempted *before* the fetch,
    /// so a source that fails or hangs is not retried for the rest of the
    /// session; a real failure sets `.error` and leaves the candidate set for
    /// good.
    private func drainInitialContentFetchQueue() {
        guard !isDrainingInitialContentFetchQueue else { return }
        isDrainingInitialContentFetchQueue = true
        Task {
            while !autoFetchContentQueue.isEmpty {
                let articleId = autoFetchContentQueue.removeFirst()
                autoFetchAttemptedContentIDs.insert(articleId)
                await fetchContent(for: articleId)
            }
            isDrainingInitialContentFetchQueue = false
        }
    }

    /// True for a paper that has paper content but no durable LLM attestation and
    /// hasn't already been attempted this session. A title alone is never enough:
    /// the Paper Metadata task must receive PDF or full-text paper content.
    /// `nonisolated` so the candidate scan can run off the main actor over a snapshot.
    nonisolated static func paperNeedsAutoMetadataExtraction(
        _ article: StudioArticle,
        alreadyAttempted: Set<String>
    ) -> Bool {
        article.sourceType == .paper
            && article.requiresPaperMetadataAI
            && article.state != .fetching
            && !alreadyAttempted.contains(article.id)
            && (article.resolvedPDFPath != nil
                || !(article.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
    }

    /// Sweep for papers that still show unknown metadata and enqueue a silent
    /// background AI extraction for each. Together with `autoFetchNewlyAddedPapers`
    /// this guarantees no paper is left with "Unknown authors" regardless of how it
    /// was added. Skipped entirely when no metadata API key is configured — we never
    /// fall back to heuristics. The full-library scan runs off the main actor over a
    /// snapshot so it never costs main-actor time; only the tiny enqueue hops back.
    /// Deferred until after launch so startup stays read-only and fast.
    func autoExtractMissingPaperMetadata() {
        let snapshot = articles
        let attempted = autoExtractMetadataAttemptedPaperIDs
        // Papers an earlier build failed over a blank field are healed with no
        // model call at all, so this half runs even with no metadata AI
        // configured and with an empty balance.
        let hasMetadataConfig = KeychainService.resolveConfig(for: .paperMetadata) != nil
        let storage = storage
        Task.detached(priority: .utility) { [weak self] in
            // The metadata gate was passed on the device that finished the paper; its record says so.
            var finishedElsewhere = Set<String>()
            if hasMetadataConfig { finishedElsewhere = await storage.sourceIDsIngestedOnAnotherDevice() }
            let healable = snapshot
                .filter(\.canAttestPaperIngestionAfterBlankMetadataFailure)
                .map(\.id)
            let candidates = hasMetadataConfig
                ? snapshot
                    .filter {
                        !finishedElsewhere.contains($0.id)
                            && Self.paperNeedsAutoMetadataExtraction($0, alreadyAttempted: attempted)
                    }
                    .map(\.id)
                : []
            guard !healable.isEmpty || !candidates.isEmpty else { return }
            // Heal first and let it commit: a healed paper drops out of the
            // extraction candidates when `enqueueAutoMetadataExtraction`
            // re-validates it against live state.
            await self?.attestPapersFailedOnBlankMetadata(healable)
            guard !candidates.isEmpty else { return }
            await self?.enqueueAutoMetadataExtraction(candidates)
        }
    }

    /// Promote papers whose only recorded problem was a bibliographic field the
    /// document does not print. The metadata stage already ran for these rows —
    /// see `canAttestPaperIngestionAfterBlankMetadataFailure` — so this spends
    /// nothing and simply stops presenting a readable paper as a failed ingestion.
    func attestPapersFailedOnBlankMetadata(_ articleIds: [String]) async {
        for id in articleIds {
            guard var article = articlesById[id] else { continue }
            guard article.attestPaperIngestionAfterBlankMetadataFailure() else { continue }
            guard await persistSource(
                article,
                context: "Attest paper ingestion after blank metadata",
                showErrorToast: false
            ) else { continue }
            if let idx = articles.firstIndex(where: { $0.id == id }) {
                articles[idx] = article
            }
            logger.info(
                "Attested paper ingestion for \(id): the extractor left \(article.missingRequiredPaperMetadataFields.joined(separator: ", ")) blank, which the document does not print"
            )
        }
    }

    /// Enqueue papers for automatic background AI metadata extraction, deduplicated
    /// per session so a paper is never auto-extracted twice. Re-validates against live
    /// state because the off-main scan worked from a snapshot. Cheap main-actor work.
    func enqueueAutoMetadataExtraction(_ articleIds: [String]) {
        var didEnqueue = false
        for id in articleIds {
            guard let article = articlesById[id],
                  Self.paperNeedsAutoMetadataExtraction(article, alreadyAttempted: autoExtractMetadataAttemptedPaperIDs)
            else { continue }
            autoExtractMetadataAttemptedPaperIDs.insert(id)
            autoExtractMetadataQueue.append(id)
            queuedPaperMetadataExtractionIds.insert(id)
            didEnqueue = true
        }
        if didEnqueue { drainAutoMetadataExtractionQueue() }
    }

    /// The next paper to work on from a background paper queue. The queues are
    /// filled by a library-wide sweep, so a paper the learner just filed in a
    /// notebook would otherwise wait behind every paper in the library, with a
    /// spinner on its row the whole time. Papers that belong to a notebook go
    /// first, in the order they were queued; the rest keep their order after them.
    private func takeNextAutoPaperID(from queue: inout [String]) -> String {
        let members = Set(notebooks.flatMap(\.approvedSourceIDs).map(canonicalSourceID))
        let index = queue.firstIndex { members.contains(canonicalSourceID($0)) } ?? 0
        return queue.remove(at: index)
    }

    /// Extract metadata for queued papers one at a time so we never run several AI
    /// calls concurrently. The loop only coordinates on the main actor; the AI
    /// request and PDF parsing happen off-main inside `extractPaperMetadataWithAI`.
    private func drainAutoMetadataExtractionQueue() {
        guard !isDrainingAutoExtractMetadataQueue else { return }
        isDrainingAutoExtractMetadataQueue = true
        Task {
            while !autoExtractMetadataQueue.isEmpty {
                let articleId = takeNextAutoPaperID(from: &autoExtractMetadataQueue)
                _ = await extractPaperMetadataWithAI(id: articleId, showToasts: false)
                queuedPaperMetadataExtractionIds.remove(articleId)
            }
            isDrainingAutoExtractMetadataQueue = false
        }
    }

    /// Resolve queued papers one at a time so we never run several downloads
    /// concurrently. Each paper goes through the same full pipeline as the manual
    /// "papers needing attention" pass — including the AI browser agent. This is an
    /// automatic background pass the user didn't ask for, so it stays silent: any
    /// download it lands is reflected in the Papers badge and list, and unresolved
    /// papers remain visible there. Only the user-initiated bulk pass
    /// (`runMissingPaperPDFDownload`) reports a toast. The loop only coordinates on
    /// the main actor; the actual download and PDF parsing happen off-main inside
    /// `downloadPaperPDF`'s `nonisolated` / `Task.detached` helpers, so the main
    /// actor stays free.
    private func drainAutoPaperFetchQueue() {
        guard !isDrainingAutoPaperFetchQueue else { return }
        isDrainingAutoPaperFetchQueue = true
        Task {
            while !autoFetchPaperQueue.isEmpty {
                // A manual bulk pass owns the same papers-needing-attention set.
                // Yield to it: drop the queue (these papers stay un-attempted, so a
                // later sweep re-enqueues any the bulk pass doesn't resolve).
                if isResolvingMissingPaperPDFs || missingPaperPDFDownloadTask != nil {
                    pendingPaperProcessingIds.subtract(autoFetchPaperQueue)
                    queuedPaperPDFResolutionIds.subtract(autoFetchPaperQueue)
                    autoFetchPaperQueue.removeAll()
                    break
                }
                let articleId = takeNextAutoPaperID(from: &autoFetchPaperQueue)
                _ = await autoResolveNewPaperPDF(for: articleId)
            }
            isDrainingAutoPaperFetchQueue = false
        }
    }

    /// Try downloading a paper PDF, resetting error state first.
    func tryPaperPDFDownload(for articleId: String) async {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }
        resolvingPaperPDFIds.insert(articleId)
        defer { resolvingPaperPDFIds.remove(articleId) }
        // One paper the publisher's file and every open-access copy are held
        // to, so the message below can name each file that was not it.
        let identity = PaperPDFIdentityGate(article: articles[idx])

        articles[idx].state = .fetching
        articles[idx].errorMessage = nil
        isFetchingContent = true
        guard await persistSource(articles[idx], context: "Save paper download state") else {
            isFetchingContent = false
            return
        }

        let result = await downloadPaperPDF(for: articleId, identity: identity)
        if result.success {
            await extractPaperTitle(for: articleId)
            isFetchingContent = false
            return
        }
        // The PDF landed but the mandatory metadata model failed. Its explicit
        // error state is already persisted; do not discard/re-download the PDF.
        if paperHasLocalPDF(articleId) {
            isFetchingContent = false
            return
        }

        if await adoptOpenAccessAlternativeIfAvailable(for: articleId, identity: identity) {
            isFetchingContent = false
            return
        }

        // Download failed — set error state with debug log
        if let idx2 = articles.firstIndex(where: { $0.id == articleId }) {
            articles[idx2].state = .error
            let debugTrace = result.debugLog.joined(separator: "\n")
            let detail = result.lastError?.localizedDescription ?? "unknown error"
            articles[idx2].errorMessage = "PDF download failed: \(detail)\n\n--- Debug Log ---\n\(debugTrace)"
            PaperIngestionDiagnostics.recordFailure(
                sourceID: articleId,
                title: articles[idx2].title,
                message: articles[idx2].errorMessage ?? "PDF download failed: \(detail)"
            )
            logger.error("Paper PDF download debug log:\n\(debugTrace)")
            debugAlertMessage = debugTrace
            showDebugAlert = true
            await persistSource(articles[idx2], context: "Save the failed download")
        }
        isFetchingContent = false
    }

    /// Where a browser agent's PDF came from when WebKit named no address,
    /// so a file turned away names the agent rather than a temporary file.
    nonisolated static let paperBrowserAgentPDFOrigin = "a link the AI browser chose"

    /// Let the AI browser agent look for the paper's PDF and attach what it
    /// downloads. A resolution passes its `identity`, which the file is held
    /// to like every other candidate: a file that is some other paper comes
    /// back as `.failed`, so the row stays as it was and the batch counts the
    /// file among those it turned away. The learner's own **Try with AI
    /// Browser** passes none; the learner is there to answer the title check.
    func attemptPaperPDFDownloadWithAIBrowser(
        for articleId: String,
        config: AITaskConfig,
        showPaywallToast: Bool,
        identity: PaperPDFIdentityGate? = nil
    ) async -> PaperAIBrowserAttemptResult {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else {
            return .failed(SourceError.fetchFailed)
        }
        guard articles[idx].sourceType == .paper,
              articles[idx].resolvedPDFPath == nil,
              articles[idx].url.hasPrefix("http") else {
            return .failed(SourceError.fetchFailed)
        }

        let article = articles[idx]
        let service = SourceDiscovery.PaperAIBrowserDownloadService(aiService: aiService)
        let attemptID = UUID()
        activePaperBrowserTasks.removeValue(forKey: articleId)?.cancel()
        activePaperBrowserServices.removeValue(forKey: articleId)?.cancel()
        activePaperBrowserAttemptIDs[articleId] = attemptID
        activePaperBrowserServices[articleId] = service
        // The progress closure below publishes browser steps into paperDownloadStep.
        // Always clear it on exit: callers like autoResolveNewPaperPDF have no cleanup
        // of their own, and without this the last step (e.g. "Downloading PDF...")
        // stays in the sidebar forever after a failed automatic attempt.
        defer {
            if activePaperBrowserAttemptIDs[articleId] == attemptID {
                activePaperBrowserAttemptIDs.removeValue(forKey: articleId)
                activePaperBrowserServices.removeValue(forKey: articleId)
                activePaperBrowserTasks.removeValue(forKey: articleId)
                paperDownloadStep = ""
            }
        }
        do {
            // The task is stored in `activePaperBrowserTasks` (owned by self), so
            // both nested escaping closures must capture self weakly. Matching the
            // ownership at both levels avoids retaining the view model and satisfies
            // Swift's nested-capture ownership rules.
            let browserTask = Task<SourceDiscovery.PaperAIBrowserDownloadService.DownloadedPDF, Error> { [weak self] in
                try Task.checkCancellation()
                let download = try await service.findAndDownloadPDF(
                    article: article,
                    config: config
                ) { [weak self] step in
                    guard self?.activePaperBrowserAttemptIDs[articleId] == attemptID else { return }
                    self?.paperDownloadStep = step
                }
                try Task.checkCancellation()
                return download
            }
            activePaperBrowserTasks[articleId] = browserTask
            let download = try await browserTask.value
            return try await attachPaperBrowserDownload(download, to: articleId, attemptID: attemptID, identity: identity)
        } catch is CancellationError {
            return .cancelled
        } catch SourceDiscovery.PaperAIBrowserDownloadService.BrowserAgentError.paywalled(let evidence) {
            logger.info("AI browser detected paywall evidence for \(articleId): \(evidence)")
            // A recheck starts with an existing marker. Leave that durable state
            // untouched instead of writing/syncing it again or showing a redundant
            // "marked paywalled" toast for every paper in the batch.
            if !article.hasPaywallMarker {
                await markPaywalled(articleId: articleId, evidence: evidence, showEvidenceToast: showPaywallToast)
            }
            return .paywalled
        } catch SourceDiscovery.PaperAIBrowserDownloadService.BrowserAgentError.likelyPaywalled(let reason) {
            logger.info("AI browser suspects a paywall for \(articleId): \(reason)")
            await recordPaywallSuspicion(articleId: articleId, reason: reason)
            return .suspectedPaywall(reason)
        } catch SourceDiscovery.PaperAIBrowserDownloadService.BrowserAgentError.notAPaper(let reason) {
            logger.info("AI browser found that \(articleId) is not a paper: \(reason)")
            await reclassifyPaperAsArticle(articleId: articleId, reason: reason)
            return .notAPaper(reason)
        } catch {
            logger.warning("AI browser paper download failed for \(articleId): \(error.localizedDescription)")
            return .failed(error)
        }
    }

    /// Attach the file the AI browser agent downloaded in attempt
    /// `attemptID`, then remove the temporary download whatever happened.
    /// `.cancelled` when the attempt was superseded, the paper already has a
    /// PDF, or the attachment was declined; throws when the file is the
    /// paper's supplementary material or, held to `identity`, another paper.
    func attachPaperBrowserDownload(
        _ download: SourceDiscovery.PaperAIBrowserDownloadService.DownloadedPDF,
        to articleId: String,
        attemptID: UUID,
        identity: PaperPDFIdentityGate?
    ) async throws -> PaperAIBrowserAttemptResult {
        let file = download.file
        guard activePaperBrowserAttemptIDs[articleId] == attemptID,
              articles.first(where: { $0.id == articleId })?.resolvedPDFPath == nil else {
            await Self.removeItem(at: file.path)
            return .cancelled
        }
        // A paper's supplementary file is not the paper, whoever found the
        // link — and it often prints the paper's title and DOI.
        if let served = download.sourceURL, PaperService.isSupplementaryPDFURL(served.absoluteString) {
            await Self.removeItem(at: file.path)
            throw SourceError.paperIngestionFailed(
                "That file is the paper's supplementary material, not the paper."
            )
        }
        let attached: Bool
        do {
            attached = try await attachPDF(
                to: articleId,
                pdfURL: file,
                cancelsActiveDiscovery: false,
                expectedDiscoveryAttemptID: attemptID,
                identity: identity,
                downloadedFrom: download.sourceURL?.absoluteString ?? Self.paperBrowserAgentPDFOrigin
            )
        } catch {
            await Self.removeItem(at: file.path)
            throw error
        }
        await Self.removeItem(at: file.path)
        guard attached else { return .cancelled }
        await refreshArticles()
        return .downloaded
    }

    /// Use an AI-guided WKWebView session to look for an open-access PDF, then
    /// attach the downloaded file to the same paper source.
    func tryPaperPDFDownloadWithAIBrowser(for articleId: String) async {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }
        guard articles[idx].sourceType == .paper,
              articles[idx].resolvedPDFPath == nil,
              articles[idx].url.hasPrefix("http") else {
            showToast("This paper already has a PDF")
            return
        }
        guard let config = KeychainService.resolveConfig(for: .paperBrowserAgent) else {
            showToast(
                KeychainService.backgroundAIUnavailableMessage(for: .paperBrowserAgent)
                    ?? "Set an API key in Settings first"
            )
            return
        }

        resolvingPaperPDFIds.insert(articleId)
        defer { resolvingPaperPDFIds.remove(articleId) }

        isFetchingContent = true
        paperDownloadStep = "Starting AI browser..."
        defer {
            isFetchingContent = false
            paperDownloadStep = ""
        }

        let result = await attemptPaperPDFDownloadWithAIBrowser(
            for: articleId,
            config: config,
            showPaywallToast: true
        )
        if case .failed(let error) = result {
            showToast("AI browser could not find a PDF: \(error.localizedDescription)")
        }
        if case .suspectedPaywall(let reason) = result {
            showToast("Looks paywalled: \(reason) — Mark as Paywalled is on the paper's row.")
        }
        if case .notAPaper(let reason) = result {
            showToast("Moved to Articles: \(reason)")
        }
    }

    /// Durable exit from the paper pipeline for a page that is not a paper.
    /// Rewrites the source as an article, drops the paper-only state, persists
    /// and syncs it at once, and hands it to the article pipeline so it is
    /// fetched and prepared like any other web page. Returns false when the
    /// source is gone, already not a paper, or could not be saved.
    @discardableResult
    func reclassifyPaperAsArticle(articleId: String, reason: String) async -> Bool {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }),
              articles[idx].sourceType == .paper else { return false }
        pendingPaperProcessingIds.remove(articleId)
        queuedPaperPDFResolutionIds.remove(articleId)
        autoFetchPaperQueue.removeAll { $0 == articleId }
        paperProcessingSteps.removeValue(forKey: articleId)

        var updated = articles[idx]
        updated.convertPaperToArticle()
        logger.info("Reclassified paper as article: \(updated.title) — \(reason)")
        PaperIngestionDiagnostics.recordReclassifiedAsArticle(
            sourceID: articleId,
            title: updated.title,
            reason: reason
        )
        await storage.clearSourceDerivedData(articleId)
        guard await persistSource(updated, context: "Save source type", syncImmediately: true) else {
            return false
        }
        if let currentIndex = articles.firstIndex(where: { $0.id == articleId }) {
            articles[currentIndex] = updated
        }
        Task { [weak self] in
            await self?.fetchContent(for: articleId)
        }
        return true
    }

    /// Fetch the HTML page for a paper URL and try to extract the title.
    /// Updates the article's title in-place if a better one is found.
    /// For direct PDF URLs (arXiv, bioRxiv, etc.), converts to the abstract page first.
    func extractPaperTitle(for articleId: String) async {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }),
              articles[idx].url.hasPrefix("http") else { return }
        let url = articles[idx].url

        // Only bother if the title looks like a domain/URL/filename (not already set to something meaningful)
        guard Self.titleNeedsResolution(articles[idx].title, domain: articles[idx].domain, url: url) else { return }

        // Strategy 1: Fetch HTML from abstract/landing page and extract title from meta tags
        if let title = await PaperService.fetchPaperPageMetadata(at: url)?.title {
            await applyExtractedPaperTitle(title, to: articleId, source: "HTML")
            return
        }

        // Strategy 2: Extract title from the downloaded local PDF metadata / first-page text
        #if canImport(PDFKit)
        if let localPath = articles.first(where: { $0.id == articleId })?.localFilePath,
           let pdfTitle = await Self.extractPDFTitleOffMain(from: localPath) {
            await applyExtractedPaperTitle(pdfTitle, to: articleId, source: "PDF metadata")
            return
        }
        #endif

    }

    /// Re-resolves the article by id (the index captured before the network
    /// awaits above may be stale after a concurrent refresh), applies the title,
    /// and persists it.
    private func applyExtractedPaperTitle(_ title: String, to articleId: String, source: String) async {
        guard mutateArticle(id: articleId, { $0.title = title }),
              let current = articles.first(where: { $0.id == articleId }) else { return }
        if await persistSource(current, context: "Save paper title", showErrorToast: false) {
            logger.info("Extracted paper title from \(source): \(title)")
        }
    }

    // Keep title derivation available cross-platform.

    /// Filenames are identity-bearing structure, not human-authored title metadata.
    /// Leave resolution to the configured paper-metadata task.
    nonisolated static func titleFromPDFURL(_ urlString: String) -> String? {
        nil
    }

}
