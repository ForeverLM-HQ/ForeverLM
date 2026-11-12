import CryptoKit
import Foundation
import os

private let logger = Logger(
    subsystem: "com.foreverlm",
    category: "SourceListenableContentPreparation"
)

struct PreparedPaperNarration: Sendable, Equatable {
    let text: String
    let sourceContentSignature: String
    let preparationSignature: String
}

struct SourceListenableContentCandidate: Sendable {
    let sourceID: String
    let title: String
    let sourceType: StudioSourceType
    let canonicalText: String
    let sourceSHA256: String
}

struct SourceListenableContentDrainResult: Sendable {
    let processedCount: Int
    let processedSourceIDs: [String]
    let remainingCount: Int
    let errorMessage: String?
}

private enum SourceListenableContentPreparationOutcome: Sendable {
    case prepared(
        candidate: SourceListenableContentCandidate,
        text: String,
        preparationSignature: String?
    )
    /// `wasCancelled` is decided where the typed error still exists: an
    /// interrupted preparation is not a failed one and must not spend the
    /// source's attempt budget.
    case failed(
        candidate: SourceListenableContentCandidate,
        message: String,
        wasCancelled: Bool
    )
}

private actor PaperNarrationMemoryCache {
    static let shared = PaperNarrationMemoryCache()

    private var values: [String: PreparedPaperNarration] = [:]

    func value(for key: String) -> PreparedPaperNarration? {
        values[key]
    }

    func insert(_ value: PreparedPaperNarration, for key: String) {
        values[key] = value
    }
}

