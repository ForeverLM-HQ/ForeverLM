// Part of ReviewSessionManager: persisting assistant responses.

import Foundation

extension ReviewSessionManager {
    /// A saved grade folded into what the review shows: each idea's latest
    /// grade and misses, each source's checkmark from its own ideas, and the
    /// topic's, so the card's ledger and the steer chips move the moment it
    /// lands. The same rule a resume rebuilds from the saved exchanges. An
    /// understanding probe's grade reaches only its idea's `understanding`:
    /// it completes no checkmark and undoes none.
    private func applyMemoryReviewGrade(_ grade: MemoryContourGrade) {
        let now = Date()
        MemoryReviewIdeaState.fold(grade.coverage, operation: grade.operation, into: &memoryReviewIdeaStates)
        guard !grade.operation.isUnderstanding else { return }
        func merged(_ existing: [MemoryIdeaCoverage], _ incoming: [MemoryIdeaCoverage]) -> [MemoryIdeaCoverage] {
            var result = existing
            for entry in incoming {
                if let index = result.firstIndex(where: { $0.ideaID == entry.ideaID }) {
                    result[index] = entry
                } else {
                    result.append(entry)
                }
            }
            return result
        }
        for group in MemoryIdeaCoverage.bySource(grade.coverage) {
            memoryReviewStatusBySource[group.sourceID] = MemoryReviewSourceStatus(
                sourceID: group.sourceID,
                coverage: merged(memoryReviewStatusBySource[group.sourceID]?.coverage ?? [], group.coverage),
                isAmbiguous: grade.verdict == .ambiguous,
                gradedAt: now
            )
        }
        if MemoryReviewTopic.isTopicID(grade.sourceID) {
            memoryReviewStatusBySource[grade.sourceID] = MemoryReviewSourceStatus(
                sourceID: grade.sourceID,
                coverage: merged(memoryReviewStatusBySource[grade.sourceID]?.coverage ?? [], grade.coverage),
                isAmbiguous: grade.verdict == .ambiguous,
                gradedAt: now
            )
        }
    }

    /// Writes this turn's reply onto its message's row. Nil when the turn
    /// has no row, or the row has a reply already; the caller then opens a
    /// row of its own, never an earlier message's.
    private func answerTurnRow(
        sessionID: String,
        answer: String,
        evaluation: String,
        score: Double?,
        sourceRefs: [String]
    ) async throws -> Int? {
        guard let sequence = turnReplySequence else { return nil }
        let answered = try await storage.answerPendingReviewExchange(
            sessionID: sessionID,
            sequence: sequence,
            answer: answer,
            evaluation: evaluation,
            score: score,
            knowledgeNote: nil,
            sourceRefs: sourceRefs
        )
        replyKept()
        return answered
    }

    /// The content a persistence stamp matches against. A reply split around
    /// turn lines lives in the transcript as its final prose, so that is what
    /// the stamp must find; every other message matches on its whole text.
    private static func persistenceMatchContent(role: Message.Role, content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard role == .assistant, content.contains("<\(MemoryReviewSourceTurn.tagName)") else { return trimmed }
        for part in MemoryReviewSourceTurn.split(content).reversed() {
            if case .text(let prose) = part { return prose }
        }
        return trimmed
    }

