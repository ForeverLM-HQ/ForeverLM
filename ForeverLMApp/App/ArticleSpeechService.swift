#if os(macOS)
import AVFoundation
import CryptoKit
import Foundation
import MediaPlayer
import os
import PDFKit
import SwiftUI
import WebKit

let articleSpeechLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
    category: "ArticleSpeech"
)

private struct SyncedArticleAudioContext {
    let sourceID: String
    let title: String
    let subtitle: String?
    let sourceType: String
    let sourceURL: String
    let provider: MacArticleSpeechMode
    let model: String
    let voice: String
    let voiceLabel: String
    let contentSignature: String
    let sourceContentSignature: String?
    let narrationPreparationSignature: String?
    let totalCharacters: Int
    let sourceText: String
    let fileExtension: String
    let createdAt: Date
}

private struct PreparedListenablePlayback: Sendable {
    let content: String
    let sourceContentSignature: String?
    let narrationPreparationSignature: String?
}

/// A chunk generation that keeps running after playback moved to another
/// source. Owns the surviving chunk tasks and enough context to schedule the
/// chunks that were never started, so the whole source still ends up in the
/// synced audio store with a manifest. Only an explicit stop of that source
/// (stop/cancel buttons, cache deletion) or a permanent failure ends it early.
private struct DetachedAudioGeneration {
    let context: SyncedArticleAudioContext
    let chunkTexts: [String]
    var tasks: [Int: Task<Data, Error>]
    var completedChunks: [SyncedArticleAudioManifest.Chunk]
    var failedChunkCount: Int
    var hasScheduledRemainingChunks: Bool
    /// The failed parts have been asked for once more, after everything else
    /// had landed, so a part the provider answered empty does not leave a
    /// narration one part short.
    var hasRetriedFailedChunks = false
}

struct ArticleSpeechChunkProgress: Equatable {
    var completedChunks: Int
    let totalChunks: Int
    /// Parts that failed and are not (yet) made: the status list says so
    /// instead of sitting at 98% without a word.
    var failedChunks = 0

    var fractionCompleted: Double {
        guard totalChunks > 0 else { return 0 }
        return Double(completedChunks) / Double(totalChunks)
    }

    var percentCompleted: Int {
        Int((fractionCompleted * 100).rounded())
    }

    var isComplete: Bool {
        totalChunks > 0 && completedChunks >= totalChunks
    }
}

enum ArticleSpeechGenerationRequestResult: Equatable {
    case started
    case alreadyGenerating
    case alreadyReady
    case cancelled
    case failed(String)
    /// Headless only: the narration would bill the provider and the caller has
    /// not approved that spend yet. Nothing was started or charged.
    case needsCostApproval(ArticleSpeechCostEstimate, model: String)
    /// Headless only: no available voice speaks the source's language, and the
    /// caller did not allow generating it anyway. Nothing was started.
    case unsupportedLanguage(String)
}

/// How `generateAudio` settles the two questions the sidebar's Generate Audio
/// puts in front of the listener — "how much will this cost" and "will the
/// audio be usable at all".
enum ArticleSpeechGenerationInteraction: Equatable, Sendable {
    /// The listener is at the Mac: both questions are modal alerts.
    case interactive
    /// An assistant asked over MCP, or another caller with no one at the Mac.
    /// Nothing modal may appear; an unanswered question comes back as a result
    /// instead, and the caller answers it by asking again with the flag set.
    case headless(costApproved: Bool, allowsUnsupportedLanguage: Bool)
}

/// How a background (generate-only) run for one source ended.
enum ArticleSpeechBackgroundGenerationOutcome: Equatable, Sendable {
    /// Every chunk landed and the synced manifest was written.
    case ready
    /// A chunk failed permanently, the provider rejected the run, or the
    /// finished audio could not be persisted.
    case failed(String)
    /// Stopped by the listener or a caller before it finished.
    case cancelled
}

/// A book, as text-to-speech needs to see it: the title to name in a price
/// confirmation and every chapter listening will walk through. Studio owns
/// the ordering and group metadata, so it supplies this rather than the speech
/// service reconstructing it from storage.
struct ArticleSpeechBookScope {
    let title: String
    let chapters: [StudioArticle]
    /// The book's cover, for the Now Playing artwork of any of its chapters.
    var coverPath: String? = nil
}

/// A text-to-speech language mismatch worth putting in front of the listener,
/// shown in the player rather than as an error: listening still works, it just
/// is not being done by the voice they picked.
struct ArticleSpeechLanguageNotice: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A voice that speaks the source's language was substituted.
        case adjusted
        /// Nothing available speaks it; the narration will be mispronounced.
        case unsupported
    }

    let sourceID: String
    let kind: Kind
    let message: String

    var id: String { sourceID }
}

@MainActor
final class ArticleSpeechService: NSObject, ObservableObject {
    /// Single app-wide instance. Text-to-speech is inherently exclusive (one voice,
    /// one Now Playing entry, one set of media-key handlers), so every reader
    /// surface shares this object. Per-surface instances used to each register
    /// MPRemoteCommandCenter targets that were never removed, and two surfaces
    /// could narrate simultaneously.
    static let shared = ArticleSpeechService()
    private let activityStorage = StorageService()
    /// When listening time was last booked to the ledger, and for which source.
    private var lastListeningTickAt: Date?
    private var lastListeningTickSourceID: String?
    /// Studio's view of the book a chapter belongs to, keyed by group ID. Set
    /// once Studio has loaded; nil before that, which only costs the price
    /// confirmation its whole-book line.
    var bookScopeProvider: (@MainActor (String) -> ArticleSpeechBookScope?)?
    /// The title of the notebook an audio overview is homed on, by the
    /// overview's Artifact id, for its Now Playing line ("Audio overview ·
    /// Mitochondria"). Set once Studio has loaded; nil before, which only
    /// leaves the notebook's name off.
    var audioOverviewNotebookTitleProvider: (@MainActor (String) -> String?)?
    /// Told once per background generation when it stops being tracked, with
    /// the source id and how it ended. `backgroundGenerationSourceIDs` says
    /// only that a run is over; a batch caller (the MCP audio queue) also needs
    /// to know whether the audio is there.
    var backgroundGenerationDidEnd: (@MainActor (String, ArticleSpeechBackgroundGenerationOutcome) -> Void)?
    /// The book whose remaining generation cost the listener already approved.
    /// Listening auto-advances from chapter to chapter, so one approval covers
    /// the book it was quoted for instead of prompting at every chapter break.
    private var approvedBookGeneration: BookGenerationApproval?

    @Published private(set) var activeArticleID: String?
    @Published private(set) var preparingArticleID: String?
    @Published private(set) var nowPlayingTitle: String?
    /// The picture beside the title in the system's Now Playing surfaces, and
    /// the source it was rendered for, so a chapter that ended before its cover
    /// arrived never wears the next one's.
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var nowPlayingArtworkSourceID: String?
    @Published private(set) var nowPlayingSubtitle: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var isPaused = false
    @Published private(set) var isLoading = false
    /// Human-readable work currently blocking the first audible word. Published
    /// synchronously from `startTextToSpeech` so every Listen entry point visibly
    /// acknowledges the click before source, iCloud, or cache work begins.
    @Published private(set) var preparationStatus: String?
    @Published private(set) var audioGenerationProgress: ArticleSpeechChunkProgress?
    /// Sources whose cloud/local-file audio is being completed without owning
    /// playback. Source rows observe this lightweight ID set; chunk data and
    /// file work remain entirely outside SwiftUI state.
    @Published private(set) var backgroundGenerationSourceIDs: Set<String> = []
    /// How many parts of each background narration have landed, by source id,
    /// from the run starting until it ends (`noteBackgroundGenerationEnded`),
    /// so a Reader and a source row can say how far a narration being made
    /// has got. Changes once a part, not once a playback tick.
    @Published private(set) var backgroundGenerationProgress: [String: ArticleSpeechChunkProgress] = [:]
    /// What a narration being made is doing before its first part lands, by
    /// source id: "Cleaning up the text for easier listening", "Choosing the
    /// voice". The product owner, 2026-10-08: a bare "Making narration" for minutes told
    /// him nothing. Cleared when the run ends or never starts.
    @Published private(set) var narrationStages: [String: String] = [:]
    /// The narrations Listen is making (`listen(to:)`), until each ends.
    @Published private(set) var narrationRequests = SourceNarrationRequests()
    /// The source whose narration Listen made and that has just landed: the
    /// control still showing that source takes it (`consumeMadeNarration`)
    /// and starts playing. Left alone when no control is on screen for the
    /// source, because the learner has gone elsewhere and a narration that
    /// keeps going while they are away does not speak up when it lands.
    @Published private(set) var madeNarrationSourceID: String?
    @Published var errorMessage: String? {
        // Any new message (or dismissal) invalidates the provider-switch hint;
        // the two provider-rejection paths re-set it right after assigning.
        didSet { errorSuggestsProviderSwitch = false }
    }
    /// True when the current `errorMessage` is a provider rejection (bad key,
    /// exhausted credits, billing) — the error alert then offers switching to
    /// another voice provider as the primary way out.
    @Published var errorSuggestsProviderSwitch = false
    /// What the language check did to the current source's narration, when it
    /// did anything. Dismissible: it explains a decision that has already been
    /// made, so it must never sit in the player's way.
    @Published var languageNotice: ArticleSpeechLanguageNotice?
    /// The on-device voice the source being narrated needs, when its language
    /// is not the one the listener's selected voice speaks. Never written back
    /// to Settings — it belongs to this source, not to the preference.
    private var activeAppleVoiceIdentifier: String?
    /// Languages the listener has already been warned about and chosen to
    /// generate anyway, keyed by the book (or lone source) the answer covers.
    /// Listening auto-advances through a book's chapters, and one answer has to
    /// cover the book it was asked about.
    private var acknowledgedUnnarratableLanguages: [String: String] = [:]
    @Published var mode: MacArticleSpeechMode {
        didSet {
            guard !isAdoptingStoredConfiguration else { return }
            configurationEpoch += 1
            MacArticleSpeechSettings.provider = mode
            if mode != .apple {
                selectedVoice = MacArticleSpeechSettings.voice(for: mode)
            }
        }
    }
    @Published var selectedVoice: String {
        didSet {
            guard !isAdoptingStoredConfiguration else { return }
            configurationEpoch += 1
            MacArticleSpeechSettings.setVoice(selectedVoice, for: mode)
        }
    }
    @Published var appleVoiceIdentifier: String? {
        didSet {
            MacArticleSpeechSettings.appleVoiceIdentifier = appleVoiceIdentifier
        }
    }
    @Published var speed: Double {
        didSet {
            MacArticleSpeechSpeed.stored = speed
            applyAudioPlaybackRate()
        }
    }
    private nonisolated static let playbackLeadChunkLimit = 1_000
    private static let minimumResumeInterval: TimeInterval = 3
    private nonisolated static let completionResumeThreshold: TimeInterval = 10
    /// Positions are saved at most this often while audio plays. This is a
    /// throttle, not a debounce: the 250ms playback ticker must never keep
    /// resetting the timer, or a crash mid-listen loses the session's progress.
    private static let playbackPositionSaveInterval: TimeInterval = 5
    // Orpheus TTS models (canopylabs/orpheus-*) generate a bounded number of audio
    // tokens per request, so any input longer than roughly a sentence gets truncated
    // or drifts into unrelated speech. Keep their chunks tiny regardless of provider.
    private nonisolated static let orpheusChunkLimit = 180
    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var audioChunks: [String] = []
    private var audioChunkIndex = 0
    private var prefetchTasks: [Int: Task<Data, Error>] = [:]
    /// Generations still running after their source stopped playing, keyed by
    /// the generation ID each chunk task captured. Chunk callbacks route here
    /// when the ID no longer matches `audioGenerationID`.
    private var detachedGenerations: [UUID: DetachedAudioGeneration] = [:]
    private var playbackTask: Task<Void, Never>?
    private var audioGenerationID = UUID()
    /// Invalidates source/preflight work when Stop or another Listen request
    /// takes ownership before that asynchronous work returns.
    private var preparationRequestID = UUID()
    /// Chunks the generation the listener is playing still has to produce.
    /// While this is nonzero, detached generations park their next request so
    /// the foreground generation gets the provider's full throughput — see
    /// `waitWhileYieldingToForegroundGeneration`.
    private var foregroundGenerationChunksRemaining = 0
    /// Monotonic counter bumped by stop/finish/seek. Async continuations capture
    /// the epoch before awaiting and bail if it moved — this is the staleness
    /// guard for playback state. Task cancellation alone cannot be trusted here:
    /// jumpToChunk historically cancelled `playbackTask` while running *inside*
    /// it, self-cancelling and silently killing every cross-chunk seek and resume.
    private var playbackEpoch = 0
    private var syncedAudioContext: SyncedArticleAudioContext?
    private var syncedChunkURLs: [URL] = []
    /// The next chunk's player, created and buffered while the current chunk is
    /// still playing so the handoff at the chunk boundary is effectively gapless.
    private var preloadedNextPlayer: (index: Int, player: AVAudioPlayer)?
    /// Manifest entries for chunks that finished generating this session,
    /// accumulated on the main actor as each prefetch completes.
    private var completedSyncedChunks: [SyncedArticleAudioManifest.Chunk] = []
    private var failedGenerationChunkCount = 0
    @Published private(set) var playbackCurrentTime: TimeInterval = 0
    @Published private(set) var playbackDuration: TimeInterval = 0
    /// Set when a source's narration finished playing to the end. Reader hosts
    /// observe this to auto-advance to the next chapter of a book.
    @Published private(set) var finishedListeningArticleID: String?
    private var chunkDurations: [Int: TimeInterval] = [:]
    private var currentlyPlayingChunkIndex = 0
    private var playbackTimeUpdateTask: Task<Void, Never>?
    private var chunkDurationLoadTask: Task<Void, Never>?
    private var lastPlaybackPositionSaveAt: Date?
    /// When the account copy of the position was last published. The file
    /// beside the audio is written every few seconds; the CloudKit record only
    /// on this interval while playing, and at once on pause or stop.
    private var lastAccountPositionSaveAt: Date?
    private var pendingResumeGlobalTime: TimeInterval?
    private var pendingResumeAppleCharacterOffset: Int?
    private var activeNarrationSignature: String?
    private var appleSpeechBaseCharacterOffset = 0
    private var appleSpeechCharacterOffset = 0
    @Published private(set) var sleepTimerRemaining: TimeInterval?
    private var sleepTimerTask: Task<Void, Never>?
    private var sleepTimerEndsAt: Date?
    private var hasStartedPlayback = false
    private var highestReadyChunkIndex = -1

    /// Set while a stored snapshot is being copied into the published
    /// properties, so their `didSet` observers neither write the same value
    /// straight back to storage nor count the copy as a user edit.
    private var isAdoptingStoredConfiguration = false
    /// Bumped by every configuration write that did not come from adopting
    /// storage. `adoptStoredConfiguration` compares it against the value it
    /// captured before reading, so a snapshot delayed by a slow Keychain can
    /// never overwrite a choice the listener made in the meantime.
    private var configurationEpoch = 0
    private var storedConfigurationTask: Task<Void, Never>?
    private var speechDirectoryObserver: NSObjectProtocol?

    override init() {
        // Deliberately reads no Keychain-backed setting. `shared` is created
        // during SwiftUI view construction — StudioAudiobookPlayerHost sits in
        // StudioView's overlay chain, and SourceReaderPanel, ArticleReaderView
        // and SourceReaderWindow each hold it as a stored `@ObservedObject` —
        // so anything blocking here blocks a view body. Reading the provider
        // used to reach `SecItemCopyMatching`, which raises a system
        // authorization dialog for an ACL-protected vault item and never
        // returns until it is answered: the app hung with no window painted,
        // and an app-hosted test run (which can never answer it) timed out
        // before the test runner connected. Seed the compile-time product
        // defaults, then adopt what is stored off the main thread.
        //
        // The two speech settings that live purely in UserDefaults stay eager;
        // they cannot block, and reading them here keeps the Apple-voice and
        // speed controls from flickering through a default on launch.
        mode = MacArticleSpeechSettings.defaultProvider
        selectedVoice = MacArticleSpeechSettings.defaultOpenRouterVoice
        appleVoiceIdentifier = MacArticleSpeechSettings.appleVoiceIdentifier
        speed = MacArticleSpeechSpeed.stored
        super.init()
        synthesizer.delegate = self
        installRemoteCommandHandlers()
        loadStoredConfiguration()
        installSpeechDirectoryRepair()
    }

    /// A read of OpenRouter's speech list that drops the stored pick repairs
    /// it at once, as Settings and the next Listen would; the next use says
    /// what changed (`MacArticleSpeechSettings.repairAfterDirectoryRead`).
    private func installSpeechDirectoryRepair() {
        speechDirectoryObserver = NotificationCenter.default.addObserver(
            forName: .openRouterAudioDirectoryDidChange,
            object: nil,
            queue: .main
        ) { notification in
            guard notification.object as? String == OpenRouterAudioDirectory.Kind.speech.rawValue else { return }
            Task.detached(priority: .utility) {
                MacArticleSpeechSettings.repairAfterDirectoryRead()
            }
        }
    }

    /// Reads the stored provider and voice off the main thread and adopts them.
    /// Playback re-reads storage of its own accord in `beginTextToSpeech`, so what
    /// this really buys is chrome — the mini player, the Settings pickers and
    /// `selectedVoiceLabel` — showing the real selection before anyone listens.
    private func loadStoredConfiguration() {
        guard storedConfigurationTask == nil else { return }
        let epoch = configurationEpoch
        storedConfigurationTask = Task.detached(priority: .utility) { [weak self] in
            let stored = MacArticleSpeechConfiguration.loadStored()
            await self?.adoptStoredConfiguration(stored, capturedAtEpoch: epoch)
        }
    }

    private func adoptStoredConfiguration(
        _ stored: MacArticleSpeechConfiguration,
        capturedAtEpoch epoch: Int
    ) {
        guard configurationEpoch == epoch else { return }
        apply(stored)
    }

    /// Copies a stored snapshot into the published properties without letting
    /// the observers persist it again.
    private func apply(_ configuration: MacArticleSpeechConfiguration) {
        isAdoptingStoredConfiguration = true
        mode = configuration.provider
        selectedVoice = configuration.voice
        isAdoptingStoredConfiguration = false
    }

    /// Schedules `@Published` mutations on the next main-actor turn so they do not run during an in-flight SwiftUI view update.
    private func deferPublishedUpdate(_ update: @escaping () -> Void) {
        Task { @MainActor in
            update()
        }
    }

    var isVisible: Bool {
        activeArticleID != nil || preparingArticleID != nil
    }

    /// The source this service is narrating, or about to.
    var narratingArticleID: String? {
        activeArticleID ?? preparingArticleID
    }

    /// Readers display one source at a time while this service is shared app-wide,
    /// so a reader asks about the source it shows rather than reading `isVisible`.
    func isNarrating(_ articleID: String) -> Bool {
        activeArticleID == articleID || preparingArticleID == articleID
    }

    var canSeek: Bool {
        mode.isCloudProvider && isPlaying && playbackDuration > 0
    }

