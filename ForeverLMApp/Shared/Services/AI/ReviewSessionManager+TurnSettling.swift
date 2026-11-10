// Part of ReviewSessionManager: native tool result trimming, cancellation and settling an answer.

import Foundation
import Observation
import PDFKit
import os

extension ReviewSessionManager {
    func nativeSynthesisCall(from call: AIToolCallRequest) -> SynthesisToolCall? {
        let action: SynthesisToolCall.Action
        switch call.name {
        case "add_to_synthesis": action = .append
        case "replace_synthesis": action = .replace
        default: return nil
        }
        guard let markdown = (call.arguments["markdown"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !markdown.isEmpty else { return nil }
        return SynthesisToolCall(action: action, markdown: markdown)
    }

    /// Keep a native turn within the selected model's actual input budget by
    /// trimming the oldest result texts only when the complete request would
    /// otherwise overflow. Protocol pairing is preserved — every tool call
    /// keeps a result row — so requests stay valid. The newest complete paper
    /// returned by get_source_content is protected: it is the evidence the
    /// model explicitly requested, so it always enters the next model input
    /// verbatim while older search/list results make room around it.
    func trimNativeToolResultTurnsIfNeeded(
        _ turns: inout [AIChatTurn],
        systemPrompt: String,
        toolCharacters: Int,
        config: AITaskConfig
    ) {
        // No published window means nothing to fit to; the request goes as built.
        guard let budget = AIService.inputCharacterBudget(
            provider: config.provider,
            model: config.model,
            requestedMaxTokens: chatResponseMaxOutputTokens
        ) else { return }
        let projectedRequest = systemPrompt.count
            + toolCharacters
            + AIService.projectedCharacterCount(of: turns)
        guard projectedRequest > budget else { return }

        let truncationNote = "\n\n[Earlier tool result shortened only because the complete request exceeded this model's context window.]"
        let protectedFullSourceCallID = newestFullSourceResultCallID(in: turns)
        var excess = projectedRequest - budget
        for index in turns.indices {
            guard case .toolResults(let results) = turns[index] else { continue }
            let shortened = results.map { result -> AIToolResultPayload in
                guard excess > 0, result.callID != protectedFullSourceCallID else { return result }
                let minimumPrefixCount = min(120, result.text.count)
                let maximumRemoval = max(
                    0,
                    result.text.count - minimumPrefixCount - truncationNote.count
                )
                let replacement: String
                if maximumRemoval > 0 {
                    let removal = min(excess, maximumRemoval)
                    let prefixCount = result.text.count - removal - truncationNote.count
                    replacement = String(result.text.prefix(prefixCount)) + truncationNote
                } else if result.text.count > "[Omitted]".count {
                    replacement = "[Omitted]"
                } else {
                    return result
                }
                excess -= max(0, result.text.count - replacement.count)
                return AIToolResultPayload(
                    callID: result.callID,
                    toolName: result.toolName,
                    text: replacement,
                    isError: result.isError
                )
            }
            turns[index] = .toolResults(shortened)
            if excess <= 0 { return }
        }
    }

    /// The latest successful full-source read is the paper the model asked to
    /// reason over next. Its identity is deterministic protocol metadata, so no
    /// title parsing or content heuristics are involved.
    private func newestFullSourceResultCallID(in turns: [AIChatTurn]) -> String? {
        for turn in turns.reversed() {
            guard case .toolResults(let results) = turn else { continue }
            if let result = results.reversed().first(where: {
                $0.toolName == "get_source_content" && !$0.isError
            }) {
                return result.callID
            }
        }
        return nil
    }

    /// Emergency variant used after a provider context-overflow rejection:
    /// truncate older tool results hard while still keeping the newest complete
    /// paper verbatim. Retrying the paper lookup would only repeat the same work.
    func hardTrimNativeToolResultTurns(_ turns: inout [AIChatTurn]) {
        let truncationNote = "\n\n[Tool result truncated after the request exceeded the model's context window.]"
        let protectedFullSourceCallID = newestFullSourceResultCallID(in: turns)
        for index in turns.indices {
            guard case .toolResults(let results) = turns[index] else { continue }
            let shortened = results.map { result -> AIToolResultPayload in
                guard result.callID != protectedFullSourceCallID,
                      result.text.count > 400 else { return result }
                return AIToolResultPayload(
                    callID: result.callID,
                    toolName: result.toolName,
                    text: String(result.text.prefix(300)) + truncationNote,
                    isError: result.isError
                )
            }
            turns[index] = .toolResults(shortened)
        }
    }

    /// Plain (role, content) projection of tool-aware turns, for plain-message helpers
    /// (the terminal output-limit compaction) that speak the simple message
    /// shape. Adjacent same-role messages are merged so providers that require
    /// strict role alternation accept the result.
    func flattenedProviderMessages(from turns: [AIChatTurn]) -> [(role: String, content: String)] {
        var messages: [(role: String, content: String)] = []
        func append(role: String, _ content: String) {
            if messages.last?.role == role {
                messages[messages.count - 1].content += "\n\n" + content
            } else {
                messages.append((role: role, content: content))
            }
        }
        for turn in turns {
            switch turn {
            case .user(let text, let images):
                var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !images.isEmpty {
                    let note = "[\(images.count) attached picture\(images.count == 1 ? "" : "s") not sent on this route]"
                    trimmed = trimmed.isEmpty ? note : trimmed + "\n" + note
                }
                guard !trimmed.isEmpty else { continue }
                append(role: "user", trimmed)
            case .assistant(let text, let toolCalls):
                var content = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !toolCalls.isEmpty {
                    let calls = toolCalls.map { "[Called \($0.name)]" }.joined(separator: " ")
                    content = content.isEmpty ? calls : content + "\n" + calls
                }
                guard !content.isEmpty else { continue }
                append(role: "assistant", content)
            case .toolResults(let results):
                let text = results.map { result in
                    "[\(result.toolName) result]\n\(String(result.text.prefix(2_000)))"
                }.joined(separator: "\n\n")
                guard !text.isEmpty else { continue }
                append(role: "user", text)
            }
        }
        return messages
    }

    /// Mark any tool rows still shown as "running" failed — used when a turn is
    /// stopped or dies while a tool call is in flight, so the transcript never
    /// shows a spinner for work that is no longer being awaited.
    func markRunningToolActivitiesStopped() {
        for index in chatMessages.indices {
            guard var activity = chatMessages[index].toolActivity,
                  activity.state == .running else { continue }
            activity.state = .failed
            if activity.resultPreview == nil {
                activity.resultPreview = "Stopped before the tool finished."
            }
            chatMessages[index].toolActivity = activity
        }
    }

    func handleGenerationCancellation(messageID: UUID, isFirst: Bool, config: AITaskConfig) async {
        if pendingModelRestart {
            pendingModelRestart = false
            let index = chatMessages.firstIndex(where: { $0.id == messageID })
            let said = index.map { chatMessages[$0].content.contains(where: { !$0.isWhitespace }) } ?? false
            if !said {
                // Asked again on another model: nothing was said, so nothing
                // is kept, the message's row stays open for the next reply,
                // and an opening turn keeps its chat.
                if let index { chatMessages.remove(at: index) }
                turnRestartsOnSelectedModel = true
                return
            }
            // Words landed between the switch and the cancel: an ordinary Stop.
        }
        if let index = chatMessages.firstIndex(where: { $0.id == messageID }) {
            let trimmed = chatMessages[index].content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                chatMessages.remove(at: index)
                if userStoppedGeneration {
                    await closePendingExchangeAfterEmptyStop(isFirst: isFirst)
                }
            } else {
                chatMessages[index].content = trimmed
                if userStoppedGeneration {
                    do {
                        try await persistAssistantResponse(trimmed, isFirst: isFirst, config: config)
                        lastAssistantQuestion = trimmed
                    } catch {
                        errorMessage = error.localizedDescription
                        logger.error("Failed to persist stopped review tutor response: \(error.localizedDescription)")
                    }
                }
            }
        }

        if !userStoppedGeneration {
            errorMessage = "Generation was cancelled."
            lastGenerationFailed = true
        }
        await discardEmptyAutomaticStartIfNeeded(isFirst: isFirst)
    }

    /// A turn that failed after it had begun to answer saves what it wrote, as
    /// Stop does. The words stay on screen either way; unsaved, they vanished
    /// the next time the chat opened, and a "keep going" after them read as a
    /// reply to nothing (2026-11-07).
    ///
    /// Not when the turn had begun its own save, which a later failure must
    /// not repeat, and not in a memory review, whose replies are stored only
    /// with the graded attempt they answer. A failed save is logged: the
    /// error the learner sees stays the one that ended the turn.
    func keepFailedTurnText(_ text: String, rowID: UUID, isFirst: Bool, config: AITaskConfig) async {
        guard sessionID != nil, !turnReplyWriteStarted,
              stagedMemoryAttempt == nil, memoryCompanionPlan == nil,
              let index = chatMessages.firstIndex(where: { $0.id == rowID }),
              chatMessages[index].exchangeID == nil else { return }
        do {
            try await persistAssistantResponse(text, isFirst: isFirst, config: config)
            lastAssistantQuestion = text
            failedTurnReplySaved = true
        } catch {
            logger.error("Failed to save the reply a failed turn had written: \(error.localizedDescription)")
        }
    }

    /// A turn stopped before it said anything — during its source search, say
    /// — leaves the learner's message as a pending row. The next reply names
    /// its own row, so it no longer lands here; the row is still closed with
    /// an empty reply, which reopening skips, because a build that pairs
    /// replies with the oldest pending row (another Mac, not yet updated)
    /// would otherwise give it the next one.
    private func closePendingExchangeAfterEmptyStop(isFirst: Bool) async {
        guard !isFirst, let sessionID, let sequence = turnReplySequence,
              stagedMemoryAttempt == nil, !isTutorLed,
              let userMessage = chatMessages.last(where: { $0.role == .user })?.content else { return }
        do {
            try await storage.answerPendingReviewExchange(
                sessionID: sessionID,
                sequence: sequence,
                answer: userMessage,
                evaluation: "",
                sourceRefs: activeSourceIDs
            )
            replyKept()
        } catch {
            logger.error("Failed to close the exchange of a reply stopped before it began: \(error.localizedDescription)")
        }
    }

    /// Fixes the row this turn's reply is written to: the learner's newest
    /// message's, as the turn begins. An opening turn answers no message.
    func beginReplyPairing(isFirst: Bool) {
        turnReplyRow = isFirst ? nil : newestMessageRow
    }

    /// The row this turn's reply belongs to, in the chat that is open; nil
    /// when its message could not be saved.
    var turnReplySequence: Int? {
        guard let turnReplyRow, turnReplyRow.sessionID == sessionID else { return nil }
        return turnReplyRow.sequence
    }

    /// The turn's message has its reply; a later turn with no new message
    /// opens a row of its own.
    func replyKept() {
        if newestMessageRow == turnReplyRow {
            newestMessageRow = nil
        }
    }

    func isCancellationLike(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled
        }
        return (error as NSError).code == NSURLErrorCancelled
    }

