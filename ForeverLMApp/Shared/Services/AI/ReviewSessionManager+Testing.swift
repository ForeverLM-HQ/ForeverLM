// Part of ReviewSessionManager: the debug-only hooks that tests call.

import Foundation

#if DEBUG
extension ReviewSessionManager {
    struct ChatPayloadSnapshot {
        let system: String
        let messages: [(role: String, content: String)]
    }

    func configureNavigationStateForTesting(sessionID: String, generationInFlight: Bool) {
        self.sessionID = sessionID
        sessionActive = true
        isGenerating = generationInFlight
        canStopGeneration = generationInFlight
    }

    /// A review whose first prompt is written before any turn, as a course
    /// quiz's chat and a teach-back open. The session row must already
    /// exist. The tutor is the one `startSession` gives a chat of that id.
    func openScriptedReviewForTesting(sessionID: String, opening: String) async {
        self.sessionID = sessionID
        sessionActive = true
        sessionPromptKind = Self.startingPromptKind(fixedSessionID: sessionID, mode: .review)
        await openWithScriptedMessage(opening)
    }

    /// The tutor a chat of this id and these exchanges goes on with when it
    /// is reopened (`resumeSession`), by its case name.
    static func resumedPromptKindForTesting(sessionID: String, exchanges: [ReviewExchangeRecord]) -> String {
        String(describing: promptKind(sessionID: sessionID, from: exchanges))
    }

    /// A chat as `startSession` starts it for `fixedSessionID` in `mode`:
    /// whether it is a teach-back, the mode it reports, whether it offers
    /// suggested questions, and its system prompt.
    static func startedChatForTesting(
        fixedSessionID: String?,
        mode: InitialPromptMode = .review
    ) -> (isTeachBack: Bool, mode: InitialPromptMode, offers: Bool, stable: String) {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        manager.sessionPromptKind = startingPromptKind(fixedSessionID: fixedSessionID, mode: mode)
        manager.sessionID = fixedSessionID
        manager.activeSourceIDs = ["source-1"]
        manager.sourceManifest = "- Test Paper (id: source-1, paper, readable text loaded)"
        let prompt = manager.systemPromptForGeneration(allowSourceRetrieval: true, nativeToolsActive: true)
        return (manager.isTeachBackSession, manager.currentPromptMode, manager.offersFollowUpQuestions, prompt.stableWithSources)
    }

    /// The learner's message, on screen and saved as a send saves it before
    /// its turn runs.
    func saveLearnerMessageForTesting(_ text: String) async {
        chatMessages.append(Message(role: .user, content: text))
        await persistPendingUserMessage(text)
    }

    /// A turn begins, as `performGenerationTurn` begins one.
    func beginTurnForTesting() {
        beginReplyPairing(isFirst: false)
    }

    /// The running turn's reply, saved as a finished turn saves it.
    func finishTurnForTesting(reply: String, config: AITaskConfig) async throws {
        chatMessages.append(Message(role: .assistant, content: reply))
        try await persistAssistantResponse(reply, isFirst: false, config: config)
        lastAssistantQuestion = reply
    }

    /// The running turn's reply settling as the generation loops settle one:
    /// its suggested questions split off, its row showing the prose, then
    /// `settleAnswer`, the loops' own last step, which stores the prose and
    /// keeps the questions on the row when this chat offers them. Returns
    /// the row, or nil when the turn failed and the row went.
    func settleReplyForTesting(_ reply: String, config: AITaskConfig) async throws -> Message? {
        let followUps = ChatFollowUps.split(reply)
        let row = Message(role: .assistant, content: followUps.prose)
        chatMessages.append(row)
        try await settleAnswer(
            followUps.prose,
            questions: followUps.questions,
            rowID: row.id,
            isFirst: false,
            config: config
        )
        return chatMessages.first { $0.id == row.id }
    }

    /// Whether a chat of `mode` offers suggested questions, and the system
    /// prompt it composes. `learnerWrote` is a chat the learner started by
    /// typing, which turns a review into study; `courseQuiz` and `sessionID`
    /// make it a quiz's chat or a day's memory review, and `walkthrough` a
    /// chat a walk is playing over.
    static func followUpGateForTesting(
        mode: InitialPromptMode,
        learnerWrote: Bool = false,
        courseQuiz: CourseQuizChatState? = nil,
        sessionID: String? = nil,
        walkthrough: WalkthroughPlayback? = nil
    ) -> (offers: Bool, stable: String, volatile: String) {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        manager.sessionPromptKind = learnerWrote
            ? mode.sessionPromptKindForUserMessage
            : mode.sessionPromptKindForAutomaticStart
        manager.courseQuiz = courseQuiz
        manager.sessionID = sessionID
        manager.walkthroughPlayback = walkthrough
        let prompt = manager.systemPromptForGeneration(allowSourceRetrieval: true, nativeToolsActive: true)
        return (manager.offersFollowUpQuestions, prompt.stableWithSources, prompt.volatile)
    }