    var isGeneratingAudio: Bool {
        guard mode.isCloudProvider else { return false }
        return audioGenerationProgress.map { !$0.isComplete } ?? false
    }

    var isWaitingForFirstChunk: Bool {
        isGeneratingAudio && isLoading && !hasStartedPlayback
    }

    var isLoadingCachedPlayback: Bool {
        isLoading && !hasStartedPlayback && !isGeneratingAudio
    }

    var isBufferingNextChunk: Bool {
        isLoading && hasStartedPlayback
    }

    var playbackFraction: Double {
        guard playbackDuration > 0 else { return 0 }
        return min(max(playbackCurrentTime / playbackDuration, 0), 1)
    }

    /// During progressive generation the total duration is extrapolated from
    /// the chunks that are already available. Reader chrome must not present
    /// that moving estimate as an exact finished-audio duration.
    var isPlaybackDurationEstimated: Bool {
        playbackDuration > 0 && chunkDurations.count < totalChunkCount
    }

    /// The model narrating right now. This is the source's resolved model, not
    /// the stored preference: a source in another language is read by a voice
    /// that speaks it, and every retry and continuation request has to keep
    /// naming that same model.
    private var activeSpeechModel: String {
        syncedAudioContext?.model ?? MacArticleSpeechSettings.model(for: mode)
    }

    /// Human-facing name for the exact model captured by this generation.
    /// Reading Settings directly here would make the progress row lie if the
    /// listener changes their preference while existing chunks are in flight.
    var activeSpeechModelLabel: String {
        ArticleSpeechCatalog.model(id: activeSpeechModel)?.name ?? activeSpeechModel
    }

    private var activeSpeechVoice: String {
        syncedAudioContext?.voice ?? selectedVoice
    }

    var selectedVoiceLabel: String {
        switch mode {
        case .openRouter, .groq, .openAI, .togetherAI, .elevenLabs, .xai, .gemini, .localQwen3:
            return providerVoiceLabel(provider: mode, voice: selectedVoice)
        case .apple: return MacArticleSpeechSettings.appleVoiceName(identifier: appleVoiceIdentifier)
        }
    }

    /// UI entry point. It publishes preparation state in the button's action
    /// turn, then performs the asynchronous source and TTS work. Keeping that
    /// first state transition out of an unstructured Task prevents a Listen
    /// click from looking ignored while the task waits to be scheduled.
    func startTextToSpeech(article: StudioArticle) {
        guard let requestID = beginTextToSpeech(article: article) else { return }
        Task { [weak self] in
            await self?.continueTextToSpeech(article: article, requestID: requestID)
        }
    }

    /// Async compatibility for automatic chapter continuation and existing
    /// non-UI callers. UI controls should call `startTextToSpeech` directly.
    func textToSpeech(article: StudioArticle) async {
        guard let requestID = beginTextToSpeech(article: article) else { return }
        await continueTextToSpeech(article: article, requestID: requestID)
    }

    private func beginTextToSpeech(article: StudioArticle) -> UUID? {
        refreshConfiguration()
        // Switching sources must not throw away in-flight generation work:
        // detach it so the previous source keeps generating in the background.
        stop(detachingGeneration: true)
        // A fresh generation for this source supersedes any background one
        // still running for it. Cancel without deleting partial audio — the
        // new generation reuses those chunks via the per-request cache.
        cancelBackgroundGeneration(sourceID: article.id, cleaningUpPartialAudio: false)
        finishedListeningArticleID = nil
        languageNotice = nil
        activeAppleVoiceIdentifier = nil
        // An approved book price covers that book only. Leaving it — to another
        // book, or to any single source — makes the next paid generation ask
        // again.
        if approvedBookGeneration?.groupID != article.parentGroup {
            approvedBookGeneration = nil
        }

        guard ArticleSpeechContent.canAttemptRead(article) else {
            if article.sourceType == .podcast {
                errorMessage = "Podcasts already have native audio, so ForeverLM does not generate text-to-speech speech for them."
            } else if article.isYouTubeURL {
                errorMessage = "YouTube videos already have native audio, so ForeverLM does not generate text-to-speech speech for them."
            } else if article.sourceType == .meeting, ArticleSpeechContent.isOriginalAudioSource(article) {
                errorMessage = "This meeting's recording plays in the reader, so ForeverLM does not generate text-to-speech speech for it."
            } else {
                errorMessage = "This source does not have readable text yet."
            }
            ArticleSpeechDiagnostics.append(
                "LISTEN_REJECTED source=\(article.id) type=\(article.sourceType.rawValue)"
            )
            return nil
        }

        let requestID = UUID()
        preparationRequestID = requestID
        preparingArticleID = article.id
        nowPlayingTitle = article.title
        nowPlayingSubtitle = displaySubtitle(for: article)
        loadNowPlayingArtwork(for: article)
        isLoading = true
        preparationStatus = "Preparing text…"
        errorMessage = nil
        // Every Listen click leaves a trace here. A click that ends in silence
        // is the one failure this service cannot explain after the fact, so the
        // request, and each way it can end early, is written to the log.
        ArticleSpeechDiagnostics.append(
            "LISTEN_REQUESTED source=\(article.id) type=\(article.sourceType.rawValue)"
        )
        return requestID
    }

    private func continueTextToSpeech(article: StudioArticle, requestID: UUID) async {
        // The synchronous entry point may run inside a SwiftUI button update.
        // Yield before subsequent publications while preserving the immediate
        // preparation state it already set.
        await Task.yield()

        let content = await ArticleSpeechContent.text(for: article)

        guard preparationRequestID == requestID,
              preparingArticleID == article.id else {
            ArticleSpeechDiagnostics.append("LISTEN_SUPERSEDED stage=text source=\(article.id)")
            return
        }

        guard let content else {
            preparingArticleID = nil
            isLoading = false
            preparationStatus = nil
            nowPlayingTitle = nil
            nowPlayingSubtitle = nil
            errorMessage = "This source does not have readable text yet."
            ArticleSpeechDiagnostics.append("LISTEN_FAILED stage=text source=\(article.id) no readable text")
            return
        }

        let isPaper = article.sourceType == .paper
        preparationStatus = article.sourceType == .book
            ? "Preparing audio…"
            : "Preparing narration…"
        let listenablePlayback: PreparedListenablePlayback
        do {
            listenablePlayback = try await prepareListenablePlayback(
                for: article,
                initialContent: content,
                learnerAsked: true
            )
        } catch {
            guard preparationRequestID == requestID,
                  preparingArticleID == article.id else {
                ArticleSpeechDiagnostics.append("LISTEN_SUPERSEDED stage=narration source=\(article.id)")
                return
            }
            preparingArticleID = nil
            isLoading = false
            preparationStatus = nil
            nowPlayingTitle = nil
            nowPlayingSubtitle = nil
            let kind = isPaper ? "paper" : "source"
            errorMessage = "Could not prepare this \(kind) for reading aloud: \(error.localizedDescription)"
            articleSpeechLogger.error(
                "Listen preparation failed for \(article.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            ArticleSpeechDiagnostics.append(
                "LISTEN_FAILED stage=narration source=\(article.id) \(error.localizedDescription)"
            )
            return
        }

        guard preparationRequestID == requestID,
              preparingArticleID == article.id else {
            ArticleSpeechDiagnostics.append("LISTEN_SUPERSEDED stage=prepared source=\(article.id)")
            return
        }
        preparationStatus = "Preparing audio…"

        // Which voice reads this source is settled before it is chunked: a
        // source in another language can need a different model, and chunk
        // sizes, cache keys, and the price quoted below all follow the model
        // that will actually synthesize it.
        let provider = mode
        let sourceID = article.id
        let selection = await resolveSpeechSelection(
            provider: provider,
            content: listenablePlayback.content,
            sourceID: sourceID
        )

        guard preparationRequestID == requestID,
              preparingArticleID == article.id else {
            ArticleSpeechDiagnostics.append("LISTEN_SUPERSEDED stage=language source=\(article.id)")
            return
        }

        // Generation 2: narration another device made is laid into the working folder, chunks and all,
        // before the cache is probed, or the audio the account already owns would be made again.
        await SyncedArticleAudioStore.bringReplicaNarration(sourceID: sourceID)
        // Narration cleanup, chunking, and cache probing all run over large
        // strings and stat files in the iCloud-synced Audio folder — strictly
        // off the main actor. The main actor only publishes the result.
        let accountPosition = await accountListenPosition(sourceID: sourceID)
        let preparation = await Task.detached(priority: .userInitiated) {
            Self.preparePlayback(
                sourceID: sourceID,
                content: listenablePlayback.content,
                provider: provider,
                model: selection.model,
                voice: selection.voice,
                isPaper: isPaper,
                sourceContentSignature: listenablePlayback.sourceContentSignature,
                narrationPreparationSignature: listenablePlayback.narrationPreparationSignature,
                accountPosition: accountPosition
            )
        }.value

        guard preparationRequestID == requestID,
              preparingArticleID == article.id else {
            ArticleSpeechDiagnostics.append("LISTEN_SUPERSEDED stage=chunking source=\(article.id)")
            return
        }

        // A language no available voice speaks is asked about before the price
        // is: an unlistenable narration is not worth any amount of money.
        let willGenerate = provider.isCloudProvider
            && preparation.manifest == nil
            && preparation.uncachedCharacterCount > 0
        guard acceptLanguageResolution(selection, article: article, isBillable: willGenerate) else {
            languageNotice = nil
            preparingArticleID = nil
            isLoading = false
            preparationStatus = nil
            nowPlayingTitle = nil
            nowPlayingSubtitle = nil
            return
        }
        activeAppleVoiceIdentifier = selection.appleVoiceIdentifier
        // The alert above spins a nested run loop; another source may have
        // taken over preparation while it was up.
        guard preparationRequestID == requestID,
              preparingArticleID == article.id else { return }

        // Paid generation is a choice, not a surprise: before any billable TTS
        // request goes out, show what it will roughly cost and let the user
        // back out. Fully cached sources and free providers skip the ask.
        //
        // A book is priced as a book. Listening auto-advances into the next
        // chapter, so starting chapter one commits to the whole book, and
        // quoting only the chapter in hand would understate that by orders of
        // magnitude. The listener approves the book once and is not asked again
        // at every chapter break.
        if willGenerate, MacArticleSpeechSettings.confirmsCostBeforeListening(for: preparation.model) {
            let approval = (article.sourceType == .book ? article.parentGroup : nil).map {
                BookGenerationApproval(
                    groupID: $0,
                    signature: "\(preparation.model)\u{1f}\(preparation.voice)"
                )
            }
            if approval == nil || approval != approvedBookGeneration {
                let book = await bookGenerationEstimate(
                    for: article,
                    provider: provider,
                    model: preparation.model,
                    narrationCharacters: preparation.narrationText.count
                )
                guard preparationRequestID == requestID,
                      preparingArticleID == article.id else { return }
                let approved = Self.confirmGenerationCost(
                    provider: provider,
                    model: preparation.model,
                    uncachedCharacters: preparation.uncachedCharacterCount,
                    book: book
                )
                // The modal alert spins a nested run loop; re-check that no other
                // source took over playback preparation while it was up.
                guard preparationRequestID == requestID,
                      preparingArticleID == article.id else { return }
                guard approved else {
                    preparingArticleID = nil
                    isLoading = false
                    preparationStatus = nil
                    nowPlayingTitle = nil
                    nowPlayingSubtitle = nil
                    return
                }
                approvedBookGeneration = approval
            }
        }

        preparingArticleID = nil
        preparationStatus = nil

        startPlayback(article: article, preparation: preparation, provider: provider)
    }

    /// Generates and syncs a source's complete text-to-speech audio without
    /// starting playback or interrupting whatever the listener is hearing.
    ///
    /// `.interactive` asks the listener about cost and language with alerts, as
    /// the sidebar action always has. `.headless` never blocks on a dialog: a
    /// billable run the caller has not approved returns `.needsCostApproval`
    /// with the exact quote, and a source in a language no voice speaks
    /// returns `.unsupportedLanguage` unless the caller allowed it.
    func generateAudio(
        article: StudioArticle,
        interaction: ArticleSpeechGenerationInteraction = .interactive
    ) async -> ArticleSpeechGenerationRequestResult {
        let result = await generateAudioRun(article: article, interaction: interaction)
        // A run that started shows its progress from here; any other end
        // leaves no stage behind.
        if case .started = result {} else { narrationStages[article.id] = nil }
        return result
    }

    private func setNarrationStage(_ stage: String, for sourceID: String) {
        // A source already generating keeps its own run's line.
        guard !backgroundGenerationSourceIDs.contains(sourceID) else { return }
        narrationStages[sourceID] = stage
    }

    private func generateAudioRun(
        article: StudioArticle,
        interaction: ArticleSpeechGenerationInteraction
    ) async -> ArticleSpeechGenerationRequestResult {
        guard ArticleSpeechContent.canAttemptRead(article) else {
            return .failed("This source does not have readable text yet.")
        }

        let provider = MacArticleSpeechSettings.provider
        guard provider.isCloudProvider else {
            return .failed("Choose a file-generating voice in Text-to-Speech settings first.")
        }

        if backgroundGenerationSourceIDs.contains(article.id)
            || activeArticleID == article.id
            || preparingArticleID == article.id {
            return .alreadyGenerating
        }

        setNarrationStage("Reading the text", for: article.id)
        guard let content = await ArticleSpeechContent.text(for: article) else {
            return .failed("This source does not have readable text yet.")
        }

        setNarrationStage(
            TextToSpeechPreparationPolicy.usesAIPreparation(
                sourceType: article.sourceType.rawValue,
                url: article.url
            ) ? "Cleaning up the text for easier listening" : "Preparing the text",
            for: article.id
        )
        let listenablePlayback: PreparedListenablePlayback
        do {
            listenablePlayback = try await prepareListenablePlayback(
                for: article,
                initialContent: content,
                learnerAsked: interaction == .interactive
            )
        } catch {
            return .failed("Could not prepare this source for audio: \(error.localizedDescription)")
        }

        let sourceID = article.id
        let isPaper = article.sourceType == .paper
        setNarrationStage("Choosing the voice", for: sourceID)
        let selection = await resolveSpeechSelection(
            provider: provider,
            content: listenablePlayback.content,
            sourceID: sourceID
        )
        setNarrationStage("Splitting the text into parts", for: sourceID)
        await SyncedArticleAudioStore.bringReplicaNarration(sourceID: sourceID)
        let accountPosition = await accountListenPosition(sourceID: sourceID)
        let preparation = await Task.detached(priority: .userInitiated) {
            Self.preparePlayback(
                sourceID: sourceID,
                content: listenablePlayback.content,
                provider: provider,
                model: selection.model,
                voice: selection.voice,
                isPaper: isPaper,
                sourceContentSignature: listenablePlayback.sourceContentSignature,
                narrationPreparationSignature: listenablePlayback.narrationPreparationSignature,
                accountPosition: accountPosition
            )
        }.value

        guard preparation.speakableText != nil, !preparation.chunks.isEmpty else {
            return .failed("This source does not have readable text yet.")
        }

        if preparation.manifest != nil {
            await Task.detached(priority: .utility) {
                ArticleSpeechAudioCache.markCached(articleID: article.id)
            }.value
            return .alreadyReady
        }

        let isBillable = preparation.uncachedCharacterCount > 0
        switch interaction {
        case .interactive:
            guard acceptLanguageResolution(
                selection,
                article: article,
                isBillable: isBillable,
                showsNotice: false
            ) else { return .cancelled }

            if isBillable,
               MacArticleSpeechSettings.confirmsCostBeforeListening(for: preparation.model) {
                setNarrationStage("Waiting for your OK on the price", for: article.id)
                let approved = Self.confirmGenerationCost(
                    provider: provider,
                    model: preparation.model,
                    uncachedCharacters: preparation.uncachedCharacterCount
                )
                guard approved else { return .cancelled }
            }
        case .headless(let costApproved, let allowsUnsupportedLanguage):
            if isBillable,
               selection.unnarratableLanguage != nil,
               let message = selection.notice?.message,
               !allowsUnsupportedLanguage {
                return .unsupportedLanguage(message)
            }
            // The in-app "don't ask again for this model" switch is the
            // listener's answer for their own clicks. A caller with no one at
            // the Mac gets the quote every time and answers it explicitly.
            if isBillable, !costApproved {
                return .needsCostApproval(
                    ArticleSpeechCostEstimate(
                        characters: preparation.uncachedCharacterCount,
                        provider: provider.rawValue,
                        model: preparation.model
                    ),
                    model: preparation.model
                )
            }
        }

        // Re-check after the confirmation's nested run loop: a reader or a
        // second menu action may have started this source while it was open.
        if backgroundGenerationSourceIDs.contains(article.id)
            || activeArticleID == article.id
            || preparingArticleID == article.id {
            return .alreadyGenerating
        }

        let context = SyncedArticleAudioContext(
            sourceID: article.id,
            title: article.title,
            subtitle: displaySubtitle(for: article),
            sourceType: article.sourceType.rawValue,
            sourceURL: article.url,
            provider: provider,
            model: preparation.model,
            voice: preparation.voice,
            voiceLabel: providerVoiceLabel(
                provider: provider,
                voice: preparation.voice,
                model: preparation.model
            ),
            contentSignature: preparation.contentSignature,
            sourceContentSignature: preparation.sourceContentSignature,
            narrationPreparationSignature: preparation.narrationPreparationSignature,
            totalCharacters: preparation.narrationText.count,
            sourceText: preparation.narrationText,
            fileExtension: Self.syncedAudioFileExtension(provider: provider, model: preparation.model),
            createdAt: Date()
        )

        // One background writer per source. Existing partial chunks remain on
        // disk and in the request cache, so a restart reuses them without a
        // second provider charge.
        cancelBackgroundGeneration(sourceID: article.id, cleaningUpPartialAudio: false)
        let generationID = UUID()
        detachedGenerations[generationID] = DetachedAudioGeneration(
            context: context,
            chunkTexts: preparation.chunks,
            tasks: [:],
            completedChunks: [],
            failedChunkCount: 0,
            hasScheduledRemainingChunks: true
        )
        backgroundGenerationSourceIDs.insert(article.id)
        backgroundGenerationProgress[article.id] = ArticleSpeechChunkProgress(
            completedChunks: 0,
            totalChunks: preparation.chunks.count
        )
        narrationStages[article.id] = "Generating audio, \(preparation.chunks.count) part\(preparation.chunks.count == 1 ? "" : "s")"
        fillMissingDetachedChunkTasks(generationID: generationID)
        articleSpeechLogger.info(
            "Background text-to-speech generation started: \(preparation.chunks.count) chunks for \(article.id)"
        )
        ArticleSpeechDiagnostics.append(
            "BACKGROUND_GENERATION_STARTED source=\(article.id) chunks=\(preparation.chunks.count)"
        )
        return .started
    }

    // MARK: - Narration: play at once, keep it as it is made

