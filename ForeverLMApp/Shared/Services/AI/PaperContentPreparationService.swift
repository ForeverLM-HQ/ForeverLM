import CryptoKit
import Foundation
import os
#if canImport(PDFKit)
import PDFKit
#endif

private let logger = Logger(subsystem: "com.foreverlm", category: "CanonicalContentCleanup")

/// Posted whenever a source gains or changes canonical text. It drives the
/// canonical cleanup stage followed by persisted listenable-content preparation.
/// Review-only artifacts remain outside this path.
extension Notification.Name {
    static let derivedSourceWorkNeeded = Notification.Name("derivedSourceWorkNeeded")
}

struct PreparedPaperContent: Sendable {
    let raw: String
    let clean: String
    let metadata: PaperContentPreparationMetadata
    let wordCount: Int

    init(
        raw: String,
        clean: String,
        metadata: PaperContentPreparationMetadata,
        wordCount: Int? = nil
    ) {
        self.raw = raw
        self.clean = clean
        self.metadata = metadata
        self.wordCount = wordCount
            ?? clean.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

struct CanonicalContentCleanupCandidate: Sendable {
    let sourceID: String
    let title: String
    let sourceType: StudioSourceType
    let raw: String
    let rawSHA256: String
    /// New ingestion can enter the durable queue before canonical text exists.
    /// Historical re-cleaning remains `ready` and must never have its visible
    /// source state changed if a newer cleanup contract fails.
    let isPendingIngestion: Bool
    /// The source's own file as its per-type row stores it: a paper's PDF
    /// (`papers.local_file_path`) or an article's archived page
    /// (`articles.local_file_path`, `Articles/<id>/article.html`).
    var localFilePath: String? = nil
    /// Set when the drain replaced `raw` with a fresh extraction of the PDF:
    /// the hash of the stored row the candidate was read from. The commit
    /// compares the row against it, so a concurrent change still aborts.
    var storedRawSHA256: String? = nil

    /// Hash of the stored text this candidate was read from.
    var storedTextSHA256: String { storedRawSHA256 ?? rawSHA256 }

    func replacingRaw(with extraction: String) -> CanonicalContentCleanupCandidate {
        CanonicalContentCleanupCandidate(
            sourceID: sourceID,
            title: title,
            sourceType: sourceType,
            raw: extraction,
            rawSHA256: PaperContentPreparationService.sha256(extraction),
            isPendingIngestion: isPendingIngestion,
            localFilePath: localFilePath,
            storedRawSHA256: storedTextSHA256
        )
    }
}

/// Thrown only when a model response is not a valid deletion diff against the
/// authoritative extraction. The queue remains intact so a later configured
/// model call can retry; no deterministic quality score or attempt budget is
/// used to approve, reject, or retire source content.
enum CanonicalContentCleanupContractError: LocalizedError, Equatable {
    case unknownBlockReference
    case nonVerbatimDeletionHunk
    case overlappingDeletionHunks

    var errorDescription: String? {
        switch self {
        case .unknownBlockReference:
            return "Source Content Cleanup referenced an unknown block."
        case .nonVerbatimDeletionHunk:
            return "Source Content Cleanup returned a non-verbatim deletion hunk."
        case .overlappingDeletionHunks:
            return "Source Content Cleanup returned overlapping deletion hunks."
        }
    }
}

struct CanonicalContentCleanupDrainResult: Sendable {
    let processedCount: Int
    let processedSourceIDs: [String]
    let remainingCount: Int
    let errorMessage: String?
    /// Whether the batch's failures were ones to wait out (a rate limit, a
    /// timeout) rather than verdicts on a source.
    var failedTransiently = false
    /// The longest wait a provider named for this batch's failures (Retry-After,
    /// or when a rate-limit quota refills), so the next drain is not tried sooner.
    var retryAfterSeconds: Double? = nil
}

/// A cleanup attempt that produced no content. `wasCancelled` is decided where
/// the typed error still exists, because a flattened `localizedDescription`
/// cannot always tell a cancelled task from a failed one.
private struct CanonicalContentCleanupFailure: Sendable {
    let message: String
    let wasCancelled: Bool
    /// Classified from the typed error, where the HTTP status still exists;
    /// the message is read too, for failures that reached here as text.
    let isTransient: Bool
    let retryAfterSeconds: Double?

    init(_ error: Error) {
        message = error.localizedDescription
        wasCancelled = AITransientErrorClassifier.isCancellation(error)
        isTransient = AITransientErrorClassifier.isTransient(error)
            || AITransientErrorClassifier.isTransient(AIError.apiError(error.localizedDescription))
        retryAfterSeconds = AITransientErrorClassifier.retryAfterSeconds(error)
    }
}

private enum CanonicalContentCleanupOutcome: Sendable {
    case prepared(candidate: CanonicalContentCleanupCandidate, content: PreparedPaperContent)
    case failed(candidate: CanonicalContentCleanupCandidate, failure: CanonicalContentCleanupFailure)
}

/// Creates the one canonical paper/article text derivative used by every
/// downstream feature. Raw extraction remains available for audits and future
/// reprocessing; only the cleaned derivative is exposed as ordinary content.
struct PaperContentPreparationService: Sendable {
    static let contentCleanupCreditsPausedMessage =
        "Source Content Cleanup paused: add your OpenRouter key in Settings → AI Usage to finish ingesting this source."
    /// The wording while the key needed a plan (until 2026-10-10). Rows that
    /// stored it are still paused for the same reason.
    private static let planEraContentCleanupCreditsPausedMessage =
        "Source Content Cleanup paused: add your OpenRouter key in Settings → AI Usage and choose a plan in Settings → Billing to finish ingesting this source."
    /// The wording before the prepaid balance was retired (2026-09-25). Rows
    /// that stored it are still paused for the same reason.
    private static let legacyContentCleanupCreditsPausedMessage =
        "Source Content Cleanup paused: your ForeverLM AI balance is empty. Top up to finish ingesting this source."

    private static let legacyArticleConfigurationFailure =
        "Article ingestion failed during Source Content Cleanup: Source Content Cleanup is not configured."

    private static let managedCreditsEmptyServiceMessage =
        "Your ForeverLM AI balance is empty — top up in Settings to continue."
    private static let legacyManagedCreditsEmptyServiceMessage =
        "ForeverLM AI credits are empty — top up in Settings to continue."

    private static let maximumBlockCharacters = 800
    private let aiService: AIService

    init(aiService: AIService = AIService()) {
        self.aiService = aiService
    }

    /// Keeps the actionable reason at the front of a compact article row. The
    /// generic pipeline prefix remains useful for model and network failures,
    /// but it previously pushed the empty-credit explanation out of view.
    static func articleIngestionFailureMessage(for error: Error) -> String {
        let detail: String
        if let urlError = error as? URLError,
           urlError.code == .networkConnectionLost {
            detail = "The network connection was lost."
        } else {
            detail = error.localizedDescription
        }
        if detail == contentCleanupCreditsPausedMessage
            || detail == planEraContentCleanupCreditsPausedMessage
            || detail == legacyContentCleanupCreditsPausedMessage
            || detail == managedCreditsEmptyServiceMessage
            || detail == legacyManagedCreditsEmptyServiceMessage {
            return contentCleanupCreditsPausedMessage
        }
        return "Article ingestion failed during Source Content Cleanup: \(detail)"
    }

    /// Whether a persisted ingestion failure says only that the managed balance
    /// was empty. That is an account condition rather than anything wrong with
    /// the source: the identical work succeeds once the balance returns, which
    /// is why callers resume these instead of asking the learner to retry.
    ///
    /// Every wording matched here is code-owned — the app wrote it — so this
    /// recognizes its own sentences rather than interpreting prose.
    static func isEmptyBalanceFailure(_ storedMessage: String?) -> Bool {
        guard let storedMessage else { return false }
        let creditWordings = [
            contentCleanupCreditsPausedMessage,
            planEraContentCleanupCreditsPausedMessage,
            legacyContentCleanupCreditsPausedMessage,
            managedCreditsEmptyServiceMessage,
            legacyManagedCreditsEmptyServiceMessage,
            SourceError.aiCreditsRequired.localizedDescription,
            SourceError.planEraAICreditsRequiredMessage,
            SourceError.legacyAICreditsRequiredMessage,
        ]
        // Ingestion wraps the service message in a stage prefix, so a failure
        // that ends in one of these sentences is the same paused state as one
        // that consists of it.
        return creditWordings.contains { storedMessage.contains($0) }
    }

    /// Recognizes only the cleanup failure sentences written by this app, then
    /// classifies the underlying provider detail. This lets old persisted
    /// timeout rows heal after an update without interpreting arbitrary source
    /// titles or user-authored text as executable state.
    ///
    /// Cancellations belong here for the same reason. An earlier build treated
    /// an interrupted drain as a verdict and parked the paper with Swift's
    /// cancellation description as its reason; those rows describe work that
    /// never ran, so they re-stage themselves instead of waiting for the
    /// learner to press Retry on each one.
    static func isTransientIngestionFailure(_ storedMessage: String?) -> Bool {
        guard let storedMessage else { return false }
        let isCleanupFailure = storedMessage.hasPrefix(
            "Article ingestion failed during Source Content Cleanup:"
        ) || storedMessage.hasPrefix(StudioArticle.paperContentCleanupFailurePrefix)
            || storedMessage.contains(StudioArticle.legacyPaperContentCleanupFailureMarker)
        guard isCleanupFailure else { return false }
        if AITransientErrorClassifier.isCancellationMessage(storedMessage) { return true }
        // A refused reasoning opt-out is not transient, but the request now
        // retries with reasoning on, so a source parked behind it resumes
        // from its preserved raw extraction without a Retry click.
        if storedMessage.lowercased().contains("reasoning is mandatory") { return true }
        return AITransientErrorClassifier.isTransient(AIError.apiError(storedMessage))
    }

    /// Re-presents rows written by the affected build without rewriting synced
    /// source records. The legacy text is reclassified only while the account is
    /// known to be empty; once it can pay again it remains a genuine configuration
    /// failure until the learner retries it.
    static func articleCreditsMessage(
        for storedMessage: String?,
        creditsAreEmpty: Bool = AICreditEntitlement.isOutOfCredits
    ) -> String? {
        guard let storedMessage else { return nil }
        if storedMessage == contentCleanupCreditsPausedMessage
            || storedMessage == legacyContentCleanupCreditsPausedMessage {
            return contentCleanupCreditsPausedMessage
        }
        // Both service wordings have shipped. Matching only the current one left
        // the older rows showing the generic pipeline prefix, which truncates in a
        // compact row before it reaches the part that says the balance is empty —
        // the learner saw a stage name where the actionable reason belonged.
        let wrappedCreditsFailures = [
            managedCreditsEmptyServiceMessage,
            legacyManagedCreditsEmptyServiceMessage,
        ].map { "Article ingestion failed during Source Content Cleanup: \($0)" }
        if wrappedCreditsFailures.contains(storedMessage) {
            return contentCleanupCreditsPausedMessage
        }
        if creditsAreEmpty, storedMessage == legacyArticleConfigurationFailure {
            return contentCleanupCreditsPausedMessage
        }
        return nil
    }

    func prepare(
        source: AIUsageSource,
        rawText: String,
        sourceType: StudioSourceType = .paper
    ) async throws -> PreparedPaperContent {
        // Callers include @MainActor view models. Semantic blocking,
        // deletion-plan validation, reconstruction, hashing, and word counting
        // all scale with the complete paper and must never inherit that executor.
        let sessionID = AIUsageAttribution.sessionID
        let taskLabel = AIUsageAttribution.task
        let task = Task.detached(priority: .utility) {
            try await AIUsageAttribution.$sessionID.withValue(sessionID) {
                try await AIUsageAttribution.$task.withValue(taskLabel) {
                    try await AIUsageAttribution.withSource(source) {
                        try await self.prepareAttributed(
                            source: source,
                            rawText: rawText,
                            sourceType: sourceType
                        )
                    }
                }
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func prepareAttributed(
        source: AIUsageSource,
        rawText: String,
        sourceType: StudioSourceType
    ) async throws -> PreparedPaperContent {
        guard sourceType == .paper || sourceType == .article
                || sourceType == .manual || sourceType == .unclassified else {
            throw AIError.apiError("Source Content Cleanup supports papers and articles only.")
        }
        let raw = rawText
        let normalizedRaw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRaw.isEmpty else { throw AIError.invalidResponse }
        guard let config = KeychainService.resolveConfig(for: .paperNarrationPreparation) else {
            if AICreditEntitlement.isOutOfCredits {
                throw AIError.apiError(Self.contentCleanupCreditsPausedMessage)
            }
            let reason = KeychainService.backgroundAIUnavailableMessage(for: .paperNarrationPreparation)
                ?? "Sign in with Apple to use Source Content Cleanup."
            throw AIError.apiError(reason)
        }

        // The model must see every extracted source character. Use one request
        // whenever the complete serialized prompt fits the selected model's
        // context budget; only a genuinely oversized source is split.
        let blocks = Self.semanticBlocks(normalizedRaw)
        let routedConfig = KeychainService.routedTextConfig(config)
        let cleanupPrompt = AITask.paperNarrationPreparation.effectivePrompt
            ?? Prompts.paperNarrationPreparation
        let requestChunks = try Self.cleanupRequestChunks(
            system: cleanupPrompt,
            sourceTitle: source.title,
            sourceType: sourceType,
            blocks: blocks,
            provider: routedConfig.provider,
            model: routedConfig.model
        )
        try Task.checkCancellation()
        // The model occasionally skips a Box heading it was told to rule on
        // (2026-10-09, an IGVF Nature paper). The plan is sampled, so a second
        // request usually rules on every heading; a repeat omission still fails
        // the cleanup rather than guessing where a Box belongs.
        var deletionPlan = AIService.PaperContentDeletionPlan.empty
        for attempt in 1...2 {
            deletionPlan = AIService.PaperContentDeletionPlan.empty
            for (index, chunk) in requestChunks.enumerated() {
                try Task.checkCancellation()
                let chunkPlan = try await AIBackgroundRetry.run(config: config) { config in
                    try await aiService.paperContentDeletionPlan(
                        source: source,
                        sourceType: sourceType,
                        blocks: chunk,
                        config: config,
                        system: cleanupPrompt,
                        chunkIndex: index,
                        chunkCount: requestChunks.count
                    )
                }
                deletionPlan = deletionPlan.merging(chunkPlan)
            }
            if requestChunks.count > 1 {
                let mergedData = try JSONEncoder().encode(deletionPlan)
                guard let mergedJSON = String(data: mergedData, encoding: .utf8) else {
                    throw AIError.invalidResponse
                }
                deletionPlan = try AIService.validatedPaperContentDeletionPlan(
                    mergedJSON,
                    blocks: blocks
                )
            }
            if sourceType == .paper {
                do {
                    try Self.validateSidebarDecisions(in: blocks, applying: deletionPlan)
                } catch where attempt < 2 {
                    logger.warning("Source Content Cleanup left a Box heading unclassified; asking again")
                    continue
                }
            }
            break
        }
        deletionPlan = try await auditingWholeBlockDeletions(
            deletionPlan,
            source: source,
            sourceType: sourceType,
            blocks: blocks,
            config: config,
            provider: routedConfig.provider,
            model: routedConfig.model
        )

        let clean = try Self.reconstruct(
            title: source.title,
            blocks: blocks,
            applying: deletionPlan
        )
        return PreparedPaperContent(
            raw: raw,
            clean: clean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: Self.sha256(raw),
                cleanSHA256: Self.sha256(clean),
                preparedAt: Date()
            ),
            wordCount: clean.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        )
    }

    /// Every whole block the plan deletes is read a second time, on its own,
    /// and any the model calls source content goes back in. On 2026-09-23 a
    /// Cell paper's cleanup deleted from its References heading to the last
    /// line, taking the STAR★Methods and Key Resources Table printed after the
    /// bibliography with it; chat then told the learner the methods were
    /// missing. Seen apart from the document, a reagent table or a cell-culture
    /// paragraph cannot pass for a reference entry. The check can only restore,
    /// so a wrong answer costs some noise, never text; a failed call fails the
    /// cleanup, which the queue retries, rather than publishing an unchecked plan.
    private func auditingWholeBlockDeletions(
        _ plan: AIService.PaperContentDeletionPlan,
        source: AIUsageSource,
        sourceType: StudioSourceType,
        blocks: [AIService.PaperContentBlock],
        config: AITaskConfig,
        provider: AIProvider,
        model: String
    ) async throws -> AIService.PaperContentDeletionPlan {
        let runs = Self.deletionAuditRuns(blocks: blocks, removing: Set(plan.removeBlocks))
        guard !runs.isEmpty else { return plan }
        let chunks = try Self.deletionAuditRequestChunks(
            sourceTitle: source.title,
            sourceType: sourceType,
            runs: runs,
            provider: provider,
            model: model
        )
        var restored = Set<String>()
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            restored.formUnion(try await AIBackgroundRetry.run(config: config) { config in
                try await aiService.paperContentDeletionAudit(
                    source: source,
                    sourceType: sourceType,
                    runs: chunk,
                    config: config,
                    chunkIndex: index,
                    chunkCount: chunks.count
                )
            })
        }
        guard !restored.isEmpty else { return plan }
        logger.notice(
            "Source cleanup check kept \(restored.count, privacy: .public) block(s) the plan would have deleted"
        )
        return AIService.PaperContentDeletionPlan(
            removeBlocks: plan.removeBlocks.filter { !restored.contains($0) },
            relocations: plan.relocations,
            keepInPlaceBoxHeadingIDs: plan.keepInPlaceBoxHeadingIDs,
            removeText: plan.removeText
        )
    }

    /// Maximal runs of consecutive deleted blocks, in document order.
    static func deletionAuditRuns(
        blocks: [AIService.PaperContentBlock],
        removing removedIDs: Set<String>
    ) -> [AIService.PaperContentDeletionAuditRun] {
        var runs: [AIService.PaperContentDeletionAuditRun] = []
        var index = 0
        while index < blocks.count {
            guard removedIDs.contains(blocks[index].id) else {
                index += 1
                continue
            }
            let start = index
            while index < blocks.count, removedIDs.contains(blocks[index].id) { index += 1 }
            runs.append(AIService.PaperContentDeletionAuditRun(
                keptBefore: start > 0 ? blocks[start - 1] : nil,
                removed: Array(blocks[start..<index]),
                keptAfter: index < blocks.count ? blocks[index] : nil
            ))
        }
        return runs
    }

    /// One request when every run fits the model's window; otherwise runs are
    /// packed in order, and a run too large for one request is split with each
    /// part keeping the context block on its own outer edge.
    static func deletionAuditRequestChunks(
        sourceTitle: String,
        sourceType: StudioSourceType,
        runs: [AIService.PaperContentDeletionAuditRun],
        provider: AIProvider,
        model: String
    ) throws -> [[AIService.PaperContentDeletionAuditRun]] {
        try deletionAuditRequestChunks(
            sourceTitle: sourceTitle,
            sourceType: sourceType,
            runs: runs,
            inputBudget: AIService.inputCharacterBudget(
                provider: provider,
                model: model,
                requestedMaxTokens: AIService.paperContentDeletionMaxTokens
            )
        )
    }

    /// - Parameter inputBudget: request characters the model accepts; nil
    ///   when it publishes no window, and then everything goes in one request.
    static func deletionAuditRequestChunks(
        sourceTitle: String,
        sourceType: StudioSourceType,
        runs: [AIService.PaperContentDeletionAuditRun],
        inputBudget: Int?
    ) throws -> [[AIService.PaperContentDeletionAuditRun]] {
        guard !runs.isEmpty else { return [] }
        guard let inputBudget else { return [runs] }
        // Reserve the fixed prompt with wider part numbers than any queue can
        // reach; the rest belongs to serialized runs and their separators.
        let scaffold = AIService.paperContentDeletionAuditRequest(
            sourceTitle: sourceTitle,
            sourceType: sourceType,
            runs: [],
            chunkIndex: 999_998,
            chunkCount: 999_999
        ).inputCharacterCount
        let runBudget = inputBudget - scaffold
        guard runBudget > 0 else {
            throw AIError.apiError(
                "Source Content Cleanup instructions exceed this model's context window."
            )
        }
        let separator = 2
        func cost(_ run: AIService.PaperContentDeletionAuditRun) -> Int {
            AIService.paperContentDeletionAuditSerializedRun(run).count + separator
        }
        guard runs.reduce(0, { $0 + cost($1) }) > runBudget else { return [runs] }

        var pieces: [(run: AIService.PaperContentDeletionAuditRun, cost: Int)] = []
        for run in runs {
            let runCost = cost(run)
            guard runCost > runBudget else {
                pieces.append((run, runCost))
                continue
            }
            var current: [AIService.PaperContentBlock] = []
            var currentCost = 0
            var isFirstPiece = true
            func piece(last: Bool) -> AIService.PaperContentDeletionAuditRun {
                AIService.PaperContentDeletionAuditRun(
                    keptBefore: isFirstPiece ? run.keptBefore : nil,
                    removed: current,
                    keptAfter: last ? run.keptAfter : nil
                )
            }
            // Both context blocks are counted against every part, so a part
            // can never exceed the budget whichever edge it turns out to hold.
            let overhead = cost(AIService.PaperContentDeletionAuditRun(
                keptBefore: run.keptBefore,
                removed: [],
                keptAfter: run.keptAfter
            ))
            for block in run.removed {
                let blockCost = AIService.paperContentDeletionTaggedBlock(block).count + separator
                guard overhead + blockCost <= runBudget else {
                    throw AIError.apiError(
                        "Source Content Cleanup found a text block larger than this model's context window."
                    )
                }
                if !current.isEmpty, overhead + currentCost + blockCost > runBudget {
                    pieces.append((piece(last: false), overhead + currentCost))
                    isFirstPiece = false
                    current = []
                    currentCost = 0
                }
                current.append(block)
                currentCost += blockCost
            }
            if !current.isEmpty { pieces.append((piece(last: true), overhead + currentCost)) }
        }

        var chunks: [[AIService.PaperContentDeletionAuditRun]] = []
        var current: [AIService.PaperContentDeletionAuditRun] = []
        var currentCost = 0
        for piece in pieces {
            if !current.isEmpty, currentCost + piece.cost > runBudget {
                chunks.append(current)
                current = []
                currentCost = 0
            }
            current.append(piece.run)
            currentCost += piece.cost
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    static func reconstruct(
        title: String,
        blocks: [AIService.PaperContentBlock],
        applying plan: AIService.PaperContentDeletionPlan
    ) throws -> String {
        let knownIDs = Set(blocks.map(\.id))
        let removedBlockIDs = Set(plan.removeBlocks)
        let relocatedBlockIDs = Set(plan.relocations.flatMap(\.blockIDs))
        let relocationAnchors = Set(plan.relocations.map(\.insertAfterBlockID))
        guard removedBlockIDs.isSubset(of: knownIDs),
              relocatedBlockIDs.isSubset(of: knownIDs),
              relocationAnchors.isSubset(of: knownIDs),
              removedBlockIDs.isDisjoint(with: relocationAnchors),
              relocatedBlockIDs.isDisjoint(with: relocationAnchors),
              plan.removeText.allSatisfy({ knownIDs.contains($0.blockID) }) else {
            throw CanonicalContentCleanupContractError.unknownBlockReference
        }
        let authoritativeTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !authoritativeTitle.isEmpty else { throw AIError.invalidResponse }

        let indexByID = Dictionary(
            uniqueKeysWithValues: blocks.enumerated().map { ($0.element.id, $0.offset) }
        )
        var validatedRelocationIDs = Set<String>()
        for relocation in plan.relocations {
            let indices = relocation.blockIDs.compactMap { indexByID[$0] }
            guard !indices.isEmpty,
                  Set(relocation.blockIDs).count == relocation.blockIDs.count,
                  indices == indices.sorted(),
                  zip(indices, indices.dropFirst()).allSatisfy({ $0.1 == $0.0 + 1 }),
                  let anchorIndex = indexByID[relocation.insertAfterBlockID],
                  let finalMovedIndex = indices.last,
                  anchorIndex > finalMovedIndex,
                  relocation.blockIDs.allSatisfy({ !validatedRelocationIDs.contains($0) }) else {
                throw CanonicalContentCleanupContractError.unknownBlockReference
            }
            validatedRelocationIDs.formUnion(relocation.blockIDs)
        }

        let inlineByBlock = Dictionary(grouping: plan.removeText, by: \.blockID)
        let relocationsByAnchor = Dictionary(grouping: plan.relocations, by: \.insertAfterBlockID)
        let blockByID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        var retainedTexts: [String] = []
        func append(_ block: AIService.PaperContentBlock) throws {
            let cleaned = try Self.applyingInlineDeletions(
                inlineByBlock[block.id] ?? [],
                to: block.text
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { retainedTexts.append(cleaned) }
        }
        for block in blocks where !removedBlockIDs.contains(block.id) {
            if relocatedBlockIDs.contains(block.id) { continue }
            try append(block)
            if let relocations = relocationsByAnchor[block.id] {
                for relocation in relocations.sorted(by: {
                    (indexByID[$0.blockIDs[0]] ?? .max) < (indexByID[$1.blockIDs[0]] ?? .max)
                }) {
                    for blockID in relocation.blockIDs {
                        if removedBlockIDs.contains(blockID) { continue }
                        guard let movedBlock = blockByID[blockID] else {
                            throw CanonicalContentCleanupContractError.unknownBlockReference
                        }
                        try append(movedBlock)
                    }
                }
            }
        }
        // A deletion diff is advisory. If it contains no retained block, ignore
        // the diff and preserve the authoritative extraction in full. This is a
        // structural fail-closed rule for deletion, not a character-ratio or
        // content heuristic.
        if retainedTexts.isEmpty {
            retainedTexts = blocks.map(\.text)
        }
        // Blocks follow extracted physical lines. Rejoin with a single newline so
        // deleting a header or author line cannot also rewrite or absorb its
        // neighboring prose.
        let body = retainedTexts.joined(separator: "\n")
        return authoritativeTitle + "\n\n" + body
    }

    private static func applyingInlineDeletions(
        _ deletions: [AIService.PaperContentTextDeletion],
        to text: String
    ) throws -> String {
        guard !deletions.isEmpty else { return text }
        var ranges: [Range<String.Index>] = []
        for deletion in deletions {
            guard deletion.occurrence > 0,
                  !deletion.exactText.isEmpty,
                  let range = occurrenceRange(
                    of: deletion.exactText,
                    occurrence: deletion.occurrence,
                    in: text
                  ) else {
                throw CanonicalContentCleanupContractError.nonVerbatimDeletionHunk
            }
            guard !ranges.contains(where: { $0.overlaps(range) }) else {
                throw CanonicalContentCleanupContractError.overlappingDeletionHunks
            }
            ranges.append(range)
        }
        var result = ""
        result.reserveCapacity(text.count)
        var cursor = text.startIndex
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            result.append(contentsOf: text[cursor..<range.lowerBound])
            cursor = range.upperBound
        }
        result.append(contentsOf: text[cursor..<text.endIndex])
        return result
    }

    private static func occurrenceRange(
        of needle: String,
        occurrence: Int,
        in text: String
    ) -> Range<String.Index>? {
        var searchStart = text.startIndex
        for current in 1...occurrence {
            guard let range = text.range(of: needle, range: searchStart..<text.endIndex) else {
                return nil
            }
            if current == occurrence { return range }
            searchStart = range.upperBound
        }
        return nil
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func semanticBlocks(_ text: String) -> [AIService.PaperContentBlock] {
        // PDF extraction usually expresses visual structure as physical lines,
        // not blank-line-separated paragraphs. Making each line its own deletion
        // unit prevents a model from deleting an abstract sentence merely because
        // it shares a large synthesized paragraph with first-page metadata.
        let lines = text.components(separatedBy: .newlines)
        var texts: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            texts.append(contentsOf: splitOversizedParagraph(trimmed))
        }
        return texts.enumerated().map { index, text in
            AIService.PaperContentBlock(id: String(format: "B%06d", index + 1), text: text)
        }
    }

    private static func splitOversizedParagraph(_ paragraph: String) -> [String] {
        var result: [String] = []
        var current = ""
        for sentence in MacArticleSpeechText.sentences(in: paragraph) {
            if sentence.count > maximumBlockCharacters {
                if !current.isEmpty { result.append(current); current = "" }
                var remainder = sentence[...]
                while remainder.count > maximumBlockCharacters {
                    let end = remainder.index(remainder.startIndex, offsetBy: maximumBlockCharacters)
                    result.append(String(remainder[..<end]))
                    remainder = remainder[end...]
                }
                if !remainder.isEmpty { current = String(remainder) }
            } else if current.isEmpty {
                current = sentence
            } else if current.count + sentence.count + 1 <= maximumBlockCharacters {
                current += " " + sentence
            } else {
                result.append(current)
                current = sentence
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func cleanupRequestChunks(
        system: String,
        sourceTitle: String,
        sourceType: StudioSourceType,
        blocks: [AIService.PaperContentBlock],
        provider: AIProvider,
        model: String
    ) throws -> [[AIService.PaperContentBlock]] {
        guard !blocks.isEmpty else { return [] }
        // Without a published window there is no limit to split against;
        // the whole paper goes in one request.
        guard let inputBudget = AIService.inputCharacterBudget(
            provider: provider,
            model: model,
            requestedMaxTokens: AIService.paperContentDeletionMaxTokens
        ) else {
            return [blocks]
        }
        let completeRequest = AIService.paperContentDeletionRequest(
            system: system,
            sourceTitle: sourceTitle,
            sourceType: sourceType,
            blocks: blocks,
            chunkIndex: 0,
            chunkCount: 1
        )
        guard completeRequest.inputCharacterCount > inputBudget else {
            return [blocks]
        }

        // Reserve the exact fixed prompt cost with deliberately wider numeric
        // placeholders than any practical cleanup queue can reach. The
        // remaining budget belongs entirely to serialized block JSON.
        let scaffold = AIService.paperContentDeletionRequest(
            system: system,
            sourceTitle: sourceTitle,
            sourceType: sourceType,
            blocks: [],
            chunkIndex: 999_998,
            chunkCount: 999_999
        )
        let blockBudget = inputBudget - scaffold.inputCharacterCount
        guard blockBudget > 0 else {
            throw AIError.apiError(
                "Source Content Cleanup instructions exceed this model's context window."
            )
        }

        var chunks: [[AIService.PaperContentBlock]] = []
        var current: [AIService.PaperContentBlock] = []
        var currentCharacters = 0
        for block in blocks {
            let taggedCharacters = AIService.paperContentDeletionTaggedBlock(block).count
            let addedCharacters = taggedCharacters + (current.isEmpty ? 0 : 2)
            guard taggedCharacters <= blockBudget else {
                throw AIError.apiError(
                    "Source Content Cleanup found a text block larger than this model's context window."
                )
            }
            if !current.isEmpty, currentCharacters + addedCharacters > blockBudget {
                chunks.append(current)
                current = []
                currentCharacters = 0
            }
            current.append(block)
            currentCharacters += taggedCharacters + (current.count == 1 ? 0 : 2)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    static func sidebarHeadingIDs(
        in blocks: [AIService.PaperContentBlock]
    ) -> Set<String> {
        Set(blocks.compactMap { block in
            isSidebarHeading(block.text) ? block.id : nil
        })
    }

    static func validateSidebarDecisions(
        in blocks: [AIService.PaperContentBlock],
        applying plan: AIService.PaperContentDeletionPlan
    ) throws {
        let relocatedHeadingIDs = Set(plan.relocations.compactMap(\.blockIDs.first))
        let keptHeadingIDs = Set(plan.keepInPlaceBoxHeadingIDs)
        guard relocatedHeadingIDs.isDisjoint(with: keptHeadingIDs) else {
            throw AIError.apiError(
                "Source Content Cleanup returned contradictory Box layout decisions."
            )
        }
        guard sidebarHeadingIDs(in: blocks).isSubset(
            of: relocatedHeadingIDs.union(keptHeadingIDs)
        ) else {
            throw AIError.apiError(
                "Source Content Cleanup did not classify every Box heading."
            )
        }
    }

    private static func isSidebarHeading(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.lowercased().hasPrefix("box ") else { return false }
        var remainder = normalized.dropFirst(4)
        guard remainder.first?.isNumber == true else { return false }
        while remainder.first?.isNumber == true { remainder.removeFirst() }
        remainder = remainder.drop(while: { $0.isWhitespace })
        guard let separator = remainder.first else { return false }
        return "|:—–-".contains(separator)
    }

}

/// Serial, resumable drain for the versioned historical cleanup queue. Each
/// source commits independently after its cleanup pass, so cancellation, sleep,
/// or a provider error leaves all remaining work durable and untouched.
actor CanonicalContentCleanupService {
    // Cleanup plans are network-bound and each result commits independently.
    // The two preparation stages overlap, so twelve here plus twelve narration
    // jobs keeps 24 source jobs in flight. A 32+32 live probe exceeded Meta's
    // concurrency ceiling and reduced throughput through 429s and timeouts.
    static let maxCandidatesPerDrain = 12

    private let storage: StorageService
    private let preparation: PaperContentPreparationService
    /// `false` in a Dev build that has not opted in (`PaidSourceCleanupPolicy`):
    /// pending sources are published raw and historical rows are left queued.
    private let runsPaidCleanup: Bool
    private var isDraining = false

    init(
        storage: StorageService,
        aiService: AIService,
        runsPaidCleanup: Bool = PaidSourceCleanupPolicy.runsPaidCleanup
    ) {
        self.storage = storage
        self.preparation = PaperContentPreparationService(aiService: aiService)
        self.runsPaidCleanup = runsPaidCleanup
    }

    /// Clean what the paper's PDF says today, not what an older build stored.
    /// Until `fbfb8c0ad` (2026-08-06) PDF extraction stopped at 50,000
    /// characters, and nothing re-read the PDFs afterwards: on 2026-09-23 about
    /// 245 papers in one library still held a prefix cut mid-word, and every
    /// cleanup since had re-cleaned that prefix. So a paper cleanup extracts
    /// its PDF again, exactly as a new import does, and cleans the complete
    /// text. A paper whose PDF is not on this Mac keeps its stored text.
    static func withCompletePDFExtraction(
        _ candidate: CanonicalContentCleanupCandidate
    ) async -> CanonicalContentCleanupCandidate {
        guard candidate.sourceType == .paper,
              let storedPath = candidate.localFilePath,
              !storedPath.isEmpty else { return candidate }
        let extraction = await Task.detached(priority: .utility) {
            Self.completePDFExtraction(storedPath: storedPath)
        }.value
        guard let extraction, extraction != candidate.raw else { return candidate }
        return candidate.replacingRaw(with: extraction)
    }

    private static func completePDFExtraction(storedPath: String) -> String? {
        #if canImport(PDFKit)
        guard !storedPath.hasPrefix("http://"), !storedPath.hasPrefix("https://"),
              let url = SourceService.resolveLocalFileURL(storedPath),
              url.pathExtension.lowercased() == "pdf",
              StorageService.ensureICloudFileDownloaded(at: url, fileManager: .default),
              let document = PDFDocument(url: url) else { return nil }
        let text = PDFTextExtractor.textWithFigureReferences(
            from: document,
            pages: 0..<document.pageCount
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        #else
        return nil
        #endif
    }

    /// The complete text a cleanup cleans: a paper's whole PDF, or an
    /// article's archived page when the stored text stops short of it.
    static func withCompleteExtraction(
        _ candidate: CanonicalContentCleanupCandidate
    ) async -> CanonicalContentCleanupCandidate {
        switch candidate.sourceType {
        case .paper: return await withCompletePDFExtraction(candidate)
        case .article: return await withCompleteArticleExtraction(candidate)
        default: return candidate
        }
    }

    /// Clean what the article's archived page says when the stored text stops
    /// short of it. Until 06271e382 (2026-08-05) article extraction kept only
    /// its first 50,000 characters, and nothing derived the text again: the
    /// chrome-filter backfill rewrote each archived page from the live site and
    /// left the text alone on purpose, and every cleanup since — cleaner v19's
    /// included — cleaned the stored prefix again. On 2026-10-06 nineteen
    /// articles in one library still ended mid-word at exactly 50,000
    /// characters while their archived pages held the rest; The Illustrated
    /// AlphaFold stopped at "the accuracy of predicted difference" with its
    /// last 15,000 characters, the whole discussion among them, on disk. So an
    /// article cleanup reads its archived page and, when the stored text stops
    /// where the page keeps going, cleans the page's complete text instead.
    /// Stored text that is already whole is cleaned as it is: a fresh
    /// import's, and text that came from somewhere the page does not reach,
    /// such as archive.ph, or an assistant's push for a page that now shows a
    /// paywall's preview.
    static func withCompleteArticleExtraction(
        _ candidate: CanonicalContentCleanupCandidate
    ) async -> CanonicalContentCleanupCandidate {
        guard candidate.sourceType == .article,
              let storedPath = candidate.localFilePath,
              !storedPath.isEmpty else { return candidate }
        let stored = candidate.raw
        let extraction = await Task.detached(priority: .utility) { () -> String? in
            guard let page = Self.archivedPageExtraction(storedPath: storedPath),
                  page != stored,
                  Self.storedArticleText(stored, stopsShortOf: page) else { return nil }
            return page
        }.value
        guard let extraction else { return candidate }
        logger.notice(
            """
            Stored text of \(candidate.sourceID, privacy: .public) stops short of its archived page; \
            cleaning the page's complete text (\(candidate.raw.count, privacy: .public) → \
            \(extraction.count, privacy: .public) characters)
            """
        )
        return candidate.replacingRaw(with: extraction)
    }

    /// The archived page's text, derived the way a newly fetched page's text
    /// is (`SourceService.readableTextFromHTML`). Nil when the page is not on
    /// this Mac or holds no text.
    private static func archivedPageExtraction(storedPath: String) -> String? {
        guard !storedPath.hasPrefix("http://"), !storedPath.hasPrefix("https://"),
              let url = SourceService.resolveLocalFileURL(storedPath),
              ["html", "htm", "xhtml"].contains(url.pathExtension.lowercased()),
              StorageService.ensureICloudFileDownloaded(at: url, fileManager: .default),
              let html = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let text = SourceService.readableTextFromHTML(html)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// Words of the stored text's ending that must recur, in order, in the
    /// archived page before the page counts as continuing it.
    static let archivedPageAnchorWordCount = 12

    /// How much more of the page must follow that ending before the stored
    /// text counts as stopping short: two or three sentences. A page that adds
    /// only a sign-off or a share line after the same last words holds the
    /// same text; the retired cap cut articles with hundreds of words to go.
    static let archivedPageMinimumMissingWords = 40

    /// Share of the stored text's words the page must say before that point.
    /// The rest is room for the site furniture an older extraction kept and
    /// the chrome filter took out of the page: 9% of a capped MDPI review's
    /// words were its menus. A page that says much less of the stored text
    /// there tells it in another order — Research Square prints the version
    /// notice a preprint's stored text ends with above the abstract, 20% of
    /// the way in — or tells something else, and does not complete it.
    static let archivedPageMinimumSharedWordFraction = 0.85

    /// Whether `stored` stops where `page` keeps going: the words before the
    /// stored text's last word recur in the page, the page's next word begins
    /// with that last word (a cap cuts mid-word — "predicted difference" for
    /// "predicted differences"), at least `archivedPageMinimumMissingWords`
    /// more words of the page follow, and the page up to there says
    /// `archivedPageMinimumSharedWordFraction` of the stored text's words.
    /// Words are compared as letters and digits only, case-folded, so text an
    /// older build extracted — list items without dashes, superscripts without
    /// carets, headings without hashes — still lines up with what the page's
    /// extraction says today.
    static func storedArticleText(_ stored: String, stopsShortOf page: String) -> Bool {
        let anchorCount = archivedPageAnchorWordCount
        let storedWords = comparisonWords(stored)
        guard storedWords.count > anchorCount, let lastWord = storedWords.last else { return false }
        let anchor = storedWords[(storedWords.count - 1 - anchorCount)..<(storedWords.count - 1)]
        let pageWords = comparisonWords(page)
        let lastStart = pageWords.count - anchorCount - 1
        guard lastStart >= 0 else { return false }
        // An ending the page says more than once is judged where the page says
        // it last, which is where the least of the page follows it.
        for start in stride(from: lastStart, through: 0, by: -1) {
            let cut = start + anchorCount
            guard pageWords[cut].hasPrefix(lastWord),
                  pageWords[start..<cut].elementsEqual(anchor) else { continue }
            guard pageWords.count - (cut + 1) >= archivedPageMinimumMissingWords else { return false }
            return sharedWordFraction(of: storedWords.dropLast(), in: pageWords[..<cut])
                >= archivedPageMinimumSharedWordFraction
        }
        return false
    }

    private static func comparisonWords(_ text: String) -> [Substring] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    }

    /// How many of `words` `page` also says, each page word counted once.
    private static func sharedWordFraction(
        of words: ArraySlice<Substring>,
        in page: ArraySlice<Substring>
    ) -> Double {
        guard !words.isEmpty else { return 0 }
        var unclaimed: [Substring: Int] = [:]
        for word in page { unclaimed[word, default: 0] += 1 }
        var shared = 0
        for word in words {
            guard let count = unclaimed[word], count > 0 else { continue }
            unclaimed[word] = count - 1
            shared += 1
        }
        return Double(shared) / Double(words.count)
    }

    /// - Parameter backgroundSpendAllowed: false once the learner's daily
    ///   background cap is reached (`BackgroundAIBudget`). Sources whose
    ///   ingestion waits on this pass still run — the learner added them —
    ///   and historical re-clean rows wait for the next day.
    func drain(backgroundSpendAllowed: Bool = true) async -> CanonicalContentCleanupDrainResult {
        guard !isDraining else {
            let remaining = (try? await storage.canonicalContentCleanupQueueCount()) ?? 0
            return CanonicalContentCleanupDrainResult(
                processedCount: 0,
                processedSourceIDs: [],
                remainingCount: remaining,
                errorMessage: nil
            )
        }
        isDraining = true
        defer { isDraining = false }

        await auditStoredContentIntegrity()

        guard runsPaidCleanup else {
            return await publishPendingSourcesWithoutCleanup()
        }

        let candidates: [CanonicalContentCleanupCandidate]
        do {
            _ = try await storage.pruneIneligibleCanonicalContentCleanupQueue()
            candidates = try await storage.canonicalContentCleanupCandidates(
                limit: Self.maxCandidatesPerDrain,
                pendingIngestionOnly: !backgroundSpendAllowed
            )
        } catch {
            return await result(
                processed: 0,
                processedSourceIDs: [],
                error: error.localizedDescription
            )
        }

        let preparation = preparation
        var processed = 0
        var processedSourceIDs: [String] = []
        var firstError: String?
        var failedTransiently = false
        var longestRetryAfter: Double?
        // Interrupted rather than failed. Counted so the drain can say so, and
        // deliberately not part of `processed`, which means work that reached a
        // verdict and left the queue.
        var cancelled = 0
        await withTaskGroup(of: CanonicalContentCleanupOutcome.self) { group in
            for candidate in candidates {
                group.addTask {
                    do {
                        let working = await Self.withCompleteExtraction(candidate)
                        let prepared = try await preparation.prepare(
                            source: AIUsageSource(
                                id: working.sourceID,
                                sourceType: working.sourceType,
                                title: working.title
                            ),
                            rawText: working.raw,
                            sourceType: working.sourceType == .paper ? .paper : .article
                        )
                        return .prepared(candidate: working, content: prepared)
                    } catch {
                        return .failed(
                            candidate: candidate,
                            failure: CanonicalContentCleanupFailure(error)
                        )
                    }
                }
            }

            for await outcome in group {
                let candidate: CanonicalContentCleanupCandidate
                let prepared: PreparedPaperContent?
                let failure: CanonicalContentCleanupFailure?
                switch outcome {
                case .prepared(let completedCandidate, let content):
                    candidate = completedCandidate
                    prepared = content
                    failure = nil
                case .failed(let failedCandidate, let failedOutcome):
                    candidate = failedCandidate
                    prepared = nil
                    failure = failedOutcome
                }

                do {
                    if let prepared {
                        try await storage.applyCanonicalContentCleanup(
                            candidate: candidate,
                            prepared: prepared
                        )
                        processed += 1
                        processedSourceIDs.append(candidate.sourceID)
                        continue
                    }
                } catch {
                    if AITransientErrorClassifier.isCancellation(error) {
                        cancelled += 1
                        continue
                    }
                    if firstError == nil {
                        firstError = "\(candidate.title): \(error.localizedDescription)"
                    }
                    try? await storage.recordCanonicalContentCleanupFailure(
                        sourceID: candidate.sourceID,
                        message: error.localizedDescription,
                        sourceSHA256: candidate.storedTextSHA256,
                        consumesAttempt: false
                    )
                    continue
                }

                if let failure {
                    // A cancelled attempt is not a verdict on this source. The
                    // batch was interrupted -- by the next work event arriving,
                    // by the app quitting -- and this source was never given the
                    // chance to succeed or fail. Recording it would park an
                    // untouched paper behind an error the learner has to clear
                    // by hand, so the durable queue row is left exactly as it
                    // was and the next drain picks it up unchanged.
                    if failure.wasCancelled {
                        cancelled += 1
                        continue
                    }
                    let transient = failure.isTransient
                    if transient {
                        failedTransiently = true
                        if let wait = failure.retryAfterSeconds {
                            longestRetryAfter = max(longestRetryAfter ?? wait, wait)
                        }
                    }
                    if candidate.isPendingIngestion, !transient {
                        try? await storage.failPendingCanonicalContentCleanup(
                            candidate: candidate,
                            message: failure.message
                        )
                        // Terminally parking one pending import frees this
                        // bounded batch to continue with later work.
                        processed += 1
                        processedSourceIDs.append(candidate.sourceID)
                    } else {
                        try? await storage.recordCanonicalContentCleanupFailure(
                            sourceID: candidate.sourceID,
                            message: failure.message,
                            sourceSHA256: candidate.storedTextSHA256,
                            consumesAttempt: false
                        )
                    }
                    if firstError == nil {
                        firstError = "\(candidate.title): \(failure.message)"
                    }
                }
            }
        }
        if cancelled > 0 {
            logger.notice(
                """
                Source cleanup was interrupted with \(cancelled, privacy: .public) source(s) \
                still running; they stay queued and resume on the next drain
                """
            )
        }
        var drained = await result(
            processed: processed,
            processedSourceIDs: processedSourceIDs,
            error: firstError
        )
        drained.failedTransiently = failedTransiently
        drained.retryAfterSeconds = longestRetryAfter
        return drained
    }

    /// Rows per storage call of the schema-134 integrity audit. Each batch
    /// hashes stored text inside one write transaction, so it stays small
    /// enough that interactive storage work is never held behind it for long.
    static let integrityAuditBatchSize = 50

    /// Work the schema-134 audit queue down before choosing candidates, so a
    /// row it finds storing less than its preparation attests is cleaned in
    /// this same drain. One bounded batch per storage call; the queue empties
    /// once per library and then costs a single count.
    private func auditStoredContentIntegrity() async {
        do {
            while true {
                let batch = try await storage.auditCanonicalContentIntegrity(
                    limit: Self.integrityAuditBatchSize
                )
                if !batch.requeuedSourceIDs.isEmpty {
                    logger.error(
                        """
                        Stored text of \(batch.requeuedSourceIDs.count, privacy: .public) source(s) did not match \
                        its preparation hash; restated as uncleaned and queued for cleanup: \
                        \(batch.requeuedSourceIDs.joined(separator: ", "), privacy: .public)
                        """
                    )
                }
                if batch.audited == 0 || batch.remaining == 0 { break }
                await Task.yield()
            }
        } catch {
            logger.error(
                "Source text integrity audit failed; it resumes on the next drain: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// The Dev build's drain. No model is called: every source still waiting
    /// on its ingestion clean-up is published with its raw extraction so it
    /// becomes readable, and historical re-clean rows are neither processed
    /// nor discarded, so an opted-in launch can still drain them later.
    private func publishPendingSourcesWithoutCleanup() async -> CanonicalContentCleanupDrainResult {
        let candidates: [CanonicalContentCleanupCandidate]
        do {
            _ = try await storage.pruneIneligibleCanonicalContentCleanupQueue()
            candidates = try await storage.canonicalContentCleanupCandidates(
                limit: Self.maxCandidatesPerDrain,
                pendingIngestionOnly: true
            )
        } catch {
            return await result(
                processed: 0,
                processedSourceIDs: [],
                error: error.localizedDescription
            )
        }
        var processedSourceIDs: [String] = []
        var firstError: String?
        for candidate in candidates {
            do {
                try await storage.publishCanonicalContentWithoutCleanup(candidate: candidate)
                processedSourceIDs.append(candidate.sourceID)
            } catch {
                // An interrupted pass says nothing about this source: its queue
                // row stays as it is and the next drain resumes from here.
                if AITransientErrorClassifier.isCancellation(error) { break }
                if firstError == nil {
                    firstError = "\(candidate.title): \(error.localizedDescription)"
                }
                try? await storage.recordCanonicalContentCleanupFailure(
                    sourceID: candidate.sourceID,
                    message: error.localizedDescription,
                    sourceSHA256: candidate.storedTextSHA256,
                    consumesAttempt: false
                )
            }
        }
        return await result(
            processed: processedSourceIDs.count,
            processedSourceIDs: processedSourceIDs,
            error: firstError
        )
    }

    private func result(
        processed: Int,
        processedSourceIDs: [String],
        error: String?
    ) async -> CanonicalContentCleanupDrainResult {
        let remaining = (try? await storage.canonicalContentCleanupQueueCount()) ?? 0
        return CanonicalContentCleanupDrainResult(
            processedCount: processed,
            processedSourceIDs: processedSourceIDs,
            remainingCount: remaining,
            errorMessage: error
        )
    }
}
