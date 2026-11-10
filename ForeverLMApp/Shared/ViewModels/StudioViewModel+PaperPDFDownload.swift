// Downloading, attaching and merging paper PDFs.

import Foundation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif
import AppKit
import Darwin

extension StudioViewModel {

    /// Resolve DOI values that are already in memory. Opening a PDF is deliberately
    /// excluded so this synchronous helper is always safe for main-actor callers.
    nonisolated static func paperDOI(for article: StudioArticle, sourceURL: String? = nil) -> String? {
        if let doi = article.doi, !doi.isEmpty { return doi }
        if let doi = PaperService.extractDOI(from: article.url) { return doi }
        if let sourceURL, let doi = PaperService.extractDOI(from: sourceURL) { return doi }
        return nil
    }

    nonisolated static func paperDOIOffMain(
        for article: StudioArticle,
        attachedPDFPath: String? = nil,
        sourceURL: String? = nil
    ) async -> String? {
        if let doi = paperDOI(for: article, sourceURL: sourceURL) { return doi }
        #if canImport(PDFKit)
        guard let attachedPDFPath else { return nil }
        return await Task.detached(priority: .utility) {
            extractDOIFromPDF(at: attachedPDFPath)
        }.value
        #else
        return nil
        #endif
    }

    /// The metadata step every PDF attachment ends with. By the time it runs the
    /// attachment is saved and the row's attestation is cleared, so this step is
    /// the only thing that can finish the paper, and it runs in a task of its own
    /// that the caller's cancellation does not reach. The reader attaches the PDF
    /// it downloaded from inside its view's `.task`, and the attachment itself
    /// swaps that remote-PDF view for the local one, cancelling the task: the
    /// extraction then returned at its first cancellation check and left the
    /// paper under "Metadata incomplete" with nothing working on it until a
    /// later refresh's sweep (2026-10-10, a Nature Communications paper the
    /// reader had just found).
    func enrichPaperMetadataAfterPDFAttachment(
        articleId: String,
        userInitiated: Bool,
        forceAIForMissingAuthor: Bool = false
    ) async -> Bool {
        await Task {
            await runPaperMetadataEnrichmentAfterPDFAttachment(
                articleId: articleId,
                userInitiated: userInitiated,
                forceAIForMissingAuthor: forceAIForMissingAuthor
            )
        }.value
    }

    private func runPaperMetadataEnrichmentAfterPDFAttachment(
        articleId: String,
        userInitiated: Bool,
        forceAIForMissingAuthor: Bool
    ) async -> Bool {
        if paperMetadataEnrichmentInFlight.contains(articleId) {
            while paperMetadataEnrichmentInFlight.contains(articleId) {
                guard !Task.isCancelled else { return false }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return articles.first(where: { $0.id == articleId })?.hasFinishedPaperIngestion == true
        }

        guard let idx = articles.firstIndex(where: { $0.id == articleId }),
              shouldEnrichPaperMetadataAfterPDFAttachment(articles[idx]) else { return false }

        // Nothing can pay for the extraction. The source itself is already saved
        // and readable; firing the calls anyway would spend the wait, mark the
        // row a failed ingestion, and end at the same prompt. Leave it pending so
        // a later pass picks it up the moment credits arrive.
        guard !AICreditEntitlement.isOutOfCredits else {
            NotificationCenter.default.post(name: .managedAICreditsEmpty, object: nil)
            return false
        }

        paperMetadataEnrichmentInFlight.insert(articleId)
        let previousProcessingStep = paperProcessingSteps[articleId]
        defer {
            paperMetadataEnrichmentInFlight.remove(articleId)
            if let previousProcessingStep {
                paperProcessingSteps[articleId] = previousProcessingStep
            } else {
                paperProcessingSteps.removeValue(forKey: articleId)
            }
            // See `dropPaperProcessingStepIfIdle`: a caption restored here is
            // only valid while some other pass still owns the row.
            dropPaperProcessingStepIfIdle(articleId)
        }

        let previousStep = paperDownloadStep
        // A non-nil prefix hands `paperDownloadStep` to this flow and to the
        // phases inside `extractPaperMetadataWithAI`; nil leaves it alone.
        let progressPrefix: String? = (userInitiated || forceAIForMissingAuthor) ? "" : nil
        // The PDF's first page is the source of truth, and the Paper Metadata
        // model reads it for the title, authors, venue, year and DOI in one call.
        // The publisher landing page and the Crossref/OpenAlex cascade are not asked
        // first: one request after another with 15-second timeouts each would let a slow
        // nature.com or a rate-limited catalog hold the row under "Looking up
        // paper metadata…" for over a minute before the model was even asked.
        // Nothing waits on the network now. `extractPaperMetadataWithAI` publishes
        // its own "Extracting paper metadata…" caption once the page text is read.
        let metadataComplete = await extractPaperMetadataWithAI(
            id: articleId,
            showToasts: userInitiated,
            progressPrefix: progressPrefix
        )
        if progressPrefix != nil {
            paperDownloadStep = previousStep
        }
        if metadataComplete {
            Task { [weak self] in
                await self?.resolvePublishedVersionIdentityAfterIngestion(for: articleId)
            }
        }
        return metadataComplete
    }

    /// Report the stage that actually stopped ingestion. PDF attachment is
    /// already durable by this point, so callers must not flatten a cleanup or
    /// persistence failure into a claim that metadata was empty.
    func stalledPaperIngestionError(for articleId: String) -> SourceError {
        guard let article = articles.first(where: { $0.id == articleId }) else {
            return AICreditEntitlement.isOutOfCredits
                ? .aiCreditsRequired
                : .paperIngestionFailed("Paper ingestion did not finish.")
        }
        if let message = article.errorMessage?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return .paperIngestionFailed(message)
        }
        if AICreditEntitlement.isOutOfCredits { return .aiCreditsRequired }
        if !article.hasPaperIngestionAttestation {
            return .paperMetadataExtractionFailed
        }
        if !article.hasCompletedPaperContentCleanup {
            return .paperIngestionFailed("Paper content cleanup did not finish.")
        }
        return .paperIngestionFailed("Paper ingestion did not finish.")
    }

