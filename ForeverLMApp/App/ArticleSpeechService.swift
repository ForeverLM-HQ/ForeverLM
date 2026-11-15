#if os(macOS)
import AVFoundation
import CoreAudio
import Foundation
import MediaPlayer
import os
import SwiftUI

let articleSpeechLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
    category: "ArticleSpeech"
)

struct SyncedArticleAudioContext {
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

struct PreparedListenablePlayback: Sendable {
    let content: String
    let sourceContentSignature: String?
    let narrationPreparationSignature: String?
}

/// A chunk generation that keeps running after playback moved to another
/// source. Owns the surviving chunk tasks and enough context to schedule the
/// chunks that were never started, so the whole source still ends up in the
/// synced audio store with a manifest. Only an explicit stop of that source
/// (stop/cancel buttons, cache deletion) or a permanent failure ends it early.
struct DetachedAudioGeneration {
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
    /// surface shares this object. A per-surface instance would register
    /// MPRemoteCommandCenter targets that are never removed, and two surfaces
    /// could narrate simultaneously.
    static let shared = ArticleSpeechService()
    let activityStorage = StorageService()
    /// When listening time was last booked to the ledger, and for which source.
    var lastListeningTickAt: Date?
    var lastListeningTickSourceID: String?
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
    var approvedBookGeneration: BookGenerationApproval?

    @Published var activeArticleID: String?
    @Published var preparingArticleID: String?
    @Published var nowPlayingTitle: String?
    /// The picture beside the title in the system's Now Playing surfaces, and
    /// the source it was rendered for, so a chapter that ended before its cover
    /// arrived never wears the next one's.
    var nowPlayingArtwork: MPMediaItemArtwork?
    var nowPlayingArtworkSourceID: String?
    @Published var nowPlayingSubtitle: String?
    @Published var isPlaying = false
    @Published var isPaused = false
    /// Watches the Mac's default output so Listen pauses when AirPods (or any
    /// Bluetooth headphones) stop being it, rather than carrying on out loud.
    var outputDeviceWatcher: MacDefaultAudioDevicesWatcher?
    var outputDeviceID = AudioDeviceID(kAudioObjectUnknown)
    var outputDeviceIsBluetooth = false
    @Published var isLoading = false
    /// Human-readable work currently blocking the first audible word. Published
    /// synchronously from `startTextToSpeech` so every Listen entry point visibly
    /// acknowledges the click before source, iCloud, or cache work begins.
    @Published var preparationStatus: String?
    @Published var audioGenerationProgress: ArticleSpeechChunkProgress?
    /// Sources whose cloud/local-file audio is being completed without owning
    /// playback. Source rows observe this lightweight ID set; chunk data and
    /// file work remain entirely outside SwiftUI state.
    @Published var backgroundGenerationSourceIDs: Set<String> = []
    /// How many parts of each background narration have landed, by source id,
    /// from the run starting until it ends (`noteBackgroundGenerationEnded`),
    /// so a Reader and a source row can say how far a narration being made
    /// has got. Changes once a part, not once a playback tick.
    @Published var backgroundGenerationProgress: [String: ArticleSpeechChunkProgress] = [:]
    /// What a narration being made is doing before its first part lands, by
    /// source id: "Cleaning up the text for easier listening", "Choosing the
    /// voice". The product owner, 2026-10-08: a bare "Making narration" for minutes told
    /// him nothing. Cleared when the run ends or never starts.
    @Published var narrationStages: [String: String] = [:]
    /// The narrations Listen is making (`listen(to:)`), until each ends.
    @Published var narrationRequests = SourceNarrationRequests()
    /// The source whose narration Listen made and that has just landed: the
    /// control still showing that source takes it (`consumeMadeNarration`)
    /// and starts playing. Left alone when no control is on screen for the
    /// source, because the learner has gone elsewhere and a narration that
    /// keeps going while they are away does not speak up when it lands.
    @Published var madeNarrationSourceID: String?
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
    var activeAppleVoiceIdentifier: String?
    /// Languages the listener has already been warned about and chosen to
    /// generate anyway, keyed by the book (or lone source) the answer covers.
    /// Listening auto-advances through a book's chapters, and one answer has to
    /// cover the book it was asked about.
    var acknowledgedUnnarratableLanguages: [String: String] = [:]
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
    nonisolated static let playbackLeadChunkLimit = 1_000
    static let minimumResumeInterval: TimeInterval = 3
    nonisolated static let completionResumeThreshold: TimeInterval = 10
    /// Positions are saved at most this often while audio plays. This is a
    /// throttle, not a debounce: the 250ms playback ticker must never keep
    /// resetting the timer, or a crash mid-listen loses the session's progress.
    static let playbackPositionSaveInterval: TimeInterval = 5
    // Orpheus TTS models (canopylabs/orpheus-*) generate a bounded number of audio
    // tokens per request, so any input longer than roughly a sentence gets truncated
    // or drifts into unrelated speech. Keep their chunks tiny regardless of provider.
    nonisolated static let orpheusChunkLimit = 180
    let synthesizer = AVSpeechSynthesizer()
    var audioPlayer: AVAudioPlayer?
    var audioChunks: [String] = []
    var audioChunkIndex = 0
    var prefetchTasks: [Int: Task<Data, Error>] = [:]
    /// Generations still running after their source stopped playing, keyed by
    /// the generation ID each chunk task captured. Chunk callbacks route here
    /// when the ID no longer matches `audioGenerationID`.
    var detachedGenerations: [UUID: DetachedAudioGeneration] = [:]
    var playbackTask: Task<Void, Never>?
    var audioGenerationID = UUID()
    /// Invalidates source/preflight work when Stop or another Listen request
    /// takes ownership before that asynchronous work returns.
    var preparationRequestID = UUID()
    /// Chunks the generation the listener is playing still has to produce.
    /// While this is nonzero, detached generations park their next request so
    /// the foreground generation gets the provider's full throughput — see
    /// `waitWhileYieldingToForegroundGeneration`.
    var foregroundGenerationChunksRemaining = 0
    /// Monotonic counter bumped by stop/finish/seek. Async continuations capture
    /// the epoch before awaiting and bail if it moved — this is the staleness
    /// guard for playback state. Task cancellation alone cannot be trusted here:
    /// jumpToChunk must not cancel `playbackTask` while running *inside*
    /// it: that self-cancels and silently kills every cross-chunk seek and resume.
    var playbackEpoch = 0
    var syncedAudioContext: SyncedArticleAudioContext?
    var syncedChunkURLs: [URL] = []
    /// The next chunk's player, created and buffered while the current chunk is
    /// still playing so the handoff at the chunk boundary is effectively gapless.
    var preloadedNextPlayer: (index: Int, player: AVAudioPlayer)?
    /// Manifest entries for chunks that finished generating this session,
    /// accumulated on the main actor as each prefetch completes.
    var completedSyncedChunks: [SyncedArticleAudioManifest.Chunk] = []
    var failedGenerationChunkCount = 0
    @Published var playbackCurrentTime: TimeInterval = 0
    @Published var playbackDuration: TimeInterval = 0
    /// Set when a source's narration finished playing to the end. Reader hosts
    /// observe this to auto-advance to the next chapter of a book.
    @Published var finishedListeningArticleID: String?
    var chunkDurations: [Int: TimeInterval] = [:]
    var currentlyPlayingChunkIndex = 0
    var playbackTimeUpdateTask: Task<Void, Never>?
    var chunkDurationLoadTask: Task<Void, Never>?
    var lastPlaybackPositionSaveAt: Date?
    /// When the account copy of the position was last published. The file
    /// beside the audio is written every few seconds; the CloudKit record only
    /// on this interval while playing, and at once on pause or stop.
    var lastAccountPositionSaveAt: Date?
    var pendingResumeGlobalTime: TimeInterval?
    var pendingResumeAppleCharacterOffset: Int?
    var activeNarrationSignature: String?
    var appleSpeechBaseCharacterOffset = 0
    var appleSpeechCharacterOffset = 0
    @Published var sleepTimerRemaining: TimeInterval?
    var sleepTimerTask: Task<Void, Never>?
    var sleepTimerEndsAt: Date?
    var hasStartedPlayback = false
    var highestReadyChunkIndex = -1

