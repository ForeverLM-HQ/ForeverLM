// Part of ReviewSessionManager: starting a generation and running the text and native turns.

import Foundation

extension ReviewSessionManager {
    private func finishSendPreparationTrace() {
        sendPreparationDetail = nil
        guard let trace = sendPreparationTrace else { return }
        sendPreparationTrace = nil
        let summary = trace.summary()
        if trace.total >= .seconds(2) {
            logger.notice("Send preparation took \(summary, privacy: .public)")
        } else {
            logger.info("Send preparation took \(summary, privacy: .public)")
        }
    }
    /// `start_feynman_technique`: asks the pane to open the Feynman Technique
    /// in this chat's Notebook. The pane opens it when the answer ends, as a
    /// new chat, since a chat's tutor is named by its id and this one's is
    /// fixed.
    private func startFeynmanTechnique() -> AppToolResult {
        guard let teachBackStarter, let notebookID = notebookSourceScopeID else {
            return AppToolResult(text: "Error: The Feynman Technique opens from a chat in a Notebook, and this chat is in none.", isError: true)
        }
        teachBackStarter(notebookID)
        return AppToolResult(
            text: "The Feynman Technique opens in a new chat in this Notebook when this answer ends. Say in one short line that it is opening, and nothing more.",
            isError: false
        )
    }

    /// `grade_quiz_answer`: the quiz's grader on the learner's answer to the
    /// question the quiz is on, run on `chatConfig`, the model this turn runs
    /// on, in a call of its own. The tutor learns the verdict and the
    /// reference answer only from this result. A first answer the grader
    /// follows up instead comes back as the follow-up to ask, with nothing
    /// graded. The grader asks again in place when its model stumbles; a
    /// grade it still cannot give is an error the tutor must report, naming
    /// that model, and nothing stands in for it.
    private func gradeCourseQuizAnswer(
        arguments: [String: Any],
        isFirst: Bool,
        chatConfig: AITaskConfig
    ) async -> AppToolResult {
        guard let quiz = courseQuiz else {
            return AppToolResult(text: "Error: This chat is not running a quiz.", isError: true)
        }
        guard !isFirst else {
            return AppToolResult(
                text: "Error: The learner has not answered yet. Ask question 1 now.",
                isError: true
            )
        }
        switch quiz.questionToGrade(arguments: arguments) {
        case .failure(let error):
            return AppToolResult(text: "Error: \(error.message)", isError: true)
        case .success(let target):
            let question = quiz.questions[target.index]
            let isCorrection = quiz.isFinished
            let gradingSessionID = sessionID
            let grader = CourseQuizChatState.graderConfig(forChat: chatConfig)
            do {
                let checked = try await quiz.request.grade(question, target.attempt, grader)
                // The chat may have changed while the grader ran.
                guard let gradingSessionID, sessionID == gradingSessionID, courseQuiz != nil else {
                    return AppToolResult(text: "Error: The quiz was closed.", isError: true)
                }
                let grade: VideoQuizGrade
                switch checked.result {
                case .followUp(let followUp):
                    courseQuiz?.recordFollowUp(followUp, answer: target.attempt.answer, forQuestionAt: target.index)
                    guard let updated = courseQuiz else {
                        return AppToolResult(text: "Error: The quiz was closed.", isError: true)
                    }
                    // Kept with the chat, so a reply after a reopen is still
                    // graded with the answer it finishes. Losing it costs only
                    // that pairing, so the learner is not told.
                    _ = await keepCourseQuizSitting(updated, sessionID: gradingSessionID)
                    return AppToolResult(
                        text: updated.followUpRequest(forQuestionAt: target.index, followUp: followUp),
                        isError: false
                    )
                case .graded(let graded):
                    grade = graded
                }
                courseQuiz?.record(grade.verdict, forQuestionAt: target.index)
                guard let updated = courseQuiz else {
                    return AppToolResult(text: "Error: The quiz was closed.", isError: true)
                }
                // Kept with the chat at once, so a chat closed right after
                // this answer picks up at the next question.
                let saveError = await keepCourseQuizSitting(updated, sessionID: gradingSessionID)
                updated.request.recorded(gradingSessionID, updated.progress(sessionID: gradingSessionID))
                pendingCourseQuizPictureTurn = .graded(questionIndex: target.index, isCorrection: isCorrection)
                var text = updated.acknowledgement(
                    forQuestionAt: target.index,
                    grade: grade,
                    memoryError: checked.memoryError,
                    isCorrection: isCorrection
                )
                if let saveError {
                    text += "\nThis grade could not be saved with the chat (\(saveError)): if the chat is closed now, the quiz will ask this question again. Tell the learner in a few words."
                }
                return AppToolResult(text: text, isError: false)
            } catch {
                // Stop, or a queued message sent now: the turn ends at the
                // next round, and the row reads as stopped, not as a grade
                // its model could not give.
                if AITransientErrorClassifier.isCancellation(error) {
                    return AppToolResult(text: "Stopped before the tool finished.", isError: true)
                }
                logger.error("grade_quiz_answer failed: \(error.localizedDescription, privacy: .public)")
                // The grader already asked again in place. A failure its
                // model could be the cause of (busy, rate-limited, a dropped
                // stream, a reply that is not a grade) names that model, the
                // chat's own, so the tutor can propose switching it.
                var model: CourseQuizChatState.GraderModel?
                if let failure = error as? QuizGradingFailure, failure.anotherModelCouldGrade {
                    model = CourseQuizChatState.GraderModel(name: failure.modelName, isFree: failure.modelIsFree)
                }
                return AppToolResult(
                    text: CourseQuizChatState.gradingFailure(
                        error.localizedDescription,
                        questionNumber: target.index + 1,
                        model: model
                    ),
                    isError: true
                )
            }
        }
    }

    /// `skip_quiz_question`: the learner asked in words to skip the question
    /// the quiz is on. Nothing is graded and nothing reaches Memory; the tutor
    /// learns the next question, or the result after the last one.
    private func skipCourseQuizQuestion(arguments: [String: Any], isFirst: Bool) async -> AppToolResult {
        guard let quiz = courseQuiz else {
            return AppToolResult(text: "Error: This chat is not running a quiz.", isError: true)
        }
        guard !isFirst else {
            return AppToolResult(
                text: "Error: The learner has not asked to skip anything yet. Ask question 1 now.",
                isError: true
            )
        }
        switch quiz.questionToSkip(arguments: arguments) {
        case .failure(let error):
            return AppToolResult(text: "Error: \(error.message)", isError: true)
        case .success(let index):
            guard let text = await applyCourseQuizSkip(at: index) else {
                return AppToolResult(text: "Error: The quiz was closed.", isError: true)
            }
            return AppToolResult(text: text, isError: false)
        }
    }

    /// The stored quiz, not the tutor model, puts the quiz's pictures in every
    /// reply of a quiz chat: what the tutor wrote of them is taken out, and
    /// the answered question's picture, with the link to where the lecture
    /// says it, and each asked question's own go where they belong
    /// (`CourseQuizChatState.placingPictures`). The tutor is told what a
    /// picture shows, never its address, so it has none to copy wrong or to
    /// make up.
    private func placingCourseQuizPictures(in response: String) -> String {
        guard let courseQuiz else { return response }
        let pending = pendingCourseQuizPictureTurn
        pendingCourseQuizPictureTurn = nil
        return courseQuiz.placingPictures(
            in: response,
            answeredQuestionIndex: pending?.answeredQuestionIndex,
            isCorrection: pending?.isCorrection ?? false
        )
    }

    /// `read_planned_reading`: the pages the course planned for one of the
    /// quiz's lectures, read from the chapter's stored text, so the tutor can
    /// summarize a reading or find where the book explains a question.
    private func readPlannedReading(arguments: [String: Any]) async -> AppToolResult {
        guard let quiz = courseQuiz else {
            return AppToolResult(text: "Error: This chat is not running a quiz.", isError: true)
        }
        switch quiz.readingToRead(arguments: arguments) {
        case .failure(let error):
            return AppToolResult(text: "Error: \(error.message)", isError: true)
        case .success(let target):
            guard let content = await storage.loadSourceContent(target.reading.chapterID) else {
                return AppToolResult(
                    text: "Error: The chapter \(target.reading.chapterTitle) has no text on this Mac yet. Tell the learner, and give them the reading's link \(target.reading.link) to open it.",
                    isError: true
                )
            }
            let pages = target.reading.pages
            let text = await Task.detached(priority: .userInitiated) {
                CourseQuizReading.text(of: pages, in: content)
            }.value
            guard let text else {
                return AppToolResult(
                    text: "Error: The chapter's text has none of the reading's pages (\(target.reading.place)). Tell the learner, and give them the reading's link \(target.reading.link) to open it.",
                    isError: true
                )
            }
            return AppToolResult(
                text: CourseQuizChatState.readingResult(number: target.number, reading: target.reading, text: text),
                isError: false
            )
        }
    }

    /// Reads the bytes of every attached picture named in the transcript that
    /// this device holds on disk but not yet in memory — a chat resumed from
    /// history — off the main actor, so turn assembly can stay synchronous.
    private func hydrateAttachedImages() async {
        let ids = Set(
            chatMessages
                .filter { $0.role == .user }
                .flatMap { AttachedImageReference.split($0.content).images.map(\.reference.id) }
        ).filter { AttachedImageStore.cached(id: $0) == nil }
        guard !ids.isEmpty else { return }
        await Task.detached(priority: .userInitiated) {
            for id in ids { _ = AttachedImageStore.read(id: id) }
        }.value
    }

    /// Reads into memory, off the main actor, the frame of every moment in the
    /// transcript that went to the model as a picture and is not held yet — a
    /// chat resumed from history — so turn assembly can stay synchronous. A
    /// frame this Mac never captured stays out, and its turn says so.
    private func hydrateVideoMomentFrames() async {
        let references = Set(
            chatMessages
                .filter { $0.role == .user }
                .flatMap { message in
                    ChatContextAdditions.parse(contextContent: message.contextualContent).onScreen
                        .compactMap { shown -> SourceImageReference? in
                            guard let moment = shown.moment, moment.frame == true else { return nil }
                            return moment.frameReference(sourceID: shown.id)
                        }
                }
        ).filter { VideoMomentFrames.cached($0) == nil }
        guard !references.isEmpty else { return }
        await Task.detached(priority: .userInitiated) {
            for reference in references {
                guard let rendered = SourceImageCatalog.renderMoment(reference) else { continue }
                VideoMomentFrames.stage(AttachedImage(data: rendered.data, mediaType: rendered.mediaType), for: reference)
            }
        }.value
    }

    // MARK: - AI Generation