    /// The Listen entry point. Listen on a source with no narration asks the
    /// price and starts playing as soon as the opening parts land, while the
    /// rest are made ahead of the playhead and kept (product owner, 2026-10-08: a
    /// narration that took 30 minutes to make before a word played "has to be
    /// sub one minute"; this reverses 2026-10-04's make-then-play, which a
    /// model that takes a minute a part made unusable). Listen on one that
    /// has it plays it. A run already being made in the background (the
    /// source's Generate Audio, an assistant's queue) is waited for.
    ///
    /// The Reader's control knows whether the narration is there and says so
    /// in `hasNarration`; a caller that does not (a context menu) leaves it
    /// nil and the check runs off the main actor first.
    func listen(to article: StudioArticle, hasNarration: Bool? = nil) {
        guard let hasNarration else {
            let sourceID = article.id
            Task { [weak self] in
                let found = await Task.detached(priority: .userInitiated) {
                    ArticleSpeechAudioCache.hasCachedAudio(sourceID: sourceID)
                }.value
                self?.listen(to: article, hasNarration: found)
            }
            return
        }
        let state = SourceNarrationState(
            hasNarration: hasNarration,
            isMaking: isMakingNarration(article.id),
            progress: backgroundGenerationProgress[article.id]
        )
        switch state.listenAction() {
        case .play:
            startTextToSpeech(article: article)
        case .wait:
            break
        }
    }

    /// Whether a narration for the source is being made, however it was asked
    /// for: Listen, the source's Generate Audio, an assistant's
    /// `generate_source_audio`, or automatic audio. The queue's own entries
    /// (`SourceAudioGenerationQueue.activeSourceIDs`) are the caller's to add,
    /// since a source waiting its turn there has no run yet.
    func isMakingNarration(_ sourceID: String) -> Bool {
        narrationRequests.contains(sourceID) || backgroundGenerationSourceIDs.contains(sourceID)
    }

    /// Stop on a narration being made: the run, the source's place in the
    /// assistant queue, and the request that would have played it.
    func stopMakingNarration(sourceID: String) {
        narrationRequests.cancel(sourceID)
        if SourceAudioGenerationQueue.shared.activeSourceIDs.contains(sourceID) {
            _ = SourceAudioGenerationQueue.shared.cancel(sourceIDs: [sourceID])
        }
        // A stop keeps what finished: starting again asks for only the parts
        // that are missing, never the hundred that landed.
        cancelBackgroundGeneration(sourceID: sourceID, cleaningUpPartialAudio: false)
    }

    /// The control showing the source takes the finished narration, once, and
    /// plays it.
    func consumeMadeNarration(sourceID: String) -> Bool {
        guard madeNarrationSourceID == sourceID else { return false }
        madeNarrationSourceID = nil
        return true
    }

    /// Every background run ends here: the queue's hook, the progress the
    /// Reader and the rows show, and a narration Listen made.
    private func noteBackgroundGenerationEnded(
        sourceID: String,
        outcome: ArticleSpeechBackgroundGenerationOutcome
    ) {
        backgroundGenerationProgress[sourceID] = nil
        narrationStages[sourceID] = nil
        if narrationRequests.end(sourceID, outcome: outcome) {
            madeNarrationSourceID = sourceID
        }
        backgroundGenerationDidEnd?(sourceID, outcome)
    }

    /// Builds a source-bound narration snapshot. A cleanup or CloudKit update
    /// can legitimately replace canonical text while preparation is in flight;
    /// refresh once and prepare the new snapshot instead of surfacing that race
    /// as a text-to-speech error. A second change still fails loudly and remains
    /// queued for the durable background preparer.
    ///
    /// `learnerAsked` is true for Listen and the sidebar's Generate Audio: a
    /// Text-to-Speech Preparation the learner stopped in the background-work
    /// list still runs for a source they asked to hear.
    private func prepareListenablePlayback(
        for article: StudioArticle,
        initialContent: String,
        learnerAsked: Bool
    ) async throws -> PreparedListenablePlayback {
        var content = initialContent

        for attempt in 0..<2 {
            do {
                return try await prepareListenablePlaybackSnapshot(
                    for: article,
                    content: content,
                    learnerAsked: learnerAsked
                )
            } catch KnowledgeStoreError.sourceContentChanged where attempt == 0 {
                guard let refreshed = await ArticleSpeechContent.persistedText(sourceID: article.id) else {
                    throw KnowledgeStoreError.sourceContentChanged
                }
                content = refreshed
            }
        }

        throw KnowledgeStoreError.sourceContentChanged
    }