    /// Guarantees the transcript ends a turn showing the answer that was saved.
    ///
    /// The screen and the database are written from two different values: the
    /// database gets the reply the stream returned, while the published row is a
    /// separately re-filtered copy that several mechanisms can empty — a late
    /// streaming hop, a display filter that rejects text the store accepted, a
    /// Split a finished memory review reply around its `<flm_source_turn>`
    /// lines: the prose before each turn keeps a bubble of its own, the turn
    /// becomes a heading row naming the source, and the question that follows
    /// starts fresh under it. The streamed message's id stays on the final
    /// prose, so the persistence stamp and the blank-bubble recovery still
    /// find their message. The raw reply, tags included, is what gets
    /// persisted, so reopening the chat rebuilds the same rows.
    func placeSourceTurnHeadings(in visible: String, replacingMessageAt index: Int, config: AITaskConfig) {
        let existing = chatMessages[index]
        let replacement = assistantMessages(
            splitting: visible,
            finalID: existing.id,
            createdAt: existing.createdAt,
            modelProvider: config.provider.rawValue,
            modelID: config.model
        )
        guard !replacement.isEmpty else {
            chatMessages[index].content = visible
            return
        }
        chatMessages.replaceSubrange(index...index, with: replacement)
        if let current = replacement.last(where: { $0.toolActivity?.turnTargetID != nil })?
            .toolActivity?.turnTargetID {
            memoryReviewCurrentSourceID = current
        }
    }

