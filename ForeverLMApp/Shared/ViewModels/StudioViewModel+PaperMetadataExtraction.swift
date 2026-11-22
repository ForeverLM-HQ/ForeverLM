// Extracting paper and article metadata, titles and authors.

import Foundation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif
import Darwin

extension StudioViewModel {

    /// Extract authors for all articles that don't have one yet using an LLM.
    func extractMissingArticleAuthors() async {
        guard let config = KeychainService.resolveConfig(for: .articleMetadata) else {
            showToast("Set an API key in Settings first")
            return
        }

        let missing = articles.filter {
            ($0.sourceType == .article || $0.sourceType == .unclassified)
            && ($0.author == nil || $0.author?.isEmpty == true)
            && $0.state == .ready
        }
        guard !missing.isEmpty else {
            showToast("All articles already have authors")
            return
        }

        logger.info("Extracting authors for \(missing.count) article(s)")
        var succeeded = 0
        for (i, article) in missing.enumerated() {
            paperDownloadStep = "Extracting author \(i + 1)/\(missing.count)…"
            var content = article.content
            if content == nil { content = await storage.loadSourceContent(article.id) }
            let result = await aiService.fixArticleTitle(
                source: AIUsageSource(source: article),
                currentTitle: article.title,
                url: article.url,
                content: content,
                config: config
            )
            if let result, let author = result.author,
               let idx = articles.firstIndex(where: { $0.id == article.id }) {
                var updated = articles[idx]
                updated.author = author
                if await persistSource(updated, context: "Save extracted author") {
                    // Re-resolve by id: persistSource suspended, so `idx` may be stale.
                    if let writeIdx = articles.firstIndex(where: { $0.id == article.id }) {
                        articles[writeIdx] = updated
                    }
                    succeeded += 1
                }
            }
        }
        paperDownloadStep = ""
        showToast("Extracted \(succeeded) author\(succeeded == 1 ? "" : "s")")
    }

    func updateArticleAuthor(id: String, author: String) async {
        guard let idx = articles.firstIndex(where: { $0.id == id }) else { return }
        let value = author.isEmpty ? nil : author
        var article = articles[idx]
        article.author = value
        if await persistSource(article, context: "Save author") {
            if let idx2 = articles.firstIndex(where: { $0.id == id }) {
                articles[idx2] = article
            }
            await completePaperIngestionAfterManualMetadata(id: id)
        }
    }

    /// Use an LLM to extract author, journal, and year from the paper's first PDF page.
    func extractPaperMetadataWithAI(id: String) async {
        _ = await extractPaperMetadataWithAI(id: id, showToasts: true)
    }

    /// - Parameter metadataOnly: Return as soon as the one front-matter call has
    ///   been applied and attested. The full-document cleanup moves to a
    ///   background task and the DOI title lookup is skipped, so Edit Details
    ///   waits for one short model call instead of the whole pipeline.
    /// - Parameter progressPrefix: Pass a non-nil value to publish this method's
    ///   own phase captions into `paperDownloadStep`. An empty string reports the
    ///   phase alone; a non-empty one prefixes it (batch callers use their
    ///   "3/7" counter). `nil` leaves `paperDownloadStep` untouched.
    @discardableResult
    func extractPaperMetadataWithAI(
        id: String,
        showToasts: Bool,
        progressPrefix: String? = nil,
        metadataOnly: Bool = false
    ) async -> Bool {
        guard let idx = articles.firstIndex(where: { $0.id == id }),
              articles[idx].sourceType == .paper else { return false }
        guard !extractingPaperMetadataIds.contains(id) else { return false }
        guard let config = KeychainService.resolveConfig(for: .paperMetadata) else {
            // "Not configured" is true of an absent account and of nothing
            // else. When the blocker is a stale model route, an empty balance,
            // or unaccepted background usage, say that instead: the generic
            // sentence sent a signed-in learner to the sign-in sheet for a
            // problem only the model picker or AI Usage can fix.
            let reason = KeychainService.backgroundAIUnavailableMessage(for: .paperMetadata)
                ?? "Paper Metadata AI is not configured."
            await failPaperMetadataExtraction(
                id: id,
                message: "Paper ingestion failed: \(reason)",
                showToasts: showToasts
            )
            return false
        }
        extractingPaperMetadataIds.insert(id)
        let previousProcessingStep = paperProcessingSteps[id]
        defer {
            extractingPaperMetadataIds.remove(id)
            if let previousProcessingStep {
                paperProcessingSteps[id] = previousProcessingStep
            } else {
                paperProcessingSteps.removeValue(forKey: id)
            }
            // The restored caption belongs to whichever pass published it. If
            // that pass has already exited, nothing owns the row and the caption
            // must go with it.
            dropPaperProcessingStepIfIdle(id)
        }

        // A manual or queued retry starts from a persisted terminal error. Clear
        // that old result before the new request begins so the sidebar never
        // presents the same paper as both actively processing and already failed.
        // Persisting the queued state also makes an interrupted retry eligible for
        // the ordinary startup metadata sweep instead of preserving a stale error.
        if articles[idx].state == .error || articles[idx].errorMessage != nil {
            var retryingArticle = articles[idx]
            retryingArticle.prepareForPaperMetadataExtraction()
            guard await persistSource(
                retryingArticle,
                context: "Save paper metadata retry state",
                showErrorToast: showToasts
            ) else { return false }
            guard let latestIdx = articles.firstIndex(where: { $0.id == id }) else { return false }
            articles[latestIdx] = retryingArticle
        }

        guard let currentArticle = articles.first(where: { $0.id == id }) else { return false }
        let firstPageText = await Self.frontMatterTextOffMain(for: currentArticle)
        guard !firstPageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await failPaperMetadataExtraction(
                id: id,
                message: "Paper ingestion failed: no readable PDF or full-text paper content was available for AI metadata extraction.",
                showToasts: showToasts
            )
            return false
        }