    /// Stop, or Send now on a queued message, before the running turn has
    /// said anything: the cancellation path of `performGenerationTurn`. With
    /// `streamedRowShown` false the reply's row is already gone, as it is
    /// while a tool such as a quiz grade runs.
    func stopTurnBeforeReplyForTesting(streamedRowShown: Bool, config: AITaskConfig) async {
        let messageID = UUID()
        if streamedRowShown {
            chatMessages.append(Message(id: messageID, role: .assistant, content: ""))
        }
        userStoppedGeneration = true
        markRunningToolActivitiesStopped()
        await handleGenerationCancellation(messageID: messageID, isFirst: false, config: config)
        userStoppedGeneration = false
    }

    /// The slow free model offer's switch landing on the running turn with
    /// `streamed` of its reply written: the cancellation path of
    /// `performGenerationTurn` with a restart pending. True when the
    /// generation loop would ask the turn again.
    func restartTurnForTesting(streamed: String, config: AITaskConfig) async -> Bool {
        let messageID = UUID()
        chatMessages.append(Message(id: messageID, role: .assistant, content: streamed))
        pendingModelRestart = true
        userStoppedGeneration = true
        await handleGenerationCancellation(messageID: messageID, isFirst: false, config: config)
        userStoppedGeneration = false
        let restarts = turnRestartsOnSelectedModel
        turnRestartsOnSelectedModel = false
        return restarts
    }

    /// Attaches `sourceIDs` to this chat the way a resume restores them,
    /// without loading anything.
    func attachSourceIDsForTesting(_ sourceIDs: [String]) {
        activeSourceIDs = sourceIDs
    }

    /// A `save_card_drafts` step of the running turn that returned `result`,
    /// its row completed as the generation loops complete one. Returns the
    /// row's activity.
    func completeSaveCardDraftsForTesting(result: String) -> Message.ToolActivity? {
        let id = appendToolActivity(for: AppToolCall(name: "save_card_drafts", arguments: [:]))
        completeToolActivity(id, result: AppToolResult(text: result, isError: false))
        return chatMessages.first { $0.id == id }?.toolActivity
    }

    /// A `toolName` step of the running turn that returned `result`, its row
    /// completed as the generation loops complete one. Returns the row.
    func completeToolForTesting(_ toolName: String, result: String) -> Message? {
        let id = appendToolActivity(for: AppToolCall(name: toolName, arguments: [:]))
        completeToolActivity(id, result: AppToolResult(text: result, isError: false))
        return chatMessages.first { $0.id == id }
    }

    /// The rebuilt transcript with the page each tool row draws as a card.
    static func reconstructedWrittenPagesForTesting(
        from exchanges: [ReviewExchangeRecord]
    ) -> [(role: String, content: String, page: ChatWrittenPage?)] {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        return manager.messages(from: exchanges).map { message in
            let role: String
            switch message.role {
            case .user: role = "user"
            case .assistant: role = "assistant"
            case .tool: role = "tool"
            }
            return (role: role, content: message.content, page: message.toolActivity?.writtenPage)
        }
    }

    /// The rebuilt transcript with the saved cards each tool row draws.
    static func reconstructedSavedCardsForTesting(
        from exchanges: [ReviewExchangeRecord]
    ) -> [(role: String, content: String, savedCards: ChatSavedCards?)] {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        return manager.messages(from: exchanges).map { message in
            let role: String
            switch message.role {
            case .user: role = "user"
            case .assistant: role = "assistant"
            case .tool: role = "tool"
            }
            return (role: role, content: message.content, savedCards: message.toolActivity?.savedCards)
        }
    }

    static func reconstructedMessagesForTesting(from exchanges: [ReviewExchangeRecord]) -> [(role: String, content: String)] {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        return manager.messages(from: exchanges).map { message in
            (role: message.role == .user ? "user" : "assistant", content: message.content)
        }
    }

    /// The rebuilt transcript with the walkthrough step each assistant row
    /// plays, when it plays one: the marker read off the persisted turn, and
    /// the prose shown under it with the marker line gone.
    static func reconstructedWalkthroughRowsForTesting(
        from exchanges: [ReviewExchangeRecord]
    ) -> [(role: String, content: String, step: WalkthroughStepTurn.Marker?)] {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        return manager.messages(from: exchanges).map { message in
            (
                role: message.role == .user ? "user" : "assistant",
                content: message.content,
                step: message.walkthroughStep
            )
        }
    }

    /// What `resumeSession` does for a walk once past its model gate, which a
    /// test host without a signed-in model cannot pass: the transcript rebuilt
    /// from the exchanges, the source attached, and the playback restored.
    func restoreWalkthroughForTesting(
        exchanges: [ReviewExchangeRecord],
        article: StudioArticle?
    ) async -> WalkthroughPlayback? {
        chatMessages = messages(from: exchanges)
        activeArticles = article.map { [$0] } ?? []
        activeSourceIDs = article.map { [$0.id] } ?? []
        await restoreWalkthroughPlaybackIfNeeded()
        return walkthroughPlayback
    }

