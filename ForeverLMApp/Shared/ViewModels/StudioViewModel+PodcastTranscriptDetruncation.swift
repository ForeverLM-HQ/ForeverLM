import Foundation
import OSLog

struct PodcastTranscriptDetruncationDrainResult: Sendable {
    let restoredCount: Int
    let verifiedCount: Int
    let restoredSourceIDs: [String]
    let remainingCount: Int
    let errorMessage: String?

    /// Episodes this drain settled, restored or found whole.
    var auditedCount: Int { restoredCount + verifiedCount }
}

/// Restores podcast transcripts that were stored under the retired
/// 50,000-character import cap.
///
/// Each queued episode's stored transcript is measured against its episode's
/// TTML text by `PodcastTranscriptCompleteness`: where the transcript stops in
/// that text says whether the cap cut it. The measurement asks no model. An
/// episode whose TTML this Mac stores is measured locally; one with none (its
/// transcript was made on another Mac, and the TTML does not sync) is
/// measured against one fetch of Apple's TTML. Only a cut episode costs
/// anything, and only for the formatting pass, which a hidden episode never
/// gets.
///
/// Until schema 167 this audit compared lengths: a transcript holding 85% of
/// the TTML text counted as complete, which every capped episode of 50,000 to
/// 58,800 characters did, so they were marked done with their end missing.
@MainActor
final class PodcastTranscriptDetruncationService {

    /// Extraction is local but not trivial — about a tenth of a second for an
    /// hour's TTML, half a second for the longest — so the audit moves in small
    /// batches between other derived-source work rather than in one pass.
    static let maxCandidatesPerDrain = 4

    /// Episodes measured against a fetched TTML in one drain. Each is a request
    /// to Apple, so a few at a time.
    static let maxFetchesPerDrain = 2

    typealias TranscriptFetch = @Sendable (Int64, String) async -> StudioViewModel.PodcastTranscriptFetchOutcome

    /// A fetch that failed for a reason that passes (network, token, rate
    /// limit): the episode waits and is tried again.
    struct TransientFetchFailure: LocalizedError {
        var errorDescription: String? {
            "Apple Podcasts could not be reached for the episode's transcript."
        }
    }

    /// The stored transcript changed between the measurement and the write.
    struct TranscriptChangedFailure: LocalizedError {
        var errorDescription: String? {
            "The transcript changed while it was measured; it is measured again."
        }
    }

    /// The formatting pass a restored episode gets (speaker names, paragraphs,
    /// the ad reads it marks); nil when it could not run.
    typealias TranscriptFormatter = @Sendable (
        _ text: String,
        _ candidate: PodcastTranscriptDetruncationCandidate,
        _ config: AITaskConfig
    ) async -> String?

    private let storage: StorageService
    private let homeDirectory: String
    private let fetchAppleTranscript: TranscriptFetch
    private let formattingConfig: @MainActor () -> AITaskConfig?
    private let formatTranscript: TranscriptFormatter
    private let log: Logger
    private var isDraining = false

    init(
        storage: StorageService,
        aiService: AIService,
        homeDirectory: String = BookmarkAccessManager.realHomeDirectory,
        fetchAppleTranscript: @escaping TranscriptFetch = { trackID, homeDirectory in
            await StudioViewModel.fetchPodcastTranscriptOffMain(trackId: trackID, homeDir: homeDirectory)
        },
        formattingConfig: @escaping @MainActor () -> AITaskConfig? = {
            KeychainService.resolveConfig(for: .transcriptFormatting)
        },
        formatTranscript: TranscriptFormatter? = nil
    ) {
        let log = Logger(subsystem: "com.foreverlm", category: "PodcastTranscriptDetruncation")
        self.storage = storage
        self.homeDirectory = homeDirectory
        self.fetchAppleTranscript = fetchAppleTranscript
        self.formattingConfig = formattingConfig
        self.formatTranscript = formatTranscript ?? { text, candidate, config in
            await StudioViewModel.formatPodcastTranscriptOffMain(
                text,
                sourceID: candidate.sourceID,
                episodeTitle: candidate.title,
                podcastName: candidate.podcastName,
                aiService: aiService,
                config: config,
                log: log
            )
        }
        self.log = log
    }