    func shouldEnrichPaperMetadataAfterPDFAttachment(_ article: StudioArticle) -> Bool {
        article.sourceType == .paper
        && article.resolvedPDFPath != nil
    }

    /// What a paper's downloaded PDFs are held to (`PaperPDFIdentity`): its
    /// DOI, and its title once that is a real one rather than the domain, URL
    /// or bot-check chrome a row wears before its title is resolved.
    nonisolated static func paperPDFIdentityRequest(for article: StudioArticle) -> PaperPDFIdentity.Request {
        PaperPDFIdentity.Request(
            doi: paperDOI(for: article),
            titles: titleNeedsResolution(article.title, domain: article.domain, url: article.url) ? [] : [article.title]
        )
    }

    /// The paper one PDF resolution holds every downloaded file to, and the
    /// files it has turned away. An index can list another paper's copy under
    /// this paper's DOI (OpenAlex did on 2026-09-28, for a DOI cut short at
    /// its parenthesis), and once the Paper Metadata model has read that copy
    /// it rewrites the title, DOI, authors and year to match, so a wrong file
    /// has to be stopped before it is attached.
    ///
    /// One gate spans every candidate a resolution tries — the publisher's
    /// link, the reader's session, each open-access copy, the AI browser
    /// agent's download — so the DOI's
    /// registered title is asked for at most once, and the message left on
    /// the paper can name every file that was not it. It is built from the row
    /// before `adoptOpenAccessAlternativeIfAvailable` swaps a candidate's
    /// address onto it: that address says nothing about which paper this is.
    @MainActor
    final class PaperPDFIdentityGate {
        let sourceID: String
        /// The paper's own address, for the diagnostics line.
        let requestedURL: String
        private(set) var request: PaperPDFIdentity.Request
        private(set) var rejections: [PaperPDFIdentityMismatchError] = []
        private let registeredTitle: (String) async -> String?
        /// Writes a turned-away file to the ingestion log. A test stands in for
        /// it, so its fixtures stay out of the real log.
        private let recordMismatch: @MainActor (_ gate: PaperPDFIdentityGate, _ rejection: PaperPDFIdentityMismatchError) -> Void

        init(
            article: StudioArticle,
            registeredTitle: @escaping (String) async -> String? = { await PaperService.registeredTitleIfKnown(forDOI: $0) },
            recordMismatch: @escaping @MainActor (_ gate: PaperPDFIdentityGate, _ rejection: PaperPDFIdentityMismatchError) -> Void = { gate, rejection in
                PaperIngestionDiagnostics.recordPDFIdentityMismatch(
                    sourceID: gate.sourceID,
                    requestedURL: gate.requestedURL,
                    requestedDOI: gate.request.doi,
                    pdfURL: rejection.pdfURL,
                    reason: rejection.reason
                )
            }
        ) {
            sourceID = article.id
            requestedURL = article.url
            request = StudioViewModel.paperPDFIdentityRequest(for: article)
            self.registeredTitle = registeredTitle
            self.recordMismatch = recordMismatch
        }

        /// Hold the PDF at `path`, which came from `pdfURL`, to the paper.
        /// Another paper's file is logged as `PDF_IDENTITY_MISMATCH` and thrown
        /// as a `PaperPDFIdentityMismatchError`, so the caller treats it as a
        /// candidate that failed and goes on to its next one. The file is
        /// removed first, unless `keepsRejectedFile`: one that was already on
        /// disk may be another row's PDF, and a caller may own the file.
        /// Otherwise returns `.confirmed` or `.unverifiable`.
        @discardableResult
        func admit(pdfAt path: String, from pdfURL: String, keepsRejectedFile: Bool = false) async throws -> PaperPDFIdentity.Verdict {
            var request = self.request
            let verdict = await PaperPDFIdentity.verdict(
                forPDFAt: URL(fileURLWithPath: path),
                request: &request,
                registeredTitle: registeredTitle
            )
            self.request = request
            guard case .mismatch(let reason) = verdict else { return verdict }
            if !keepsRejectedFile {
                await StudioViewModel.removeItem(at: path)
            }
            let rejection = PaperPDFIdentityMismatchError(pdfURL: pdfURL, reason: reason)
            rejections.append(rejection)
            recordMismatch(self, rejection)
            throw rejection
        }
    }

    /// A batch summary's word on the PDFs it turned away as other papers:
    /// one is named, more are counted. The ingestion log names every one.
    nonisolated static func turnedAwayPDFsSummary(_ rejections: [PaperPDFIdentityMismatchError]) -> String? {
        switch rejections.count {
        case 0: return nil
        case 1: return "turned away the PDF found at \(rejections[0].origin), a different paper"
        default: return "turned away \(rejections.count) PDFs that were other papers"
        }
    }

    /// Result of a paper PDF download attempt.
    struct PaperDownloadResult {
        let success: Bool
        let lastError: Error?
        let metadataComplete: Bool?
        /// Step-by-step log of the download flow for debugging.
        var debugLog: [String] = []

        init(
            success: Bool,
            lastError: Error?,
            metadataComplete: Bool? = nil,
            debugLog: [String] = []
        ) {
            // This result describes PDF acquisition. Mandatory ingestion status
            // is carried independently so callers can report the metadata error
            // without treating an already-downloaded PDF as a failed download and
            // attempting to acquire or replace it again.
            self.success = success
            self.lastError = lastError
            self.metadataComplete = metadataComplete
            self.debugLog = debugLog
        }
    }

    enum PaperAIBrowserAttemptResult {
        case downloaded
        case paywalled
        /// The agent thinks the page is paywalled but had no explicit evidence
        /// to mark it; the reason is recorded on the paper, whose attention
        /// row now offers Mark as Paywalled.
        case suspectedPaywall(String)
        /// The agent found a news story or commentary, not a paper; the
        /// source has already been moved to Articles.
        case notAPaper(String)
        case cancelled
        case failed(Error)
    }