    /// The transcript messages one tutor reply becomes once split around its
    /// turn lines. A turn naming a source that is not in this review is
    /// dropped as debris; its prose neighbours then merge into one bubble.
    func assistantMessages(
        splitting text: String,
        finalID: UUID?,
        createdAt: Date,
        exchangeID: String? = nil,
        exchangeField: ReviewExchangeMessageField? = nil,
        modelProvider: String?,
        modelID: String?
    ) -> [Message] {
        guard let kept = Self.displayableAssistantContentKeepingSourceTurns(text) else { return [] }
        // A played walkthrough step opens with its marker line; the row it
        // becomes carries the marker as a field and shows the prose under it.
        let walkthroughStep = WalkthroughStepTurn.marker(in: kept)
        let displayable = walkthroughStep == nil ? kept : WalkthroughStepTurn.stripped(kept)
        var messages: [Message] = []
        var pendingProse: [String] = []

        func flushProse(id: UUID = UUID()) {
            let prose = pendingProse.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            pendingProse.removeAll()
            guard !prose.isEmpty else { return }
            messages.append(Message(
                id: id,
                role: .assistant,
                content: prose,
                createdAt: createdAt,
                exchangeID: exchangeID,
                exchangeField: exchangeField,
                modelProvider: modelProvider,
                modelID: modelID,
                walkthroughStep: walkthroughStep
            ))
        }

        for part in MemoryReviewSourceTurn.split(displayable) {
            switch part {
            case .text(let prose):
                // A page the turn wrote is drawn as its card, and a line of
                // saved cards as the cards, where the turn drew them
                // (`ChatWrittenPage.storing`, `ChatSavedCards.storing`).
                for head in ChatWrittenPage.split(prose) {
                    switch head {
                    case .page(let page):
                        flushProse()
                        messages.append(Message(
                            role: .tool,
                            content: "",
                            createdAt: createdAt,
                            exchangeID: exchangeID,
                            exchangeField: exchangeField,
                            toolActivity: Message.ToolActivity(
                                toolName: ChatWrittenPage.cardRowName,
                                detail: page.title,
                                state: .succeeded,
                                resultPreview: nil,
                                customTitle: page.kind == .animation ? "Animation" : "Page",
                                writtenPage: page
                            )
                        ))
                    case .text(let rest):
                        for piece in ChatSavedCards.split(rest) {
                            switch piece {
                            case .text(let text):
                                pendingProse.append(text)
                            case .cards(let cards):
                                flushProse()
                                messages.append(Message(
                                    role: .tool,
                                    content: "",
                                    createdAt: createdAt,
                                    exchangeID: exchangeID,
                                    exchangeField: exchangeField,
                                    toolActivity: Message.ToolActivity(
                                        toolName: "save_card_drafts",
                                        detail: cards.label,
                                        state: .succeeded,
                                        resultPreview: nil,
                                        savedCards: cards
                                    )
                                ))
                            }
                        }
                    }
                }
            case .turn(let sourceID):
                if MemoryReviewTopic.isTopicID(sourceID) {
                    // A topic has no library record: its row carries the id
                    // in `detail` and its title as the heading.
                    guard let topic = memoryReviewTopics.first(where: { $0.id == sourceID }) else { continue }
                    flushProse()
                    messages.append(Message(
                        role: .tool,
                        content: "",
                        createdAt: createdAt,
                        exchangeID: exchangeID,
                        exchangeField: exchangeField,
                        toolActivity: Message.ToolActivity(
                            kind: .sourceTurn,
                            toolName: Self.sourceTurnActivityName,
                            detail: topic.id,
                            sourcePresentation: nil,
                            state: .succeeded,
                            resultPreview: nil,
                            customTitle: topic.title
                        )
                    ))
                    continue
                }
                guard let presentation = sourcePresentationFromActiveArticles(sourceID) else {
                    // A chat in today's review has no article either: its row
                    // carries the id in `detail` and the briefing's title, so
                    // the turn survives the reply settling. Until 2026-09-26
                    // the line was dropped, and the card turning to a chat
                    // lost its heading and its place in the deck.
                    guard memoryReviewSourceIDs.contains(sourceID),
                          let title = memoryReviewMaterialTitles[sourceID] else { continue }
                    flushProse()
                    messages.append(Message(
                        role: .tool,
                        content: "",
                        createdAt: createdAt,
                        exchangeID: exchangeID,
                        exchangeField: exchangeField,
                        toolActivity: Message.ToolActivity(
                            kind: .sourceTurn,
                            toolName: Self.sourceTurnActivityName,
                            detail: sourceID,
                            sourcePresentation: nil,
                            state: .succeeded,
                            resultPreview: nil,
                            customTitle: title
                        )
                    ))
                    continue
                }
                flushProse()
                messages.append(Message(
                    role: .tool,
                    content: "",
                    createdAt: createdAt,
                    exchangeID: exchangeID,
                    exchangeField: exchangeField,
                    toolActivity: Message.ToolActivity(
                        kind: .sourceTurn,
                        toolName: Self.sourceTurnActivityName,
                        detail: nil,
                        sourcePresentation: presentation,
                        state: .succeeded,
                        resultPreview: nil,
                        customTitle: "Now reviewing: \(presentation.title)"
                    )
                ))
            }
        }
        flushProse(id: finalID ?? UUID())
        // A reply that ends on a heading has no prose to carry the streamed id;
        // give it to the last prose there is so the stamp still lands.
        if let finalID, !messages.contains(where: { $0.id == finalID }),
           let last = messages.lastIndex(where: { $0.role == .assistant }) {
            let prose = messages[last]
            messages[last] = Message(
                id: finalID,
                role: .assistant,
                content: prose.content,
                createdAt: prose.createdAt,
                exchangeID: prose.exchangeID,
                exchangeField: prose.exchangeField,
                modelProvider: prose.modelProvider,
                modelID: prose.modelID,
                walkthroughStep: prose.walkthroughStep
            )
        }
        return messages
    }