    /// Set while a stored snapshot is being copied into the published
    /// properties, so their `didSet` observers neither write the same value
    /// straight back to storage nor count the copy as a user edit.
    private var isAdoptingStoredConfiguration = false
    /// Bumped by every configuration write that did not come from adopting
    /// storage. `adoptStoredConfiguration` compares it against the value it
    /// captured before reading, so a snapshot delayed by a slow Keychain can
    /// never overwrite a choice the listener made in the meantime.
    var configurationEpoch = 0
    private var storedConfigurationTask: Task<Void, Never>?
    private var speechDirectoryObserver: NSObjectProtocol?

    override init() {
        // Deliberately reads no Keychain-backed setting. `shared` is created
        // during SwiftUI view construction — StudioAudiobookPlayerHost sits in
        // StudioView's overlay chain, and SourceReaderPanel, ArticleReaderView
        // and SourceReaderWindow each hold it as a stored `@ObservedObject` —
        // so anything blocking here blocks a view body. Reading the provider
        // from the keychain reaches `SecItemCopyMatching`, which raises a system
        // authorization dialog for an ACL-protected vault item and never
        // returns until it is answered: the app would hang with no window
        // painted, and an app-hosted test run (which can never answer it) would
        // time out before the test runner connected. Seed the compile-time product
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
        installOutputDeviceWatcher()
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
    /// this really buys is chrome — the mini player and the Settings pickers —
    /// showing the real selection before anyone listens.
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
    func apply(_ configuration: MacArticleSpeechConfiguration) {
        isAdoptingStoredConfiguration = true
        mode = configuration.provider
        selectedVoice = configuration.voice
        isAdoptingStoredConfiguration = false
    }

    /// Schedules `@Published` mutations on the next main-actor turn so they do not run during an in-flight SwiftUI view update.
    func deferPublishedUpdate(_ update: @escaping () -> Void) {
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
    var activeSpeechModel: String {
        syncedAudioContext?.model ?? MacArticleSpeechSettings.model(for: mode)
    }

    var activeSpeechVoice: String {
        syncedAudioContext?.voice ?? selectedVoice
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