    private func prepareListenablePlaybackSnapshot(
        for article: StudioArticle,
        content: String,
        learnerAsked: Bool
    ) async throws -> PreparedListenablePlayback {
        let usesAITextToSpeechPreparation = TextToSpeechPreparationPolicy.usesAIPreparation(
            sourceType: article.sourceType.rawValue,
            url: article.url
        )
        let sourceHash = await Task.detached(priority: .utility) {
            PaperContentPreparationService.sha256(
                content.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }.value
        let storedListenable = await ArticleSpeechContent.listenableContent(sourceID: article.id)
        let currentPreparationSignature = usesAITextToSpeechPreparation
            ? await PaperTextToSpeechPreparationService.currentPreparationSignature()
            : nil
        let validStoredListenable: StoredSourceListenableContent? = storedListenable.flatMap { stored in
            guard stored.metadata.sourceSHA256 == sourceHash else { return nil }
            if usesAITextToSpeechPreparation {
                guard let currentSignature = currentPreparationSignature,
                      stored.metadata.preparationSignature == currentSignature else { return nil }
            }
            return stored
        }

        if let validStoredListenable {
            return PreparedListenablePlayback(
                content: validStoredListenable.text,
                sourceContentSignature: usesAITextToSpeechPreparation ? sourceHash : nil,
                narrationPreparationSignature: usesAITextToSpeechPreparation
                    ? validStoredListenable.metadata.preparationSignature
                    : nil
            )
        }

        let candidate = SourceListenableContentCandidate(
            sourceID: article.id,
            title: article.title,
            sourceType: article.sourceType,
            canonicalText: content,
            sourceSHA256: sourceHash
        )
        if usesAITextToSpeechPreparation {
            let source = AIUsageSource(
                id: article.id,
                sourceType: article.sourceType,
                title: article.title
            )
            let preparedSource = try await Task.detached(priority: .userInitiated) {
                try await AIUsageAttribution.$learnerAsked.withValue(learnerAsked) {
                    try await PaperTextToSpeechPreparationService().prepare(
                        source: source,
                        canonicalText: content
                    )
                }
            }.value
            try await ArticleSpeechContent.saveListenableContent(
                candidate: candidate,
                text: preparedSource.text,
                preparationSignature: preparedSource.preparationSignature
            )
            return PreparedListenablePlayback(
                content: preparedSource.text,
                sourceContentSignature: preparedSource.sourceContentSignature,
                narrationPreparationSignature: preparedSource.preparationSignature
            )
        }

        let preparedText = await Task.detached(priority: .userInitiated) {
            MacArticleSpeechText.narrationText(from: content)
        }.value
        try await ArticleSpeechContent.saveListenableContent(
            candidate: candidate,
            text: preparedText,
            preparationSignature: nil
        )
        return PreparedListenablePlayback(
            content: preparedText,
            sourceContentSignature: nil,
            narrationPreparationSignature: nil
        )
    }

    /// One book approved for paid generation, remembered so auto-advance does
    /// not re-ask at every chapter. The signature pins the quote to the model
    /// and voice it was given for: changing either reprices the book and
    /// invalidates its cached audio, so the listener is asked again.
    private struct BookGenerationApproval: Equatable {
        let groupID: String
        let signature: String
    }

    /// Renders the Now Playing picture for the source about to play: the book's
    /// cover for a chapter, a paper's first page, an article's artwork, or the
    /// ForeverLM mark. Off-main, and applied only if this source is still the
    /// one playing when the image is ready.
    private func loadNowPlayingArtwork(for article: StudioArticle) {
        if nowPlayingArtworkSourceID != article.id {
            nowPlayingArtwork = nil
        }
        nowPlayingArtworkSourceID = article.id
        var coverPath: String?
        if article.sourceType == .book, let groupID = article.parentGroup {
            coverPath = bookScopeProvider?(groupID)?.coverPath
        }
        let cover = coverPath
        Task { [weak self] in
            let image = await Task.detached(priority: .utility) {
                await NowPlayingArtwork.image(for: article, bookCoverPath: cover)
            }.value
            guard let self, self.nowPlayingArtworkSourceID == article.id else { return }
            self.nowPlayingArtwork = NowPlayingArtwork.artwork(from: image)
            self.updateNowPlayingInfo()
        }
    }

    /// The line under the title in Now Playing and in the synced audio
    /// manifest: the book a chapter belongs to, otherwise the author or the
    /// site. A book's `parentGroup` is its stable group id — a bare UUID for an
    /// imported book — so the title is resolved through Studio's book scope,
    /// and when Studio has not supplied one the line falls back to the author
    /// rather than ever showing the id.
    func displaySubtitle(for article: StudioArticle) -> String? {
        if let overviewID = GeneratedAudioOverview.artifactID(ofCarrier: article) {
            let kind = AudioOverviewScript.kindLabel
            guard let notebook = audioOverviewNotebookTitleProvider?(overviewID)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !notebook.isEmpty else { return kind }
            return "\(kind) · \(notebook)"
        }
        if article.sourceType == .book, let groupID = article.parentGroup, groupID != article.id {
            if let title = bookScopeProvider?(groupID)?.title.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty, title != groupID {
                return title
            }
        } else if article.sourceType != .book, let group = article.parentGroup, !group.isEmpty {
            return group
        }
        return article.displayAuthor ?? article.displayDomain
    }

    /// The book behind a chapter, priced as the listener will actually hear it.
    private struct BookGenerationEstimate {
        let groupID: String
        let title: String
        /// Chapters beyond the one being started that still have no cached
        /// audio — what auto-advance goes on to generate and be billed for.
        let remainingChapters: ArticleSpeechCostEstimate
    }

    /// Prices the rest of the book behind the chapter about to start. Nil for a
    /// source that is not a book chapter, when Studio has not supplied the
    /// book's chapters, or when every other chapter is already cached — the
    /// confirmation then quotes the single source, which is the whole charge.
    private func bookGenerationEstimate(
        for article: StudioArticle,
        provider: MacArticleSpeechMode,
        model: String,
        narrationCharacters: Int
    ) async -> BookGenerationEstimate? {
        guard article.sourceType == .book,
              let groupID = article.parentGroup,
              let scope = bookScopeProvider?(groupID) else { return nil }
        let others = scope.chapters
            .filter { $0.id != article.id && ArticleSpeechContent.canAttemptRead($0) }
        guard !others.isEmpty else { return nil }
        let chapterIDs = others.map(\.id)
        let wordCounts = Dictionary(
            others.compactMap { chapter in chapter.wordCount.map { (chapter.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        // This chapter's own narration is the best ratio available for the
        // chapters whose narration has not been prepared yet.
        let charactersPerWord = ArticleSpeechCostEstimate.charactersPerWord(
            narrationCharacters: narrationCharacters,
            wordCount: article.wordCount
        )

        // Cache probing stats files and the length lookup reads across the whole
        // book, so both run off the main actor — and the lengths come from
        // `LENGTH(content)`, never by pulling a chapter's text into memory.
        let storage = activityStorage
        let pending = await Task.detached(priority: .userInitiated) { () async -> (chapters: Int, characters: Int) in
            let uncached = chapterIDs.filter {
                !ArticleSpeechAudioCache.hasCachedAudio(sourceID: $0)
            }
            guard !uncached.isEmpty else { return (0, 0) }
            // A chapter whose text has not been extracted into `source_content`
            // yet has no stored length, so its word count stands in. One with
            // neither is still counted as a chapter but adds no characters,
            // which understates the book rather than inventing a number.
            let lengths = await storage.sourceContentLengths(for: uncached)
            let characters = uncached.reduce(0) { total, id in
                if let length = lengths[id] { return total + length }
                guard let words = wordCounts[id] else { return total }
                return total + Int((Double(words) * charactersPerWord).rounded())
            }
            return (uncached.count, characters)
        }.value
        guard pending.chapters > 0, pending.characters > 0 else { return nil }

        return BookGenerationEstimate(
            groupID: groupID,
            title: scope.title,
            remainingChapters: ArticleSpeechCostEstimate(
                characters: pending.characters,
                sourceCount: pending.chapters,
                provider: provider.rawValue,
                model: model
            )
        )
    }

    // MARK: - Whole book

    /// What generating the rest of a book would take: the chapters that still
    /// need audio, in reading order, and one price for all of them.
    ///
    /// Listening already auto-advances chapter to chapter and quotes the book
    /// once, so the price is a book-level idea here too. The point of asking it
    /// up front is that the answer is one dialog rather than one per chapter.
    struct AudiobookPlan: Equatable {
        let groupID: String
        let title: String
        /// Readable chapters with no cached audio yet, in reading order.
        let chapters: [StudioArticle]
        /// Chapters already narrated, so a mostly-done book can say so.
        let readyChapterCount: Int
        let estimate: ArticleSpeechCostEstimate
        /// The model the quote was priced against.
        let model: String
        /// Whether generating this costs anything. An exact zero-price model
        /// still generates; it just does not need an answer first.
        var isBillable: Bool { (estimate.usd ?? 1) > 0 }
    }

    /// Prices a whole book without preparing any of its narration.
    ///
    /// Deliberately cheaper than the per-chapter path: it never extracts,
    /// chunks, or normalizes text. Stored content lengths stand in for
    /// narration length, with word counts behind them for a chapter whose text
    /// has not been extracted yet — the same approximation the existing
    /// whole-book line in the listening confirmation uses, and the same
    /// off-main lookups, because a forty-chapter book must not touch the main
    /// actor to answer this.
    func audiobookPlan(forBookGroup groupID: String) async -> AudiobookPlan? {
        guard let scope = bookScopeProvider?(groupID) else { return nil }
        let provider = MacArticleSpeechSettings.provider
        guard provider.isCloudProvider else { return nil }
        let model = MacArticleSpeechSettings.model(for: provider)
        let readable = scope.chapters.filter { ArticleSpeechContent.canAttemptRead($0) }
        guard !readable.isEmpty else { return nil }

        let wordCounts = Dictionary(
            readable.compactMap { chapter in chapter.wordCount.map { (chapter.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let ids = readable.map(\.id)
        let storage = activityStorage
        let pending = await Task.detached(priority: .userInitiated) { () async -> (uncached: Set<String>, characters: Int) in
            let uncached = ids.filter { !ArticleSpeechAudioCache.hasCachedAudio(sourceID: $0) }
            guard !uncached.isEmpty else { return ([], 0) }
            let lengths = await storage.sourceContentLengths(for: uncached)
            let characters = uncached.reduce(0) { total, id in
                if let length = lengths[id] { return total + length }
                guard let words = wordCounts[id] else { return total }
                return total + Int((Double(words) * ArticleSpeechCostEstimate.fallbackCharactersPerWord).rounded())
            }
            return (Set(uncached), characters)
        }.value

        let chapters = readable.filter { pending.uncached.contains($0.id) }
        guard !chapters.isEmpty else { return nil }
        return AudiobookPlan(
            groupID: groupID,
            title: scope.title,
            chapters: chapters,
            readyChapterCount: readable.count - chapters.count,
            estimate: ArticleSpeechCostEstimate(
                characters: pending.characters,
                sourceCount: chapters.count,
                provider: provider.rawValue,
                model: model
            ),
            model: model
        )
    }

    /// Asks once for the whole book. The suppression switch is deliberately
    /// absent: "don't ask again" belongs to a single chapter's small charge,
    /// not to an answer that authorizes a book-sized one.
    static func confirmAudiobookGeneration(_ plan: AudiobookPlan) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Generate the audiobook for \u{201C}\(plan.title)\u{201D}?"
        var lines = [plan.model, plan.estimate.summary(countingSourcesAs: "chapter")]
        if plan.readyChapterCount > 0 {
            let noun = plan.readyChapterCount == 1 ? "chapter" : "chapters"
            lines.append("\(plan.readyChapterCount) \(noun) already narrated, and not charged again.")
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Generate")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Upfront price check before billable text-to-speech generation. Returns true
    /// when the user chooses to proceed. Checking "Don't ask again for this
    /// model" suppresses only this model, across all of its voices, and persists
    /// only on confirm — cancelling must never silently authorize future spend.
    private static func confirmGenerationCost(
        provider: MacArticleSpeechMode,
        model: String,
        uncachedCharacters: Int,
        book: BookGenerationEstimate? = nil
    ) -> Bool {
        let source = ArticleSpeechCostEstimate(
            characters: uncachedCharacters,
            provider: provider.rawValue,
            model: model
        )

        let alert = NSAlert()
        if let book {
            let wholeBook = source.adding(book.remainingChapters)
            alert.messageText = "Generate text-to-speech audio for \u{201C}\(book.title)\u{201D}?"
            alert.informativeText = """
                \(model)
                This chapter · \(source.summary)
                Whole book · \(wholeBook.summary(countingSourcesAs: "chapter"))
                """
        } else {
            alert.messageText = "Generate text-to-speech audio?"
            alert.informativeText = "\(model) · \(source.summary)"
        }
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again for this model"

        let confirmed = alert.runModal() == .alertFirstButtonReturn
        if confirmed, alert.suppressionButton?.state == .on {
            MacArticleSpeechSettings.setConfirmsCostBeforeListening(false, for: model)
        }
        return confirmed
    }

    // MARK: - Source language

    /// The model, voice, and on-device voice this source's own language calls
    /// for, plus what the listener should be told about the choice.
    private struct ResolvedSpeechSelection {
        let model: String
        let voice: String
        /// An `AVSpeechSynthesisVoice` identifier for on-device narration, when
        /// the source needs one the listener has not selected.
        let appleVoiceIdentifier: String?
        let notice: ArticleSpeechLanguageNotice?
        /// The language the notice is about, so one answer can cover a whole
        /// book instead of every chapter in it.
        let unnarratableLanguage: String?
    }

    /// Decides what will read this source aloud.
    ///
    /// The listener picks one voice in Settings and then imports a paper in
    /// German. Almost every catalog voice is English-only and will happily
    /// generate — and bill for — German words read with English phonemes, which
    /// is unlistenable and indistinguishable from a broken model. So the
    /// language is recognized from the narration itself, off-main, before
    /// anything is chunked, cached, or charged: if the catalog has a voice that
    /// speaks it, this source quietly gets that voice; if it does not, the
    /// listener is told before the money goes out.
    private func resolveSpeechSelection(
        provider: MacArticleSpeechMode,
        content: String,
        sourceID: String
    ) async -> ResolvedSpeechSelection {
        var model = MacArticleSpeechSettings.model(for: provider)
        var voice = MacArticleSpeechSettings.voice(for: provider)

        if provider == .apple {
            let selected = appleVoiceIdentifier
            let resolved = await Task.detached(priority: .userInitiated) {
                Self.resolveAppleSpeechLanguage(content: content, selectedVoiceIdentifier: selected)
            }.value
            return ResolvedSpeechSelection(
                model: model,
                voice: resolved.identifier ?? voice,
                appleVoiceIdentifier: resolved.identifier,
                notice: resolved.notice.map {
                    ArticleSpeechLanguageNotice(sourceID: sourceID, kind: $0.kind, message: $0.message)
                },
                unnarratableLanguage: resolved.unnarratableLanguage
            )
        }

        // The catalog only describes the managed OpenRouter rail. A stored
        // retired provider is already rejected by `configurationError`; never
        // answer it by silently moving the listener onto OpenRouter.
        guard provider == .openRouter else {
            return ResolvedSpeechSelection(
                model: model,
                voice: voice,
                appleVoiceIdentifier: nil,
                notice: nil,
                unnarratableLanguage: nil
            )
        }

        // The catalog is OpenRouter's speech list; a Mac that has never read
        // it knows only the models this build records, and the language fit,
        // the chunk sizes and the price below all read the selected model's
        // entry. Returns at once when a read exists. A stored pick the list
        // stopped offering is repaired as Settings repairs it, and the
        // listener is told once; a model the list does not offer otherwise
        // is left as it is — the speech request refuses it by name — rather
        // than swapped for another model on account of its language.
        await OpenRouterAudioDirectory.prepare(.speech)
        let repair = await Task.detached(priority: .userInitiated) {
            MacArticleSpeechSettings.repairSelectionForUse()
        }.value
        var repairNotice: ArticleSpeechLanguageNotice?
        if let repair {
            model = repair.newModel
            voice = repair.newVoice
            apply(MacArticleSpeechConfiguration(provider: provider, voice: voice))
            repairNotice = ArticleSpeechLanguageNotice(sourceID: sourceID, kind: .adjusted, message: repair.message)
            ArticleSpeechDiagnostics.append(
                "SELECTION_REPAIRED source=\(sourceID) old=\(repair.oldModel) model=\(model) voice=\(voice)"
            )
        }
        // A pick applied while its test could not finish, or whose pass has
        // run out, is tested now, beside this request.
        AIModelQualification.testSpeechWhenDue(model: model, voice: voice)
        guard ArticleSpeechCatalog.model(id: model) != nil else {
            return ResolvedSpeechSelection(
                model: model,
                voice: voice,
                appleVoiceIdentifier: nil,
                notice: repairNotice,
                unnarratableLanguage: nil
            )
        }

        let resolution = await Task.detached(priority: .userInitiated) { [model, voice] in
            ArticleSpeechLanguageResolution.resolve(text: content, model: model, voice: voice)
        }.value
        let notice: ArticleSpeechLanguageNotice? = resolution.message.map { message in
            ArticleSpeechLanguageNotice(
                sourceID: sourceID,
                kind: resolution.changesSelection ? .adjusted : .unsupported,
                message: [repairNotice?.message, message].compactMap { $0 }.joined(separator: " ")
            )
        } ?? repairNotice
        if let language = resolution.languageCode {
            ArticleSpeechDiagnostics.append(
                "LANGUAGE source=\(sourceID) detected=\(language) model=\(resolution.model) voice=\(resolution.voice)"
            )
        }
        return ResolvedSpeechSelection(
            model: resolution.model,
            voice: resolution.voice,
            appleVoiceIdentifier: nil,
            notice: notice,
            unnarratableLanguage: resolution.outcome == .unsupported ? resolution.languageCode : nil
        )
    }

    private struct AppleSpeechLanguageResolution: Sendable {
        let identifier: String?
        let notice: (kind: ArticleSpeechLanguageNotice.Kind, message: String)?
        let unnarratableLanguage: String?
    }

    /// On-device narration has its own catalog: whatever voices macOS has
    /// installed. Enumerating them and recognizing the language both walk real
    /// data — blocking work, never on the main actor.
    private nonisolated static func resolveAppleSpeechLanguage(
        content: String,
        selectedVoiceIdentifier: String?
    ) -> AppleSpeechLanguageResolution {
        guard let code = ArticleSpeechLanguage.detect(in: content) else {
            return AppleSpeechLanguageResolution(identifier: nil, notice: nil, unnarratableLanguage: nil)
        }
        let selected = selectedVoiceIdentifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
        let selectedLanguage = selected.flatMap { ArticleSpeechLanguage.primaryCode($0.language) }
            ?? ArticleSpeechLanguage.primaryCode(AVSpeechSynthesisVoice.currentLanguageCode())
        if selectedLanguage == code {
            return AppleSpeechLanguageResolution(identifier: nil, notice: nil, unnarratableLanguage: nil)
        }

        let name = ArticleSpeechLanguage.displayName(for: code)
        let installed = AVSpeechSynthesisVoice.speechVoices()
            .filter { ArticleSpeechLanguage.primaryCode($0.language) == code }
        guard let best = installed.max(by: { $0.quality.rawValue < $1.quality.rawValue }) else {
            return AppleSpeechLanguageResolution(
                identifier: nil,
                notice: (
                    .unsupported,
                    """
                    This source is in \(name), and macOS has no \(name) voice installed. \
                    Add one in System Settings › Accessibility › Spoken Content, or the \
                    narration will be read with the wrong pronunciation.
                    """
                ),
                unnarratableLanguage: code
            )
        }
        return AppleSpeechLanguageResolution(
            identifier: best.identifier,
            notice: (
                .adjusted,
                "This source is in \(name). Reading it with the on-device \(best.name) voice."
            ),
            unnarratableLanguage: nil
        )
    }

    /// Last stop before paying to generate narration no voice can pronounce.
    /// Unlike the price check this is not suppressible: the cost dialog answers
    /// "how much", and this answers "will the audio be usable at all".
    private static func confirmUnnarratableLanguage(message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Generate audio in a language no voice speaks?"
        alert.informativeText = message
        alert.addButton(withTitle: "Generate Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Presents the language decision for `article` and returns false when the
    /// listener backed out. One answer covers the book a chapter belongs to.
    ///
    /// `showsNotice` is false for background generation: the notice belongs to
    /// the player, and a source generating quietly in the background must not
    /// replace the one the listener is hearing right now.
    private func acceptLanguageResolution(
        _ resolution: ResolvedSpeechSelection,
        article: StudioArticle,
        isBillable: Bool,
        showsNotice: Bool = true
    ) -> Bool {
        if showsNotice { languageNotice = resolution.notice }
        guard let language = resolution.unnarratableLanguage,
              let message = resolution.notice?.message,
              isBillable else { return true }

        let scope = article.parentGroup ?? article.id
        if acknowledgedUnnarratableLanguages[scope] == language { return true }
        guard Self.confirmUnnarratableLanguage(message: message) else { return false }
        acknowledgedUnnarratableLanguages[scope] = language
        return true
    }

    /// Everything the main actor needs to start playback, computed off-main.
    private struct PlaybackPreparation {
        let narrationText: String
        let contentSignature: String
        let sourceContentSignature: String?
        let narrationPreparationSignature: String?
        let speakableText: String?
        let chunks: [String]
        let manifest: SyncedArticleAudioManifest?
        let manifestChunkTexts: [String]?
        let hasCompleteRequestCache: Bool
        /// Characters of narration that have no cached audio yet and would be
        /// billed to the cloud provider if generation starts. 0 for free
        /// providers and fully cached sources.
        let uncachedCharacterCount: Int
        let savedPosition: ArticleSpeechPlaybackPosition?
        let model: String
        let voice: String
    }

    private struct SyncedResumeResolution {
        let chunkIndex: Int?
        let offset: TimeInterval
        let loadedDurations: [Int: TimeInterval]
        let totalDuration: TimeInterval?
        let shouldClearSavedPosition: Bool
    }

    private nonisolated static func preparePlayback(
        sourceID: String,
        content: String,
        provider: MacArticleSpeechMode,
        model: String,
        voice: String,
        isPaper: Bool,
        sourceContentSignature: String?,
        narrationPreparationSignature: String?,
        accountPosition: ArticleSpeechPlaybackPosition? = nil
    ) -> PlaybackPreparation {
        let narrationText = isPaper
            ? MacArticleSpeechText.paperNarrationText(from: content)
            : MacArticleSpeechText.narrationText(from: content)
        let contentSignature = SyncedArticleAudioStore.contentSignature(for: narrationText)
        // Apple speech used to bypass the full narration cleanup and speak the
        // raw PDF extraction, even though cloud voices received cleaned chunks.
        // All providers must consume the exact same preflight-cleaned text.
        let speakableText = MacArticleSpeechText.speakableInput(from: narrationText)
        // Boundaries only move for a generation that has no complete manifest
        // yet; anything already generated replays from its manifest's own chunk
        // texts, so cached audio keeps seeking and resuming exactly as before.
        let chunks = narrationChunks(
            from: narrationText,
            maxLength: chunkLimit(for: provider, model: model),
            firstChunkMaxLength: firstChunkLimit(for: provider, model: model),
            leadChunkCount: leadChunkCount(for: provider)
        )

        var manifest: SyncedArticleAudioManifest?
        var manifestChunkTexts: [String]?
        if provider.isCloudProvider,
           let complete = SyncedArticleAudioStore.loadManifestIgnoringChunks(sourceID: sourceID),
           complete.usesSupportedPlaybackFormat,
           firstSyncedChunkIsAvailable(in: complete),
           cachedContentMatches(
               manifest: complete,
               content: content,
               narrationSignature: contentSignature,
               isPaper: isPaper
           ) {
            let sortedChunks = complete.chunks.sorted { $0.index < $1.index }
            let texts = sortedChunks.compactMap(\.text)
            // This is already-generated, content-matched audio. Its recorded
            // model, voice, and chunking outrank this Mac's current settings;
            // changing a preference must not hide audio made on the iPhone.
            manifest = complete
            if texts.count == sortedChunks.count {
                manifestChunkTexts = texts
            }
        }

        return PlaybackPreparation(
            narrationText: narrationText,
            contentSignature: contentSignature,
            sourceContentSignature: sourceContentSignature,
            narrationPreparationSignature: narrationPreparationSignature,
            speakableText: speakableText,
            chunks: chunks,
            manifest: manifest,
            manifestChunkTexts: manifestChunkTexts,
            hasCompleteRequestCache: manifest != nil
                || completeRequestCacheExists(
                    chunks: chunks,
                    provider: provider,
                    model: model,
                    voice: voice
                ),
            uncachedCharacterCount: manifest != nil
                ? 0
                : uncachedCharacterCount(
                    chunks: chunks,
                    provider: provider,
                    model: model,
                    voice: voice
                ),
            // Generation 2's account copy is the source's ReadingState; the newer saved time wins.
            savedPosition: ListeningPositionSync.newest(SyncedArticleAudioStore.loadPlaybackPosition(sourceID: sourceID), accountPosition),
            model: model,
            voice: voice
        )
    }

    private nonisolated static func completeRequestCacheExists(
        chunks: [String],
        provider: MacArticleSpeechMode,
        model: String,
        voice: String
    ) -> Bool {
        guard provider.isCloudProvider, !chunks.isEmpty else { return false }
        for chunk in chunks {
            guard let parts = MacArticleTTSClient.requestCacheParts(
                provider: provider,
                model: model,
                voice: voice,
                speed: MacArticleSpeechSpeed.defaultSpeed,
                text: chunk
            ) else {
                return false
            }
            let cacheKey = ArticleSpeechAudioCache.key(parts: parts)
            guard ArticleSpeechAudioCache.hasData(for: cacheKey) else { return false }
        }
        return true
    }

    /// Total characters of chunks that would need fresh (billable) generation.
    /// Chunks whose request cache is already on disk play back for free.
    private nonisolated static func uncachedCharacterCount(
        chunks: [String],
        provider: MacArticleSpeechMode,
        model: String,
        voice: String
    ) -> Int {
        guard provider.isCloudProvider else { return 0 }
        var total = 0
        for chunk in chunks {
            if let parts = MacArticleTTSClient.requestCacheParts(
                provider: provider,
                model: model,
                voice: voice,
                speed: MacArticleSpeechSpeed.defaultSpeed,
                text: chunk
            ), ArticleSpeechAudioCache.hasData(for: ArticleSpeechAudioCache.key(parts: parts)) {
                continue
            }
            total += chunk.count
        }
        return total
    }

    private func applySavedPosition(_ preparation: PlaybackPreparation) {
        pendingResumeGlobalTime = nil
        pendingResumeAppleCharacterOffset = nil
        guard let saved = preparation.savedPosition else { return }
        if let savedSignature = saved.contentSignature, savedSignature != preparation.contentSignature {
            return
        }
        pendingResumeGlobalTime = saved.globalTime >= Self.minimumResumeInterval ? saved.globalTime : nil
        pendingResumeAppleCharacterOffset = saved.appleCharacterOffset
    }

    /// Publishes playback state and starts audio. All heavy work already
    /// happened off-main in `preparePlayback`; this only mutates UI state.
    private func startPlayback(
        article: StudioArticle,
        preparation: PlaybackPreparation,
        provider: MacArticleSpeechMode
    ) {
        guard let speakableText = preparation.speakableText else {
            isLoading = false
            nowPlayingTitle = nil
            nowPlayingSubtitle = nil
            errorMessage = "This source does not have readable text yet."
            return
        }

        applySavedPosition(preparation)
        activeNarrationSignature = preparation.contentSignature
        activeArticleID = article.id
        nowPlayingTitle = article.title
        loadNowPlayingArtwork(for: article)
        errorMessage = nil
        isPlaying = true
        isPaused = false
        appleSpeechBaseCharacterOffset = pendingResumeAppleCharacterOffset ?? 0
        appleSpeechCharacterOffset = appleSpeechBaseCharacterOffset
        updateNowPlayingInfo()
        Task { [activityStorage] in
            do {
                try await activityStorage.recordScheduledSourceActivity(
                    sourceID: article.id,
                    on: Date(),
                    kind: .listening
                )
            } catch {
                articleSpeechLogger.error(
                    "Failed to log listening activity for \(article.id, privacy: .public): \(error.localizedDescription)"
                )
            }
        }

        if provider == .apple {
            var textToSpeak = speakableText
            if let resumeOffset = pendingResumeAppleCharacterOffset,
               resumeOffset > 0,
               resumeOffset < speakableText.count {
                let startIndex = speakableText.index(speakableText.startIndex, offsetBy: resumeOffset)
                textToSpeak = String(speakableText[startIndex...])
            }
            pendingResumeAppleCharacterOffset = nil

            let utterance = AVSpeechUtterance(string: textToSpeak)
            utterance.prefersAssistiveTechnologySettings = false
            utterance.rate = Self.appleSpeechRate(for: speed)
            utterance.pitchMultiplier = 0.95
            if let identifier = activeAppleVoiceIdentifier ?? appleVoiceIdentifier,
               let voice = AVSpeechSynthesisVoice(identifier: identifier) {
                utterance.voice = voice
            }
            isLoading = false
            synthesizer.speak(utterance)
            return
        }

        syncedAudioContext = SyncedArticleAudioContext(
            sourceID: article.id,
            title: article.title,
            subtitle: displaySubtitle(for: article),
            sourceType: article.sourceType.rawValue,
            sourceURL: article.url,
            provider: provider,
            model: preparation.model,
            voice: preparation.voice,
            voiceLabel: providerVoiceLabel(
                provider: provider,
                voice: preparation.voice,
                model: preparation.model
            ),
            contentSignature: preparation.contentSignature,
            sourceContentSignature: preparation.sourceContentSignature,
            narrationPreparationSignature: preparation.narrationPreparationSignature,
            totalCharacters: preparation.narrationText.count,
            sourceText: preparation.narrationText,
            fileExtension: Self.syncedAudioFileExtension(provider: provider, model: preparation.model),
            createdAt: Date()
        )

        if let manifest = preparation.manifest {
            // Prefer the chunk texts recorded in the manifest: they match the
            // audio files exactly, so seeking and resume stay aligned even when
            // the current provider would chunk the source differently.
            audioChunks = preparation.manifestChunkTexts ?? preparation.chunks
            beginSyncedPlayback(manifest: manifest)
            return
        }

        audioChunks = preparation.chunks
        guard !audioChunks.isEmpty else {
            stop()
            nowPlayingTitle = nil
            nowPlayingSubtitle = nil
            errorMessage = "This source does not have readable text yet."
            return
        }
        audioChunkIndex = 0
        isLoading = true
        let generationID = UUID()
        audioGenerationID = generationID
        if !preparation.hasCompleteRequestCache {
            audioGenerationProgress = ArticleSpeechChunkProgress(
                completedChunks: 0,
                totalChunks: audioChunks.count
            )
            articleSpeechLogger.info(
                "Text-to-speech generation started: \(self.audioChunks.count) chunks, \(preparation.narrationText.count) characters"
            )
            ArticleSpeechDiagnostics.append(
                "GENERATION_STARTED provider=\(provider.rawValue) chunks=\(audioChunks.count) characters=\(preparation.narrationText.count) source=\(article.id)"
            )
        } else {
            articleSpeechLogger.info(
                "Text-to-speech replay started from request cache: \(self.audioChunks.count) chunks"
            )
        }
        prefetchAllAudioChunks(generationID: generationID)

        startPlaybackTask { [weak self] in
            if await self?.applyPendingResumeIfNeeded() == true { return }
            await self?.playNextChunk()
        }
    }

    /// Replaces the active playback task, cancelling the previous one from the
    /// outside. The replacement must never cancel `playbackTask` from within
    /// its own body — that self-cancels and silently aborts the operation.
    private func startPlaybackTask(_ operation: @escaping @MainActor () async -> Void) {
        playbackTask?.cancel()
        playbackTask = Task { await operation() }
    }

    func pauseOrResume() {
        guard isPlaying else { return }
        if mode == .apple {
            if synthesizer.isPaused {
                synthesizer.continueSpeaking()
                isPaused = false
            } else {
                synthesizer.pauseSpeaking(at: .word)
                isPaused = true
                savePlaybackPositionNow()
            }
            updateNowPlayingInfo()
            return
        }

        if isBufferingNextChunk {
            isPaused.toggle()
            if isPaused {
                savePlaybackPositionNow()
            }
            updateNowPlayingInfo()
            return
        }

        guard let audioPlayer else {
            // No player and not buffering: a chunk failed and playback paused in
            // place. Resume retries the failed chunk from the saved position.
            if isPaused {
                isPaused = false
                errorMessage = nil
                startPlaybackTask { [weak self] in
                    await self?.playNextChunk()
                }
                updateNowPlayingInfo()
            }
            return
        }
        if audioPlayer.isPlaying {
            audioPlayer.pause()
            isPaused = true
            savePlaybackPositionNow()
        } else {
            audioPlayer.play()
            isPaused = false
        }
        updateNowPlayingInfo()
    }

    func skipBackward(seconds: TimeInterval = 15) {
        guard canSeek else { return }

        if let player = audioPlayer {
            let offset = player.currentTime
            if offset >= seconds {
                player.currentTime = offset - seconds
                playbackCurrentTime = currentGlobalPlaybackTime()
                updateNowPlayingInfo()
                return
            }

            var remaining = seconds - offset
            var chunkIndex = currentlyPlayingChunkIndex - 1
            while chunkIndex >= 0 {
                guard let duration = chunkDurations[chunkIndex], duration > 0 else { break }
                if remaining <= duration {
                    startPlaybackTask { [weak self] in
                        await self?.jumpToChunk(chunkIndex, offset: duration - remaining)
                    }
                    return
                }
                remaining -= duration
                chunkIndex -= 1
            }
        }

        seek(to: max(0, currentGlobalPlaybackTime() - seconds))
    }

    func skipForward(seconds: TimeInterval = 15) {
        guard canSeek else { return }

        if let player = audioPlayer {
            let offset = player.currentTime
            let duration = chunkDurations[currentlyPlayingChunkIndex] ?? player.duration
            if duration > 0, offset + seconds <= duration {
                player.currentTime = offset + seconds
                playbackCurrentTime = currentGlobalPlaybackTime()
                updateNowPlayingInfo()
                return
            }

            var remaining = seconds - max(0, duration - offset)
            var chunkIndex = currentlyPlayingChunkIndex + 1
            while chunkIndex < totalChunkCount {
                guard let chunkDuration = chunkDurations[chunkIndex], chunkDuration > 0 else { break }
                if remaining <= chunkDuration {
                    startPlaybackTask { [weak self] in
                        await self?.jumpToChunk(chunkIndex, offset: remaining)
                    }
                    return
                }
                remaining -= chunkDuration
                chunkIndex += 1
            }
        }

        seek(to: min(playbackDuration, currentGlobalPlaybackTime() + seconds))
    }

    func cycleSpeed() {
        speed = MacArticleSpeechSpeed.nextOption(after: speed)
    }

    func startSleepTimer(duration: TimeInterval) {
        guard duration > 0 else { return }
        cancelSleepTimer()
        let endsAt = Date().addingTimeInterval(duration)
        sleepTimerEndsAt = endsAt
        sleepTimerRemaining = duration
        sleepTimerTask = Task { [weak self, endsAt] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, self?.sleepTimerEndsAt == endsAt else { return }
                let remaining = endsAt.timeIntervalSinceNow
                if remaining <= 0 {
                    self?.deferPublishedUpdate { [weak self] in
                        guard self?.sleepTimerEndsAt == endsAt else { return }
                        self?.cancelSleepTimer()
                        self?.stop()
                    }
                    return
                }
                self?.deferPublishedUpdate { [weak self] in
                    guard self?.sleepTimerEndsAt == endsAt else { return }
                    self?.sleepTimerRemaining = remaining
                }
            }
        }
    }

    func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEndsAt = nil
        sleepTimerRemaining = nil
    }

    func seek(to time: TimeInterval) {
        guard canSeek else { return }
        let clamped = min(max(time, 0), playbackDuration)
        let (chunkIndex, offset) = location(forGlobalTime: clamped)
        let availableLimit = availableSeekChunkLimit()
        guard chunkIndex <= availableLimit else { return }

        startPlaybackTask { [weak self] in
            await self?.jumpToChunk(chunkIndex, offset: offset)
            self?.savePlaybackPositionNow()
        }
    }

    func seek(toFraction fraction: Double) {
        guard playbackDuration > 0 else { return }
        seek(to: playbackDuration * min(max(fraction, 0), 1))
    }

    /// Stops playback. By default any in-flight audio generation is cancelled
    /// and its partial synced audio cleaned up (explicit stop/cancel actions).
    /// Pass `detachingGeneration: true` when the listener is merely moving to
    /// another source — the generation then keeps running in the background
    /// until every chunk is synced and the manifest is written.
    func stop(detachingGeneration: Bool = false) {
        let sourceID = activeArticleID
        let positionSnapshot = capturePlaybackPositionSnapshot()

        let didDetachGeneration = detachingGeneration && detachActiveGenerationForBackgroundCompletion()

        let partialGenerationSourceID: String? = {
            guard !didDetachGeneration,
                  mode.isCloudProvider,
                  let progress = audioGenerationProgress,
                  !progress.isComplete else {
                return nil
            }
            return syncedAudioContext?.sourceID ?? activeArticleID
        }()

        cancelSleepTimer()
        clearNowPlayingInfo()
        playbackEpoch += 1
        playbackTask?.cancel()
        playbackTask = nil
        audioGenerationID = UUID()
        preparationRequestID = UUID()
        foregroundGenerationChunksRemaining = 0
        synthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer = nil
        preloadedNextPlayer = nil
        prefetchTasks.values.forEach { $0.cancel() }
        prefetchTasks = [:]
        audioChunks = []
        audioChunkIndex = 0
        syncedChunkURLs = []
        completedSyncedChunks = []
        failedGenerationChunkCount = 0
        activeArticleID = nil
        preparingArticleID = nil
        nowPlayingTitle = nil
        nowPlayingSubtitle = nil
        syncedAudioContext = nil
        audioGenerationProgress = nil
        preparationStatus = nil
        isPlaying = false
        isPaused = false
        isLoading = false
        hasStartedPlayback = false
        highestReadyChunkIndex = -1
        pendingResumeGlobalTime = nil
        pendingResumeAppleCharacterOffset = nil
        activeNarrationSignature = nil
        appleSpeechBaseCharacterOffset = 0
        appleSpeechCharacterOffset = 0
        lastPlaybackPositionSaveAt = nil
        lastAccountPositionSaveAt = nil
        resetPlaybackPosition()

        if let sourceID, let positionSnapshot {
            persistPlaybackPosition(positionSnapshot, sourceID: sourceID)
        }

        if let partialGenerationSourceID {
            Task.detached {
                if SyncedArticleAudioStore.loadCompleteManifest(sourceID: partialGenerationSourceID) == nil {
                    ArticleSpeechAudioCache.deleteCachedAudio(sourceID: partialGenerationSourceID, forgettingReplicaNarration: false)
                }
            }
        }
    }

    /// Moves the current generation's chunk tasks into `detachedGenerations`
    /// so they keep running after playback state is torn down. Returns false
    /// when there is no incomplete cloud generation to hand over.
    private func detachActiveGenerationForBackgroundCompletion() -> Bool {
        guard mode.isCloudProvider,
              let context = syncedAudioContext,
              !audioChunks.isEmpty,
              completedSyncedChunks.count < audioChunks.count,
              !prefetchTasks.isEmpty else { return false }

        let hasScheduledRemainingChunks = audioChunks.count == 1
            || prefetchTasks.keys.contains { $0 > 0 }
            || completedSyncedChunks.contains { $0.index > 0 }
        // Only the lead chunk ever ran and it already failed permanently: the
        // generation is dead, so let the normal cancel path clean it up.
        guard hasScheduledRemainingChunks || failedGenerationChunkCount == 0 else { return false }

        // At most one background generation per source: an older record for
        // this source would race the new one on the same chunk files.
        cancelBackgroundGeneration(sourceID: context.sourceID, cleaningUpPartialAudio: false)

        // Completed chunks are already on disk (synced store + request cache);
        // dropping their task handles releases the audio Data they retain.
        var tasks = prefetchTasks
        for chunk in completedSyncedChunks {
            tasks[chunk.index] = nil
        }

        let generationID = audioGenerationID
        detachedGenerations[generationID] = DetachedAudioGeneration(
            context: context,
            chunkTexts: audioChunks,
            tasks: tasks,
            completedChunks: completedSyncedChunks,
            failedChunkCount: failedGenerationChunkCount,
            hasScheduledRemainingChunks: hasScheduledRemainingChunks
        )
        backgroundGenerationSourceIDs.insert(context.sourceID)
        backgroundGenerationProgress[context.sourceID] = ArticleSpeechChunkProgress(
            completedChunks: completedSyncedChunks.count,
            totalChunks: audioChunks.count
        )
        prefetchTasks = [:]
        if hasScheduledRemainingChunks {
            // A chunk whose prefetch task failed and was dropped during
            // playback would otherwise never be retried; give every missing
            // chunk a fresh task. Audio that already exists returns straight
            // from the per-request cache.
            fillMissingDetachedChunkTasks(generationID: generationID)
        }
        articleSpeechLogger.info(
            "Text-to-speech generation continues in background: \(self.completedSyncedChunks.count)/\(self.audioChunks.count) chunks done for \(context.sourceID)"
        )
        ArticleSpeechDiagnostics.append(
            "GENERATION_DETACHED source=\(context.sourceID) completed=\(completedSyncedChunks.count)/\(audioChunks.count)"
        )
        return true
    }

    /// True while chunk tasks for this generation should keep saving results:
    /// either it is the generation playback is consuming, or it was detached
    /// to finish in the background.
    private func isGenerationActive(_ generationID: UUID) -> Bool {
        generationID == audioGenerationID || detachedGenerations[generationID] != nil
    }

    /// Ends any background generation for the source. Explicit stops and cache
    /// deletion clean up partial synced audio (matching `stop()`); a restart of
    /// the same source passes false so the new generation can reuse the chunks.
    func cancelBackgroundGeneration(sourceID: String, cleaningUpPartialAudio: Bool = true) {
        for (generationID, generation) in detachedGenerations
        where generation.context.sourceID == sourceID {
            cancelDetachedGeneration(
                generationID: generationID,
                cleaningUpPartialAudio: cleaningUpPartialAudio
            )
        }
    }

    private func cancelDetachedGeneration(
        generationID: UUID,
        cleaningUpPartialAudio: Bool = true,
        outcome: ArticleSpeechBackgroundGenerationOutcome = .cancelled
    ) {
        guard let generation = detachedGenerations.removeValue(forKey: generationID) else { return }
        if !detachedGenerations.values.contains(where: { $0.context.sourceID == generation.context.sourceID }) {
            backgroundGenerationSourceIDs.remove(generation.context.sourceID)
        }
        generation.tasks.values.forEach { $0.cancel() }
        noteBackgroundGenerationEnded(sourceID: generation.context.sourceID, outcome: outcome)
        guard cleaningUpPartialAudio else { return }
        let sourceID = generation.context.sourceID
        Task.detached {
            if SyncedArticleAudioStore.loadCompleteManifest(sourceID: sourceID) == nil {
                ArticleSpeechAudioCache.deleteCachedAudio(sourceID: sourceID, forgettingReplicaNarration: false)
            }
        }
    }

    private func playNextChunk() async {
        guard audioChunkIndex < totalChunkCount else {
            if let activeArticleID, syncedChunkURLs.isEmpty {
                Task.detached(priority: .utility) {
                    ArticleSpeechAudioCache.markCached(articleID: activeArticleID)
                }
                writeSyncedAudioManifestFromSavedChunks()
            }
            finishPlayback(completedSuccessfully: true)
            return
        }

        isLoading = true
        let epoch = playbackEpoch
        let currentChunkIndex = audioChunkIndex
        currentlyPlayingChunkIndex = currentChunkIndex

        if let preloaded = takePreloadedPlayer(for: currentChunkIndex) {
            audioChunkIndex = currentChunkIndex + 1
            do {
                try startPlayer(preloaded)
            } catch {
                pausePlayback(withError: error, retryingChunk: currentChunkIndex)
            }
            return
        }

        do {
            let data = try await segmentData(at: currentChunkIndex)
            guard !Task.isCancelled, epoch == playbackEpoch, activeArticleID != nil else {
                deferPublishedUpdate { [weak self] in
                    self?.isLoading = false
                }
                return
            }

            audioChunkIndex = currentChunkIndex + 1
            try playAudioData(data)
            // Consumed: from here on this chunk replays from disk if needed.
            prefetchTasks[currentChunkIndex] = nil
        } catch {
            guard !Task.isCancelled, epoch == playbackEpoch, activeArticleID != nil else {
                deferPublishedUpdate { [weak self] in
                    self?.isLoading = false
                }
                return
            }
            pausePlayback(withError: error, retryingChunk: currentChunkIndex)
        }
    }

    /// Data for the chunk at `index`, wherever it currently lives: the synced
    /// chunk file for cached replays, an in-flight prefetch task, the
    /// per-request disk cache, or a fresh generation.
    private func segmentData(at index: Int) async throws -> Data {
        if !syncedChunkURLs.isEmpty {
            guard index < syncedChunkURLs.count else {
                throw MacArticleTTSError.badResponse("Audio segment \(index + 1) is out of range.")
            }
            return try await Task.detached { [url = syncedChunkURLs[index]] in
                try Data(contentsOf: url)
            }.value
        }
        return try await audioData(forChunkAt: index)
    }

    private func beginSyncedPlayback(manifest: SyncedArticleAudioManifest) {
        isLoading = true
        audioGenerationProgress = nil
        let epoch = playbackEpoch
        startPlaybackTask { [weak self] in
            let urls = Self.syncedChunkURLs(for: manifest)
            guard let self, !Task.isCancelled, epoch == self.playbackEpoch else { return }
            self.syncedChunkURLs = urls
            self.audioChunkIndex = 0

            if let resumeTime = self.pendingResumeGlobalTime,
               resumeTime >= Self.minimumResumeInterval {
                let resolution = await Task.detached(priority: .userInitiated) {
                    Self.resolveSyncedResume(
                        resumeTime: resumeTime,
                        chunkURLs: urls
                    )
                }.value
                guard !Task.isCancelled, epoch == self.playbackEpoch else { return }
                self.applySyncedResumeResolution(resolution)
                if resolution.shouldClearSavedPosition {
                    if let sourceID = self.activeArticleID {
                        Task.detached(priority: .utility) { [storage = self.activityStorage] in
                            await Self.clearListenPosition(sourceID: sourceID, storage: storage)
                        }
                    }
                    await self.playNextChunk()
                    self.loadAllChunkDurations()
                    return
                }
                if let chunkIndex = resolution.chunkIndex {
                    self.loadAllChunkDurations()
                    await self.jumpToChunk(chunkIndex, offset: resolution.offset)
                    return
                }
            }

            self.pendingResumeGlobalTime = nil
            await self.playNextChunk()
            self.loadAllChunkDurations()
        }
    }

    private nonisolated static func syncedChunkURLs(for manifest: SyncedArticleAudioManifest) -> [URL] {
        let directory = SyncedArticleAudioStore.sourceDirectory(sourceID: manifest.sourceID)
            .appendingPathComponent(SyncedArticleAudioStore.chunksDirectoryName, isDirectory: true)
        return manifest.chunks
            .sorted { $0.index < $1.index }
            .map { directory.appendingPathComponent($0.fileName) }
    }

    private nonisolated static func firstSyncedChunkIsAvailable(in manifest: SyncedArticleAudioManifest) -> Bool {
        guard !MacArticleSpeechSettings.isRetiredModel(manifest.model) else { return false }
        guard let first = syncedChunkURLs(for: manifest).first else { return false }
        return FileManager.default.fileExists(atPath: first.path)
    }

    private nonisolated static func resolveSyncedResume(
        resumeTime: TimeInterval,
        chunkURLs: [URL]
    ) -> SyncedResumeResolution {
        var loadedDurations: [Int: TimeInterval] = [:]
        var elapsed: TimeInterval = 0
        let target = max(0, resumeTime)

        for (index, url) in chunkURLs.enumerated() {
            if Task.isCancelled { break }
            guard let duration = audioDuration(at: url), duration > 0 else {
                return SyncedResumeResolution(
                    chunkIndex: nil,
                    offset: 0,
                    loadedDurations: loadedDurations,
                    totalDuration: nil,
                    shouldClearSavedPosition: false
                )
            }
            loadedDurations[index] = duration
            if target <= elapsed + duration || index == chunkURLs.count - 1 {
                let totalDuration = index == chunkURLs.count - 1 ? elapsed + duration : nil
                let shouldClear = totalDuration.map {
                    target >= $0 - completionResumeThreshold
                } ?? false
                return SyncedResumeResolution(
                    chunkIndex: shouldClear ? nil : index,
                    offset: min(max(target - elapsed, 0), duration),
                    loadedDurations: loadedDurations,
                    totalDuration: totalDuration,
                    shouldClearSavedPosition: shouldClear
                )
            }
            elapsed += duration
        }

        return SyncedResumeResolution(
            chunkIndex: nil,
            offset: 0,
            loadedDurations: loadedDurations,
            totalDuration: loadedDurations.count == chunkURLs.count ? elapsed : nil,
            shouldClearSavedPosition: false
        )
    }

    private nonisolated static func audioDuration(at url: URL) -> TimeInterval? {
        guard FileManager.default.fileExists(atPath: url.path),
              let player = try? AVAudioPlayer(contentsOf: url),
              player.duration > 0 else {
            return nil
        }
        return player.duration
    }

    private func applySyncedResumeResolution(_ resolution: SyncedResumeResolution) {
        pendingResumeGlobalTime = nil
        for (index, duration) in resolution.loadedDurations {
            chunkDurations[index] = duration
        }
        if let totalDuration = resolution.totalDuration, totalDuration > 0 {
            playbackDuration = totalDuration
        } else {
            updatePlaybackDuration()
        }
    }

    private func playAudioData(_ data: Data, startingAt offset: TimeInterval = 0) throws {
        try startPlayer(AVAudioPlayer(data: data), startingAt: offset)
    }

    private func startPlayer(_ player: AVAudioPlayer, startingAt offset: TimeInterval = 0) throws {
        let wasPaused = isPaused
        player.delegate = self
        player.enableRate = true
        player.rate = Self.audioPlaybackRate(for: speed)
        player.prepareToPlay()
        recordChunkDuration(index: currentlyPlayingChunkIndex, duration: player.duration)
        if offset > 0 {
            player.currentTime = min(offset, player.duration)
        }
        audioPlayer = player
        hasStartedPlayback = true
        deferPublishedUpdate { [weak self] in
            self?.isLoading = false
        }
        startPlaybackTimeUpdatesIfNeeded()

        guard player.play() else {
            throw MacArticleTTSError.badResponse("Audio playback could not start.")
        }

        if wasPaused {
            player.pause()
        }
        playbackCurrentTime = currentGlobalPlaybackTime()
        updateNowPlayingInfo()
        preloadNextSegment()
    }

    private func takePreloadedPlayer(for index: Int) -> AVAudioPlayer? {
        guard let preloaded = preloadedNextPlayer, preloaded.index == index else { return nil }
        preloadedNextPlayer = nil
        return preloaded.player
    }

    /// Prepares the next chunk's player while the current chunk is still
    /// playing, so the handoff at the chunk boundary has no fetch/decode gap.
    /// Especially audible with Orpheus's ~180-character chunks, where a
    /// boundary lands every sentence or two.
    private func preloadNextSegment() {
        guard mode.isCloudProvider else { return }
        let nextIndex = audioChunkIndex
        guard nextIndex < totalChunkCount, preloadedNextPlayer?.index != nextIndex else { return }
        let epoch = playbackEpoch
        Task { [weak self] in
            guard let self else { return }
            guard let data = try? await self.segmentData(at: nextIndex) else { return }
            guard self.playbackEpoch == epoch,
                  self.activeArticleID != nil,
                  self.preloadedNextPlayer?.index != nextIndex,
                  let player = try? AVAudioPlayer(data: data) else { return }
            player.prepareToPlay()
            self.preloadedNextPlayer = (index: nextIndex, player: player)
        }
    }

    /// Surfaces a chunk failure without tearing the session down: playback
    /// pauses in place with position and chunk state intact, and resume (or
    /// the media-key play command) retries the failed chunk.
    private func pausePlayback(withError error: Error, retryingChunk index: Int) {
        articleSpeechLogger.error(
            "Playback paused on chunk \(index + 1): \(error.localizedDescription, privacy: .public)"
        )
        ArticleSpeechDiagnostics.append(
            "PLAYBACK_PAUSED chunk=\(index) \(error.localizedDescription)"
        )
        audioChunkIndex = index
        currentlyPlayingChunkIndex = index
        // A CancellationError here usually means abortAudioGeneration tore the
        // prefetch tasks down and already published the real provider error —
        // don't overwrite that message (or its provider-switch hint) with a
        // generic "operation cancelled".
        if !(error is CancellationError) || errorMessage == nil {
            errorMessage = error.localizedDescription
            errorSuggestsProviderSwitch = (error as? MacArticleTTSError)?.suggestsProviderSwitch == true
        }
        isPaused = true
        isLoading = false
        savePlaybackPositionNow()
        updateNowPlayingInfo()
    }

    private func jumpToChunk(_ index: Int, offset: TimeInterval) async {
        let wasPaused = isPaused
        playbackEpoch += 1
        let epoch = playbackEpoch
        preloadedNextPlayer = nil
        audioPlayer?.stop()
        audioPlayer = nil

        currentlyPlayingChunkIndex = index
        audioChunkIndex = index
        isPaused = wasPaused

        do {
            let data = try await segmentData(at: index)
            guard epoch == playbackEpoch, activeArticleID != nil else { return }
            audioChunkIndex = index + 1
            try playAudioData(data, startingAt: offset)
        } catch is CancellationError {
            return
        } catch {
            guard epoch == playbackEpoch, activeArticleID != nil else { return }
            pausePlayback(withError: error, retryingChunk: index)
        }
    }

    private var totalChunkCount: Int {
        if !syncedChunkURLs.isEmpty {
            return syncedChunkURLs.count
        }
        return audioChunks.count
    }

    private func availableSeekChunkLimit() -> Int {
        if !syncedChunkURLs.isEmpty {
            return syncedChunkURLs.count - 1
        }
        let played = max(0, audioChunkIndex - 1)
        return max(highestReadyChunkIndex, played)
    }

    private func chunkDuration(at index: Int) -> TimeInterval {
        if let duration = chunkDurations[index], duration > 0 {
            return duration
        }
        return estimatedChunkDuration
    }

    private var estimatedChunkDuration: TimeInterval {
        guard !chunkDurations.isEmpty else { return 0 }
        let total = chunkDurations.values.reduce(0, +)
        return total / Double(chunkDurations.count)
    }

    private func location(forGlobalTime time: TimeInterval) -> (chunkIndex: Int, offset: TimeInterval) {
        let count = totalChunkCount
        guard count > 0 else { return (0, 0) }

        var remaining = min(max(time, 0), playbackDuration)
        for index in 0..<count {
            let duration = chunkDuration(at: index)
            if remaining <= duration || index == count - 1 {
                return (index, min(remaining, duration))
            }
            remaining -= duration
        }
        return (0, 0)
    }

    private func chunkStartTime(forChunk index: Int) -> TimeInterval {
        guard index > 0 else { return 0 }
        return (0..<index).reduce(0) { partial, chunkIndex in
            partial + chunkDuration(at: chunkIndex)
        }
    }

    private func currentGlobalPlaybackTime() -> TimeInterval {
        chunkStartTime(forChunk: currentlyPlayingChunkIndex) + (audioPlayer?.currentTime ?? 0)
    }

    private func recordChunkDuration(index: Int, duration: TimeInterval) {
        guard duration > 0 else { return }
        chunkDurations[index] = duration
        updatePlaybackDuration()
    }

    private func updatePlaybackDuration() {
        let count = totalChunkCount
        guard count > 0 else {
            playbackDuration = 0
            return
        }

        let knownTotal = chunkDurations.values.reduce(0, +)
        let knownCount = chunkDurations.count
        if knownCount == count {
            playbackDuration = knownTotal
        } else if knownCount > 0 {
            let average = knownTotal / Double(knownCount)
            playbackDuration = knownTotal + average * Double(count - knownCount)
        } else {
            playbackDuration = 0
        }
    }

    private func startPlaybackTimeUpdatesIfNeeded() {
        playbackTimeUpdateTask?.cancel()
        playbackTimeUpdateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.playbackCurrentTime = self?.currentGlobalPlaybackTime() ?? 0
                self?.updateNowPlayingInfo()
                self?.schedulePlaybackPositionSave()
            }
        }
    }

    private func loadAllChunkDurations() {
        let urls = chunkFileURLs()
        guard !urls.isEmpty else { return }

        chunkDurationLoadTask?.cancel()
        chunkDurationLoadTask = Task.detached(priority: .utility) { [weak self, urls] in
            var durations: [Int: TimeInterval] = [:]
            for (index, url) in urls.enumerated() {
                if Task.isCancelled { return }
                guard FileManager.default.fileExists(atPath: url.path),
                      let player = try? AVAudioPlayer(contentsOf: url),
                      player.duration > 0 else { continue }
                durations[index] = player.duration
            }
            let total = durations.values.reduce(0, +)
            await MainActor.run { [weak self, durations, total] in
                guard let self, !Task.isCancelled else { return }
                for (index, duration) in durations {
                    self.chunkDurations[index] = duration
                }
                if total > 0 {
                    self.playbackDuration = total
                } else {
                    self.updatePlaybackDuration()
                }
            }
        }
    }

    private func chunkFileURLs() -> [URL] {
        if !syncedChunkURLs.isEmpty {
            return syncedChunkURLs
        }
        guard let context = syncedAudioContext, totalChunkCount > 0 else { return [] }
        return (0..<totalChunkCount).map { index in
            SyncedArticleAudioStore.chunkURL(
                sourceID: context.sourceID,
                index: index,
                fileExtension: context.fileExtension
            )
        }
    }

    private func resetPlaybackPosition() {
        playbackTimeUpdateTask?.cancel()
        playbackTimeUpdateTask = nil
        chunkDurationLoadTask?.cancel()
        chunkDurationLoadTask = nil
        chunkDurations = [:]
        currentlyPlayingChunkIndex = 0
        playbackCurrentTime = 0
        playbackDuration = 0
    }

    /// Returns true when `content` matches the narration that produced `manifest`.
    /// Blocking file I/O on the stored-text fallback — never call on the main actor.
    private nonisolated static func cachedContentMatches(
        manifest: SyncedArticleAudioManifest,
        content: String,
        narrationSignature: String,
        isPaper: Bool
    ) -> Bool {
        var signatures: Set<String> = [narrationSignature]
        if !isPaper {
            signatures.insert(
                SyncedArticleAudioStore.contentSignature(
                    for: content.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }
        if signatures.contains(manifest.contentSignature) {
            return true
        }

        if let storedText = try? SyncedArticleAudioStore.loadSourceText(for: manifest) {
            let storedNarration = isPaper
                ? MacArticleSpeechText.paperNarrationText(from: storedText)
                : MacArticleSpeechText.narrationText(from: storedText)
            if signatures.contains(SyncedArticleAudioStore.contentSignature(for: storedNarration)) {
                return true
            }
        }

        return false
    }

    private func audioData(forChunkAt index: Int) async throws -> Data {
        if let task = prefetchTasks[index] {
            do {
                return try await task.value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Drop the failed task so a later retry starts fresh instead of
                // re-awaiting the same stored failure.
                prefetchTasks[index] = nil
                articleSpeechLogger.warning(
                    "Prefetch task failed for chunk \(index + 1); retrying for playback: \(error.localizedDescription, privacy: .public)"
                )
                return try await generateAudioWithRetry(forChunkAt: index)
            }
        }

        return try await generateAudioWithRetry(forChunkAt: index)
    }

    private func prefetchAllAudioChunks(generationID: UUID) {
        guard mode.isCloudProvider, !audioChunks.isEmpty else { return }
        completedSyncedChunks = []
        failedGenerationChunkCount = 0
        foregroundGenerationChunksRemaining = audioChunks.count

        // Give the opening request the provider to itself. Starting six requests
        // in the same turn let a whole chapter compete with the one short chunk
        // blocking the first audible word. Once the opening lands, its playback
        // duration is the buffer while the remainder generates concurrently.
        prefetchChunk(at: 0, permitPool: nil, generationID: generationID)
    }

    private func prefetchRemainingAudioChunks(generationID: UUID) {
        guard generationID == audioGenerationID,
              mode.isCloudProvider,
              audioChunks.count > 1 else { return }
        let permitPool = ArticleSpeechAudioCachePermitPool(
            limit: Self.backgroundAudioCacheConcurrency(for: mode)
        )
        for index in 1..<audioChunks.count {
            prefetchChunk(at: index, permitPool: permitPool, generationID: generationID)
        }
    }

    private func prefetchChunk(
        at index: Int,
        permitPool: ArticleSpeechAudioCachePermitPool?,
        generationID: UUID
    ) {
        guard mode.isCloudProvider,
              index < audioChunks.count,
              prefetchTasks[index] == nil else { return }

        prefetchTasks[index] = makeChunkGenerationTask(
            text: audioChunks[index],
            index: index,
            provider: mode,
            model: activeSpeechModel,
            voice: activeSpeechVoice,
            syncedContext: syncedAudioContext,
            permitPool: permitPool,
            generationID: generationID
        )
    }

    /// Generates one chunk, saves it to the synced store, and reports the
    /// outcome back to whichever generation (active or detached) owns
    /// `generationID`. Shared by playback prefetch and background completion.
    private func makeChunkGenerationTask(
        text: String,
        index: Int,
        provider: MacArticleSpeechMode,
        model: String,
        voice: String,
        syncedContext: SyncedArticleAudioContext?,
        permitPool: ArticleSpeechAudioCachePermitPool?,
        generationID: UUID
    ) -> Task<Data, Error> {
        // Detached: a plain Task would inherit this class's @MainActor isolation,
        // putting every saveChunk write (into the iCloud-synced Audio folder) on
        // the main thread — one blocking write per chunk beachballs playback.
        Task.detached { [weak self] in
            if let permitPool {
                await permitPool.acquire(order: index)
            }
            let releasePermit: () async -> Void = {
                if let permitPool {
                    await permitPool.release()
                }
            }
            var attempt = 0
            while !Task.isCancelled {
                do {
                    try await self?.waitWhileYieldingToForegroundGeneration(generationID: generationID)
                } catch {
                    await releasePermit()
                    throw CancellationError()
                }
                attempt += 1
                do {
                    let data = try await MacArticleTTSClient.speech(
                        provider: provider,
                        text: text,
                        speed: MacArticleSpeechSpeed.defaultSpeed,
                        model: model,
                        voice: voice,
                        task: "read_aloud",
                        source: syncedContext.map {
                            AIUsageSource(id: $0.sourceID, type: $0.sourceType, title: $0.title)
                        }
                    )
                    try Task.checkCancellation()
                    let generationStillActive = await MainActor.run { [weak self] in
                        self?.isGenerationActive(generationID) ?? false
                    }
                    guard generationStillActive else {
                        await releasePermit()
                        throw CancellationError()
                    }
                    if let syncedContext {
                        do {
                            _ = try SyncedArticleAudioStore.saveChunk(
                                data,
                                sourceID: syncedContext.sourceID,
                                index: index,
                                fileExtension: syncedContext.fileExtension
                            )
                        } catch {
                            // A sync failure must not interrupt listening: the audio
                            // still plays from memory and the per-request disk cache.
                            articleSpeechLogger.error(
                                "Could not sync chunk \(index + 1) to iCloud: \(error.localizedDescription, privacy: .public)"
                            )
                        }
                    }
                    await releasePermit()
                    let succeededAttempt = attempt
                    let byteCount = data.count
                    await MainActor.run { [weak self] in
                        self?.recordAudioGenerationChunkSucceeded(
                            generationID: generationID,
                            chunkIndex: index,
                            attempt: succeededAttempt,
                            byteCount: byteCount
                        )
                    }
                    return data
                } catch is CancellationError {
                    await releasePermit()
                    throw CancellationError()
                } catch {
                    articleSpeechLogger.warning(
                        "Chunk \(index + 1) attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)"
                    )
                    // A MacArticleTTSError means the TTS client already exhausted
                    // its own retries or hit a permanent failure (bad request,
                    // missing API key) — retrying from out here cannot succeed.
                    // One exception: a provider that returns HTTP 200 with no
                    // audio ("empty audio stream") does it for one part and not
                    // the next. Giving up on that part ended the whole narration
                    // as incomplete once the other parts landed, so it is asked
                    // again, a few times.
                    let isEmptyStream = error.localizedDescription.contains("empty audio stream")
                    let isPermanent = error is MacArticleTTSError && !(isEmptyStream && attempt < 4)
                    guard !isPermanent, attempt < Self.maxChunkGenerationAttempts else {
                        articleSpeechLogger.error(
                            "Chunk \(index + 1) failed permanently after \(attempt) attempt(s)"
                        )
                        ArticleSpeechDiagnostics.append(
                            "CHUNK_FAILED index=\(index) attempts=\(attempt) \(error.localizedDescription)"
                        )
                        await releasePermit()
                        if let ttsError = error as? MacArticleTTSError, ttsError.abortsGeneration {
                            await MainActor.run { [weak self] in
                                self?.abortAudioGeneration(generationID: generationID, with: ttsError)
                            }
                        } else {
                            await MainActor.run { [weak self] in
                                self?.recordAudioGenerationChunkFailed(
                                    generationID: generationID,
                                    chunkIndex: index
                                )
                            }
                        }
                        throw error
                    }
                    try await Task.sleep(nanoseconds: Self.chunkRetryDelayNanoseconds(attempt: attempt))
                }
            }
            await releasePermit()
            throw CancellationError()
        }
    }

    /// Parks a detached generation's chunk task while the generation the
    /// listener is actually playing still has chunks to produce. Every
    /// generation runs its own permit pool, so chapters left generating in the
    /// background otherwise compete with the foreground chapter for provider
    /// throughput and rate limits — which is what made a freshly started
    /// chapter buffer for half a minute right after its 2-second lead chunk.
    /// Polled rather than gated: the wait self-corrects within one interval no
    /// matter how playback state changed while the task slept, and Task.sleep
    /// honors cancellation.
    private nonisolated func waitWhileYieldingToForegroundGeneration(generationID: UUID) async throws {
        while true {
            let shouldYield = await MainActor.run {
                self.foregroundGenerationChunksRemaining > 0
                    && generationID != self.audioGenerationID
            }
            guard shouldYield else { return }
            try await Task.sleep(for: .seconds(3))
        }
    }

    private func generateAudioWithRetry(forChunkAt index: Int) async throws -> Data {
        var attempt = 0
        while !Task.isCancelled {
            attempt += 1
            do {
                return try await MacArticleTTSClient.speech(
                    provider: mode,
                    text: audioChunks[index],
                    speed: MacArticleSpeechSpeed.defaultSpeed,
                    model: activeSpeechModel,
                    voice: activeSpeechVoice,
                    task: "read_aloud",
                    source: syncedAudioContext.map {
                        AIUsageSource(id: $0.sourceID, type: $0.sourceType, title: $0.title)
                    }
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                articleSpeechLogger.warning(
                    "Playback chunk \(index + 1) attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)"
                )
                let isPermanent = error is MacArticleTTSError
                guard !isPermanent, attempt < Self.maxChunkGenerationAttempts else {
                    articleSpeechLogger.error(
                        "Playback chunk \(index + 1) failed permanently after \(attempt) attempt(s)"
                    )
                    ArticleSpeechDiagnostics.append(
                        "PLAYBACK_CHUNK_FAILED index=\(index) attempts=\(attempt) \(error.localizedDescription)"
                    )
                    if let ttsError = error as? MacArticleTTSError, ttsError.abortsGeneration {
                        abortAudioGeneration(generationID: audioGenerationID, with: ttsError)
                    }
                    throw error
                }
                try await Task.sleep(nanoseconds: Self.chunkRetryDelayNanoseconds(attempt: attempt))
            }
        }
        throw CancellationError()
    }

    private func finishPlayback(completedSuccessfully: Bool = false) {
        let finishedSourceID = activeArticleID
        // Anything short of a clean finish keeps the resume point: a network
        // failure mid-book must not lose the listener's place.
        let positionSnapshot = completedSuccessfully ? nil : capturePlaybackPositionSnapshot()

        cancelSleepTimer()
        clearNowPlayingInfo()
        playbackEpoch += 1
        playbackTask = nil
        audioPlayer = nil
        preloadedNextPlayer = nil
        audioGenerationID = UUID()
        preparationRequestID = UUID()
        foregroundGenerationChunksRemaining = 0
        prefetchTasks.values.forEach { $0.cancel() }
        prefetchTasks = [:]
        audioChunks = []
        audioChunkIndex = 0
        syncedChunkURLs = []
        completedSyncedChunks = []
        failedGenerationChunkCount = 0
        activeArticleID = nil
        preparingArticleID = nil
        nowPlayingTitle = nil
        nowPlayingSubtitle = nil
        syncedAudioContext = nil
        audioGenerationProgress = nil
        preparationStatus = nil
        isPlaying = false
        isPaused = false
        isLoading = false
        hasStartedPlayback = false
        highestReadyChunkIndex = -1
        pendingResumeGlobalTime = nil
        pendingResumeAppleCharacterOffset = nil
        activeNarrationSignature = nil
        appleSpeechBaseCharacterOffset = 0
        appleSpeechCharacterOffset = 0
        lastPlaybackPositionSaveAt = nil
        lastAccountPositionSaveAt = nil
        resetPlaybackPosition()

        if completedSuccessfully, let finishedSourceID {
            let sourceID = finishedSourceID
            Task.detached(priority: .utility) { [activityStorage] in
                await Self.clearListenPosition(sourceID: sourceID, storage: activityStorage)
            }
            Task { [activityStorage] in
                do {
                    try await activityStorage.recordScheduledSourceCompletion(
                        sourceID: sourceID,
                        on: Date(),
                        kind: .listening
                    )
                    NotificationCenter.default.post(
                        name: .sourceListeningCompletionDidChange,
                        object: sourceID
                    )
                } catch {
                    articleSpeechLogger.error(
                        "Failed to log completed listening for \(sourceID, privacy: .public): \(error.localizedDescription)"
                    )
                }
            }
            finishedListeningArticleID = finishedSourceID
        } else if let finishedSourceID, let positionSnapshot {
            persistPlaybackPosition(positionSnapshot, sourceID: finishedSourceID)
        }
    }

    /// Consumes the finished-listening event so exactly one reader host
    /// auto-advances to the next chapter, even when several observe the service.
    func consumeFinishedListening(articleID: String) -> Bool {
        guard finishedListeningArticleID == articleID else { return false }
        finishedListeningArticleID = nil
        return true
    }

    @discardableResult
    private func applyPendingResumeIfNeeded() async -> Bool {
        guard mode.isCloudProvider else { return false }
        guard let resumeTime = pendingResumeGlobalTime,
              resumeTime >= Self.minimumResumeInterval else {
            pendingResumeGlobalTime = nil
            return false
        }

        for _ in 0..<50 {
            if playbackDuration > 0 || !chunkDurations.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(100))
        }

        let duration = playbackDuration
        guard duration <= 0 || resumeTime < duration - Self.completionResumeThreshold else {
            pendingResumeGlobalTime = nil
            if let sourceID = activeArticleID {
                let sourceIDCopy = sourceID
                Task.detached(priority: .utility) { [activityStorage] in
                    await Self.clearListenPosition(sourceID: sourceIDCopy, storage: activityStorage)
                }
            }
            return false
        }

        pendingResumeGlobalTime = nil
        let clamped = duration > 0 ? min(resumeTime, max(0, duration - 1)) : resumeTime
        let target = location(forGlobalTime: clamped)
        let availableLimit = availableSeekChunkLimit()
        guard target.chunkIndex <= availableLimit else { return false }

        await jumpToChunk(target.chunkIndex, offset: target.offset)
        return true
    }

    private func shouldPersistPosition(time: TimeInterval, duration: TimeInterval) -> Bool {
        guard time >= Self.minimumResumeInterval else { return false }
        guard duration > 0 else { return true }
        return time < duration - Self.completionResumeThreshold
    }

    private func capturePlaybackPositionSnapshot() -> ArticleSpeechPlaybackPosition? {
        guard activeArticleID != nil,
              isPlaying || isPaused,
              hasStartedPlayback || mode == .apple else {
            return nil
        }

        if mode == .apple {
            guard appleSpeechCharacterOffset > 0 else { return nil }
            return ArticleSpeechPlaybackPosition(
                globalTime: 0,
                appleCharacterOffset: appleSpeechCharacterOffset,
                contentSignature: activeNarrationSignature,
                updatedAt: Date()
            )
        }

        let time = currentGlobalPlaybackTime()
        guard shouldPersistPosition(time: time, duration: playbackDuration) else { return nil }
        return ArticleSpeechPlaybackPosition(
            globalTime: time,
            appleCharacterOffset: nil,
            contentSignature: activeNarrationSignature,
            updatedAt: Date()
        )
    }

    private func schedulePlaybackPositionSave() {
        guard mode.isCloudProvider || mode == .apple else { return }
        guard activeArticleID != nil, hasStartedPlayback || mode == .apple else { return }
        if let last = lastPlaybackPositionSaveAt,
           Date().timeIntervalSince(last) < Self.playbackPositionSaveInterval {
            return
        }
        savePlaybackPositionNow()
    }

    private func savePlaybackPositionNow() {
        guard let sourceID = activeArticleID,
              let snapshot = capturePlaybackPositionSnapshot() else { return }
        let now = Date()
        lastPlaybackPositionSaveAt = now
        // A pause is the moment the listener is most likely to reach for the
        // other device, so it publishes at once; steady playback republishes
        // on the account interval.
        let publishesToAccount = isPaused
            || lastAccountPositionSaveAt.map {
                now.timeIntervalSince($0) >= ListeningPositionSync.accountSaveInterval
            } ?? true
        persistPlaybackPosition(snapshot, sourceID: sourceID, toAccount: publishesToAccount)
        recordListeningDepth(sourceID: sourceID)
    }

    /// Promote resumable playback position into durable consumption evidence.
    ///
    /// Abandoning a podcast at 70% previously left nothing behind but a resume
    /// locator, so the memory companion could not tell it apart from an episode
    /// that was never opened. Depth rides the same throttle as the position
    /// save, and completion separately records 1.0.
    ///
    /// Deliberately skipped while the duration is still extrapolated from the
    /// chunks generated so far: depth merges with MAX and never decreases, so a
    /// single inflated sample against an underestimated duration would stick
    /// permanently. Apple's local voice reports no duration and so records
    /// nothing here — its progress is a character offset, not a time.
    private func recordListeningDepth(sourceID: String) {
        // Time listened accrues in slices between position saves while playing:
        // the ledger's engaged seconds for text-to-speech. A slice is capped at two
        // save intervals so a sleep or a stall cannot book hours.
        let now = Date()
        var listened = 0.0
        if isPlaying, !isPaused {
            if let last = lastListeningTickAt, lastListeningTickSourceID == sourceID {
                listened = min(max(0, now.timeIntervalSince(last)), 2 * Self.playbackPositionSaveInterval)
            }
            lastListeningTickAt = now
            lastListeningTickSourceID = sourceID
        } else {
            lastListeningTickAt = nil
            lastListeningTickSourceID = nil
        }
        // Depth is skipped while the duration is still an estimate; time is
        // honest either way.
        let fraction: Double? = isPlaybackDurationEstimated || playbackFraction <= 0 ? nil : playbackFraction
        guard fraction != nil || listened > 0 else { return }
        let title = nowPlayingTitle ?? ""
        Task { [activityStorage] in
            do {
                try await activityStorage.recordScheduledSourceActivity(
                    sourceID: sourceID,
                    on: now,
                    kind: .listening,
                    fraction: fraction,
                    engagedSeconds: listened
                )
            } catch {
                articleSpeechLogger.error(
                    "Failed to log listening depth for \(sourceID, privacy: .public): \(error.localizedDescription)"
                )
            }
            // The day's log, which History and the Activity pane draw as time: a
            // minute heard aloud is a minute on the clock, whether or not the
            // Reader is open on the source.
            guard listened > 0 else { return }
            do {
                try await activityStorage.recordDayActivity(kind: .listening, targetID: sourceID, title: title, at: now)
            } catch {
                articleSpeechLogger.error(
                    "Failed to log listening in the day's log for \(sourceID, privacy: .public): \(error.localizedDescription)"
                )
            }
        }
    }

    /// Saves the resume point beside the audio and, when `toAccount`, mirrors
    /// it to the account so another device resumes from it. Stop paths always
    /// mirror: they are the last word this device has on the position.
    private func persistPlaybackPosition(
        _ position: ArticleSpeechPlaybackPosition,
        sourceID: String,
        toAccount: Bool = true
    ) {
        if toAccount {
            lastAccountPositionSaveAt = Date()
        }
        Task.detached(priority: .utility) { [activityStorage] in
            try? SyncedArticleAudioStore.savePlaybackPosition(position, sourceID: sourceID)
            if toAccount {
                await SyncedArticleAudioStore.publishPlaybackPositionToAccount(position, sourceID: sourceID)
                // The account copy is the source's ReadingState (`listen.position.*` stays on this Mac).
                try? await activityStorage.saveListenPosition(position, sourceID: sourceID)
            }
        }
    }

    /// The account copy of a source's resume point under generation 2 (its ReadingState), read before
    /// playback is prepared; nil under generation 1, whose account copy `loadPlaybackPosition` reads.
    private func accountListenPosition(sourceID: String) async -> ArticleSpeechPlaybackPosition? {
        return try? await activityStorage.loadListenPosition(sourceID: sourceID)
    }

    /// Forgets a source's resume point everywhere: the file beside the audio, the account copy and,
    /// under generation 2, its ReadingState. The ReadingState goes first: when that write fails the
    /// local copy stays too, so the next play still finds the resume point at the end and forgets it
    /// again, rather than this Mac forgetting while every other device resumes from it.
    private nonisolated static func clearListenPosition(sourceID: String, storage: StorageService) async {
        do {
            try await storage.saveListenPosition(nil, sourceID: sourceID)
        } catch {
            articleSpeechLogger.error("Could not forget the resume point of \(sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        SyncedArticleAudioStore.clearPlaybackPosition(sourceID: sourceID)
    }

    /// Re-reads the stored configuration at the start of a listening session,
    /// so a provider or voice changed in Settings takes effect on the next
    /// Listen. This one is synchronous on purpose: it runs from a click rather
    /// than from launch, the vault is cached in memory by then, and narrating
    /// with a stale provider would be worse than the read. It supersedes any
    /// launch-time read still in flight.
    private func refreshConfiguration() {
        configurationEpoch += 1
        apply(.loadStored())
        appleVoiceIdentifier = MacArticleSpeechSettings.appleVoiceIdentifier
        speed = MacArticleSpeechSpeed.stored
    }

    private func recordAudioGenerationChunkSucceeded(
        generationID: UUID,
        chunkIndex: Int,
        attempt: Int,
        byteCount: Int
    ) {
        guard generationID == audioGenerationID else {
            recordDetachedGenerationChunkSucceeded(
                generationID: generationID,
                chunkIndex: chunkIndex,
                byteCount: byteCount
            )
            return
        }
        guard !completedSyncedChunks.contains(where: { $0.index == chunkIndex }) else { return }

        foregroundGenerationChunksRemaining = max(0, foregroundGenerationChunksRemaining - 1)
        highestReadyChunkIndex = max(highestReadyChunkIndex, chunkIndex)

        if chunkIndex == 0 {
            prefetchRemainingAudioChunks(generationID: generationID)
        }

        if let context = syncedAudioContext {
            completedSyncedChunks.append(SyncedArticleAudioManifest.Chunk(
                index: chunkIndex,
                fileName: SyncedArticleAudioStore.chunkFileName(
                    index: chunkIndex,
                    fileExtension: context.fileExtension
                ),
                byteCount: byteCount,
                text: chunkIndex < audioChunks.count ? audioChunks[chunkIndex] : nil
            ))
            if completedSyncedChunks.count == audioChunks.count {
                writeSyncedAudioManifest(chunks: completedSyncedChunks)
                let sourceID = context.sourceID
                Task.detached(priority: .utility) {
                    ArticleSpeechAudioCache.markCached(articleID: sourceID)
                }
            }
        }

        // The chunk now lives in the synced store and the per-request disk cache,
        // so the in-memory prefetch result can be released — holding every task's
        // Data kept a whole chapter of audio (WAV for Orpheus) resident in RAM.
        // Keep only the chunk playback is about to consume and the preload target.
        if chunkIndex < audioChunkIndex || chunkIndex > audioChunkIndex + 1 {
            prefetchTasks[chunkIndex] = nil
        }

        if var progress = audioGenerationProgress,
           progress.completedChunks < progress.totalChunks {
            progress.completedChunks += 1
            deferPublishedUpdate { [weak self] in
                guard var current = self?.audioGenerationProgress,
                      current.completedChunks < current.totalChunks else { return }
                current.completedChunks = progress.completedChunks
                self?.audioGenerationProgress = current
            }
            if attempt > 1 {
                articleSpeechLogger.info(
                    "Chunk \(chunkIndex + 1)/\(progress.totalChunks) ready after \(attempt) attempts"
                )
            } else {
                articleSpeechLogger.debug(
                    "Chunk \(chunkIndex + 1)/\(progress.totalChunks) ready"
                )
            }
            if progress.isComplete {
                articleSpeechLogger.info(
                    "Text-to-speech generation finished: \(progress.totalChunks) chunks"
                )
                loadAllChunkDurations()
            }
        }
    }

    /// Bookkeeping for a chunk that finished after its generation was detached.
    /// Mirrors the active-generation path minus playback and progress UI, and
    /// writes the synced manifest once the last chunk lands.
    private func recordDetachedGenerationChunkSucceeded(
        generationID: UUID,
        chunkIndex: Int,
        byteCount: Int
    ) {
        guard var generation = detachedGenerations[generationID] else { return }
        // The chunk is on disk; releasing the task handle frees its audio Data.
        generation.tasks[chunkIndex] = nil
        if !generation.completedChunks.contains(where: { $0.index == chunkIndex }) {
            generation.completedChunks.append(SyncedArticleAudioManifest.Chunk(
                index: chunkIndex,
                fileName: SyncedArticleAudioStore.chunkFileName(
                    index: chunkIndex,
                    fileExtension: generation.context.fileExtension
                ),
                byteCount: byteCount,
                text: chunkIndex < generation.chunkTexts.count ? generation.chunkTexts[chunkIndex] : nil
            ))
        }
        detachedGenerations[generationID] = generation
        backgroundGenerationProgress[generation.context.sourceID] = ArticleSpeechChunkProgress(
            completedChunks: generation.completedChunks.count,
            totalChunks: generation.chunkTexts.count,
            failedChunks: generation.failedChunkCount
        )

        if !generation.hasScheduledRemainingChunks {
            scheduleRemainingDetachedChunks(generationID: generationID)
        }

        if generation.completedChunks.count == generation.chunkTexts.count {
            finishDetachedGeneration(generationID: generationID)
        } else if Self.isEveryChunkAccountedFor(generation) {
            endIncompleteDetachedGeneration(generationID: generationID)
        }
    }

    /// Schedules the chunks a detached generation never started because the
    /// listener switched away while the lead chunk was still in flight.
    private func scheduleRemainingDetachedChunks(generationID: UUID) {
        guard var generation = detachedGenerations[generationID],
              !generation.hasScheduledRemainingChunks else { return }
        generation.hasScheduledRemainingChunks = true
        detachedGenerations[generationID] = generation
        fillMissingDetachedChunkTasks(generationID: generationID)
    }

    /// Creates a chunk task for every index that has neither a running task
    /// nor a completed chunk on disk.
    private func fillMissingDetachedChunkTasks(generationID: UUID) {
        guard var generation = detachedGenerations[generationID] else { return }

        let permitPool = ArticleSpeechAudioCachePermitPool(
            limit: Self.backgroundAudioCacheConcurrency(for: generation.context.provider)
        )
        for index in 0..<generation.chunkTexts.count
        where generation.tasks[index] == nil
            && !generation.completedChunks.contains(where: { $0.index == index }) {
            generation.tasks[index] = makeChunkGenerationTask(
                text: generation.chunkTexts[index],
                index: index,
                provider: generation.context.provider,
                model: generation.context.model,
                voice: generation.context.voice,
                syncedContext: generation.context,
                permitPool: permitPool,
                generationID: generationID
            )
        }
        detachedGenerations[generationID] = generation
    }

    private func finishDetachedGeneration(generationID: UUID) {
        guard let generation = detachedGenerations.removeValue(forKey: generationID) else { return }
        let context = generation.context
        if !detachedGenerations.values.contains(where: { $0.context.sourceID == context.sourceID }) {
            backgroundGenerationSourceIDs.remove(context.sourceID)
        }
        let chunks = generation.completedChunks
        articleSpeechLogger.info(
            "Background text-to-speech generation finished: \(chunks.count) chunks for \(context.sourceID)"
        )
        ArticleSpeechDiagnostics.append(
            "BACKGROUND_GENERATION_FINISHED source=\(context.sourceID) chunks=\(chunks.count)"
        )
        Task.detached(priority: .utility) { [weak self] in
            if let failure = Self.persistSyncedAudio(context: context, chunks: chunks) {
                await MainActor.run { [weak self] in
                    self?.errorMessage = failure
                    self?.noteBackgroundGenerationEnded(sourceID: context.sourceID, outcome: .failed(failure))
                }
            } else {
                ArticleSpeechAudioCache.markCached(articleID: context.sourceID)
                await MainActor.run { [weak self] in
                    self?.noteBackgroundGenerationEnded(sourceID: context.sourceID, outcome: .ready)
                }
            }
        }
    }

    private func recordAudioGenerationChunkFailed(generationID: UUID, chunkIndex: Int) {
        guard generationID == audioGenerationID else {
            recordDetachedGenerationChunkFailed(generationID: generationID)
            return
        }
        failedGenerationChunkCount += 1
        foregroundGenerationChunksRemaining = max(0, foregroundGenerationChunksRemaining - 1)
        if chunkIndex == 0 {
            // The opening owns the first-audio gate, so no continuation chunks
            // were scheduled. End generation UI now; playback surfaces the
            // actual error instead of leaving a zero-percent spinner behind.
            deferPublishedUpdate { [weak self] in
                self?.audioGenerationProgress = nil
            }
            return
        }
        // Progress can never reach 100% once a chunk failed permanently. Drop the
        // generation UI instead of spinning forever — the failure itself surfaces
        // (and pauses playback in place) when the listener reaches that chunk.
        if let progress = audioGenerationProgress,
           progress.completedChunks + failedGenerationChunkCount >= progress.totalChunks {
            deferPublishedUpdate { [weak self] in
                self?.audioGenerationProgress = nil
            }
        }
    }

    private func recordDetachedGenerationChunkFailed(generationID: UUID) {
        guard var generation = detachedGenerations[generationID] else { return }
        generation.failedChunkCount += 1
        detachedGenerations[generationID] = generation
        backgroundGenerationProgress[generation.context.sourceID] = ArticleSpeechChunkProgress(
            completedChunks: generation.completedChunks.count,
            totalChunks: generation.chunkTexts.count,
            failedChunks: generation.failedChunkCount
        )
        // The manifest can never be written once a chunk failed permanently.
        // Let the other in-flight chunks land in the request cache, but once
        // every chunk is accounted for — or the lead chunk failed before the
        // rest were even scheduled — drop the record. Completed chunks stay
        // cached, so a later Listen only regenerates the failed ones.
        let isUnschedulable = !generation.hasScheduledRemainingChunks
        if isUnschedulable || Self.isEveryChunkAccountedFor(generation) {
            endIncompleteDetachedGeneration(generationID: generationID)
        }
    }

    private static func isEveryChunkAccountedFor(_ generation: DetachedAudioGeneration) -> Bool {
        generation.completedChunks.count + generation.failedChunkCount >= generation.chunkTexts.count
    }

    /// Ends a background run that has failed parts and nothing left in
    /// flight. Either the last failure or the last success can be the one
    /// that settles it: a run whose final part landed after its failures used
    /// to wait for ever at 98%, since only a failure asked.
    private func endIncompleteDetachedGeneration(generationID: UUID) {
        guard var generation = detachedGenerations[generationID] else { return }
        // Before giving up, ask for the failed parts once more: the rest are
        // cached, so only they are made (and billed), and a provider that
        // answered one part empty usually answers it the second time.
        if !generation.hasRetriedFailedChunks, generation.hasScheduledRemainingChunks,
           generation.failedChunkCount > 0 {
            generation.hasRetriedFailedChunks = true
            generation.failedChunkCount = 0
            backgroundGenerationProgress[generation.context.sourceID] = ArticleSpeechChunkProgress(
                completedChunks: generation.completedChunks.count,
                totalChunks: generation.chunkTexts.count
            )
            let landed = Set(generation.completedChunks.map(\.index))
            for index in Array(generation.tasks.keys) where !landed.contains(index) {
                generation.tasks[index] = nil
            }
            detachedGenerations[generationID] = generation
            ArticleSpeechDiagnostics.append(
                "BACKGROUND_GENERATION_RETRYING_FAILED source=\(generation.context.sourceID) missing=\(generation.chunkTexts.count - landed.count)"
            )
            narrationStages[generation.context.sourceID] = "Retrying the parts that failed"
            fillMissingDetachedChunkTasks(generationID: generationID)
            return
        }
        articleSpeechLogger.error(
            "Background text-to-speech generation for \(generation.context.sourceID) ended with \(generation.failedChunkCount) failed chunk(s)"
        )
        ArticleSpeechDiagnostics.append(
            "BACKGROUND_GENERATION_INCOMPLETE source=\(generation.context.sourceID) failed=\(generation.failedChunkCount)"
        )
        let message = "Audio generation for \(generation.context.title) could not finish."
        errorMessage = message
        // The parts that landed stay: the next Listen or Generate Audio asks
        // for only the ones that are missing.
        cancelDetachedGeneration(
            generationID: generationID,
            cleaningUpPartialAudio: false,
            outcome: .failed(message)
        )
    }

    /// Stops the whole generation after a provider rejection (bad key, dead
    /// credits, billing failure): every remaining chunk request would fail the
    /// same way, so cancelling them avoids hammering the provider with
    /// per-chunk retries. Audio that already arrived keeps playing; the error
    /// surfaces immediately in the player UI.
    private func abortAudioGeneration(generationID: UUID, with error: Error) {
        guard generationID == audioGenerationID else {
            if detachedGenerations[generationID] != nil {
                articleSpeechLogger.error(
                    "Background text-to-speech generation aborted: \(error.localizedDescription, privacy: .public)"
                )
                ArticleSpeechDiagnostics.append(
                    "BACKGROUND_GENERATION_ABORTED \(error.localizedDescription)"
                )
                cancelDetachedGeneration(
                    generationID: generationID,
                    outcome: .failed(error.localizedDescription)
                )
            }
            return
        }
        let message = error.localizedDescription
        articleSpeechLogger.error(
            "Text-to-speech generation aborted: \(message, privacy: .public)"
        )
        ArticleSpeechDiagnostics.append("GENERATION_ABORTED \(message)")
        audioGenerationID = UUID()
        foregroundGenerationChunksRemaining = 0
        prefetchTasks.values.forEach { $0.cancel() }
        prefetchTasks = [:]
        deferPublishedUpdate { [weak self] in
            guard let self else { return }
            self.audioGenerationProgress = nil
            self.errorMessage = message
            // Every caller aborts with a `MacArticleTTSError`; the default only
            // covers a future one that does not.
            self.errorSuggestsProviderSwitch =
                (error as? MacArticleTTSError)?.suggestsProviderSwitch ?? true
            if !self.hasStartedPlayback {
                // Nothing is playing and nothing further will arrive — stop
                // the "waiting for first chunk" spinner in place.
                self.isLoading = false
                self.isPaused = true
                self.savePlaybackPositionNow()
                self.updateNowPlayingInfo()
            }
        }
    }

    private func applyAudioPlaybackRate() {
        guard mode.isCloudProvider, let audioPlayer else { return }
        audioPlayer.enableRate = true
        audioPlayer.rate = Self.audioPlaybackRate(for: speed)
        updateNowPlayingInfo()
    }

    private func installRemoteCommandHandlers() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                self.pauseOrResume()
            }
            return .success
        }

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying, self.isPaused else { return }
                self.pauseOrResume()
            }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying, !self.isPaused else { return }
                self.pauseOrResume()
            }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor [weak self] in
                self?.seek(to: event.positionTime)
            }
            return .success
        }

        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.skipForward()
            }
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.skipBackward()
            }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard isPlaying, let title = nowPlayingTitle else {
            clearNowPlayingInfo()
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "ForeverLM",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: playbackCurrentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0 : playbackNowPlayingRate
        ]
        if playbackDuration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = playbackDuration
        }
        // The book (or author) reads as the album line under the title.
        if let subtitle = nowPlayingSubtitle, !subtitle.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = subtitle
        }
        if let nowPlayingArtwork, nowPlayingArtworkSourceID == activeArticleID {
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        if #available(macOS 12.0, *) {
            MPNowPlayingInfoCenter.default().playbackState = isPaused ? .paused : .playing
        }
    }

    private var playbackNowPlayingRate: Double {
        if mode == .apple {
            return isPaused ? 0 : 1
        }
        return Double(Self.audioPlaybackRate(for: speed))
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if #available(macOS 12.0, *) {
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        }
    }

