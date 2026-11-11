import Foundation
import Observation
import os

/// Shared session logic for explain-it-back review quizzing across all platforms.
/// Owns the AI chat loop and knowledge-base search; platform views observe its state.
@Observable
@MainActor
final class ReviewSessionManager {
    // MARK: - Observable State

    var sessionActive = false
    var isSearching = false
    /// Today's memory review is being prepared live — ideas extracted and the
    /// planner called — because nobody prepared it ahead of time. It rides
    /// along with `isSearching` so every busy guard holds, and exists
    /// separately so the status line can say what is actually happening: this
    /// is planning, not a library search, and it is the wait
    /// `DailyReviewPreparation` exists to remove.
    var isPlanningMemoryReview = false
    /// A saved chat is hydrating. It rides along with `isSearching` so every
    /// existing "busy" guard keeps working unchanged, and exists separately so the
    /// transcript can tell opening a conversation apart from running a turn — the
    /// two look nothing alike to the learner and must not share a status line.
    var isResumingSession = false
    var isGenerating = false
    /// Assistant message currently receiving streamed tokens; drives lightweight transcript rendering.
    var streamingMessageID: UUID?
    /// The reasoning the model has shown so far in the step being streamed —
    /// OpenAI's summaries, Claude's or DeepSeek's thinking — for the status
    /// line to show while no answer text exists. Empty when the model keeps
    /// its reasoning hidden, and cleared when the step ends. Once the answer
    /// begins, it is folded into the transcript as a `.thinking` row above
    /// it, which lives as long as the other activity rows do; it is never
    /// saved with the chat.
    var streamingReasoning = ""
    /// The `.thinking` row the attempt being streamed has written, so later
    /// reasoning updates that row instead of adding a second one.
    var streamingThinkingRowID: UUID?
    var foundSources: [FoundSource] = []
    var chatMessages: [Message] = [] {
        didSet {
            let count = chatMessages.count
            if count != chatMessageCount { chatMessageCount = count }
        }
    }
    /// How many messages the transcript holds, kept apart from the messages
    /// themselves so a view can depend on one without the other. Observation
    /// tracks a dependency per property: a body that reads `chatMessages` only
    /// to ask whether it is empty is still re-evaluated by every streamed
    /// content publish, a dozen times a second. The chat panel's layout and
    /// draft logic read this instead, and only the transcript rows read the
    /// messages.
    private(set) var chatMessageCount = 0
    /// True from the submit turn until the generation driver takes over. This is
    /// observable UI state, not merely a manager-retention lease: source hydration,
    /// Notebook context loading, and session setup may all take long enough that a
    /// chat which shows no reply indicator looks as though the send was dropped.
    var isPreparingGeneration = false
    /// What the send is waiting on right now, when it is something the learner
    /// would recognise — "Downloading <video title>". Nil for the sub-second
    /// steps the generic "Getting your sources ready" line covers.
    var sendPreparationDetail: String?
    /// Messages waiting for the running turn to finish, oldest first.
    var queuedFollowUps: [QueuedFollowUp] = []
    var topic = ""
    /// True while `topic` is just the echoed opening message, pending the
    /// AI-suggested title (or a decision that the echo is fine as a title).
    var titleIsProvisional = false
    var errorMessage: String?
    /// The error that ended the last turn, when one did. `errorMessage` is its
    /// text for the panel; this is the typed value a caller classifies: the
    /// scheduled-task runner decides from it whether a backup model or a later
    /// try could get past it. Nil when the turn never reached a model (no
    /// balance, no model resolved), which nothing tries again.
    @ObservationIgnored var lastGenerationError: Error?
    /// A model this manager's turns use in place of the chat's Default Model
    /// while it is set. The scheduled-task runner walks the Chat model's
    /// backups (`AIBackupModels.chatConfigs`) through it; a chat the learner
    /// types in never sets it.
    @ObservationIgnored var modelOverride: AITaskConfig?
    var turnModel: TurnModel?
    var completedSummary: String?
    var synthesisToolContext: SynthesisToolContext?
    var pendingSynthesisToolCall: SynthesisToolCall?
    /// A reader mark the next message is about (What's New): the chat links
    /// itself to it the moment the message is saved, as `recordDocAnchor`
    /// links a doc passage, so the reader can open this chat from the mark.
    var pendingSourceHighlightLink: String?
    /// Wall-clock record of the steps between the learner's send and the request
    /// leaving the app — the stretch the transcript labels "Getting your sources
    /// ready". Each step is a hop through the shared storage actor or a network
    /// fetch, and none of them left a trace, so a 39-second wait could not be
    /// pinned on anything. Logged the moment generation begins.
    var sendPreparationTrace: ChatSendPreparationTrace?

    var canStopGeneration = false
    /// Estimated composition of the most recently dispatched request; nil until
    /// the first generation round of the session runs.
    var contextBreakdown: ChatContextBreakdown?
    /// Recorded spend attributed to this session: the persisted ledger sum at
    /// open plus every request recorded live since. Nil while no session is
    /// active. Rows recorded before attribution existed carry no session ID,
    /// so an old chat's total covers only its post-upgrade turns.
    var sessionCost: ChatSessionCost?
    /// Boundary of the live/persisted split: the ledger is summed over rows
    /// created strictly before this instant, live events count from it on.
    @ObservationIgnored var sessionCostCutoff: Date?

    // MARK: - Services

    let aiService = AIService()
    let storage: StorageService
    /// Built here rather than injected: Studio owns one of these too, and the
    /// two would only need to be the same object to share the in-flight
    /// deduplication. The durable dedup — a current index has no queue row, and
    /// an analyzed figure is not analyzed twice — sits in storage and holds
    /// across instances, so the worst a race costs is one duplicated vision
    /// call on a figure two surfaces open at the same moment.
    @ObservationIgnored
    lazy var paperFigureIndexer = PaperFigureIndexer(storage: storage, aiService: aiService)
    @ObservationIgnored let appToolDefinitions: () -> [AppToolDefinition]
    /// Runs an app tool. The third parameter is the review session this chat is
    /// already recording into: session-creating tools bind to it instead of
    /// inserting a second, exchange-less session row.
    @ObservationIgnored let appToolExecutor: ((String, [String: Any], String?) async -> AppToolResult)?
    /// The app's Browser as this chat drives it (`ChatBrowsing`). Nil where
    /// there is no Browser pane; the browser tools are then not offered.
    @ObservationIgnored let browserAgent: ChatBrowserAgent?

    /// Where this chat's `run_code` scripts run (`ChatCode`). Nil where a
    /// process cannot start (the iPhone), in which case the chat offers no
    /// code tool.
    @ObservationIgnored let codeRunner: ChatCodeRunner?

    /// Names the chat's working folder until the chat has a session id.
    @ObservationIgnored let codeFallbackKey = UUID().uuidString
    var sessionID: String?
    var activeSourceIDs: [String] = []
    var activeArticles: [StudioArticle] = []
    /// The titles of the sources this chat has met in a tool's answer, so a
    /// reply that cites one as `【Title】` can be repaired into its link
    /// (`ChatSourceTitleIndex`). The attached and found sources join it when a
    /// reply is repaired.
    var toolSourceTitles = ChatSourceTitleIndex()
    /// Slack channel names by id, learned from `list_slack_channels` results in
    /// this chat, so a `read_slack_channel` row can name its channel while it is
    /// still running. The read's own result carries the name too, which fills
    /// in a row whose list happened in an earlier session.
    var slackChannelNames: [String: String] = [:]
    /// The Notebook a chat is attached to, when it has one. It names the chat's
    /// subject and its primary source pool; it is not a boundary around the
    /// learner's library, which stays searchable and readable from here.
    var notebookSourceScopeID: String? {
        didSet {
            if notebookSourceScopeID != oldValue {
                notebookImportFiling = nil
                madeThingFiling = nil
            }
        }
    }

    /// Whether a paper or page this chat imports is filed in its Notebook as
    /// well. A team's Notebook this account can only read, or an archived one,
    /// takes none, and its chat's imports go to the library alone
    /// (`NotebookImportRefusal`). Read from the Notebook and its team at the
    /// start of each turn (`refreshNotebookImportFiling`), so the prompt's
    /// import line and the notebook_id an import is given agree. Nil until
    /// read, and for a chat in no Notebook; an import is filed only on `.files`.
    var notebookImportFiling: NotebookImportFiling?

    /// Where what this chat makes at the learner's request is filed
    /// (docs/notebooks-design.md, "Homing"): a Doc, a site or an animation, a
    /// course, a Goal or an Idea, a picture, a video. The notebook is the
    /// chat's Notebook, or the Notebook its Goal belongs to; a chat in no
    /// Notebook, or on a Goal standing alone, has none. `filing` says whether
    /// that notebook takes new things — a team's this account can only read,
    /// or an archived one, does not, and what the chat makes is then filed in
    /// no notebook. Read beside `notebookImportFiling` at the start of each
    /// turn, so the prompt's line and the arguments agree. Nil until read.
    var madeThingFiling: MadeThingFiling?