        reportPaperIngestionStep(id, progressPrefix, "Extracting paper metadata…")

        // The registered title is only a glyph repair for the model's title, so
        // it is asked for beside the model call, not after it: Crossref alone can
        // take several seconds. The DOI comes from the row, its address, or the
        // front matter's own text, which the model does not need to have read.
        let candidateDOI = Self.paperDOI(for: currentArticle)
            ?? Self.extractDOIFromText(firstPageText)
        let registeredTitleLookup: Task<String?, Never>? = metadataOnly || candidateDOI == nil
            ? nil
            : Task { await PaperService.registeredTitleIfKnown(forDOI: candidateDOI) }
        defer { registeredTitleLookup?.cancel() }

        let maximumAttempts = 3
        var attemptsMade = 0
        var result: AIService.PaperMetadataResult?
        var lastError: Error?
        var metadataMaxTokens = AIService.paperMetadataMaxTokens
        for attempt in 1...maximumAttempts {
            guard !Task.isCancelled,
                  let currentArticle = articles.first(where: { $0.id == id }) else { return false }
            attemptsMade = attempt
            do {
                result = try await aiService.extractPaperMetadata(
                    source: AIUsageSource(source: currentArticle),
                    url: currentArticle.url,
                    title: currentArticle.title,
                    firstPageText: firstPageText,
                    maxTokens: metadataMaxTokens,
                    config: config
                )
                break
            } catch {
                lastError = error
                logger.warning(
                    "Paper metadata extraction attempt \(attempt)/\(maximumAttempts) failed for \(id) using \(config.provider.shortName): \(error.localizedDescription)"
                )
                PaperIngestionDiagnostics.recordAttempt(
                    sourceID: id,
                    provider: config.provider.shortName,
                    attempt: attempt,
                    maximumAttempts: maximumAttempts,
                    message: error.localizedDescription
                )
                // A reasoning model that spent its whole output ceiling thinking
                // answers within a larger one.
                if case AIError.outputTokenLimit = error,
                   let raised = AIService.paperMetadataRaisedMaxTokens(after: metadataMaxTokens) {
                    metadataMaxTokens = raised
                    continue
                }
                guard attempt < maximumAttempts,
                      AITransientErrorClassifier.isTransient(error) else { break }
                let retryAfter = AITransientErrorClassifier.retryAfterSeconds(error) ?? 0
                guard retryAfter <= AITransientErrorClassifier.maximumRetryAfterWait else { break }
                let delay = min(
                    max(Double(attempt), retryAfter),
                    AITransientErrorClassifier.maximumRetryAfterWait
                )
                try? await Task.sleep(for: .seconds(delay))
            }
        }

        // The first pages did not name everything. A title page that prints no
        // venue, or a cover sheet ahead of the real one, leaves fields the next
        // pages (a running header, a footer's "Published in", a citation line)
        // often carry. One longer look fills only those gaps; it is skipped when
        // it would hand the model nothing it has not already seen.
        if let first = result,
           first.title == nil || first.author == nil || first.journal == nil || first.year == nil,
           let latest = articles.first(where: { $0.id == id }) {
            let longer = await Self.frontMatterTextOffMain(
                for: latest,
                maximumPages: Self.paperLongLookMaximumPages,
                minimumCharacters: Self.paperLongLookCharacters
            )
            if longer.count > min(firstPageText.count, 6000) + 200 {
                reportPaperIngestionStep(id, progressPrefix, "Reading further for paper metadata…")
                let secondLook = await loggedRead("paper metadata from a longer look") {
                    try await aiService.extractPaperMetadata(
                        source: AIUsageSource(source: latest),
                        url: latest.url,
                        title: latest.title,
                        firstPageText: longer,
                        characterLimit: Self.paperLongLookCharacters,
                        config: config
                    )
                }
                if let second = secondLook {
                    result = AIService.PaperMetadataResult(
                        title: first.title ?? second.title,
                        author: first.author ?? second.author,
                        journal: first.journal ?? second.journal,
                        year: first.year ?? second.year,
                        doi: first.doi ?? second.doi
                    )
                }
            }
        }

