import AVFoundation
import Combine
import Foundation
import MediaPlayer
import OSLog

@MainActor
final class MobileAudioReviewViewModel: NSObject, ObservableObject {
    // One instance shared by every scene. The phone window scene and the CarPlay
    // scene must drive the same review session and audio engine: when the car
    // connects with the phone locked, the SwiftUI WindowGroup scene may never
    // connect, so the CarPlay scene reaches the session through this singleton
    // rather than through a scene-owned @StateObject.
    static let shared = MobileAudioReviewViewModel()

    // The first render precedes the app's launch task. Start in the state the
    // catalog is actually in so Home cannot briefly publish a false empty
    // library before `load()` has had a chance to run.
    @Published var isLoading = true
    @Published var items: [MobileAudioItem] = []
    @Published var currentItem: MobileAudioItem?
    /// Now Playing artwork for `currentItem`, and the source it belongs to.
    var nowPlayingArtwork: MPMediaItemArtwork?
    var nowPlayingArtworkSourceID: String?
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var speed: Float
    @Published var isSiriVoiceSessionActive = false
    @Published var isSourceChatActive = false
    @Published var isChatResponding = false
    @Published var activeChatTitle: String?
    @Published var lastVoiceCommand: String?
    @Published var hasOpenAIKey: Bool
    @Published var allSources: [MobileCloudSource] = [] {
        didSet {
            sourcesByID = Dictionary(allSources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }
    /// `allSources` by id, kept beside it: Home asks every notebook's sources
    /// on each render, and playback republishes the model twice a second.
    private(set) var sourcesByID: [String: MobileCloudSource] = [:]
    /// Every placement across Notebooks, resolved against `allSources`. The
    /// phone displays only today's pending plan (the home screen's Today card);
    /// the rest feeds the voice Schedule tools, the widget, and reviews.
    @Published var scheduleItems: [MobileScheduledCatalogItem] = [] {
        didSet { scheduleTodayWidgetSnapshotPublish() }
    }
    /// Today's card review (`MemoryCardQueue.today`), as Home's Memory strip
    /// and the widget count it: how many due and new cards, never a card's
    /// answer. The card review deals the same cards.
    @Published var todayMemoryCards: MemoryCardQueue.Today = .empty {
        didSet { scheduleTodayWidgetSnapshotPublish() }
    }
    /// Moves on every deal of today's cards from the catalog — a load's
    /// checkpoint, an answer saved — so a notebook's Studio counts its cards
    /// again when a card arrives that today's review does not ask yet.
    @Published var memoryCardsRevision = 0
    /// How many cards wait in To Check over every notebook, read with today's
    /// cards: what Home's Memory strip adds to them.
    @Published var cardsToCheckTotal = 0
    /// The learner's synced daily minutes and new cards a day as last read by
    /// `refreshMemoryReviewPreferences`: until the first read lands, today's
    /// cards are dealt uncut, with the Mac's default new cards.
    var memoryReviewPreferences = MobileMemoryReviewPreferences()
    /// Notebooks synced from the Mac, newest activity first. Talking in one
    /// reads exactly its ticked sources.
    @Published var notebooks: [MobileCloudNotebook] = []
    /// Includes child Goals and plain Schedules. Kept for relationship checks;
    /// Notebook browsing continues to use the narrower `notebooks` projection.
    @Published var scheduledSources: [MobileCloudScheduledSource] = []
    /// Book/course display metadata for grouped lists. The hidden sets it also
    /// carries are already applied — `allSources` only ever holds visible rows.
    @Published var collections: MobileCatalogCollections = .empty
    /// Live catalog sync state, for both the full-screen first-sync view and
    /// the in-content banner. nil whenever no walk or drain is in flight.
    @Published var syncStatus: MobileCatalogSyncStatus?
    /// The two sources `syncStatus` is projected from. CloudKit's readout wins
    /// while it has one; the narration scan fills the gap after it — which is
    /// what stops the shell row from saying "Syncing your library" with no
    /// numbers behind it once the CloudKit passes are done.
    var catalogSyncStatus: MobileCatalogSyncStatus?
    var narrationScanStatus: MobileCatalogSyncStatus?
    /// Compatibility line for the existing compact progress UI. The richer
    /// status above drives newer screens, but keeping this projection makes the
    /// catalog persistence change independent of an accompanying view rollout.
    @Published var syncProgressText: String?
    /// True from the first word that the library is arriving on this phone for
    /// the first time until it is whole (`handleLibraryArrival`) — what gates
    /// the shell's sync row and the Library's note that its counts are still
    /// growing.
    @Published var isInitialCatalogSync = false
    /// Where that arrival stands, as the session last said.
    var libraryArrival = MobileLibraryArrival.settled
    /// True while a first launch's narration scan (the iCloud Drive manifest
    /// pass) is still running. Keeps the shell's sync row up after CloudKit
    /// finishes, now with that scan's own count in it.
    @Published var isInitialNarrationScan = false
    @Published var sourceSyncDiagnostic: MobileSourceSyncDiagnostic?
    @Published var activeVoiceSourceID: String?
    /// Title of the source whose narration audio is being generated right now —
    /// the stretch between a text-to-speech request and the first playable chunk,
    /// which the home banner shows so the wait never reads as silence.
    @Published var textToSpeechPreparingTitle: String?
    @Published var textToSpeechPreparingSourceID: String?
    @Published var textToSpeechPreparationDetail: String?
    @Published var textToSpeechGenerationProgress: MobileTextToSpeechGenerationProgress?
    /// Generate-only jobs are independent of the source currently playing.
    /// Keying them by source keeps every row honest when several articles are
    /// being prepared at once without turning playback into a global lock.
    @Published var backgroundTextToSpeechPreparingTitles: [String: String] = [:]
    @Published var backgroundTextToSpeechGenerationProgress: [String: MobileTextToSpeechGenerationProgress] = [:]
    /// The speech model each running generation narrates with, by source, from
    /// the moment the generation knows it will make audio: a paper's narration
    /// is prepared for a while before the first chunk reports, and the row
    /// names the model through that wait too (`textToSpeechModelName`).
    @Published var textToSpeechModelNames: [String: String] = [:]
    @Published var automaticAudioProgress: SourceAudioAutomation.GenerationProgress?
    @Published var textToSpeechCostConfirmation: MobileTextToSpeechCostConfirmation?
    /// A whole book's audio being generated chapter after chapter
    /// (Generate Audiobook), and the price question that comes before it.
    @Published var audiobookGeneration: MobileAudiobookGeneration?
    @Published var audiobookConfirmation: MobileAudiobookPlan?
    var audiobookGenerationTask: Task<Void, Never>?
    /// The narration voice mode started (`listen_to_source`), until the next
    /// conversation takes the audio back.
    @Published var voiceListen: MobileVoiceListen?
    /// Sources whose narration the learner asked for by voice, having heard
    /// its price there when it has one: generating them asks nothing on a
    /// screen nobody is looking at.
    var voiceApprovedTextToSpeechSourceIDs: Set<String> = []
    /// Explainer ids by the id of the source they explain, derived from the
    /// catalog on every publish; `explainerID(explaining:)` reads it.
    @Published var explainerIDsByExplainedSourceID: [String: String] = [:]
    /// The audio overviews the Mac saved, read with the Notebooks they are in.
    @Published var audioOverviewRecords: [MobileAudioOverviewRecord] = []
    /// Every current Artifact not hidden; a notebook's Studio lists the Docs
    /// among them (`docs(in:)`).
    @Published var notebookArtifacts: [MobileCloudArtifact] = []
    /// The chats filed under each notebook, newest first (`notebookChats(in:)`).
    @Published var notebookChatsByNotebookID: [String: [MobileNotebookChatSummary]] = [:]
    /// Where the system asked the phone to go, which the shell has yet to
    /// follow: a foreverlm:// link (`ForeverLMMobileApp.onOpenURL` — the
    /// widget's Today and review taps, a notebook in a calendar note, a
    /// source), Siri's "open today" and memory review, the reminder's tap.
    /// Held here rather than posted, so one that arrives before the shell is
    /// on screen (a cold launch, the sign-in wall) is followed when it
    /// appears, before the launch reopens the last notebook. The shell
    /// clears it.
    @Published var pendingDeepLink: MobileDeepLink?
    @Published var bookContinuationOffer: MobileBookContinuationOffer?
    /// The first narration on this phone, waiting while the learner picks a
    /// voice, and the one to go ahead with once the sheet has gone.
    @Published var voiceChoiceRequest: MobileVoiceChoiceRequest?
    var voiceChoiceContinuation: MobileVoiceChoiceRequest?
    /// The first voice conversation, waiting while the learner picks its
    /// voice, and the one to start once the sheet has gone.
    @Published var voiceModeVoiceChoice: MobileVoiceModeVoiceChoice?
    var voiceModeStartAfterChoice: (@MainActor () async -> Void)?
    /// Listen's sleep timer, while one is set.
    @Published var sleepTimer: MobileSleepTimer?
    @Published var lastDrivingBenchmark: MobileDrivingVoiceBenchmark?
    @Published var apiKeyText: String
    @Published var errorMessage: String?
    @Published var isMutatingLibrary = false

    // The app constructs this shared model before SwiftUI's first frame. Audio
    // objects can synchronously contact media/speech services during init, so none
    // of them belongs on that launch-critical path. Each one wires itself up on
    // first use instead.
    private var initializedPlayer: AVPlayer?
    lazy var player: AVPlayer = {
        let player = AVPlayer()
        initializedPlayer = player
        installTimeObserver(for: player)
        installRemoteCommandHandlers()
        installAudioSessionObservers()
        registerAudioSessionPreemptionIfNeeded()
        return player
    }()

    /// Makes `incoming` the player. A longer narration takes over from the one
    /// that is playing by starting on a second player in step with the first
    /// (`MobileGaplessPlayerHandover`), so the player's identity changes at
    /// that moment and the clock observer moves with it.
    func adoptPlayer(_ incoming: AVPlayer) {
        if let outgoing = initializedPlayer, let timeObserver {
            outgoing.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        initializedPlayer = incoming
        player = incoming
        installTimeObserver(for: incoming)
    }
    lazy var voice: MobileVoiceCommandService = {
        let voice = MobileVoiceCommandService()
        voice.onTranscript = { [weak self] text in
            Task { @MainActor in
                await self?.handleVoiceTranscript(text)
            }
        }
        voice.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.objectWillChange.send()
                }
            }
            .store(in: &cancellables)
        registerAudioSessionPreemptionIfNeeded()
        return voice
    }()
    lazy var speech: MobileReviewSpeechService = {
        let speech = MobileReviewSpeechService.shared
        speech.onFinishSpeaking = { [weak self] in
            Task { @MainActor in
                await self?.resumeAfterSpeech()
            }
        }
        speech.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.objectWillChange.send()
                }
            }
            .store(in: &cancellables)
        return speech
    }()
    lazy var sourceChat = MobileSourceChatService()
    lazy var voiceAgent = MobileVoiceAgentService()
    var timeObserver: Any?
    var endObserver: NSObjectProtocol?
    var completedPlayerItemIdentity: ObjectIdentifier?
    /// The source whose opening section is playing while the rest of its
    /// narration is still being generated. Set only between the opening
    /// starting and the whole composition taking over.
    var openingPlaybackSourceID: String?
    /// True while an opening section is playing ahead of the rest. The opening
    /// running out is not the end of the source, so it must not announce one.
    var isAwaitingRemainingNarration = false
    /// Distinguishes automatic buffering from an intentional pause. AVPlayer
    /// reports both as not playing, but only buffering should auto-resume when
    /// a longer contiguous prefix or the final composition arrives.
    var openingPlaybackRanDry = false
    /// The longest prefix generated so far that is not in the player yet.
    /// A paper arrives as dozens of pieces and each swap assembles the whole
    /// prefix again, so while sound is playing a longer prefix waits here
    /// until the playhead nears the end of the one it has. The swap itself
    /// makes no break in the sound (`MobileGaplessPlayerHandover`).
    var deferredOpeningExtension: MobileAudioItem?
    /// How many seconds of listening must be left in the playing prefix for a
    /// longer one to wait. Long enough to assemble and install the next one.
    static let openingExtensionLeadSeconds: TimeInterval = 20
    /// A read request that arrived while TTS was already preparing audio. This
    /// closes the CarPlay race where generate_source_audio could be running and
    /// a later "listen now" request would be ignored.
    var pendingTextToSpeechAfterPreparationSourceID: String?
    /// Event-driven handoff when a next chapter was already being prepared at
    /// the moment its predecessor finished. The generation completion consumes
    /// this pair; no timer polls keyed progress state.
    var pendingAutomaticBookContinuation: (completedSourceID: String, nextSourceID: String)?
    /// Distinguishes an in-flight generation that already owns autoplay from a
    /// background-only preparation that needs the pending handoff above.
    var textToSpeechAutoplaySourceID: String?
    /// Concurrent generation jobs share one idle-timer lease. Saving/restoring
    /// the raw UIApplication value per task races and can re-enable sleep while
    /// another article is still generating (or leave it disabled forever).
    var textToSpeechIdleTimerLeaseCount = 0
    var wasIdleTimerDisabledBeforeTextToSpeechGeneration = false
    /// The background-execution assertion that lease also holds. One identifier
    /// for the whole lease, for the same reason: several jobs, one runway.
    var textToSpeechBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    /// Generations that were cut short by something worth retrying, and whether
    /// the listener was waiting to hear each one. Suspension is the common
    /// cause: the speech requests in flight when iOS froze the app fail as soon
    /// as it thaws, which would otherwise end the whole generation for good.
    var pendingTextToSpeechResumes: [String: Bool] = [:]
    var automaticTextToSpeechResumeCounts: [String: Int] = [:]
    /// Sources whose Listen stopped while the text was still being prepared,
    /// before any speech was asked for. Restarting one repeats no narration, so
    /// the automatic resume may pick it up without a speech journal.
    var textToSpeechStoppedWhilePreparingText: Set<String> = []
    /// Cancels the generation running for a source, keyed by source id. Present
    /// exactly while that generation can be stopped by the listener.
    var stoppableTextToSpeechGenerations: [String: () -> Void] = [:]
    /// Sources whose generation the listener stopped by hand. A stop is not an
    /// interruption: nothing resumes it and nothing is announced. Cleared when
    /// the listener asks for that source again.
    var listenerStoppedTextToSpeechSourceIDs: Set<String> = []
    var isResumingTextToSpeechGeneration = false
    /// How many times an interrupted generation restarts itself before it waits
    /// for a deliberate Listen. A long absence can strand the same source
    /// several times over; a phone with no network must not loop on it.
    static let maximumAutomaticTextToSpeechResumes = 3
    /// How long a generation the network ended waits on screen for a path to
    /// come back before leaving the retry to the next foreground. Long enough
    /// for the underground stretch of a commute, short enough that a phone left
    /// in airplane mode is not watched indefinitely.
    static let offlineResumeNetworkWait: TimeInterval = 120
    /// The one concurrent UI generation whose opening claimed the player.
    /// Holding ownership until that job finishes prevents later openings from
    /// replacing it — or appearing after the listener closes it.
    var backgroundOpeningPlaybackOwnerSourceID: String?
    var textToSpeechCostConfirmationContinuation: CheckedContinuation<Bool, Never>?
    private var cancellables: Set<AnyCancellable> = []
    var didRegisterAudioSessionPreemption = false
    /// The session observers that keep Listen in step with AirPods and the
    /// system: a pulled-out bud or a call pauses it, a call ending resumes it.
    var audioSessionObservers: [NSObjectProtocol] = []
    /// True while a call, Siri or an alarm holds Listen paused and the system
    /// may hand the audio back.
    var pausedByAudioInterruption = false
    var activeCatalogLoad: (id: UUID, task: Task<Bool, Never>)?
    var forcedCatalogReloadRequested = false
    /// Whether the next load walks the iCloud Drive audio tree; a reload the replica asked for does not.
    var narrationScanRequested = false
    /// Turns the replica's changes into at most one library reload per interval.
    private var replicaReloads: MobileReloadCoalescer?
    var lastSourceSyncErrorMessage: String?
    var shouldResumePlaybackAfterSpeech = false
    var lastPlaybackPositionSaveAt: Date?
    /// When the account copy of the position was last published. The file
    /// beside the audio is written every few seconds; the CloudKit record only
    /// on `ListeningPositionSync.accountSaveInterval` while playing, and at
    /// once whenever a save is forced (pause, skip, dismiss, backgrounding).
    var lastAccountPositionSaveAt: Date?
    /// Keeps the audio list current with narrations other devices publish
    /// while this app is running. Started after the first manifest walk.
    var syncedAudioManifestObserver: SyncedAudioManifestObserver?
    var syncedAudioObservationTask: Task<Void, Never>?
    /// Suppresses duplicate reader-scroll and AVPlayer completion callbacks for
    /// one source while its CloudKit consumption write is in flight. IDs move
    /// to the completed set only after the durable write succeeds, so a visible
    /// failure can be retried instead of being silently treated as saved.
    var sourceConsumptionInFlightIDs = Set<String>()
    var sourceConsumptionRecordedIDs = Set<String>()
    /// Deepest fraction already published per source this launch, so repeated
    /// clock ticks and scroll callbacks collapse into a few writes.
    var recordedSourceDepths: [String: Double] = [:]
    /// How much deeper the learner must get before another depth write is worth
    /// a CloudKit round trip. Twenty steps across a whole source is plenty to
    /// distinguish "opened it" from "went through most of it".
    static let depthReportingStep = 0.05
    /// When each source's depth was last reported to `recordSourceDepth`, and
    /// the listening or reading seconds counted since the last write. Time
    /// rides along with the next depth write; what is left when playback
    /// stops short of a step is lost, which is at most one step's worth.
    var depthTickAt: [String: Date] = [:]
    var pendingEngagedSeconds: [String: Double] = [:]
    /// A tick gap longer than this is a pause or a background stretch, not time
    /// with the source.
    static let maxEngagedTickGap: TimeInterval = 15
    static let activityLogger = Logger(
        subsystem: "com.foreverlm.mobile",
        category: "SourceActivity"
    )
    var sourceActivityInFlightIDs = Set<String>()
    var sourceActivityRecordedIDs = Set<String>()
    lazy var sourceCatalog = MobileCloudSourceCatalog.shared
    lazy var sourceTextStore = MobileCloudSourceTextStore.shared
    var activeVoiceSourceTitle: String?

    // Hands-free review quiz (the app quizzes the user and grades with Claude).
    @Published private(set) var isReviewActive = false
    @Published private(set) var reviewTitle: String?
    @Published private(set) var reviewStatus: String?
    @Published var anthropicKeyText: String
    @Published var hasAnthropicKey: Bool
    // Which grader runs the review. Persisted so the choice survives relaunch.
    @Published var reviewGrader: MobileReviewGrader {
        didSet {
            guard reviewGrader != oldValue else { return }
            Preferences.set(reviewGrader.rawValue, for: Prefs.Mobile.reviewGrader)
        }
    }
    // Resolved at the start of each review from reviewGrader; held for the whole
    // session so the engine's conversation state stays intact across turns.
    private(set) var reviewBrain: any MobileReviewEngine = MobileReviewBrain()

    lazy var reviewRecorder = MobileReviewSessionRecorder.shared
    var reviewSessionID: String?
    var reviewTopic = ""
    var reviewSourceID: String?
    var reviewSourceType: String?
    var reviewStartedAt: Date?
    var reviewPendingQuestion: String?
    var reviewExchanges: [MobileReviewRecordedExchange] = []

    override init() {
        let storedSpeed = Preferences.value(Prefs.Mobile.playbackSpeed)
        speed = MobileAudioPlaybackSpeed.clamped(storedSpeed ?? 1.0)
        apiKeyText = ""
        anthropicKeyText = ""
        // Deliberately assumed, not read. `ManagedAI.isSignedIn` is a synchronous
        // keychain round trip, and this init runs inside the
        // `MobileAudioReviewViewModel.shared` @StateObject autoclosure — i.e. on the
        // main actor during first body evaluation on cold launch. `load()` publishes
        // the real value off-main, and it runs before any Siri command is handled, so
        // the guards that read these never see the placeholder.
        hasOpenAIKey = false
        hasAnthropicKey = false
        let storedGrader = Preferences.value(Prefs.Mobile.reviewGrader)
        reviewGrader = storedGrader.flatMap(MobileReviewGrader.init(rawValue:)) ?? .default
        super.init()
        // The library's first arrival, from the session: now and every few
        // seconds while it lasts. The value is read here, outside the
        // main-actor hop, because Notification itself is not Sendable.
        NotificationCenter.default
            .publisher(for: .mobileLibraryArrivalDidChange)
            .sink { [weak self] note in
                guard let arrival = note.userInfo?[MobileLibraryArrival.userInfoKey] as? MobileLibraryArrival else { return }
                Task { @MainActor in
                    await self?.handleLibraryArrival(arrival)
                }
            }
            .store(in: &cancellables)
        // A round of the phone's session keeps the replica current; the library is read again whenever it
        // changes. Every write and every settled round posts it, so it is coalesced (`MobileReloadCoalescer`),
        // and the narration folder is not walked again for it: only a launch or a foreground reads that.
        replicaReloads = MobileReloadCoalescer { [weak self] in
            _ = await self?.load(forceRefresh: true, scansNarrations: false)
        }
        NotificationCenter.default
            .publisher(for: .mobileReplicaDidChange)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.replicaReloads?.changed()
                }
            }
            .store(in: &cancellables)
        // A read of OpenRouter's speech list that drops the stored pick
        // repairs it at once, as the Mac does; the next use says what changed
        // (`ArticleSpeechSelection.repairAfterDirectoryRead`).
        NotificationCenter.default
            .publisher(for: .openRouterAudioDirectoryDidChange)
            .filter { $0.object as? String == OpenRouterAudioDirectory.Kind.speech.rawValue }
            .sink { _ in
                Task.detached(priority: .utility) {
                    ArticleSpeechSelection.repairAfterDirectoryRead()
                    await ArticleSpeechPreferences.shared.reloadFromStorage()
                }
            }
            .store(in: &cancellables)
    }

    var widgetSnapshotPublishTask: Task<Void, Never>?
    var automaticSourceAudioTask: Task<Void, Never>?
    var automaticSourceAudioPassRequested = false
    /// Sources whose automatic preparation failed this launch. A source the
    /// phone cannot narrate — text that has not synced from the Mac yet, most
    /// often — must not stall every other source behind it, and must not be
    /// retried on every pass. The error still surfaces; only the retry stops.
    var failedAutomaticSourceAudioIDs: Set<String> = []
    @Published var narrationDownloadSourceID: String?
    @Published var narrationDownloadProgress: MobileNarrationDownloadProgress?
    /// True while a streamed opening is being set up from the downloaded
    /// prefix, so two CloudDocs updates cannot both start one.
    var isStartingDownloadedOpening = false
    /// The iCloud pull itself, held apart from the call that asked for it so
    /// the learner can stop it from the banner without the screen that started
    /// it having to stay (`cancelNarrationDownload`).
    var narrationDownloadTask: Task<Void, Error>?
    /// The next chapter's chunks being pulled down ahead of need, so the book
    /// carries on without a download gap. Replaced whenever playback moves.
    var nextChapterPrefetchTask: Task<Void, Never>?
    /// The quiet pass that fetches narrations the listener will likely play next.
    var narrationPrefetchTask: Task<Void, Never>?

    var shareNotebookListPublishTask: Task<Void, Never>?

    deinit {
        if let player = initializedPlayer, let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        for observer in audioSessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        syncedAudioObservationTask?.cancel()
    }

    /// Mirror of the synced consent, refreshed by the settings screen and
    /// before each pass so the executor never trails a revocation.
    var allowsPaidAutomaticVoices = false

    /// False when the last consent read did not reach iCloud. The mirror then
    /// holds no answer, and a pass may neither generate nor retire anything.
    /// A transient outage must not read as "consent withdrawn": the pass would
    /// try to switch every opt-in off, that write would fail on the same outage,
    /// and the failure would be announced as a toast over the source list.
    var paidAutomaticVoiceConsentIsKnown = false

}