    func persistAssistantResponse(_ response: String, isFirst: Bool, config: AITaskConfig) async throws {
        guard let sessionID else { return }
        turnReplyWriteStarted = true
        // A settled turn has split its suggested questions off already; the
        // Stop path saves whatever had streamed. Either way the stored reply,
        // which the model's history, copy, fork, MCP transcripts and every
        // search read, holds the prose alone.
        let response = ChatFollowUps.hidingBlock(in: response)
        // What the exchange keeps: the reply with the cards this turn saved
        // at its head (`ChatSavedCards`), so a reopened chat draws them again.
        // The transcript row holds the prose alone, which the persistence
        // stamp below matches; the turn's own tool row draws the cards.
        // The pages it wrote go first, the same way (`ChatWrittenPage`).
        let stored = ChatWrittenPage.storing(
            ChatSavedCards.storing(response, with: stagedSavedCards),
            with: stagedWrittenPages
        )
        stagedSavedCards = nil
        stagedWrittenPages = []

        if isFirst {
            let sequence = try await storage.addReviewPrompt(
                sessionID: sessionID,
                question: stored,
                sourceRefs: activeSourceIDs
            )
            await updateLastMessagePersistence(
                role: .assistant,
                content: response,
                sequence: sequence,
                field: .question
            )
        } else if let staged = stagedMemoryAttempt {
            let attempt = Self.memoryAttempt(staged.attempt, replacingFeedbackWith: response)
            let linked: MemoryAttempt
            do {
                linked = try await storage.completePendingReviewExchangeAndRecordMemoryAttempt(
                    sessionID: sessionID,
                    sequence: turnReplySequence,
                    answer: attempt.learnerAnswer,
                    evaluation: stored,
                    knowledgeNote: staged.knowledgeNote,
                    sourceRefs: activeSourceIDs,
                    item: staged.item,
                    expectedExistingItem: staged.expectedExistingItem,
                    attempt: attempt,
                    answeredAt: attempt.attemptedAt
                )
            } catch {
                if staged.expectedExistingItem != nil {
                    // Any failed optimistic commit invalidates the cached queue.
                    // Keep the pending transcript untouched and require a fresh
                    // prompt/rubric snapshot before accepting another answer.
                    memoryCompanionPlan = nil
                    currentMemoryTargetIndex = 0
                    lastMemoryAttemptNeedsRetry = false
                    stagedMemoryAttempt = nil
                    throw AIError.apiError(
                        "The memory curriculum could not be confirmed at save time. Start a new memory check to reload the current target; this answer was not graded or scheduled. \(error.localizedDescription)"
                    )
                }
                throw error
            }
            replyKept()
            guard let exchangeID = linked.exchangeID else {
                throw AIError.apiError(
                    "The memory attempt was saved without its review exchange link. The review cannot continue safely."
                )
            }
            await updateLastMessagePersistence(
                role: .user,
                content: attempt.learnerAnswer,
                exchangeID: exchangeID,
                field: .userAnswer
            )
            await updateLastMessagePersistence(
                role: .assistant,
                content: response,
                exchangeID: exchangeID,
                field: .evaluation
            )
            if let item = staged.item {
                adoptCreatedMemoryItem(item)
            }
            lastMemoryAttemptNeedsRetry = !staged.shouldAdvance
            if staged.shouldAdvance, let count = memoryCompanionPlan?.targets.count, count > 0 {
                currentMemoryTargetIndex = (currentMemoryTargetIndex + 1) % count
            }
            stagedMemoryAttempt = nil
        } else if let question = lastAssistantQuestion {
            let userAnswer = (chatMessages.last(where: { $0.role == .user })?.content)
                .map { AttachedImageReference.textOnly($0) } ?? ""
            // A graded contour is about one source, and it is the one score an
            // in-app chat exchange carries, so `exemplarQuestions` can find it.
            let grade = stagedContourGrade
            let exchangeSourceRefs = grade.map { [$0.sourceID] } ?? activeSourceIDs
            let updatedPendingExchange = try await answerTurnRow(
                sessionID: sessionID,
                answer: userAnswer,
                evaluation: stored,
                score: grade?.score,
                sourceRefs: exchangeSourceRefs
            )
            let sequence: Int
            if let updatedPendingExchange {
                sequence = updatedPendingExchange
            } else {
                // A retry of a failed reply that was saved: the message is
                // on the failed reply's row already, so this row holds none.
                sequence = try await storage.addReviewExchange(
                    sessionID: sessionID,
                    question: question,
                    answer: turnFollowsSavedFailedReply ? "" : userAnswer,
                    evaluation: stored,
                    score: grade?.score,
                    knowledgeNote: nil,
                    sourceRefs: exchangeSourceRefs
                )
            }
            if let grade {
                try await storage.recordMemoryContourGrade(sessionID: sessionID, sequence: sequence, grade: grade)
                stagedContourGrade = nil
                applyMemoryReviewGrade(grade)
            }
            if updatedPendingExchange != nil || !turnFollowsSavedFailedReply {
                await updateLastMessagePersistence(
                    role: .user,
                    content: userAnswer,
                    sequence: sequence,
                    field: .userAnswer
                )
            }
            await updateLastMessagePersistence(
                role: .assistant,
                content: response,
                sequence: sequence,
                field: .evaluation
            )
        } else if isTutorLed {
            let sequence = try await storage.addReviewPrompt(
                sessionID: sessionID,
                question: stored,
                sourceRefs: activeSourceIDs
            )
            await updateLastMessagePersistence(
                role: .assistant,
                content: response,
                sequence: sequence,
                field: .question
            )
        } else if !isTutorLed,
                  let userMessage = chatMessages.last(where: { $0.role == .user })?.content {
            // The learner's message was persisted eagerly when sent; attach the
            // reply to that same pending row, falling back to a fresh exchange
            // only if eager persistence failed.
            let sequence: Int
            var messageOnRow = true
            if let pendingSequence = try await answerTurnRow(
                sessionID: sessionID,
                answer: userMessage,
                evaluation: stored,
                score: nil,
                sourceRefs: activeSourceIDs
            ) {
                sequence = pendingSequence
            } else {
                // As above: a retry of a saved failed reply writes no message.
                messageOnRow = !turnFollowsSavedFailedReply
                sequence = try await storage.addReviewExchange(
                    sessionID: sessionID,
                    question: "",
                    answer: messageOnRow ? userMessage : "",
                    evaluation: stored,
                    score: nil,
                    knowledgeNote: nil,
                    sourceRefs: activeSourceIDs
                )
            }
            if messageOnRow {
                await updateLastMessagePersistence(
                    role: .user,
                    content: userMessage,
                    sequence: sequence,
                    field: .userAnswer
                )
            }
            await updateLastMessagePersistence(
                role: .assistant,
                content: response,
                sequence: sequence,
                field: .evaluation
            )
        }

        if stagedContourGrade != nil {
            // The reply took a branch that writes no answered exchange, so the
            // grade has no row to land on. Dropped rather than stamped onto the
            // wrong turn; the tutor grades again after the learner's next answer.
            logger.error("A staged contour grade had no exchange to land on and was dropped.")
            stagedContourGrade = nil
        }

        // The day's log: a turn in this chat is a minute of the day spent
        // on it. Turns closer together than the merge gap read as one sitting.
        do {
            try await storage.recordDayActivity(kind: .chat, targetID: sessionID, title: topic)
        } catch {
            logger.error("Failed to log the chat turn in the day's log: \(error.localizedDescription)")
        }

        try await storage.updateReviewSessionModel(
            sessionID: sessionID,
            modelProvider: config.provider.rawValue,
            modelID: config.model,
            modelEffort: config.effort?.rawValue,
            modelSpeed: config.speed?.rawValue
        )
        await recordCitedSourceChatActivity(in: response)
        await updateSuggestedSessionTitleIfNeeded(from: response)
    }