    /// Manual attachment owns the paper from this point forward. Cancel the
    /// actual browser task/service, clear queued discovery, and invalidate the
    /// attempt id so a late WebKit or model result cannot attach a second PDF.
    func cancelPaperPDFDiscovery(for articleId: String) {
        activePaperBrowserTasks.removeValue(forKey: articleId)?.cancel()
        activePaperBrowserServices.removeValue(forKey: articleId)?.cancel()
        activePaperBrowserAttemptIDs.removeValue(forKey: articleId)
        resolvingPaperPDFIds.remove(articleId)
        pendingPaperProcessingIds.remove(articleId)
        queuedPaperPDFResolutionIds.remove(articleId)
        autoFetchPaperQueue.removeAll { $0 == articleId }
        paperProcessingSteps.removeValue(forKey: articleId)
        if activePaperBrowserAttemptIDs.isEmpty {
            paperDownloadStep = ""
        }
    }

    /// Convert a source to a local-PDF paper after a PDF has been attached.
    /// Keeps the original URL as the stable source identity and stores the
    /// downloaded PDF in `localFilePath`, so future discovery can still dedup
    /// against the original scholarly URL. Callers verify `destPath` before
    /// entering this method.
    func convertPaperToLocalPDF(at idx: Int, destPath: String, doi: String?, updateDateAdded: Bool = false) {
        StudioArticle.recordExistingLocalPath(destPath)
        var updated = articles[idx]
        let oldURL = updated.url
        updated.localFilePath = destPath
        updated.sourceType = .paper
        updated.domain = "Local PDF"
        updated.prepareForPaperMetadataExtraction()
        updated.isPaywalled = false
        updated.paywallSuspicion = nil
        if updateDateAdded {
            updated.dateAdded = Date()
        }
        if let doi, !doi.isEmpty, updated.doi == nil {
            updated.doi = doi
        }
        _ = Self.finalizeRequiredPaperMetadata(for: &updated)
        articles[idx] = updated
        logger.info("Attached local PDF to paper: \(oldURL) → \(destPath)")
    }

    /// Fold `articleId` together with any paper that now shares its identity,
    /// keeping whichever side is the better copy rather than assuming the caller's
    /// row should survive. Attaching a PDF names its own winner; learning that a
    /// saved preprint was published does not — the journal record already in the
    /// library may be the one holding the PDF and the peer-reviewed metadata.
    @discardableResult
    func mergePaperIntoBestEquivalent(_ articleId: String) async -> Bool {
        guard let article = articles.first(where: { $0.id == articleId }),
              article.sourceType == .paper else { return false }
        let equivalents = articles.filter { candidate in
            candidate.id != articleId
                && candidate.sourceType == .paper
                && candidate.teamID == article.teamID
                && Self.paperDedupKeysMatch(article, candidate)
        }
        guard !equivalents.isEmpty else { return false }

        let canonical = (equivalents + [article])
            .max { Self.paperStorageScore($0) < Self.paperStorageScore($1) } ?? article
        return await mergeEquivalentPaperDuplicates(into: canonical.id)
    }

    /// When a PDF is attached to one paper row, fold equivalent URL-discovered
    /// paper rows into that user-targeted row. This prevents publisher URL
    /// variants like ScienceDirect `/abs/pii/...` from reappearing as "PDF not
    /// available" after the PDF was attached to the sibling record.
    @discardableResult
    func mergeEquivalentPaperDuplicates(
        into canonicalId: String,
        knownDuplicateIDs: Set<String>? = nil
    ) async -> Bool {
        guard let canonicalIdx = articles.firstIndex(where: { $0.id == canonicalId }),
              articles[canonicalIdx].sourceType == .paper else { return false }

        // A team library lists the learner's own sources beside the team's
        // (docs/teams-design.md, decision 19). A merge archives the duplicate,
        // and archiving a team row takes it from every member, so a duplicate
        // is only ever one from the canonical's own library.
        let canonicalPaper = articles[canonicalIdx]
        let canonicalTeamID = canonicalPaper.teamID
        let duplicates = articles.filter { candidate in
            guard candidate.id != canonicalId,
                  candidate.sourceType == .paper,
                  candidate.teamID == canonicalTeamID else { return false }
            if let knownDuplicateIDs {
                return knownDuplicateIDs.contains(candidate.id)
            }
            return Self.paperDedupKeysMatch(canonicalPaper, candidate)
        }
        guard !duplicates.isEmpty else { return false }

        var canonical = articles[canonicalIdx]
        var changedCanonical = false
        for duplicate in duplicates {
            if canonical.localFilePath == nil, let duplicatePath = duplicate.localFilePath {
                canonical.localFilePath = duplicatePath
                changedCanonical = true
            }
            if canonical.wordCount == nil, let wordCount = duplicate.wordCount {
                canonical.wordCount = wordCount
                changedCanonical = true
            }
            if canonical.artworkURL == nil, let artworkURL = duplicate.artworkURL {
                canonical.artworkURL = artworkURL
                changedCanonical = true
            }
            if canonical.isPaywalled && !duplicate.isPaywalled {
                canonical.isPaywalled = false
                changedCanonical = true
            }
            if canonical.content == nil, let content = duplicate.content {
                canonical.content = content
                changedCanonical = true
            }
            if Self.mergePaperMetadata(from: duplicate, into: &canonical) {
                changedCanonical = true
            }
        }

        if changedCanonical {
            guard await persistSource(canonical, context: "Save merged paper duplicate") else {
                return false
            }
            if let idx = articles.firstIndex(where: { $0.id == canonicalId }) {
                articles[idx] = canonical
            }
        }

        let duplicateIds = Set(duplicates.map(\.id))
        var archivedDuplicateIds = Set<String>()
        for duplicateId in duplicateIds {
            do {
                try await storage.archivePaperIdentityDuplicate(
                    duplicateId,
                    replacingWith: canonicalId
                )
                archivedDuplicateIds.insert(duplicateId)
            } catch {
                logger.error("Failed to archive duplicate paper \(duplicateId): \(error.localizedDescription)")
            }
        }
        guard !archivedDuplicateIds.isEmpty else { return false }
        articles.removeAll { archivedDuplicateIds.contains($0.id) }
        if let selectedArticleId, archivedDuplicateIds.contains(selectedArticleId) {
            self.selectedArticleId = canonicalId
        }
        logger.info("Merged \(archivedDuplicateIds.count) equivalent paper duplicate(s) into \(canonicalId)")
        return true
    }