        guard let result else {
            let detail = lastError?.localizedDescription ?? "unknown error"
            let attemptLabel = attemptsMade == 1 ? "attempt" : "attempts"
            await failPaperMetadataExtraction(
                id: id,
                message: "Paper ingestion failed: Paper Metadata AI (\(config.provider.shortName)) failed after \(attemptsMade) \(attemptLabel): \(detail)",
                showToasts: showToasts
            )
            return false
        }

        // The model read the title off the PDF's text, and PDF text drops a
        // glyph its font cannot map (J Neurosci's "α-Ketoglutarate" arrived as
        // "-Ketoglutarate"). The title the DOI is registered under is where
        // the character survives; its lookup has been running since before the
        // model call, so this wait is normally already over. A DOI only the
        // model found is not looked up: the repair never holds the row back.
        // It is given two seconds past the model's answer and then left behind,
        // so a slow catalog cannot hold the row.
        let registeredTitle: String?
        if let registeredTitleLookup {
            registeredTitle = await withTaskGroup(of: String?.self) { group in
                group.addTask { await registeredTitleLookup.value }
                group.addTask {
                    try? await Task.sleep(for: .seconds(2))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
        } else {
            registeredTitle = nil
        }

        guard let idx = articles.firstIndex(where: { $0.id == id }) else { return false }
        var article = articles[idx]
        _ = Self.applyExtractedPaperMetadata(
            result,
            to: &article,
            overwriteTitle: true,
            registeredTitle: registeredTitle
        )
        // A field the document does not print is a blank, not a failure. The
        // paper ingests on whatever the extractor resolved — a preprint with no
        // venue, an unsigned editorial, a thesis with no year — and the blank
        // stays editable in Edit Details. Only a result that resolved nothing at
        // all is treated as an extraction that did not happen.
        guard article.hasAttestablePaperMetadata else {
            let missing = article.missingRequiredPaperMetadataFields

            // An unusable bibliography says nothing about the document's text.
            // Skipping cleanup here meant the paper was stored with no canonical
            // text at all: unsearchable on the Mac, and on iOS a source that
            // offered Listen and could only report that it was still preparing.
            // Cleanup is independent of the metadata gate, so run it before
            // recording the failure. Already-cleaned text is left alone — this
            // path is re-entered on every launch until the learner fills the
            // fields in.
            if !metadataOnly, !article.hasCompletedPaperContentCleanup {
                let cleanupError = await installCanonicalPaperContent(
                    on: &article,
                    progressPrefix: progressPrefix
                )
                if let cleanupError {
                    logger.error(
                        "Paper content cleanup failed for \(id) while its metadata was incomplete: \(cleanupError.localizedDescription)"
                    )
                }
            }

            // One save for the partial metadata, the canonical text, and the
            // failure. The Listen queue reads the source's state in the same
            // transaction that writes its content, so splitting the failure into
            // a second write would enqueue nothing.
            let message = StudioArticle.paperMetadataIncompleteMessage(missing: missing)
            article.failPaperIngestionMetadata(message)
            if await persistSource(
                article,
                context: "Save partial paper metadata",
                showErrorToast: false
            ) {
                article.discardPersistedPaperContentFromMemory()
                if let partialIdx = articles.firstIndex(where: { $0.id == id }) {
                    articles[partialIdx] = article
                }
                reportPaperMetadataFailure(id: id, message: message, showToasts: showToasts)
            } else {
                // The combined save did not commit. Record the failure on its own
                // so the row never stays silently mid-extraction.
                await failPaperMetadataExtraction(
                    id: id,
                    message: message,
                    showToasts: showToasts
                )
            }
            return false
        }

        // Metadata is its own durable stage. Attest it before the independent
        // full-document cleanup call so a cleanup failure cannot be mislabeled
        // as an empty metadata response or cause a duplicate metadata charge.
        guard article.attestPaperMetadataExtractionAfterLLM() else { return false }

        // Publish the resolved title/author/venue/year now, before Source Content
        // Cleanup below. Cleanup is a full-document model pass and can take time;
        // holding these fields until it returns left the
        // sidebar showing a bare domain long after the real title was known. The
        // source stays out of `.ready` — only `completePaperMetadataExtractionAfterLLM()`
        // admits it — so this publishes display metadata, not ingestion success.
        if await persistSource(
            article,
            context: "Save extracted paper metadata",
            showErrorToast: false,
            syncImmediately: true
        ),
           let metadataIdx = articles.firstIndex(where: { $0.id == id }) {
            articles[metadataIdx] = article
        }

        if metadataOnly {
            if !article.hasCompletedPaperContentCleanup, !processingPaperIDs.contains(id) {
                pendingPaperProcessingIds.insert(id)
                reportPaperIngestionStep(id, nil, "Cleaning up paper text…")
                Task {
                    defer {
                        pendingPaperProcessingIds.remove(id)
                        paperProcessingSteps.removeValue(forKey: id)
                    }
                    guard !Task.isCancelled else { return }
                    await cleanUpPaperContentAfterManualMetadata(id: id, showToasts: false)
                }
            }
            if showToasts { showToast("Metadata saved") }
            return true
        }

        // Cleanup is a full-document model pass that takes minutes on a free
        // model. The paper is readable (its PDF or page) once its metadata is
        // in, so the pass goes to the durable cleanup queue instead of holding
        // the row in Processing — and every paper queued behind it — until it
        // returns (product owner, 2026-10-13: "should be ingested instantly
        // basically; and cleanup happens in the background"). The queue's
        // drain moves the row from `.queued` to `.ready` when it lands.
        if !article.hasCompletedPaperContentCleanup,
           let raw = await rawPaperTextForCleanup(article),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let rawSHA256 = await Self.contentSHA256OffMain(raw)
            article.stagePaperContentCleanup(raw: raw, rawSHA256: rawSHA256)
            article.state = .queued
            article.errorMessage = nil
            guard await persistSource(
                article,
                context: "Queue paper content cleanup",
                showErrorToast: false,
                syncImmediately: true
            ) else { return false }
            article.discardPersistedPaperContentFromMemory()
            if let latestIdx = articles.firstIndex(where: { $0.id == id }) {
                articles[latestIdx] = article
            }
            NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
            if showToasts { showToast("Metadata saved") }
            return true
        }

        // Only a paper with no text to stage reaches the inline pass, which
        // records why cleanup could not run. A paper that already carries
        // canonical text is re-entering this method only for its metadata — a
        // retry, or a row an earlier build failed over a blank field — and
        // re-cleaning it would charge the learner twice for the same text.
        if !article.hasCompletedPaperContentCleanup,
           let cleanupError = await installCanonicalPaperContent(
               on: &article,
               progressPrefix: progressPrefix
           ) {
            if AITransientErrorClassifier.shouldRetryAutomatically(cleanupError),
               let raw = await storage.loadRawPaperContent(id) {
                let rawSHA256 = await Self.contentSHA256OffMain(raw)
                article.stagePaperContentCleanup(raw: raw, rawSHA256: rawSHA256)
                article.state = .queued
                article.errorMessage = nil
                if await persistSource(
                    article,
                    context: "Queue transient paper content cleanup",
                    showErrorToast: false,
                    syncImmediately: true
                ), let latestIdx = articles.firstIndex(where: { $0.id == id }) {
                    article.discardPersistedPaperContentFromMemory()
                    articles[latestIdx] = article
                }
                return false
            }
            let message = StudioArticle.paperContentCleanupFailureMessage(
                cleanupError.localizedDescription
            )
            article.failPaperContentCleanup(message)
            if await persistSource(
                article,
                context: "Save paper content cleanup failure",
                showErrorToast: false,
                syncImmediately: true
            ), let latestIdx = articles.firstIndex(where: { $0.id == id }) {
                articles[latestIdx] = article
            }
            PaperIngestionDiagnostics.recordFailure(
                sourceID: id,
                title: article.title,
                message: message
            )
            logger.error("\(message)")
            if showToasts { showToast(message) }
            return false
        }
        guard article.completePaperMetadataExtractionAfterLLM() else { return false }

        do {
            // This is the durable paper-metadata boundary. Push promptly so an
            // older whole-record snapshot from another Mac cannot remain the
            // CloudKit winner while the completed extraction sits behind a bulk
            // background-repair backlog.
            try await storage.saveSource(article, syncImmediately: true)
            article.discardPersistedPaperContentFromMemory()
            if let latestIdx = articles.firstIndex(where: { $0.id == id }) {
                articles[latestIdx] = article
            }
            if showToasts {
                showToast("Metadata saved")
            }
            return true
        } catch {
            logger.error("Failed to save AI-extracted paper metadata for \(id): \(error.localizedDescription)")
            if showToasts {
                showToast("Metadata save failed: \(error.localizedDescription)")
            }
            return false
        }
    }

