// Part of ReviewSessionManager: published chat state, send preparation and prompt mode.

import Foundation

extension ReviewSessionManager {
    /// A message sent while a turn was still running. It is not in
    /// `chatMessages`: a user turn appended under a reply that is still being
    /// written would ride into that reply's next tool round and break the
    /// alternation the provider expects. It waits here, is drawn above the
    /// composer (`ReviewChatQueuedMessages`), and becomes a real message the
    /// moment that turn ends.
    struct QueuedFollowUp: Identifiable, Equatable {
        let id: UUID
        let text: String
        let contextualContent: String?
        let docAnchor: ChatDocAnchor?
    }
    /// True when a send made now waits for the running turn rather than
    /// starting one: anything of a turn is still in flight, or earlier sends
    /// are already waiting and this one belongs behind them.
    var queuesSendsNow: Bool {
        isPreparingGeneration || isGenerating || canStopGeneration || activeGenerationTask != nil
            || !queuedFollowUps.isEmpty
    }
    /// Work that is not a turn and has no turn to queue behind: a saved chat
    /// hydrating, sources being attached. The composer holds for these only.
    var isBusyOutsideTurn: Bool {
        isSearching && !isPreparingGeneration && !isGenerating
    }
    /// The model the running turn was sent to, from the moment its config is
    /// resolved until the turn ends. Nil between turns and while a scheduled
    /// task's `modelOverride` stands in for the chat's model. The offer to
    /// leave a slow free model reads it (`SlowFreeModelOffer`).
    struct TurnModel: Equatable {
        let provider: AIProvider
        let model: String
        /// Free to run (`AIModelCatalog.isFree`): a `:free` variant, the Free
        /// Models Router, or a model listed at nothing.
        let isFree: Bool
        let startedAt: Date
    }
    var currentSessionID: String? { sessionID }
    var linkedSourceIDs: [String] { activeSourceIDs }
    /// Whether anything has been said here, or is being said: a conversation
    /// exists once the chat has a row, a live session, or a message on its
    /// way. The same three checks `clearStagedSources` refuses on; without
    /// any of them the chat is an idle composer, whatever it has staged.
    var hasConversation: Bool {
        sessionID != nil || sessionActive || !chatMessages.isEmpty
    }
    /// Navigation keeps a manager alive while any part of a turn can still
    /// produce or prepare a response. View disappearance is not a stop signal.
    var hasGenerationWorkInFlight: Bool {
        isPreparingGeneration
            || isSearching
            || isGenerating
            || canStopGeneration
            || activeGenerationTask != nil
    }

    /// A turn that failed has saved nothing but the learner's message: the
    /// steps it ran, its error, Retry and any message waiting under that
    /// Retry are held here only. Reopening the chat from storage shows the
    /// bare message, as if nothing had been tried.
    var holdsFailedTurn: Bool {
        lastGenerationFailed && sessionActive && sessionID != nil && !failedTurnCameFromStorage
    }

    /// Whether leaving this chat for another must keep the manager: a turn
    /// is still at work, or one failed and what it left exists nowhere else.
    var mustOutliveNavigation: Bool {
        hasGenerationWorkInFlight || holdsFailedTurn
    }

    /// Covers the source/context preparation that happens before
    /// `sendMessage` enters the manager. Without this lease, an immediate chat
    /// switch could release the manager in the brief interval between showing
    /// the optimistic user bubble and starting the generation turn.
    func beginGenerationPreparation() {
        generationPreparationDepth += 1
        isPreparingGeneration = true
    }

    func endGenerationPreparation() {
        generationPreparationDepth = max(0, generationPreparationDepth - 1)
        isPreparingGeneration = generationPreparationDepth > 0
        if !isPreparingGeneration {
            sendPreparationDetail = nil
        }
    }

    /// Start timing a send. The panel calls this before its own preparation
    /// (Notebook files, source downloads) so those steps are counted too.
    func beginSendPreparationTrace() {
        sendPreparationTrace = ChatSendPreparationTrace()
    }

    func beginSendPreparationTraceIfNeeded() {
        if sendPreparationTrace == nil { beginSendPreparationTrace() }
    }

    /// Close the step that just finished under `step`.
    func markSendPreparation(_ step: String) {
        sendPreparationTrace?.mark(step)
    }