    /// Where a resumed memory review stands: the last source the tutor turned
    /// to, in transcript order, with a graded contour counting as a turn to
    /// its source for replies written before the turn line existed.
    static func currentMemorySourceID(
        from exchanges: [ReviewExchangeRecord],
        topics: [MemoryReviewTopic] = []
    ) -> String? {
        MemoryReviewSourceStatus.currentSourceID(from: exchanges.map {
            .init(sequenceNumber: $0.sequenceNumber, question: $0.question, ideaCoverage: $0.ideaCoverage, evaluation: $0.evaluation)
        }, topics: topics)
    }

    /// The last thing the tutor said, as persisted: the newest exchange's
    /// evaluation when it has one, else its question. Without the lines the
    /// app put at its head for the turn's pages and saved cards
    /// (`storedProse`): the live path keeps the reply's prose, and this
    /// becomes the next exchange's question and the grader's prompt.
    static func lastAssistantReplyText(from exchanges: [ReviewExchangeRecord]) -> String? {
        for exchange in exchanges.sorted(by: { $0.sequenceNumber > $1.sequenceNumber }) {
            for text in [exchange.evaluation, exchange.question] {
                guard let text, let visible = displayableAssistantContentKeepingSourceTurns(text)
                    .map(storedProse), !visible.isEmpty else { continue }
                return visible
            }
        }
        return nil
    }