    /// Generation driver. If a turn is already running, the just-sent message
    /// (already appended and persisted) is queued and answered in a follow-up
    /// turn as soon as the running one finishes — sending mid-generation never
    /// silently drops a message. Messages the learner sent while this turn ran
    /// wait in `queuedFollowUps` and are admitted one per turn here, in order,
    /// for as long as each turn ends well; a failed turn leaves them waiting
    /// under its Retry rather than sending them into the same failure.
    func generateQuestion(isFirst: Bool) async {
        guard !isGenerating else {
            // Queued behind a running turn; the wait ahead is that turn's, not
            // this send's preparation.
            discardSendPreparationTrace()
            followUpGenerationRequested = true
            return
        }
        var first = isFirst
        repeat {
            followUpGenerationRequested = false
            await performGenerationTurn(isFirst: first)
            if turnRestartsOnSelectedModel {
                // The same turn again, on the model the learner just picked,
                // before anything queued behind it.
                turnRestartsOnSelectedModel = false
                followUpGenerationRequested = true
                continue
            }
            first = false
            if !followUpGenerationRequested, sessionActive, !lastGenerationFailed, !queuedFollowUps.isEmpty {
                let next = queuedFollowUps.removeFirst()
                await admitQueuedFollowUp(next)
                followUpGenerationRequested = true
            }
        } while followUpGenerationRequested && sessionActive && !lastGenerationFailed
    }