    /// The Schedule's chat day for the sources a chat opens with: every source
    /// a review covers, but only the one source a chat was opened on. A chat
    /// opened across a Notebook carries the whole Notebook as context, and one
    /// broad question must not put a day on every source in it; those get
    /// their day when a reply cites them (`recordCitedSourceChatActivity`).
    /// The memory review's own picker applies the same rule when it reads the
    /// chat back (`ChatSourceEvidence`).
    func sessionCreationActivityDate(mode: InitialPromptMode, now: Date = Date()) -> Date? {
        guard !activeSourceIDs.isEmpty else { return nil }
        if mode == .review || activeSourceIDs.count == 1 { return now }
        return nil
    }

    /// Put today on the Schedule for each library source an ordinary chat's
    /// reply cites. Reviews and the memory review are not discussions of their
    /// sources; they record their own activity.
    private func recordCitedSourceChatActivity(in response: String) async {
        guard !isTutorLed, !isMemoryReviewSession else { return }
        let tokens = ChatSourceEvidence.sourceLinkTokens(in: response)
        guard !tokens.isEmpty else { return }
        var stamped = Set<String>()
        for token in tokens {
            do {
                guard let sourceID = try await storage.resolveSourceID(forLinkToken: token),
                      stamped.insert(sourceID).inserted else { continue }
                _ = try await storage.recordScheduledSourceActivity(sourceID: sourceID, on: Date(), kind: .chat)
            } catch {
                logger.error("Failed to log chat activity for a cited source: \(error.localizedDescription)")
            }
        }
    }

    func updateLastMessagePersistence(
        role: Message.Role,
        content: String,
        sequence: Int,
        field: ReviewExchangeMessageField
    ) async {
        guard let exchangeID = await exchangeID(forSequence: sequence) else { return }
        let trimmedContent = Self.persistenceMatchContent(role: role, content: content)
        guard let index = chatMessages.lastIndex(where: { message in
            message.role == role &&
            message.content.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedContent
        }) else {
            return
        }
        chatMessages[index].exchangeID = exchangeID
        chatMessages[index].exchangeField = field
    }

    func updateLastMessagePersistence(
        role: Message.Role,
        content: String,
        exchangeID: String,
        field: ReviewExchangeMessageField
    ) async {
        let trimmedContent = Self.persistenceMatchContent(role: role, content: content)
        guard let index = chatMessages.lastIndex(where: { message in
            message.role == role &&
            message.content.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedContent
        }) else { return }
        chatMessages[index].exchangeID = exchangeID
        chatMessages[index].exchangeField = field
    }

    private static func memoryAttempt(
        _ attempt: MemoryAttempt,
        replacingFeedbackWith feedback: String
    ) -> MemoryAttempt {
        MemoryAttempt(
            id: attempt.id,
            memoryItemID: attempt.memoryItemID,
            sessionID: attempt.sessionID,
            exchangeID: attempt.exchangeID,
            attemptType: attempt.attemptType,
            prompt: attempt.prompt,
            learnerAnswer: attempt.learnerAnswer,
            feedback: feedback,
            score: attempt.score,
            scheduleRating: attempt.scheduleRating,
            gradeState: attempt.gradeState,
            gradingError: attempt.gradingError,
            evidenceJSON: attempt.evidenceJSON,
            attemptedAt: attempt.attemptedAt,
            modelProvider: attempt.modelProvider,
            modelID: attempt.modelID,
            modelMetadataJSON: attempt.modelMetadataJSON
        )
    }

    private func adoptCreatedMemoryItem(_ item: MemoryItem) {
        guard let plan = memoryCompanionPlan,
              plan.targets.indices.contains(currentMemoryTargetIndex) else { return }
        var targets = plan.targets
        let previous = targets[currentMemoryTargetIndex]
        targets[currentMemoryTargetIndex] = MemoryCompanionTarget(
            memoryItem: item,
            sourceID: previous.sourceID,
            reason: previous.reason,
            daysOverdue: previous.daysOverdue
        )
        memoryCompanionPlan = MemoryCompanionPlan(
            targets: targets,
            topic: plan.topic,
            goalID: plan.goalID,
            generatedAt: plan.generatedAt
        )
    }
}
