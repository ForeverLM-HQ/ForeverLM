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

enum PodcastYouTubeTranscriptRecoveryError: LocalizedError {
    case sourceMissing
    case notPodcast
    case noCandidates
    case alreadyImporting
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .sourceMissing:
            return "This podcast episode is no longer in the library."
        case .notPodcast:
            return "YouTube transcript recovery is only available for podcast episodes."
        case .noCandidates:
            return "No matching YouTube videos were found."
        case .alreadyImporting:
            return "This transcript is already being imported."
        case .emptyTranscript:
            return "YouTube returned an empty transcript for this video."
        }
    }
}

/// Captions from a confirmed YouTube video, saved raw on a podcast episode
/// and waiting for their formatting pass.
struct PodcastYouTubeTranscriptImport: Sendable {
    let podcastID: String
    let candidate: YouTubeVideoSearchResult
    let videoTitle: String
    let rawTranscript: String
    let wordCount: Int
}

struct PodcastTranscriptCleanupDrainResult: Sendable {
    let processedCount: Int
    let processedSourceIDs: [String]
    let remainingCount: Int
    let errorMessage: String?
    /// See `CanonicalContentCleanupDrainResult`.
    var failedTransiently = false
    var retryAfterSeconds: Double? = nil
}

private enum PodcastTranscriptCleanupOutcome: Sendable {
    case prepared(PodcastTranscriptCleanupCandidate, PreparedPodcastTranscriptCleanup)
    /// The `Bool` is whether the attempt was cancelled rather than failed,
    /// decided where the typed error still exists. An episode whose pass was
    /// interrupted must not spend one of its few attempts on work never done.
    /// The `Double?` is the wait the provider named, if any.
    case failed(PodcastTranscriptCleanupCandidate, String, Bool, Double?)
}

struct PodcastTranscriptAdRemovalCandidate: Sendable {
    let annotationIndex: Int
    let lowerCharacterOffset: Int
    let upperCharacterOffset: Int
    let proposedDeletion: String
    let precedingContext: String
    let followingContext: String
}

private struct PodcastTranscriptAnnotation: Decodable {
    let after: String?
    let speaker: String?
    let adStart: String?
    let adEnd: String?

    enum CodingKeys: String, CodingKey {
        case after, speaker
        case adStart = "ad_start"
        case adEnd = "ad_end"
    }
}