    /// Finish ingestion for a paper whose required metadata the learner just
    /// supplied by hand. Some documents never print all three fields — a
    /// repository thesis can carry no journal and no year anywhere in its front
    /// matter — so the extractor can be permanently unable to attest a paper a
    /// human can complete in seconds. Once they do, the stale extraction error
    /// must clear and the remaining Source Content Cleanup must run.
    ///
    /// Returns once the metadata itself is attested and on disk. The cleanup is
    /// a full-document model pass that takes tens of seconds, so it runs in the
    /// returned task rather than under the caller's await: the Edit Details
    /// sheet would sit on a disabled Save button for the whole pass, showing
    /// "Cleaning up paper text…" in the sidebar while the learner waited for a
    /// dialog that had nothing left to do. The row moves to Processing for the
    /// duration instead. `nil` means no cleanup was started — either the paper
    /// did not need attesting, the save failed, or its text is already clean.
    @discardableResult
    func completePaperIngestionAfterManualMetadata(
        id: String,
        showToasts: Bool = false
    ) async -> Task<Void, Never>? {
        guard let idx = articles.firstIndex(where: { $0.id == id }) else { return nil }
        var article = articles[idx]
        // Only papers the pipeline could not attest itself. An already-attested
        // paper keeps its own ingestion record; ordinary metadata edits on it
        // are not an ingestion event.
        guard article.sourceType == .paper,
              article.requiresPaperMetadataAI,
              article.hasAttestablePaperMetadata,
              article.completePaperMetadataFromManualEntry() else { return nil }

        guard await persistSource(article, context: "Save manual paper metadata") else { return nil }
        if let latestIdx = articles.firstIndex(where: { $0.id == id }) {
            articles[latestIdx] = article
        }
        guard !article.hasCompletedPaperContentCleanup else {
            if showToasts { showToast("Paper metadata saved") }
            return nil
        }
        // Another pass — a Retry, or a second Save while the first is still
        // cleaning — already owns this paper's cleanup and will install the text.
        guard !processingPaperIDs.contains(id) else { return nil }

        pendingPaperProcessingIds.insert(id)
        reportPaperIngestionStep(id, nil, "Cleaning up paper text…")
        return Task {
            defer {
                pendingPaperProcessingIds.remove(id)
                paperProcessingSteps.removeValue(forKey: id)
            }
            // The metadata is attested and saved either way; a cancelled pass
            // leaves the text to the ordinary repair path, like an empty one.
            guard !Task.isCancelled else { return }
            await cleanUpPaperContentAfterManualMetadata(id: id, showToasts: showToasts)
        }
    }