    /// failure raised after the answer was already complete. Each one produces the
    /// same silent result: a saved answer and a blank bubble, with nothing on
    /// screen to say a reply ever arrived.
    ///
    /// This only fills a row that is missing or empty. A row the display path
    /// deliberately shortened (leaked tool names stripped, say) is left alone.
    private func ensureAssistantMessageVisible(id: UUID, answer: String, config: AITaskConfig) {
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }

        if let index = chatMessages.firstIndex(where: { $0.id == id }) {
            guard chatMessages[index].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            chatMessages[index].content = answer
            logger.error("Recovered a saved reply that had been left blank in the transcript.")
        } else {
            chatMessages.append(Message(
                id: id,
                role: .assistant,
                content: answer,
                modelProvider: config.provider.rawValue,
                modelID: config.model
            ))
            logger.error("Recovered a saved reply that was missing from the transcript entirely.")
        }
    }

    /// The end of a turn whose reply is an answer, in the text and the native
    /// tool loops alike: the prose stored and on its row, and the suggested
    /// questions the reply wrote kept beside it. The questions were split off
    /// before the loop's checks read the reply (`ChatFollowUps.split`).
    ///
    /// An answer with no prose is never stored. The streams retry a reply
    /// that is only the suggested-questions block, so none should arrive
    /// here; if one does, its row goes and the turn fails as an empty
    /// stream does, rather than saving an empty answer.
    func settleAnswer(
        _ answer: String,
        questions: [String],
        rowID: UUID,
        isFirst: Bool,
        config: AITaskConfig
    ) async throws {
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            chatMessages.removeAll { $0.id == rowID }
            throw AIError.apiError(Self.noVisibleAnswerMessage)
        }
        try await persistAssistantResponse(answer, isFirst: isFirst, config: config)
        ensureAssistantMessageVisible(id: rowID, answer: answer, config: config)
        adoptFollowUpQuestions(questions, forMessageID: rowID)
        lastAssistantQuestion = answer
    }

    /// What a turn says when the model wrote nothing the learner could read,
    /// even after the retries for a visible answer.
    static let noVisibleAnswerMessage = "The AI provider produced no visible assistant text even after automatic retries with a larger output budget. Switch to a non-reasoning model if this keeps happening."

    /// Puts a settled reply's suggested questions on its row, where the
    /// transcript draws them as cards under the newest answer. Only in a chat
    /// that offers them, which a walkthrough's turns never are: a walk's next
    /// step is its own card.
    private func adoptFollowUpQuestions(_ questions: [String], forMessageID id: UUID) {
        guard !questions.isEmpty, offersFollowUpQuestions,
              let index = chatMessages.firstIndex(where: { $0.id == id }) else { return }
        chatMessages[index].followUpQuestions = questions
    }
}