/// Drains `podcast_transcript_cleanup_queue` in small, resumable batches, on
/// the learner-selected Transcript Formatting task. A transcript hydration
/// saved raw gets the whole formatting pass here, after it is already readable
/// (schema 172): speaker names, paragraphs and ad reads. The historical
/// backlog of transcripts that were formatted before the ad-read contract runs
/// the ad-only prompt, so an old readable transcript does not pay for speaker
/// research or paragraph formatting a second time.
actor PodcastTranscriptCleanupService {
    static let maxCandidatesPerDrain = 2

    /// The formatting pass over one raw transcript, given with the blank lines
    /// of its readable layout taken out: the formatted transcript, or nil when
    /// the transcript is too short to be worth one. Throws when the pass could
    /// not run, a learner's Stop among them.
    typealias TranscriptFormatter = @Sendable (
        _ raw: String,
        _ candidate: PodcastTranscriptCleanupCandidate,
        _ config: AITaskConfig
    ) async throws -> String?

    private struct VerificationItem: Encodable {
        let id: Int
        let precedingContext: String
        let proposedDeletion: String
        let followingContext: String

        enum CodingKeys: String, CodingKey {
            case id
            case precedingContext = "preceding_context"
            case proposedDeletion = "proposed_deletion"
            case followingContext = "following_context"
        }
    }

    private struct VerificationPayload: Encodable {
        let candidates: [VerificationItem]
    }

    private struct VerificationResponse: Decodable {
        let approvedIDs: [Int]

        enum CodingKeys: String, CodingKey {
            case approvedIDs = "approved_ids"
        }
    }

    private let storage: StorageService
    private let aiService: AIService
    private let formatTranscript: TranscriptFormatter
    private let explicitlyAuthorizedConfig: AITaskConfig?
    /// `false` in a Dev build that has not opted in (`PaidSourceCleanupPolicy`).
    /// The ad pass only ever touches episodes that are already readable, so
    /// the Dev drain leaves the queue exactly as it found it. A maintenance
    /// launch that names its route explicitly has opted in by doing so.
    private let runsPaidCleanup: Bool
    private var isDraining = false

    init(
        storage: StorageService,
        aiService: AIService,
        explicitlyAuthorizedConfig: AITaskConfig? = nil,
        runsPaidCleanup: Bool = PaidSourceCleanupPolicy.runsPaidCleanup,
        formatTranscript: TranscriptFormatter? = nil
    ) {
        self.storage = storage
        self.aiService = aiService
        self.formatTranscript = formatTranscript ?? { raw, candidate, config in
            try await StudioViewModel.formatPodcastTranscript(
                raw,
                sourceID: candidate.sourceID,
                episodeTitle: candidate.title,
                podcastName: candidate.podcastName,
                aiService: aiService,
                config: config,
                log: Logger(subsystem: "com.foreverlm", category: "PodcastTranscriptCleanup")
            )
        }
        self.explicitlyAuthorizedConfig = explicitlyAuthorizedConfig
        self.runsPaidCleanup = runsPaidCleanup || explicitlyAuthorizedConfig != nil
    }

    /// - Parameter backgroundSpendAllowed: false once the learner's daily
    ///   background cap is reached. The ad backlog waits for the next day; a
    ///   transcript just fetched is still formatted, as a source the learner
    ///   added is still cleaned.
    func drain(backgroundSpendAllowed: Bool = true) async -> PodcastTranscriptCleanupDrainResult {
        guard !isDraining else { return await result(processed: [], error: nil) }
        isDraining = true
        defer { isDraining = false }

        guard runsPaidCleanup else { return await result(processed: [], error: nil) }

        let candidates: [PodcastTranscriptCleanupCandidate]
        do {
            candidates = try await storage.podcastTranscriptCleanupCandidates(
                limit: Self.maxCandidatesPerDrain,
                formattingOnly: !backgroundSpendAllowed
            )
        } catch {
            return await result(processed: [], error: error.localizedDescription)
        }
        guard !candidates.isEmpty else { return await result(processed: [], error: nil) }
        // The historical backfill waited for Transcript Formatting to be given
        // a model of its own until tasks stopped having one (2026-09-28). It
        // runs on Background › Text now, like new transcripts, under the
        // daily background cap (`backgroundSpendAllowed`).
        let config: AITaskConfig
        if let explicitlyAuthorizedConfig {
            config = explicitlyAuthorizedConfig
        } else {
            guard let resolved = KeychainService.resolveConfig(for: .transcriptFormatting) else {
                return await result(
                    processed: [],
                    error: "Transcript Formatting has no configured model."
                )
            }
            config = resolved
        }

        let aiService = aiService
        let formatTranscript = formatTranscript
        var processed: [String] = []
        var firstError: String?
        var failedTransiently = false
        var longestRetryAfter: Double?
        await withTaskGroup(of: PodcastTranscriptCleanupOutcome.self) { group in
            for candidate in candidates {
                group.addTask {
                    do {
                        let prepared = try await Self.prepare(
                            candidate,
                            config: config,
                            aiService: aiService,
                            formatTranscript: formatTranscript
                        )
                        return .prepared(candidate, prepared)
                    } catch {
                        return .failed(
                            candidate,
                            error.localizedDescription,
                            AITransientErrorClassifier.isCancellation(error),
                            AITransientErrorClassifier.retryAfterSeconds(error)
                        )
                    }
                }
            }

            for await outcome in group {
                let candidate: PodcastTranscriptCleanupCandidate
                switch outcome {
                case .prepared(let completedCandidate, let prepared):
                    candidate = completedCandidate
                    do {
                        try await storage.applyPodcastTranscriptCleanup(
                            candidate: candidate,
                            prepared: prepared
                        )
                        processed.append(candidate.sourceID)
                    } catch where AITransientErrorClassifier.isCancellation(error) {
                        continue
                    } catch {
                        let message = error.localizedDescription
                        if firstError == nil { firstError = "\(candidate.title): \(message)" }
                        try? await storage.recordPodcastTranscriptCleanupFailure(
                            sourceID: candidate.sourceID,
                            message: message,
                            sourceSHA256: candidate.inputSHA256,
                            consumesAttempt: false
                        )
                    }
                case .failed(let failedCandidate, let message, let wasCancelled, let retryAfter):
                    // An interrupted pass is not an attempt. Recording it here
                    // would count against this episode's attempt budget and
                    // eventually retire a transcript nothing was ever wrong with.
                    if wasCancelled { continue }
                    candidate = failedCandidate
                    if firstError == nil { firstError = "\(candidate.title): \(message)" }
                    let transient = Self.isRetryableFailure(message)
                    if transient {
                        failedTransiently = true
                        if let retryAfter {
                            longestRetryAfter = max(longestRetryAfter ?? retryAfter, retryAfter)
                        }
                    }
                    try? await storage.recordPodcastTranscriptCleanupFailure(
                        sourceID: candidate.sourceID,
                        message: message,
                        sourceSHA256: candidate.inputSHA256,
                        consumesAttempt: !transient
                    )
                }
            }
        }
        var drained = await result(processed: processed, error: firstError)
        drained.failedTransiently = failedTransiently
        drained.retryAfterSeconds = longestRetryAfter
        return drained
    }

    private func result(
        processed: [String],
        error: String?
    ) async -> PodcastTranscriptCleanupDrainResult {
        let remaining = (try? await storage.podcastTranscriptCleanupQueueCount()) ?? 0
        return PodcastTranscriptCleanupDrainResult(
            processedCount: processed.count,
            processedSourceIDs: processed,
            remainingCount: remaining,
            errorMessage: error
        )
    }

    private static func prepare(
        _ candidate: PodcastTranscriptCleanupCandidate,
        config: AITaskConfig,
        aiService: AIService,
        formatTranscript: TranscriptFormatter
    ) async throws -> PreparedPodcastTranscriptCleanup {
        if candidate.formatsTranscript {
            // The model is given the transcript as Apple or speech-to-text
            // gave it, not the paragraphs it was laid out in to be read
            // meanwhile, and places every break itself. The ad reads it marks
            // come out with its breaks, so the ad pass is done with it.
            let formatted = try await formatTranscript(
                StudioViewModel.podcastTranscriptWithoutLayout(candidate.input),
                candidate,
                config
            )
            let clean = formatted ?? candidate.input
            return PreparedPodcastTranscriptCleanup(
                input: candidate.input,
                clean: clean,
                metadata: PodcastTranscriptCleanupMetadata(
                    cleanerVersion: PodcastTranscriptCleanupMetadata.currentVersion,
                    inputSHA256: candidate.inputSHA256,
                    cleanSHA256: PaperContentPreparationService.sha256(clean),
                    preparedAt: Date()
                )
            )
        }
        let chunks = StudioViewModel.podcastTranscriptAdCleanupChunks(candidate.input)
        let activityID = UUID().uuidString
        let indexed = Array(chunks.enumerated())
        let cleanedChunks = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var next = 0
            while next < min(StudioViewModel.transcriptChunkFormatConcurrency, indexed.count) {
                let item = indexed[next]
                group.addTask {
                    try await cleanChunk(
                        item,
                        candidate: candidate,
                        config: config,
                        activityID: activityID,
                        aiService: aiService
                    )
                }
                next += 1
            }

            var results: [(Int, String)] = []
            while let completed = try await group.next() {
                results.append(completed)
                guard next < indexed.count else { continue }
                let item = indexed[next]
                group.addTask {
                    try await cleanChunk(
                        item,
                        candidate: candidate,
                        config: config,
                        activityID: activityID,
                        aiService: aiService
                    )
                }
                next += 1
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let clean = cleanedChunks.joined(separator: "\n\n")
        return PreparedPodcastTranscriptCleanup(
            input: candidate.input,
            clean: clean,
            metadata: PodcastTranscriptCleanupMetadata(
                cleanerVersion: PodcastTranscriptCleanupMetadata.currentVersion,
                inputSHA256: candidate.inputSHA256,
                cleanSHA256: PaperContentPreparationService.sha256(clean),
                preparedAt: Date()
            )
        )
    }

    private static func cleanChunk(
        _ item: (offset: Int, element: String),
        candidate: PodcastTranscriptCleanupCandidate,
        config: AITaskConfig,
        activityID: String,
        aiService: AIService
    ) async throws -> (Int, String) {
        let response = try await AIBackgroundRetry.run(config: config) { config in
            try await aiService.call(
                config: config,
                system: Prompts.podcastTranscriptAdCleanup,
                user: item.element,
                maxTokens: 4_000,
                temperature: 0.2,
                disablesReasoning: true,
                sourceTitle: StudioViewModel.transcriptLedgerTitle(candidate.title, candidate.podcastName),
                subjectID: candidate.sourceID,
                subjectType: "podcast_episode",
                activityID: activityID
            )
        }
        let proposedRemovals = StudioViewModel.podcastTranscriptAdRemovalCandidatesOffMain(
            to: item.element,
            from: response
        )
        guard !proposedRemovals.isEmpty else { return (item.offset, item.element) }

        let approvedIDs = try await verifyProposedRemovals(
            proposedRemovals,
            candidate: candidate,
            config: config,
            activityID: activityID,
            aiService: aiService
        )
        return (
            item.offset,
            StudioViewModel.applyPodcastTranscriptAdRemovalsOffMain(
                to: item.element,
                candidates: proposedRemovals.filter { approvedIDs.contains($0.annotationIndex) }
            )
        )
    }

    private static func verifyProposedRemovals(
        _ candidates: [PodcastTranscriptAdRemovalCandidate],
        candidate: PodcastTranscriptCleanupCandidate,
        config: AITaskConfig,
        activityID: String,
        aiService: AIService
    ) async throws -> Set<Int> {
        let payload = VerificationPayload(candidates: candidates.map {
            VerificationItem(
                id: $0.annotationIndex,
                precedingContext: $0.precedingContext,
                proposedDeletion: $0.proposedDeletion,
                followingContext: $0.followingContext
            )
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        guard let user = String(data: data, encoding: .utf8) else {
            throw AIError.invalidResponse
        }
        let response = try await AIBackgroundRetry.run(config: config) { config in
            try await aiService.call(
                config: config,
                system: Prompts.podcastTranscriptAdRemovalVerification,
                user: user,
                maxTokens: 1_000,
                temperature: 0,
                disablesReasoning: true,
                sourceTitle: StudioViewModel.transcriptLedgerTitle(candidate.title, candidate.podcastName),
                subjectID: candidate.sourceID,
                subjectType: "podcast_episode",
                activityID: activityID
            )
        }
        guard let responseData = response.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(VerificationResponse.self, from: responseData) else {
            throw AIError.invalidResponse
        }
        let validIDs = Set(candidates.map(\.annotationIndex))
        return Set(decoded.approvedIDs).intersection(validIDs)
    }

    nonisolated static func isRetryableFailure(_ message: String) -> Bool {
        let normalizedMessage = message.lowercased()
        return AITransientErrorClassifier.isTransient(AIError.apiError(message))
            || normalizedMessage.contains("error code: 524")
            || normalizedMessage.contains("max_output_tokens")
            || normalizedMessage.contains("operation timed out")
    }
}

private final class PodcastFeedEnclosureParser: NSObject, XMLParserDelegate {
    private let targetPageURL: String
    private var insideItem = false
    private var currentElement = ""
    private var currentLink = ""
    private var currentEnclosure: String?
    private(set) var enclosureURL: URL?

    init(targetPageURL: URL) {
        self.targetPageURL = Self.canonical(targetPageURL)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName.lowercased()
        if currentElement == "item" || currentElement == "entry" {
            insideItem = true
            currentLink = ""
            currentEnclosure = nil
        } else if insideItem, currentElement == "enclosure" {
            currentEnclosure = attributeDict["url"]
        } else if insideItem, currentElement == "link",
                  let href = attributeDict["href"], !href.isEmpty {
            currentLink = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideItem, currentElement == "link" { currentLink += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        if (name == "item" || name == "entry"), insideItem {
            if let linkURL = URL(string: currentLink.trimmingCharacters(in: .whitespacesAndNewlines)),
               Self.canonical(linkURL) == targetPageURL,
               let rawEnclosure = currentEnclosure,
               let url = URL(string: rawEnclosure),
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                enclosureURL = url
            }
            insideItem = false
        }
        currentElement = ""
    }

    private static func canonical(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        var value = components?.url?.absoluteString ?? url.absoluteString
        while value.hasSuffix("/") { value.removeLast() }
        return value.lowercased()
    }
}

extension StudioViewModel {

    nonisolated static let podcastYouTubeFallbackShowsKey = "podcasts.youtubeFallbackShows"

    // A transcript the retired 50,000-character import cap cut is found and
    // restored by the completeness audit (`PodcastTranscriptDetruncationService`,
    // schema 167), which measures where each transcript stops in its episode's
    // TTML. Opening an episode no longer guesses at it: the reader used to
    // re-fetch and re-format every TTML-less episode of 44,000 to 50,000
    // characters, complete ones included, and missed the capped ones that
    // formatting had pushed past 50,000.

    /// Fetches an episode's transcript again from Apple Podcasts and replaces
    /// the stored one: `refetch_source_content`'s route for a podcast. It is
    /// hydration with nothing taken from storage: a row filed under the
    /// episode's web page is resolved to its public episode first, and the
    /// whole TTML is extracted and saved readable with the TTML, its
    /// formatting queued when the episode allows it. A fetch that fails keeps
    /// the transcript the episode has and its state; only an identity the
    /// fetch moved the row to is taken into the loaded copy, so a later save
    /// cannot write the old address back. Returns the outcome, or nil when
    /// nothing was fetched.
    @discardableResult
    func refetchPodcastTranscript(
        for articleId: String,
        config: AITaskConfig?,
        fetchAppleTranscript: @escaping @Sendable (Int64, String) async -> PodcastTranscriptFetchOutcome = { trackID, homeDir in
            await StudioViewModel.fetchPodcastTranscriptOffMain(trackId: trackID, homeDir: homeDir)
        }
    ) async -> PodcastTranscriptHydrationResult.Outcome? {
        guard !contentFetchInFlight.contains(articleId),
              let candidate = podcastHydrationCandidate(for: articleId, userInitiated: true) else { return nil }
        contentFetchInFlight.insert(articleId)
        defer { contentFetchInFlight.remove(articleId) }

        let storage = self.storage
        let homeDir = realHomeDirectory
        let result = await Task.detached(priority: .utility) {
            await Self.hydratePodcastTranscript(
                candidate,
                storage: storage,
                homeDir: homeDir,
                config: config,
                forceRefresh: true,
                fetchAppleTranscript: fetchAppleTranscript
            )
        }.value

        if case .failed(let message) = result.outcome, result.mergedIntoSourceID == nil {
            logger.notice("Could not fetch the transcript of \(candidate.title, privacy: .public) again: \(message, privacy: .public)")
            if let identity = result.resolvedIdentity,
               let index = articles.firstIndex(where: { $0.id == articleId }) {
                articles[index].url = identity.url
                articles[index].normalizedURL = URLNormalizer.normalize(identity.url)
                articles[index].podcastWebPageURL = identity.webPageURL
            }
            return result.outcome
        }
        await applyPodcastHydrationResult(result)
        return result.outcome
    }

    /// Explicitly permits paid speech-to-text for one episode. Ordinary podcast
    /// hydration stops when Apple has no transcript; this is the only podcast
    /// path that opts into resolving and transcribing the episode audio.
    func transcribePodcastEpisodeAudio(for articleId: String) async {
        guard !contentFetchInFlight.contains(articleId),
              let candidate = podcastHydrationCandidate(
                for: articleId,
                userInitiated: true,
                honorYouTubePreference: false
              ),
              let index = articles.firstIndex(where: { $0.id == articleId }) else { return }

        contentFetchInFlight.insert(articleId)
        isFetchingContent = true
        defer {
            contentFetchInFlight.remove(articleId)
            isFetchingContent = false
        }

        articles[index].state = .fetching
        articles[index].errorMessage = nil
        try? await storage.saveSource(articles[index])

        let storage = self.storage
        let homeDir = realHomeDirectory
        let config = KeychainService.resolveConfig(for: .transcriptFormatting)
        let result = await Task.detached(priority: .utility) {
            // The learner pressed Transcribe Audio: a transcription stopped
            // under Running in the background still runs for it.
            await AIUsageAttribution.$learnerAsked.withValue(true) {
                await Self.hydratePodcastTranscript(
                    candidate,
                    storage: storage,
                    homeDir: homeDir,
                    config: config,
                    forceRefresh: true,
                    allowAudioTranscription: true
                )
            }
        }.value
        await applyPodcastHydrationResult(result)
    }

    // MARK: - Podcast Transcript Fetching

    nonisolated static func podcastShowPreferenceKey(_ showName: String) -> String {
        showName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func prefersYouTubeTranscript(forPodcastShow showName: String) -> Bool {
        let key = Self.podcastShowPreferenceKey(showName)
        return !key.isEmpty && podcastYouTubeFallbackShows.contains(key)
    }

    func setYouTubeTranscriptFallback(forPodcastShow showName: String, enabled: Bool) {
        let key = Self.podcastShowPreferenceKey(showName)
        guard !key.isEmpty else { return }
        if enabled {
            podcastYouTubeFallbackShows.insert(key)
        } else {
            podcastYouTubeFallbackShows.remove(key)
        }
        PreferenceStore.set(
            podcastYouTubeFallbackShows.sorted(),
            forKey: Self.podcastYouTubeFallbackShowsKey
        )
    }

    nonisolated static func podcastYouTubeSearchQuery(for article: StudioArticle) -> String {
        let context = podcastYouTubeShowName(for: article)
        return [article.title.trimmingCharacters(in: .whitespacesAndNewlines), context]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    nonisolated static func podcastYouTubeShowName(for article: StudioArticle) -> String {
        let showName = article.parentGroup?.trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = article.domain.trimmingCharacters(in: .whitespacesAndNewlines)
        return showName.flatMap { $0.isEmpty ? nil : $0 } ?? domain
    }

    nonisolated static func mergedPodcastYouTubeSearchResults(
        _ indexedResults: [(Int, [YouTubeVideoSearchResult])]
    ) -> [YouTubeVideoSearchResult] {
        var seen = Set<String>()
        return indexedResults
            .sorted { $0.0 < $1.0 }
            .flatMap(\.1)
            .filter { seen.insert($0.videoId).inserted }
    }

    nonisolated static func rankedPodcastYouTubeSearchResults(
        _ results: [YouTubeVideoSearchResult],
        videoIDs: [String]
    ) -> [YouTubeVideoSearchResult] {
        let byID = Dictionary(uniqueKeysWithValues: results.map { ($0.videoId, $0) })
        return videoIDs.compactMap { byID[$0] }
    }

    /// Automatic recovery is reader-driven and bounded to the episode the
    /// learner opened. It never starts an OAuth flow on its own, and it never
    /// imports a search result without the separate confirmation action.
    nonisolated static func shouldAutomaticallySearchYouTubeForPodcast(
        _ article: StudioArticle,
        isYouTubeSignedIn: Bool
    ) -> Bool {
        isYouTubeSignedIn
            && article.sourceType == .podcast
            && isTerminalPodcastTranscriptError(article.errorMessage)
    }

    /// Find public YouTube candidates, but never decide episode identity. The
    /// episode's own web page and the show's own channel are read first: they
    /// find an upload whatever it is titled, and on the day it goes up. Search
    /// comes after, with queries an LLM writes from the episode metadata to get
    /// past Apple's title wording, and the LLM ranks everything found; the
    /// learner still confirms a video before any captions are persisted against
    /// the podcast source. Returned best match first — the reader presents that
    /// one and keeps the rest as alternatives.
    ///
    /// On 2026-09-30 Core Memory's EP 90, "He's Here To End Death", was up on
    /// YouTube as "Can We Put Death On Hold?", linked from the episode's page
    /// and first on the show's channel, while every Data API search came back
    /// empty and the reader said no matching video was found.
    func findYouTubeTranscriptCandidates(for podcastID: String) async throws -> [YouTubeVideoSearchResult] {
        guard let article = articles.first(where: { $0.id == podcastID }) else {
            throw PodcastYouTubeTranscriptRecoveryError.sourceMissing
        }
        guard article.sourceType == .podcast else {
            throw PodcastYouTubeTranscriptRecoveryError.notPodcast
        }
        guard let config = KeychainService.resolveConfig(for: .podcastYouTubeMatching) else {
            throw AIError.missingAPIKey
        }

        // Videos this show's other episodes took their transcripts from name
        // the show's channel, and none of them is this episode.
        let otherEpisodeVideoIDs = youtubeVideoIDsOfOtherEpisodes(of: article)
        let takenVideoIDs = Set(otherEpisodeVideoIDs)
        async let linkedVideoIDs = Self.youtubeVideoIDsLinkedFromEpisodePage(article.podcastWebPageURL)
        async let channelVideoIDs = Self.youtubeUploadIDsNearEpisode(
            onChannelOf: Array(otherEpisodeVideoIDs.prefix(3)),
            excluding: takenVideoIDs,
            addedAt: article.dateAdded
        )

        // A failed search is not the end while the page or the channel found
        // the upload; it is reported only when nothing else was found.
        let searched: Result<[YouTubeVideoSearchResult], Error>
        do {
            searched = .success(try await searchYouTubeForPodcast(article, config: config))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            searched = .failure(error)
        }

        let linked = await linkedVideoIDs.filter { !takenVideoIDs.contains($0) }
        let uploads = await channelVideoIDs.filter { !linked.contains($0) }
        var origins: [String: PodcastYouTubeCandidateOrigin] = [:]
        for id in linked { origins[id] = .episodePage }
        for id in uploads { origins[id] = .showChannel }
        let direct: [YouTubeVideoSearchResult]
        if origins.isEmpty {
            direct = []
        } else {
            do {
                direct = try await YouTubeService.shared.videos(ids: linked + uploads)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.warning("Could not read the YouTube videos found for a podcast episode: \(error.localizedDescription)")
                direct = []
            }
        }

        let results = Self.mergedPodcastYouTubeSearchResults([
            (0, direct),
            (1, (try? searched.get()) ?? []),
        ])
        .filter { !takenVideoIDs.contains($0.videoId) }
        .map { result -> YouTubeVideoSearchResult in
            var found = result
            found.foundBy = origins[result.videoId] ?? .search
            return found
        }
        guard !results.isEmpty else {
            if case .failure(let error) = searched { throw error }
            throw PodcastYouTubeTranscriptRecoveryError.noCandidates
        }
        let showName = Self.podcastYouTubeShowName(for: article)
        let rankedIDs = try await aiService.rankPodcastYouTubeCandidates(
            episodeTitle: article.title,
            showName: showName,
            author: article.author,
            candidates: results,
            foundBy: results.reduce(into: [:]) { found, result in
                found[result.videoId] = result.foundBy?.rawValue
            },
            config: config
        )
        let ranked = Self.rankedPodcastYouTubeSearchResults(results, videoIDs: rankedIDs)
        // The reader confirms the ranked best match, so an empty ranking has to
        // surface as "nothing found" rather than an empty confirmation.
        guard !ranked.isEmpty else {
            throw PodcastYouTubeTranscriptRecoveryError.noCandidates
        }
        return ranked
    }

    /// The YouTube videos this show's other episodes took their transcripts
    /// from, newest episode first.
    func youtubeVideoIDsOfOtherEpisodes(of article: StudioArticle) -> [String] {
        let show = Self.podcastShowPreferenceKey(Self.podcastYouTubeShowName(for: article))
        guard !show.isEmpty else { return [] }
        var seen = Set<String>()
        return articles
            .filter {
                $0.id != article.id && $0.sourceType == .podcast
                    && Self.podcastShowPreferenceKey(Self.podcastYouTubeShowName(for: $0)) == show
            }
            .sorted { $0.dateAdded > $1.dateAdded }
            .compactMap { $0.publicURL.flatMap(ForeverLMCore.youtubeVideoID(from:)) }
            .filter { seen.insert($0).inserted }
    }

    /// The videos an episode's web page links, most linked first. A show that
    /// posts to YouTube embeds the upload on the episode's page and links its
    /// chapters to times in it, so the episode's own video is the one the page
    /// names most. A page that cannot be read contributes nothing.
    nonisolated static func youtubeVideoIDsLinkedFromEpisodePage(_ pageURL: String?) async -> [String] {
        guard let pageURL,
              let url = URL(string: pageURL),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(),
              // Apple's episode page links no YouTube video.
              host != "podcasts.apple.com" else { return [] }
        if let videoID = ForeverLMCore.youtubeVideoID(from: pageURL) { return [videoID] }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(SharedWebKit.desktopSafariUserAgent, forHTTPHeaderField: "User-Agent")
        guard let fetched = try? await URLSession.shared.data(for: request),
              let http = fetched.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let html = String(data: fetched.0, encoding: .utf8) ?? String(data: fetched.0, encoding: .isoLatin1)
        else { return [] }
        return Array(youtubeVideoIDsLinked(inEpisodePage: html).prefix(3))
    }

    nonisolated static func youtubeVideoIDsLinked(inEpisodePage html: String) -> [String] {
        // watch?v=, embed/, shorts/, live/, v/ and youtu.be/ addresses, as
        // markup (`&amp;`) and as JSON (`\/`) write them.
        let pattern = #"(?:youtube(?:-nocookie)?\.com\\?/(?:watch\?(?:[^"'\s<>]*?&(?:amp;)?)?v=|(?:embed|shorts|live|v)\\?/)|youtu\.be\\?/)([A-Za-z0-9_-]{11})(?![A-Za-z0-9_-])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let text = html as NSString
        var counts: [String: Int] = [:]
        var order: [String] = []
        for match in regex.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            let videoID = text.substring(with: match.range(at: 1))
            if counts[videoID] == nil { order.append(videoID) }
            counts[videoID, default: 0] += 1
        }
        return order.enumerated()
            .sorted { lhs, rhs in
                let (left, right) = (counts[lhs.element] ?? 0, counts[rhs.element] ?? 0)
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .map { $0.element }
    }

    /// Uploads on the channel `knownVideoIDs` came from, published nearest the
    /// day the episode was filed. A followed show's episode is filed the day it
    /// is released, and its YouTube upload goes up within days of it. The
    /// uploads playlist lists a video as soon as it is up.
    nonisolated static func youtubeUploadIDsNearEpisode(
        onChannelOf knownVideoIDs: [String],
        excluding taken: Set<String>,
        addedAt: Date
    ) async -> [String] {
        guard !knownVideoIDs.isEmpty,
              let known = try? await YouTubeService.shared.videos(ids: knownVideoIDs) else { return [] }
        let channels = known.compactMap(\.channelId).reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        guard let channelID = channels.max(by: { $0.value < $1.value })?.key,
              YouTubeService.isChannelID(channelID),
              let feed = try? await YouTubeService.shared.listChannelUploadsFeed(
                uploadsPlaylistID: YouTubeService.uploadsPlaylistID(forChannelID: channelID),
                maxCount: 50
              ) else { return [] }
        return uploadsNearEpisode(feed.items.filter { !taken.contains($0.videoId) }, addedAt: addedAt)
    }

    nonisolated static func uploadsNearEpisode(
        _ uploads: [YouTubePlaylistItem],
        addedAt: Date,
        window: TimeInterval = 10 * 86_400,
        limit: Int = 3
    ) -> [String] {
        uploads
            .compactMap { upload -> (String, TimeInterval)? in
                guard let published = upload.videoPublishedAt else { return nil }
                let distance = abs(published.timeIntervalSince(addedAt))
                return distance <= window ? (upload.videoId, distance) : nil
            }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    /// YouTube search for the episode: Apple's own title with the show's name,
    /// and up to two shorter queries the model writes.
    private func searchYouTubeForPodcast(
        _ article: StudioArticle,
        config: AITaskConfig
    ) async throws -> [YouTubeVideoSearchResult] {
        let showName = Self.podcastYouTubeShowName(for: article)
        // The literal title search needs no model, so it runs while the model
        // writes the broader queries instead of waiting behind that call.
        let literalQuery = Self.podcastYouTubeSearchQuery(for: article)
        async let literalResults = YouTubeService.shared.searchVideos(
            query: literalQuery,
            maxResults: 5
        )
        let semanticQueries = try await aiService.podcastYouTubeSearchQueries(
            episodeTitle: article.title,
            showName: showName,
            author: article.author,
            config: config
        )
        var seenQueries: Set<String> = [literalQuery.lowercased()]
        let queries = semanticQueries
            .filter { seenQueries.insert($0.lowercased()).inserted }
            .prefix(2)

        let indexedResults = try await withThrowingTaskGroup(
            of: (Int, [YouTubeVideoSearchResult]).self
        ) { group in
            for (index, query) in queries.enumerated() {
                group.addTask {
                    let results = try await YouTubeService.shared.searchVideos(
                        query: query,
                        maxResults: 5
                    )
                    return (index, results)
                }
            }
            var completed: [(Int, [YouTubeVideoSearchResult])] = []
            for try await result in group {
                completed.append(result)
            }
            return completed
        }
        // The literal query ranks last among the queries, as it always has.
        return Self.mergedPodcastYouTubeSearchResults(
            indexedResults + [(queries.count, try await literalResults)]
        )
    }

    /// Import captions from a learner-confirmed YouTube candidate into the
    /// existing podcast. The Apple episode URL remains the source identity;
    /// `publicURL` records the YouTube provenance and syncs with the transcript.
    func importYouTubeTranscript(
        for podcastID: String,
        from candidate: YouTubeVideoSearchResult
    ) async throws {
        let imported = try await importRawYouTubeTranscript(for: podcastID, from: candidate)
        await formatImportedYouTubeTranscript(imported)
    }

    /// The first half of `importYouTubeTranscript`: the captions, saved as they
    /// come, make the episode readable at once. The episode stays marked as
    /// importing until `formatImportedYouTubeTranscript` has run on the result,
    /// which an assistant's call leaves running after it answers.
    func importRawYouTubeTranscript(
        for podcastID: String,
        from candidate: YouTubeVideoSearchResult
    ) async throws -> PodcastYouTubeTranscriptImport {
        guard !podcastYouTubeTranscriptImportInFlight.contains(podcastID) else {
            throw PodcastYouTubeTranscriptRecoveryError.alreadyImporting
        }
        guard let article = articles.first(where: { $0.id == podcastID }) else {
            throw PodcastYouTubeTranscriptRecoveryError.sourceMissing
        }
        guard article.sourceType == .podcast else {
            throw PodcastYouTubeTranscriptRecoveryError.notPodcast
        }

        podcastYouTubeTranscriptImportInFlight.insert(podcastID)
        let rawTranscript: String
        let videoTitle: String
        do {
            let fetched = try await YouTubeTranscriptService.shared.fetchTranscript(from: candidate.url)
            rawTranscript = fetched.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            videoTitle = fetched.title ?? candidate.title
            guard !rawTranscript.isEmpty else {
                throw PodcastYouTubeTranscriptRecoveryError.emptyTranscript
            }

            // Persist content, ready state, cleared Apple error, and provenance in
            // one SQLite transaction before publishing the ready source to SwiftUI.
            try await storage.savePodcastYouTubeTranscript(
                podcastID,
                rawTranscript,
                youtubeURL: candidate.url
            )
        } catch {
            podcastYouTubeTranscriptImportInFlight.remove(podcastID)
            throw error
        }
        let wordCount = rawTranscript.split(whereSeparator: \.isWhitespace).count
        if let readyIndex = articles.firstIndex(where: { $0.id == podcastID }) {
            articles[readyIndex].content = rawTranscript
            articles[readyIndex].wordCount = wordCount
            articles[readyIndex].state = .ready
            articles[readyIndex].errorMessage = nil
            articles[readyIndex].publicURL = candidate.url
            queueSourceEmbeddingRefreshIfReady(podcastID)
        }
        return PodcastYouTubeTranscriptImport(
            podcastID: podcastID,
            candidate: candidate,
            videoTitle: videoTitle,
            rawTranscript: rawTranscript,
            wordCount: wordCount
        )
    }

    /// Match ordinary YouTube imports: raw captions become readable at once,
    /// then upgrade in place if the configured transcript-formatting task is
    /// available and preserves the timing markers.
    func formatImportedYouTubeTranscript(_ imported: PodcastYouTubeTranscriptImport) async {
        let podcastID = imported.podcastID
        let candidate = imported.candidate
        let rawTranscript = imported.rawTranscript
        defer { podcastYouTubeTranscriptImportInFlight.remove(podcastID) }
        guard articles.contains(where: { $0.id == podcastID && $0.publicURL == candidate.url }) else { return }

        let formatted = await formatReadableYouTubeTranscriptWithLLM(
            rawTranscript,
            sourceID: podcastID,
            videoTitle: imported.videoTitle,
            channelName: candidate.channelTitle,
            removingPodcastAdReads: true
        )
        guard let formatted,
              Self.containsYouTubeTimingMarkers(formatted),
              formatted != rawTranscript else { return }
        do {
            try await storage.savePodcastYouTubeTranscript(
                podcastID,
                formatted,
                youtubeURL: nil,
                cleanupInput: rawTranscript
            )
            guard let formattedIndex = articles.firstIndex(where: { $0.id == podcastID }),
                  articles[formattedIndex].publicURL == candidate.url else { return }
            articles[formattedIndex].content = formatted
            articles[formattedIndex].wordCount = formatted.split(whereSeparator: \.isWhitespace).count
            articles[formattedIndex].state = .ready
            articles[formattedIndex].errorMessage = nil
            queueSourceEmbeddingRefreshIfReady(podcastID)
        } catch {
            logger.warning("Could not save formatted YouTube podcast transcript: \(error.localizedDescription)")
        }
    }

    /// Fetch a podcast transcript TTML via the Apple Podcasts API or local cache.
    /// Returns the raw TTML content string, or nil on failure.
    func fetchPodcastTranscript(trackId: Int64) async -> String? {
        guard case .available(let transcript) = await Self.fetchPodcastTranscriptOffMain(
            trackId: trackId,
            homeDir: realHomeDirectory
        ) else {
            return nil
        }
        return transcript
    }

    /// Fetches an episode's transcript and saves it readable. Its formatting
    /// is queued, not run: `config` is the Transcript Formatting model, and
    /// nil (none chosen) queues nothing.
    nonisolated static func hydratePodcastTranscript(
        _ candidate: PodcastTranscriptHydrationCandidate,
        storage: StorageService,
        homeDir: String,
        config: AITaskConfig?,
        forceRefresh: Bool = false,
        allowAudioTranscription: Bool = false,
        fetchAppleTranscript: @escaping @Sendable (Int64, String) async -> PodcastTranscriptFetchOutcome = { trackID, homeDir in
            await StudioViewModel.fetchPodcastTranscriptOffMain(trackId: trackID, homeDir: homeDir)
        },
        resolveEpisodeAudioURL: @escaping @Sendable (String, String?, String) async -> URL? = { sourceURL, webPageURL, homeDir in
            await StudioViewModel.podcastEpisodeAudioURLForTranscriptionOffMain(
                sourceURL: sourceURL,
                webPageURL: webPageURL,
                homeDir: homeDir
            )
        },
        transcribeEpisodeAudio: @escaping @Sendable (URL) async throws -> String = { mediaURL in
            try await MeetingTranscriptionService.shared.transcribe(remoteMediaURL: mediaURL)
        },
        resolvePublicEpisode: @escaping @Sendable (String, String, String) async -> PodcastPublicEpisodeResolution = { showName, title, homeDir in
            await PodcastPublicEpisodeResolver.shared.resolve(
                showName: showName,
                episodeTitle: title,
                homeDir: homeDir
            )
        }
    ) async -> PodcastTranscriptHydrationResult {
        let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "PodcastHydration")

        // A row filed under the episode's web page can only be holding that
        // page's text, which is not a transcript; stored text counts as the
        // finished import only for a row with an Apple episode address.
        let filedUnderWebPage = Self.isWebPageAddress(candidate.url)
        if !forceRefresh, !filedUnderWebPage,
           let existingContent = await storage.loadSourceContent(candidate.id),
           !existingContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return PodcastTranscriptHydrationResult(
                id: candidate.id,
                outcome: .ready(content: existingContent, persistedReadyState: false)
            )
        }

        // Checked after stored text: an episode whose transcript already came
        // from YouTube is finished, and must not be sent back to "find it".
        if candidate.prefersYouTube {
            return PodcastTranscriptHydrationResult(
                id: candidate.id,
                outcome: .failed(message: youtubePreferredPodcastTranscriptMessage)
            )
        }

        var trackID = Self.publicTrackID(inPodcastURL: candidate.url)
        var resolvedIdentity: PodcastResolvedEpisodeIdentity?
        var sourceURL = candidate.url
        var webPageURL = candidate.webPageURL
        func result(_ outcome: PodcastTranscriptHydrationResult.Outcome) -> PodcastTranscriptHydrationResult {
            PodcastTranscriptHydrationResult(id: candidate.id, outcome: outcome, resolvedIdentity: resolvedIdentity)
        }

        if trackID == nil {
            // A private-feed placeholder or a web-page row has no public track
            // id of its own, and Apple transcribes only the public catalog. A
            // member feed mirrors a public show, so look the episode up there
            // and move the row onto the identity the transcript lives under.
            switch await resolvePublicEpisode(candidate.podcastName, candidate.title, homeDir) {
            case .matched(let episode, let showName):
                let publicURL = SourceDiscovery.podcastEpisodePlaceholderURL(trackId: episode.trackID)
                let page = filedUnderWebPage ? candidate.url : (episode.webPageURL ?? candidate.webPageURL)
                do {
                    try await storage.rebindPodcastEpisodeIdentity(
                        candidate.id,
                        toPublicURL: publicURL,
                        webPageURL: page
                    )
                } catch KnowledgeStoreError.duplicateSourceIdentity(let existingSourceID) {
                    do {
                        try await storage.archivePodcastEpisodeDuplicate(
                            candidate.id,
                            replacingWith: existingSourceID
                        )
                        log.info("Folded \(candidate.title) into the episode already in the library")
                        return PodcastTranscriptHydrationResult(
                            id: candidate.id,
                            outcome: .failed(message: mergedPodcastEpisodeMessage),
                            mergedIntoSourceID: existingSourceID
                        )
                    } catch {
                        log.warning("Could not fold duplicate podcast row \(candidate.id): \(error.localizedDescription)")
                        return result(.failed(message: retryablePodcastTranscriptMessage))
                    }
                } catch {
                    log.warning("Could not rebind podcast row \(candidate.id): \(error.localizedDescription)")
                    return result(.failed(message: retryablePodcastTranscriptMessage))
                }
                log.info("Resolved \(candidate.title) to public episode \(episode.trackID) of \(showName)")
                trackID = episode.trackID
                sourceURL = publicURL
                webPageURL = page
                resolvedIdentity = PodcastResolvedEpisodeIdentity(url: publicURL, webPageURL: page)
            case .noPublicShow, .noMatchingEpisode:
                // No public twin. A web-page row has nothing left to try; a
                // private-feed row keeps its exact enclosure in the local
                // catalog, which the explicit Transcribe Audio action may use.
                if filedUnderWebPage || !allowAudioTranscription {
                    return result(.failed(message: noPublicPodcastEpisodeMessage))
                }
            case .failed:
                return result(.failed(message: retryablePodcastTranscriptMessage))
            }
        }

        let appleOutcome: PodcastTranscriptFetchOutcome?
        if let trackID {
            appleOutcome = await fetchAppleTranscript(trackID, homeDir)
        } else {
            appleOutcome = nil
        }

        let rawTTML: String?
        let extractedText: String
        switch appleOutcome {
        case .available(let transcript):
            rawTTML = transcript
            guard let text = await extractPodcastTTMLTextOffMain(transcript) else {
                return result(.failed(message: "Could not extract transcript text from Apple Podcasts TTML."))
            }
            extractedText = text

        case .failed:
            // A timeout, expired Apple token, rate limit, or server failure is
            // not evidence that the episode lacks an Apple transcript. Keep
            // the operation retryable instead of starting a second, paid STT
            // path for audio Apple may already have transcribed.
            return result(.failed(message: retryablePodcastTranscriptMessage))

        case .unavailable, nil:
            let unavailableMessage: String
            switch appleOutcome {
            case .unavailable:
                unavailableMessage = unavailablePodcastTranscriptMessage
            default:
                unavailableMessage = noPodcastTranscriptMessage
            }
            guard allowAudioTranscription else {
                return result(.failed(message: unavailableMessage))
            }

            rawTTML = nil
            guard let audioURL = await resolveEpisodeAudioURL(sourceURL, webPageURL, homeDir) else {
                return result(.failed(message: unavailableMessage))
            }
            do {
                log.info("The learner opted in to managed STT for \(candidate.title)")
                let transcript = try await transcribeEpisodeAudio(audioURL)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !transcript.isEmpty else {
                    throw MeetingTranscriptionService.TranscriptionError.emptyTranscript
                }
                extractedText = transcript
            } catch where AITransientErrorClassifier.isCancellation(error) {
                // Stopped, not failed: the episode says so, and is not given
                // the terminal message that would send its reader looking on
                // YouTube; Transcribe Audio asks again.
                log.info("Transcribing podcast audio for \(candidate.id) was stopped")
                return result(.failed(message: error.localizedDescription))
            } catch {
                log.warning("Could not transcribe podcast audio for \(candidate.id): \(error.localizedDescription)")
                return result(.failed(message: podcastAudioTranscriptionMessage))
            }
        }

        // The transcript reads the moment it is here (product owner,
        // 2026-10-13: "for all sources if we upload it, we should IMMEDIATELY
        // be able to already read it"). It is saved ready, laid out in
        // paragraphs with no model, and the speaker names and formatting come
        // after, from the clean-up queue, which lasts a quit and runs two
        // episodes at a time however many a first import fetches. An episode
        // that may not pay for formatting (hidden, and nobody asked for it)
        // keeps its readable transcript for a future unhide and is not queued.
        let transcript = readablePodcastTranscriptLayout(extractedText)
        let formatting: PodcastTranscriptFormattingRequest?
        if !candidate.allowsFormatting {
            log.info("Skipping transcript formatting for hidden podcast episode \(candidate.title)")
            formatting = nil
        } else if config == nil || extractedText.count <= minimumFormattableTranscriptLength {
            // No model chosen for Transcript Formatting, or nothing to format.
            formatting = nil
        } else {
            formatting = candidate.userInitiated ? .learnerAsked : .automatic
        }

        do {
            try await storage.saveTranscript(
                candidate.id,
                transcript,
                rawTTML: rawTTML,
                podcastFormatting: formatting
            )
            log.info("Hydrated podcast transcript for \(candidate.title)")
            return result(.ready(content: transcript, persistedReadyState: true))
        } catch {
            log.warning("Could not save podcast transcript for \(candidate.id): \(error.localizedDescription)")
            return result(.failed(message: "Could not save transcript: \(error.localizedDescription)"))
        }
    }

    /// The Apple store track id an episode address names, or nil for a
    /// private-feed placeholder, a legacy local row, or a web page.
    nonisolated static func publicTrackID(inPodcastURL url: String) -> Int64? {
        guard url.hasPrefix("apple-podcast:") else { return nil }
        return url.split(separator: "/").last.flatMap { Int64($0) }
    }

    nonisolated static func isWebPageAddress(_ url: String) -> Bool {
        let lowered = url.lowercased()
        return lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
    }

    /// `formatPodcastTranscript`, with a failure logged and taken for nil:
    /// for the completeness audit, which restores a cut transcript whether or
    /// not it can be formatted.
    nonisolated static func formatPodcastTranscriptOffMain(
        _ raw: String,
        sourceID: String,
        episodeTitle: String?,
        podcastName: String?,
        aiService: AIService,
        config: AITaskConfig?,
        log: Logger
    ) async -> String? {
        // No settings-resolved model means no call: substituting a literal
        // would bill a model the user never selected.
        guard let config else { return nil }
        do {
            return try await formatPodcastTranscript(
                raw,
                sourceID: sourceID,
                episodeTitle: episodeTitle,
                podcastName: podcastName,
                aiService: aiService,
                config: config,
                log: log
            )
        } catch {
            log.warning("Podcast transcript formatting failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// The formatting pass over a raw podcast transcript: speaker names where
    /// the episode makes them clear, then the model's paragraph breaks and ad
    /// reads applied by code. Nil for a transcript too short to be worth it.
    /// Throws when a paragraph request fails or the work is stopped; a speaker
    /// lookup that fails for any other reason only leaves the labels as they
    /// are.
    nonisolated static func formatPodcastTranscript(
        _ raw: String,
        sourceID: String,
        episodeTitle: String?,
        podcastName: String?,
        aiService: AIService,
        config: AITaskConfig,
        log: Logger
    ) async throws -> String? {
        guard raw.count > minimumFormattableTranscriptLength else { return nil }
        let activityID = UUID().uuidString

        let speakerNamedRaw = try await replaceInferredPodcastSpeakerLabelsOffMain(
            in: raw,
            config: config,
            sourceID: sourceID,
            activityID: activityID,
            episodeTitle: episodeTitle,
            podcastName: podcastName,
            aiService: aiService,
            log: log
        )

        let chunkSize = 50_000
        let chunks: [String]
        if speakerNamedRaw.count <= chunkSize {
            chunks = [speakerNamedRaw]
        } else {
            var result: [String] = []
            var start = speakerNamedRaw.startIndex
            while start < speakerNamedRaw.endIndex {
                let end = speakerNamedRaw.index(start, offsetBy: chunkSize, limitedBy: speakerNamedRaw.endIndex) ?? speakerNamedRaw.endIndex
                var breakAt = end
                if end < speakerNamedRaw.endIndex,
                   let dotRange = speakerNamedRaw[start..<end].range(of: ". ", options: .backwards) {
                    breakAt = speakerNamedRaw.index(after: dotRange.lowerBound)
                }
                result.append(String(speakerNamedRaw[start..<breakAt]))
                start = breakAt
            }
            chunks = result
        }

        let indexed = Array(chunks.enumerated())
        // Long episodes bill one charge per chunk, so without this the
        // ledger shows a run of identical "Transcript Formatting" rows with
        // nothing saying which episode they came from.
        let ledgerTitle = StudioViewModel.transcriptLedgerTitle(episodeTitle, podcastName)
        // Sliding window: episode hydration already runs several episodes at
        // once, so an unbounded fan-out here multiplies against that limit
        // rather than respecting it.
        let chunkResults = try await withThrowingTaskGroup(of: (Int, String, String).self) { group in
            var nextPosition = 0
            while nextPosition < min(StudioViewModel.transcriptChunkFormatConcurrency, indexed.count) {
                let (index, chunk) = indexed[nextPosition]
                group.addTask {
                    try await StudioViewModel.breakPointsForChunk(
                        index: index,
                        chunk: chunk,
                        config: config,
                        aiService: aiService,
                        ledgerTitle: ledgerTitle,
                        subjectID: sourceID,
                        activityID: activityID
                    )
                }
                nextPosition += 1
            }

            var results: [(Int, String, String)] = []
            while let result = try await group.next() {
                results.append(result)
                guard nextPosition < indexed.count else { continue }
                let (index, chunk) = indexed[nextPosition]
                group.addTask {
                    try await StudioViewModel.breakPointsForChunk(
                        index: index,
                        chunk: chunk,
                        config: config,
                        aiService: aiService,
                        ledgerTitle: ledgerTitle,
                        subjectID: sourceID,
                        activityID: activityID
                    )
                }
                nextPosition += 1
            }
            return results.sorted { $0.0 < $1.0 }
        }

        // Decided on the whole transcript: a chunk can fall inside one
        // speaker's long turn and hold no label line of its own.
        let diarized = isDiarizedPodcastTranscriptOffMain(speakerNamedRaw)
        return chunkResults
            .map { _, chunk, response in
                applyPodcastTranscriptBreakPointsOffMain(
                    to: chunk,
                    from: response,
                    transcriptIsDiarized: diarized
                )
            }
            .joined(separator: "\n\n")
    }

    nonisolated static func podcastTranscriptAdCleanupChunks(
        _ transcript: String,
        maximumCharacters: Int = 20_000
    ) -> [String] {
        guard transcript.count > maximumCharacters else { return [transcript] }
        var chunks: [String] = []
        var start = transcript.startIndex
        while start < transcript.endIndex {
            let hardEnd = transcript.index(
                start,
                offsetBy: maximumCharacters,
                limitedBy: transcript.endIndex
            ) ?? transcript.endIndex
            var end = hardEnd
            if hardEnd < transcript.endIndex {
                let slice = transcript[start..<hardEnd]
                if let paragraph = slice.range(of: "\n\n", options: .backwards),
                   transcript.distance(from: start, to: paragraph.upperBound) >= maximumCharacters / 2 {
                    end = paragraph.upperBound
                } else if let sentence = slice.range(of: ". ", options: .backwards),
                          transcript.distance(from: start, to: sentence.upperBound) >= maximumCharacters / 2 {
                    end = sentence.upperBound
                }
            }
            chunks.append(String(transcript[start..<end]))
            start = end
        }
        return chunks
    }

    /// Ask the model where one chunk's paragraph breaks belong. Split out of the
    /// task group so the sliding window can enqueue it from two places without
    /// duplicating the request, and without a nested closure capturing the group.
    nonisolated static func breakPointsForChunk(
        index: Int,
        chunk: String,
        config: AITaskConfig,
        aiService: AIService,
        ledgerTitle: String? = nil,
        subjectID: String? = nil,
        activityID: String? = nil
    ) async throws -> (Int, String, String) {
        // Break-point placement is pattern work, and hidden reasoning was
        // costing 12,000 to 18,000 tokens and one to three minutes per chunk
        // for a two-hundred-token answer. Ask for the least reasoning the
        // model allows.
        let response = try await AIBackgroundRetry.run(config: config) { config in
            try await aiService.call(
                config: config,
                system: Prompts.transcriptFormattingBreakPoints,
                user: chunk,
                maxTokens: 4_000,
                temperature: 0.2,
                disablesReasoning: true,
                sourceTitle: ledgerTitle,
                subjectID: subjectID,
                subjectType: subjectID == nil ? nil : "podcast_episode",
                activityID: activityID
            )
        }
        return (index, chunk, response)
    }

    nonisolated static func replaceInferredPodcastSpeakerLabelsOffMain(
        in raw: String,
        config: AITaskConfig,
        sourceID: String,
        activityID: String,
        episodeTitle: String?,
        podcastName: String?,
        aiService: AIService,
        log: Logger
    ) async throws -> String {
        let mapping = try await inferPodcastSpeakerNameMappingOffMain(
            raw,
            config: config,
            sourceID: sourceID,
            activityID: activityID,
            episodeTitle: episodeTitle,
            podcastName: podcastName,
            aiService: aiService,
            log: log
        )
        guard !mapping.isEmpty else { return raw }
        return applyPodcastSpeakerNameMappingOffMain(mapping, to: raw)
    }

    nonisolated static func inferPodcastSpeakerNameMappingOffMain(
        _ raw: String,
        config: AITaskConfig,
        sourceID: String,
        activityID: String,
        episodeTitle: String?,
        podcastName: String?,
        aiService: AIService,
        log: Logger
    ) async throws -> [String: String] {
        let speakerIDs = PodcastSpeakerNameInference.speakerIDs(in: raw)
        guard !speakerIDs.isEmpty else { return [:] }
        let system = """
        You identify actual speaker names in podcast transcripts.

        Return ONLY a JSON object whose keys are existing speaker IDs like "SPEAKER_1" and values are \
        the actual person's name.

        Rules:
        - Include a mapping only when the transcript or metadata makes the name clear.
        - Use real names only, such as "Dwarkesh Patel", "Nick Lane", or "Dwarkesh".
        - Do not use role labels like Host, Guest, Interviewer, Interviewee, Narrator, or Speaker 1.
        - Align the name to the speaker ID that actually says the turn. A person mentioned by a speaker \
        is not necessarily that speaker.
        - Intro clues like "I'm your host, X" identify the current speaker. Guest introductions like \
        "today's guest is Y" usually identify the next different speaker who responds to the welcome.
        - For multiple hosts, co-hosts, or guests, map each diarized speaker ID separately only when a \
        turn belongs to that person.
        - Do not invent names. Omit uncertain speakers.
        - Output valid JSON only, no commentary, no markdown fences.
        """
        let userMessage = podcastSpeakerInferenceUserMessageOffMain(
            speakerIDs: speakerIDs,
            episodeTitle: episodeTitle,
            podcastName: podcastName,
            sourceURL: nil,
            podcastWebPageURL: nil,
            transcript: raw,
            excerptLimit: 80_000
        )

        do {
            let response = try await aiService.call(
                config: config,
                system: system,
                user: userMessage,
                maxTokens: 800,
                temperature: 0,
                disablesReasoning: true,
                sourceTitle: StudioViewModel.transcriptLedgerTitle(episodeTitle, podcastName),
                subjectID: sourceID,
                subjectType: "podcast_episode",
                activityID: activityID
            )
            return parsePodcastSpeakerNameMappingOffMain(response, validSpeakerIDs: speakerIDs, log: log)
        } catch where AITransientErrorClassifier.isCancellation(error) {
            // Stopped, not failed: the transcript waits to be formatted whole,
            // names and all, rather than going on without them.
            throw error
        } catch {
            log.warning("Podcast speaker-name inference failed: \(error.localizedDescription)")
            return [:]
        }
    }

    nonisolated static func podcastSpeakerInferenceUserMessageOffMain(
        speakerIDs: Set<String>,
        episodeTitle: String?,
        podcastName: String?,
        sourceURL: String?,
        podcastWebPageURL: String?,
        transcript: String,
        excerptLimit: Int
    ) -> String {
        let metadata = [
            episodeTitle.map { "Episode title: \($0)" },
            podcastName.map { "Podcast/show: \($0)" },
            sourceURL.map { "Source URL: \($0)" },
            podcastWebPageURL.map { "Podcast episode web page: \($0)" }
        ].compactMap { $0 }.joined(separator: "\n")

        let transcriptExcerpt = transcript.count > excerptLimit
            ? String(transcript.prefix(excerptLimit))
            : transcript
        let speakerEvidence = PodcastSpeakerNameInference.evidenceSummary(
            from: transcript,
            speakerIDs: speakerIDs
        )

        return """
        Speaker IDs: \(speakerIDs.sorted().joined(separator: ", "))

        \(metadata)

        Speaker evidence:
        \(speakerEvidence)

        Transcript:
        \(transcriptExcerpt)
        """
    }

    nonisolated static func parsePodcastSpeakerNameMappingOffMain(
        _ response: String,
        validSpeakerIDs: Set<String>,
        log: Logger
    ) -> [String: String] {
        var json = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```") {
            json = json.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if json.hasSuffix("```") {
                json = String(json.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            log.warning("Could not parse podcast speaker-name mapping")
            return [:]
        }

        var result: [String: String] = [:]
        for (speakerID, name) in decoded {
            let trimmedID = speakerID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard validSpeakerIDs.contains(trimmedID),
                  PodcastSpeakerNameInference.isValidPersonName(trimmedName) else { continue }
            result[trimmedID] = trimmedName
        }

        return withoutDuplicatePodcastSpeakerNamesOffMain(result)
    }

    nonisolated static func mergePodcastSpeakerNameMappingsOffMain(
        _ primary: [String: String],
        _ secondary: [String: String]
    ) -> [String: String] {
        var merged = primary
        for (speakerID, name) in secondary where merged[speakerID] == nil {
            merged[speakerID] = name
        }
        return withoutDuplicatePodcastSpeakerNamesOffMain(merged)
    }

    nonisolated static func withoutDuplicatePodcastSpeakerNamesOffMain(_ mapping: [String: String]) -> [String: String] {
        let duplicateNames = Dictionary(grouping: mapping) { $0.value.lowercased() }
            .filter { $0.value.count > 1 }
            .keys
        guard !duplicateNames.isEmpty else { return mapping }
        return mapping.filter { !duplicateNames.contains($0.value.lowercased()) }
    }

    nonisolated static func applyPodcastSpeakerNameMappingOffMain(
        _ mapping: [String: String],
        to text: String
    ) -> String {
        mapping.reduce(text) { partial, entry in
            partial
                .replacingOccurrences(of: "[\(entry.key)]", with: "[\(entry.value)]")
                .replacingOccurrences(of: "**\(entry.key.replacingOccurrences(of: "_", with: " ").capitalized):**", with: "**\(entry.value):**")
        }
    }

    nonisolated static func podcastTranscriptAdRemovalCandidatesOffMain(
        to text: String,
        from response: String
    ) -> [PodcastTranscriptAdRemovalCandidate] {
        var json = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```") {
            json = json.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if json.hasSuffix("```") {
                json = String(json.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard let data = json.data(using: .utf8),
              let annotations = try? JSONDecoder().decode([PodcastTranscriptAnnotation].self, from: data) else {
            return []
        }

        let candidates = annotations.enumerated().compactMap { index, annotation -> PodcastTranscriptAdRemovalCandidate? in
            guard let rawStart = annotation.adStart,
                  let rawEnd = annotation.adEnd else { return nil }
            let start = rawStart.trimmingCharacters(in: .whitespacesAndNewlines)
            let end = rawEnd.trimmingCharacters(in: .whitespacesAndNewlines)
            guard start.count >= 12, end.count >= 12 else { return nil }

            let startRanges = exactPodcastTranscriptRangesOffMain(of: start, in: text)
            guard startRanges.count == 1, let startRange = startRanges.first else { return nil }
            let endRanges = exactPodcastTranscriptRangesOffMain(
                of: end,
                in: text,
                searchStart: startRange.lowerBound
            )
            guard endRanges.count == 1, let endRange = endRanges.first,
                  endRange.upperBound > startRange.lowerBound else { return nil }

            var removalStart = startRange.lowerBound
            while removalStart > text.startIndex {
                let previous = text.index(before: removalStart)
                guard text[previous].isWhitespace else { break }
                removalStart = previous
            }
            var removalEnd = endRange.upperBound
            while removalEnd < text.endIndex, text[removalEnd].isWhitespace {
                removalEnd = text.index(after: removalEnd)
            }
            let removalLength = text.distance(from: removalStart, to: removalEnd)
            guard removalLength <= 20_000 else { return nil }

            return PodcastTranscriptAdRemovalCandidate(
                annotationIndex: index,
                lowerCharacterOffset: text.distance(from: text.startIndex, to: removalStart),
                upperCharacterOffset: text.distance(from: text.startIndex, to: removalEnd),
                proposedDeletion: String(text[removalStart..<removalEnd]),
                precedingContext: String(text[..<removalStart].suffix(400)),
                followingContext: String(text[removalEnd...].prefix(400))
            )
        }
        .sorted { $0.lowerCharacterOffset < $1.lowerCharacterOffset }

        var nonOverlapping: [PodcastTranscriptAdRemovalCandidate] = []
        for candidate in candidates {
            guard nonOverlapping.last.map({ candidate.lowerCharacterOffset < $0.upperCharacterOffset }) != true else {
                continue
            }
            nonOverlapping.append(candidate)
        }
        let removedCharacterCount = nonOverlapping.reduce(0) {
            $0 + ($1.upperCharacterOffset - $1.lowerCharacterOffset)
        }
        return removedCharacterCount * 100 <= text.count * 45 ? nonOverlapping : []
    }

    nonisolated static func applyPodcastTranscriptAdRemovalsOffMain(
        to text: String,
        candidates: [PodcastTranscriptAdRemovalCandidate]
    ) -> String {
        var result = text
        for candidate in candidates.sorted(by: {
            $0.lowerCharacterOffset > $1.lowerCharacterOffset
        }) {
            guard candidate.lowerCharacterOffset >= 0,
                  candidate.upperCharacterOffset >= candidate.lowerCharacterOffset,
                  let lower = result.index(
                    result.startIndex,
                    offsetBy: candidate.lowerCharacterOffset,
                    limitedBy: result.endIndex
                  ),
                  let upper = result.index(
                    result.startIndex,
                    offsetBy: candidate.upperCharacterOffset,
                    limitedBy: result.endIndex
                  ) else { continue }
            result.replaceSubrange(lower..<upper, with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A speaker label on a line of its own (`[SPEAKER_1]`, `[Nick Lane]`), as
    /// TTML extraction writes one before each speaker's turn.
    nonisolated private static let podcastSpeakerLabelLine = try! NSRegularExpression(
        pattern: #"^[ \t]*\[[^\[\]\n]{1,80}\][ \t]*$"#,
        options: [.anchorsMatchLines]
    )

    /// Whether the transcript's source already says who speaks: a label line
    /// before each turn, as Apple's TTML has after extraction.
    nonisolated static func isDiarizedPodcastTranscriptOffMain(_ text: String) -> Bool {
        podcastSpeakerLabelLine.firstMatch(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        ) != nil
    }

    nonisolated private static func isPodcastSpeakerLabelLine(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        guard trimmed.count >= 3, trimmed.count <= 82,
              trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return false }
        let inner = trimmed.dropFirst().dropLast()
        return !inner.contains("[") && !inner.contains("]")
    }

    // MARK: - Readable before any model

    /// A podcast transcript as it reads before any model has touched it. Each
    /// stretch of speech (one speaker's turn under its `[SPEAKER_1]` line, or
    /// a stretch speech-to-text returned with no speakers at all) is cut into
    /// paragraphs at sentence ends by `readableTranscriptParagraphs`. Words,
    /// their order and the label lines stay as they were; only blank lines
    /// are added, and `podcastTranscriptWithoutLayout` takes them out again.
    nonisolated static func readablePodcastTranscriptLayout(_ transcript: String) -> String {
        transcript
            .components(separatedBy: "\n\n")
            .map { block in
                var lines = block.split(separator: "\n", omittingEmptySubsequences: false)
                let label = lines.first.flatMap { isPodcastSpeakerLabelLine($0) ? String($0) : nil }
                if label != nil { lines.removeFirst() }
                // A stretch that already breaks into lines keeps its own shape.
                guard lines.count == 1 else { return block }
                let paragraphs = readableTranscriptParagraphs(String(lines[0]))
                return label.map { "\($0)\n\(paragraphs)" } ?? paragraphs
            }
            .joined(separator: "\n\n")
    }

    /// The transcript `readablePodcastTranscriptLayout` was given: the
    /// paragraphs of each stretch of speech run back together into one, the
    /// shape the formatting pass places its own breaks in. A blank line before
    /// a speaker's label stays. For Apple's transcript this is exactly the
    /// text extracted from the TTML; for speech-to-text, whose stretches have
    /// no labels between them, the whole transcript becomes one run.
    nonisolated static func podcastTranscriptWithoutLayout(_ transcript: String) -> String {
        var blocks: [String] = []
        for block in transcript.components(separatedBy: "\n\n") {
            if let last = blocks.last, !last.isEmpty, !block.isEmpty,
               !isPodcastSpeakerLabelLine(block.prefix(while: { $0 != "\n" })) {
                blocks[blocks.count - 1] = last + " " + block
            } else {
                blocks.append(block)
            }
        }
        return blocks.joined(separator: "\n\n")
    }

    /// A run of speech cut into paragraphs at sentence ends: four sentences or
    /// about 95 words a paragraph, a short tail kept with the paragraph before
    /// it, and a run of 140 words or fewer left whole. Speech with no sentence
    /// ends is cut every 95 words. The Mac reader draws an episode's TTML with
    /// the same rule (`PodcastTranscriptParser`), so an episode reads alike
    /// there and wherever its stored text is shown.
    nonisolated static func readableTranscriptParagraphs(_ text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard transcriptWordCount(cleaned) > 140 else { return cleaned }

        let sentences = transcriptSentenceParagraphs(cleaned)
        guard sentences.count > 1 else {
            return transcriptWordParagraphs(cleaned).joined(separator: "\n\n")
        }

        return sentences.joined(separator: "\n\n")
    }

    nonisolated private static func transcriptSentenceParagraphs(_ text: String) -> [String] {
        let separated = text
            .replacingOccurrences(of: #"(?<=[.!?])\s+"#, with: "\u{0}", options: .regularExpression)
        let sentences = separated
            .components(separatedBy: "\u{0}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard sentences.count > 1 else { return [] }

        var chunks: [String] = []
        var current: [String] = []
        var currentWordCount = 0

        for sentence in sentences {
            current.append(sentence)
            currentWordCount += transcriptWordCount(sentence)
            if current.count >= 4 || currentWordCount >= 95 {
                chunks.append(current.joined(separator: " "))
                current = []
                currentWordCount = 0
            }
        }

        if !current.isEmpty {
            let remainder = current.joined(separator: " ")
            if transcriptWordCount(remainder) < 35, let last = chunks.popLast() {
                chunks.append(last + " " + remainder)
            } else {
                chunks.append(remainder)
            }
        }

        return chunks
    }

    nonisolated private static func transcriptWordParagraphs(_ text: String) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        guard words.count > 140 else { return [text] }

        var chunks: [String] = []
        var current: [String] = []
        for word in words {
            current.append(word)
            if current.count >= 95 {
                chunks.append(current.joined(separator: " "))
                current = []
            }
        }
        if !current.isEmpty {
            chunks.append(current.joined(separator: " "))
        }
        return chunks
    }

    nonisolated private static func transcriptWordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace }.count
    }

    /// Whether a paragraph break at `index` would add only blank lines: the
    /// text ends there, or already breaks there into a new paragraph or a
    /// speaker's turn, or the point ends a speaker label line (a break there
    /// would part the label from its turn).
    nonisolated static func podcastTranscriptBreaksAlreadyOffMain(
        _ text: String,
        at index: String.Index
    ) -> Bool {
        var cursor = index
        while cursor < text.endIndex, text[cursor] == " " || text[cursor] == "\t" {
            cursor = text.index(after: cursor)
        }
        guard cursor < text.endIndex else { return true }
        guard text[cursor] == "\n" else { return false }
        let lineStart = text[..<index].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        if isPodcastSpeakerLabelLine(text[lineStart..<cursor]) { return true }
        let nextStart = text.index(after: cursor)
        let nextEnd = text[nextStart...].firstIndex(of: "\n") ?? text.endIndex
        let nextLine = text[nextStart..<nextEnd]
        return nextLine.allSatisfy { $0 == " " || $0 == "\t" } || isPodcastSpeakerLabelLine(nextLine)
    }

    /// - Parameter transcriptIsDiarized: whether the whole transcript names its
    ///   speakers on label lines; nil reads it from `text`.
    nonisolated static func applyPodcastTranscriptBreakPointsOffMain(
        to text: String,
        from response: String,
        transcriptIsDiarized: Bool? = nil
    ) -> String {
        struct Annotation: Decodable {
            let after: String?
            let speaker: String?
            let adStart: String?
            let adEnd: String?

            enum CodingKeys: String, CodingKey {
                case after, speaker
                case adStart = "ad_start"
                case adEnd = "ad_end"
            }
        }

        var json = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```") {
            json = json.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if json.hasSuffix("```") {
                json = String(json.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard let data = json.data(using: .utf8),
              let annotations = try? JSONDecoder().decode([Annotation].self, from: data) else {
            return text
        }

        // The model decides what is advertising, but it never rewrites the
        // transcript. Deletions are applied only when both exact boundaries are
        // unique, ordered, bounded, and collectively cover less than 45% of the
        // chunk. That keeps a malformed or over-eager response from erasing the
        // episode's editorial content.
        let candidateRemovalRanges = annotations.compactMap { annotation -> Range<String.Index>? in
            guard let rawStart = annotation.adStart,
                  let rawEnd = annotation.adEnd else { return nil }
            let start = rawStart.trimmingCharacters(in: .whitespacesAndNewlines)
            let end = rawEnd.trimmingCharacters(in: .whitespacesAndNewlines)
            guard start.count >= 12, end.count >= 12 else { return nil }

            let startRanges = exactPodcastTranscriptRangesOffMain(of: start, in: text)
            guard startRanges.count == 1, let startRange = startRanges.first else { return nil }
            let endRanges = exactPodcastTranscriptRangesOffMain(
                of: end,
                in: text,
                searchStart: startRange.lowerBound
            )
            guard endRanges.count == 1, let endRange = endRanges.first,
                  endRange.upperBound > startRange.lowerBound else { return nil }

            var removalStart = startRange.lowerBound
            while removalStart > text.startIndex {
                let previous = text.index(before: removalStart)
                guard text[previous].isWhitespace else { break }
                removalStart = previous
            }
            var removalEnd = endRange.upperBound
            while removalEnd < text.endIndex, text[removalEnd].isWhitespace {
                removalEnd = text.index(after: removalEnd)
            }
            let removalRange = removalStart..<removalEnd
            let removalLength = text.distance(from: removalRange.lowerBound, to: removalRange.upperBound)
            guard removalLength <= 20_000 else { return nil }
            return removalRange
        }
        .sorted { $0.lowerBound < $1.lowerBound }

        var removalRanges: [Range<String.Index>] = []
        for range in candidateRemovalRanges {
            guard removalRanges.last.map({ range.lowerBound < $0.upperBound }) != true else { continue }
            removalRanges.append(range)
        }
        let removedCharacterCount = removalRanges.reduce(into: 0) { count, range in
            count += text.distance(from: range.lowerBound, to: range.upperBound)
        }
        if removedCharacterCount * 100 > text.count * 45 {
            removalRanges.removeAll()
        }

        var result = text
        for range in removalRanges.reversed() {
            result.replaceSubrange(range, with: "\n\n")
        }

        // A transcript its source diarized already names each turn on a
        // `[Name]` line, and the model's "speaker" could only repeat it — a
        // `**Name:**` marker right above the `[Name]` line, in 390 of 1,092
        // stored episodes on 2026-10-06 — or contradict it, as when a host's
        // welcome was filed under the guest's name. Such a transcript takes the
        // model's paragraph breaks and none of its speakers.
        let diarized = transcriptIsDiarized ?? isDiarizedPodcastTranscriptOffMain(text)
        for annotation in annotations.reversed() {
            guard let rawAfter = annotation.after else { continue }
            let after = rawAfter.trimmingCharacters(in: .whitespacesAndNewlines)
            guard after.count >= 8,
                  let range = result.range(of: after, options: .backwards) else { continue }
            let speaker = diarized ? nil : normalizedPodcastTranscriptSpeakerLabelOffMain(annotation.speaker)
            // A break where the text already breaks — before a speaker's turn,
            // where an ad was taken out, where another annotation broke it —
            // only stacks blank lines (four or six newlines in 303 stored
            // episodes). A speaker named there opens the paragraph that follows.
            if podcastTranscriptBreaksAlreadyOffMain(result, at: range.upperBound) {
                if let speaker,
                   let start = podcastTranscriptParagraphStartOffMain(result, after: range.upperBound) {
                    result.insert(contentsOf: "**\(speaker):** ", at: start)
                }
                continue
            }
            var insertion = "\n\n"
            if let speaker {
                insertion += "**\(speaker):** "
            }
            result.insert(contentsOf: insertion, at: range.upperBound)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where the paragraph after `index` begins, past the break; nil at the
    /// end of the text, or when that paragraph opens with a speaker of its own.
    nonisolated private static func podcastTranscriptParagraphStartOffMain(
        _ text: String,
        after index: String.Index
    ) -> String.Index? {
        guard let start = text[index...].firstIndex(where: { !$0.isWhitespace }) else { return nil }
        let lineEnd = text[start...].firstIndex(of: "\n") ?? text.endIndex
        if text[start...].hasPrefix("**") || isPodcastSpeakerLabelLine(text[start..<lineEnd]) { return nil }
        return start
    }

    nonisolated private static func exactPodcastTranscriptRangesOffMain(
        of snippet: String,
        in text: String,
        searchStart: String.Index? = nil
    ) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var cursor = searchStart ?? text.startIndex
        while cursor < text.endIndex,
              let range = text.range(of: snippet, range: cursor..<text.endIndex) {
            ranges.append(range)
            guard range.upperBound < text.endIndex else { break }
            cursor = range.upperBound
        }
        return ranges
    }

    nonisolated static func normalizedPodcastTranscriptSpeakerLabelOffMain(_ label: String?) -> String? {
        guard let label else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 60 else { return nil }
        guard trimmed.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) == nil else { return nil }
        guard trimmed.range(of: #"^[A-Za-z][A-Za-z0-9.'’_ -]{0,59}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return trimmed
    }

    nonisolated static func extractPodcastTTMLTextOffMain(_ rawTTML: String) async -> String? {
        await Task.detached(priority: .utility) {
            try? SourceService.extractTextFromTTMLContent(rawTTML)
        }.value
    }

    nonisolated static func podcastTranscriptHTTPDisposition(statusCode: Int) -> PodcastTranscriptHTTPDisposition {
        switch statusCode {
        case 200:
            .success
        case 401:
            .authenticationExpired
        case 404:
            .unavailable
        case 403:
            // The Podcasts app may have an entitlement or cached asset that
            // the catalog request does not. A denial does not prove that the
            // episode has no Apple transcript, so never spend on STT from it.
            .failed
        default:
            .failed
        }
    }

    nonisolated static func fetchPodcastTranscriptOffMain(
        trackId: Int64,
        homeDir: String
    ) async -> PodcastTranscriptFetchOutcome {
        if let cached = await cachedPodcastTTMLContentOffMain(trackId: trackId, homeDir: homeDir) {
            return .available(cached)
        }

        let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "Studio")

        // Not cached — download via Apple Podcasts transcript API directly.

        // Query the transcript API to get the signed TTML download URL
        let apiURLStr = "https://amp-api.podcasts.apple.com/v1/catalog/us/podcast-episodes/\(trackId)/transcripts?fields=ttmlToken,ttmlAssetUrls&include%5Bpodcast-episodes%5D=podcast&l=en-US&with=entitlements"
        guard let apiURL = URL(string: apiURLStr) else { return .failed }

        for attempt in 0..<2 {
            guard let bearer = await Self.obtainPodcastBearerToken(homeDir: homeDir, forceRefresh: attempt > 0) else {
                log.warning("Could not obtain bearer token for podcast transcript API")
                return .failed
            }

            var request = URLRequest(url: apiURL)
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    log.warning("Transcript API returned non-HTTP response for trackId \(trackId)")
                    return .failed
                }

                let disposition = podcastTranscriptHTTPDisposition(statusCode: httpResponse.statusCode)
                if disposition == .authenticationExpired, attempt == 0 {
                    log.warning("Podcast transcript bearer token rejected; refreshing token and retrying")
                    Self.invalidateCachedPodcastBearerTokens(homeDir: homeDir)
                    continue
                }

                if disposition == .unavailable {
                    log.info("Apple Podcasts does not expose a transcript for trackId \(trackId)")
                    return .unavailable
                }

                guard disposition == .success else {
                    log.warning("Transcript API returned status \(httpResponse.statusCode) for trackId \(trackId)")
                    return .failed
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let dataArray = json["data"] as? [[String: Any]] else {
                    log.warning("Could not parse transcript API response for trackId \(trackId)")
                    return .failed
                }
                guard let first = dataArray.first else {
                    log.info("Apple Podcasts returned no transcript record for trackId \(trackId)")
                    return .unavailable
                }
                guard let attrs = first["attributes"] as? [String: Any] else {
                    log.warning("Transcript API response omitted attributes for trackId \(trackId)")
                    return .failed
                }
                guard let ttmlAssetUrls = attrs["ttmlAssetUrls"] as? [String: String],
                      let ttmlURLStr = ttmlAssetUrls["ttml"] else {
                    log.info("Apple Podcasts returned no TTML asset for trackId \(trackId)")
                    return .unavailable
                }
                guard let ttmlURL = URL(string: ttmlURLStr) else {
                    log.warning("Transcript API returned an invalid TTML URL for trackId \(trackId)")
                    return .failed
                }

                // Download the actual TTML file
                let (ttmlData, ttmlResponse) = try await URLSession.shared.data(from: ttmlURL)
                guard let ttmlHttpResponse = ttmlResponse as? HTTPURLResponse else {
                    log.warning("Failed to download TTML for trackId \(trackId)")
                    return .failed
                }
                let ttmlDisposition = podcastTranscriptHTTPDisposition(statusCode: ttmlHttpResponse.statusCode)
                if ttmlDisposition == .unavailable {
                    log.info("Apple Podcasts TTML asset is unavailable for trackId \(trackId)")
                    return .unavailable
                }
                guard ttmlDisposition == .success, ttmlData.count > 100 else {
                    log.warning("Failed to download TTML for trackId \(trackId): status \(ttmlHttpResponse.statusCode)")
                    return .failed
                }

                // Return raw TTML content as string
                guard let ttmlString = String(data: ttmlData, encoding: .utf8) else {
                    log.warning("Failed to decode TTML data as UTF-8 for trackId \(trackId)")
                    return .failed
                }
                return .available(ttmlString)
            } catch {
                log.warning("Transcript download failed for trackId \(trackId): \(error)")
                return .failed
            }
        }

        return .failed
    }

    nonisolated static func cachedPodcastTTMLContentOffMain(trackId: Int64, homeDir: String) async -> String? {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let ttmlBaseDir = (homeDir as NSString).appendingPathComponent(
                "Library/Group Containers/243LU875E5.groups.com.apple.podcasts/Library/Cache/Assets/TTML"
            )
            // Synced podcast rows can exist on a Mac that never granted local
            // Podcasts access. Do not turn background transcript hydration into
            // an implicit macOS app-data permission prompt.
            guard fm.isReadableFile(atPath: ttmlBaseDir),
                  let enumerator = fm.enumerator(atPath: ttmlBaseDir) else {
                return nil
            }

            // Match both old format (transcript_NNNN.ttml) and new format
            // (transcript_NNNN.ttml-NNNN.ttml) used by recent macOS/iOS versions.
            let prefix = "transcript_\(trackId).ttml"
            while let file = enumerator.nextObject() as? String {
                let filename = (file as NSString).lastPathComponent
                guard filename.hasPrefix(prefix) else { continue }
                let cachePath = (ttmlBaseDir as NSString).appendingPathComponent(file)
                return try? String(contentsOfFile: cachePath, encoding: .utf8)
            }

            return nil
        }.value
    }

    /// Resolve the exact enclosure for a public or private Apple Podcasts
    /// episode without persisting signed/private feed URLs. Public episodes use
    /// the indexed track-id lookup; private episodes are matched against the
    /// same deterministic placeholder URL used during discovery.
    nonisolated static func podcastEpisodeAudioURLForTranscriptionOffMain(
        sourceURL: String,
        webPageURL: String? = nil,
        homeDir: String
    ) async -> URL? {
        let localURL = await Task.detached(priority: .utility) { () -> URL? in
            let dbPath = (homeDir as NSString).appendingPathComponent(
                "Library/Group Containers/243LU875E5.groups.com.apple.podcasts/Documents/MTLibrary.sqlite"
            )
            let metadata: PodcastEpisodeMetadata?
            if let trackID = sourceURL.split(separator: "/").last.flatMap({ Int64($0) }) {
                metadata = SourceDiscovery.lookupPodcastMetadata(
                    dbPath: dbPath,
                    storeTrackIds: [trackID]
                )[trackID]
            } else {
                let discovery = SourceDiscovery.discoverPlayedEpisodes(dbPath: dbPath)
                metadata = discovery.episodes.first {
                    SourceDiscovery.podcastEpisodeURL(for: $0) == sourceURL
                }
            }

            guard let rawURL = metadata?.enclosureURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawURL.isEmpty,
                  let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else { return nil }
            return url
        }.value
        if let localURL { return localURL }
        guard let webPageURL,
              let pageURL = URL(string: webPageURL),
              let scheme = pageURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return await podcastFeedEnclosureURL(pageURL: pageURL)
    }

    /// Public podcast pages commonly expose an origin-level RSS feed. Match the
    /// episode by its exact canonical page URL, then use that item's enclosure;
    /// no title or fuzzy text matching is involved.
    nonisolated private static func podcastFeedEnclosureURL(pageURL: URL) async -> URL? {
        guard var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/feed"
        components.query = nil
        components.fragment = nil
        guard let feedURL = components.url else { return nil }
        var request = URLRequest(url: feedURL)
        request.setValue("Mozilla/5.0 ForeverLM", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true else {
            return nil
        }
        let parser = XMLParser(data: data)
        let delegate = PodcastFeedEnclosureParser(targetPageURL: pageURL)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.enclosureURL
    }

    /// Obtain a bearer token for the Apple Podcasts transcript API.
    ///
    /// Strategy:
    /// 1. Return a cached token from Application Support if it is still valid (30 days).
    /// 2. Otherwise run the bundled PodcastTokenHelper, which mints a freshly
    ///    signed token via the private PodcastsFoundation framework and prints
    ///    it to stdout. The helper isolates that crash-prone signing in its own
    ///    process, so a failure there can never take down the app.
    ///
    /// Any token obtained is persisted to Application Support for future launches.
    nonisolated static func obtainPodcastBearerToken(homeDir: String, forceRefresh: Bool = false) async -> String? {
        let fm = FileManager.default
        let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "PodcastToken")
        let cacheValidity: TimeInterval = 60 * 60 * 24 * 30 // 30 days

        let appSupportTokenPath: String? = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            .map { $0.appendingPathComponent("podcast_bearer_token.txt").path }

        if !forceRefresh, let path = appSupportTokenPath,
           let token = Self.readCachedBearerToken(at: path, validity: cacheValidity) {
            return token
        }

        // Locate the embedded helper. In shipping builds it lives in the app's
        // Contents/MacOS (found by pathForAuxiliaryExecutable); the explicit
        // paths cover development runs where the tool sits beside the .app in the
        // build products directory.
        var candidateTools: [String] = []
        if let p = Bundle.main.path(forAuxiliaryExecutable: "PodcastTokenHelper") {
            candidateTools.append(p)
        }
        let bundleURL = Bundle.main.bundleURL
        candidateTools.append(bundleURL.appendingPathComponent("Contents/MacOS/PodcastTokenHelper").path)
        candidateTools.append(bundleURL.deletingLastPathComponent()
            .appendingPathComponent("PodcastTokenHelper").path)

        guard let toolPath = candidateTools.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            log.warning("Podcast bearer token: PodcastTokenHelper not found in app bundle")
            return nil
        }

        log.info("Podcast bearer token: running PodcastTokenHelper at \(toolPath)")

        let token: String? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: toolPath)

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    log.warning("Podcast bearer token: could not launch helper: \(error)")
                    continuation.resume(returning: nil)
                    return
                }

                // Drain stdout fully before waiting so the child never blocks on a
                // full pipe; the token is a single short line.
                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                let output = String(data: outData, encoding: .utf8) ?? ""
                let candidate = output
                    .split(whereSeparator: \.isNewline).first
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespaces) ?? ""

                if candidate.count > 10, candidate.hasPrefix("ey") {
                    log.info("Podcast bearer token: obtained via PodcastTokenHelper")
                    continuation.resume(returning: candidate)
                } else {
                    let errOut = String(
                        data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8) ?? ""
                    log.warning("Podcast bearer token: helper exited \(process.terminationStatus), stderr: \(errOut.prefix(200))")
                    continuation.resume(returning: nil)
                }
            }
        }

        if let token, let appPath = appSupportTokenPath {
            try? token.write(toFile: appPath, atomically: true, encoding: .utf8)
        }
        return token
    }

    nonisolated static func invalidateCachedPodcastBearerTokens(homeDir: String) {
        let fm = FileManager.default
        if let appSupportPath = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("podcast_bearer_token.txt")
            .path {
            try? fm.removeItem(atPath: appSupportPath)
        }
    }

    /// Read and validate a cached bearer token file.
    nonisolated static func readCachedBearerToken(at path: String, validity: TimeInterval) -> String? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modDate) < validity,
              let token = try? String(contentsOfFile: path, encoding: .utf8)
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              token.count > 10, token.hasPrefix("ey") else {
            return nil
        }
        return token
    }
}