    /// The Source Content Cleanup half of a manual attestation. Runs after the
    /// metadata is durable, so every failure here keeps the attestation and
    /// Retry resumes from the cleanup step instead of asking for the fields again.
    private func cleanUpPaperContentAfterManualMetadata(id: String, showToasts: Bool) async {
        guard let idx = articles.firstIndex(where: { $0.id == id }) else { return }
        var article = articles[idx]
        guard !article.hasCompletedPaperContentCleanup else { return }

        let storedRaw = await storage.loadRawPaperContent(id)
        let rawText: String
        if let storedRaw {
            rawText = storedRaw
        } else if let inMemoryRaw = article.content {
            rawText = inMemoryRaw
        } else {
            rawText = await Self.fullPaperTextOffMain(for: article)
        }
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Nothing to clean yet. The metadata itself is attested and saved,
            // so the ordinary repair path can supply the text later.
            return
        }

        do {
            let prepared = try await PaperContentPreparationService(aiService: aiService).prepare(
                source: AIUsageSource(source: article),
                rawText: rawText
            )
            article.installPreparedPaperContent(
                raw: prepared.raw,
                clean: prepared.clean,
                metadata: prepared.metadata,
                wordCount: prepared.wordCount
            )
            article.state = .ready
            article.errorMessage = nil
        } catch {
            if AITransientErrorClassifier.shouldRetryAutomatically(error) {
                let rawSHA256 = await Self.contentSHA256OffMain(rawText)
                article.stagePaperContentCleanup(raw: rawText, rawSHA256: rawSHA256)
                article.state = .queued
                article.errorMessage = nil
                let persisted = await persistSource(
                    article,
                    context: "Queue transient manual-metadata cleanup",
                    showErrorToast: false
                )
                if persisted {
                    article.discardPersistedPaperContentFromMemory()
                }
                if persisted, let latestIdx = articles.firstIndex(where: { $0.id == id }) {
                    articles[latestIdx] = article
                }
                return
            }
            let message = StudioArticle.paperContentCleanupFailureMessage(error.localizedDescription)
            article.state = .error
            article.errorMessage = message
            PaperIngestionDiagnostics.recordFailure(
                sourceID: id,
                title: article.title,
                message: message
            )
            _ = await persistSource(
                article,
                context: "Save manual metadata cleanup error",
                showErrorToast: false
            )
            if let latestIdx = articles.firstIndex(where: { $0.id == id }) {
                articles[latestIdx] = article
            }
            if showToasts { showToast(message) }
            return
        }