    /// Extract a `.pdf` filename from a web URL, URL-decoded. Returns nil for
    /// non-http(s) URLs or paths that don't end in `.pdf`. Used to detect when
    /// an imported PDF matches an existing URL-based source (e.g. a thesis URL
    /// like `https://…/Final_Report%20…pdf?sequence=1`).
    static func pdfFilenameFromWebURL(_ urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        let lastComponent = url.lastPathComponent
        let decoded = lastComponent.removingPercentEncoding ?? lastComponent
        guard decoded.lowercased().hasSuffix(".pdf") else { return nil }
        return decoded
    }

    /// Attempt to download a paper PDF from a known academic URL.
    /// Converts abstract URLs to PDF URLs for supported providers (arXiv, bioRxiv, etc.),
    /// downloads the PDF to ForeverLM/Papers/, and updates the article state.
    ///
    /// Every file is held to `identity` before it is attached. A caller trying
    /// open-access copies passes the gate it built from the paper before the
    /// row took a candidate's address; without one, the row as it is now is
    /// the paper.
    ///
    /// With `replacingDerivedData`, the save that attaches an accepted PDF
    /// also clears the paper's old text and everything derived from it, in one
    /// transaction (`persistSource(replacingDerivedData:)`). Nothing is
    /// cleared for a file that is never accepted.
    func downloadPaperPDF(
        for articleId: String,
        userInitiated: Bool = true,
        forceMetadataExtractionForMissingAuthor: Bool = false,
        identity: PaperPDFIdentityGate? = nil,
        replacingDerivedData: Bool = false
    ) async -> PaperDownloadResult {
        var log: [String] = []
        func setDownloadStep(_ step: String) {
            if userInitiated {
                paperDownloadStep = step
            }
        }

        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else {
            return PaperDownloadResult(success: false, lastError: nil, debugLog: ["Article not found"])
        }
        guard articles[idx].sourceType == .paper else {
            logger.error("Refused paper download pipeline for non-paper source \(articleId)")
            return PaperDownloadResult(
                success: false,
                lastError: SourceError.fetchFailed,
                debugLog: ["Source is not a paper"]
            )
        }
        let gate = identity ?? PaperPDFIdentityGate(article: articles[idx])
        let url = articles[idx].url
        log.append("URL: \(url)")
        setDownloadStep("Downloading PDF…")
        defer {
            if userInitiated {
                paperDownloadStep = ""
            }
        }

        var pdfURL = PaperService.paperPDFURL(from: url)
        // eLife's page advertises no PDF link; its API names the file on the CDN.
        if pdfURL == nil, let elife = PaperService.eLifeArticle(from: url) {
            log.append("No direct PDF — asking eLife's API for \(elife.collection)/\(elife.id)...")
            setDownloadStep("Asking eLife for the PDF…")
            if let elifePDF = await PaperService.lookupELifePDFURL(elife) {
                log.append("eLife API found PDF: \(elifePDF)")
                pdfURL = elifePDF
            } else {
                log.append("eLife API named no PDF for \(elife.collection)/\(elife.id)")
            }
        }
        // For PMC URLs without a direct PDF URL, try PMCID-based lookup via EuropePMC
        if pdfURL == nil, let pmcid = PaperService.extractPMCID(from: url) {
            log.append("No direct PDF — trying EuropePMC for PMCID \(pmcid)...")
            setDownloadStep("Searching PubMed Central…")
            if let pmcResult = await PaperService.lookupPMCByPMCID(pmcid: pmcid) {
                // NCBI's own route first: Europe PMC's render answers apps with
                // 403 (2026-09-23), and `downloadPDF` answers NCBI's check.
                if let pmcPdfURL = pmcResult.orderedPDFURLs.first {
                    log.append("PMC PDF candidate: \(pmcPdfURL)")
                    pdfURL = pmcPdfURL
                } else if let pmcid = pmcResult.pmcid {
                    // No direct PDF, but we have PMCID — try BioC full text
                    log.append("No PDF URL from EuropePMC, trying BioC full text for \(pmcid)...")
                    if let fullText = await PaperService.fetchPMCFullText(pmcid: pmcid) {
                        log.append("BioC full text SUCCESS (\(fullText.count) chars)")
                        if let idx = articles.firstIndex(where: { $0.id == articleId }) {
                            articles[idx].content = fullText
                            articles[idx].domain = "PubMed Central"
                            articles[idx].prepareForPaperMetadataExtraction()
                            guard await persistSource(articles[idx], context: "Save PubMed Central full text") else {
                                log.append("BioC full text save FAILED")
                                return PaperDownloadResult(success: false, lastError: SourceError.fetchFailed, debugLog: log)
                            }
                            await backfillPaperMetadata(onlyIds: [articleId])
                            _ = await extractPaperMetadataWithAI(id: articleId, showToasts: userInitiated)
                            let currentArticle = articles.first(where: { $0.id == articleId })
                            logger.info("Loaded PMC full text for: \(currentArticle?.title ?? articleId)")
                            let metadataComplete = currentArticle?.hasFinishedPaperIngestion == true
                            if userInitiated, metadataComplete {
                                showToast("Full text loaded from PubMed Central")
                            }
                            // Full text is useful reader/AI content, but it is not
                            // a PDF attachment. Keep resolving below instead of
                            // reporting a successful PDF download and leaving the
                            // paper in "needs attention".
                            log.append("BioC full text stored; continuing PDF resolution")
                        }
                    } else {
                        log.append("BioC full text FAILED")
                    }
                }
            } else {
                log.append("EuropePMC: no entry found for \(pmcid)")
            }
        }
        // Generic fallback: fetch the web page and look for citation_pdf_url meta tag.
        // This covers any publisher that follows Google Scholar's metadata conventions.
        if pdfURL == nil {
            log.append("No known pattern — fetching page to extract citation_pdf_url…")
            setDownloadStep("Scanning page for PDF link…")
            if let metaPdfURL = await PaperService.extractPDFURLFromWebPage(at: url) {
                log.append("Found PDF via meta tag: \(metaPdfURL)")
                pdfURL = metaPdfURL
            } else {
                log.append("No PDF meta tag found on page")
            }
        }
        guard let pdfURL else {
            log.append("Could not derive PDF URL from article URL")
            return PaperDownloadResult(success: false, lastError: SourceError.invalidURL, debugLog: log)
        }
        log.append("PDF URL: \(pdfURL)")

        let papersDir = (knowledgeBasePath as NSString).appendingPathComponent("Papers")
        await Self.ensureDirectoryExists(at: papersDir)

        let initialDOI = Self.paperDOI(for: articles[idx], sourceURL: pdfURL)
        let filename = Self.preferredPaperFilename(doi: initialDOI, url: url)
        var destPath = (papersDir as NSString).appendingPathComponent(filename)
        log.append("Dest: \(filename)")

        /// Attach the PDF at `destPath` once it is this paper, and run the
        /// metadata pass. `candidateURL` is where it was downloaded from, nil
        /// for a file that was already there. Another paper's file is thrown
        /// (`PaperPDFIdentityGate.admit`) before the Paper Metadata model can
        /// read it, so each step's catch below goes on to the next candidate.
        func attachDownloadedPDF(
            from candidateURL: String?,
            step: String,
            saveContext: String,
            successToast: String = "PDF downloaded",
            route: String
        ) async throws -> PaperDownloadResult {
            try await gate.admit(
                pdfAt: destPath,
                from: candidateURL ?? URL(fileURLWithPath: destPath).absoluteString,
                keepsRejectedFile: candidateURL == nil
            )
            log.append("\(step): SUCCESS")
            if let idx = articles.firstIndex(where: { $0.id == articleId }) {
                let doi = await Self.paperDOIOffMain(
                    for: articles[idx],
                    attachedPDFPath: destPath,
                    sourceURL: candidateURL ?? pdfURL
                )
                convertPaperToLocalPDF(at: idx, destPath: destPath, doi: doi, updateDateAdded: userInitiated)
                guard await persistSource(
                    articles[idx],
                    context: saveContext,
                    replacingDerivedData: replacingDerivedData
                ) else {
                    log.append("\(step): DB save FAILED")
                    return PaperDownloadResult(success: false, lastError: SourceError.fetchFailed, debugLog: log)
                }
                let metadataComplete = await enrichPaperMetadataAfterPDFAttachment(
                    articleId: articleId,
                    userInitiated: userInitiated,
                    forceAIForMissingAuthor: forceMetadataExtractionForMissingAuthor
                )
                logger.info("Downloaded paper PDF \(route, privacy: .public): \((destPath as NSString).lastPathComponent)")
                if userInitiated {
                    showToast(metadataComplete ? successToast : "PDF downloaded, but AI metadata extraction failed")
                }
            }
            return PaperDownloadResult(
                success: true,
                lastError: nil,
                metadataComplete: articles.first(where: { $0.id == articleId })?.hasFinishedPaperIngestion,
                debugLog: log
            )
        }

        // Don't re-download if file already exists
        if await Self.fileExists(at: destPath) {
            if await Self.canOpenPDF(at: destPath) {
                log.append("File already exists — using cached")
                do {
                    return try await attachDownloadedPDF(
                        from: nil,
                        step: "Cached file",
                        saveContext: "Save cached PDF attachment",
                        route: "from the Papers folder"
                    )
                } catch {
                    // Two papers can share a file name (DOIs cut to the same
                    // prefix did), so another paper's file here may be another
                    // row's PDF: it stays, and this paper downloads beside it.
                    destPath = await Self.unusedPaperPath(besides: destPath)
                    log.append("Cached file: FAILED — \(error.localizedDescription); downloading to \((destPath as NSString).lastPathComponent)")
                }
            } else {
                log.append("Cached file is not a readable PDF — removing and retrying")
                await Self.removeItem(at: destPath)
            }
        }

        var lastError: Error?

        // Step 1: Try unauthenticated download
        let pdfSource = Self.pdfSourceLabel(from: pdfURL)
        setDownloadStep("Downloading from \(pdfSource)…")
        log.append("Step 1: Unauthenticated download from \(pdfSource)...")
        do {
            try await sourceService.downloadPDF(from: pdfURL, to: destPath)
            guard await Self.canOpenPDF(at: destPath) else {
                await Self.removeItem(at: destPath)
                throw SourceError.pdfReadFailed
            }
            return try await attachDownloadedPDF(
                from: pdfURL,
                step: "Step 1",
                saveContext: "Save downloaded PDF",
                route: "from \(pdfSource)"
            )
        } catch {
            lastError = error
            log.append("Step 1: FAILED — \(error.localizedDescription)")
            logger.warning("PDF download failed for \(pdfURL): \(error.localizedDescription)")
            await Self.removeItem(at: destPath)

            if ScienceDirectService.isScienceDirectURL(pdfURL) || ScienceDirectService.isScienceDirectURL(url) {
                log.append("Step 1a: Trying authenticated ScienceDirect browser session...")
                setDownloadStep("Trying authenticated ScienceDirect session…")
                do {
                    try await ScienceDirectService.downloadPDFWithAuthenticatedWebSession(
                        from: pdfURL,
                        to: destPath,
                        label: articles.first(where: { $0.id == articleId })?.title
                    )
                    guard await Self.canOpenPDF(at: destPath) else {
                        await Self.removeItem(at: destPath)
                        throw SourceError.pdfReadFailed
                    }
                    return try await attachDownloadedPDF(
                        from: pdfURL,
                        step: "Step 1a",
                        saveContext: "Save authenticated ScienceDirect PDF",
                        successToast: "PDF downloaded from ScienceDirect",
                        route: "from ScienceDirect with the authenticated browser session"
                    )
                } catch {
                    lastError = error
                    log.append("Step 1a: FAILED — \(error.localizedDescription)")
                    logger.warning("Authenticated ScienceDirect download failed: \(error.localizedDescription)")
                    await Self.removeItem(at: destPath)
                }
            }

            // Step 1c: the publisher answered ForeverLM's own client with a
            // page — a bot check, or a refusal aimed at anything that is not a
            // browser — while the reader holds a session for the host. Ask
            // again as the reader: a hidden web view on the reader's data
            // store downloads the file, and when a bare request for it is
            // bounced (nature.com sends `<id>.pdf` back to the article page)
            // opens the paper's page and clicks its Download PDF control, the
            // way the reader's own button does. The file goes through the same
            // attach path as a PDF the reader downloaded.
            if let lastError, let pdfURLValue = URL(string: pdfURL) {
                let readerCookies = await InAppWebSession.cookies(for: pdfURLValue)
                switch WebSessionPDFDownload.decision(
                    pdfURL: pdfURL,
                    after: lastError,
                    cookies: readerCookies,
                    paperHasPDF: paperHasLocalPDF(articleId)
                ) {
                case .attempt:
                    log.append("Step 1c: Downloading through the reader's web session (\(readerCookies.count) cookies for \(pdfURLValue.host ?? pdfSource))...")
                    setDownloadStep("Downloading from \(pdfSource) as the reader…")
                    do {
                        let data = try await WebSessionPDFDownloader.download(
                            pdfURLValue,
                            landingPage: URL(string: url) ?? WebSessionPDFDownloader.landingPageURL(forPDF: pdfURLValue)
                        )
                        try await attachDownloadedPDFData(
                            to: articleId,
                            data: data,
                            sourceURL: pdfURLValue,
                            userInitiated: userInitiated,
                            forceAIForMissingAuthor: forceMetadataExtractionForMissingAuthor,
                            identity: gate,
                            destinationPath: destPath,
                            replacingDerivedData: replacingDerivedData
                        )
                        guard paperHasLocalPDF(articleId) else { throw SourceError.pdfReadFailed }
                        log.append("Step 1c: SUCCESS")
                        let current = articles.first(where: { $0.id == articleId })
                        PaperIngestionDiagnostics.recordWebSessionPDFDownload(
                            sourceID: articleId,
                            title: current?.title ?? "",
                            url: pdfURL
                        )
                        logger.info("Downloaded paper PDF through the reader's web session: \(pdfURL)")
                        if userInitiated {
                            let metadataComplete = current?.hasFinishedPaperIngestion == true
                            showToast(metadataComplete ? "PDF downloaded" : "PDF downloaded, but AI metadata extraction failed")
                        }
                        return PaperDownloadResult(
                            success: true,
                            lastError: nil,
                            metadataComplete: current?.hasFinishedPaperIngestion,
                            debugLog: log
                        )
                    } catch {
                        // The publisher's own answer stays the recorded failure:
                        // a wall met twice is the same wall.
                        log.append("Step 1c: FAILED — \(error.localizedDescription)")
                        logger.warning("Web-session PDF download failed for \(pdfURL): \(error.localizedDescription)")
                    }
                case .skipped(let reason):
                    log.append("Step 1c: Skipped — \(reason)")
                }
            }

            // For DOI links with 10.1101/ prefix, the paper might be on medRxiv instead of bioRxiv.
            if url.lowercased().contains("doi.org/10.1101/"), pdfURL.contains("biorxiv.org") {
                let medrxivURL = pdfURL.replacingOccurrences(of: "biorxiv.org", with: "medrxiv.org")
                log.append("Step 1b: Trying medRxiv fallback...")
                do {
                    try await sourceService.downloadPDF(from: medrxivURL, to: destPath)
                    guard await Self.canOpenPDF(at: destPath) else {
                        await Self.removeItem(at: destPath)
                        throw SourceError.pdfReadFailed
                    }
                    return try await attachDownloadedPDF(
                        from: medrxivURL,
                        step: "Step 1b",
                        saveContext: "Save downloaded PDF",
                        route: "from the medRxiv fallback"
                    )
                } catch {
                    lastError = error
                    log.append("Step 1b: FAILED — \(error.localizedDescription)")
                    logger.warning("medRxiv fallback also failed: \(error.localizedDescription)")
                    await Self.removeItem(at: destPath)
                }
            }

            log.append("Step 2: Scanning article page for an alternate PDF link...")
            setDownloadStep("Scanning page for PDF link…")
            if let alternatePDFURL = await PaperService.extractPDFURLFromWebPage(at: url),
               alternatePDFURL != pdfURL {
                log.append("Step 2: Found alternate PDF URL: \(alternatePDFURL)")
                do {
                    try await sourceService.downloadPDF(from: alternatePDFURL, to: destPath)
                    guard await Self.canOpenPDF(at: destPath) else {
                        await Self.removeItem(at: destPath)
                        throw SourceError.pdfReadFailed
                    }
                    return try await attachDownloadedPDF(
                        from: alternatePDFURL,
                        step: "Step 2",
                        saveContext: "Save downloaded alternate PDF",
                        route: "from the article page's alternate link"
                    )
                } catch {
                    lastError = error
                    log.append("Step 2: FAILED — \(error.localizedDescription)")
                    logger.warning("Alternate PDF download failed for \(alternatePDFURL): \(error.localizedDescription)")
                    await Self.removeItem(at: destPath)
                }
            } else {
                log.append("Step 2: No alternate PDF link found")
            }
            return PaperDownloadResult(success: false, lastError: lastError, debugLog: log)
        }
    }