// MARK: - Hands-free review quiz
//
// This lives in the same file as the view model (not a separate extension file)
// so it can reach the model's private speak/listen helpers — speakAndResumeListening,
// sourceContext(for:), resolveSourceID(_:from:) — which drive the existing
// speak → listen → transcript loop. The quiz reuses that loop: each question is
// spoken, listening resumes, and the next transcript is routed back here as the
// learner's answer.
extension MobileAudioReviewViewModel {
    func startReviewQuiz(sourceID: String?, utterance: String) async {
        let totalStart = Date()
        guard !isReviewActive else { return }
        await beginSiriVoiceSessionIfNeeded()
        // Only the Claude grader needs a managed session. The Apple on-device grader is
        // checked when the engine begins (it fails loudly if unavailable).
        if reviewGrader.requiresManagedSession, !hasAnthropicKey {
            speakAndResumeListening(
                MobileReviewError.missingAnthropicKey.errorDescription
                    ?? "Sign in with Apple to run a review.",
                pausePlayback: true,
                resumePlaybackAfterSpeech: false
            )
            await endSiriVoiceSession()
            return
        }

        // Record identity is never inferred from a spoken phrase. Siri/App Intents pass
        // an exact source id; an in-app follow-up may use the source already playing.
        let resolutionStart = Date()
        var resolution = MobileVoiceSourceResolver.resolve(
            sourceID: sourceID,
            utterance: utterance,
            sources: allSources,
            currentSourceID: nil,
            activeVoiceSourceID: nil
        )
        if resolution.strategy == .none {
            if let currentID = currentItem?.id ?? activeVoiceSourceID {
                resolution = MobileVoiceSourceResolution(sourceID: currentID, strategy: .currentSource)
            }
        }
        let sourceResolutionMilliseconds = MobileBenchmarkClock.milliseconds(since: resolutionStart)

        guard let resolved = resolution.sourceID else {
            speakAndResumeListening(
                "I could not tell which source to quiz you on. Ask Siri to quiz you on a specific source.",
                pausePlayback: true,
                resumePlaybackAfterSpeech: false
            )
            return
        }

        // sourceContext speaks its own error (e.g. text not synced yet) and returns nil.
        let sourceTextStart = Date()
        guard let context = await sourceContext(for: resolved) else { return }
        let sourceTextLoadMilliseconds = MobileBenchmarkClock.milliseconds(since: sourceTextStart)

        if isSourceChatActive {
            await sourceChat.reset()
            isSourceChatActive = false
            activeChatTitle = nil
        }
        if isPlaying {
            player.pause()
            isPlaying = false
            updateNowPlayingInfo()
        }

        reviewBrain = MobileReviewGraderFactory.makeEngine(for: reviewGrader)
        await reviewBrain.reset()
        reviewSessionID = Self.makeReviewSessionID()
        reviewTopic = context.title
        reviewSourceID = context.sourceID
        reviewSourceType = context.sourceType
        reviewStartedAt = Date()
        reviewPendingQuestion = nil
        reviewExchanges = []
        isReviewActive = true
        reviewTitle = context.title
        reviewStatus = "Reviewing \(context.title)"
        isChatResponding = true
        Task { [weak self] in
            await self?.recordSourceActivity(sourceID: context.sourceID, kind: .review)
        }

        do {
            let modelStart = Date()
            let turn = try await withReviewSourceUsageAttribution {
                try await reviewBrain.begin(
                    sourceTitle: context.title,
                    sourceText: context.text,
                    topic: context.title
                )
            }
            let firstModelTurnMilliseconds = MobileBenchmarkClock.milliseconds(since: modelStart)
            lastDrivingBenchmark = MobileDrivingVoiceBenchmark(
                utterance: utterance,
                route: "chat",
                sourceResolutionStrategy: resolution.strategy.rawValue,
                sourceResolutionMilliseconds: sourceResolutionMilliseconds,
                sourceTextLoadMilliseconds: sourceTextLoadMilliseconds,
                firstModelTurnMilliseconds: firstModelTurnMilliseconds,
                totalMilliseconds: MobileBenchmarkClock.milliseconds(since: totalStart),
                selectedSourceTitle: context.title
            )
            isChatResponding = false
            reviewPendingQuestion = turn.spoken
            reviewStatus = "Reviewing \(context.title)"
            speakAndResumeListening("Let's review \(context.title). \(turn.spoken)", pausePlayback: false)
        } catch {
            isChatResponding = false
            await cancelReview(speaking: error.localizedDescription)
        }
    }