        guard await persistSource(
            article,
            context: "Save manually attested paper",
            showErrorToast: false,
            syncImmediately: true
        ) else { return }
        article.discardPersistedPaperContentFromMemory()
        if let latestIdx = articles.firstIndex(where: { $0.id == id }) {
            articles[latestIdx] = article
        }
        if showToasts { showToast("Paper metadata saved") }
    }

    /// Publish the per-paper ingestion phase. A non-nil prefix also mirrors the
    /// phase into the batch header's shared `paperDownloadStep` caption.
    func reportPaperIngestionStep(_ articleID: String, _ prefix: String?, _ phase: String) {
        paperProcessingSteps[articleID] = phase
        guard let prefix else { return }
        paperDownloadStep = prefix.isEmpty ? phase : "\(prefix) \(phase)"
    }

    /// The text Source Content Cleanup reads: the stored raw extraction, else
    /// the row's loaded text, else the PDF's full text.
    private func rawPaperTextForCleanup(_ article: StudioArticle) async -> String? {
        if let storedRaw = await storage.loadRawPaperContent(article.id) { return storedRaw }
        if let inMemoryRaw = article.content { return inMemoryRaw }
        return await Self.fullPaperTextOffMain(for: article)
    }

    /// Run Source Content Cleanup and install the canonical derivative on
    /// `article`, leaving it for the caller to persist. Returns the failure when
    /// cleanup could not produce canonical text, so the caller decides which
    /// error the row should carry.
    ///
    /// This stage is deliberately independent of the metadata gate: cleanup is
    /// what gives a paper readable, searchable, listenable text, and a document
    /// that prints no author still has all of it.
    private func installCanonicalPaperContent(
        on article: inout StudioArticle,
        progressPrefix: String?
    ) async -> Error? {
        let rawText = await rawPaperTextForCleanup(article) ?? ""
        reportPaperIngestionStep(article.id, progressPrefix, "Cleaning up paper text…")
        do {
            let prepared = try await PaperContentPreparationService(aiService: aiService).prepare(
                source: AIUsageSource(source: article),
                rawText: rawText
            )
            article.installPreparedPaperContent(
                raw: prepared.raw,
                clean: prepared.clean,
                metadata: prepared.metadata,
                wordCount: prepared.wordCount
            )
            return nil
        } catch {
            return error
        }
    }

    private func failPaperMetadataExtraction(
        id: String,
        message: String,
        showToasts: Bool
    ) async {
        guard let idx = articles.firstIndex(where: { $0.id == id }),
              articles[idx].sourceType == .paper else { return }
        var article = articles[idx]
        article.failPaperIngestionMetadata(message)
        if await persistSource(article, context: "Save failed paper metadata ingestion") {
            if let latestIdx = articles.firstIndex(where: { $0.id == id }) {
                articles[latestIdx] = article
            }
        }
        reportPaperMetadataFailure(id: id, message: message, showToasts: showToasts)
    }

    /// Diagnostics, logging, and the toast for a paper-ingestion failure the
    /// caller has already recorded on the row. Split out so a caller that has to
    /// persist the failure alongside other state — canonical text, partial
    /// metadata — can still report it exactly like the ordinary path.
    private func reportPaperMetadataFailure(
        id: String,
        message: String,
        showToasts: Bool
    ) {
        PaperIngestionDiagnostics.recordFailure(
            sourceID: id,
            title: articles.first(where: { $0.id == id })?.title ?? id,
            message: message
        )
        logger.error("\(message)")
        if showToasts {
            showToast(message, action: paperMetadataRetryToastAction(id: id))
        }
    }

    /// The toast's Retry, offered only when the row itself would offer one: a
    /// failure whose fix is a setting, a PDF or the learner's own fields gets
    /// no button that cannot succeed.
    private func paperMetadataRetryToastAction(id: String) -> StudioToastAction? {
        guard let article = articles.first(where: { $0.id == id }),
              article.paperIngestionRecoveryAction(hasUsablePDF: displayHasUsablePDF(article)) == .retry
        else { return nil }
        return StudioToastAction(title: "Retry") { [weak self] _ in
            await self?.extractPaperMetadataWithAI(id: id)
        }
    }

    /// Run AI metadata extraction for every paper that lacks an attested metadata
    /// stage. A paper the extractor attested on partial fields is deliberately
    /// excluded: the model already answered "?" for the blank, so asking again
    /// spends tokens on the same answer. Those blanks are filled in Edit Details.
    func extractMissingPaperMetadata() async {
        guard KeychainService.resolveConfig(for: .paperMetadata) != nil else {
            showToast("Set an API key in Settings first")
            return
        }

        let missing = articles.filter {
            $0.sourceType == .paper && !$0.hasPaperIngestionAttestation
        }
        guard !missing.isEmpty else {
            showToast("All papers have verified metadata")
            return
        }

        logger.info("Extracting metadata for \(missing.count) paper(s) with unknown authors")
        var succeeded = 0
        for (i, paper) in missing.enumerated() {
            let progressPrefix = "\(i + 1)/\(missing.count)"
            paperDownloadStep = "\(progressPrefix) Extracting paper metadata…"
            if await extractPaperMetadataWithAI(
                id: paper.id,
                showToasts: false,
                progressPrefix: progressPrefix
            ) {
                succeeded += 1
            }
        }
        paperDownloadStep = ""
        showToast("Extracted metadata for \(succeeded) of \(missing.count) paper\(missing.count == 1 ? "" : "s")")
    }

    /// `registeredTitle` is the title the paper's DOI is registered under,
    /// when known. It replaces the title only when that title is it with
    /// characters the PDF's text lost (`RegisteredPaperTitle`), so a DOI that
    /// names some other work cannot bring that work's title with it, and the
    /// DOI, URL and id are never touched by it.
    @discardableResult
    nonisolated static func applyExtractedPaperMetadata(
        _ result: AIService.PaperMetadataResult,
        to article: inout StudioArticle,
        overwriteTitle: Bool,
        registeredTitle: String? = nil
    ) -> Bool {
        var updated = false
        if let title = result.title, !title.isEmpty,
           article.title != title,
           overwriteTitle || titleNeedsResolution(article.title, domain: article.domain, url: article.url) {
            article.title = title
            updated = true
        }
        if let restored = RegisteredPaperTitle.restoringLostCharacters(
            in: article.title,
            registered: registeredTitle
        ) {
            article.title = restored
            updated = true
        }
        if let doi = result.doi, article.doi != doi {
            article.doi = doi
            updated = true
        }
        if let author = result.author, article.author != author {
            article.author = author
            updated = true
        }
        if let journal = result.journal, article.journal != journal {
            article.journal = journal
            updated = true
        }
        if let year = result.year, article.publishedYear != year {
            article.publishedYear = year
            updated = true
        }
        return updated
    }

    nonisolated static func firstPageText(for article: StudioArticle) -> String {
        firstPageText(fromPDFPath: article.resolvedPDFPath)
    }

    nonisolated static func firstPageText(fromPDFPath pdfPath: String?) -> String {
        #if canImport(PDFKit)
        if let pdfPath,
           let doc = PDFDocument(url: URL(fileURLWithPath: pdfPath)),
           let page = doc.page(at: 0) {
            return page.string ?? ""
        }
        #endif
        return ""
    }

    /// Metadata extraction reads front matter, not strictly page one. A
    /// repository copy of a thesis or report opens with a library cover sheet
    /// that carries the title and little else, pushing the real title page —
    /// with the awarding institution and the degree year — to the next page.
    /// Pages are added only until there is enough text to work with, so an
    /// ordinary paper, whose first page already clears the threshold, is read
    /// exactly as before.
    nonisolated static let paperFrontMatterMinimumCharacters = 2500
    nonisolated static let paperFrontMatterMaximumPages = 3
    /// The longer look taken when the first page or two did not name every
    /// field: more pages, and a larger share of them handed to the model.
    nonisolated static let paperLongLookMaximumPages = 6
    nonisolated static let paperLongLookCharacters = 14_000

    nonisolated static func frontMatterText(
        fromPDFPath pdfPath: String?,
        maximumPages: Int = StudioViewModel.paperFrontMatterMaximumPages,
        minimumCharacters: Int = StudioViewModel.paperFrontMatterMinimumCharacters
    ) -> String {
        #if canImport(PDFKit)
        guard let pdfPath,
              let doc = PDFDocument(url: URL(fileURLWithPath: pdfPath)) else { return "" }
        var collected = ""
        for index in 0..<min(doc.pageCount, maximumPages) {
            guard let page = doc.page(at: index)?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !page.isEmpty else { continue }
            collected += collected.isEmpty ? page : "\n\n\(page)"
            if collected.count >= minimumCharacters { break }
        }
        return collected
        #else
        return ""
        #endif
    }

    /// Front matter for the metadata extractor. Kept separate from
    /// `firstPageTextOffMain`, whose callers scan for a DOI and must not see
    /// the reference DOIs that later pages can contain.
    nonisolated static func frontMatterTextOffMain(
        for article: StudioArticle,
        maximumPages: Int = StudioViewModel.paperFrontMatterMaximumPages,
        minimumCharacters: Int = StudioViewModel.paperFrontMatterMinimumCharacters
    ) async -> String {
        let pdfPath = article.resolvedPDFPath
        let storedText = article.content?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return await Task.detached(priority: .utility) {
            let pdfText = Self.frontMatterText(
                fromPDFPath: pdfPath,
                maximumPages: maximumPages,
                minimumCharacters: minimumCharacters
            )
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !pdfText.isEmpty {
                return pdfText
            }
            return storedText.map { String($0.prefix(12_000)) } ?? ""
        }.value
    }

    nonisolated static func firstPageTextOffMain(for article: StudioArticle) async -> String {
        let pdfPath = article.resolvedPDFPath
        let storedText = article.content?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return await Task.detached(priority: .utility) {
            let pdfText = Self.firstPageText(fromPDFPath: pdfPath)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !pdfText.isEmpty {
                return pdfText
            }
            // Full-text scholarly repositories can provide the paper without a
            // PDF. The opening text is still paper content, not a title-only
            // heuristic, and is therefore valid input to the mandatory model call.
            return storedText.map { String($0.prefix(12_000)) } ?? ""
        }.value
    }

    nonisolated static func fullPaperTextOffMain(for article: StudioArticle) async -> String {
        let pdfPath = article.resolvedPDFPath
        return await Task.detached(priority: .utility) {
            guard let pdfPath else { return "" }
            return (try? SourceService.shared.extractTextFromPDF(at: pdfPath)) ?? ""
        }.value
    }

    /// Use API lookups (for papers) then LLM to fix title, author, and year for an article.
    /// Returns whether anything was found and saved, so a caller can say so
    /// when the answer is no instead of leaving the learner staring at an
    /// unchanged form.
    @discardableResult
    func fixTitle(for articleId: String) async -> Bool {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return false }
        guard !fixingTitleIds.contains(articleId) else { return false }
        fixingTitleIds.insert(articleId)
        defer { fixingTitleIds.remove(articleId) }

        // Work on a local copy across the awaits below; the captured index can go
        // stale if a concurrent refresh reorders `articles`. Written back by id at the end.
        var working = articles[idx]
        var didUpdate = false

        // Step 0: For YouTube videos, fetch the title from YouTube (fast, no LLM needed)
        if YouTubeTranscriptService.isYouTubeURL(working.url),
           let videoId = YouTubeTranscriptService.extractVideoId(from: working.url),
           let title = await YouTubeTranscriptService.shared.fetchVideoTitle(videoId: videoId) {
            working.title = title
            didUpdate = true
        }

        // Step 1: For papers, try API metadata lookups first
        if working.sourceType == .paper {
            var doi = PaperService.extractDOI(from: working.url)
            #if canImport(PDFKit)
            if doi == nil {
                let candidates = [
                    working.localFilePath,
                    working.url.hasPrefix("/") ? working.url : nil,
                    working.resolvedPDFPath,
                ].compactMap { $0 }
                doi = await Self.firstPDFDOIOffMain(in: candidates)
            }
            #endif
            if let meta = await PaperService.fetchPaperMetadata(url: working.url, title: working.title, doi: doi) {
                if let apiTitle = meta.title, !apiTitle.isEmpty {
                    working.title = apiTitle
                    didUpdate = true
                }
                if let authors = meta.authorsDisplay, !authors.isEmpty {
                    didUpdate = await applyMetadataAuthor(authors, to: &working) || didUpdate
                }
                if let journal = meta.journal, !journal.isEmpty {
                    working.journal = journal
                    didUpdate = true
                }
                if let year = meta.year, !year.isEmpty {
                    working.publishedYear = year
                    didUpdate = true
                }
            }
        }

        // Step 2: LLM fix for remaining gaps (or all fields for non-papers)
        let needsTitle = !didUpdate || working.title.hasPrefix("http") || working.title.hasSuffix(".pdf")
        let needsAuthor = working.author == nil || working.author?.isEmpty == true
        let needsYear = working.publishedYear == nil || working.publishedYear?.isEmpty == true

        if needsTitle || needsAuthor || needsYear {
            if let metaConfig = KeychainService.resolveConfig(for: .articleMetadata) {
                // A PDF imported from disk or a link carries no stored text, so
                // the model got only an address and answered with a request to
                // fetch it. Hand it what the document itself says on its first
                // pages, as the paper path does.
                var evidenceText = working.content ?? ""
                if evidenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    evidenceText = await Self.frontMatterTextOffMain(for: working)
                }
                let result = await aiService.fixArticleTitle(
                    source: AIUsageSource(source: working),
                    currentTitle: working.title,
                    url: working.url,
                    content: evidenceText,
                    config: metaConfig
                )
                if let result {
                    if needsTitle, let title = result.title {
                        working.title = title
                        didUpdate = true
                    }
                    if needsAuthor, let author = result.author {
                        working.author = author
                        didUpdate = true
                    }
                    if needsYear, let year = result.year {
                        working.publishedYear = year
                        didUpdate = true
                    }
                }
            }
        }

        if didUpdate {
            // Re-resolve and write the working copy back by id (the captured
            // index may be stale after the awaits above), then persist.
            if let writeIdx = articles.firstIndex(where: { $0.id == articleId }) {
                articles[writeIdx] = working
            }
            if await persistSource(working, context: "Save title metadata") {
                logger.info("Fixed title/metadata for: \(working.title)")
                return true
            }
        }
        return false
    }

    nonisolated static func firstPDFDOIOffMain(in candidates: [String]) async -> String? {
        await Task.detached(priority: .utility) {
            for candidate in candidates {
                if let doi = extractDOIFromPDF(at: candidate) {
                    return doi
                }
            }
            return nil
        }.value
    }

    /// True when the title is just the domain, URL, or otherwise clearly not a real title.
    nonisolated static func titleLooksBad(_ title: String, domain: String, url: String) -> Bool {
        titleNeedsResolution(title, domain: domain, url: url)
    }

    /// True when an article's title is one its page supplied — the head's
    /// metadata, the headline, the site's own name, the host placeholder —
    /// rather than one a person typed. The article-metadata model's answer may
    /// replace the former; the latter is the learner's and stays.
    nonisolated static func articleTitleIsPageSupplied(
        _ title: String,
        pageTitle: String?,
        evidence: PaperService.WebArticleTitleEvidence?,
        domain: String,
        url: String
    ) -> Bool {
        if titleLooksBad(title, domain: domain, url: url) { return true }
        let current = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pageTitle = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           pageTitle.caseInsensitiveCompare(current) == .orderedSame {
            return true
        }
        let host = URL(string: url)?.host ?? domain
        return evidence?.supplied(current, host: host) ?? false
    }

    /// Replace placeholder article titles/authors using HTML metadata, then body text.
    nonisolated static func applyWebArticleMetadataIfNeeded(
        to article: inout StudioArticle,
        pageTitle: String?,
        pageAuthor: String?,
        content: String
    ) {
        if titleLooksBad(article.title, domain: article.domain, url: article.url) {
            if let pageTitle = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
               !pageTitle.isEmpty,
               pageTitle.count < 300 {
                article.title = pageTitle
            }
        }
        if article.author == nil,
           let pageAuthor = pageAuthor?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pageAuthor.isEmpty {
            article.author = pageAuthor
        }
    }

}