    /// One played step's turn as the live transcript builds it, for the row
    /// the resume path must reproduce.
    static func playedWalkthroughRowsForTesting(markdown: String) -> [(content: String, step: WalkthroughStepTurn.Marker?)] {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        return manager.assistantMessages(
            splitting: markdown,
            finalID: nil,
            createdAt: Date(),
            exchangeID: nil,
            exchangeField: .question,
            modelProvider: nil,
            modelID: nil
        ).map { (content: $0.content, step: $0.walkthroughStep) }
    }

    /// The rebuilt transcript with its heading rows: a source-turn row reports
    /// the source it names, a prose row its text.
    static func reconstructedTranscriptForTesting(
        from exchanges: [ReviewExchangeRecord],
        articles: [StudioArticle]
    ) -> [(role: String, content: String, sourceTurnID: String?)] {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        manager.activeArticles = articles
        return manager.messages(from: exchanges).map { message in
            let role: String
            switch message.role {
            case .user: role = "user"
            case .assistant: role = "assistant"
            case .tool: role = "tool"
            }
            return (
                role: role,
                content: message.content,
                sourceTurnID: message.toolActivity?.turnTargetID
            )
        }
    }

    static func resumedPayloadForTesting(
        messages: [(role: String, content: String)],
        systemPrompt: String
    ) -> ChatPayloadSnapshot {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        manager.chatMessages = messages.map { message in
            Message(role: message.role == "assistant" ? .assistant : .user, content: message.content)
        }
        let payload = manager.chatPayload(
            isFirst: false,
            systemPrompt: GenerationSystemPrompt(stable: systemPrompt, volatile: "")
        )
        return ChatPayloadSnapshot(system: payload.system.combined, messages: payload.messages)
    }

    static func attachedDocsPromptForTesting(
        docs: [ChatDocAttachment],
        appTools: [AppToolDefinition] = []
    ) -> String {
        let manager = ReviewSessionManager(
            storage: StorageService(storeRoot: temporaryTestingRoot()),
            appToolDefinitions: { appTools },
            appToolExecutor: appTools.isEmpty ? nil : { _, _, _ in AppToolResult(text: "", isError: false) }
        )
        for doc in docs { manager.addContextDoc(doc) }
        return manager.attachedDocsInstruction()
    }

    static func canvasContextPromptForTesting(
        context: KnowledgeMapChatContext?,
        appTools: [AppToolDefinition] = []
    ) -> String {
        let manager = ReviewSessionManager(
            storage: StorageService(storeRoot: temporaryTestingRoot()),
            appToolDefinitions: { appTools },
            appToolExecutor: appTools.isEmpty ? nil : { _, _, _ in AppToolResult(text: "", isError: false) }
        )
        if let context {
            manager.addCanvasCards(canvasID: context.canvasID, name: context.name, cards: context.cards, replacing: true)
        }
        return manager.canvasContextInstruction()
    }

    /// The provider payload for a run of learner turns with the context each
    /// carried, so a test can read what the tutor is told around a side
    /// question and around the answer that follows it.
    static func providerContentsForTesting(
        learnerTurns: [(visible: String, context: String?)]
    ) -> [String] {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        manager.chatMessages = learnerTurns.map { turn in
            Message(role: .user, content: turn.visible, contextualContent: turn.context)
        }
        let payload = manager.chatPayload(
            isFirst: false,
            systemPrompt: GenerationSystemPrompt(stable: "System", volatile: "")
        )
        return payload.messages.map(\.content)
    }

    static func contextualUserMessageForTesting(
        visibleContent: String,
        contextualContent: String
    ) -> (displayed: String, provider: String) {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        manager.chatMessages = [Message(
            role: .user,
            content: visibleContent,
            contextualContent: contextualContent
        )]
        let payload = manager.chatPayload(
            isFirst: false,
            systemPrompt: GenerationSystemPrompt(stable: "System", volatile: "")
        )
        return (manager.chatMessages[0].content, payload.messages[0].content)
    }

    static func strippingLeakedNativeToolPayloadsForTesting(
        _ text: String,
        toolName: String,
        argumentsJSON: String
    ) -> String {
        strippingLeakedNativeToolPayloads(
            text,
            toolCalls: [AIToolCallRequest(
                id: "test-call",
                name: toolName,
                argumentsJSON: argumentsJSON
            )]
        )
    }

    static func historyDigestPayloadForTesting(
        messages: [(role: String, content: String)],
        digest: String,
        coveredMessageCount: Int,
        systemPrompt: String
    ) -> ChatPayloadSnapshot {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        manager.chatMessages = messages.map { message in
            Message(role: message.role == "assistant" ? .assistant : .user, content: message.content)
        }
        manager.historyDigest = digest
        manager.historyDigestCoveredMessageCount = coveredMessageCount
        let payload = manager.chatPayload(
            isFirst: false,
            systemPrompt: GenerationSystemPrompt(stable: systemPrompt, volatile: "")
        )
        return ChatPayloadSnapshot(system: payload.system.combined, messages: payload.messages)
    }