    private func performGenerationTurn(isFirst: Bool) async {
        guard !isGenerating else { return }
        isGenerating = true
        finishSendPreparationTrace()
        canStopGeneration = true
        errorMessage = nil
        lastGenerationError = nil
        lastGenerationFailed = false
        userStoppedGeneration = false
        turnReplyWriteStarted = false
        turnFollowsSavedFailedReply = retryFollowsSavedFailedReply
        retryFollowsSavedFailedReply = false
        failedTurnReplySaved = false
        beginReplyPairing(isFirst: isFirst)
        removeProviderMetadataMessages()

        let generationID = UUID()
        activeGenerationID = generationID
        let turnStartedAt = Date()
        defer {
            if activeGenerationID == generationID {
                activeGenerationTask = nil
                activeGenerationID = nil
                canStopGeneration = false
                userStoppedGeneration = false
                pendingModelRestart = false
                turnModel = nil
            }
            isGenerating = false
        }

        let followsChatSelection = modelOverride == nil
        guard let config = await resolvedGenerationConfigOrShowError() else {
            lastGenerationFailed = true
            await discardEmptyAutomaticStartIfNeeded(isFirst: isFirst)
            return
        }
        // Refused here, with the message kept and Retry offered, rather than
        // sent to a model that would answer about a picture it never saw.
        if let refusal = Self.visionRefusal(
            for: config,
            latestUserMessage: chatMessages.last(where: { $0.role == .user })?.content
        ) {
            errorMessage = refusal
            lastGenerationFailed = true
            return
        }

        let streamedAssistantMessageID = UUID()
        if followsChatSelection {
            // Priced off-main: the catalog snapshot can rebuild on a price refresh.
            let provider = config.provider
            let model = config.model
            let isFree = await Task.detached(priority: .userInitiated) {
                AIModelCatalog.isFree(provider: provider, modelID: model)
            }.value
            turnModel = TurnModel(provider: provider, model: model, isFree: isFree, startedAt: turnStartedAt)
        }
        appToolResultContext = ""

        // The entire turn — streaming, tool execution, and tool-result
        // compaction — runs inside one cancellable task, so Stop interrupts it
        // wherever it currently is (not just mid-stream). The usage-attribution
        // binding rides the same scope: every ledger row the turn produces,
        // including overflow-compaction calls and a stream that dies
        // mid-request, lands under this session's ID. The history fold is not
        // part of the turn: it runs in its own background task with its own
        // binding, so Stop leaves it alone and it never delays the reply.
        let turnTask = Task { @MainActor in
            try await AIUsageAttribution.$sessionID.withValue(self.sessionID) {
                try await self.runGenerationTurn(
                    isFirst: isFirst,
                    config: config,
                    streamedAssistantMessageID: streamedAssistantMessageID
                )
            }
        }
        activeGenerationTask = turnTask

        do {
            try await turnTask.value
        } catch is CancellationError {
            markRunningToolActivitiesStopped()
            await handleGenerationCancellation(messageID: streamedAssistantMessageID, isFirst: isFirst, config: config)
        } catch {
            markRunningToolActivitiesStopped()
            if userStoppedGeneration, isCancellationLike(error) {
                await handleGenerationCancellation(messageID: streamedAssistantMessageID, isFirst: isFirst, config: config)
                return
            }
            // Keep whatever the model did say, whichever error ended the turn. A
            // failure can land after the reply is complete and already saved — a
            // later tool round, a persistence error — and deleting the text then
            // left the learner with an error and no answer, while the answer sat
            // in SQLite. An empty row is still removed; it would render as
            // nothing anyway, and the error message carries the outcome.
            if let index = chatMessages.firstIndex(where: { $0.id == streamedAssistantMessageID }) {
                let trimmed = chatMessages[index].content.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    chatMessages.remove(at: index)
                } else {
                    chatMessages[index].content = trimmed
                    await keepFailedTurnText(trimmed, rowID: streamedAssistantMessageID, isFirst: isFirst, config: config)
                }
            }
            errorMessage = error.localizedDescription
            lastGenerationError = error
            lastGenerationFailed = true
            await discardEmptyAutomaticStartIfNeeded(isFirst: isFirst)
            logger.error("review tutor generation failed: \(error.localizedDescription)")
        }
        // This reply may have aged a block of turns out of the verbatim window.
        // Fold them now, while the learner reads, so the next turn finds the
        // summary ready rather than waiting on it.
        scheduleHistoryFoldIfNeeded()
    }

    /// Automatic starts create their durable parent before asking the tutor for
    /// the opening turn. If that first request fails without producing any text,
    /// the row has no learner-authored content and nothing useful to resume. Drop
    /// it immediately instead of leaving an errored stub in the Chats rail.
    func discardEmptyAutomaticStartIfNeeded(isFirst: Bool) async {
        guard isFirst,
              let sessionID,
              !chatMessages.contains(where: { $0.role == .user }),
              !chatMessages.contains(where: {
                  $0.role == .assistant
                      && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            return
        }

        do {
            if try await storage.deleteReviewSessionIfNoRecordedConversation(sessionID) {
                self.sessionID = nil
                sessionActive = false
                sessionCostCutoff = Date()
                logger.info("Removed failed automatic chat start \(sessionID, privacy: .public) with no recorded conversation.")
            }
        } catch {
            // Preserve the original provider/configuration error. Cleanup is
            // opportunistic and must never replace the failure the learner saw.
            logger.error("Failed to remove empty automatic chat start \(sessionID, privacy: .public): \(error.localizedDescription)")
        }
    }

    struct ChatConfigResolution: Sendable {
        let config: AITaskConfig?
        let failureMessage: String
    }

    /// Resolve the chat model config off the main actor — the keychain read is
    /// synchronous IPC that must never run on the UI thread. Preserve the reason
    /// resolution failed without misreporting a valid Apple session as missing.
    nonisolated static func resolveChatConfig() async -> ChatConfigResolution {
        await Task.detached(priority: .userInitiated) {
            var config = KeychainService.resolveConfig(for: .chat)
            // In-app chat follows the .chat model selection, but in the
            // usage ledger it is its own feature: label the whole turn "chat"
            // rather than after the config key it borrows. Sites with a more
            // specific purpose (grading, titles) overwrite this again.
            config?.taskLabel = "chat"
            return ChatConfigResolution(
                config: config,
                failureMessage: chatConfigFailureMessage(
                    isSignedIn: ManagedAI.isSignedIn,
                    provider: KeychainService.resolvedProvider(for: .chat)
                )
            )
        }.value
    }

    func resolvedChatConfigOrShowError() async -> AITaskConfig? {
        // A resolvable model is not the same as a payable one. With no
        // ForeverLM balance, the request would travel to the proxy only to be
        // refused, so refuse it here and offer the purchase that is the actual fix.
        guard !AICreditEntitlement.isOutOfCredits else {
            errorMessage = AICreditEntitlement.purchaseRequiredMessage
            return nil
        }
        if let modelOverride {
            refreshSourceContextBudget(for: modelOverride)
            return modelOverride
        }
        let resolution = await Self.resolveChatConfig()
        guard let config = resolution.config else {
            errorMessage = resolution.failureMessage
            return nil
        }
        refreshSourceContextBudget(for: config)
        return config
    }

    /// Size the resident source budget for the model that will read it.
    ///
    /// Called wherever a chat config is resolved, and before any source text is
    /// loaded, so a drop into an idle composer is budgeted for the selected
    /// model rather than for the standing figure.
    private func refreshSourceContextBudget(for config: AITaskConfig) {
        sourceContextCharacterLimit = AIService.sourceContextCharacterBudget(
            provider: config.provider,
            model: config.model,
            requestedMaxTokens: chatResponseMaxOutputTokens
        ) ?? Self.fallbackSourceContextCharacterLimit
    }

    /// `refreshSourceContextBudget` for paths that load source text without a
    /// resolved config in hand. Resolution failing leaves the budget as it was;
    /// the send that follows will surface the failure itself.
    func refreshSourceContextBudgetFromSelectedModel() async {
        guard let config = await Self.resolveChatConfig().config else { return }
        refreshSourceContextBudget(for: config)
    }

    /// Deep Research runs on the chat's own model (product owner, 2026-09-27: it is
    /// not a background task). The mode changes only the prompt, the web
    /// search budget and the ledger label.
    func resolvedGenerationConfigOrShowError(
        for requestedMode: InitialPromptMode? = nil
    ) async -> AITaskConfig? {
        let deepResearch = requestedMode == .deepResearch || (requestedMode == nil && isDeepResearchMode)
        guard var config = await resolvedChatConfigOrShowError() else { return nil }
        guard deepResearch else { return config }

        guard config.provider != .gemini else {
            errorMessage = "Deep Research runs on the chat's model and needs one with web search. Choose a model other than Gemini."
            return nil
        }
        deepResearchSystemPrompt = await Task.detached(priority: .userInitiated) {
            AITask.deepResearch.effectivePrompt ?? Prompts.deepResearch
        }.value
        config.taskLabel = "deep_research_chat"
        refreshSourceContextBudget(for: config)
        return config
    }

    /// Resolve a non-chat text task away from the main actor. Keychain access is
    /// synchronous IPC, and completion/grading must remain as responsive as the
    /// rest of the review UI.
    func resolvedTaskConfigOrShowError(
        _ task: AITask,
        unavailableMessage: String
    ) async -> AITaskConfig? {
        guard !AICreditEntitlement.isOutOfCredits else {
            errorMessage = AICreditEntitlement.purchaseRequiredMessage
            return nil
        }
        let resolution = await Task.detached(priority: .userInitiated) {
            let config = KeychainService.resolveConfig(for: task)
            let failureMessage: String
            if !ManagedAI.isSignedIn {
                failureMessage = Self.signInRequiredMessage
            } else {
                failureMessage = KeychainService.backgroundAIUnavailableMessage(for: task)
                    ?? unavailableMessage
            }
            return ChatConfigResolution(config: config, failureMessage: failureMessage)
        }.value
        guard let config = resolution.config else {
            errorMessage = resolution.failureMessage
            return nil
        }
        return config
    }

    private nonisolated static func chatConfigFailureMessage(
        isSignedIn: Bool,
        provider _: AIProvider
    ) -> String {
        guard isSignedIn else {
            return signInRequiredMessage
        }
        return "The selected chat model isn't available. Choose another model, or check your OpenRouter key in AI Usage (the sidebar's OpenRouter button)."
    }

    nonisolated static func chatConfigFailureMessageForTesting(
        isSignedIn: Bool,
        provider: AIProvider
    ) -> String {
        chatConfigFailureMessage(isSignedIn: isSignedIn, provider: provider)
    }

    /// Outcome of re-applying a resumed session's saved model.
    enum SessionModelRestore {
        case restored
        case nothingSaved
        /// The saved model is unavailable to typed chat. Carries its display
        /// name for diagnostics only; this expected transition is not an error.
        case unavailable(saved: String)
    }

    /// Re-applies a resumed session's saved model, with the effort and speed
    /// its last reply was asked for, as the current-chat override, so an old
    /// chat keeps using the route it was held in instead of whatever the
    /// picker happens to be on — after a relaunch as much as within one run
    /// (product owner, 2026-09-28). An effort or speed the restored model can't
    /// honor is dropped, mirroring a manual pick; nil is the model's default.
    ///
    /// When the saved model is retired, this clears any stale override rather
    /// than leaving it in place. The routing path already refused to restore a
    /// retired provider, but the composer pill kept rendering the saved model
    /// from the session row — so the UI named a model that would never answer,
    /// which is worse than naming the wrong one. The caller logs the switch.
    nonisolated static func restoreSessionModelOverride(
        provider providerRaw: String?,
        modelID: String?,
        effort effortRaw: String? = nil,
        speed speedRaw: String? = nil
    ) async -> SessionModelRestore {
        await Task.detached(priority: .userInitiated) {
            guard
                let providerRaw,
                let modelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines),
                !modelID.isEmpty
            else { return SessionModelRestore.nothingSaved }

            let savedProvider = AIProvider(rawValue: providerRaw)
            guard
                let provider = savedProvider,
                AIProvider.activeChatProviders.contains(provider),
                KeychainService.hasUsableTextProviderCredentials(for: provider),
                AIModelCatalog.isEnabledChatSelection(provider: provider, modelID: modelID)
            else {
                // Drop a retired, disabled, or otherwise dead selection so the
                // chat, the picker, and the next send all agree on the current
                // Settings default.
                KeychainService.resetChatSessionSelection()
                // A provider whose raw value no longer decodes still needs a
                // name; the model ID alone is enough to render one.
                let name = AIModelDisplayName.textModelName(
                    modelID, provider: savedProvider ?? .openRouter
                )
                return SessionModelRestore.unavailable(saved: name)
            }
            let tuning = Self.restorableTuning(
                provider: provider, model: modelID, effort: effortRaw, speed: speedRaw
            )
            KeychainService.setTaskRoute(
                provider: provider,
                model: modelID,
                effort: tuning.effort,
                speed: tuning.speed,
                for: .chat
            )
            return SessionModelRestore.restored
        }.value
    }

    /// The saved effort and speed a restored model can take. A raw value this
    /// build does not know, or one the model does not offer, is the model's
    /// default; so is a speed the route cannot carry. Speed tiers that no
    /// longer exist are dropped later by the picker once OpenRouter answers,
    /// as they are for a manual pick.
    nonisolated static func restorableTuning(
        provider: AIProvider,
        model: String,
        effort effortRaw: String?,
        speed speedRaw: String?
    ) -> (effort: AIEffort?, speed: AISpeed?) {
        let effort = effortRaw.flatMap(AIEffort.init(rawValue:)).flatMap { effort -> AIEffort? in
            guard AIRequestOptionSupport.supportedEfforts(provider: provider, model: model).contains(effort) else {
                return nil
            }
            return effort
        }
        let speed = speedRaw.flatMap(AISpeed.init(rawValue:)).flatMap { speed -> AISpeed? in
            guard speed != .standard,
                  AIRequestOptionSupport.routeCanCarrySpeed(provider: provider, model: model) else { return nil }
            return speed
        }
        return (effort, speed)
    }

    /// One full agent turn: stream a reply, run any tool calls it makes, feed the
    /// results back, and repeat until the model answers with prose. Runs inside
    /// the cancellable turn task owned by `generateQuestion`.
    ///
    /// Native provider tool calling is the primary path: tool calls arrive as
    /// structured protocol data with an explicit stop reason, and results go back
    /// as typed tool-result turns with a stable (cacheable) system prompt. The
    /// <flm_tool_call> text protocol remains the fallback for providers
    /// that reject native tool definitions.
    private func runGenerationTurn(
        isFirst: Bool,
        config: AITaskConfig,
        streamedAssistantMessageID: UUID
    ) async throws {
        if MemoryTutorTurnPolicy.requiresRecordedAttempt(
            isFirst: isFirst,
            hasMemoryPlan: memoryCompanionPlan != nil,
            previousTutorQuestion: lastAssistantQuestion
        ) {
            stagedMemoryAttempt = nil
        }
        // Cards a failed turn saved stay in To Check, and pages it wrote stay
        // in Pages; they are not the next reply's.
        stagedSavedCards = nil
        stagedWrittenPages = []
        await refreshNotebookImportFiling()
        // Every turn: the log changes as the learner works, and a failed read
        // leaves it out of this turn only.
        if WorkingNotesPreference.isEnabled {
            if isFirst { await storage.syncWorkingNotesMirror() }
            do {
                sessionWorkingLog = try await storage.workingLogPromptExcerpt()
            } catch {
                sessionWorkingLog = nil
                logger.error("The working log could not be read for this chat: \(error.localizedDescription)")
            }
        } else {
            sessionWorkingLog = nil
        }
        // The notes nearest what was just said and what the chat is about:
        // chosen by on-device embedding, never all of them. Recall cannot
        // fail a turn; with nothing to rank by it falls back to recency.
        let recallQuery = [chatMessages.last(where: { $0.role == .user })?.content, topic]
            .compactMap { $0 }
            .joined(separator: "\n")
        sessionRecalledNotes = !WorkingNotesPreference.isEnabled ? [] : await storage.workingNotes().recall(
            query: String(recallQuery.prefix(800)),
            topK: Self.recalledWorkingNoteCount
        )
        if sessionSkills == nil {
            // Off-main through the storage actor. A failed read leaves the
            // catalog out of this turn and is tried again on the next; the
            // chat itself does not depend on it.
            do {
                sessionSkills = try await storage.loadSkills()
            } catch {
                logger.error("Skills could not be read for this chat: \(error.localizedDescription)")
            }
        }
        if memoryCompanionPlan != nil, nativeToolsDisabledForSession {
            throw AIError.apiError(
                "This chat model previously rejected the private memory-recording tool, so the review cannot continue safely. Choose another Chat model and retry."
            )
        }
        if memoryCompanionPlan != nil,
           !AIService.supportsNativeTools(provider: config.provider, model: config.model) {
            throw AIError.apiError(
                "The selected chat model cannot record memory attempts safely because it does not support native tools. Choose a tool-capable Chat model and retry."
            )
        }
        // The text tool protocol has no grade_quiz_answer, so a quiz there
        // could only be graded by the tutor itself, which it never may be.
        if courseQuiz != nil,
           nativeToolsDisabledForSession || !AIService.supportsNativeTools(provider: config.provider, model: config.model) {
            throw Self.courseQuizNeedsNativeToolsError
        }
        if !nativeToolsDisabledForSession,
           AIService.supportsNativeTools(provider: config.provider, model: config.model) {
            do {
                try await runNativeGenerationTurn(
                    isFirst: isFirst,
                    config: config,
                    streamedAssistantMessageID: streamedAssistantMessageID
                )
                return
            } catch {
                guard AINativeToolSupport.isNativeToolRejection(error) else { throw error }
                if memoryCompanionPlan != nil {
                    throw AIError.apiError(
                        "The selected chat model rejected the private memory-recording tool, so this attempt was not graded or scheduled. Choose another Chat model and retry."
                    )
                }
                if courseQuiz != nil {
                    throw Self.courseQuizNeedsNativeToolsError
                }
                nativeToolsDisabledForSession = true
                logger.warning("Provider rejected native tool definitions; falling back to the text tool protocol for this session: \(error.localizedDescription)")
                chatMessages.removeAll { $0.id == streamedAssistantMessageID }
                appendSystemActivity(
                    .fallback,
                    slug: "text_protocol_fallback",
                    title: "Switched to the text tool protocol",
                    detail: "this provider rejected native tool definitions",
                    resultPreview: error.localizedDescription
                )
            }
        }
        try await runTextProtocolGenerationTurn(
            isFirst: isFirst,
            config: config,
            streamedAssistantMessageID: streamedAssistantMessageID
        )
    }

    /// Text-protocol tool loop: tool calls parsed from <flm_tool_call> text blocks.
    private func runTextProtocolGenerationTurn(
        isFirst: Bool,
        config: AITaskConfig,
        streamedAssistantMessageID: UUID
    ) async throws {
        var promissoryNudges = 0
        var malformedToolCallNudges = 0
        var invalidSourceLinkNudges = 0
        var invalidPictureAddressNudges = 0
        var refusals = RepeatedToolRefusals()
        var continuationNudge: String? = nil
        var streamedRounds = 0
        // Without native tools there is no request_web_search escalation, and
        // the Exa fallback would bill one search per Chat request, so only
        // Deep Research rides the web on this path.
        let webSearch: WebSearchAccess = isDeepResearchMode && config.provider != .gemini
            ? .native
            : .unavailable

        scheduleHistoryFoldIfNeeded()
        while true {
            // Stop must interrupt the loop between rounds too — a cancelled turn
            // never starts another stream or tool call.
            try Task.checkCancellation()
            if userStoppedGeneration { throw CancellationError() }

            let systemPrompt = systemPromptForGeneration(
                allowSourceRetrieval: true,
                continuationNudge: continuationNudge,
                webSearch: webSearch
            )
            continuationNudge = nil
            let payload = chatPayload(isFirst: isFirst, systemPrompt: systemPrompt)
            publishContextBreakdown(
                system: payload.system,
                conversationCharacters: payload.messages.reduce(0) { $0 + $1.content.count + 16 },
                toolCharacters: 0,
                config: config
            )
            // On this path the model already rejected native tool definitions,
            // so web search runs OpenRouter's Exa engine — one
            // unconditional search per request. Ride it only on the round that
            // carries the learner's fresh message; tool-continuation rounds
            // would re-bill the same search.
            let attachWebSearch = webSearch == .native && streamedRounds == 0
            streamedRounds += 1
            let assistantMessage = try await streamAssistantResponse(
                messageID: streamedAssistantMessageID,
                system: payload.system,
                messages: Self.textOnlyProviderMessages(payload.messages),
                config: config,
                allowSourceRetrieval: true,
                webSearch: attachWebSearch
            )
            var response = assistantMessage.content

            if let retrievalCall = parseRetrievalToolCall(response) {
                chatMessages.removeAll { $0.id == assistantMessage.id }
                // No per-turn retrieval ceiling, matching app tool calls: the
                // retrieved context is size-capped on append and the Stop button
                // is the circuit breaker for a runaway loop.
                let activityID = appendToolActivity(for: AppToolCall(
                    name: "retrieve_sources",
                    arguments: retrievalCall.query.isEmpty ? [:] : ["query": retrievalCall.query]
                ))
                let retrieved = await retrieveSourceContext(for: retrievalCall)
                adoptRetrievedSourceContext(retrieved)
                completeToolActivity(activityID, result: AppToolResult(
                    text: retrieved.text,
                    isError: retrieved.loadedIDs.isEmpty
                ))
                compactAppToolResultsIfNeeded(config: config, isFirst: isFirst)
                continue
            }

            if let appToolCall = parseAppToolCall(response) {
                chatMessages.removeAll { $0.id == assistantMessage.id }
                // No per-turn ceiling: long multi-step commands legitimately chain
                // many calls. Every call is surfaced live in the transcript and the
                // Stop button cancels generation, so the user is the circuit breaker
                // for a runaway loop.
                //
                // Surface the call in the transcript before it runs, so the learner sees
                // what the assistant is doing rather than an unexplained pause.
                let activityID = appendToolActivity(for: appToolCall)
                // A refusal repeated word for word is the one thing that
                // stops the chain (`RepeatedToolRefusals`).
                let toolResult: AppToolResult
                let modelText: String
                if let withheld = refusals.withheldResult(for: appToolCall.name) {
                    toolResult = withheld
                    modelText = withheld.text
                } else {
                    toolResult = try await executeAppToolCall(appToolCall)
                    modelText = refusals.record(toolName: appToolCall.name, result: toolResult)
                }
                completeToolActivity(activityID, result: toolResult)
                if let refusal = refusals.exhaustedRefusal {
                    throw RepeatedToolRefusals.Stopped(refusal: refusal)
                }
                appendAppToolResult(toolName: appToolCall.name, result: modelText)
                compactAppToolResultsIfNeeded(config: config, isFirst: isFirst)
                continue
            }

            if let toolCall = parseSynthesisToolCall(response) {
                pendingSynthesisToolCall = toolCall
                response = "Updating the synthesis..."
                if let index = chatMessages.firstIndex(where: { $0.id == assistantMessage.id }) {
                    chatMessages[index].content = response
                }
                if let sessionID {
                    try await storage.updateReviewSessionModel(
                        sessionID: sessionID,
                        modelProvider: config.provider.rawValue,
                        modelID: config.model,
                        modelEffort: config.effort?.rawValue,
                        modelSpeed: config.speed?.rawValue
                    )
                }
                lastAssistantQuestion = nil
                return
            }

            // The reply carries an <flm_tool_call> block that none of the parsers
            // accepted — broken JSON, usually. Such a reply is never an answer:
            // the block is stripped for display, so accepting it hands the learner
            // the model's lead-in ("I'll pull that up") and nothing else, with the
            // work silently skipped. Ask for a valid call, then for a plain answer,
            // and fail loudly rather than delivering the promise on its own.
            if response.contains("<flm_tool_call") {
                chatMessages.removeAll { $0.id == assistantMessage.id }
                guard malformedToolCallNudges < malformedToolCallNudgeMaxAttempts else {
                    throw unreadableToolCallError()
                }
                malformedToolCallNudges += 1
                continuationNudge = malformedToolCallNudges < malformedToolCallNudgeMaxAttempts
                    ? """
                    Your previous reply contained an <flm_tool_call> block that could not be parsed, so nothing ran. Re-emit the tool call as exactly one line of valid JSON in the documented format — double-quoted keys and strings, matching closing tag, no other text on the line. If no tool call is actually needed, answer directly without any <flm_tool_call> block.
                    """
                    : """
                    Your reply again contained an <flm_tool_call> block that could not be parsed, so nothing ran and the learner has been given no answer. Stop trying to call tools. Answer now in plain prose from the conversation and the sources already in context, and say in one sentence which lookup you could not perform. Your reply must contain no <flm_tool_call> block of any kind.
                    """
                continue
            }

            // The suggested-questions tail is never prose: it comes off before
            // the checks below read the reply's last words and its links.
            let followUps = ChatFollowUps.split(response)
            response = followUps.prose

            // The model ended its turn with plain prose whose last words only announce
            // more work ("searching your library now") without emitting the tool call
            // for it. Nothing ran, so the reply is a promise rather than an answer —
            // re-prompt a bounded number of times before accepting it. This holds
            // whether or not a tool ran earlier this turn: a promise made with no
            // tool call at all leaves the learner with strictly less.
            if promissoryNudges < promissoryContinuationMaxAttempts,
               replyPromisesUncalledToolWork(response) {
                chatMessages.removeAll { $0.id == assistantMessage.id }
                promissoryNudges += 1
                continuationNudge = promissoryNudges < promissoryContinuationMaxAttempts
                    ? """
                    Your previous reply announced an action but emitted no <flm_tool_call> block, so nothing ran and the learner's request is still unfinished. Do not narrate the next step — emit the actual <flm_tool_call> for it now (for a targeted source lookup, use search_sources_semantic). If you have already gathered everything the learner asked for, deliver the concrete results instead of promising them.
                    """
                    : """
                    Your reply again promised work instead of doing it, and the learner still has no answer. This is your last turn: answer now from the conversation and the sources already in context, and name in one sentence anything you could not look up. Do not announce further steps.
                    """
                continue
            }

            let invalidSourceLinks = try await unresolvedSourceLinkTokens(in: response)
            if !invalidSourceLinks.isEmpty {
                chatMessages.removeAll { $0.id == assistantMessage.id }
                guard invalidSourceLinkNudges < invalidSourceLinkNudgeMaxAttempts else {
                    throw invalidSourceLinkError(count: invalidSourceLinks.count)
                }
                invalidSourceLinkNudges += 1
                continuationNudge = invalidSourceLinkCorrectionNudge
                continue
            }

            let invalidPictures = try await unresolvedPictureAddresses(in: response)
            if !invalidPictures.isEmpty {
                chatMessages.removeAll { $0.id == assistantMessage.id }
                logger.warning("Reply showed \(invalidPictures.count) picture address(es) that name nothing; asking for a rewrite (attempt \(invalidPictureAddressNudges + 1))")
                guard invalidPictureAddressNudges < invalidPictureAddressNudgeMaxAttempts else {
                    throw invalidPictureAddressError(count: invalidPictures.count)
                }
                invalidPictureAddressNudges += 1
                continuationNudge = invalidPictureAddressCorrectionNudge
                continue
            }

            response = placingCourseQuizPictures(in: response)
            if let index = chatMessages.firstIndex(where: { $0.id == assistantMessage.id }) {
                chatMessages[index].content = response
            }
            try await settleAnswer(
                response,
                questions: followUps.questions,
                rowID: assistantMessage.id,
                isFirst: isFirst,
                config: config
            )
            return
        }
    }

    /// Native tool loop: tool calls arrive as structured protocol data, results
    /// return as typed tool-result turns, and the system prompt stays stable
    /// across the whole turn so providers can cache it.
    private func runNativeGenerationTurn(
        isFirst: Bool,
        config: AITaskConfig,
        streamedAssistantMessageID: UUID
    ) async throws {
        await hydrateAttachedImages()
        await hydrateVideoMomentFrames()
        // A resumed/failed opening turn can contain learner messages without a
        // persisted tutor question. That is steering context, not a retrieval
        // attempt, so it must not be graded or rejected as an unrecorded answer.
        let memoryAttemptExpected = MemoryTutorTurnPolicy.requiresRecordedAttempt(
            isFirst: isFirst,
            hasMemoryPlan: memoryCompanionPlan != nil,
            previousTutorQuestion: lastAssistantQuestion
        )
        var promissoryNudges = 0
        var invalidSourceLinkNudges = 0
        var invalidPictureAddressNudges = 0
        var firstReviewSourceNudges = 0
        var courseQuizOutOfTurnNudges = 0
        var refusals = RepeatedToolRefusals()
        // Citations from every kept round of this turn, deduplicated by URL:
        // a model can search on a tool round and answer on a later one, and
        // the footer belongs to the turn's final visible reply.
        var turnWebCitations: [AIWebCitation] = []

        scheduleHistoryFoldIfNeeded()

        // Deep Research takes the provider's web tool with its research budget;
        // Chat takes whatever its route can bill exactly (see WebSearchAccess).
        let deepResearchTurn = isDeepResearchMode
        let webSearch: WebSearchAccess = deepResearchTurn
            ? (config.provider != .gemini ? .native : .unavailable)
            : Self.webSearchAccess(for: config)
        let systemPrompt = systemPromptForGeneration(
            allowSourceRetrieval: true,
            continuationNudge: nil,
            nativeToolsActive: true,
            webSearch: webSearch
        )
        let payload = chatPayload(isFirst: isFirst, systemPrompt: systemPrompt)
        let imagesReadable = KeychainService.modelSupportsVision(provider: config.provider, model: config.model) != false
        var turns: [AIChatTurn] = payload.messages.map { message in
            message.role == "assistant"
                ? AIChatTurn.assistant(text: message.content, toolCalls: [])
                : Self.userTurn(content: message.content, imagesReadable: imagesReadable)
        }
        // The learner's message this turn: the per-turn tail stays in front of
        // it for every round, whatever nudges the rounds append after it.
        let learnerTurnIndex = turns.lastIndex { turn in
            if case .user = turn { return true }
            return false
        }
        var tools = nativeToolSpecs(webSearch: webSearch)
        var toolCharacters = Self.projectedToolCharacterCount(of: tools)
        // Rounds of this turn that carried the provider's web tool; Deep
        // Research stops attaching it once the budget is spent.
        var webSearchRounds = 0
        // Set by a successful request_web_search call, consumed by the round after it.
        var webSearchRequested = false

        while true {
            // Stop must interrupt the loop between rounds too — a cancelled turn
            // never starts another stream or tool call.
            try Task.checkCancellation()
            if userStoppedGeneration { throw CancellationError() }

            trimNativeToolResultTurnsIfNeeded(
                &turns,
                systemPrompt: payload.system.combined,
                toolCharacters: toolCharacters,
                config: config
            )

            publishContextBreakdown(
                system: payload.system,
                conversationCharacters: AIService.projectedCharacterCount(of: turns),
                toolCharacters: toolCharacters,
                config: config
            )

            let attachWebSearch: Bool
            switch webSearch {
            case .unavailable:
                attachWebSearch = false
            case .native:
                // The provider's tool rides every round: idle it costs nothing,
                // and a model that read a doc or searched the library first still
                // needs the web afterwards. Deep Research used to carry it on the
                // first round only, so one library lookup silently turned the
                // rest of the turn into a library-only answer. Its per-turn bound
                // is the round budget below on top of the per-request search
                // ceiling (`AIWebSearchDepth.deepResearch`).
                attachWebSearch = deepResearchTurn
                    ? webSearchRounds < Self.deepResearchWebSearchRoundBudget
                    : true
            case .onRequest:
                attachWebSearch = webSearchRequested
            }
            if attachWebSearch { webSearchRounds += 1 }
            webSearchRequested = false
            // While a quiz question waits and no grade or skip has come back
            // this turn, anything the tutor writes may be a verdict of its
            // own: it reaches the screen only once the round is over and
            // `questionShownOutOfTurn` has passed it.
            let holdsCourseQuizText = courseQuiz?.currentIndex != nil && pendingCourseQuizPictureTurn == nil
            let result = try await streamAssistantResponseNative(
                messageID: streamedAssistantMessageID,
                system: payload.system,
                turns: turns,
                tools: tools,
                config: config,
                webSearch: attachWebSearch,
                webSearchDepth: deepResearchTurn ? .deepResearch : .standard,
                learnerTurnIndex: learnerTurnIndex,
                showsTextWhileStreaming: !holdsCourseQuizText
            )

            if result.toolCalls.isEmpty {
                // The suggested-questions tail is never prose: it comes off
                // before the checks below read the reply's last words and links.
                let followUps = ChatFollowUps.split(result.text)
                let response = followUps.prose
                if let requiredSourceID = currentFirstReviewSourceIDNeedingLoad() {
                    chatMessages.removeAll { $0.id == streamedAssistantMessageID }
                    guard firstReviewSourceNudges < firstReviewSourceNudgeMaxAttempts else {
                        throw AIError.apiError(
                            "The tutor did not load the first-review source before asking. No ungrounded question was saved; retry the review."
                        )
                    }
                    firstReviewSourceNudges += 1
                    turns.append(.assistant(text: response, toolCalls: []))
                    turns.append(.user("ForeverLM rejected that reply because the current first-review source is still catalog-only. Before showing any question or feedback, call retrieve_sources with source_ids [\"\(requiredSourceID)\"] and a focused query for the concept you will test. Do not infer the source from its title."))
                    continue
                }
                // Even with native tools a model can still end its turn narrating
                // work instead of calling the tool for it; re-prompt a bounded
                // number of times before accepting the reply. Whether a tool ran
                // earlier in the turn does not matter — a promise is not an answer
                // either way.
                if promissoryNudges < promissoryContinuationMaxAttempts,
                   replyPromisesUncalledToolWork(response) {
                    chatMessages.removeAll { $0.id == streamedAssistantMessageID }
                    promissoryNudges += 1
                    turns.append(.assistant(text: response, toolCalls: []))
                    turns.append(.user(
                        promissoryNudges < promissoryContinuationMaxAttempts
                            ? "Your previous reply announced an action but called no tool, so nothing ran and the request is still unfinished. Do not narrate the next step — call the tool for it now (for a targeted source lookup, use search_sources_semantic). If you have already gathered everything needed, deliver the concrete results instead of promising them."
                            : "Your reply again promised work instead of doing it, and the learner still has no answer. This is your last turn: answer now from the conversation and the sources already in context, and name in one sentence anything you could not look up. Do not announce further steps."
                    ))
                    continue
                }
                let invalidSourceLinks = try await unresolvedSourceLinkTokens(in: response)
                if !invalidSourceLinks.isEmpty {
                    chatMessages.removeAll { $0.id == streamedAssistantMessageID }
                    guard invalidSourceLinkNudges < invalidSourceLinkNudgeMaxAttempts else {
                        throw invalidSourceLinkError(count: invalidSourceLinks.count)
                    }
                    invalidSourceLinkNudges += 1
                    turns.append(.assistant(text: response, toolCalls: []))
                    turns.append(.user(invalidSourceLinkCorrectionNudge))
                    continue
                }
                let invalidPictures = try await unresolvedPictureAddresses(in: response)
                if !invalidPictures.isEmpty {
                    chatMessages.removeAll { $0.id == streamedAssistantMessageID }
                    logger.warning("Reply showed \(invalidPictures.count) picture address(es) that name nothing; asking for a rewrite (attempt \(invalidPictureAddressNudges + 1))")
                    guard invalidPictureAddressNudges < invalidPictureAddressNudgeMaxAttempts else {
                        throw invalidPictureAddressError(count: invalidPictures.count)
                    }
                    invalidPictureAddressNudges += 1
                    turns.append(.assistant(text: response, toolCalls: []))
                    turns.append(.user(invalidPictureAddressCorrectionNudge))
                    continue
                }
                // A quiz reply that shows a question the sitting has not
                // reached went on without a grade: withheld, and the tutor is
                // sent back to the grader.
                if let quiz = courseQuiz, let shown = quiz.questionShownOutOfTurn(in: response) {
                    chatMessages.removeAll { $0.id == streamedAssistantMessageID }
                    logger.warning("Quiz reply showed question \(shown) while the sitting is on question \((quiz.currentIndex ?? 0) + 1); withheld (attempt \(courseQuizOutOfTurnNudges + 1))")
                    guard courseQuizOutOfTurnNudges < courseQuizOutOfTurnNudgeMaxAttempts else {
                        throw AIError.apiError(quiz.outOfTurnFailure(shown: shown))
                    }
                    courseQuizOutOfTurnNudges += 1
                    turns.append(.assistant(text: response, toolCalls: []))
                    turns.append(.user(quiz.outOfTurnCorrection(shown: shown)))
                    continue
                }
                recordWebSearchResults(result.webCitations, into: &turnWebCitations, before: streamedAssistantMessageID)
                var visible = Self.appendingWebSourcesFooter(
                    to: await linkingLibrarySources(
                        in: await rewritingSlideFramePaths(
                            in: repairingSourceTitleMarkers(in: Self.visibleAssistantText(from: response) ?? response)
                        )
                    ),
                    citations: turnWebCitations
                )
                visible = placingCourseQuizPictures(in: visible)
                if let index = chatMessages.firstIndex(where: { $0.id == streamedAssistantMessageID }) {
                    if isMemoryReviewSession, visible.contains("<\(MemoryReviewSourceTurn.tagName)") {
                        placeSourceTurnHeadings(in: visible, replacingMessageAt: index, config: config)
                    } else if visible != chatMessages[index].content {
                        chatMessages[index].content = visible
                    }
                }
                if memoryAttemptExpected, stagedMemoryAttempt == nil {
                    throw AIError.apiError(
                        "The tutor answered without recording this memory attempt. Nothing was graded or rescheduled; retry the turn."
                    )
                }
                try await settleAnswer(
                    visible,
                    questions: followUps.questions,
                    rowID: streamedAssistantMessageID,
                    isFirst: isFirst,
                    config: config
                )
                return
            }
            recordWebSearchResults(result.webCitations, into: &turnWebCitations, before: streamedAssistantMessageID)

            // The model called tools. Keep any lead-in prose visible — frozen under
            // its own id so the next round can stream into the shared bubble.
            // Words written before a quiz answer's grade came back cannot be
            // feedback on it, so that lead-in is left out.
            let leadIn = holdsCourseQuizText && result.toolCalls.contains(where: { $0.name == CourseQuizChatState.gradeToolName })
                ? ""
                : Self.visibleAssistantText(from: result.text)
                    .map { Self.strippingLeakedNativeToolPayloads($0, toolCalls: result.toolCalls) }?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let index = chatMessages.firstIndex(where: { $0.id == streamedAssistantMessageID }) {
                if leadIn.isEmpty {
                    chatMessages.remove(at: index)
                } else {
                    let createdAt = chatMessages[index].createdAt
                    chatMessages[index] = Message(
                        role: .assistant,
                        content: leadIn,
                        createdAt: createdAt,
                        modelProvider: config.provider.rawValue,
                        modelID: config.model
                    )
                }
            }
            turns.append(.assistant(text: result.text, toolCalls: result.toolCalls))

            var results: [AIToolResultPayload] = []
            for call in result.toolCalls {
                try Task.checkCancellation()
                if userStoppedGeneration { throw CancellationError() }

                switch call.name {
                case "record_memory_attempt":
                    let recorded = await stageMemoryAttempt(
                        arguments: call.arguments,
                        isFirst: isFirst,
                        config: config
                    )
                    results.append(AIToolResultPayload(
                        callID: call.id,
                        toolName: call.name,
                        text: recorded.text,
                        isError: recorded.isError
                    ))
                case "grade_memory_contour":
                    let graded = stageContourGrade(arguments: call.arguments, isFirst: isFirst)
                    results.append(AIToolResultPayload(
                        callID: call.id,
                        toolName: call.name,
                        text: graded.text,
                        isError: graded.isError
                    ))
                case "grade_topic_recall":
                    let graded = stageTopicGrade(arguments: call.arguments, isFirst: isFirst)
                    results.append(AIToolResultPayload(
                        callID: call.id,
                        toolName: call.name,
                        text: graded.text,
                        isError: graded.isError
                    ))
                case CourseQuizChatState.gradeToolName:
                    let activityID = appendToolActivity(
                        for: AppToolCall(name: call.name, arguments: call.arguments)
                    )
                    let graded = await gradeCourseQuizAnswer(
                        arguments: call.arguments,
                        isFirst: isFirst,
                        chatConfig: config
                    )
                    completeToolActivity(activityID, result: graded)
                    results.append(AIToolResultPayload(
                        callID: call.id,
                        toolName: call.name,
                        text: graded.text,
                        isError: graded.isError
                    ))
                case CourseQuizChatState.skipToolName:
                    let activityID = appendToolActivity(
                        for: AppToolCall(name: call.name, arguments: call.arguments)
                    )
                    let skipped = await skipCourseQuizQuestion(arguments: call.arguments, isFirst: isFirst)
                    completeToolActivity(activityID, result: skipped)
                    results.append(AIToolResultPayload(
                        callID: call.id,
                        toolName: call.name,
                        text: skipped.text,
                        isError: skipped.isError
                    ))
                case CourseQuizChatState.readingToolName:
                    let activityID = appendToolActivity(
                        for: AppToolCall(name: call.name, arguments: call.arguments)
                    )
                    let read = await readPlannedReading(arguments: call.arguments)
                    completeToolActivity(activityID, result: read)
                    results.append(AIToolResultPayload(
                        callID: call.id,
                        toolName: call.name,
                        text: read.text,
                        isError: read.isError
                    ))
                case "set_review_depth":
                    let activityID = appendToolActivity(
                        for: AppToolCall(name: call.name, arguments: call.arguments)
                    )
                    let set = await setReviewDepth(arguments: call.arguments)
                    completeToolActivity(activityID, result: set)
                    results.append(AIToolResultPayload(
                        callID: call.id,
                        toolName: call.name,
                        text: set.text,
                        isError: set.isError
                    ))
                case "add_to_synthesis", "replace_synthesis":
                    if let synthesisCall = nativeSynthesisCall(from: call) {
                        pendingSynthesisToolCall = synthesisCall
                        chatMessages.append(Message(
                            role: .assistant,
                            content: "Updating the synthesis...",
                            modelProvider: config.provider.rawValue,
                            modelID: config.model
                        ))
                        if let sessionID {
                            try await storage.updateReviewSessionModel(
                                sessionID: sessionID,
                                modelProvider: config.provider.rawValue,
                                modelID: config.model,
                                modelEffort: config.effort?.rawValue,
                                modelSpeed: config.speed?.rawValue
                            )
                        }
                        lastAssistantQuestion = nil
                        return
                    }
                    results.append(AIToolResultPayload(
                        callID: call.id,
                        toolName: call.name,
                        text: "Error: The \(call.name) call carried no usable markdown argument. Re-emit the call with the complete markdown.",
                        isError: true
                    ))
                case "retrieve_sources":
                    let retrievalCall = retrievalToolCall(fromArguments: call.arguments)
                    // Surfaced like an app tool: retrieval can be slow (PDF
                    // extraction, OCR), and a silent pause here is exactly what
                    // the activity rows exist to prevent.
                    let activityID = appendToolActivity(
                        for: AppToolCall(name: call.name, arguments: call.arguments)
                    )
                    let retrieved = await retrieveSourceContext(for: retrievalCall)
                    // Fold into the session's source context as well as
                    // returning it: tool-result turns are rebuilt from
                    // `chatMessages` each turn and do not survive, so this is
                    // the only thing keeping a loaded source loaded.
                    adoptRetrievedSourceContext(retrieved)
                    completeToolActivity(activityID, result: AppToolResult(
                        text: retrieved.text,
                        isError: retrieved.loadedIDs.isEmpty
                    ))
                    results.append(AIToolResultPayload(
                        callID: call.id,
                        toolName: call.name,
                        text: retrieved.text,
                        isError: false
                    ))
                case "inspect_paper_figure":
                    let activityID = appendToolActivity(
                        for: AppToolCall(name: call.name, arguments: call.arguments)
                    )
                    let inspected = await inspectPaperFigure(arguments: call.arguments)
                    completeToolActivity(activityID, result: inspected)
                    results.append(AIToolResultPayload(
                        callID: call.id,
                        toolName: call.name,
                        text: inspected.text,
                        isError: inspected.isError
                    ))
                case "show_source_image":
                    let activityID = appendToolActivity(
                        for: AppToolCall(name: call.name, arguments: call.arguments)
                    )
                    let shown = await showSourceImage(arguments: call.arguments)
                    completeToolActivity(activityID, result: shown)
                    if shown.images.count == 1, let picture = shown.images.first {
                        updateToolActivityPreview(activityID, image: picture.data)
                    }
                    results.append(AIToolResultPayload(
                        callID: call.id,
                        toolName: call.name,
                        text: shown.text,
                        isError: shown.isError,
                        images: shown.images
                    ))
                case "focus_source_anchor":
                    let activityID = appendToolActivity(
                        for: AppToolCall(name: call.name, arguments: call.arguments)
                    )
                    let focused = await focusSourceAnchor(arguments: call.arguments)
                    completeToolActivity(activityID, result: focused)
                    results.append(AIToolResultPayload(
                        callID: call.id,
                        toolName: call.name,
                        text: focused.text,
                        isError: focused.isError
                    ))
                case "extract_video_slides":
                    let activityID = appendToolActivity(
                        for: AppToolCall(name: call.name, arguments: call.arguments)
                    )
                    let captured = await extractVideoSlides(arguments: call.arguments)
                    completeToolActivity(activityID, result: captured)
                    results.append(AIToolResultPayload(
                        callID: call.id,
                        toolName: call.name,
                        text: captured.text,
                        isError: captured.isError
                    ))
                case "generate_image":
                    let activityID = appendToolActivity(
                        for: AppToolCall(name: call.name, arguments: call.arguments)
                    )
                    let drawn = await generateChatImage(arguments: call.arguments)
                    completeToolActivity(activityID, result: drawn)
                    results.append(AIToolResultPayload(
                        callID: call.id,
                        toolName: call.name,
                        text: drawn.text,
                        isError: drawn.isError
                    ))
                case "list_open_panes":
                    let activityID = appendToolActivity(
                        for: AppToolCall(name: call.name, arguments: call.arguments)
                    )
                    let listed = openPanesForThisChat().map { AppToolResult(text: $0.text, isError: false) }
                        ?? AppToolResult(text: "Error: this chat is not shown in a ForeverLM window, so there are no panes to list.", isError: true)
                    completeToolActivity(activityID, result: listed)
                    results.append(AIToolResultPayload(
                        callID: call.id,
                        toolName: call.name,
                        text: listed.text,
                        isError: listed.isError
                    ))
                case "list_generated_images":
                    let activityID = appendToolActivity(
                        for: AppToolCall(name: call.name, arguments: call.arguments)
                    )
                    let listed = await listGeneratedImages(arguments: call.arguments)
                    completeToolActivity(activityID, result: listed)
                    results.append(AIToolResultPayload(
                        callID: call.id,
                        toolName: call.name,
                        text: listed.text,
                        isError: listed.isError
                    ))
                case "request_web_search":
                    let activityID = appendToolActivity(
                        for: AppToolCall(name: call.name, arguments: call.arguments)
                    )
                    let query = (call.arguments["query"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let outcome: AppToolResult
                    switch webSearch {
                    case .native:
                        outcome = AppToolResult(
                            text: "Error: request_web_search is not needed on this model route. The provider's web_search tool is already attached to this step; use it directly now.",
                            isError: true
                        )
                    case .unavailable:
                        outcome = AppToolResult(
                            text: "Error: Web search is unavailable on this model route. Do not claim to have searched the web; if live web information is essential, tell the learner to pick another model.",
                            isError: true
                        )
                    case .onRequest where query.isEmpty:
                        outcome = AppToolResult(
                            text: "Error: request_web_search requires a focused, non-empty query.",
                            isError: true
                        )
                    case .onRequest:
                        outcome = AppToolResult(
                            text: "Live web search is enabled for the next assistant step. Search the web for: \(query). Use the provider's web_search tool now; do not call request_web_search again unless a later, distinct refinement is genuinely necessary.",
                            isError: false
                        )
                        webSearchRequested = true
                    }
                    completeToolActivity(activityID, result: outcome)
                    results.append(AIToolResultPayload(
                        callID: call.id,
                        toolName: call.name,
                        text: outcome.text,
                        isError: outcome.isError
                    ))
                case "fetch_web_page":
                    let activityID = appendToolActivity(
                        for: AppToolCall(name: call.name, arguments: call.arguments)
                    )
                    let fetched = await fetchWebPage(arguments: call.arguments)
                    completeToolActivity(activityID, result: fetched.result)
                    // A page the model read is a page the learner may want to
                    // keep, whether or not the search engine also cited it.
                    if let citation = fetched.citation {
                        turnWebCitations = Self.mergingWebCitations(turnWebCitations, adding: [citation])
                    }
                    results.append(AIToolResultPayload(
                        callID: call.id,
                        toolName: call.name,
                        text: fetched.result.text,
                        isError: fetched.result.isError
                    ))
                case _ where ChatBrowsing.isBrowserTool(call.name):
                    let activityID = appendToolActivity(
                        for: AppToolCall(name: call.name, arguments: call.arguments)
                    )
                    let outcome = await runBrowserTool(
                        name: call.name,
                        arguments: call.arguments,
                        activityID: activityID,
                        config: config
                    )
                    completeToolActivity(activityID, result: AppToolResult(text: outcome.text, isError: outcome.isError))
                    if let preview = outcome.preview {
                        updateToolActivityPreview(activityID, image: preview)
                    }
                    results.append(AIToolResultPayload(
                        callID: call.id,
                        toolName: call.name,
                        text: outcome.text,
                        isError: outcome.isError,
                        images: outcome.screenshot.map { [$0] } ?? []
                    ))
                case ChatCode.toolName:
                    let activityID = appendToolActivity(
                        for: AppToolCall(name: call.name, arguments: call.arguments)
                    )
                    let ran = await runCodeTool(arguments: call.arguments)
                    completeToolActivity(activityID, result: ran)
                    showCodeOnActivity(activityID, arguments: call.arguments, result: ran)
                    results.append(AIToolResultPayload(
                        callID: call.id,
                        toolName: call.name,
                        text: ran.text,
                        isError: ran.isError
                    ))
                case TeachBack.toolName:
                    let activityID = appendToolActivity(
                        for: AppToolCall(name: call.name, arguments: call.arguments)
                    )
                    let started = startFeynmanTechnique()
                    completeToolActivity(activityID, result: started)
                    results.append(AIToolResultPayload(
                        callID: call.id,
                        toolName: call.name,
                        text: started.text,
                        isError: started.isError
                    ))
                case Self.loadAppToolsName:
                    // Quiet: loading tools is plumbing, not something the
                    // learner asked for, so it gets no activity row.
                    let loaded = loadAppTools(arguments: call.arguments)
                    results.append(AIToolResultPayload(
                        callID: call.id,
                        toolName: call.name,
                        text: loaded.text,
                        isError: loaded.isError
                    ))
                default:
                    // App tool: surfaced live in the transcript, run under the
                    // watchdog, failure signaled by the tool layer's own flag.
                    let appCall = AppToolCall(name: call.name, arguments: call.arguments)
                    let activityID = appendToolActivity(for: appCall)
                    let toolResult: AppToolResult
                    let modelText: String
                    if let withheld = refusals.withheldResult(for: call.name) {
                        toolResult = withheld
                        modelText = withheld.text
                    } else {
                        toolResult = try await executeAppToolCall(appCall)
                        modelText = refusals.record(toolName: call.name, result: toolResult)
                    }
                    completeToolActivity(activityID, result: toolResult)
                    results.append(AIToolResultPayload(
                        callID: call.id,
                        toolName: call.name,
                        text: modelText,
                        isError: toolResult.isError
                    ))
                }
            }
            if let refusal = refusals.exhaustedRefusal {
                throw RepeatedToolRefusals.Stopped(refusal: refusal)
            }
            turns.append(.toolResults(results))
            if result.toolCalls.contains(where: { $0.name == Self.loadAppToolsName }) {
                tools = nativeToolSpecs(webSearch: webSearch)
                toolCharacters = Self.projectedToolCharacterCount(of: tools)
            }
        }
    }

    /// Stream one native-tools assistant step, porting the text path's recovery
    /// state machine: empty-output retries, output-limit continuations with a
    /// terminal compaction, context-overflow compaction, and transient retries
    /// with Retry-After-aware backoff.
    private func streamAssistantResponseNative(
        messageID: UUID,
        system: GenerationSystemPrompt,
        turns: [AIChatTurn],
        tools: [AIToolSpec],
        config: AITaskConfig,
        webSearch: Bool,
        webSearchDepth: AIWebSearchDepth,
        learnerTurnIndex: Int? = nil,
        showsTextWhileStreaming: Bool = true
    ) async throws -> AIToolStreamResult {
        chatMessages.append(Message(
            id: messageID,
            role: .assistant,
            content: "",
            modelProvider: config.provider.rawValue,
            modelID: config.model
        ))
        streamingMessageID = messageID
        defer {
            streamingMessageID = nil
            streamingReasoning = ""
            streamingThinkingRowID = nil
        }

        var emptyOutputRetries = 0
        var continuationAttempts = 0
        var transientRetries = 0
        var contextOverflowRetries = 0
        var currentSystem = system
        var currentTurns = turns
        var currentMaxTokens = chatResponseMaxOutputTokens
        // Text carried over from a cut-off attempt that later attempts continue.
        var prefixText = ""

        while true {
            let prefix = prefixText
            let publishGuard = StreamPublishGuard()
            // Each batcher numbers its own publishes, so the reasoning lane
            // needs a guard of its own.
            let reasoningGuard = StreamPublishGuard()
            // Every exit from this attempt — the finished answer, a retry that
            // starts a fresh batcher, a throw — is followed by an await, and the
            // batcher publishes from unstructured Tasks that only run when the
            // main actor yields. Sealing here means a hop dispatched mid-stream
            // can never land after the attempt has written its result.
            defer {
                publishGuard.seal()
                reasoningGuard.seal()
            }
            let attemptStartedAt = Date()
            let batcher = StreamTextBatcher(interval: streamUIUpdateInterval) { [weak self] sequence, text in
                guard showsTextWhileStreaming, let self, publishGuard.accept(sequence) else { return }
                guard let index = self.chatMessages.firstIndex(where: { $0.id == messageID }) else { return }
                let combined = prefix.isEmpty ? text : prefix + text
                self.chatMessages[index].content = self.repairingSourceTitleMarkers(in: Self.visibleAssistantText(
                    from: MemoryReviewSourceTurn.strippingTrailingPartialTag(
                        Self.strippingTrailingPartialToolCallTag(combined)
                    )
                ) ?? "")
                // The answer has begun, so the thinking before it is over: it
                // leaves the status line and folds into a row above the answer.
                if self.streamingThinkingRowID == nil, !self.chatMessages[index].content.isEmpty {
                    self.settleThinking(before: messageID, reasoning: self.streamingReasoning, startedAt: attemptStartedAt)
                }
            }
            streamingReasoning = ""
            streamingThinkingRowID = nil
            let reasoningBatcher = StreamTextBatcher(interval: streamUIUpdateInterval) { [weak self] sequence, text in
                guard let self, reasoningGuard.accept(sequence) else { return }
                self.streamingReasoning = text
            }

            do {
                let result = try await withSingleSourceUsageAttribution {
                    try await aiService.streamChatWithTools(
                        config: config,
                        system: currentSystem.stable,
                        sourceSystem: currentSystem.sources,
                        volatileSystem: currentSystem.volatile,
                        turns: currentTurns,
                        tools: tools,
                        maxTokens: currentMaxTokens,
                        webSearch: webSearch,
                        webSearchDepth: webSearchDepth,
                        learnerTurnIndex: learnerTurnIndex,
                        onReasoningDelta: { delta in reasoningBatcher.consume(delta) },
                        onTextDelta: { delta in batcher.consume(delta) }
                    )
                }
                // The batcher publishes on an interval, so the reasoning's last
                // words may not have reached the row; the stream is over now
                // and its full text can be read.
                settleThinking(before: messageID, reasoning: reasoningBatcher.snapshotText(), startedAt: attemptStartedAt)
                try Task.checkCancellation()
                let fullText = (prefix + result.text).trimmingCharacters(in: .whitespacesAndNewlines)
                // What the learner would read. The suggested-questions tail is
                // not an answer, so a reply that is only that block has said
                // nothing and takes the same retry as an empty one.
                let shown = ChatFollowUps.hidingBlock(in: fullText)

                // Finished cleanly with neither text nor tool calls: a reasoning
                // model that spent its budget on hidden thinking. Retry with a
                // direct-answer directive and more room before surfacing an error.
                if shown.isEmpty, result.toolCalls.isEmpty,
                   emptyOutputRetries < emptyOutputTokenRetryMaxAttempts {
                    emptyOutputRetries += 1
                    appendSystemActivity(
                        .retry,
                        slug: "empty_output_retry",
                        title: "Retrying for a visible answer",
                        detail: "the model streamed only hidden reasoning (attempt \(emptyOutputRetries) of \(emptyOutputTokenRetryMaxAttempts))",
                        before: messageID
                    )
                    currentMaxTokens = min(currentMaxTokens * 2, chatResponseMaxOutputTokensCeiling)
                    // The directive goes at the end of the request, not in the
                    // per-turn tail: the tail sits ahead of this turn's tool
                    // rounds, so changing it rewrites every one of them.
                    currentSystem = system
                    currentTurns = Self.nativeTurns(turns, endingWith: "Your previous response streamed no visible text — only hidden reasoning or metadata. Answer directly in plain text now, or call the appropriate tool. Lead with the answer and keep internal reasoning minimal.")
                    prefixText = ""
                    if let index = chatMessages.firstIndex(where: { $0.id == messageID }) {
                        chatMessages[index].content = ""
                    }
                    continue
                }

                guard !shown.isEmpty || !result.toolCalls.isEmpty else {
                    chatMessages.removeAll { $0.id == messageID }
                    throw AIError.apiError(Self.noVisibleAnswerMessage)
                }

                // Held text is the caller's to show, once it has passed.
                if showsTextWhileStreaming, let index = chatMessages.firstIndex(where: { $0.id == messageID }) {
                    let visible = Self.visibleAssistantText(from: fullText)
                        .map { Self.strippingLeakedNativeToolPayloads($0, toolCalls: result.toolCalls) }
                    chatMessages[index].content = repairingSourceTitleMarkers(in: visible ?? "")
                }
                return AIToolStreamResult(
                    text: fullText,
                    toolCalls: result.toolCalls,
                    webCitations: result.webCitations
                )
            } catch AIError.outputTokenLimit(_) {
                // Before any retry row, so the transcript keeps the order it
                // happened in: what the model thought, then what went wrong.
                settleThinking(before: messageID, reasoning: reasoningBatcher.snapshotText(), startedAt: attemptStartedAt)
                let partial = (prefix + batcher.snapshotText())
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if partial.isEmpty,
                   emptyOutputRetries < emptyOutputTokenRetryMaxAttempts,
                   currentMaxTokens < chatResponseMaxOutputTokensCeiling {
                    emptyOutputRetries += 1
                    appendSystemActivity(
                        .retry,
                        slug: "empty_output_retry",
                        title: "Retrying for a visible answer",
                        detail: "the output budget was spent on hidden reasoning — doubling it (attempt \(emptyOutputRetries) of \(emptyOutputTokenRetryMaxAttempts))",
                        before: messageID
                    )
                    currentMaxTokens = min(currentMaxTokens * 2, chatResponseMaxOutputTokensCeiling)
                    currentSystem = system
                    currentTurns = Self.nativeTurns(turns, endingWith: "Answer directly and concisely. Lead with the answer and keep internal reasoning minimal so the response fits within the output budget.")
                    prefixText = ""
                    if let index = chatMessages.firstIndex(where: { $0.id == messageID }) {
                        chatMessages[index].content = ""
                    }
                    continue
                }

                if !partial.isEmpty, continuationAttempts < outputTokenContinuationMaxAttempts {
                    continuationAttempts += 1
                    appendSystemActivity(
                        .continuation,
                        slug: "output_limit_continuation",
                        title: "Continuing past the output limit",
                        detail: "attempt \(continuationAttempts) of \(outputTokenContinuationMaxAttempts)",
                        before: messageID
                    )
                    // Source shrink applies to the stable head (where the
                    // source text lives); the volatile tail is preserved.
                    currentSystem = GenerationSystemPrompt(
                        stable: compactedSystemPromptForOutputTokenRetry(
                            from: system.stableWithSources,
                            allowSourceRetrieval: false
                        ),
                        volatile: system.volatile
                    )
                    prefixText = partial
                    currentTurns = turns + [
                        .assistant(text: partial, toolCalls: []),
                        .user("Continue exactly from where you stopped. Do not repeat any text already written. Keep the continuation concise and complete the answer.")
                    ]
                    continue
                }

                let finalAnswer = try await compactedFinalAnswerAfterOutputLimit(
                    partial: partial,
                    system: system.combined,
                    messages: flattenedProviderMessages(from: turns),
                    config: config,
                    anchorMessageID: messageID
                )
                if showsTextWhileStreaming, let index = chatMessages.firstIndex(where: { $0.id == messageID }) {
                    chatMessages[index].content = finalAnswer
                }
                return AIToolStreamResult(text: finalAnswer, toolCalls: [])
            } catch {
                // A stopped or failed step keeps what it thought: a reply the
                // learner stopped still shows the reasoning behind it.
                settleThinking(before: messageID, reasoning: reasoningBatcher.snapshotText(), startedAt: attemptStartedAt)
                // Context overflow: compact the request and retry rather than
                // dead-ending the turn (see the text path for rationale).
                if !userStoppedGeneration,
                   AITransientErrorClassifier.isContextOverflow(error),
                   contextOverflowRetries < contextOverflowRetryMaxAttempts {
                    try Task.checkCancellation()
                    contextOverflowRetries += 1
                    logger.warning("Provider rejected the native-tools request as over the context window (attempt \(contextOverflowRetries)); compacting and retrying: \(error.localizedDescription)")
                    appendSystemActivity(
                        .compaction,
                        slug: "context_overflow_compaction",
                        title: "Compacted the request",
                        detail: "it exceeded the model's context window — retrying (attempt \(contextOverflowRetries) of \(contextOverflowRetryMaxAttempts))",
                        resultPreview: error.localizedDescription,
                        before: messageID
                    )
                    currentSystem.stable = compactedSystemPromptForContextOverflow(from: currentSystem.stableWithSources)
                    currentSystem.sources = ""
                    hardTrimNativeToolResultTurns(&currentTurns)
                    continue
                }

                guard !userStoppedGeneration,
                      AITransientErrorClassifier.isTransient(error),
                      transientRetries < transientStreamRetryMaxAttempts else {
                    throw error
                }
                let rateLimited = AITransientErrorClassifier.isRateLimited(error)
                let retryAfter = AITransientErrorClassifier.retryAfterSeconds(error) ?? 0
                // A wait the server says outlasts our retry budget is not
                // something to sit through three times over — surface it now,
                // with the server's own message, which names the wait. A 429
                // carrying no hint still gets the normal backoff: upstream
                // provider limits are usually seconds, not the proxy's hour.
                guard retryAfter <= AITransientErrorClassifier.maximumRetryAfterWait else {
                    throw error
                }
                try Task.checkCancellation()
                transientRetries += 1
                let backoffSeconds = transientStreamRetryBaseDelaySeconds * pow(2.0, Double(transientRetries - 1))
                let delaySeconds = min(max(backoffSeconds, retryAfter), AITransientErrorClassifier.maximumRetryAfterWait)
                logger.warning("Transient AI stream failure (attempt \(transientRetries)), retrying in \(delaySeconds)s: \(error.localizedDescription)")
                appendSystemActivity(
                    .retry,
                    slug: "transient_stream_retry",
                    title: rateLimited ? "Waiting out an AI rate limit" : "Retrying after a connection error",
                    detail: "waiting \(Int(delaySeconds.rounded()))s (attempt \(transientRetries) of \(transientStreamRetryMaxAttempts))",
                    resultPreview: error.localizedDescription,
                    before: messageID
                )
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                let partial = (prefix + batcher.snapshotText())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !partial.isEmpty {
                    prefixText = partial
                    currentSystem = system
                    currentTurns = turns + [
                        .assistant(text: partial, toolCalls: []),
                        .user("The connection dropped mid-response. Continue exactly from where you stopped. Do not repeat any text already written.")
                    ]
                }
                continue
            }
        }
    }

    /// Validate a contour grade against the review's ideas and hold it for the
    /// reply it belongs to. Identity is checked here: an idea id the source does
    /// not have refuses the whole grade rather than trimming it.
    private func stageContourGrade(arguments: [String: Any], isFirst: Bool) -> AppToolResult {
        guard !isFirst else {
            return AppToolResult(
                text: "Error: Nothing to grade yet. Ask the first contour question now.",
                isError: true
            )
        }
        guard stagedContourGrade == nil else {
            return AppToolResult(
                text: "Error: This answer already has a staged grade. Reply to the learner without grading it twice.",
                isError: true
            )
        }
        // A source has one contour, at its opening. Probes that follow are
        // graded by the tutor's own reply, not by the grader: on 2026-09-21 a
        // paper's full seven-idea contour was re-graded on eight consecutive
        // answers, so every correct answer to a narrow probe still scored ~0.1
        // against the whole paper and eight low contours went onto its ladder.
        if let sourceID = (arguments["source_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           memoryReviewStatusBySource[sourceID] != nil {
            return AppToolResult(
                text: "Error: This source's contour has already been graded in today's review. "
                    + "A source is graded once, at its contour; answer this probe in your reply "
                    + "without calling the grader.",
                isError: true
            )
        }
        switch MemoryContourGrade.validate(arguments: arguments, ideasBySource: memoryReviewIdeasBySource) {
        case .failure(let error):
            logger.error("grade_memory_contour rejected: \(error.message, privacy: .public)")
            return AppToolResult(text: error.message, isError: true)
        case .success(let grade):
            stagedContourGrade = grade
            // The contour just graded is the source under discussion until the
            // tutor writes its next turn line; the strip follows it either way.
            memoryReviewCurrentSourceID = grade.sourceID
            let depth = memoryReviewDepthBySource[grade.sourceID] ?? .standard
            return AppToolResult(
                text: MemoryReviewTutoring.gradeAcknowledgement(grade: grade, depth: depth),
                isError: false
            )
        }
    }

    /// `grade_topic_recall` from the tutor, in a review planned by topic: the
    /// opening answer to a topic graded against every idea it lists, across
    /// its sources, or a Go deeper answer graded on the probed idea. Staged
    /// for the reply it belongs to, like a contour grade, and written onto
    /// that reply's exchange by `persistAssistantResponse`.
    private func stageTopicGrade(arguments: [String: Any], isFirst: Bool) -> AppToolResult {
        guard !isFirst else {
            return AppToolResult(
                text: "Error: Do not grade before the learner has answered. Ask the first topic's opening question now.",
                isError: true
            )
        }
        guard stagedContourGrade == nil else {
            return AppToolResult(
                text: "Error: This answer already has a staged grade. Reply to the learner without grading it twice.",
                isError: true
            )
        }
        var ideasByID: [String: SourceIdea] = [:]
        for ideas in memoryReviewIdeasBySource.values {
            for idea in ideas { ideasByID[idea.id] = idea }
        }
        let graded = Set(memoryReviewIdeaStates.keys)
        switch MemoryContourGrade.validateTopic(
            arguments: arguments,
            topics: memoryReviewTopics,
            ideasByID: ideasByID,
            gradedIdeaIDs: graded
        ) {
        case .failure(let error):
            let message = error.message.replacingOccurrences(of: "grade_memory_contour", with: "grade_topic_recall")
            logger.error("grade_topic_recall rejected: \(message, privacy: .public)")
            return AppToolResult(text: message, isError: true)
        case .success(let grade):
            stagedContourGrade = grade
            memoryReviewCurrentSourceID = grade.sourceID
            let topic = memoryReviewTopics.first { $0.id == grade.sourceID }
            let isOpening = graded.isDisjoint(with: Set(topic?.ideaIDs ?? []))
            return AppToolResult(
                text: MemoryReviewTutoring.topicGradeAcknowledgement(
                    grade: grade, topic: topic, isOpening: isOpening, priorStates: memoryReviewIdeaStates
                ),
                isError: false
            )
        }
    }

    /// Markdown images that point at a slide frame's file — the path a model
    /// copies out of a transcript's slide block — become the portable slide
    /// reference before the reply is kept, so the chat draws the slide, here
    /// and on every device the transcript syncs to, instead of a broken
    /// picture. The frame number comes from the source's stored block; a file
    /// the block does not name falls back to the number in its own name.
    private func rewritingSlideFramePaths(in text: String) async -> String {
        let paths = SourceImageReference.slideFramePaths(in: text)
        guard !paths.isEmpty else { return text }
        var contentBySource: [String: String] = [:]
        var indexByPath: [SourceImageReference.SlideFramePath: Int] = [:]
        for path in paths {
            if contentBySource[path.sourceID] == nil {
                contentBySource[path.sourceID] = await storage.loadSourceContent(path.sourceID)
                    ?? activeArticles.first(where: { $0.id == path.sourceID })?.content
                    ?? ""
            }
            if let index = SourceImageCatalog.slideFrameIndex(for: path, in: contentBySource[path.sourceID] ?? "") {
                indexByPath[path] = index
            }
        }
        return SourceImageReference.rewritingSlideFramePaths(in: text) { indexByPath[$0] }
    }
}

/// Batches streamed text deltas off the main actor: deltas arrive serially on
/// the AI service's executor and accumulate there; only the throttled publish
/// hops to the main actor, so a fast provider can never flood the UI thread
/// with per-token hops. Publishes carry a sequence number so a late-running hop
/// can never overwrite newer text.
private final class StreamTextBatcher: @unchecked Sendable {
    private let interval: TimeInterval
    private let publish: @MainActor (Int, String) -> Void
    private var accumulated = ""
    private var sequence = 0
    private var lastPublish = Date.distantPast

    init(interval: TimeInterval, publish: @escaping @MainActor (Int, String) -> Void) {
        self.interval = interval
        self.publish = publish
    }

    /// Called serially from the streaming executor.
    func consume(_ delta: String) {
        accumulated += delta
        let now = Date()
        guard now.timeIntervalSince(lastPublish) >= interval else { return }
        lastPublish = now
        emit()
    }

    /// The full text accumulated so far. Read only after the stream call has
    /// returned or thrown, when no further writes can occur.
    func snapshotText() -> String {
        accumulated
    }

    private func emit() {
        sequence += 1
        let currentSequence = sequence
        let text = accumulated
        Task { @MainActor in
            self.publish(currentSequence, text)
        }
    }
}

/// Rejects out-of-order streaming publishes on the main actor.
@MainActor
private final class StreamPublishGuard {
    private var lastAccepted = 0
    private var sealed = false

    func accept(_ sequence: Int) -> Bool {
        guard !sealed, sequence > lastAccepted else { return false }
        lastAccepted = sequence
        return true
    }

    /// Closes the guard once an attempt is over, so a hop still queued on the
    /// main actor can no longer publish. Sequence ordering alone does not cover
    /// this: the authoritative text is written directly, without a sequence, so
    /// a pending hop carrying a fragment would out-rank nothing and overwrite
    /// the finished answer — blanking it when that fragment renders empty.
    func seal() {
        sealed = true
    }
}