    /// Name the source a send is waiting on (nil once it is done); the working
    /// indicator shows it in place of the generic preparing line.
    func setSendPreparationDetail(_ detail: String?) {
        let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        sendPreparationDetail = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// The send did not reach generation; nothing to attribute.
    func discardSendPreparationTrace() {
        sendPreparationTrace = nil
        sendPreparationDetail = nil
    }

    var currentPromptMode: InitialPromptMode {
        switch sessionPromptKind {
        case .summarize: return .summarize
        case .shallowRead: return .shallowRead
        case .deepRead: return .deepRead
        case .deepResearch: return .deepResearch
        case .agent: return .assistant
        case .review, .study, .teachBack: return .review
        }
    }
    var isDeepResearchMode: Bool { sessionPromptKind == .deepResearch }
    /// Whether the chat is the Feynman Technique: the learner explains,
    /// the tutor asks and fills in (`TeachBack`).
    var isTeachBackSession: Bool { sessionPromptKind == .teachBack }
    /// A chat whose tutor asks and the learner answers: a review, or a
    /// teach-back. Each turn is kept as the tutor's question and the answer
    /// to it, and neither offers suggested questions or files its sources'
    /// citations as reading.
    var isTutorLed: Bool { sessionPromptKind == .review || sessionPromptKind == .teachBack }

    /// How a turn reaches live web search on its model route.
    ///
    /// Chat is not a mode switch away from the web: "look that up" has to work
    /// in the conversation the learner is already in. What differs per route is
    /// what an idle search engine costs, and that decides how it is attached.
    enum WebSearchAccess: Equatable {
        /// No web engine ForeverLM can bill per request (Google AI Studio's
        /// account-wide allowance), or a route with no web path at all.
        case unavailable
        /// The provider's own search tool rides every round. Idle it costs
        /// nothing — only the searches the model performs bill — so the model
        /// decides when to search, the way it decides when to read a source.
        case native
        /// The route's engine (OpenRouter's Exa fallback) searches once per
        /// request unconditionally, so it must not ride every round. The model
        /// asks through `request_web_search`, and only the next round carries it.
        case onRequest
    }

    /// Web access for an ordinary Chat turn on `config`, judged on the route
    /// the request will actually travel: under the OpenRouter transport policy
    /// a first-party selection becomes an OpenRouter slug, and the slug decides
    /// which engine answers.
    static func webSearchAccess(for config: AITaskConfig) -> WebSearchAccess {
        let routed = KeychainService.routedTextSelection(
            provider: config.provider,
            model: config.model,
            speed: config.speed
        )
        return webSearchAccess(
            selectedProvider: config.provider,
            routedProvider: routed.provider,
            routedModel: routed.model,
            speed: config.speed
        )
    }

    static func webSearchAccess(
        selectedProvider: AIProvider,
        routedProvider: AIProvider,
        routedModel: String,
        speed: AISpeed? = nil
    ) -> WebSearchAccess {
        // The rule Deep Research applies too: Gemini's search allowance is
        // account-wide, so a Gemini selection stays off the web whatever
        // transport carries it.
        guard selectedProvider != .gemini else { return .unavailable }
        switch routedProvider {
        case .anthropic, .openai, .xai, .meta:
            return .native
        case .gemini:
            return .unavailable
        case .openRouter, .groq, .cerebras, .together, .fireworks, .nvidia:
            guard AIService.routesThroughOpenRouter(routedProvider) else { return .unavailable }
            let slug = AIService.openAICompatibleModelID(
                provider: routedProvider,
                model: routedModel
            )
            return AIService.openRouterSlugHasNativeWebSearch(slug) ? .native : .onRequest
        }
    }

    /// Switch the conversational surface without creating a parallel chat. The
    /// next turn resolves the corresponding task model and web-search policy.
    func setAssistantMode(_ mode: InitialPromptMode) {
        guard !isSearching, !isGenerating else { return }
        switch mode {
        case .assistant:
            sessionPromptKind = .agent
        case .shallowRead:
            sessionPromptKind = .shallowRead
        case .deepRead:
            sessionPromptKind = .deepRead
        case .deepResearch:
            sessionPromptKind = .deepResearch
        case .review, .summarize:
            return
        }
        errorMessage = nil
    }
    var canRetryLastGeneration: Bool {
        lastGenerationFailed && sessionActive && !isGenerating && !isSearching
    }
    typealias ChatSessionCost = KnowledgeStore.AIUsageSessionCost
    enum NotebookImportFiling: Equatable {
        case files
        case libraryOnly(NotebookImportRefusal)
    }

    struct MadeThingFiling: Equatable {
        let notebookID: String
        let filing: NotebookImportFiling
        /// The notebook's team; nil for a notebook of My Library. A course is
        /// made in My Library, so a team notebook's chat files no course in it
        /// (`create_course` and `generate_course` refuse a team's Notebook).
        var teamID: String? = nil
    }

    /// The notebook this turn's made things are filed in, when it takes them.
    var madeThingNotebookID: String? {
        guard let madeThingFiling, madeThingFiling.filing == .files else { return nil }
        return madeThingFiling.notebookID
    }

    /// A chat with exactly one attached source is source-bound usage. Multi-
    /// source and library-wide chats deliberately remain unscoped because
    /// assigning their whole cost to one record would be false attribution.
    private var singleSourceUsageAttribution: AIUsageSource? {
        guard activeSourceIDs.count == 1, let sourceID = activeSourceIDs.first else { return nil }
        if let article = activeArticles.first(where: { $0.id == sourceID }) {
            return AIUsageSource(source: article)
        }
        guard let found = foundSources.first(where: { $0.id == sourceID }) else { return nil }
        return AIUsageSource(id: found.id, type: found.sourceType, title: found.title)
    }

    func withSingleSourceUsageAttribution<Result>(
        operation: () async throws -> Result
    ) async rethrows -> Result {
        guard let source = singleSourceUsageAttribution else {
            return try await operation()
        }
        return try await AIUsageAttribution.withSource(
            source,
            activityID: sessionID ?? UUID().uuidString,
            operation: operation
        )
    }
    /// Whether the review is organized by topic.
    var isTopicMemoryReview: Bool { isMemoryReviewSession && !memoryReviewTopics.isEmpty }
    /// An idea of today's review by id: statement, source and anchors for the ledger.
    func memoryReviewIdea(_ ideaID: String) -> SourceIdea? {
        guard let sourceID = SourceIdea.sourceID(fromIdeaID: ideaID) else { return nil }
        return memoryReviewIdeasBySource[sourceID]?.first { $0.id == ideaID }
    }
    /// The ids of one source's ideas in today's review, in the order they
    /// were extracted: what a source card's ledger lists in a review planned
    /// source by source, which has no topic to carry them.
    func memoryReviewIdeaIDs(forSource sourceID: String) -> [String] {
        memoryReviewIdeasBySource[sourceID]?.map(\.id) ?? []
    }
    /// Set only after a grade or skip has moved the sitting, so the reply that
    /// follows gets the answered question's picture for the answer
    /// (`placingCourseQuizPictures`). The tutor is told what the picture
    /// shows, never its address.
    enum PendingCourseQuizPictureTurn {
        case graded(questionIndex: Int, isCorrection: Bool)
        case skipped

        var answeredQuestionIndex: Int? {
            if case .graded(let questionIndex, _) = self { return questionIndex }
            return nil
        }

        var isCorrection: Bool {
            if case .graded(_, let isCorrection) = self { return isCorrection }
            return false
        }
    }
    /// True while the source under discussion has a graded contour: the chat
    /// shows the Go deeper and Next chips under its newest settled reply. The
    /// tutor is told never to leave a source unasked, so the chips have to be
    /// there after every probe and under its closing offer, not only under the
    /// graded reply. Derived, so it follows the strip's current source and the
    /// checkmarks wherever they change.
    var offersMemoryReviewSteer: Bool {
        MemoryReviewSourceStatus.offersSteer(
            currentSourceID: memoryReviewCurrentSourceID,
            statuses: memoryReviewStatusBySource
        )
    }
    static let sourceTurnActivityName = "memory_source_turn"
    /// An exchange row a reply is written to, in the chat it belongs to.
    struct ReplyRow: Equatable {
        let sessionID: String
        let sequence: Int
    }
    static let fallbackSourceContextCharacterLimit = 64_000
    /// Separator between loaded source blocks in `sourceContext`.
    ///
    /// Shared rather than written inline at each site: the retry compactors
    /// locate individual blocks by splitting on exactly this string, so two
    /// literals drifting apart would silently disable context-overflow
    /// recovery instead of failing.
    static let sourceBlockSeparator = "\n\n---\n\n"
    /// Per-request cap on the resident block: the same budget, so text loaded
    /// for a large window is never trimmed back to a smaller one on send.
    var sourceContextPromptCharacterLimit: Int { sourceContextCharacterLimit }
    static let reviewSwitchInstruction = "Let's switch to a review. Start with a compact concept checklist, then ask me one deep question."
}