    /// Exposes the stable/volatile system split so tests can assert that
    /// per-turn content (history digest, continuity instruction) never lands
    /// in the cacheable stable head.
    static func historyDigestPayloadPartsForTesting(
        messages: [(role: String, content: String)],
        digest: String,
        coveredMessageCount: Int,
        systemPrompt: String
    ) -> (stable: String, volatile: String) {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        manager.chatMessages = messages.map { message in
            Message(role: message.role == "assistant" ? .assistant : .user, content: message.content)
        }
        manager.historyDigest = digest
        manager.historyDigestCoveredMessageCount = coveredMessageCount
        let payload = manager.chatPayload(
            isFirst: false,
            systemPrompt: GenerationSystemPrompt(stable: systemPrompt, volatile: "")
        )
        return (stable: payload.system.stableWithSources, volatile: payload.system.volatile)
    }

    static func trimmedToolResultEntriesForTesting(_ context: String, budget: Int) -> String {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        return manager.trimmedToolResultEntries(context, budget: budget)
    }

    static func toolArgumentSummaryForTesting(_ arguments: [String: Any]) -> String? {
        toolArgumentSummary(arguments)
    }

    static func toolActivityDetailForTesting(
        toolName: String,
        arguments: [String: Any]
    ) -> String? {
        toolActivityDetail(toolName: toolName, arguments: arguments)
    }

    static func toolResultPreviewForTesting(toolName: String, result: String) -> String {
        toolResultPreview(toolName: toolName, result: result)
    }

    static func initialPayloadForTesting(
        mode: InitialPromptMode,
        topic: String,
        hasAttachedSource: Bool,
        sourceContext: String = ""
    ) -> ChatPayloadSnapshot {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        manager.topic = topic
        manager.sessionPromptKind = mode.sessionPromptKindForAutomaticStart
        if hasAttachedSource {
            manager.activeSourceIDs = ["source-1"]
            manager.sourceManifest = "- Test Source (id: source-1, article, readable text loaded)"
            manager.sourceContext = sourceContext
        }
        let system = manager.systemPromptForGeneration(allowSourceRetrieval: true)
        let payload = manager.chatPayload(isFirst: true, systemPrompt: system)
        return ChatPayloadSnapshot(system: payload.system.combined, messages: payload.messages)
    }

    static func switchedReviewPayloadForTesting(
        messages: [(role: String, content: String)],
        topic: String,
        hasAttachedSource: Bool,
        sourceContext: String = ""
    ) -> ChatPayloadSnapshot {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        manager.topic = topic
        manager.sessionPromptKind = .review
        manager.lastAssistantQuestion = nil
        manager.chatMessages = messages.map { message in
            Message(role: message.role == "assistant" ? .assistant : .user, content: message.content)
        }
        manager.chatMessages.append(Message(
            role: .user,
            content: Self.reviewSwitchInstruction
        ))
        if hasAttachedSource {
            manager.activeSourceIDs = ["source-1"]
            manager.sourceManifest = "- Test Source (id: source-1, article, readable text loaded)"
            manager.sourceContext = sourceContext
        }
        let system = manager.systemPromptForGeneration(allowSourceRetrieval: true)
        let payload = manager.chatPayload(isFirst: false, systemPrompt: system)
        return ChatPayloadSnapshot(system: payload.system.combined, messages: payload.messages)
    }

    static func displayableAssistantDeltaForTesting(_ delta: String) -> String? {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        return manager.displayableAssistantDelta(from: delta)
    }

    static func nativeSystemPromptForTesting(
        topic: String,
        hasAttachedSource: Bool,
        attachedSourceCount: Int = 1,
        appTools: [AppToolDefinition] = [],
        synthesisTitle: String? = nil,
        notebookScopeID: String? = nil,
        importFiling: NotebookImportFiling? = .files,
        madeThingFiling: MadeThingFiling?? = nil,
        mode: InitialPromptMode = .assistant,
        webSearch: WebSearchAccess = .unavailable
    ) -> String {
        let manager = ReviewSessionManager(
            storage: StorageService(storeRoot: temporaryTestingRoot()),
            appToolDefinitions: { appTools },
            appToolExecutor: appTools.isEmpty ? nil : { _, _, _ in AppToolResult(text: "", isError: false) }
        )
        manager.topic = topic
        manager.sessionPromptKind = mode.sessionPromptKindForAutomaticStart
        manager.notebookSourceScopeID = nonEmptyTrimmed(notebookScopeID)
        // What a turn would have read for the Notebook (`refreshNotebookImportFiling`).
        manager.notebookImportFiling = manager.notebookSourceScopeID == nil ? nil : importFiling
        // Its made things file as its imports do unless a test names otherwise.
        switch madeThingFiling {
        case .some(let given):
            manager.madeThingFiling = given
        case .none:
            manager.madeThingFiling = manager.notebookSourceScopeID.flatMap { id in
                manager.notebookImportFiling.map { MadeThingFiling(notebookID: id, filing: $0) }
            }
        }
        if hasAttachedSource {
            let ids = (1...max(1, attachedSourceCount)).map { "source-\($0)" }
            manager.activeSourceIDs = ids
            manager.sourceManifest = ids
                .map { "- Test Source \($0) (id: \($0), article, readable text loaded)" }
                .joined(separator: "\n")
        }
        if let synthesisTitle {
            manager.synthesisToolContext = SynthesisToolContext(title: synthesisTitle, markdown: "Notes")
        }
        return manager.systemPromptForGeneration(
            allowSourceRetrieval: true,
            nativeToolsActive: true,
            webSearch: webSearch
        ).combined
    }

