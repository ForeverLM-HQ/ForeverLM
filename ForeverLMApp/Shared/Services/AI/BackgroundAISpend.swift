import Foundation
import os

// MARK: - Spend control for background AI
//
// A change to the cleaner can re-queue every ready paper and article for
// canonical clean-up, and each clean-up commit queues a paid Text-to-Speech
// Preparation pass behind it: thousands of model calls on the learner's own
// OpenRouter key, when only a fraction of the sources are affected by the
// change. Three controls keep that spend in the learner's hands:
//
// 1. A bulk re-queue into a paid background queue waits for the learner to
//    choose: run all of it, run only what the change affects, or skip it
//    (`BackgroundAIBulkQueue`, `KnowledgeStore.holdingBulkRequeue`).
// 2. Background tasks stop at a daily cap the learner sets
//    (`BackgroundAIDailyCap`, `BackgroundAIBudget`).
// 3. Listen is prepared when someone listens, or for the kinds automatic
//    audio covers, not after every change to a source's text
//    (`KnowledgeStore.enqueueSourceListenableContentPreparation`). That
//    includes a new import: most papers are read, not heard.

extension AITask {
    /// Whether this task's calls are background work: the daily cap counts
    /// them and the drains that run them pause when it is reached.
    ///
    /// Exempt are chat, reviews and whatever the learner starts: a course, an
    /// explainer, a walkthrough, a day plan redrawn on request. The ledger
    /// records a call's task, not who started it, so a background task the
    /// learner also triggers by hand (Text-to-Speech Preparation when they press
    /// Listen, metadata when they add a paper) still counts. Those calls are
    /// never paused; only the maintenance drains are. Exhaustive on purpose:
    /// a new task has to be classified here to compile.
    var isBackgroundWork: Bool {
        switch self {
        case .chat,
             .reviewGrading,
             .mobileReview,
             .mobileVoiceAgent,
             .deepResearch,
             // Discover runs when the learner searches a notebook's Add sources.
             .sourceDiscovery,
             .notebookNotesMerge,
             .cohortSessionPlan,
             .courseCurriculumPlan,
             .courseLessonWriting,
             .explainerWriting,
             // Written when the learner makes a notebook's audio overview.
             .audioOverviewWriting,
             // Written when the learner makes a notebook's report.
             .reportWriting,
             // Written when the learner makes a mnemonic reading.
             .mnemonicReadingWriting,
             .walkthroughWriting,
             .walkthroughAnimation,
             // Written when the learner asks for a course's quizzes, or opens one.
             .lectureQuizWriting,
             .courseQuizWriting,
             // Planned when the learner adds a textbook to a course.
             .courseTextbookReadings,
             // Asked of the Canvas, an Atlas opened, the Reader's Levels
             // opened: each one the learner's own press.
             .canvasAsk, .atlasWriting, .sourceLevels,
             // Spoken to the Canvas: each request the learner's own words.
             .canvasVoice,
             // Go Deeper on a card in the review, and Check on one.
             .cardGoDeeper,
             .cardAnswerCheck:
            return false
        case .realtimeReviewPreparation,
             // A chat's title and its history summary run on Background's
             // model and count against the cap; nothing pauses them, since
             // no drain runs them.
             .chatTitle,
             .chatHistoryCompaction,
             .transcriptFormatting,
             .podcastSpeakerIdentification,
             .podcastYouTubeMatching,
             .slideFrameClassification,
             .slideCitationExtraction,
             .paperFigureUnderstanding,
             .lecturePaperDiscovery,
             .meetingPaperDiscovery,
             .paperReferenceExtraction,
             .articleLinkDiscovery,
             .journalArticleMatching,
             .citationResolution,
             .embedding,
             .sourceClassification,
             .paperMetadata,
             .paperNarrationPreparation,
             .paperTextToSpeechPreparation,
             .automaticAudioFiltering,
             .paperAttachmentCheck,
             .paperBrowserAgent,
             .articleMetadata,
             .articleChromeFiltering,
             .bookAuthor,
             .duplicateDetection,
             .bookChapterSplitting,
             // Runs inside Add Book on a scanned book, as the chapter split does.
             .scannedPageProofreading,
             .meetingSessionDetails,
             .meetingActionItems,
             .lectureNoteMatching,
             .courseOrdering,
             .courseMetadata,
             // Runs after a playlist import as well as from the course menu.
             .courseLectureNaming,
             .sourceIdeaExtraction,
             // Card Drafting runs when the learner presses Make Cards as well
             // as in the background: the ledger counts
             // both, and only the background runs pause at the cap
             // (`CardDraftingSpendGate`).
             .cardDrafting,
             // Checks the wording of every card drafted or saved.
             .cardWordingCheck,
             // Runs on its own when a notebook made without a name first
             // holds something, like a chat's title but outside the chat.
             .notebookNaming,
             // Runs on its own after a paste into a Page, like a chat's title:
             // counted against the cap, never paused, since no drain runs it.
             .pastedLineJoining,
             // Runs on its own while the Map is open: a cluster's summary when
             // its cards change, and the view's caption as the learner pans.
             .mapSummaries:
            return true
        }
    }