    /// Start a background pass that tries to resolve every non-paywalled paper
    /// that still needs PDF attention. The command returns immediately so the
    /// sidebar and reader stay usable while network downloads continue.
    func downloadMissingPaperPDFs() {
        if missingPaperPDFDownloadTask != nil || isResolvingMissingPaperPDFs {
            showToast("Already checking papers")
            return
        }

        // Recover papers left stuck in `.fetching` by a download that was
        // interrupted (app quit or crashed mid-fetch). They're hidden from the
        // visible attention list and badge so an in-flight download can't strand
        // the badge, but this manual pass is the safe place to retry them: the
        // guard above means no batch is running, and `isFetchingContent` rules out
        // an active single-paper download whose row also sits in `.fetching`.
        let stuckIds = isFetchingContent ? [] : papersStuckFetchingPDF.map(\.id)

        var seen = Set<String>()
        let missingIds = (papersNeedingPDFAttention.map(\.id) + stuckIds)
            .filter { seen.insert($0).inserted }
        guard !missingIds.isEmpty else {
            let waiting = unavailableRecordedPDFCount
            showToast(
                waiting > 0
                    ? "No papers need PDF attention. \(waiting) PDFs are waiting for iCloud to download them."
                    : "No papers need PDF attention"
            )
            return
        }

        isResolvingMissingPaperPDFs = true
        paperPDFResolutionKind = .missingPDFs
        isStoppingPaperPDFResolution = false
        paperDownloadStep = "Checking \(missingIds.count) paper\(missingIds.count == 1 ? "" : "s") in background…"
        missingPaperPDFDownloadTask = Task { [weak self] in
            await self?.runMissingPaperPDFDownload(for: missingIds, recovering: stuckIds)
        }
    }