    static func nativeToolSpecsForTesting(
        hasAttachedSource: Bool,
        appTools: [AppToolDefinition],
        hasSynthesisContext: Bool,
        mode: InitialPromptMode = .assistant,
        notebookScopeID: String? = nil,
        webSearch: WebSearchAccess = .unavailable,
        browserAgent: ChatBrowserAgent? = nil,
        codeRunner: ChatCodeRunner? = nil,
        openPanes: ChatOpenPanes? = nil,
        pointsReader: Bool = false,
        opensTeachBack: Bool = false
    ) -> [AIToolSpec] {
        let manager = ReviewSessionManager(
            storage: StorageService(storeRoot: temporaryTestingRoot()),
            appToolDefinitions: { appTools },
            appToolExecutor: { _, _, _ in AppToolResult(text: "", isError: false) },
            browserAgent: browserAgent,
            codeRunner: codeRunner
        )
        manager.sessionPromptKind = mode.sessionPromptKindForAutomaticStart
        manager.notebookSourceScopeID = nonEmptyTrimmed(notebookScopeID)
        if hasAttachedSource {
            manager.activeSourceIDs = ["source-1"]
            manager.sourceManifest = "- Test Source (id: source-1)"
        }
        if hasSynthesisContext {
            manager.synthesisToolContext = SynthesisToolContext(title: "Notebook", markdown: "Notes")
        }
        if let openPanes {
            manager.openPanesProvider = { openPanes }
        }
        // A pane showing the chat lends it a way to point the Reader.
        if pointsReader {
            manager.walkthroughFocusHandler = { _ in }
        }
        if opensTeachBack {
            manager.teachBackStarter = { _ in }
        }
        return manager.nativeToolSpecs(webSearch: webSearch)
    }

    /// A command-the-app chat over `appTools` that runs `load_app_tools` with
    /// each of `loads` in turn, returning every result and the tool list the
    /// next round would send.
    static func toolSpecsAfterLoadingForTesting(
        appTools: [AppToolDefinition],
        loads: [[String: Any]]
    ) -> (results: [AppToolResult], specs: [AIToolSpec]) {
        let manager = ReviewSessionManager(
            storage: StorageService(storeRoot: temporaryTestingRoot()),
            appToolDefinitions: { appTools },
            appToolExecutor: { _, _, _ in AppToolResult(text: "", isError: false) }
        )
        manager.sessionPromptKind = InitialPromptMode.assistant.sessionPromptKindForAutomaticStart
        let results = loads.map { manager.loadAppTools(arguments: $0) }
        return (results, manager.nativeToolSpecs())
    }

    /// `focus_source_anchor` as the chat runs it.
    func focusSourceAnchorForTesting(arguments: [String: Any]) async -> AppToolResult {
        await focusSourceAnchor(arguments: arguments)
    }

    static func notebookScopedArgumentsForTesting(
        toolName: String,
        arguments: [String: Any],
        notebookScopeID: String,
        importFiling: NotebookImportFiling? = .files,
        madeThingFiling: MadeThingFiling?? = nil
    ) -> [String: Any] {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        manager.notebookSourceScopeID = nonEmptyTrimmed(notebookScopeID)
        manager.notebookImportFiling = importFiling
        // By default the chat's scope is a Notebook whose made things file as
        // its imports do; a test of a Goal's chat names the Notebook.
        switch madeThingFiling {
        case .some(let given):
            manager.madeThingFiling = given
        case .none:
            manager.madeThingFiling = manager.notebookSourceScopeID.flatMap { id in
                importFiling.map { MadeThingFiling(notebookID: id, filing: $0) }
            }
        }
        return manager.notebookScopedArguments(toolName: toolName, arguments: arguments)
    }