    static var backgroundWorkTaskIDs: [String] {
        allCases.filter(\.isBackgroundWork).map(\.rawValue).sorted()
    }
}

// MARK: - Needed or optional

/// What a line in AI Usage › Activity is for, so the learner can tell the
/// spend they may turn off from the spend the library cannot do without
/// (product owner, 2026-10-07: "some things are not really optional; differentiate
/// between the optional nice to haves and the ones that aren't").
enum AIUsageTaskNeed: Sendable, Equatable {
    /// The library needs it to import, find or read what the learner added:
    /// search embeddings, a paper's metadata, a duplicate check. Never offered
    /// a switch; turning it off would leave a source half-made.
    case needed
    /// A nice to have that runs on its own. It gets a switch in Settings,
    /// and the Activity row links to it.
    case optional
    /// The learner started it (chat, a picture they asked for, a report). It
    /// stops by not being asked for.
    case requested

    /// The need of a ledger task key. Keys that are not an `AITask` (the
    /// pictures and recordings the ledger also holds) are listed here.
    static func of(taskKey: String) -> AIUsageTaskNeed {
        if let task = AITask(rawValue: taskKey) { return task.usageNeed }
        switch taskKey {
        case "notebook_cover", "course_quiz_picture", "course_quiz_icon", "meeting_icon",
             "meeting_transcription":
            return .optional
        case "author_normalization", "content_cleanup",
             "podcast_transcription", "course_video_transcription":
            return .needed
        default:
            return .requested
        }
    }
}

extension AITask {
    /// Exhaustive on purpose: a new task has to be classified here to compile.
    /// Only tasks that run without the learner asking are `.needed` or
    /// `.optional`; the rest are `.requested`.
    var usageNeed: AIUsageTaskNeed {
        switch self {
        case .chat, .reviewGrading, .mobileReview, .mobileVoiceAgent,
             .deepResearch, .sourceDiscovery, .notebookNotesMerge, .cohortSessionPlan,
             .courseCurriculumPlan, .courseLessonWriting, .explainerWriting,
             .audioOverviewWriting, .reportWriting, .mnemonicReadingWriting, .walkthroughWriting,
             .walkthroughAnimation, .lectureQuizWriting, .courseQuizWriting,
             .courseTextbookReadings, .canvasAsk, .canvasVoice, .atlasWriting, .sourceLevels, .cardGoDeeper,
             .cardAnswerCheck,
             // Asked for from a source's menu or an MCP tool.
             .paperFigureUnderstanding, .lecturePaperDiscovery, .meetingPaperDiscovery,
             .articleLinkDiscovery, .slideCitationExtraction:
            return .requested
        case .embedding, .sourceClassification, .paperMetadata, .articleMetadata,
             .articleChromeFiltering, .bookAuthor, .bookChapterSplitting, .scannedPageProofreading,
             .duplicateDetection,
             .paperAttachmentCheck, .paperBrowserAgent, .citationResolution, .meetingSessionDetails,
             .lectureNoteMatching, .courseOrdering, .courseMetadata, .courseLectureNaming,
             .slideFrameClassification, .chatTitle, .chatHistoryCompaction,
             // The gate a card passes before it is saved: without it no
             // drafted card is kept, so it is part of drafting, not a switch
             // of its own.
             .cardWordingCheck,
             // Without it a paste from a PDF stays one paragraph per printed
             // line, which is a paste half made, not a nice to have.
             .pastedLineJoining:
            return .needed
        // Review questions are written ahead of time for the sources a review
        // is likely to be about; nothing else writes them, and a review
        // without them still runs.
        case .realtimeReviewPreparation,
             .transcriptFormatting, .podcastSpeakerIdentification, .podcastYouTubeMatching,
             .journalArticleMatching, .paperNarrationPreparation, .paperTextToSpeechPreparation,
             .automaticAudioFiltering, .meetingActionItems, .sourceIdeaExtraction, .cardDrafting,
             .notebookNaming, .mapSummaries,
             // Runs when a paper is added, for the references the free read left
             // without a link, as well as from Find Cited Papers: its Activity
             // row has a switch (`PaperReferenceModelReading`).
             .paperReferenceExtraction:
            return .optional
        }
    }
}

// MARK: - Daily cap