    /// Which batch owns the in-flight PDF-resolution pass. Both batches share
    /// `missingPaperPDFDownloadTask`, so the sidebar needs this to put Cancel on
    /// the button the learner actually pressed.
    enum PaperPDFResolutionKind {
        case missingPDFs
        case paywallRecheck
    }

    /// Ask the running batch to stop. Deliberately cooperative: the paper being
    /// worked on right now finishes its download/cleanup/persist sequence, and
    /// the loop then breaks instead of starting the next one. Hard-cancelling the
    /// task would abort mid-persist and could strand a row in `.fetching`.
    /// The per-paper phase captions keep writing to `paperDownloadStep` while the
    /// current paper finishes, so the stopping state is published through this
    /// flag and the sidebar renders its own caption from it.
    func stopPaperPDFResolution() {
        guard isResolvingMissingPaperPDFs, !isStoppingPaperPDFResolution else { return }
        isStoppingPaperPDFResolution = true
    }

    /// Revisit papers the learner previously marked paywalled. Unlike the normal
    /// missing-PDF pass, this deliberately includes paywall markers and keeps them
    /// in place unless a readable PDF is successfully attached. The command is
    /// manual: open-access availability changes over time, but repeatedly spending
    /// network/AI work in the background would be surprising.
    func recheckPaywalledPaperPDFs() {
        if missingPaperPDFDownloadTask != nil || isResolvingMissingPaperPDFs {
            showToast("Already checking papers")
            return
        }

        let paywalledIds = paywalledPapersEligibleForRecheck.map(\.id)
        guard !paywalledIds.isEmpty else {
            showToast("No paywalled papers to recheck")
            return
        }

        isResolvingMissingPaperPDFs = true
        paperPDFResolutionKind = .paywallRecheck
        isStoppingPaperPDFResolution = false
        paperDownloadStep = "Rechecking \(paywalledIds.count) paywalled paper\(paywalledIds.count == 1 ? "" : "s")…"
        missingPaperPDFDownloadTask = Task { [weak self] in
            await self?.runPaywalledPaperRecheck(for: paywalledIds)
        }
    }