    /// A Notebook chat's turn as far as its imports go: reads whether the
    /// Notebook takes them from `storage`, as each turn does, then pins an
    /// import's arguments and builds the prompt's Notebook guidance.
    static func notebookChatImportTurnForTesting(
        storage: StorageService,
        notebookScopeID: String,
        toolName: String,
        arguments: [String: Any]
    ) async -> (filing: NotebookImportFiling?, arguments: [String: Any], prompt: String) {
        let tools = ["import_paper_from_url", "add_source", "add_sources", "add_notebook_sources"].map {
            AppToolDefinition(name: $0, description: $0, inputSchemaJSON: "{\"type\":\"object\"}")
        }
        let manager = ReviewSessionManager(
            storage: storage,
            appToolDefinitions: { tools },
            appToolExecutor: { _, _, _ in AppToolResult(text: "", isError: false) }
        )
        manager.topic = "Notebook chat"
        manager.notebookSourceScopeID = nonEmptyTrimmed(notebookScopeID)
        await manager.refreshNotebookImportFiling()
        let pinned = manager.notebookScopedArguments(toolName: toolName, arguments: arguments)
        let prompt = manager.systemPromptForGeneration(allowSourceRetrieval: true, nativeToolsActive: true).combined
        return (manager.notebookImportFiling, pinned, prompt)
    }

    /// A chat's turn as far as what it makes goes: reads from `storage` where
    /// its made things are filed, as each turn does — its Notebook, or its
    /// Goal's — then fills a maker's arguments and builds the prompt.
    static func notebookChatMadeThingTurnForTesting(
        storage: StorageService,
        notebookScopeID: String,
        toolName: String,
        arguments: [String: Any]
    ) async -> (filing: MadeThingFiling?, arguments: [String: Any], prompt: String) {
        let tools = ["create_doc", "save_site", "save_animation", "generate_course", "create_course"].map {
            AppToolDefinition(name: $0, description: $0, inputSchemaJSON: "{\"type\":\"object\"}")
        }
        let manager = ReviewSessionManager(
            storage: storage,
            appToolDefinitions: { tools },
            appToolExecutor: { _, _, _ in AppToolResult(text: "", isError: false) }
        )
        manager.topic = "Notebook chat"
        manager.notebookSourceScopeID = nonEmptyTrimmed(notebookScopeID)
        await manager.refreshNotebookImportFiling()
        let filled = manager.notebookScopedArguments(toolName: toolName, arguments: arguments)
        let prompt = manager.systemPromptForGeneration(allowSourceRetrieval: true, nativeToolsActive: true).combined
        return (manager.madeThingFiling, filled, prompt)
    }

    /// Run one app tool call through a Notebook chat's executor. A Notebook chat
    /// must pass a library read straight through: the source the model asked for
    /// belongs to the learner, so nothing may be refused before the tool runs.
    static func notebookChatAppToolResultForTesting(
        storage: StorageService,
        notebookScopeID: String,
        attachedSourceIDs: [String] = [],
        toolName: String,
        arguments: [String: Any]
    ) async -> AppToolResult {
        let manager = ReviewSessionManager(
            storage: storage,
            appToolExecutor: { _, _, _ in AppToolResult(text: "the tool ran", isError: false) }
        )
        manager.notebookSourceScopeID = nonEmptyTrimmed(notebookScopeID)
        manager.activeSourceIDs = attachedSourceIDs
        return (try? await manager.executeAppToolCall(
            AppToolCall(name: toolName, arguments: arguments)
        )) ?? AppToolResult(text: "the call threw", isError: true)
    }

    static func memoryCompanionPromptForTesting(
        plan: MemoryCompanionPlan,
        currentTargetIndex: Int = 0,
        retry: Bool = false,
        struggleProjections: [String: MemoryStruggleProjection] = [:]
    ) -> (stable: String, volatile: String, toolSpecs: [AIToolSpec]) {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        manager.sessionPromptKind = .review
        manager.memoryCompanionPlan = plan
        manager.memoryStruggleProjections = struggleProjections
        manager.currentMemoryTargetIndex = currentTargetIndex
        manager.lastMemoryAttemptNeedsRetry = retry
        manager.activeSourceIDs = plan.sourceIDs
        manager.sourceManifest = plan.sourceIDs
            .map { "- Source (id: \($0), article, readable text available)" }
            .joined(separator: "\n")
        let prompt = manager.systemPromptForGeneration(
            allowSourceRetrieval: true,
            nativeToolsActive: true
        )
        return (prompt.stableWithSources, prompt.volatile, manager.nativeToolSpecs())
    }

    static func restoredMemoryCompanionStateForTesting(
        targetIDs: [String],
        items: [MemoryItem],
        attempts: [MemoryAttempt],
        session: ReviewSessionRecord,
        firstReviewSourceIDsByPortableKey: [String: String] = [:]
    ) throws -> (plan: MemoryCompanionPlan, currentTargetIndex: Int, needsRetry: Bool)? {
        guard let restored = try restoredMemoryCompanionState(
            targetIDs: targetIDs,
            items: items,
            attempts: attempts,
            session: session,
            firstReviewSourceIDsByPortableKey: firstReviewSourceIDsByPortableKey
        ) else { return nil }
        return (
            plan: restored.plan,
            currentTargetIndex: restored.currentTargetIndex,
            needsRetry: restored.needsRetry
        )
    }

    static func firstReviewSourceIDNeedingLoadForTesting(
        plan: MemoryCompanionPlan,
        currentTargetIndex: Int = 0,
        loadedSourceIDs: Set<String> = []
    ) -> String? {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        manager.memoryCompanionPlan = plan
        manager.currentMemoryTargetIndex = currentTargetIndex
        manager.loadedSourceIDs = loadedSourceIDs
        return manager.currentFirstReviewSourceIDNeedingLoad()
    }