    var lastAssistantQuestion: String?
    /// Docs the learner attached to this chat, by identity — never by body.
    /// The composer lists them and the prompt names them; the text itself is
    /// read back through `read_doc` at the revision recorded here.
    var contextDocs: [ChatDocAttachment] = []
    /// The canvas this chat was opened from, or had cards added from, and
    /// those cards in the order added (`KnowledgeMapChatContext`). In memory,
    /// as `contextDocs` are: the composer shows a chip for the canvas and one
    /// for each card, and the prompt names them (`canvasContextInstruction`).
    var canvasContext: KnowledgeMapChatContext?
    /// Pictures dropped or pasted into the composer and not yet sent. They
    /// leave with the next message as `foreverlm://image/attached/<id>` lines
    /// in its text, or are forgotten when the chat is reset.
    var pendingImages: [ChatImageAttachment] = []
    var sourceManifest = ""
    var sourceContext = ""
    /// Next unread character for each paged full-source retrieval. An
    /// otherwise identical retry therefore advances instead of returning the
    /// same capped prefix forever when a model omits the continuation cursor.
    @ObservationIgnored var fullSourceRetrievalOffsets: [String: Int] = [:]
    /// Sources whose verbatim text is currently in `sourceContext`.
    ///
    /// Distinct from `activeSourceIDs`, which is the whole attached pool. A
    /// notebook chat attaches every approved source so the model can see the
    /// catalog, but none of that text reaches the prompt until the learner
    /// drops a source in or the model asks for one — so this set starts small
    /// and grows through the conversation. It drives the composer's live
    /// "in context" count, and it is remembered beside the saved chat so a
    /// reopen restores it (`persistLoadedSourceIDs`).
    var loadedSourceIDs: Set<String> = []