    func runPaywalledPaperRecheck(for paperIds: [String]) async {
        logger.info("Rechecking \(paperIds.count) paywalled paper(s) for open-access copies")
        var recovered = 0
        var stillPaywalled = 0
        var movedToArticles = 0
        var failed = 0
        var skippedBrowserChecks = 0
        var turnedAway: [PaperPDFIdentityMismatchError] = []
        var stoppedAfter: Int?
        let browserConfig = KeychainService.resolveConfig(for: .paperBrowserAgent)

        defer {
            paperDownloadStep = ""
            isResolvingMissingPaperPDFs = false
            paperPDFResolutionKind = nil
            isStoppingPaperPDFResolution = false
            missingPaperPDFDownloadTask = nil
        }

        for (index, articleId) in paperIds.enumerated() {
            if isStoppingPaperPDFResolution {
                stoppedAfter = index
                break
            }
            paperDownloadStep = "Rechecking paper \(index + 1)/\(paperIds.count)…"
            let identity = articles.first(where: { $0.id == articleId }).map { PaperPDFIdentityGate(article: $0) }
            let outcome = await resolveMissingPaperPDF(
                for: articleId,
                browserConfig: browserConfig,
                recheckingPaywall: true,
                identity: identity,
                onReachingBrowserStep: { [weak self] in
                    self?.paperDownloadStep = "Browsing for paper \(index + 1)/\(paperIds.count)…"
                }
            )
            turnedAway += identity?.rejections ?? []
            switch outcome {
            case .downloaded:
                recovered += 1
            case .textRecovered:
                recovered += 1
            case .paywalled, .suspectedPaywall:
                stillPaywalled += 1
            case .reclassifiedAsArticle:
                movedToArticles += 1
            case .failed:
                failed += 1
            case .skippedNoBrowserConfig:
                skippedBrowserChecks += 1
            }
        }

        var parts = ["recovered \(recovered)"]
        if stillPaywalled > 0 { parts.append("\(stillPaywalled) still paywalled") }
        if movedToArticles > 0 { parts.append("moved \(movedToArticles) to Articles") }
        if failed > 0 { parts.append("\(failed) checks failed") }
        if skippedBrowserChecks > 0 { parts.append("\(skippedBrowserChecks) need an AI browser model") }
        if let turnedAwaySummary = Self.turnedAwayPDFsSummary(turnedAway) { parts.append(turnedAwaySummary) }
        if let stoppedAfter {
            showToast(
                "Paywall recheck stopped after \(stoppedAfter) of \(paperIds.count) papers: \(parts.joined(separator: ", "))"
            )
        } else {
            showToast("Paywall recheck complete: \(parts.joined(separator: ", "))")
        }
    }