    static func providerMessagesForTesting(from messages: [Message]) -> [(role: String, content: String)] {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        return manager.providerMessages(from: messages)
    }

    static func flattenedProviderMessagesForTesting(from turns: [AIChatTurn]) -> [(role: String, content: String)] {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        return manager.flattenedProviderMessages(from: turns)
    }

    static func trimmedNativeToolResultTurnsForTesting(
        _ turns: [AIChatTurn],
        systemPrompt: String,
        toolCharacters: Int = 0,
        config: AITaskConfig
    ) -> [AIChatTurn] {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        var mutable = turns
        manager.trimNativeToolResultTurnsIfNeeded(
            &mutable,
            systemPrompt: systemPrompt,
            toolCharacters: toolCharacters,
            config: config
        )
        return mutable
    }

    static func synthesisToolInstructionForTesting(title: String, markdown: String) -> String {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        manager.synthesisToolContext = SynthesisToolContext(title: title, markdown: markdown)
        return manager.synthesisToolInstruction(nativeToolsActive: false)
    }

    static func synthesisToolCallForTesting(_ response: String) -> SynthesisToolCall? {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        return manager.parseSynthesisToolCall(response)
    }

    /// Verbatim text for sources that were explicitly loaded. Attaching a pool
    /// never produces this — see `sourceManifestForTesting` for what a pool
    /// source actually contributes to the prompt.
    static func sourceContextContentForTesting(articles: [StudioArticle]) async -> String {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        manager.activeSourceIDs = articles.map(\.id)
        return await manager.loadSourceTextBlock(
            for: articles,
            budget: manager.sourceContextCharacterLimit
        ).text
    }

    /// Drops `droppedArticles` into a chat that already holds `existingMessages`
    /// and reports what the next message would carry: the pending additions
    /// as the transcript lists them, and the stored context of a message sent
    /// with `referenceContext`.
    static func contextAdditionsForTesting(
        existingMessages: [Message],
        droppedArticles: [StudioArticle],
        referenceContext: String? = nil
    ) async -> (pending: [ChatContextAdditions.Source], nextContext: String?) {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        manager.chatMessages = existingMessages
        manager.sessionActive = !existingMessages.isEmpty
        await manager.addContextSources(droppedArticles)
        let pending = manager.pendingContextAdditions
        return (pending, manager.attachPendingContextAdditions(to: referenceContext))
    }

    /// The stored context a message sent with `referenceContext` would carry
    /// in a chat whose window shows `openPanes` (nil: no window), with
    /// `leftOut` taken out by their chips' × first.
    static func onScreenContextForTesting(
        openPanes: ChatOpenPanes?,
        referenceContext: String?,
        leftOut: [String] = []
    ) -> String? {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        if let openPanes {
            manager.openPanesProvider = { openPanes }
        }
        leftOut.forEach(manager.leaveOutOnScreenSource)
        return manager.attachOnScreenSources(to: referenceContext)
    }

    static func droppedSourceContextForTesting(
        attachedArticles: [StudioArticle],
        droppedArticles: [StudioArticle],
        stageBeforeAttachment: Bool = false
    ) async -> (loadedIDs: Set<String>, context: String) {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        if stageBeforeAttachment {
            await manager.addContextSources(droppedArticles)
            let attachedContext = await manager.loadSourceContext(from: attachedArticles)
            await manager.applyAttachedSourceContext(
                attachedContext,
                articles: attachedArticles,
                preloading: []
            )
        } else {
            let attachedContext = await manager.loadSourceContext(from: attachedArticles)
            manager.foundSources = attachedContext.sources
            manager.sourceManifest = attachedContext.manifest
            manager.activeSourceIDs = attachedContext.sources.map(\.id)
            manager.activeArticles = attachedArticles
            await manager.addContextSources(droppedArticles)
        }
        return (manager.loadedSourceIDs, manager.sourceContext)
    }

    static func contextBreakdownForTesting(
        stableSystem: String,
        volatileSystem: String,
        sourceContext: String,
        perSourceShares: [ChatContextBreakdown.SourceShare],
        conversationCharacters: Int,
        toolCharacters: Int,
        config: AITaskConfig,
        sourceManifest: String = "",
        usage: AIUsageEvent? = nil
    ) -> ChatContextBreakdown? {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        manager.sourceContext = sourceContext
        manager.sourceManifest = sourceManifest
        manager.perSourcePromptShares = perSourceShares
        manager.publishContextBreakdown(
            system: GenerationSystemPrompt(stable: stableSystem, volatile: volatileSystem),
            conversationCharacters: conversationCharacters,
            toolCharacters: toolCharacters,
            config: config
        )
        if let usage { manager.calibrateContextBreakdown(with: usage) }
        return manager.contextBreakdown
    }