/// The learner's ceiling on what background AI may spend in one local day.
///
/// Off unless the learner sets it; there is no default amount. Spend is read
/// from the local `ai_usage_events` ledger, so a call paid by the learner's own
/// OpenRouter key counts exactly as one paid by the ForeverLM balance.
enum BackgroundAIDailyCap {
    /// Synced: the cap is the learner's decision about their account's spend,
    /// and every Mac on the account reads the same ledger.
    static let preferenceKey = Prefs.Spend.backgroundDailyCapUSD.name
    /// The largest cap chat may set. Billing's own monthly limit tops out at
    /// $250 (`set_billing_settings`), and a daily background ceiling above the
    /// largest monthly one the account offers limits nothing.
    static let maximumUSD: Double = 250

    static let didChange = Notification.Name("foreverlmBackgroundAIDailyCapDidChange")

    /// The cap in dollars, or nil when it is off.
    static func capUSD(defaults: UserDefaults = .standard) -> Double? {
        guard let number = defaults.object(forKey: Prefs.Spend.backgroundDailyCapUSD.name) as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value > 0 else { return nil }
        return value
    }

    /// nil or zero turns the cap off.
    static func setCapUSD(_ value: Double?) {
        if let value, value.isFinite, value > 0 {
            Preferences.set(min(value, maximumUSD), for: Prefs.Spend.backgroundDailyCapUSD)
        } else {
            Preferences.reset(Prefs.Spend.backgroundDailyCapUSD)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// The local calendar day containing `date`, midnight to midnight, so a
    /// day that gains or loses an hour to daylight saving is still one day.
    static func localDay(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        guard let day = calendar.dateInterval(of: .day, for: date) else {
            preconditionFailure("The calendar has no day containing \(date)")
        }
        return day
    }

    enum Status: Equatable, Sendable {
        case off
        case under(spentUSD: Double, capUSD: Double)
        case reached(spentUSD: Double, capUSD: Double)

        var isReached: Bool {
            if case .reached = self { return true }
            return false
        }
    }

    static func status(spentUSD: Double, capUSD: Double?) -> Status {
        guard let capUSD else { return .off }
        return spentUSD >= capUSD
            ? .reached(spentUSD: spentUSD, capUSD: capUSD)
            : .under(spentUSD: spentUSD, capUSD: capUSD)
    }
}

/// Answers whether the background drains may spend right now, and says once a
/// day when they may not.
actor BackgroundAIBudget {
    struct Check: Sendable {
        let status: BackgroundAIDailyCap.Status
        let day: DateInterval
        /// True the first time the cap is found reached on this local day,
        /// on this Mac: the caller tells the learner then and never again.
        let isFirstNoticeToday: Bool
        /// The ledger could not be read while a cap was set. The drains stay
        /// paused rather than spend past a cap nobody can check.
        let errorMessage: String?

        var allowsBackgroundSpend: Bool { !status.isReached && errorMessage == nil }
    }

    private let spendReader: @Sendable (DateInterval) async throws -> Double
    private let defaults: UserDefaults
    private let calendar: Calendar
    private let logger = Logger(subsystem: "com.foreverlm", category: "BackgroundAIBudget")

    init(
        storage: StorageService,
        defaults: UserDefaults = .standard,
        calendar: Calendar = .current
    ) {
        self.init(
            defaults: defaults,
            calendar: calendar,
            spendReader: { day in
                try await storage.backgroundAISpendUSD(from: day.start, to: day.end)
            }
        )
    }

    init(
        defaults: UserDefaults,
        calendar: Calendar,
        spendReader: @escaping @Sendable (DateInterval) async throws -> Double
    ) {
        self.defaults = defaults
        self.calendar = calendar
        self.spendReader = spendReader
    }

    func check(now: Date = Date()) async -> Check {
        let day = BackgroundAIDailyCap.localDay(containing: now, calendar: calendar)
        guard let cap = BackgroundAIDailyCap.capUSD(defaults: defaults) else {
            return Check(status: .off, day: day, isFirstNoticeToday: false, errorMessage: nil)
        }
        let spent: Double
        do {
            spent = try await spendReader(day)
        } catch {
            logger.error("Background AI cap could not read the ledger: \(error.localizedDescription, privacy: .public)")
            return Check(
                status: .under(spentUSD: 0, capUSD: cap),
                day: day,
                isFirstNoticeToday: false,
                errorMessage: error.localizedDescription
            )
        }
        let status = BackgroundAIDailyCap.status(spentUSD: spent, capUSD: cap)
        var firstNotice = false
        if status.isReached {
            let key = DailyNote.dayKey(for: now, calendar: calendar)
            if defaults.string(forKey: Prefs.Spend.backgroundDailyCapNoticeDay.name) != key {
                defaults.set(key, forKey: Prefs.Spend.backgroundDailyCapNoticeDay.name)
                firstNotice = true
            }
        }
        return Check(status: status, day: day, isFirstNoticeToday: firstNotice, errorMessage: nil)
    }
}

// MARK: - Bulk re-queues wait for the learner

/// A paid background queue a bulk re-queue can land in, with the task that
/// prices its work.
enum BackgroundAIBulkQueue: String, CaseIterable, Sendable {
    case canonicalCleanup = "canonical_cleanup"
    case listenPreparation = "listen_preparation"
    case podcastTranscriptCleanup = "podcast_transcript_cleanup"

    /// More sources than this in one re-queue wait for the learner. It is
    /// the largest batch one learner action puts into these queues: `add_sources`
    /// takes at most 50 items a call (`MCPToolRegistry.maxBatchSourceItems`),
    /// and every other import adds sources one at a time or by the folder the
    /// learner chose. A re-queue past it is library-wide work nobody asked for
    /// source by source, which is exactly what cleaner v19 was.
    static let learnerDecisionThreshold = 50

    /// "Recent" for the estimate: the last 30 days of the ledger, the default
    /// range of AI Usage, so the estimate prices from the history
    /// the learner sees there.
    static let costSampleWindowDays = 30

    var tableName: String {
        switch self {
        case .canonicalCleanup: "canonical_content_cleanup_queue"
        case .listenPreparation: "source_listenable_content_queue"
        case .podcastTranscriptCleanup: "podcast_transcript_cleanup_queue"
        }
    }

    /// The task whose ledger rows price one source of this queue.
    var task: AITask {
        switch self {
        case .canonicalCleanup: .paperNarrationPreparation
        case .listenPreparation: .paperTextToSpeechPreparation
        case .podcastTranscriptCleanup: .transcriptFormatting
        }
    }

    var displayName: String {
        switch self {
        case .canonicalCleanup: "Source clean-up"
        case .listenPreparation: "Listen preparation"
        case .podcastTranscriptCleanup: "Podcast ad clean-up"
        }
    }
}

/// What a bulk re-queue knows about which sources its change reaches. A bump
/// has to say one or the other: there is no default.
enum BulkRequeueAffectedSources: Sendable, Equatable {
    /// The change cannot tell affected sources from the rest; `because` says
    /// why, so an omission reads as a decision in the code.
    case unknown(because: String)
    /// An SQL condition true for the sources the change affects. It is read
    /// with `s` bound to the `sources` row and `pp` / `ap` left-joined to
    /// `paper_content_preparations` / `article_content_preparations`.
    case matching(sql: String)
}

enum BackgroundAIBulkDecision: String, CaseIterable, Sendable {
    case runAll = "run_all"
    case runAffected = "run_affected"
    case skip
}

/// What recent ledger history says one source of a task costs.
struct BackgroundAICostSample: Equatable, Sendable {
    /// Sources whose every call in the window carries a cost.
    var pricedSourceCount: Int
    var pricedTotalUSD: Double
    /// Sources with at least one call the ledger could not price. Left out of
    /// the average rather than counted as free.
    var unpricedSourceCount: Int

    static let empty = BackgroundAICostSample(pricedSourceCount: 0, pricedTotalUSD: 0, unpricedSourceCount: 0)

    /// nil when the ledger has no priced history for the task: the cost is
    /// unknown, not zero and not a guess.
    var perSourceUSD: Double? {
        guard pricedSourceCount > 0 else { return nil }
        return pricedTotalUSD / Double(pricedSourceCount)
    }

    func estimatedUSD(forSourceCount count: Int) -> Double? {
        guard count > 0 else { return 0 }
        return perSourceUSD.map { $0 * Double(count) }
    }
}

/// One bulk re-queue waiting for the learner.
struct BackgroundAIBulkJob: Identifiable, Equatable, Sendable {
    let id: String
    let queue: BackgroundAIBulkQueue
    let reason: String
    let createdAt: Date
    /// Sources still held in the queue for this decision.
    let heldSourceCount: Int
    /// Of those, how many the change affects; nil when it cannot say.
    let affectedSourceCount: Int?
    let costSample: BackgroundAICostSample

    var estimatedUSD: Double? { costSample.estimatedUSD(forSourceCount: heldSourceCount) }
    var estimatedAffectedUSD: Double? {
        affectedSourceCount.flatMap { costSample.estimatedUSD(forSourceCount: $0) }
    }
    var canLimitToAffected: Bool { affectedSourceCount != nil }

    /// "about $41.20", or "cost unknown" when the ledger has no history.
    static func costText(_ usd: Double?) -> String {
        guard let usd else { return "cost unknown" }
        return "about " + usd.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    var headline: String {
        let noun = heldSourceCount == 1 ? "source" : "sources"
        return "\(queue.displayName): \(heldSourceCount.formatted()) \(noun), \(Self.costText(estimatedUSD))"
    }
}

extension Notification.Name {
    /// A bulk re-queue was held, decided, or emptied.
    static let backgroundAIBulkJobsDidChange = Notification.Name("foreverlmBackgroundAIBulkJobsDidChange")
}