    /// Sources the learner has brought into this conversation since their last
    /// message — the ones the transcript will say were "added to context" above
    /// the next message they send. Recorded only once a conversation exists:
    /// what is staged before the first message is the chat's opening context,
    /// which the composer's chip already shows. Taken off and written beside
    /// the next message (`ChatContextAdditions`), so a reopened chat still
    /// shows which articles arrived before "explain these".
    var pendingContextAdditions: [ChatContextAdditions.Source] = []
    /// What the tutor is told with the learner's next message about a memory
    /// review's material: the sources removed from the day since the last
    /// turn (`removeMemoryReviewSource`). Emptied when that message goes.
    @ObservationIgnored var pendingMemoryReviewNotes: [String] = []
    /// Per-source character counts for the text currently in `sourceContext`,
    /// feeding the context gauge's per-source rows. Grows as sources are
    /// loaded; cleared when a full-text retrieval replaces the assembled
    /// context (the split is then unknown).
    @ObservationIgnored var perSourcePromptShares: [ChatContextBreakdown.SourceShare] = []
    /// Characters-per-token last measured against a provider's own reported
    /// prompt tokens, keyed by "provider|model". Seeds the next round's gauge
    /// so it renders calibrated before that round's usage lands.
    @ObservationIgnored var observedCharactersPerToken: [String: Double] = [:]
    @ObservationIgnored var usageEventObserver: NSObjectProtocol?
    @ObservationIgnored private var sessionObserver: NSObjectProtocol?
    @ObservationIgnored var appToolResultContext = ""
    @ObservationIgnored var generationPreparationDepth = 0
    /// Resolved off-main with the Deep Research task configuration; reading
    /// task prompt overrides synchronously on the main actor would hit Keychain.
    @ObservationIgnored var deepResearchSystemPrompt = Prompts.deepResearch
    var sessionPromptKind: SessionPromptKind = .agent
    var dailyPlanRationale: String?
    /// Ordered, durable learning targets for the AI-native memory conversation.
    /// Nil preserves the ordinary source-level Review Chat path.
    var memoryCompanionPlan: MemoryCompanionPlan?
    /// Bounded, structured prior failures loaded before a memory session starts.
    /// Keeping this immutable for the live session preserves the cached prompt
    /// head; today's attempt becomes context on the next session, not by
    /// invalidating every subsequent turn in this one.
    @ObservationIgnored var memoryStruggleProjections: [String: MemoryStruggleProjection] = [:]
    var currentMemoryTargetIndex = 0
    @ObservationIgnored var stagedMemoryAttempt: StagedMemoryAttempt?
    @ObservationIgnored var lastMemoryAttemptNeedsRetry = false
    /// The ideas of today's memory review by source: what `grade_memory_contour`
    /// is validated against. Loaded when the review starts or resumes; empty in
    /// every other chat, which is also what hides the grading tools.
    @ObservationIgnored var memoryReviewIdeasBySource: [String: [SourceIdea]] = [:]
    /// The material of today's memory review, in briefing order: every source
    /// the cohort chose, chats included. A chat is review material under its own
    /// session id without being a source row, so it is never in
    /// `activeSourceIDs` — the attached article pool the catalog numbers. This
    /// list is what the session record carries and what the grader accepts, and
    /// it outlives any source the learner attaches or detaches during the review.
    @ObservationIgnored var memoryReviewSourceIDs: [String] = [] {
        didSet {
            // The briefing is always in place before the material is set, and
            // a removal only shortens the list, so the order read here holds.
            let ordered = MemoryReviewTutoring.planOrdered(memoryReviewSourceIDs, inBriefing: dailyPlanRationale)
            if ordered != memoryReviewMaterialInPlanOrder { memoryReviewMaterialInPlanOrder = ordered }
            // A topic's title rides with the sources' so the card's head and
            // the turn row name a topic the way they name a source.
            let topics = memoryReviewSourceIDs.isEmpty ? [] : MemoryReviewTutoring.topics(inBriefing: dailyPlanRationale)
            if topics != memoryReviewTopics { memoryReviewTopics = topics }
            var titles = dailyPlanRationale.map(MemoryReviewTutoring.sourceTitles) ?? [:]
            for topic in topics { titles[topic.id] = topic.title }
            memoryReviewMaterialTitles = titles
        }
    }
    /// Today's topics, when the review was planned by topic (docs/memory-design.md,
    /// "Review by topic"): read off the briefing, less the ideas of any source
    /// the learner took out. Empty for a review planned source by source, which
    /// is also what keeps the contour grader and the strip in place for it.
    private(set) var memoryReviewTopics: [MemoryReviewTopic] = []
    /// Every idea today's review has graded, with its latest grade and how
    /// often it came back missing: the topic card's ledger.
    var memoryReviewIdeaStates: [String: MemoryReviewIdeaState] = [:]
    /// The kind of the understanding probe Go deeper asked last in today's
    /// review, so the next one rotates past it (`MemoryUnderstandingProbe`).
    /// Read back from the saved grades when the review is reopened.
    @ObservationIgnored var memoryReviewLastProbeKind: MemoryUnderstandingProbe.Kind?
    /// Today's review material, chats included, in the order the plan's moves
    /// take it: what the chat's source strip shows, so it reads done, current,
    /// next in the order the tutor actually works.
    private(set) var memoryReviewMaterialInPlanOrder: [String] = []
    /// Each review source's title as the briefing heads it. The strip names a
    /// chat from here, since a chat has no article to carry its title.
    @ObservationIgnored private(set) var memoryReviewMaterialTitles: [String: String] = [:]
    /// Each review source's depth, so the grader's tool result can tell the
    /// tutor what silence means for that source.
    @ObservationIgnored var memoryReviewDepthBySource: [String: MemoryReviewDepth] = [:]
    /// A validated contour grade waiting for the reply it belongs to; written
    /// onto that reply's exchange by `persistAssistantResponse`.
    @ObservationIgnored var stagedContourGrade: MemoryContourGrade?
    /// The cards this turn saved (`save_card_drafts`), waiting for the reply
    /// they belong to: `persistAssistantResponse` stores them at its head as
    /// one link line, so a reopened chat draws them where the turn drew them.
    @ObservationIgnored var stagedSavedCards: ChatSavedCards?
    /// The pages this turn wrote (`ChatWrittenPage`), waiting for the reply
    /// they belong to: `persistAssistantResponse` stores a line for each at
    /// its head, so a reopened chat draws their cards again.
    @ObservationIgnored var stagedWrittenPages: [ChatWrittenPage] = []
    /// The course quiz this chat is running (`startCourseQuiz`): its
    /// questions sit in the prompt's cached head and `grade_quiz_answer`
    /// grades against it. Reopening the quiz chat restores the grader too,
    /// including after the first pass so missed questions can be corrected.
    @ObservationIgnored var courseQuiz: CourseQuizChatState? {
        didSet {
            let number = courseQuiz?.currentIndex.map { $0 + 1 }
            if courseQuizOpenQuestionNumber != number { courseQuizOpenQuestionNumber = number }
            if courseQuiz == nil { pendingCourseQuizPictureTurn = nil }
        }
    }
    @ObservationIgnored var pendingCourseQuizPictureTurn: PendingCourseQuizPictureTurn?
    /// The number of the quiz question waiting for an answer in this chat;
    /// nil when the chat runs no quiz or its quiz's questions are all
    /// settled. Observed, so Skip Question shows only while there is a
    /// question to skip.
    private(set) var courseQuizOpenQuestionNumber: Int?
    /// What today's review has actually settled, by source: a source appears
    /// here once its contour has been graded. Observed rather than queried, so
    /// the chat's source strip checks a source off the moment the grade lands.
    var memoryReviewStatusBySource: [String: MemoryReviewSourceStatus] = [:]
    /// The source the tutor is asking about right now: the last
    /// `<flm_source_turn>` line it wrote, or, when it wrote none, the last
    /// contour it graded. Drives the current chip in the chat's source strip.
    var memoryReviewCurrentSourceID: String?
    /// Built here like `paperFigureIndexer`: the durable dedup is the content
    /// hash in storage, so two instances cost at most one duplicate extraction.
    @ObservationIgnored
    lazy var ideaExtraction = SourceIdeaExtractionService(storage: storage, aiService: aiService)
    var lastGenerationFailed = false
    /// Set when a provider rejects native tool definitions; the session then
    /// uses the <flm_tool_call> text protocol for its remaining turns.
    @ObservationIgnored var nativeToolsDisabledForSession = false
    /// The learner's skills as this chat first saw them, read at its first
    /// turn and kept for the conversation, so the catalog in the cached system
    /// head stays the same bytes turn after turn (chat-design.md, "Skills").
    /// A skill written mid-chat is still reachable: `get_skill` reads the
    /// store, and `/name` carries its instructions in the message. nil until
    /// read.
    @ObservationIgnored var sessionSkills: [SkillRecord]?
    /// The working log's excerpt (`WorkingLog`), read at the start of every
    /// turn because it moves as the learner works. nil while it holds nothing
    /// or could not be read.
    @ObservationIgnored var sessionWorkingLog: String?
    /// The working notes nearest this turn's message (`WorkingNoteStore.recall`),
    /// chosen by embedding at the start of every turn.
    @ObservationIgnored var sessionRecalledNotes: [WorkingNote] = []
    /// Set when the learner sends a message while a turn is still generating.
    /// The message is appended and persisted immediately; when the running turn
    /// finishes, the generation driver runs a follow-up turn to answer it.
    @ObservationIgnored var followUpGenerationRequested = false
    @ObservationIgnored var activeGenerationTask: Task<Void, Error>?
    @ObservationIgnored var activeGenerationID: UUID?
    @ObservationIgnored var userStoppedGeneration = false
    /// `restartTurnOnSelectedModel` has cancelled the running turn and wants
    /// it asked again. Consumed by `handleGenerationCancellation`, and dropped
    /// when the turn ends any other way.
    @ObservationIgnored var pendingModelRestart = false
    /// The turn that just ended was cancelled to be asked again: the
    /// generation loop runs it once more before anything queued.
    @ObservationIgnored var turnRestartsOnSelectedModel = false
    /// The row the learner's newest message was saved to, until a reply is
    /// kept on it (`persistPendingUserMessage`).
    @ObservationIgnored var newestMessageRow: ReplyRow?
    /// The row the running turn's reply is written to: the newest message's
    /// as the turn began (`beginReplyPairing`), so a message saved while the
    /// turn runs waits for a turn of its own. A reply names its row rather
    /// than taking the oldest row still without one: on 2026-09-27 a course
    /// quiz's grade cut short by Send now saved nothing, its row stayed open,
    /// the next reply filled it, and every later answer was stored with the
    /// reply to a later message.
    @ObservationIgnored var turnReplyRow: ReplyRow?
    /// The running turn has begun writing its reply to storage
    /// (`persistAssistantResponse`). A failure after that point must not save
    /// the reply a second time.
    @ObservationIgnored var turnReplyWriteStarted = false
    /// The turn that just failed saved what it had written on its message's
    /// row (`keepFailedTurnText`), so Retry asks again for a message that
    /// already has a reply.
    @ObservationIgnored var failedTurnReplySaved = false
    /// Retry has asked again for a message whose failed reply was saved; read
    /// once by the turn it starts (`turnFollowsSavedFailedReply`).
    @ObservationIgnored var retryFollowsSavedFailedReply = false
    /// The running turn is that retry: its reply goes on a row of its own
    /// with no message, so a reopened chat shows the learner's message once,
    /// then the failed reply, then this one, as the transcript does.
    @ObservationIgnored var turnFollowsSavedFailedReply = false
    @ObservationIgnored var historyDigest = ""
    @ObservationIgnored var historyDigestCoveredMessageCount = 0
    /// The background fold in flight, if any. Never awaited by a turn: the
    /// deterministic transcript compact covers whatever it has not folded yet.
    @ObservationIgnored var historyFoldTask: Task<Void, Never>?
    @ObservationIgnored var historyFoldID: UUID?
    let recentMessageLimit = 20
    let streamUIUpdateInterval: TimeInterval = 0.075
    let compactedHistoryCharacterLimit = 6_000
    let compactedTurnCharacterLimit = 600
    // Rolling model-written summary of older turns, so a chat can run for any
    // number of turns without its early history degrading into dropped or
    // hard-truncated text. Turns beyond the verbatim recent window are folded
    // into the summary once at least a block of them has accumulated; between
    // folds the deterministic transcript compact covers the not-yet-folded
    // remainder. Folding runs in the background: it used to block the reply
    // until the summary came back, which on a reasoning model was a long
    // silence before the first token.
    let historyDigestFoldBlockMessageCount = 8
    // Desired summary size, not the provider request ceiling. `AIService.callChat`
    // adds reasoning headroom and expands again if the provider still hits its
    // output limit.
    let historyDigestTargetOutputTokens = 2_000
    let historyDigestFoldTurnCharacterLimit = 4_000
    // Transcript text one fold request may carry. A chat reopened without a
    // saved summary used to fold its whole backlog in a single request —
    // hundreds of turns, minutes of latency, and on a small window a provider
    // rejection that then repeated on every turn. Catch-up is now a series of
    // bounded requests, and the summary is saved so it happens once per chat.
    let historyDigestFoldCharacterLimit = 24_000
    // Safety net on the summary itself, which is resent on every turn. The
    // prompt asks the model to keep it dense; this only bites if it does not.
    let historyDigestCharacterLimit = 12_000
    // Characters of verbatim source text kept resident and resent every turn.
    // Sized from the selected model's context window by
    // `refreshSourceContextBudget`, so a dropped-in book loads as far as the
    // model can actually hold it; full sources stay retrievable through tools
    // past that point. The 64k figure (~16k tokens) is only the standing value
    // until a model is known, and the value kept when the model publishes no
    // window — a guess would be worse than the figure that has always applied.
    var sourceContextCharacterLimit = ReviewSessionManager.fallbackSourceContextCharacterLimit
    let sourceRetrievalCharacterLimit = 16_000
    let sourceRetrievalDefaultMaxSources = 4
    let sourceRetrievalMaxSources = 8
    // A named-source retrieval is still audited by the ranker, and the sources
    // it would have read instead come back as short leads. These bound that
    // addition so an audit can never crowd out the read the model asked for.
    let sourceCrossCheckMaxSources = 2
    let sourceCrossCheckCharacterLimit = 2_000
    // Tool results are volatile and get resent on every continuation. They are
    // sized against the selected model's real input window below; an arbitrary
    // fixed cap would turn a complete get_source_content response into a
    // misleading fragment even when the model has ample room for the paper.
    // A small chat model sometimes ends its turn mid-task by narrating the next step
    // ("searching your library now") instead of emitting the tool call. When that
    // happens after it has already run a tool this turn, re-prompt it to continue a
    // bounded number of times before giving up and surfacing whatever it produced.
    let promissoryContinuationMaxAttempts = 2
    let chatResponseMaxOutputTokens = 8_000
    let outputTokenContinuationMaxAttempts = 4
    // When a reasoning model spends its whole output budget on hidden thinking and
    // emits no visible answer, retry with a larger ceiling before surfacing an error.
    let emptyOutputTokenRetryMaxAttempts = 2
    // Transient provider failures (network blips, 429 rate limits, overloaded /
    // 5xx states) are retried with exponential backoff instead of killing the
    // turn; any partially streamed text is carried forward as a continuation.
    let transientStreamRetryMaxAttempts = 3
    let transientStreamRetryBaseDelaySeconds: TimeInterval = 1.0
    // When a provider rejects a request as exceeding its context window (the
    // char→token estimate undershot), the request is compacted and retried
    // instead of dead-ending the turn.
    let contextOverflowRetryMaxAttempts = 2
    // A model occasionally emits an <flm_tool_call> block with broken JSON. Ask
    // it to re-emit a valid call a bounded number of times before accepting the
    // reply as prose.
    let malformedToolCallNudgeMaxAttempts = 2
    // Library citations carry persisted identity. A fabricated source link must
    // never be rendered or saved as if it came from a tool result: give the model
    // two chances to rewrite the answer from grounded results, then fail loudly.
    let invalidSourceLinkNudgeMaxAttempts = 2
    // A picture address is identity too: one that names nothing draws "picture
    // unavailable" where a picture was promised. Same two chances, then fail.
    let invalidPictureAddressNudgeMaxAttempts = 2
    // A first-review target has no durable curriculum yet. Its first cue must be
    // derived from source text, never the catalog title, so reject a visible reply
    // until the model has actually loaded the manager-owned target source.
    let firstReviewSourceNudgeMaxAttempts = 2
    // A quiz's open question is the sitting's, never the tutor's to move: a
    // reply that shows a question the sitting has not reached is withheld and
    // the tutor sent back to the grader, twice at most, then the turn fails
    // (`CourseQuizChatState.questionShownOutOfTurn`).
    let courseQuizOutOfTurnNudgeMaxAttempts = 2
    let chatResponseMaxOutputTokensCeiling = 32_000
    let compactedRetrySourceContextCharacterLimit = 10_000
    let compactedRetrySectionCharacterLimit = 1_500
    let genericSelectedSourcesTitle = ReviewSessionTitleHeuristics.genericSelectedSourcesTitle
    let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
        category: "Review"
    )

    init(
        storage: StorageService = StorageService(),
        appToolDefinitions: @escaping () -> [AppToolDefinition] = { [] },
        appToolExecutor: ((String, [String: Any], String?) async -> AppToolResult)? = nil,
        browserAgent: ChatBrowserAgent? = nil,
        codeRunner: ChatCodeRunner? = nil
    ) {
        self.storage = storage
        self.appToolDefinitions = appToolDefinitions
        self.appToolExecutor = appToolExecutor
        self.browserAgent = browserAgent
        self.codeRunner = codeRunner
        // A "sign in" error shown while signed out (a chat or a review tried AI first) is
        // stale the moment a sign-in stores a session; it used to stay on the home until closed.
        sessionObserver = NotificationCenter.default.addObserver(
            forName: .managedAISessionDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` guarantees this block runs on the main thread.
            MainActor.assumeIsolated {
                guard let self, self.errorMessage == Self.signInRequiredMessage, ManagedAI.isSignedIn else { return }
                self.errorMessage = nil
            }
        }
    }

    deinit {
        if let usageEventObserver {
            NotificationCenter.default.removeObserver(usageEventObserver)
        }
        if let sessionObserver {
            NotificationCenter.default.removeObserver(sessionObserver)
        }
    }

    /// What every AI entry point says while no session exists on this Mac.
    nonisolated static let signInRequiredMessage = "Sign in with Apple to use ForeverLM AI."

    // MARK: - Session Control

    /// The kind a chat this manager creates is written with (D50): the day's memory
    /// review `memory`, a course quiz's sitting `quizSitting`, a review `review`, any other chat `chat`.
    /// A spoken conversation is the chat or review it drives.
    nonisolated static func createdChatKind(fixedSessionID: String?, mode: InitialPromptMode) -> ChatKind {
        if let fixedSessionID, MemoryReviewSession.isMemorySession(fixedSessionID) { return .memory }
        if let fixedSessionID, fixedSessionID.hasPrefix(CourseQuizSitting.sessionIDPrefix) { return .quizSitting }
        return mode == .review ? .review : .chat
    }

    /// Start a review session. Pass articles for source-grounded quizzing (iOS/macOS)
    /// or an empty array for general-knowledge mode.
    /// - Parameter preloadSourceIDs: Sources whose full text should be in
    ///   context from the first turn, because the learner picked them —
    ///   opening a chat on one paper, for instance. Everything else in
    ///   `articles` is attached as catalog only and loaded if the model asks.
    func startSession(
        topic: String,
        articles: [StudioArticle] = [],
        mode: InitialPromptMode = .review,
        goalID: String? = nil,
        notebookScopeID: String? = nil,
        dailyPlanRationale: String? = nil,
        memoryPlan: MemoryCompanionPlan? = nil,
        preloadSourceIDs: Set<String> = [],
        fixedSessionID: String? = nil,
        persistedBriefing: String? = nil,
        reviewMaterialSourceIDs: [String] = [],
        startedAt: Date = Date(),
        scriptedOpening: String? = nil
    ) async {
        releaseWalkthroughPlaybackForNewChat(about: articles)
        let trimmedTopic = reviewTitle(topic: topic, articles: articles)
        guard !trimmedTopic.isEmpty else {
            errorMessage = "Add a source before starting Chat."
            return
        }
        guard let config = await resolvedGenerationConfigOrShowError(for: mode) else { return }
        beginSendPreparationTraceIfNeeded()
        markSendPreparation("model")

        self.topic = trimmedTopic
        notebookSourceScopeID = Self.nonEmptyTrimmed(notebookScopeID)
        self.titleIsProvisional = false
        self.dailyPlanRationale = {
            let trimmed = dailyPlanRationale?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }()
        self.memoryCompanionPlan = memoryPlan
        memoryReviewSourceIDs = reviewMaterialSourceIDs
        memoryStruggleProjections = [:]
        currentMemoryTargetIndex = 0
        stagedMemoryAttempt = nil
        lastMemoryAttemptNeedsRetry = false
        sessionPromptKind = Self.startingPromptKind(fixedSessionID: fixedSessionID, mode: mode)
        errorMessage = nil
        lastGenerationFailed = false
        completedSummary = nil
        isSearching = true

        let context = await loadSourceContext(from: articles)
        isSearching = false
        guard articles.isEmpty || !context.readableSourceIDs.isEmpty else {
            errorMessage = "No readable source content is available for Chat. Fetch or import the source content before starting a review."
            return
        }

        await applyAttachedSourceContext(context, articles: articles, preloading: preloadSourceIDs)
        markSendPreparation("sources")

        do {
            try await refreshMemoryStruggleProjections()
        } catch {
            errorMessage = "Prior memory evidence could not be loaded. \(error.localizedDescription)"
            logger.error("Failed to load memory struggle context: \(error.localizedDescription)")
            return
        }

        let memoryTargetIDs: [String]
        do {
            memoryTargetIDs = try await persistedMemoryTargetIDs(for: memoryPlan)
        } catch {
            errorMessage = "The memory review targets could not be identified portably. No chat was created. \(error.localizedDescription)"
            return
        }
        guard memoryTargetIDs.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }), Set(memoryTargetIDs).count == memoryTargetIDs.count else {
            errorMessage = "The memory review plan contains an invalid duplicate target. No chat was created."
            return
        }

        // A caller-chosen id is how the day's memory review stays one record:
        // `MemoryReviewSession.sessionID(for:)` names the day, so a second start
        // on another device converges on it instead of creating a twin.
        let id = fixedSessionID ?? UUID().uuidString
        do {
            try await storage.createReviewSession(
                id: id,
                topic: trimmedTopic,
                sourceIDs: persistedSessionSourceIDs,
                cardIDs: memoryTargetIDs,
                startedAt: startedAt,
                modelProvider: config.provider.rawValue,
                modelID: config.model,
                modelEffort: config.effort?.rawValue,
                modelSpeed: config.speed?.rawValue,
                goalID: goalID,
                scheduleActivityAt: sessionCreationActivityDate(mode: mode, now: startedAt),
                scheduleActivityKind: mode == .review ? .review : .chat,
                kind: fixedSessionID.map(MemoryReviewSession.isMemorySession) == true ? .memory : nil,
                briefing: persistedBriefing,
                chatKind: Self.createdChatKind(fixedSessionID: fixedSessionID, mode: mode)
            )
            sessionID = id
            sessionActive = true
            beginSessionCostTracking()
            markSendPreparation("session row")
            await persistLoadedSourceIDs()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to create in-app review session: \(error.localizedDescription)")
            return
        }

        if let scriptedOpening {
            await openWithScriptedMessage(scriptedOpening)
        } else {
            await generateQuestion(isFirst: true)
        }
    }

    /// The tutor a new chat starts with: its mode's, unless its id names a
    /// teach-back (`TeachBack.sessionIDPrefix`), whose tutor the id carries
    /// so the chat keeps it when reopened (`promptKind(sessionID:from:)`).
    static func startingPromptKind(fixedSessionID: String?, mode: InitialPromptMode) -> SessionPromptKind {
        if let fixedSessionID, TeachBack.isSessionID(fixedSessionID) { return .teachBack }
        return mode.sessionPromptKindForAutomaticStart
    }

    /// The Feynman Technique: a chat in the notebook, its ticked sources
    /// attached as a catalog and read on demand, that opens by asking the learner what they know of it
    /// from memory, with no model turn before it (`TeachBack.openingMessage`).
    /// The tutor (`Prompts.teachBackTutor`) takes over from the learner's first
    /// reply. Kept as a review: private to the learner and a review on the
    /// Schedule, like a course quiz's chat.
    func startTeachBack(notebookID: String, notebookTitle: String, articles: [StudioArticle]) async {
        await startSession(
            topic: TeachBack.topic(notebookTitle: notebookTitle),
            articles: articles,
            mode: .review,
            goalID: notebookID,
            notebookScopeID: notebookID,
            // Catalog only: the tutor reads the passages and figures it needs
            // with retrieve_sources. Preloading a whole notebook put 330k
            // tokens in every request (`AIService.sourceContextMaxTokens`).
            fixedSessionID: TeachBack.sessionID(),
            scriptedOpening: TeachBack.openingMessage(notebookTitle: notebookTitle)
        )
    }

    /// A chat whose opening is already written (a course quiz's question 1)
    /// shows it at once and keeps it as the session's first prompt, as a
    /// model-written opening would be kept. No model is asked; the tutor
    /// takes over from the learner's first reply.
    func openWithScriptedMessage(_ opening: String) async {
        discardSendPreparationTrace()
        guard let sessionID else { return }
        chatMessages.append(Message(role: .assistant, content: opening))
        lastAssistantQuestion = opening
        do {
            let sequence = try await storage.addReviewPrompt(
                sessionID: sessionID,
                question: opening,
                sourceRefs: activeSourceIDs
            )
            await updateLastMessagePersistence(
                role: .assistant,
                content: opening,
                sequence: sequence,
                field: .question
            )
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to keep the scripted opening of \(sessionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The chat as voice mode is told it when the learner carries it on out
    /// loud (`RealtimeVoiceChatContinuation`): what was typed and what was
    /// answered, with tool rows and empty turns left out. Nil while no chat
    /// is open.
    var voiceContinuationChat: RealtimeVoiceChatContinuation.Chat? {
        guard let sessionID else { return nil }
        let turns: [RealtimeVoiceChatContinuation.ChatTurn] = chatMessages.compactMap { message in
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            switch message.role {
            case .user: return .init(role: .learner, text: text)
            case .assistant: return .init(role: .assistant, text: text)
            case .tool: return nil
            }
        }
        return RealtimeVoiceChatContinuation.Chat(sessionID: sessionID, title: topic, turns: turns)
    }

    /// Keeps what ForeverLM said in a voice conversation that carried chat
    /// `targetSessionID` on (`RealtimeVoiceChatContinuation.note`) as one reply
    /// in it. Shown at once when that chat is the one open here, after any
    /// typed turn still running; written to the store alone when the learner
    /// has moved to another chat meanwhile, where it shows on reopening.
    func appendVoiceConversation(_ note: String, toSession targetSessionID: String) async {
        if sessionID == targetSessionID {
            // Not in the middle of a typed reply: the note follows it.
            var waited = 0
            while canStopGeneration, waited < 600 {
                try? await Task.sleep(for: .milliseconds(500))
                waited += 1
            }
        }
        guard sessionID == targetSessionID else {
            do {
                _ = try await storage.addReviewPrompt(sessionID: targetSessionID, question: note, sourceRefs: [])
            } catch {
                logger.error("Voice conversation not kept in chat \(targetSessionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        chatMessages.append(Message(role: .assistant, content: note))
        do {
            let sequence = try await storage.addReviewPrompt(
                sessionID: targetSessionID,
                question: note,
                sourceRefs: activeSourceIDs
            )
            await updateLastMessagePersistence(
                role: .assistant,
                content: note,
                sequence: sequence,
                field: .question
            )
        } catch {
            errorMessage = "The voice conversation could not be added to this chat: \(error.localizedDescription)"
            logger.error("Voice conversation not kept in chat \(targetSessionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Start today's memory review: plan it, then open it as an ordinary review
    /// chat whose stable briefing is the plan and the material.
    ///
    /// The plan is one model call and can fail; when it does the learner sees
    /// why and no session row is created, because a review with no plan would
    /// be an ordinary chat pretending to be a review. The briefing travels as
    /// `dailyPlanRationale`, in memory for the life of the session — on a later
    /// resume the transcript and the loaded sources carry the conversation.
    func startMemoryReview(
        _ request: MemoryReviewRequest,
        articles: [StudioArticle],
        now: Date = Date()
    ) async {
        guard !request.cohort.isEmpty else {
            errorMessage = "Nothing to review yet. Read or listen to something first."
            return
        }
        guard let planConfig = await resolvedTaskConfigOrShowError(
            .cohortSessionPlan,
            unavailableMessage: "The model for planning a review isn't available. Check your OpenRouter key in AI Usage (the sidebar's OpenRouter button)."
        ) else { return }

        errorMessage = nil
        isSearching = true
        isPlanningMemoryReview = true
        defer {
            isSearching = false
            isPlanningMemoryReview = false
        }

        // Ideas first: the contour is graded against them, so a source without
        // ideas cannot be reviewed today. Extraction is one billed call per
        // source text and costs nothing when the stored ideas already match.
        let extraction = await extractIdeas(for: request.cohort)
        let cohort = extraction.cohort
        guard !cohort.isEmpty else {
            let reason = extraction.skipped.first.map { " \($0)" } ?? ""
            errorMessage = "Today's review could not be prepared: no source yielded ideas.\(reason)"
            return
        }

        let briefs: [CohortSourceBrief]
        let summaries: [String]
        do {
            briefs = try await storage.cohortBriefs(for: cohort)
            summaries = try await storage.recentReviewSummaries(limit: 3)
        } catch {
            errorMessage = "Today's review material could not be loaded. \(error.localizedDescription)"
            logger.error("Failed to brief memory review: \(error.localizedDescription)")
            return
        }

        let plan: CohortSessionPlan
        do {
            plan = try await aiService.planCohortSession(
                cohort: cohort,
                briefs: briefs,
                recentSessionSummaries: summaries,
                budgetMinutes: MemoryReviewBudget.minutes,
                config: planConfig
            )
        } catch {
            errorMessage = "Today's review could not be planned. \(error.localizedDescription)"
            logger.error("Failed to plan memory review: \(error.localizedDescription)")
            return
        }

        memoryReviewIdeasBySource = Dictionary(
            uniqueKeysWithValues: briefs.map { ($0.source.sourceID, $0.ideas) }
        )
        memoryReviewDepthBySource = Dictionary(
            uniqueKeysWithValues: briefs.map { ($0.source.sourceID, $0.depth) }
        )
        stagedContourGrade = nil
        memoryReviewStatusBySource = [:]
        memoryReviewIdeaStates = [:]
        memoryReviewLastProbeKind = nil
        memoryReviewCurrentSourceID = nil

        // Persisted with the session, so a resume after relaunch, a chat prepared
        // ahead of time, and the other device all open the same review.
        let briefing = MemoryReviewTutoring.briefing(
            cohort: cohort,
            briefs: briefs,
            plan: plan,
            skippedSources: extraction.skipped,
            startedAt: now,
            budgetMinutes: MemoryReviewBudget.minutes
        )
        let reviewSourceIDs = Set(cohort.sources.map(\.sourceID))

        isSearching = false
        isPlanningMemoryReview = false
        await startSession(
            topic: MemoryReviewSession.title(for: now),
            articles: articles.filter { reviewSourceIDs.contains($0.id) },
            mode: .review,
            dailyPlanRationale: briefing,
            fixedSessionID: request.sessionID,
            persistedBriefing: briefing,
            // The record carries the whole material list, chats included; the
            // articles above are only the part of it that has text to load.
            reviewMaterialSourceIDs: cohort.sources.map(\.sourceID),
            // A review prepared the evening before is dated the morning it is
            // for, the day its id names, so every reading of "when" agrees.
            startedAt: now
        )
    }

    /// - Parameter courseQuiz: set when the chat is a quiz's sitting
    ///   (`CourseQuizSitting.quizID(inSessionID:)`) and the quiz still
    ///   exists: the grader goes back on and the quiz goes on from the first
    ///   question the chat has not graded.
    func resumeSession(
        _ session: ReviewSessionRecord,
        articles: [StudioArticle] = [],
        notebookScopeID: String? = nil,
        courseQuiz quizRequest: CourseQuizChatRequest? = nil
    ) async {
        guard session.isLocalMCPSession else {
            errorMessage = "Only in-app review sessions can be resumed here."
            return
        }
        // A quiz runs only in the chat it was started in. Its request below
        // restores the grader when that chat is reopened, including for
        // corrections after the first pass.
        courseQuiz = nil
        // What the last chat left out of what is open is that chat's.
        onScreenSourcesLeftOut = []
        pinnedCard = nil

        // Everything from here down is session setup, so hold `isSearching` for
        // all of it rather than only for the source hydration. The transcript now
        // lands early, and a composer that looked live before the session row was
        // selected would file the learner's next message into a brand new chat.
        isSearching = true
        isResumingSession = true
        defer {
            isSearching = false
            isResumingSession = false
        }

        // Empty local review rows have no conversation to reconstruct. Remove them
        // when the learner opens one instead of repeatedly surfacing a dead chat.
        // The storage predicate is checked atomically with deletion, so a transcript
        // completed on another device wins this race and remains intact.
        let persistedMemoryTargetIDs: [String]
        do {
            persistedMemoryTargetIDs = try await storage.loadReviewSessionCardIDs(
                sessionID: session.id
            )
            if persistedMemoryTargetIDs.isEmpty,
               !MemoryReviewSession.isMemorySession(session.id),
               try await storage.deleteReviewSessionIfNoRecordedConversation(session.id) {
                endSession()
                logger.info("Removed abandoned review session \(session.id, privacy: .public) with no recorded conversation.")
                return
            }
        } catch {
            errorMessage = "ForeverLM could not check this saved review before opening it. \(error.localizedDescription)"
            logger.error("Failed to check review session \(session.id, privacy: .public) before resume: \(error.localizedDescription)")
            return
        }

        let exchanges: [ReviewExchangeRecord]
        do {
            // Do NOT reopen here. Opening a finished review to look at it must not
            // flip it from completed back to active (which would un-mark it reviewed
            // and turn a read-through into a live session). We reopen lazily only when
            // the learner actually continues the review (sendAnswer / generateQuestion).
            exchanges = try await storage.loadReviewSessionExchanges(sessionID: session.id)

            // Defend against a cross-device update replacing the exchanges after the
            // atomic preflight above but before this load completed.
            let hasRecordedConversation = exchanges.contains { exchange in
                exchange.userAnswer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
            // A day's memory review is kept until the day is over even when the
            // learner has not answered yet: its opening question *is* the review
            // waiting for them, not an abandoned blank chat. A chat playing a
            // walkthrough is kept the same way: the steps it has shown are
            // the walk so far, typed by nobody.
            let playsWalkthrough = exchanges.contains { WalkthroughStepTurn.marker(in: $0.question) != nil }
            guard hasRecordedConversation
                || !persistedMemoryTargetIDs.isEmpty
                || playsWalkthrough
                || MemoryReviewSession.isMemorySession(session.id) else {
                let deleted = try await storage.deleteReviewSessionIfNoRecordedConversation(session.id)
                endSession()
                if deleted {
                    logger.info("Removed abandoned review session \(session.id, privacy: .public) after its transcript changed while opening.")
                } else {
                    errorMessage = "This saved review changed while it was opening. Try opening it again."
                }
                return
            }
        } catch {
            let message = error.localizedDescription
            endSession()
            errorMessage = message
            logger.error("Failed to resume review session: \(error.localizedDescription)")
            return
        }

        // Put the transcript on screen here, ahead of the credit check, the source
        // hydration and the memory restore below. The learner clicked a conversation
        // and that conversation is one indexed query away; making it wait behind
        // everything else is what made an opened chat show its empty state first.
        // Nothing further down changes what these messages say.
        errorMessage = nil
        lastGenerationFailed = false
        completedSummary = nil
        topic = session.title
        titleIsProvisional = false
        // Historical messages are attributed to the model the session last used —
        // the same label the session browser shows for the whole session.
        chatMessages = messages(
            from: exchanges,
            sessionStartedAt: session.createdAt,
            modelProvider: session.modelProvider,
            modelID: session.modelID
        )
        // The chat that lands decides the walk; the chat's own walk, if it
        // has one, is picked back up below (`restoreWalkthroughPlaybackIfNeeded`).
        releaseWalkthroughPlaybackForReopenedChat(session.id)
        resetHistoryDigest()
        await restorePersistedHistoryDigest(sessionID: session.id)
        // The persisted reply, as the live path keeps it: a memory review
        // reply split around its turn lines is several bubbles here, and the
        // next exchange's question must be the whole reply or reopening the
        // chat later shows that question twice. Its pages' and saved cards'
        // lines are not the reply's words and stay out.
        lastAssistantQuestion = Self.lastAssistantReplyText(from: exchanges)
            ?? chatMessages.last(where: { $0.role == .assistant })?.content

        guard await resolvedChatConfigOrShowError() != nil else {
            discardResumedTranscript()
            return
        }

        let context = await loadSourceContext(from: articles)
        guard articles.isEmpty || !context.readableSourceIDs.isEmpty else {
            discardResumedTranscript()
            errorMessage = "No readable source content is available for Chat. Fetch or import the source content before resuming this review."
            return
        }

        do {
            let memoryResume = try await memoryItemsForResume(
                sessionID: session.id,
                targetIDs: persistedMemoryTargetIDs,
                sessionSourceIDs: session.sourceIDs
            )
            let resumedMemoryItems = memoryResume.items
            let resumedMemoryAttempts: [MemoryAttempt]
            if persistedMemoryTargetIDs.isEmpty, resumedMemoryItems.isEmpty {
                resumedMemoryAttempts = []
            } else {
                resumedMemoryAttempts = try await storage.loadMemoryAttempts(
                    memoryItemID: nil,
                    sessionID: session.id
                )
            }

            // Continue the chat on the route it was held in: re-apply the
            // session's saved model, effort and speed as the current chat
            // override so the composer picker and the next send both match
            // the transcript. Read from the row rather than the list record,
            // so a relaunch (a rebuild included) comes back to what the last
            // reply ran on.
            let savedRoute = try await storage.loadReviewSessionModelRoute(sessionID: session.id)
            let restore = await Self.restoreSessionModelOverride(
                provider: savedRoute?.modelProvider,
                modelID: savedRoute?.modelID,
                effort: savedRoute?.modelEffort,
                speed: savedRoute?.modelSpeed
            )
            if case .unavailable(let saved) = restore {
                // A chat recorded from realtime voice (removed 2026-10-01)
                // names a model typed chat cannot use. Continuing on the
                // configured text model is expected, so keep this transition
                // out of the error UI.
                logger.info("Resume: saved model \(saved, privacy: .public) is unavailable to typed chat; using the default text model.")
            }

            foundSources = context.sources
            sourceManifest = context.manifest
            fullSourceRetrievalOffsets = [:]
            activeSourceIDs = context.sources.isEmpty ? session.sourceIDs : context.sources.map(\.id)
            activeArticles = articles
            notebookSourceScopeID = Self.nonEmptyTrimmed(notebookScopeID)
            sessionID = session.id
            sessionActive = true
            beginSessionCostTracking()
            // A reopened chat holds what it held. The sources whose text was in
            // the model's context when the chat was last open come back loaded
            // — the paper the learner dropped in stays attached until they
            // remove it, whether the chat was filed under a Notebook since or
            // left for a week — and the rest of its catalog stays catalog, so a
            // Notebook pool that was only ever a catalog costs nothing here.
            // What was loaded is remembered per chat (schema 104); a chat from
            // before that is read off its transcript's citations.
            let remembered: [String]?
            do {
                remembered = try await storage.loadReviewSessionLoadedSourceIDs(sessionID: session.id)
            } catch {
                logger.error("Reading the chat's remembered sources failed: \(error.localizedDescription, privacy: .public)")
                remembered = nil
            }
            let reload = Self.sourceIDsToReloadOnResume(
                remembered: remembered,
                attached: activeSourceIDs,
                exchanges: exchanges
            )
            let reloadArticles = articles.filter { reload.contains($0.id) }
            if !reloadArticles.isEmpty {
                await refreshSourceContextBudgetFromSelectedModel()
            }
            let restored = await loadSourceTextBlock(for: reloadArticles, budget: sourceContextCharacterLimit)
            sourceContext = restored.text
            perSourcePromptShares = restored.shares
            loadedSourceIDs = restored.loadedIDs
            if remembered == nil {
                await persistLoadedSourceIDs()
            }
            sessionPromptKind = persistedMemoryTargetIDs.isEmpty
                ? Self.promptKind(sessionID: session.id, from: exchanges)
                : .review
            dailyPlanRationale = nil
            stagedContourGrade = nil
            if let quizRequest {
                await resumeCourseQuiz(quizRequest, sessionID: session.id)
            }
            if MemoryReviewSession.isMemorySession(session.id) {
                // The briefing rides in the session record (schema 89), so the
                // tutor reopens onto the same plan and ideas it started with.
                do {
                    dailyPlanRationale = try await storage.loadReviewSessionBriefing(sessionID: session.id)
                } catch {
                    logger.error("Reading the memory review briefing failed: \(error.localizedDescription, privacy: .public)")
                    dailyPlanRationale = nil
                }
                // The record's list is the review's material, not the attached
                // article pool: a chat reviewed as material has no article, so
                // reading the pool here dropped it, and the grader then refused
                // the very source the briefing told the tutor to open with. A
                // record from before build 94 was written from that pool, so
                // the briefing's headers restore what it lost, and the repaired
                // list is written back for the phone and the next resume.
                let material = Self.memoryReviewMaterialSourceIDs(
                    recorded: session.sourceIDs,
                    briefing: dailyPlanRationale
                )
                if material != session.sourceIDs {
                    do {
                        try await storage.updateReviewSessionSources(sessionID: session.id, sourceIDs: material)
                        logger.notice("Memory review \(session.id, privacy: .public): restored \(material.count - session.sourceIDs.count) review source(s) the record had lost.")
                    } catch {
                        logger.error("Memory review \(session.id, privacy: .public): could not write back its restored sources: \(error.localizedDescription, privacy: .public)")
                    }
                }
                memoryReviewSourceIDs = material
                // Only the ideas this review put in play. A source narrowed to
                // what a chat engaged must stay narrowed when the review is
                // reopened, and the briefing is the record of what was
                // narrowed — the store still holds every idea the source has.
                let storedIdeas: [String: [SourceIdea]]
                do {
                    storedIdeas = try await storage.loadSourceIdeas(sourceIDs: material)
                } catch {
                    logger.error("Reading the review's source ideas failed: \(error.localizedDescription, privacy: .public)")
                    storedIdeas = [:]
                }
                memoryReviewIdeasBySource = Self.gradableIdeas(storedIdeas, briefing: dailyPlanRationale)
                let depths: [String: MemoryReviewDepth]
                do {
                    depths = try await storage.loadSourceReviewDepths(sourceIDs: material)
                } catch {
                    logger.error("Reading the review's source depths failed: \(error.localizedDescription, privacy: .public)")
                    depths = [:]
                }
                memoryReviewDepthBySource = Dictionary(material.map { sourceID in
                    // Material with no article is a chat: the only thing a
                    // memory review carries that is not a source.
                    let sourceType = activeArticles.first(where: { $0.id == sourceID })?.sourceType.rawValue
                        ?? ReviewableChat.sourceType
                    return (sourceID, MemoryReviewDepth.effective(
                        sourceDepth: depths[sourceID],
                        sourceType: sourceType
                    ))
                }, uniquingKeysWith: { first, _ in first })
                // Reopening the day's review must show the checkmarks it
                // already earned, including ones earned on the other Mac.
                memoryReviewStatusBySource = MemoryReviewSourceStatus.statuses(from: exchanges, topics: memoryReviewTopics)
                memoryReviewIdeaStates = MemoryReviewIdeaState.states(from: exchanges.map {
                    .init(
                        sequenceNumber: $0.sequenceNumber, ideaCoverage: $0.ideaCoverage,
                        questionVerdict: $0.questionVerdict, answeredAt: $0.answeredAt, operation: $0.operation
                    )
                })
                // The understanding probes rotate across the day's review, so
                // a reopened review asks the kind after the last one answered.
                memoryReviewLastProbeKind = MemoryUnderstandingProbe.lastKind(
                    operations: exchanges.sorted { $0.sequenceNumber < $1.sequenceNumber }.map(\.operation)
                )
                memoryReviewCurrentSourceID = Self.currentMemorySourceID(from: exchanges, topics: memoryReviewTopics)
                // The early transcript above was built before this review's
                // articles were known, so its heading rows could not resolve
                // their sources. Rebuild it now that they can.
                if exchanges.contains(where: {
                    $0.question.contains("<\(MemoryReviewSourceTurn.tagName)")
                        || ($0.evaluation ?? "").contains("<\(MemoryReviewSourceTurn.tagName)")
                }) {
                    chatMessages = messages(
                        from: exchanges,
                        sessionStartedAt: session.createdAt,
                        modelProvider: session.modelProvider,
                        modelID: session.modelID
                    )
                }
            } else {
                memoryReviewSourceIDs = []
                memoryReviewIdeasBySource = [:]
                memoryReviewDepthBySource = [:]
                memoryReviewStatusBySource = [:]
                memoryReviewIdeaStates = [:]
                memoryReviewLastProbeKind = nil
                memoryReviewCurrentSourceID = nil
            }
            try restoreMemoryCompanionPlan(
                targetIDs: persistedMemoryTargetIDs,
                items: resumedMemoryItems,
                attempts: resumedMemoryAttempts,
                session: session,
                firstReviewSourceIDsByPortableKey: memoryResume.firstReviewSourceIDsByPortableKey
            )
            try await refreshMemoryStruggleProjections()
            stagedMemoryAttempt = nil
            await restoreWalkthroughPlaybackIfNeeded()
            if exchanges.isEmpty, memoryCompanionPlan != nil {
                // Setup is done; the turn below owns the composer from here.
                isSearching = false
                isResumingSession = false
                await generateQuestion(isFirst: true)
            }
        } catch {
            let message = error.localizedDescription
            endSession()
            errorMessage = message
            logger.error("Failed to resume review session: \(error.localizedDescription)")
        }
    }

    var optimisticUserMessage: OptimisticUserMessage?

    // MARK: - The moment a question beside a video is about

    /// Whether the composer held words at its last edit, so the first
    /// keystroke of a new message can be told from the rest.
    @ObservationIgnored var composerHoldsWords = false
    /// Where each video beside the chat stood at the first keystroke of the
    /// message being typed, by source id: the moment the learner decided to
    /// ask, which the send keeps while the player has not moved on from it.
    @ObservationIgnored var questionStartMoments: [String: Int] = [:]
    /// Frame captures started for a question, by the frame's address, so the
    /// send finds the picture already taken. A capture outlives the question
    /// it was started for: `show_source_image` reads the same file.
    @ObservationIgnored var videoMomentFrameCaptures: [String: Task<Bool, Never>] = [:]

    /// Drop everything an idle composer has staged.
    ///
    /// The chat pane outlives the question that filled it: a source dropped in,
    /// or read for a passage half an hour ago, stays staged until something
    /// ends the session, and the next question inherits it. An entry point that
    /// means "chat about exactly this" needs a way to say so.
    ///
    /// Refuses once a conversation exists. Those sources are in the transcript
    /// and in its cached prompt prefix; they cannot be unsaid, only detached
    /// one at a time through `removeContextSource`.
    func clearStagedSources() {
        guard sessionID == nil, !sessionActive, chatMessages.isEmpty else { return }
        foundSources = []
        sourceManifest = ""
        sourceContext = ""
        fullSourceRetrievalOffsets = [:]
        loadedSourceIDs = []
        pendingContextAdditions = []
        pendingMemoryReviewNotes = []
        perSourcePromptShares = []
        contextBreakdown = nil
        activeSourceIDs = []
        activeArticles = []
        contextDocs = []
        canvasContext = nil
        discardPendingImages()
    }

    func endSession() {
        stopGeneration()
        // A chat-bar pick belongs only to the chat being closed. Carrying it
        // into the empty composer made a new Notebook chat contradict the
        // Default Model selected in Settings.
        KeychainService.resetChatSessionSelection()
        sessionActive = false
        chatMessages = []
        resetHistoryDigest()
        foundSources = []
        toolSourceTitles = ChatSourceTitleIndex()
        contextDocs = []
        canvasContext = nil
        onScreenSourcesLeftOut = []
        pinnedCard = nil
        discardPendingImages()
        sourceManifest = ""
        sourceContext = ""
        fullSourceRetrievalOffsets = [:]
        loadedSourceIDs = []
        pendingContextAdditions = []
        pendingMemoryReviewNotes = []
        perSourcePromptShares = []
        contextBreakdown = nil
        sessionCost = nil
        sessionCostCutoff = nil
        topic = ""
        titleIsProvisional = false
        sessionID = nil
        pendingSourceHighlightLink = nil
        activeSourceIDs = []
        activeArticles = []
        notebookSourceScopeID = nil
        lastAssistantQuestion = nil
        completedSummary = nil
        errorMessage = nil
        lastGenerationError = nil
        modelOverride = nil
        lastGenerationFailed = false
        nativeToolsDisabledForSession = false
        sessionSkills = nil
        sessionWorkingLog = nil
        sessionRecalledNotes = []
        followUpGenerationRequested = false
        newestMessageRow = nil
        turnReplyRow = nil
        sessionPromptKind = .agent
        dailyPlanRationale = nil
        memoryCompanionPlan = nil
        memoryStruggleProjections = [:]
        currentMemoryTargetIndex = 0
        stagedMemoryAttempt = nil
        lastMemoryAttemptNeedsRetry = false
        clearWalkthroughPlayback()
        memoryReviewSourceIDs = []
        memoryReviewIdeasBySource = [:]
        memoryReviewDepthBySource = [:]
        stagedContourGrade = nil
        memoryReviewStatusBySource = [:]
        memoryReviewIdeaStates = [:]
        memoryReviewLastProbeKind = nil
        memoryReviewCurrentSourceID = nil
        courseQuiz = nil
    }

    /// Takes back a transcript that was painted early by `resumeSession` when the
    /// resume then failed. Only the displayed conversation goes: the message that
    /// explains why the chat could not open has already been set and must survive,
    /// which is what keeps this from being `endSession()`.
    private func discardResumedTranscript() {
        chatMessages = []
        topic = ""
        titleIsProvisional = false
        resetHistoryDigest()
        lastAssistantQuestion = nil
    }

    func completeSession() async {
        guard let sessionID else {
            errorMessage = "No active review session to complete."
            return
        }
        guard currentPromptMode == .review else {
            errorMessage = "Switch to Review and answer at least one question before completing the session."
            return
        }
        guard containsLearnerReviewAnswer else {
            errorMessage = "Answer at least one review question before completing the session."
            return
        }
        guard let config = await resolvedTaskConfigOrShowError(
            .reviewGrading,
            unavailableMessage: "The selected Review Grading model isn't available. Check your OpenRouter key in AI Usage (the sidebar's OpenRouter button)."
        ) else { return }

        isGenerating = true
        defer { isGenerating = false }

        let transcript = chatMessages.compactMap { message -> String? in
            // Tool rows are UI affordances, not part of the learner/tutor exchange.
            guard message.role != .tool else { return nil }
            let label = message.role == .user ? "Learner" : "Tutor"
            let content = message.role == .user ? AttachedImageReference.textOnly(message.content) : message.content
            return "\(label): \(content)"
        }.joined(separator: "\n\n")

        do {
            let graded = try await AIUsageAttribution.$sessionID.withValue(sessionID) {
                try await gradeReview(transcript: transcript, config: config)
            }
            let completedAt = Date()
            if memoryCompanionPlan != nil {
                let attempts = try await storage.loadMemoryAttempts(
                    memoryItemID: nil,
                    sessionID: sessionID
                )
                guard !attempts.isEmpty else {
                    throw AIError.apiError(
                        "No graded memory attempt was recorded. The review remains open so untouched ideas are not marked reviewed."
                    )
                }
                let reviewedSourceIDs = try await storage.reviewedMemorySourceIDs(
                    sessionID: sessionID
                )
                guard !reviewedSourceIDs.isEmpty else {
                    throw AIError.apiError(
                        "The recorded memory attempts have no valid source anchors. The review remains open."
                    )
                }
                try await storage.completeReviewSessionAndRecordMemoryAttempts(
                    sessionID: sessionID,
                    overallScore: graded.score,
                    summary: graded.summary,
                    endedAt: completedAt,
                    sessionSourceIDs: activeSourceIDs,
                    reviewedSourceIDs: reviewedSourceIDs,
                    scheduleReviewDate: completedAt,
                    companionGoalID: memoryCompanionPlan?.goalID,
                    companionQuizDate: memoryCompanionPlan?.goalID.map { _ in
                        Self.memoryCompanionDayString(completedAt)
                    },
                    attempts: attempts
                )
            } else {
                try await storage.completeReviewSession(
                    sessionID: sessionID,
                    overallScore: graded.score,
                    summary: graded.summary
                )
                // An ordinary completed review belongs on the Schedule. Memory
                // companion reviews use the atomic branch above so only concepts
                // actually attempted can complete their anchored sources.
                for sourceID in activeSourceIDs {
                    try await storage.recordScheduledSourceReview(sourceID: sourceID, on: completedAt)
                }
            }
            completedSummary = graded.summary
            sessionActive = false
            lastAssistantQuestion = nil
            await updateSuggestedSessionTitleIfNeeded(from: graded.summary)
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to complete in-app review session: \(error.localizedDescription)")
        }
    }

    private static func memoryCompanionDayString(_ date: Date) -> String {
        let parts = Calendar.autoupdatingCurrent.dateComponents(
            [.year, .month, .day],
            from: date
        )
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
    }

    private struct GradedReview {
        let score: Double?
        let summary: String
    }

    /// Ask the model for an overall recall score plus a study summary for a completed
    /// review. The score feeds spaced-repetition (memory training) and Learning
    /// Companion mastery. We never invent a score ourselves: if the JSON has a summary
    /// but no clean number, the review is saved with its summary and no score (treated
    /// as neutral by the scheduler) rather than a heuristic guess. If the model returns
    /// no parseable JSON object or no usable summary, parsing throws so the session
    /// stays open and the error surfaces — we never persist raw prose as a summary.
    private func gradeReview(transcript: String, config: AITaskConfig) async throws -> GradedReview {
        let raw = try await withSingleSourceUsageAttribution {
            try await aiService.chat(
                system: "You grade completed review sessions for a learner's study history. Judge how well the learner recalled and explained the material from their own answers.",
                messages: [(
                    role: "user",
                    content: """
                    Based only on this review transcript, respond with a single line of JSON and nothing else:
                    {"score": <number 0.0-1.0 overall recall/understanding>, "summary": "<one or two sentences on what was covered and where understanding still needs work>"}

                    \(transcript)
                    """
                )],
                config: config,
                maxTokens: 600
            )
        }
        return try Self.parseGradedReview(raw)
    }

    private static func parseGradedReview(_ raw: String) throws -> GradedReview {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // No parseable JSON object. Fail loudly so the session stays open and the
            // learner can retry — never persist raw model prose as a review summary.
            throw AIError.apiError("The grading model did not return a parseable JSON object for the review summary. The session was left open — try completing it again.")
        }
        var score: Double?
        if let value = object["score"] as? Double {
            score = value
        } else if let value = object["score"] as? Int {
            score = Double(value)
        } else if let value = object["score"] as? String, let parsed = Double(value) {
            score = parsed
        }
        guard let parsedSummary = (object["summary"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !parsedSummary.isEmpty else {
            // JSON parsed but carried no usable summary. Fail loudly rather than storing
            // the raw JSON blob as the review summary.
            throw AIError.apiError("The grading model returned JSON without a usable review summary. The session was left open — try completing it again.")
        }
        return GradedReview(score: score.map { min(max($0, 0), 1) }, summary: parsedSummary)
    }

    private var containsLearnerReviewAnswer: Bool {
        var hasReviewQuestionPrompt = false
        for message in chatMessages {
            let content = Self.displayableMessageContent(role: message.role, content: message.content)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !content.isEmpty else { continue }

            switch message.role {
            case .assistant:
                if message.exchangeField == .question {
                    hasReviewQuestionPrompt = true
                }
            case .user:
                if hasReviewQuestionPrompt && content != Self.reviewSwitchInstruction {
                    return true
                }
            case .tool:
                // A tool the assistant ran is not a learner answer.
                continue
            }
        }
        return false
    }

    /// Tools this chat has loaded with `load_app_tools`, in load order, for
    /// the session they were loaded in. Appended after the core tools, so a
    /// load never reorders what the request already carried.
    @ObservationIgnored var loadedAppTools: (sessionID: String?, names: [String]) = (nil, [])

    /// How long one app tool call may run before the turn stops waiting for it.
    /// Generous because some tools do real network work (imports, transcription);
    /// the point is that a hung tool can never wedge the chat forever.
    let appToolCallWatchdogSeconds: TimeInterval = 300

    var walkthroughPlayback: WalkthroughPlayback? {
        didSet { persistWalkthroughProgressIfChanged() }
    }
    /// The progress last written for the walk this chat plays, so a move
    /// that changes nothing the record keeps (a figure loaded, the focus
    /// resolved) writes nothing.
    @ObservationIgnored var persistedWalkthroughProgress: WalkthroughProgress?
    /// Saves run one after another, so a quick Next, Next lands in order.
    @ObservationIgnored var walkthroughProgressSave: Task<Void, Never>?

    /// Where each played step points in the PDF, which panels its figure
    /// offers and which one is shown, by step id — what the row's anchor chip
    /// and panel letters draw.
    var walkthroughResolvedByStep: [String: WalkthroughResolvedAnchor] = [:]
    /// The figure a step's cards show without the step outlining it — its
    /// own picture, or one an earlier step of its chapter showed
    /// (`PaperWalkthrough.cardPicture(of:)`) — resolved for its crop, by
    /// step id. The page does not move to it.
    var walkthroughCardPictureByStep: [String: WalkthroughResolvedAnchor] = [:]
    /// Wrong picks on a Find it card so far, by step id: the second wrong
    /// pick shows the answer.
    var walkthroughFindMisses: [String: Int] = [:]
    /// The panel the learner picked within a step, by step id; "" is the
    /// whole figure.
    var walkthroughChosenPanel: [String: String] = [:]
    /// Geometry, cached for the life of the walk (`WalkthroughAnchorResolver`).
    var walkthroughResolver: WalkthroughAnchorResolver?
    /// How this chat points the Reader at a step. The manager has no window;
    /// the pane showing it has the Studio model and sets this on appear, and
    /// the same closure serves the `focus_source_anchor` tool.
    @ObservationIgnored var walkthroughFocusHandler: (@MainActor (WalkthroughReaderFocus) -> Void)?
    /// How this chat opens the Feynman Technique in its Notebook, for
    /// `start_feynman_technique`. The pane showing the chat has the Studio
    /// model and sets this; a manager with no pane (a test, the iPhone) has
    /// none, and the tool is not offered there.
    @ObservationIgnored var teachBackStarter: (@MainActor (_ notebookID: String) -> Void)?

    var walkthroughStepScrollRequest: WalkthroughStepScrollRequest?

    /// Whether a Reader in this chat's window is showing the source right
    /// now. Set by the pane beside `walkthroughFocusHandler`; nil (a manager
    /// with no pane, as in a test) counts as no Reader on screen. A step or a
    /// focused panel is shown enlarged in the row only when the Reader is not
    /// already showing it beside the chat (product owner, 2026-09-20: "don't also
    /// show the figure in the chat if it's already in the reader on the side").
    @ObservationIgnored var walkthroughReaderShowsSource: (@MainActor (String) -> Bool)?

    /// What this chat's window and the other Studio windows have open, for
    /// the `list_open_panes` tool. Set by the pane beside
    /// `walkthroughFocusHandler`; nil (a manager with no pane, as in a test or
    /// a chat outside a Studio window) leaves the tool off the request.
    @ObservationIgnored var openPanesProvider: (@MainActor () -> ChatOpenPanes)?

    /// The sources open beside this chat that the learner took out of it
    /// with the × on their chip over the composer, by source id. The chat is
    /// told nothing of them while they stay open: no on-screen line on the
    /// message, no moment, no pause on typing, nothing in `list_open_panes`
    /// (product owner, 2026-10-13: "if i don't want to chat about that; i
    /// can click a small X and it will remove it from context"). A source
    /// leaves the set when it leaves the window (`keepOnScreenSourcesLeftOut`),
    /// so opening it again shows its chip again; a new or reopened chat
    /// starts with none left out.
    var onScreenSourcesLeftOut: Set<String> = []

    /// The flashcard this chat was opened about (Ask in Chat on a card to
    /// check). The chat is told of it with every message whether or not the
    /// Memory pane still shows it, because opening the chat can take that
    /// pane's place; the chip's × leaves it out like any open card's. A new
    /// or reopened chat starts with none.
    var pinnedCard: ChatContextAdditions.CardOnScreen?

    /// How this chat pauses the video a Reader beside it is playing, by
    /// source id; set by the pane beside `openPanesProvider`. Nil for a chat
    /// with no Studio window around it, which pauses nothing.
    @ObservationIgnored var videoPauser: (@MainActor (String) -> Void)?

    /// How this chat opens a source in a Reader beside itself; set by the
    /// pane, nil for a chat with no Studio window around it. True when the
    /// source was opened.
    @ObservationIgnored var readerBesideChatOpener: (@MainActor (String) async -> Bool)?

    /// How this chat's window opens a Notebook with this chat in it, by
    /// Notebook and chat id; set by the pane, nil for a chat with no Studio
    /// window around it, which is filed in the Notebook and stays where it is.
    @ObservationIgnored var notebookWithThisChatOpener: (@MainActor (_ notebookID: String, _ sessionID: String) async -> Void)?

    @ObservationIgnored var sourceOpenedBesideChat: (id: String, at: Date)?

    /// What the walk is doing before a step can be drawn, for the line the
    /// transcript shows in its place: the record, figure index and PDF coming
    /// off the storage actor, then the anchor resolved against the page.
    ///
    /// A played step spends no model tokens, so none of this is a turn — and
    /// none of it used to say anything either, which left the chat blank
    /// through the whole wait (product owner, 2026-09-21, on pressing Walk Through:
    /// "loading that walkthrough actually was crazy long, for the longest time
    /// it just showed nothing"). It borrows the working line and its clock and
    /// nothing else: sends are neither queued nor blocked while it runs.
    var walkthroughPreparationDetail: String?
    var walkthroughPreparationDepth = 0

    /// Steps whose turn is being appended right now. Playing a step awaits
    /// the session, the anchor and the save before the turn lands, and more
    /// than one caller can ask for the same step in that time — the pane's
    /// Walk Through task running again, or two panes lending one manager —
    /// so a check of `playedStepIDs` alone let each of them append and save
    /// the step (2026-09-22: step 1 of 14 shown and saved three times).
    var walkthroughStepsBeingPlayed: Set<String> = []

    let toolResultEntrySeparator = "\n\n---\n\n"
}

/// Names and times the steps of one chat send's preparation, the work between
/// the learner pressing send and the model request leaving the app. Owned by the
/// manager, so main-actor only.
struct ChatSendPreparationTrace {
    private static let clock = ContinuousClock()
    private let startedAt: ContinuousClock.Instant
    private var lastMarkAt: ContinuousClock.Instant
    private(set) var steps: [(name: String, duration: Duration)] = []

    init() {
        startedAt = Self.clock.now
        lastMarkAt = startedAt
    }

    /// Close the step that ran since the previous mark (or the start).
    mutating func mark(_ name: String) {
        let now = Self.clock.now
        steps.append((name: name, duration: now - lastMarkAt))
        lastMarkAt = now
    }

    var total: Duration { Self.clock.now - startedAt }

    /// `"12.4s: Notebook files 11.9s · model 0.1s · session row 0.3s"`. The steps
    /// are listed in the order they ran, so the slow one reads in context.
    func summary() -> String {
        let parts = steps.map { "\($0.name) \(Self.format($0.duration))" }
        let detail = parts.isEmpty ? "no steps recorded" : parts.joined(separator: " · ")
        return "\(Self.format(total)): \(detail)"
    }

    static func format(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.1fs", seconds)
    }
}

/// The stored prefixes of a first-review target's id in a memory review's
/// `card_ids`. The strings are what sessions already hold, so they do not change.
enum MemoryFirstReviewTargetPrefix {
    /// A source with earlier whole-source review history, by portable source key.
    static let sourceRefreshPortable = "legacy-first-review-portable:"
    /// The same, by this library's own source id (sessions made before portable keys).
    static let sourceRefresh = "legacy-first-review:"
    /// A consumed source never reviewed, by portable source key.
    static let neverReviewedPortable = "new-first-review-portable:"
    /// The same, by this library's own source id (sessions made before portable keys).
    static let neverReviewed = "new-first-review:"
}