    static func crossCheckSelectionForTesting(
        rankedIDs: [String],
        requested: Set<String>,
        limit: Int
    ) -> [String] {
        crossCheckSelection(rankedIDs: rankedIDs, requested: requested, limit: limit)
    }

    static func focusedExcerptForTesting(
        content: String,
        query: String,
        limit: Int,
        bestChunkID: String? = nil
    ) -> String {
        focusedExcerpt(
            from: content,
            query: query,
            limit: limit,
            bestChunkID: bestChunkID
        )
    }

    static func sourceManifestForTesting(articles: [StudioArticle]) async -> String {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        return await manager.loadSourceContext(from: articles).manifest
    }

    static func appToolCallForTesting(_ response: String) -> (name: String, arguments: [String: Any])? {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        guard let call = manager.parseAppToolCall(response) else { return nil }
        return (call.name, call.arguments)
    }

    static func replyPromisesUncalledToolWorkForTesting(_ response: String) -> Bool {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        return manager.replyPromisesUncalledToolWork(response)
    }

    static func retrievalToolCallForTesting(_ response: String) -> Bool {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        return manager.parseRetrievalToolCall(response) != nil
    }

    static func retrievalToolCallWantsFullTextForTesting(_ response: String) -> Bool {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        return manager.parseRetrievalToolCall(response)?.wantsFullText == true
    }

    static func retrievalToolCallCursorForTesting(_ response: String) -> Int? {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        return manager.parseRetrievalToolCall(response)?.cursor
    }

    static func fullSourcePageForTesting(
        content: String,
        cursor: Int,
        limit: Int,
        sourceID: String = "source-1"
    ) -> (text: String, nextCursor: Int?) {
        let page = fullSourcePage(
            content: content,
            cursor: cursor,
            limit: limit,
            sourceID: sourceID
        )
        return (page.text, page.nextCursor)
    }

    static func outputTokenRetryPromptForTesting(systemPrompt: String, sourceContext: String) -> String {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        manager.sourceContext = sourceContext
        return manager.compactedSystemPromptForOutputTokenRetry(
            from: systemPrompt,
            allowSourceRetrieval: true
        )
    }

    static func finalizedVisibleResponseAfterOutputLimitForTesting(_ response: String) -> String? {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        return manager.finalizedVisibleResponseAfterOutputLimit(response)
    }

    static func sourceLinkTokensForTesting(_ response: String) -> [String] {
        sourceLinkTokens(in: response)
    }

    struct StablePrefixProbe {
        let stable: String
        let volatile: String
    }

    /// Builds the real generation system prompt twice, mutating between the two
    /// calls exactly the way a live session does after its first assistant
    /// reply: the session gets auto-retitled, the model edits the Notebook notes, and a
    /// turn's tool results land. `stable` must come back byte-identical or the
    /// prompt cache misses on every turn after the first.
    ///
    /// This deliberately goes through `systemPromptForGeneration` rather than
    /// constructing `GenerationSystemPrompt` directly — the point is to catch a
    /// mutable field drifting into the stable half.
    static func stablePrefixAcrossTurnsForTesting(
        sourceContext: String,
        firstTopic: String,
        retitledTopic: String,
        firstNotebookNotesMarkdown: String,
        editedNotebookNotesMarkdown: String,
        notebookInstructions: String? = nil,
        researchQuestions: [String] = [],
        repository: String? = nil,
        notebookMaterialsMarkdown: String = ""
    ) -> (first: StablePrefixProbe, second: StablePrefixProbe) {
        let manager = ReviewSessionManager(storage: StorageService(storeRoot: temporaryTestingRoot()))
        manager.sessionPromptKind = .review
        manager.sourceContext = sourceContext
        manager.topic = firstTopic
        manager.synthesisToolContext = SynthesisToolContext(
            title: "Notebook Under Test",
            markdown: firstNotebookNotesMarkdown,
            instructions: notebookInstructions,
            researchQuestions: researchQuestions,
            repository: repository,
            notebookMaterialsMarkdown: notebookMaterialsMarkdown
        )

        let first = manager.systemPromptForGeneration(allowSourceRetrieval: true, nativeToolsActive: true)

        // Everything a real turn 2 changes.
        manager.topic = retitledTopic
        manager.synthesisToolContext = SynthesisToolContext(
            title: "Notebook Under Test",
            markdown: editedNotebookNotesMarkdown,
            instructions: notebookInstructions,
            researchQuestions: researchQuestions,
            repository: repository,
            notebookMaterialsMarkdown: notebookMaterialsMarkdown
        )
        manager.appToolResultContext = "search_sources_semantic returned 3 excerpts."

        let second = manager.systemPromptForGeneration(allowSourceRetrieval: true, nativeToolsActive: true)

        return (
            StablePrefixProbe(stable: first.stableWithSources, volatile: first.volatile),
            StablePrefixProbe(stable: second.stableWithSources, volatile: second.volatile)
        )
    }

    private static func temporaryTestingRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewSessionManagerTests-\(UUID().uuidString)", isDirectory: true)
    }
}
#endif