    private func withReviewSourceUsageAttribution<Result>(
        operation: () async throws -> Result
    ) async rethrows -> Result {
        guard let sourceID = reviewSourceID,
              let sourceType = reviewSourceType else {
            return try await operation()
        }
        return try await AIUsageAttribution.withSource(
            AIUsageSource(
                id: sourceID,
                type: sourceType,
                title: reviewTitle ?? reviewTopic
            ),
            activityID: reviewSessionID ?? UUID().uuidString,
            operation: operation
        )
    }

    func routeReviewUtterance(_ utterance: String) async {
        if Self.isReviewExitCommand(utterance) {
            await finishReviewAtLearnerRequest()
            return
        }
        guard !isChatResponding, let question = reviewPendingQuestion else { return }

        isChatResponding = true
        reviewStatus = "Grading your answer"
        await voice.stop()

        do {
            var turn = try await withReviewSourceUsageAttribution {
                try await reviewBrain.answer(utterance)
            }
            reviewExchanges.append(
                MobileReviewRecordedExchange(
                    question: question,
                    userAnswer: utterance,
                    evaluation: turn.lastEvaluation,
                    score: turn.lastScore,
                    answeredAt: Date()
                )
            )
            if turn.isComplete {
                // A normal answer never authorizes closure. Suppress the
                // model's premature wrap-up and regenerate the next question;
                // only finishReviewAtLearnerRequest may persist/end.
                turn = try await withReviewSourceUsageAttribution {
                    try await reviewBrain.continueAfterPrematureCompletion()
                }
                guard !turn.isComplete else {
                    throw MobileReviewError.badResponse(
                        "The grader tried to end the review before the learner asked to stop."
                    )
                }
            }
            isChatResponding = false
            reviewPendingQuestion = turn.spoken
            reviewStatus = "Reviewing \(reviewTitle ?? "source")"
            speakAndResumeListening(turn.spoken, pausePlayback: false)
        } catch {
            isChatResponding = false
            await cancelReview(speaking: error.localizedDescription)
        }
    }