    private func writeSyncedAudioManifest(chunks: [SyncedArticleAudioManifest.Chunk]) {
        guard let context = syncedAudioContext,
              !chunks.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            if let failure = Self.persistSyncedAudio(context: context, chunks: chunks) {
                await MainActor.run { [weak self] in self?.errorMessage = failure }
            }
        }
    }

    private func writeSyncedAudioManifestFromSavedChunks() {
        guard let context = syncedAudioContext,
              !audioChunks.isEmpty else { return }
        let chunkCount = audioChunks.count
        let chunkTexts = audioChunks

        Task.detached(priority: .utility) { [weak self] in
            let chunks: [SyncedArticleAudioManifest.Chunk] = (0..<chunkCount).compactMap { index in
                let url = SyncedArticleAudioStore.chunkURL(
                    sourceID: context.sourceID,
                    index: index,
                    fileExtension: context.fileExtension
                )
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                guard size > 0 else { return nil }
                return SyncedArticleAudioManifest.Chunk(
                    index: index,
                    fileName: url.lastPathComponent,
                    byteCount: size,
                    text: index < chunkTexts.count ? chunkTexts[index] : nil
                )
            }

            guard chunks.count == chunkCount else { return }
            if let failure = Self.persistSyncedAudio(context: context, chunks: chunks) {
                await MainActor.run { [weak self] in self?.errorMessage = failure }
            }
        }
    }

    /// Verify every chunk file exists, then write the synced source text and manifest.
    /// Blocking file I/O against the iCloud-synced Audio folder — never call on the main actor.
    private nonisolated static func persistSyncedAudio(
        context: SyncedArticleAudioContext,
        chunks: [SyncedArticleAudioManifest.Chunk]
    ) -> String? {
        let sortedChunks = chunks.sorted { $0.index < $1.index }
        let chunkDirectory = SyncedArticleAudioStore.sourceDirectory(sourceID: context.sourceID)
            .appendingPathComponent(SyncedArticleAudioStore.chunksDirectoryName, isDirectory: true)
        guard sortedChunks.allSatisfy({
            FileManager.default.fileExists(atPath: chunkDirectory.appendingPathComponent($0.fileName).path)
        }) else { return nil }

        let manifest = SyncedArticleAudioManifest(
            schemaVersion: SyncedArticleAudioManifest.schemaVersion,
            sourceID: context.sourceID,
            title: context.title,
            subtitle: context.subtitle,
            sourceType: context.sourceType,
            sourceURL: context.sourceURL,
            provider: context.provider.rawValue,
            model: context.model,
            voice: context.voice,
            voiceLabel: context.voiceLabel,
            contentSignature: context.contentSignature,
            totalCharacters: context.totalCharacters,
            createdAt: context.createdAt,
            chunks: sortedChunks,
            sourceTextFileName: SyncedArticleAudioStore.sourceTextFileName,
            narrationVersion: context.sourceType == StudioSourceType.paper.rawValue
                ? PaperNarrationFilter.version
                : nil,
            sourceContentSignature: context.sourceContentSignature,
            narrationPreparationSignature: context.narrationPreparationSignature,
            generatedOnPlatform: "macos"
        )

        do {
            try SyncedArticleAudioStore.saveSourceText(context.sourceText, sourceID: context.sourceID)
            try SyncedArticleAudioStore.saveManifest(manifest)
            ArticleSpeechAudioCache.markCached(articleID: context.sourceID)
            // Opportunistic housekeeping while already off-main: the per-request
            // cache is otherwise append-only and would grow without bound.
            ArticleSpeechAudioCache.pruneStaleEntries()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Splits already-cleaned narration text into provider-sized chunks. Takes
    /// the output of `MacArticleSpeechText.narrationText(from:)` so callers that
    /// computed it once (off-main) do not pay for the cleanup regexes again.
    /// `leadChunkCount` opening chunks are held to `firstChunkMaxLength` — a few
    /// sentences each — before full-size chunks take over. One short chunk only
    /// buys the first word; the chunks right behind it are the ones playback
    /// runs into next, and at full size they arrive slower than they are heard.
    nonisolated static func narrationChunks(
        from reflowed: String,
        maxLength: Int,
        firstChunkMaxLength: Int? = nil,
        leadChunkCount: Int = 1
    ) -> [String] {
        var chunks: [String] = []
        var current = ""
        let leadLimit = min(firstChunkMaxLength ?? maxLength, maxLength)
        let leadChunks = max(leadChunkCount, 0)
        func limit(forChunkAt index: Int) -> Int {
            index < leadChunks ? leadLimit : maxLength
        }
        var currentLimit = limit(forChunkAt: 0)

        func flushCurrent() {
            guard !current.isEmpty else { return }
            chunks.append(current)
            current = ""
            currentLimit = limit(forChunkAt: chunks.count)
        }

        let paragraphs = reflowed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for paragraph in paragraphs {
            // Paragraphs are indivisible whenever the provider limit permits,
            // but several consecutive paragraphs share one synthesis request.
            // The extra context lets the voice carry pacing and intonation
            // forward instead of restarting its prosody after every paragraph.
            let fillingLeadChunk = currentLimit < maxLength
            let candidate = current.isEmpty ? paragraph : "\(current)\n\n\(paragraph)"
            if candidate.count <= currentLimit {
                current = candidate
                continue
            }

            // The paragraph won't fit on the open chunk. Close the accumulated
            // paragraphs and start this one on a fresh request. The fast lead is
            // the exception: flushing it underfilled can ship a bare heading, so
            // fill its remaining room with whole sentences from the first body
            // paragraph and start playback promptly.
            if !fillingLeadChunk {
                flushCurrent()
                if paragraph.count <= currentLimit {
                    current = paragraph
                    continue
                }
            }

            // Pack whole sentences so any split lands at a sentence boundary — a
            // natural pause — instead of mid-sentence. This matters most for
            // Orpheus's tiny 180-char chunks, where every chunk boundary is an
            // audible gap between separately generated audio clips.
            var joiner = "\n\n"
            for sentence in MacArticleSpeechText.sentences(in: paragraph) {
                let sentenceCandidate = current.isEmpty ? sentence : "\(current)\(joiner)\(sentence)"
                joiner = " "
                if sentenceCandidate.count <= currentLimit {
                    current = sentenceCandidate
                } else {
                    flushCurrent()
                    if sentence.count <= currentLimit {
                        current = sentence
                    } else {
                        // A single sentence longer than the limit still has to be
                        // broken; fall back to word boundaries for just this sentence.
                        chunks.append(contentsOf: wordChunks(
                            sentence,
                            maxLength: maxLength,
                            firstChunkMaxLength: currentLimit
                        ))
                        current = ""
                        currentLimit = limit(forChunkAt: chunks.count)
                    }
                }
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks.compactMap { MacArticleSpeechText.speakableInput(from: $0) }
    }

    private nonisolated static func wordChunks(_ text: String, maxLength: Int, firstChunkMaxLength: Int? = nil) -> [String] {
        var result: [String] = []
        var current = ""
        var currentLimit = min(firstChunkMaxLength ?? maxLength, maxLength)

        for word in text.split(separator: " ") {
            let candidate = current.isEmpty ? String(word) : "\(current) \(word)"
            if candidate.count <= currentLimit {
                current = candidate
            } else {
                if !current.isEmpty {
                    result.append(current)
                    currentLimit = maxLength
                }
                current = String(word)
            }
        }

        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    private static func appleSpeechRate(for speed: Double) -> Float {
        let normalReadingRate: Float = 0.16
        let scaledRate = normalReadingRate * Float(MacArticleSpeechSpeed.clamped(speed))
        return min(max(scaledRate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    private static func audioPlaybackRate(for speed: Double) -> Float {
        min(max(Float(MacArticleSpeechSpeed.clamped(speed)), 0.5), 2.0)
    }

    private static func syncedAudioFileExtension(provider: MacArticleSpeechMode, model: String) -> String {
        switch provider {
        case .groq:
            return model.hasPrefix("canopylabs/orpheus") ? "wav" : "mp3"
        case .openRouter:
            return ArticleSpeechCatalog.model(id: model)?.responseFormat.storedFileExtension ?? "mp3"
        case .openAI, .togetherAI, .elevenLabs, .xai:
            return "mp3"
        case .gemini:
            // Gemini returns raw PCM; the client transcodes it to AAC in an m4a container.
            return "m4a"
        case .localQwen3:
            return "wav"
        case .apple:
            return "mp3"
        }
    }

    private nonisolated static func isOrpheusModel(_ model: String) -> Bool {
        model.hasPrefix("canopylabs/orpheus")
    }

    /// `model` is the model this generation will actually use, which is not
    /// always the stored selection: a source in another language can be routed
    /// to a voice that speaks it, and the chunk plan has to follow.
    private nonisolated static func chunkLimit(
        for provider: MacArticleSpeechMode,
        model: String
    ) -> Int {
        switch provider {
        case .openRouter:
            // Orpheus keeps its short-input limit on every host; the rest of
            // the OpenRouter catalog carries its own per-model unit size, which
            // the iPhone reads from the same place.
            if isOrpheusModel(model) { return orpheusChunkLimit }
            return ArticleSpeechCatalog.chunkLimit(forModel: model)
        case .groq:
            return isOrpheusModel(MacArticleSpeechSettings.groqModel) ? orpheusChunkLimit : 4_000
        case .openAI:
            // Smaller chunks generate faster, so each later segment is ready well before
            // playback reaches it — keeps audio gapless after the quick first-chunk start.
            return 2_000
        case .togetherAI:
            // The default TogetherAI model is canopylabs/orpheus-3b, which has the same
            // short-input limit as Groq's Orpheus; only the non-Orpheus voices
            // (Cartesia, Rime, Minimax) can take the larger chunk.
            return isOrpheusModel(MacArticleSpeechSettings.togetherAIModel) ? orpheusChunkLimit : 3_000
        case .elevenLabs:
            let model = MacArticleSpeechSettings.elevenLabsModel
            if model == "eleven_v3" {
                return 2_800
            }
            if model == "eleven_multilingual_v2" {
                return 8_000
            }
            if model.contains("flash") || model.contains("turbo") {
                return 8_000
            }
            return 5_000
        case .xai:
            return 14_000
        case .gemini:
            // The TTS models take up to a 32k-token session; chunks stay small so
            // seek and resume keep paragraph granularity.
            return 3_500
        case .localQwen3:
            return 1_500
        case .apple:
            return 3_500
        }
    }

    private nonisolated static func leadChunkLimit(
        for provider: MacArticleSpeechMode,
        model: String
    ) -> Int {
        switch provider {
        case .openAI, .gemini:
            // gpt-4o-mini-tts and Gemini TTS latency scale with input length, so a
            // shorter lead chunk gets the first audio playing noticeably sooner.
            return 500
        case .openRouter:
            return isOrpheusModel(model)
                ? playbackLeadChunkLimit
                : ArticleSpeechCatalog.leadChunkLimit(forModel: model)
        case .groq, .togetherAI, .elevenLabs, .xai, .localQwen3, .apple:
            return playbackLeadChunkLimit
        }
    }

    /// How many opening chunks stay at the lead size. Three short requests get
    /// audio playing and keep the buffer ahead of the playhead through the first
    /// minute, which is where a fresh source used to run dry.
    private nonisolated static func leadChunkCount(for provider: MacArticleSpeechMode) -> Int {
        switch provider {
        case .apple:
            // Local synthesis has no per-request latency to hide.
            return 1
        case .openRouter, .groq, .openAI, .togetherAI, .elevenLabs, .xai, .gemini, .localQwen3:
            return 3
        }
    }

    private nonisolated static func firstChunkLimit(
        for provider: MacArticleSpeechMode,
        model: String
    ) -> Int? {
        let maxLength = chunkLimit(for: provider, model: model)
        let leadLimit = leadChunkLimit(for: provider, model: model)
        guard maxLength > leadLimit else { return nil }
        return leadLimit
    }

    private nonisolated static let maxChunkGenerationAttempts = 8

    private nonisolated static func chunkRetryDelayNanoseconds(attempt: Int) -> UInt64 {
        let seconds = min(pow(2.0, Double(attempt - 1)), 16.0) + Double.random(in: 0.25...1.0)
        return UInt64(seconds * 1_000_000_000)
    }

    private static func backgroundAudioCacheConcurrency(for provider: MacArticleSpeechMode) -> Int {
        switch provider {
        case .elevenLabs:
            return 4
        case .openRouter, .openAI, .togetherAI, .xai, .gemini:
            // A narration kept for later has nothing to play while it is made,
            // so how many parts are in flight sets how long the learner waits:
            // Gemini TTS takes ~45 s a part, a 100,000-character source is
            // ~125 parts, and six at a time was 30 minutes. The proxy admits 120
            // requests a minute a connection and a 429 is retried with backoff,
            // so 40 in flight is well inside both: a 105-part narration is
            // three rounds, not eighteen.
            return 40
        case .groq:
            return 8
        case .localQwen3:
            return 2
        case .apple:
            return 1
        }
    }

    private func providerVoiceLabel(
        provider: MacArticleSpeechMode,
        voice: String,
        model: String? = nil
    ) -> String {
        switch provider {
        case .openRouter:
            return ArticleSpeechCatalog.voiceLabel(
                model: model ?? MacArticleSpeechSettings.openRouterModel,
                voice: voice
            )
        case .elevenLabs:
            return MacArticleSpeechSettings.elevenLabsVoicePresets.first(where: { $0.id == voice })?.name ?? voice
        case .togetherAI:
            return voice.replacingOccurrences(of: "_", with: " ").capitalized
        case .groq:
            return voice.capitalized
        case .openAI:
            return voice.capitalized
        case .xai:
            return MacArticleSpeechSettings.xaiVoiceLabel(for: voice)
        case .gemini:
            return voice
        case .localQwen3:
            return voice.replacingOccurrences(of: "_", with: " ")
        case .apple:
            return MacArticleSpeechSettings.appleVoiceName(
                identifier: activeAppleVoiceIdentifier ?? appleVoiceIdentifier
            )
        }
    }

}

/// Bounds how many chunks generate at once, and hands each freed permit to the
/// chunk playback will reach soonest.
///
/// Arrival order carries no information here: every chunk task for a generation
/// starts in the same turn, so a plain FIFO queue admits them in whatever order
/// the scheduler happened to wake them — and a retry sends a chunk to the back.
/// That left the generator working on chunk 40 while playback sat waiting on
/// chunk 3.
private actor ArticleSpeechAudioCachePermitPool {
    private var available: Int
    private var waiters: [(order: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(limit: Int) {
        self.available = max(1, limit)
    }

    func acquire(order: Int) async {
        if available > 0 {
            available -= 1
            return
        }

        await withCheckedContinuation { continuation in
            let insertion = waiters.firstIndex { $0.order > order } ?? waiters.endIndex
            waiters.insert((order: order, continuation: continuation), at: insertion)
        }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }
}

extension ArticleSpeechService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            // A stale delegate callback from a player that was already replaced
            // (seek, stop, teardown race) must not advance or kill the session.
            guard self.activeArticleID != nil, player === self.audioPlayer else { return }
            if !flag {
                // One undecodable segment should not end a two-hour chapter;
                // log it and move on to the next segment.
                articleSpeechLogger.warning(
                    "Audio segment \(self.currentlyPlayingChunkIndex + 1) ended with a decode error; continuing with the next segment."
                )
            }
            await self.playNextChunk()
        }
    }
}

extension ArticleSpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            guard self.mode == .apple, self.isPlaying, self.activeArticleID != nil else { return }
            self.appleSpeechCharacterOffset = self.appleSpeechBaseCharacterOffset + characterRange.location
            self.schedulePlaybackPositionSave()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.finishPlayback(completedSuccessfully: true)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.finishPlayback()
        }
    }
}
#endif