/// Bounded, durable preparation of the text Listen will consume. Papers and
/// articles use the configured speech-adaptation LLM; other text sources are
/// normalized locally.
/// A small batch prepares concurrently while each result commits independently,
/// so quitting or sleeping never loses the rest of the queue.
actor SourceListenableContentPreparationService {
    // Narration preparation is likewise network-bound and transactionally
    // independent per source. Match canonical cleanup's catch-up concurrency so
    // the second stage can keep pace instead of becoming the new bottleneck.
    static let maxCandidatesPerDrain = 12

    private let storage: StorageService
    private let textToSpeechPreparation: PaperTextToSpeechPreparationService
    private var isDraining = false

    init(storage: StorageService, aiService: AIService) {
        self.storage = storage
        self.textToSpeechPreparation = PaperTextToSpeechPreparationService(aiService: aiService)
    }

    private func queuedListenableCount() async -> Int {
        do {
            return try await storage.sourceListenableContentQueueCount()
        } catch {
            logger.error("Counting the queued listenable content failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    /// - Parameter backgroundSpendAllowed: false once the learner's daily
    ///   background cap is reached; the queue waits for the next day. Listen
    ///   itself still prepares a source when the learner presses it.
    func drain(backgroundSpendAllowed: Bool = true) async -> SourceListenableContentDrainResult {
        guard backgroundSpendAllowed else {
            return SourceListenableContentDrainResult(
                processedCount: 0,
                processedSourceIDs: [],
                remainingCount: await queuedListenableCount(),
                errorMessage: nil
            )
        }
        guard !isDraining else {
            return SourceListenableContentDrainResult(
                processedCount: 0,
                processedSourceIDs: [],
                remainingCount: await queuedListenableCount(),
                errorMessage: nil
            )
        }
        isDraining = true
        defer { isDraining = false }

        let candidates: [SourceListenableContentCandidate]
        do {
            candidates = try await storage.sourceListenableContentCandidates(
                limit: Self.maxCandidatesPerDrain
            )
        } catch {
            return SourceListenableContentDrainResult(
                processedCount: 0,
                processedSourceIDs: [],
                remainingCount: await queuedListenableCount(),
                errorMessage: error.localizedDescription
            )
        }

        let textToSpeechPreparation = textToSpeechPreparation
        var processed = 0
        var processedSourceIDs: [String] = []
        var firstError: String?
        var cancelled = 0
        await withTaskGroup(of: SourceListenableContentPreparationOutcome.self) { group in
            for candidate in candidates {
                group.addTask {
                    do {
                        if TextToSpeechPreparationPolicy.usesAIPreparation(
                            sourceType: candidate.sourceType.rawValue
                        ) {
                            let prepared = try await textToSpeechPreparation.prepare(
                                source: AIUsageSource(
                                    id: candidate.sourceID,
                                    sourceType: candidate.sourceType,
                                    title: candidate.title
                                ),
                                canonicalText: candidate.canonicalText
                            )
                            return .prepared(
                                candidate: candidate,
                                text: prepared.text,
                                preparationSignature: prepared.preparationSignature
                            )
                        }
                        return .prepared(
                            candidate: candidate,
                            text: MacArticleSpeechText.narrationText(from: candidate.canonicalText),
                            preparationSignature: nil
                        )
                    } catch {
                        return .failed(
                            candidate: candidate,
                            message: error.localizedDescription,
                            wasCancelled: AITransientErrorClassifier.isCancellation(error)
                        )
                    }
                }
            }

            for await outcome in group {
                let candidate: SourceListenableContentCandidate
                let failureMessage: String?
                switch outcome {
                case .prepared(let preparedCandidate, let text, let preparationSignature):
                    candidate = preparedCandidate
                    do {
                        try await storage.applySourceListenableContent(
                            candidate: candidate,
                            text: text,
                            preparationSignature: preparationSignature
                        )
                        processed += 1
                        processedSourceIDs.append(candidate.sourceID)
                        continue
                    } catch KnowledgeStoreError.sourceContentChanged {
                        // The canonical-content write already refreshed the
                        // durable queue. Count this superseded snapshot as
                        // forward progress so the event-driven drain selects
                        // the replacement snapshot immediately.
                        processed += 1
                        continue
                    } catch where AITransientErrorClassifier.isCancellation(error) {
                        cancelled += 1
                        continue
                    } catch {
                        failureMessage = error.localizedDescription
                    }
                case .failed(let failedCandidate, let message, let wasCancelled):
                    // Cancellation is not a result. Recording it would burn an
                    // attempt and demote the source in the queue's ordering for
                    // work that never ran, so the row is left untouched.
                    if wasCancelled {
                        cancelled += 1
                        continue
                    }
                    candidate = failedCandidate
                    failureMessage = message
                }

                if let failureMessage {
                    do {
                        try await storage.recordSourceListenableContentFailure(
                            sourceID: candidate.sourceID,
                            message: failureMessage,
                            sourceSHA256: candidate.sourceSHA256
                        )
                    } catch {
                        logger.error("Could not record the listenable-content failure: \(error.localizedDescription, privacy: .public)")
                    }
                    if firstError == nil {
                        firstError = "\(candidate.title): \(failureMessage)"
                    }
                }
            }
        }

        if cancelled > 0 {
            logger.notice(
                """
                Listenable-content preparation was interrupted with \(cancelled, privacy: .public) \
                source(s) still running; they stay queued and resume on the next drain
                """
            )
        }
        return SourceListenableContentDrainResult(
            processedCount: processed,
            processedSourceIDs: processedSourceIDs,
            remainingCount: await queuedListenableCount(),
            errorMessage: firstError
        )
    }
}

/// Builds the speech-only paper/article derivative immediately before TTS.
/// Canonical source text remains unchanged for reading, search, chat, MCP, and
/// review.
struct PaperTextToSpeechPreparationService: Sendable {
    // A sidebar can span several thousand extracted characters and interrupt a
    // paragraph across a page boundary. Larger ordering windows let the model
    // see the fragment before the box and its continuation after the box in one
    // validated plan; the previous 12k windows split the Scannell example at
    // exactly that boundary and made a correct relocation inexpressible.
    private static let maximumRequestCharacters = 48_000
    private let aiService: AIService

    init(aiService: AIService = AIService()) {
        self.aiService = aiService
    }

    static func currentPreparationSignature() async -> String? {
        await Task.detached(priority: .utility) {
            guard let config = KeychainService.resolveConfig(for: .paperTextToSpeechPreparation) else {
                return nil
            }
            return preparationSignature(config: config)
        }.value
    }

    func prepare(source: AIUsageSource, canonicalText: String) async throws -> PreparedPaperNarration {
        // Some callers are @MainActor playback controllers. Keep hashing, cache
        // reads, block/chunk construction, validation, and reconstruction off the
        // UI executor even when preparation is initiated by a Listen click.
        let sessionID = AIUsageAttribution.sessionID
        let taskLabel = AIUsageAttribution.task
        let learnerAsked = AIUsageAttribution.learnerAsked
        let task = Task.detached(priority: .utility) {
            try await AIUsageAttribution.$sessionID.withValue(sessionID) {
                try await AIUsageAttribution.$task.withValue(taskLabel) {
                    try await AIUsageAttribution.$learnerAsked.withValue(learnerAsked) {
                        try await AIUsageAttribution.withSource(source) {
                            try await self.prepareAttributed(source: source, canonicalText: canonicalText)
                        }
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
        canonicalText: String
    ) async throws -> PreparedPaperNarration {
        let normalized = canonicalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw AIError.invalidResponse }
        guard let config = KeychainService.resolveConfig(for: .paperTextToSpeechPreparation) else {
            let reason = KeychainService.backgroundAIUnavailableMessage(for: .paperTextToSpeechPreparation)
                ?? "Sign in with Apple to prepare this source for text-to-speech."
            throw AIError.apiError(reason)
        }

        let sourceSignature = normalized.sha256Hex
        let preparationSignature = Self.preparationSignature(config: config)
        let cacheKey = "\(source.id)\u{1F}\(sourceSignature)\u{1F}\(preparationSignature)"
        if let cached = await PaperNarrationMemoryCache.shared.value(for: cacheKey) {
            return cached
        }
        if let cached = Self.syncedNarration(
            sourceID: source.id,
            sourceSignature: sourceSignature,
            preparationSignature: preparationSignature
        ) {
            await PaperNarrationMemoryCache.shared.insert(cached, for: cacheKey)
            return cached
        }

        let blocks = PaperContentPreparationService.semanticBlocks(normalized)
        let chunks = Self.requestChunks(blocks)
        guard !chunks.isEmpty else { throw AIError.invalidResponse }

        // The windows never reference one another (a plan may not cross its
        // chunk's boundary), so they are asked at once rather than one after
        // the other: a long paper waits for its slowest window, not the sum.
        // The plans are merged in window order, so the result is the same as
        // the sequential run's.
        let aiService = self.aiService
        let chunkCount = chunks.count
        let plans = try await withThrowingTaskGroup(
            of: (Int, AIService.PaperSpeechAdaptationPlan).self
        ) { group in
            for (index, chunk) in chunks.enumerated() {
                group.addTask {
                    let plan = try await aiService.paperSpeechAdaptationPlan(
                        source: source,
                        blocks: chunk,
                        config: config,
                        chunkIndex: index,
                        chunkCount: chunkCount
                    )
                    return (index, plan)
                }
            }
            var byIndex: [Int: AIService.PaperSpeechAdaptationPlan] = [:]
            for try await (index, plan) in group { byIndex[index] = plan }
            return byIndex
        }
        var plan = AIService.PaperSpeechAdaptationPlan.empty
        for index in 0..<chunkCount {
            if let chunkPlan = plans[index] { plan = plan.merging(chunkPlan) }
        }

        let text = try Self.reconstruct(blocks: blocks, applying: plan)
        let prepared = PreparedPaperNarration(
            text: text,
            sourceContentSignature: sourceSignature,
            preparationSignature: preparationSignature
        )
        await PaperNarrationMemoryCache.shared.insert(prepared, for: cacheKey)
        return prepared
    }

    static func reconstruct(
        blocks: [AIService.PaperContentBlock],
        applying plan: AIService.PaperSpeechAdaptationPlan
    ) throws -> String {
        let knownIDs = Set(blocks.map(\.id))
        let adaptedIDs = Set(plan.adaptations.flatMap(\.blockIDs))
        let relocatedIDs = Set(plan.relocations.flatMap(\.blockIDs))
        let deletionIDs = Set(plan.removeText.map(\.blockID))
        let relocationAnchors = Set(plan.relocations.map(\.insertAfterBlockID))
        guard adaptedIDs.isSubset(of: knownIDs),
              relocatedIDs.isSubset(of: knownIDs),
              deletionIDs.isSubset(of: knownIDs),
              relocationAnchors.isSubset(of: knownIDs),
              adaptedIDs.isDisjoint(with: relocatedIDs),
              adaptedIDs.isDisjoint(with: relocationAnchors),
              relocatedIDs.isDisjoint(with: relocationAnchors) else {
            throw AIError.apiError("Text-to-Speech Preparation referenced an unknown block.")
        }

        let indexByID = Dictionary(uniqueKeysWithValues: blocks.enumerated().map { ($0.element.id, $0.offset) })
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
                throw AIError.apiError("Text-to-Speech Preparation returned an invalid sidebar relocation.")
            }
            validatedRelocationIDs.formUnion(relocation.blockIDs)
        }

        let adaptationByFirstID = Dictionary(
            uniqueKeysWithValues: plan.adaptations.compactMap { adaptation in
                adaptation.blockIDs.first.map { ($0, adaptation) }
            }
        )
        let relocationsByAnchor = Dictionary(grouping: plan.relocations, by: \.insertAfterBlockID)
        let deletionsByBlock = Dictionary(grouping: plan.removeText, by: \.blockID)
        let blockByID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        var output: [String] = []
        var consumed = Set<String>()
        // A table or figure the PDF placed inside a main-text sentence — the
        // extractor reads a two-column page in physical order — would have its
        // spoken summary read between the halves of that sentence. Such a
        // summary waits until the sentence it interrupted has ended.
        var deferredSpokenText: [String] = []

        func appendUnadaptedBlock(_ block: AIService.PaperContentBlock) throws {
            let cleaned = try applyingInlineDeletions(
                deletionsByBlock[block.id] ?? [],
                to: block.text
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { output.append(cleaned) }
        }

        func flushDeferredSpokenTextIfSentenceEnded() {
            guard !deferredSpokenText.isEmpty,
                  output.last.map(endsSentence) ?? true else { return }
            output.append(contentsOf: deferredSpokenText)
            deferredSpokenText.removeAll()
        }

        for block in blocks {
            if consumed.contains(block.id) || relocatedIDs.contains(block.id) { continue }
            if let adaptation = adaptationByFirstID[block.id] {
                consumed.formUnion(adaptation.blockIDs)
                if let spoken = adaptation.spokenText {
                    if let last = output.last, !endsSentence(last) {
                        deferredSpokenText.append(spoken)
                    } else {
                        output.append(spoken)
                    }
                }
            } else {
                try appendUnadaptedBlock(block)
                flushDeferredSpokenTextIfSentenceEnded()
            }
            if let relocations = relocationsByAnchor[block.id] {
                for relocation in relocations.sorted(by: {
                    (indexByID[$0.blockIDs[0]] ?? .max) < (indexByID[$1.blockIDs[0]] ?? .max)
                }) {
                    for blockID in relocation.blockIDs {
                        guard let movedBlock = blockByID[blockID] else {
                            throw AIError.apiError("Text-to-Speech Preparation referenced an unknown relocated block.")
                        }
                        try appendUnadaptedBlock(movedBlock)
                    }
                }
            }
        }

        output.append(contentsOf: deferredSpokenText)

        let narration = CloudArticleTTS.reflowedForSpeech(output.joined(separator: "\n"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard MacArticleSpeechText.containsLetterOrDigit(narration) else {
            throw AIError.apiError("Text-to-Speech Preparation returned no narratable text.")
        }
        return narration
    }

    /// Whether narration may pause here: the text ends in sentence-closing
    /// punctuation, optionally followed by a closing quote or bracket. A
    /// heading without punctuation does not count, so a table right after a
    /// heading is read after the section's first paragraph rather than before.
    static func endsSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return true }
        let closers: Set<Character> = [".", "!", "?", ":", ";", "\"", "\u{201D}", "\u{2019}", ")", "]"]
        if last == ".", trimmed.hasSuffix("...") { return true }
        return closers.contains(last)
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
                  deletion.exactText.count <= 160,
                  let range = PaperContentPreparationService.occurrenceRange(
                      of: deletion.exactText,
                      occurrence: deletion.occurrence,
                      in: text
                  ),
                  !ranges.contains(where: { $0.overlaps(range) }) else {
                throw AIError.apiError("Text-to-Speech Preparation returned an invalid citation deletion.")
            }
            ranges.append(range)
        }

        var result = ""
        var cursor = text.startIndex
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            result.append(contentsOf: text[cursor..<range.lowerBound])
            cursor = range.upperBound
        }
        result.append(contentsOf: text[cursor..<text.endIndex])
        return result
    }

    private static func requestChunks(
        _ blocks: [AIService.PaperContentBlock]
    ) -> [[AIService.PaperContentBlock]] {
        var result: [[AIService.PaperContentBlock]] = []
        var current: [AIService.PaperContentBlock] = []
        var currentCharacters = 0
        for block in blocks {
            let encodedCharacters = block.id.count * 2 + block.text.count + 24
            if !current.isEmpty, currentCharacters + encodedCharacters > maximumRequestCharacters {
                result.append(current)
                current = []
                currentCharacters = 0
            }
            current.append(block)
            currentCharacters += encodedCharacters
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func preparationSignature(config: AITaskConfig) -> String {
        let material = [
            String(PaperNarrationFilter.version),
            config.provider.rawValue,
            config.model,
            config.effort?.rawValue ?? "",
            config.speed?.rawValue ?? "",
            AITask.paperTextToSpeechPreparation.effectivePrompt ?? Prompts.paperTextToSpeechPreparation,
        ].joined(separator: "\u{1F}")
        return PaperNarrationFilter.preparationContractPrefix + material.sha256Hex
    }

    private static func syncedNarration(
        sourceID: String,
        sourceSignature: String,
        preparationSignature: String
    ) -> PreparedPaperNarration? {
        guard let manifest = SyncedArticleAudioStore.loadManifestIgnoringChunks(sourceID: sourceID),
              manifest.usesCurrentNarration,
              manifest.sourceContentSignature == sourceSignature,
              manifest.narrationPreparationSignature == preparationSignature,
              let text = try? SyncedArticleAudioStore.loadSourceText(for: manifest),
              MacArticleSpeechText.containsLetterOrDigit(text) else {
            return nil
        }
        return PreparedPaperNarration(
            text: text,
            sourceContentSignature: sourceSignature,
            preparationSignature: preparationSignature
        )
    }
}