    /// The model never owns session closure. This path is reachable only after
    /// `isReviewExitCommand` recognized an explicit learner request, and gives
    /// the grader a separate final-verdict turn without misrecording "I'm done"
    /// as an answer to the pending quiz question.
    private func finishReviewAtLearnerRequest() async {
        guard !isChatResponding else { return }

        isChatResponding = true
        reviewStatus = "Saving review"
        await voice.stop()

        do {
            let turn = try await withReviewSourceUsageAttribution {
                try await reviewBrain.finish()
            }
            guard turn.isComplete else {
                throw MobileReviewError.badResponse(
                    "The grader did not return a final verdict after the learner asked to stop."
                )
            }
            isChatResponding = false
            await finalizeReview(turn: turn)
        } catch {
            isChatResponding = false
            errorMessage = error.localizedDescription
            reviewStatus = "Review still open"
            speakAndResumeListening(
                "I couldn't save the review yet. It's still open.",
                pausePlayback: false,
                resumePlaybackAfterSpeech: false
            )
        }
    }

    private func finalizeReview(turn: MobileReviewTurn) async {
        let title = reviewTitle ?? reviewTopic
        // Only the grader's own overall score counts. Averaging the per-turn scores —
        // or falling back to 0 when there are none — would invent a grade, and the Mac
        // reads this field as the source's most recent recall score: a fabricated 0
        // marks the source as failed recall and pulls it forward in the memory-review
        // schedule. MemoryReviewSchedule.intervalDays treats a nil score as ungraded
        // and neutral, which is what an ungraded session actually is. The per-turn
        // scores still ride along on the exchanges, so nothing real is dropped.
        let score = turn.overallScore
        let summary = turn.summary ?? "Completed a hands-free review of \(title)."

        if let sessionID = reviewSessionID,
           let sourceID = reviewSourceID,
           let startedAt = reviewStartedAt {
            // The engine that graded this session, not the grader preference:
            // resetReviewState() has not run yet, so this is still the brain
            // makeEngine(for:) actually handed back at review start.
            do {
                let provenance = try await reviewBrain.provenance()
                var result = MobileReviewResult(
                    sessionID: sessionID,
                    topic: reviewTopic,
                    sourceID: sourceID,
                    goalID: nil,
                    startedAt: startedAt,
                    endedAt: Date(),
                    overallScore: score,
                    summary: summary,
                    exchanges: reviewExchanges,
                    gaps: turn.gaps,
                    knowledgeNote: "Recorded from a hands-free iOS review.",
                    modelProvider: provenance.provider,
                    modelID: provenance.modelID
                )
                result.kind = .review
                try await reviewRecorder.record(result)
                try await MobileCloudMutationService.shared.completeScheduledSource(sourceID: sourceID)
                await load()
            } catch {
                // Never fake a successful save (CLAUDE.md: surface AI/sync failures loudly).
                errorMessage = "This review or its Schedule completion could not be saved yet: \(error.localizedDescription)"
            }
        }

        // No grade, nothing to read out — saying "you scored 0 percent" would be the
        // same invention, just spoken.
        let scoreSentence = score.map { " You scored \(Int((max(0, min(1, $0)) * 100).rounded())) percent." } ?? ""
        let spoken = turn.spoken.isEmpty
            ? "\(summary)\(scoreSentence)"
            : turn.spoken
        resetReviewState()
        await endSiriVoiceSession()
        speakAndResumeListening(spoken, pausePlayback: false)
    }

    func cancelReview(speaking message: String) async {
        await reviewBrain.reset()
        resetReviewState()
        await endSiriVoiceSession()
        speakAndResumeListening(message, pausePlayback: false, resumePlaybackAfterSpeech: false)
    }

    private func resetReviewState() {
        isReviewActive = false
        reviewStatus = nil
        reviewTitle = nil
        reviewPendingQuestion = nil
        reviewSessionID = nil
        reviewSourceID = nil
        reviewSourceType = nil
        reviewStartedAt = nil
        reviewTopic = ""
        reviewExchanges = []
    }

    private static func isReviewExitCommand(_ utterance: String) -> Bool {
        let normalized = utterance.lowercased()
        let phrases = [
            "stop the review", "stop review", "end the review", "end review",
            "stop quizzing", "stop the quiz", "end the quiz", "i'm done",
            "im done", "that's enough", "thats enough", "exit review",
            "quit the review", "cancel the review", "stop the review"
        ]
        return phrases.contains { normalized.contains($0) }
    }

    private static func makeReviewSessionID() -> String {
        "ios-\(UUID().uuidString.lowercased())"
    }
}