    func runMissingPaperPDFDownload(for missingIds: [String], recovering stuckIds: [String] = []) async {
        // Un-stick papers left in `.fetching` before retrying them, so that even a
        // failed retry leaves them back in `.ready` — visible in the attention list
        // and counted by the badge again — instead of orphaned. Persist through
        // storage so the recovery survives relaunch and keeps CloudKit sync
        // metadata consistent. `downloadPaperPDF` never re-enters `.fetching` on
        // this path, so a failed attempt cannot re-strand them.
        for id in Set(stuckIds) {
            guard let idx = articles.firstIndex(where: { $0.id == id }),
                  articles[idx].state == .fetching else { continue }
            articles[idx].prepareForPaperMetadataExtraction()
            _ = await persistSource(articles[idx], context: "Recover stuck paper download state")
        }

        logger.info("Checking \(missingIds.count) paper(s) needing PDF attention")
        var downloaded = 0
        var textRecovered = 0
        var incompleteMetadata = 0
        var paywalled = 0
        var suspectedPaywall = 0
        var movedToArticles = 0
        var failed = 0
        let browserConfig = KeychainService.resolveConfig(for: .paperBrowserAgent)
        var skippedBrowserChecks = 0
        var turnedAway: [PaperPDFIdentityMismatchError] = []
        var stoppedAfter: Int?

        defer {
            paperDownloadStep = ""
            isResolvingMissingPaperPDFs = false
            paperPDFResolutionKind = nil
            isStoppingPaperPDFResolution = false
            missingPaperPDFDownloadTask = nil
        }

        for (i, articleId) in missingIds.enumerated() {
            if isStoppingPaperPDFResolution {
                stoppedAfter = i
                break
            }
            paperDownloadStep = "Trying paper \(i + 1)/\(missingIds.count)…"

            let identity = articles.first(where: { $0.id == articleId }).map { PaperPDFIdentityGate(article: $0) }
            let outcome = await resolveMissingPaperPDF(
                for: articleId,
                browserConfig: browserConfig,
                identity: identity,
                onReachingBrowserStep: { [weak self] in
                    self?.paperDownloadStep = "Checking page \(i + 1)/\(missingIds.count)…"
                }
            )
            turnedAway += identity?.rejections ?? []
            switch outcome {
            case .downloaded(metadataComplete: let metadataComplete):
                downloaded += 1
                if !metadataComplete {
                    incompleteMetadata += 1
                }
            case .textRecovered(metadataComplete: let metadataComplete):
                textRecovered += 1
                if !metadataComplete {
                    incompleteMetadata += 1
                }
            case .paywalled:
                paywalled += 1
            case .suspectedPaywall:
                suspectedPaywall += 1
            case .reclassifiedAsArticle:
                movedToArticles += 1
            case .failed:
                failed += 1
            case .skippedNoBrowserConfig:
                skippedBrowserChecks += 1
                failed += 1
            }
        }

        var parts: [String] = []
        if downloaded > 0 {
            parts.append("downloaded \(downloaded) PDF\(downloaded == 1 ? "" : "s")")
        }
        if textRecovered > 0 {
            parts.append("recovered text for \(textRecovered) paper\(textRecovered == 1 ? "" : "s")")
        }
        if incompleteMetadata > 0 {
            parts.append("\(incompleteMetadata) still missing metadata")
        }
        if paywalled > 0 {
            parts.append("marked \(paywalled) paywalled")
        }
        if suspectedPaywall > 0 {
            parts.append("\(suspectedPaywall) look\(suspectedPaywall == 1 ? "s" : "") paywalled (Mark as Paywalled is on the row)")
        }
        if movedToArticles > 0 {
            parts.append("moved \(movedToArticles) to Articles")
        }
        if failed > 0 {
            parts.append("\(failed) still need attention")
        }
        if let turnedAwaySummary = Self.turnedAwayPDFsSummary(turnedAway) {
            parts.append(turnedAwaySummary)
        }
        if parts.isEmpty {
            parts.append("no changes")
        }
        let suffix = skippedBrowserChecks > 0 ? ". Set an API key to check paywalls." : ""
        if let stoppedAfter {
            showToast(
                "Paper check stopped after \(stoppedAfter) of \(missingIds.count) papers: \(parts.joined(separator: ", "))\(suffix)"
            )
        } else {
            showToast("Paper check complete: \(parts.joined(separator: ", "))\(suffix)")
        }
    }

    func paperHasLocalPDF(_ articleId: String) -> Bool {
        articles.first(where: { $0.id == articleId })?.resolvedPDFPath != nil
    }

    func paperIsMarkedPaywalled(_ articleId: String) -> Bool {
        guard let article = articles.first(where: { $0.id == articleId }) else { return false }
        return article.hasPaywallMarker
    }

    enum MissingPaperPDFOutcome {
        case downloaded(metadataComplete: Bool)
        case textRecovered(metadataComplete: Bool)
        case paywalled
        /// Still needs attention, but its row now offers Mark as Paywalled
        /// with the AI browser's reason behind it.
        case suspectedPaywall
        /// Not a paper after all; it now lives in Articles and left the
        /// attention list for good.
        case reclassifiedAsArticle
        case failed
        /// Reached the AI-browser step but no browser API key is configured.
        case skippedNoBrowserConfig
    }

}
