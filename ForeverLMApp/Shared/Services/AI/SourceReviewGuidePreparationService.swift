import Foundation

struct SourceReviewGuide: Codable, Sendable, Equatable {
    /// Version 3 follows the learner's selected Chat model. New guides are
    /// always generated at the current version, but every earlier version stays
    /// readable: a guide that already covers the source's canonical text is
    /// never regenerated just because the generator moved on. Treating an older
    /// version as stale turned one release into a whole-library regeneration.
    static let currentVersion = 3

    static func isCompatible(generatorVersion: Int, sourceType: StudioSourceType) -> Bool {
        generatorVersion >= 1 && generatorVersion <= currentVersion
    }

    let sourceSHA256: String
    let guide: String
    let generatorVersion: Int
    let generatedAt: Date
}

struct SourceReviewGuideCandidate: Sendable {
    let sourceID: String
    let sourceType: StudioSourceType
    let title: String
    let content: String
    let sourceSHA256: String
    let attemptCount: Int
}

enum SourceReviewGuidePreparationError: LocalizedError, Sendable {
    case noConfiguredModel
    case sourceNotReady(String)
    case resultNotPersisted(String)

    var errorDescription: String? {
        switch self {
        case .noConfiguredModel:
            return "Source Review Guide has no configured model."
        case .sourceNotReady(let sourceID):
            return "Source \(sourceID) does not have canonical text ready for review."
        case .resultNotPersisted(let sourceID):
            return "The review guide for source \(sourceID) could not be loaded after it was prepared."
        }
    }
}

/// Preparation of a single source's review curriculum. A guide is generated
/// for a source a review is actually about to happen on — the one a voice
/// session was opened on, the one its greeting offers, the one the tutor just
/// loaded — and, ahead of time, for the few sources a review is likely to be
/// about today (`prebuildLikelyReviews`), never for the library at large.
/// Concurrent requests for the same source share one generation, and the
/// result is accepted only while its source hash matches.
actor SourceReviewGuidePreparationService {
    private let storage: StorageService
    private let aiService: AIService
    private var inFlight: [String: Task<SourceReviewGuide, Error>] = [:]

    init(storage: StorageService, aiService: AIService) {
        self.storage = storage
        self.aiService = aiService
    }

    /// Start this source's guide now without waiting for it, and swallow any
    /// failure: the caller is guessing at what the learner will review next, so
    /// a guess that cannot be prepared must not surface as an error. A later
    /// `prepare` joins the same generation rather than starting a second one,
    /// which is the whole point — by the time `prepare_review` asks, the guide
    /// is usually finished, and the review starts instead of stalling on a
    /// cold generation over the source's full text.
    nonisolated func warm(sourceID: String) {
        Task { [weak self] in
            _ = try? await self?.prepare(sourceID: sourceID)
        }
    }

    /// Return this source's existing guide, or generate one now. Every review
    /// entry point funnels through here, so a source that was never reviewed
    /// never cost a generation.
    func prepare(sourceID: String) async throws -> SourceReviewGuide {
        if let prepared = try await storage.loadSourceReviewGuide(sourceID) {
            return prepared
        }
        if let task = inFlight[sourceID] {
            return try await task.value
        }
        var candidate = try await storage.sourceReviewGuideCandidate(sourceID: sourceID)
        if candidate == nil {
            // Nothing enqueues preparation ahead of time, so this request is
            // what creates the durable row. Ready canonical text deterministically
            // produces a candidate; anything else is genuinely not reviewable yet.
            try await storage.ensureSourceReviewGuidePreparationQueued(sourceID: sourceID)
            candidate = try await storage.sourceReviewGuideCandidate(sourceID: sourceID)
        }
        guard let candidate else {
            // A concurrent request may have committed between the first read and
            // candidate lookup.
            if let prepared = try await storage.loadSourceReviewGuide(sourceID) {
                return prepared
            }
            throw SourceReviewGuidePreparationError.sourceNotReady(sourceID)
        }
        guard let config = KeychainService.resolveConfig(for: .realtimeReviewPreparation) else {
            throw SourceReviewGuidePreparationError.noConfiguredModel
        }
        return try await prepare(candidate: candidate, config: config)
    }

    /// Writes guides for the sources a review is likely to be about soon —
    /// today's Schedule, then what was engaged with in the last two days — so
    /// a quiz started from the car answers "yes" with its first question
    /// instead of a cold generation over a whole transcript (product owner,
    /// 2026-09-22: "how can we make it a LOT faster by maybe prepping work in
    /// advance?"). At most `maximum` generations are attempted; the caller
    /// owns the daily budget. Returns how many attempts spent a model call.
    func prebuildLikelyReviews(maximum: Int) async -> Int {
        guard maximum > 0,
              KeychainService.resolveConfig(for: .realtimeReviewPreparation) != nil else { return 0 }
        let sourceIDs: [String]
        do {
            sourceIDs = try await storage.likelyReviewSourceIDsWithoutGuide(
                lookbackDays: 2,
                limit: maximum * 2
            )
        } catch {
            return 0
        }
        var attempts = 0
        for sourceID in sourceIDs where attempts < maximum {
            guard !Task.isCancelled else { break }
            do {
                _ = try await prepare(sourceID: sourceID)
                attempts += 1
            } catch SourceReviewGuidePreparationError.sourceNotReady {
                // Text still being cleaned: nothing was spent, and the next
                // pass or an on-demand request picks it up.
                continue
            } catch {
                // A failed generation may still have been billed; it counts,
                // and its queue row's attempt count keeps it out of later
                // passes after a second failure.
                attempts += 1
            }
        }
        return attempts
    }

    private func prepare(
        candidate: SourceReviewGuideCandidate,
        config: AITaskConfig
    ) async throws -> SourceReviewGuide {
        if let task = inFlight[candidate.sourceID] {
            return try await task.value
        }

        let task = Task { [aiService, storage] in
            do {
                let guide = try await aiService.prepareSourceReviewGuide(
                    source: AIUsageSource(
                        id: candidate.sourceID,
                        sourceType: candidate.sourceType,
                        title: candidate.title
                    ),
                    sourceText: candidate.content,
                    config: config
                )
                try await storage.applySourceReviewGuide(candidate: candidate, guide: guide)
                guard let prepared = try await storage.loadSourceReviewGuide(candidate.sourceID) else {
                    throw SourceReviewGuidePreparationError.resultNotPersisted(candidate.sourceID)
                }
                return prepared
            } catch {
                let generationError = error
                do {
                    try await storage.recordSourceReviewGuideFailure(
                        sourceID: candidate.sourceID,
                        message: generationError.localizedDescription
                    )
                } catch {
                    throw AIError.apiError(
                        "Could not persist review preparation failure: \(error.localizedDescription)"
                    )
                }
                throw generationError
            }
        }
        inFlight[candidate.sourceID] = task
        do {
            let prepared = try await task.value
            inFlight[candidate.sourceID] = nil
            return prepared
        } catch {
            inFlight[candidate.sourceID] = nil
            throw error
        }
    }
}