    func drain() async -> PodcastTranscriptDetruncationDrainResult {
        guard !isDraining else { return await result(restored: [], verified: 0, error: nil) }
        isDraining = true
        defer { isDraining = false }

        let candidates: [PodcastTranscriptDetruncationCandidate]
        do {
            candidates = try await storage.podcastTranscriptDetruncationCandidates(
                fetchingTTML: false,
                limit: Self.maxCandidatesPerDrain
            ) + storage.podcastTranscriptDetruncationCandidates(
                fetchingTTML: true,
                limit: Self.maxFetchesPerDrain
            )
        } catch {
            return await result(restored: [], verified: 0, error: error.localizedDescription)
        }
        guard !candidates.isEmpty else {
            return await result(restored: [], verified: 0, error: nil)
        }

        // Resolved once per drain, and only used for episodes that turn out to
        // be cut. A missing model never blocks the repair: restoring the whole
        // episode as plain text is strictly better than leaving part of it in
        // place, and the formatting can catch up later.
        let formattingConfig = self.formattingConfig()

        var restored: [String] = []
        var verified = 0
        var firstError: String?

        for candidate in candidates {
            do {
                if try await audit(candidate, formattingConfig: formattingConfig) {
                    restored.append(candidate.sourceID)
                } else {
                    verified += 1
                }
            } catch {
                let message = error.localizedDescription
                if firstError == nil { firstError = "\(candidate.title): \(message)" }
                let attempt = candidate.attemptCount + 1
                do {
                    try await storage.recordPodcastTranscriptDetruncationFailure(
                        sourceID: candidate.sourceID,
                        message: message,
                        retryAfter: Date().addingTimeInterval(
                            KnowledgeStore.podcastTranscriptAuditRetryDelay(afterAttempt: attempt)
                        )
                    )
                } catch {
                    log.error("Recording a transcript audit failure failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        return await result(restored: restored, verified: verified, error: firstError)
    }

    /// Returns true when the episode was cut and has been restored.
    private func audit(
        _ candidate: PodcastTranscriptDetruncationCandidate,
        formattingConfig: AITaskConfig?
    ) async throws -> Bool {
        guard let inputs = try await storage.podcastTranscriptAuditInputs(sourceID: candidate.sourceID) else {
            // The transcript went since the episode was queued. Nothing is
            // recorded: a new one is hydrated whole, or queued again by the
            // save that writes it.
            try await storage.removePodcastTranscriptFromDetruncationQueue(sourceID: candidate.sourceID)
            return false
        }

        let rawTTML: String
        let fetched: Bool
        if let stored = inputs.rawTTML {
            rawTTML = stored
            fetched = false
        } else if let trackID = candidate.appleTrackID {
            switch await fetchAppleTranscript(trackID, homeDirectory) {
            case .available(let ttml):
                rawTTML = ttml
                fetched = true
            case .unavailable:
                // Nothing to measure against, now or on a retry.
                try await storage.recordPodcastTranscriptAudit(
                    sourceID: candidate.sourceID,
                    ttmlSHA256: nil,
                    outcome: .noTranscript
                )
                return false
            case .failed:
                throw TransientFetchFailure()
            }
        } else {
            // Queued with a TTML that has since gone, and not a public Apple
            // episode: nothing to measure against.
            try await storage.recordPodcastTranscriptAudit(
                sourceID: candidate.sourceID,
                ttmlSHA256: nil,
                outcome: .noTranscript
            )
            return false
        }

        // The extraction, the hash and the measurement run off the main actor
        // in one hop: a long episode's TTML is several megabytes and its text
        // a few hundred thousand characters, and this service is @MainActor.
        let transcript = inputs.transcript
        let measured = await Task.detached(priority: .utility) { () -> (sha: String, text: String?, verdict: PodcastTranscriptCompleteness.Verdict?) in
            let sha = PaperContentPreparationService.sha256(rawTTML)
            guard let text = try? SourceService.extractTextFromTTMLContent(rawTTML), !text.isEmpty else {
                return (sha, nil, nil)
            }
            let verdict = PodcastTranscriptCompleteness.verdict(transcript: transcript, episodeText: text)
            return (sha, text, verdict)
        }.value
        guard let fullText = measured.text, let verdict = measured.verdict else {
            throw KnowledgeStoreError.invalidData(
                "Could not extract transcript text from the episode's TTML."
            )
        }

        switch verdict {
        case .complete:
            try await storage.recordPodcastTranscriptAudit(
                sourceID: candidate.sourceID,
                ttmlSHA256: measured.sha,
                outcome: .complete
            )
            return false
        case .unplaced:
            try await storage.recordPodcastTranscriptAudit(
                sourceID: candidate.sourceID,
                ttmlSHA256: measured.sha,
                outcome: .unplaced
            )
            return false
        case .cut:
            break
        }

        log.notice(
            """
            Restoring \(candidate.title, privacy: .public): the stored transcript stops where the \
            retired cap cut it, \(transcript.count) characters against \(fullText.count)
            """
        )

        // A hidden show or episode is restored as plain text and never billed
        // for formatting, matching how hydration treats it.
        var formatted: String?
        if candidate.allowsFormatting, let formattingConfig {
            formatted = await formatTranscript(fullText, candidate, formattingConfig)
        }

        // One transaction, written only over the transcript just measured. It
        // retires any preparation recorded against the cut text and stages
        // the deletion-only ad pass again, so sponsor reads are removed from
        // the whole episode rather than from the part that survived the cap,
        // and renews the indexes and the text other devices read. A fetched
        // TTML is the extraction this transcript came from, kept as hydration
        // keeps one.
        let replaced = try await storage.restorePodcastTranscript(
            sourceID: candidate.sourceID,
            auditedTranscript: transcript,
            restoredTranscript: formatted ?? fullText,
            fetchedTTML: fetched ? rawTTML : nil,
            ttmlSHA256: measured.sha
        )
        guard replaced else { throw TranscriptChangedFailure() }
        return true
    }

    private func result(
        restored: [String],
        verified: Int,
        error: String?
    ) async -> PodcastTranscriptDetruncationDrainResult {
        var remaining = 0
        do {
            remaining = try await storage.podcastTranscriptDetruncationQueueCount()
        } catch {
            log.error("Counting the transcript audit queue failed: \(error.localizedDescription, privacy: .public)")
        }
        return PodcastTranscriptDetruncationDrainResult(
            restoredCount: restored.count,
            verifiedCount: verified,
            restoredSourceIDs: restored,
            remainingCount: remaining,
            errorMessage: error
        )
    }
}
