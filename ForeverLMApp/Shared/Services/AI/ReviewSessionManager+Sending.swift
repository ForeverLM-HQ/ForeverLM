// Part of ReviewSessionManager: sending, queued follow-ups, retry and take-back.

import Foundation

extension ReviewSessionManager {
    func sendAnswer(
        _ text: String,
        contextualContent: String? = nil,
        docAnchor: ChatDocAnchor? = nil
    ) async {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        beginSendPreparationTraceIfNeeded()
        errorMessage = nil
        lastGenerationFailed = false
        let stamped = attachOnScreenSources(to: attachPendingContextAdditions(to: contextualContent))
        var messageID: UUID?
        if claimOptimisticUserMessage(answer) {
            // The bubble went up before the additions were attached to it.
            if let index = chatMessages.lastIndex(where: { $0.role == .user && $0.content == answer }) {
                chatMessages[index].contextualContent = stamped
                messageID = chatMessages[index].id
            }
        } else {
            let message = Message(
                role: .user,
                content: answer,
                contextualContent: stamped
            )
            chatMessages.append(message)
            messageID = message.id
        }
        // A question typed beside a video carries the moment it stood at:
        // what was said around it and the frame on screen then.
        let contextualContent = await completeVideoMoments(in: stamped)
        if contextualContent != stamped, let messageID,
           let index = chatMessages.firstIndex(where: { $0.id == messageID }) {
            chatMessages[index].contextualContent = contextualContent
        }
        // Continuing a finished review reopens it now (idempotent: only acts when the
        // session is currently completed). Reopen is deferred to here so merely viewing
        // a completed/imported review never un-marks it reviewed.
        if let sessionID {
            do {
                try await storage.reopenReviewSession(sessionID: sessionID)
            } catch {
                logger.error("Failed to reopen review session before continuing: \(error.localizedDescription)")
            }
        }
        markSendPreparation("reopen")
        await persistPendingUserMessage(answer, contextContent: contextualContent, docAnchor: docAnchor)
        markSendPreparation("message row")
        await generateQuestion(isFirst: false)
    }

    // MARK: - Queued follow-ups

    /// Files a message to be sent when the running turn is over. Its bubble is
    /// drawn by the panel from `queuedFollowUps`; nothing is persisted until it
    /// is admitted, so a message returned to the composer leaves no trace.
    @discardableResult
    func enqueueFollowUp(
        _ text: String,
        contextualContent: String? = nil,
        docAnchor: ChatDocAnchor? = nil
    ) -> QueuedFollowUp? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let item = QueuedFollowUp(
            id: UUID(),
            text: trimmed,
            contextualContent: contextualContent,
            docAnchor: docAnchor
        )
        queuedFollowUps.append(item)
        return item
    }

    /// Takes one waiting message back out, for the composer to edit.
    @discardableResult
    func removeQueuedFollowUp(_ id: UUID) -> QueuedFollowUp? {
        guard let index = queuedFollowUps.firstIndex(where: { $0.id == id }) else { return nil }
        return queuedFollowUps.remove(at: index)
    }

    /// Empties the queue and hands back what was in it. Stop calls this before
    /// cancelling: a stop is "not that reply", not "not my next message", so
    /// the words go back to the composer instead of being sent unread or lost.
    func takeQueuedFollowUps() -> [QueuedFollowUp] {
        let taken = queuedFollowUps
        queuedFollowUps.removeAll()
        return taken
    }

    /// The learner wants this message answered now, not after the reply being
    /// written: the reply stops where it is, kept as far as it got, and this
    /// message goes next, ahead of anything queued before it. The rest of the
    /// queue keeps waiting in order — cutting a reply short for one message is
    /// not Stop, which hands the whole queue back. With no turn to cut short
    /// (the last one failed and left the queue under its Retry) it just sends.
    func sendQueuedFollowUpNow(_ id: UUID) async {
        guard let index = queuedFollowUps.firstIndex(where: { $0.id == id }) else { return }
        if index != 0 {
            let item = queuedFollowUps.remove(at: index)
            queuedFollowUps.insert(item, at: 0)
        }
        if canStopGeneration {
            // Only the reply is cut short. The turn's own loop admits the head
            // of the queue once the stopped reply has been kept, so unlike
            // `stopGeneration` this leaves the follow-up request standing.
            pendingModelRestart = false
            userStoppedGeneration = true
            activeGenerationTask?.cancel()
            return
        }
        await resumeQueuedFollowUps()
    }

    /// Sends the waiting messages when no turn is running to send them after:
    /// the previous turn failed with Retry on offer, and the learner sent
    /// something new instead. Nothing to do while a turn is in flight — its
    /// own loop drains the queue.
    func resumeQueuedFollowUps() async {
        guard !isGenerating, !isPreparingGeneration, activeGenerationTask == nil,
              sessionActive, !queuedFollowUps.isEmpty else { return }
        errorMessage = nil
        lastGenerationFailed = false
        let next = queuedFollowUps.removeFirst()
        await admitQueuedFollowUp(next)
        await generateQuestion(isFirst: false)
    }

    /// Moves a queued message into the transcript and storage, the way
    /// `sendAnswer` does for a live send. The preparation lease is held across
    /// the write so the composer keeps queueing: `isGenerating` is false between
    /// turns, and a send that slipped in here would start a second turn.
    func admitQueuedFollowUp(_ item: QueuedFollowUp) async {
        beginGenerationPreparation()
        defer { endGenerationPreparation() }
        let contextualContent = await completeVideoMoments(
            in: attachOnScreenSources(to: attachPendingContextAdditions(to: item.contextualContent))
        )
        chatMessages.append(Message(
            role: .user,
            content: item.text,
            contextualContent: contextualContent
        ))
        await persistPendingUserMessage(item.text, contextContent: contextualContent, docAnchor: item.docAnchor)
    }

    // MARK: - Optimistic user bubble

    /// The learner's message, appended to `chatMessages` the instant it was sent and
    /// not yet claimed by the send path.
    struct OptimisticUserMessage {
        let text: String
        /// Whether the transcript was empty when the bubble went up. `sendMessage`
        /// branches on that, and the bubble itself would otherwise hide it.
        let startsNewSession: Bool
    }

    /// Puts the learner's message on screen immediately. The send path has to hydrate
    /// source content, reopen the session and hit SQLite before generation starts, and
    /// a bubble that waits for all of that reads as the message having been swallowed.
    /// Call this from the same main-actor turn as the submit, before any `await`.
    func showUserMessage(_ text: String, contextualContent: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        optimisticUserMessage = OptimisticUserMessage(
            text: trimmed,
            startsNewSession: !sessionActive && chatMessages.isEmpty
        )
        chatMessages.append(Message(
            role: .user,
            content: trimmed,
            contextualContent: contextualContent
        ))
    }

    /// True when `text` is already on screen from `showUserMessage`, meaning the send
    /// path must not append it a second time.
    private func claimOptimisticUserMessage(_ text: String) -> Bool {
        guard optimisticUserMessage?.text == text else { return false }
        optimisticUserMessage = nil
        return true
    }

    /// Pulls the bubble back off screen when the send fails before a session exists.
    /// Leaving it would keep `chatMessages` non-empty and route every later send down
    /// the continue-session path, so the session could never start.
    private func rollbackOptimisticUserMessage(_ text: String) {
        discardSendPreparationTrace()
        guard optimisticUserMessage?.text == text else { return }
        optimisticUserMessage = nil
        if let index = chatMessages.lastIndex(where: { $0.role == .user && $0.content == text }) {
            chatMessages.remove(at: index)
        }
    }

    /// A prerequisite owned by the chat surface failed after the optimistic
    /// bubble appeared but before `sendMessage` took ownership of it.
    func discardOptimisticUserMessage(_ text: String) {
        rollbackOptimisticUserMessage(text)
    }

    /// Persist the learner's message the moment it is sent, so a crash or force
    /// quit during generation never loses it. The evaluation lands on the same
    /// exchange row when the tutor reply completes; failures here are logged but
    /// never block the turn — the end-of-turn persistence still surfaces errors.
    func persistPendingUserMessage(
        _ text: String,
        contextContent: String? = nil,
        docAnchor: ChatDocAnchor? = nil
    ) async {
        guard let sessionID else { return }
        let context = contextContent?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let sequence = try await storage.recordPendingReviewUserMessage(
                sessionID: sessionID,
                answer: text,
                sourceRefs: activeSourceIDs,
                contextContent: (context?.isEmpty == false) ? context : nil
            )
            newestMessageRow = ReplyRow(sessionID: sessionID, sequence: sequence)
        } catch {
            // With no row of its own, the reply opens one rather than taking
            // an earlier message's.
            newestMessageRow = nil
            logger.error("Failed to eagerly persist the learner's message: \(error.localizedDescription)")
        }
        await recordDocAnchor(docAnchor, sessionID: sessionID)
        await recordSourceHighlightLink(sessionID: sessionID)
    }

    /// Links the reader mark this chat was opened on (What's New) to the chat,
    /// once the chat has a row to link. The open reader re-reads its marks on
    /// the data-change post and offers the chat from the mark.
    ///
    /// Logged and swallowed like `recordDocAnchor`: the link records where the
    /// research came from, and losing it must never cost the learner the answer.
    private func recordSourceHighlightLink(sessionID: String) async {
        guard let highlightID = pendingSourceHighlightLink else { return }
        pendingSourceHighlightLink = nil
        do {
            try await storage.linkSourceHighlight(id: highlightID, toChat: sessionID)
            NotificationCenter.default.post(name: .foreverLMDataDidChange, object: nil)
        } catch {
            logger.error("Failed to link a chat to the reader mark it was opened on: \(error.localizedDescription)")
        }
    }

    /// Writes down that this chat began on a passage of a doc — here, on the
    /// send, rather than when Chat was opened from the doc. Opening Chat and
    /// then typing nothing is not a conversation about the passage, and a link
    /// written at open time would claim one for every abandoned click.
    ///
    /// A failure is logged and swallowed: the link is a record of where the
    /// question came from, and losing it must never cost the learner the answer.
    private func recordDocAnchor(_ anchor: ChatDocAnchor?, sessionID: String) async {
        guard let anchor else { return }
        do {
            try await storage.linkArtifactPassageToChat(
                artifactID: anchor.artifactID,
                sessionID: sessionID,
                selectionStart: anchor.selectionStart,
                selectionEnd: anchor.selectionEnd,
                quote: anchor.quote,
                sectionTitle: anchor.sectionTitle,
                anchorRevision: anchor.artifactRevision.isEmpty ? nil : anchor.artifactRevision
            )
        } catch {
            logger.error("Failed to link a chat to the doc passage it started on: \(error.localizedDescription)")
        }
    }

    func retryLastGeneration() async {
        guard canRetryLastGeneration else { return }
        retryFollowsSavedFailedReply = failedTurnReplySaved
        markFailedAttemptRows()
        await generateQuestion(isFirst: chatMessages.isEmpty)
    }

    /// Marks what the failed turn left on screen — every row after the
    /// newest learner message — as the failed attempt's, so the answer block
    /// the retry adds to times and draws the new attempt alone.
    private func markFailedAttemptRows() {
        let start = chatMessages.lastIndex(where: { $0.role == .user }).map { $0 + 1 } ?? 0
        for index in start..<chatMessages.count where !chatMessages[index].isFromFailedAttempt {
            chatMessages[index].isFromFailedAttempt = true
        }
    }

    // MARK: - Try again and Edit

    /// The newest learner message and the reply saved on its row: the turn
    /// Try again asks again and Edit takes back (Codex's retry and
    /// edit-and-resend). Nil when the newest message has no saved reply.
    struct SettledTurn: Equatable {
        let userIndex: Int
        let exchangeID: String
    }

    nonisolated static func newestSettledTurn(in messages: [Message]) -> SettledTurn? {
        guard let userIndex = messages.lastIndex(where: { $0.role == .user && $0.toolActivity == nil }),
              let exchangeID = messages[userIndex].exchangeID,
              messages[userIndex].exchangeField == .userAnswer else { return nil }
        let replied = messages[(userIndex + 1)...].contains {
            $0.role == .assistant && $0.exchangeID == exchangeID && $0.exchangeField == .evaluation
        }
        return replied ? SettledTurn(userIndex: userIndex, exchangeID: exchangeID) : nil
    }

    /// Whether the newest turn can be asked again or taken back: a chat, not
    /// a review (a review's turns are graded and scheduled, and storage keeps
    /// a turn linked to memory history immutable), nothing running or
    /// waiting, and the newest message's reply saved.
    var canTakeBackNewestTurn: Bool {
        sessionActive && !isTutorLed && stagedMemoryAttempt == nil && !queuesSendsNow && !isSearching
            && Self.newestSettledTurn(in: chatMessages) != nil
    }

    /// Try again: the newest reply goes, from the transcript and from its
    /// row, and the learner's message is asked again on the model the chat is
    /// set to now (Try again with… sets it first). False, with nothing
    /// changed, once the turn can no longer be taken back.
    @discardableResult
    func tryAgain() async -> Bool {
        guard canTakeBackNewestTurn, let sessionID,
              let turn = Self.newestSettledTurn(in: chatMessages) else { return false }
        // Held across the writes so a send made meanwhile queues behind the
        // new reply rather than starting a turn of its own.
        beginGenerationPreparation()
        let sequence: Int?
        do {
            try await storage.deleteReviewExchangeMessage(
                sessionID: sessionID, exchangeID: turn.exchangeID, field: .evaluation
            )
            sequence = try await storage.loadReviewSessionExchanges(sessionID: sessionID)
                .first { $0.id == turn.exchangeID }?.sequenceNumber
        } catch {
            endGenerationPreparation()
            errorMessage = error.localizedDescription
            logger.error("Try again could not remove the reply: \(error.localizedDescription)")
            return false
        }
        endGenerationPreparation()
        guard self.sessionID == sessionID, chatMessages.indices.contains(turn.userIndex),
              chatMessages[turn.userIndex].exchangeID == turn.exchangeID else { return false }
        dropRows(after: turn.userIndex)
        // The message's row is open again, and the new reply is written to it.
        newestMessageRow = sequence.map { ReplyRow(sessionID: sessionID, sequence: $0) }
        await generateQuestion(isFirst: false)
        return true
    }

    /// Edit and resend: the newest learner message and the reply after it
    /// go, from the transcript and from storage, so the edited words can be
    /// sent in their place. `exchangeID` is the message the learner chose to
    /// edit; false, with nothing changed, when it is no longer the newest
    /// settled turn.
    @discardableResult
    func takeBackNewestTurn(exchangeID: String) async -> Bool {
        guard canTakeBackNewestTurn, let sessionID,
              let turn = Self.newestSettledTurn(in: chatMessages),
              turn.exchangeID == exchangeID else { return false }
        do {
            try await storage.deleteReviewExchangeMessage(
                sessionID: sessionID, exchangeID: exchangeID, field: .evaluation
            )
            try await storage.deleteReviewExchangeMessage(
                sessionID: sessionID, exchangeID: exchangeID, field: .userAnswer
            )
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Edit could not take back the message: \(error.localizedDescription)")
            return false
        }
        guard self.sessionID == sessionID, chatMessages.indices.contains(turn.userIndex),
              chatMessages[turn.userIndex].exchangeID == exchangeID else { return false }
        dropRows(after: turn.userIndex - 1)
        newestMessageRow = nil
        return true
    }

    /// Everything after `index` leaves the transcript, and what was read off
    /// the rows that went is read again from the ones that stay.
    private func dropRows(after index: Int) {
        let start = max(0, index + 1)
        guard start < chatMessages.count else { return }
        chatMessages.removeSubrange(start...)
        historyDigestCoveredMessageCount = min(historyDigestCoveredMessageCount, chatMessages.count)
        lastAssistantQuestion = chatMessages.last(where: { $0.role == .assistant && $0.toolActivity == nil })?.content
        completedSummary = nil
        lastGenerationFailed = false
        errorMessage = nil
    }

    func stopGeneration() {
        guard canStopGeneration else { return }
        // Stop means stop everything, including any message queued mid-turn.
        followUpGenerationRequested = false
        pendingModelRestart = false
        userStoppedGeneration = true
        activeGenerationTask?.cancel()
    }

    /// Whether the running turn can be asked again from the start: it has
    /// written none of its reply, run no tool (a tool asked twice could write
    /// twice), and no message has been saved behind it. A thinking row or an
    /// automatic retry row does not count; neither did anything.
    var canRestartTurn: Bool {
        guard canStopGeneration, activeGenerationTask != nil, !userStoppedGeneration,
              modelOverride == nil, newestMessageRow == turnReplyRow else { return false }
        return !Self.turnHasActed(in: chatMessages)
    }

    /// Whether the turn at the end of `messages` (everything after the newest
    /// learner message) has written any of its reply or run a tool.
    nonisolated static func turnHasActed(in messages: [Message]) -> Bool {
        for message in messages.reversed() {
            if message.role == .user { return false }
            if message.toolActivity?.kind == .tool { return true }
            if message.role == .assistant, message.toolActivity == nil,
               message.content.contains(where: { !$0.isWhitespace }) {
                return true
            }
        }
        return false
    }

    /// Asks the running turn again on the model now selected for the chat:
    /// the slow free model offer's switch (`SlowFreeModelOffer`). The turn has
    /// said nothing (`canRestartTurn`), so nothing is kept and no error shows;
    /// the learner's message keeps its row, and the generation loop sends it
    /// again at once, ahead of anything queued. False, with the turn left
    /// running, once that no longer holds: the new model then takes the next
    /// message.
    @discardableResult
    func restartTurnOnSelectedModel() -> Bool {
        guard canRestartTurn else { return false }
        pendingModelRestart = true
        // Through the stop path, so the cancellation surfaces as one wherever
        // in the turn it lands, and no transient retry tries to outlast it.
        userStoppedGeneration = true
        activeGenerationTask?.cancel()
        return true
    }

    func deleteMessage(_ message: Message) async {
        guard !isGenerating, !isSearching else {
            errorMessage = "Wait for the current Chat response to finish before deleting a message."
            return
        }

        if let sessionID,
           let exchangeID = message.exchangeID,
           let exchangeField = message.exchangeField {
            do {
                try await storage.deleteReviewExchangeMessage(
                    sessionID: sessionID,
                    exchangeID: exchangeID,
                    field: exchangeField
                )
            } catch {
                errorMessage = error.localizedDescription
                logger.error("Failed to delete review chat message: \(error.localizedDescription)")
                return
            }
        }

        if let index = chatMessages.firstIndex(where: { $0.id == message.id }),
           index < historyDigestCoveredMessageCount {
            // The summary already covers this message; the boundary it marks
            // moves up with the deletion, or the turn just behind it would be
            // dropped from the transcript compact as if it had been folded too.
            historyDigestCoveredMessageCount -= 1
        }
        chatMessages.removeAll { $0.id == message.id }
        if lastAssistantQuestion == message.content {
            lastAssistantQuestion = chatMessages.last(where: { $0.role == .assistant })?.content
        }
        completedSummary = nil
        lastGenerationFailed = false
    }

    /// Copies the current persisted conversation through the selected assistant
    /// turn into a new active session. The storage layer performs the clone in
    /// one transaction so the fork and its source relationships sync together.
    func forkConversation(through messages: [Message]) async -> ReviewSessionRecord? {
        guard !isGenerating, !isSearching else {
            errorMessage = "Wait for the current Chat response to finish before forking the conversation."
            return nil
        }
        guard let sessionID,
              let boundary = messages.last(where: {
                  $0.exchangeID != nil && $0.exchangeField != nil
              }),
              let exchangeID = boundary.exchangeID,
              let exchangeField = boundary.exchangeField else {
            errorMessage = "This response has not been saved yet, so it cannot be forked."
            return nil
        }

        do {
            return try await storage.forkReviewSession(
                sessionID: sessionID,
                throughExchangeID: exchangeID,
                field: exchangeField
            )
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to fork review chat: \(error.localizedDescription)")
            return nil
        }
    }

    /// - Parameter preloadSourceIDs: Sources to load in full on the opening
    ///   turn because the learner chose them. Ignored once a session is
    ///   running — from then on, sources arrive through `addContextSources`
    ///   or the model's own retrieval.
    func sendMessage(
        _ text: String,
        topic: String,
        articles: [StudioArticle] = [],
        initialMode: InitialPromptMode = .review,
        goalID: String? = nil,
        notebookScopeID: String? = nil,
        preloadSourceIDs: Set<String> = [],
        contextualContent: String? = nil,
        docAnchor: ChatDocAnchor? = nil
    ) async {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        beginSendPreparationTraceIfNeeded()

        // An optimistic bubble makes `chatMessages` non-empty, so the branch has to
        // read the emptiness recorded when the bubble went up, not the current state.
        let startsNewSession: Bool
        if let pending = optimisticUserMessage, pending.text == message {
            startsNewSession = pending.startsNewSession
        } else {
            startsNewSession = !sessionActive && chatMessages.isEmpty
        }

        if startsNewSession {
            await startSessionFromUserMessage(
                message,
                topic: topic,
                articles: articles,
                mode: initialMode,
                goalID: goalID,
                notebookScopeID: notebookScopeID,
                preloadSourceIDs: preloadSourceIDs,
                contextualContent: contextualContent,
                docAnchor: docAnchor
            )
        } else {
            await sendAnswer(message, contextualContent: contextualContent, docAnchor: docAnchor)
        }
    }

    func completeSynthesisToolCall(_ callID: UUID, message: String) {
        guard pendingSynthesisToolCall?.id == callID else { return }
        pendingSynthesisToolCall = nil
        if let index = chatMessages.lastIndex(where: { $0.role == .assistant }) {
            chatMessages[index].content = message
        } else {
            chatMessages.append(Message(role: .assistant, content: message))
        }
    }

    /// Whether the frame at `seconds` was captured, waiting for a capture
    /// under way up to `videoMomentFrameWait`. A capture still running then
    /// carries on for next time; this message goes without the picture.
    private func videoMomentFrameCaptured(sourceID: String, seconds: Int) async -> Bool {
        let key = SourceImageReference(sourceID: sourceID, location: .moment(seconds)).urlString
        guard let capture = videoMomentFrameCaptures[key] else { return false }
        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await capture.value }
            group.addTask {
                try? await Task.sleep(for: Self.videoMomentFrameWait)
                return nil
            }
            let first = await group.next()
            group.cancelAll()
            return (first ?? nil) ?? false
        }
    }

    /// The transcript around `seconds` of a video, read from its stored
    /// content off the main actor (`ChatContextAdditions.transcriptExcerpt`).
    private func transcriptExcerpt(
        sourceID: String,
        around seconds: Int
    ) async -> (said: String, slide: (slide: Int, from: Int, to: Int)?, trimmed: Bool)? {
        guard let content = await storage.loadSourceContent(sourceID) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let parsed = YouTubeSlideContentParser.parse(content)
            let timed = YouTubeTranscriptDisplayParser.parse(parsed.transcriptContent).segments
                .compactMap { segment -> (seconds: Double, text: String)? in
                    guard let start = YouTubeTranscriptTime.seconds(from: segment.startTime) else { return nil }
                    return (start, segment.text)
                }
            // A video with an extracted deck is asked about a slide: everything
            // said while it was up. Without one, a window around the playhead.
            let deck = parsed.displaySlides.map { slide in
                (index: slide.index, windows: slide.windows.map { (start: $0.start, end: $0.end) })
            }
            if let span = ChatContextAdditions.slideSpan(deck, at: seconds),
               let talk = ChatContextAdditions.transcriptSpan(timed, from: span.from, to: span.to, around: seconds) {
                return (talk.text, span, talk.trimmed)
            }
            guard let said = ChatContextAdditions.transcriptExcerpt(timed, around: seconds) else { return nil }
            return (said, nil, false)
        }.value
    }

    /// The message's stored context with each video moment this chat is about
    /// filled in: the transcript around it and, when the capture lands in
    /// time, the frame on screen then. Stored with the message, so every later
    /// turn replays what this one said. At most two videos, which is more than
    /// a window shows.
    private func completeVideoMoments(
        in contextualContent: String?,
        openingArticles: [StudioArticle]? = nil
    ) async -> String? {
        let stored = ChatContextAdditions.parse(contextContent: contextualContent)
        let asked = stored.onScreen.filter { isVideoMomentForThisChat($0, openingArticles: openingArticles) }
        guard !asked.isEmpty else {
            questionStartMoments = [:]
            return contextualContent
        }
        var completed: [String: ChatContextAdditions.VideoMoment] = [:]
        for shown in asked.prefix(2) {
            guard var moment = shown.moment else { continue }
            // Still where the question began (the pause lands a beat after
            // the first keystroke): keep that moment and its frame.
            if let started = questionStartMoments[shown.id], abs(started - moment.at) <= 2 {
                moment.at = started
            }
            setSendPreparationDetail("Looking at \(moment.clock)")
            startVideoMomentFrameCapture(sourceID: shown.id, seconds: moment.at)
            if let talk = await transcriptExcerpt(sourceID: shown.id, around: moment.at) {
                moment.said = talk.said
                moment.slide = talk.slide?.slide
                moment.slideFrom = talk.slide?.from
                moment.slideTo = talk.slide?.to
                moment.trimmed = talk.trimmed ? true : nil
            }
            moment.frame = await videoMomentFrameCaptured(sourceID: shown.id, seconds: moment.at)
            completed[shown.id] = moment
        }
        setSendPreparationDetail(nil)
        markSendPreparation("video moment")
        questionStartMoments = [:]
        return ChatContextAdditions.contextContent(contextualContent, completingMoments: completed)
    }

    private func startSessionFromUserMessage(
        _ message: String,
        topic: String,
        articles: [StudioArticle],
        mode: InitialPromptMode,
        goalID: String? = nil,
        notebookScopeID: String? = nil,
        preloadSourceIDs: Set<String> = [],
        contextualContent: String? = nil,
        docAnchor: ChatDocAnchor? = nil
    ) async {
        releaseWalkthroughPlaybackForNewChat(about: articles)
        let contextualContent = attachOnScreenSources(to: contextualContent)
        let trimmedTopic = reviewTitle(topic: topic, articles: articles)
        let sessionTopic: String
        let titleEchoesMessage: Bool
        if isGenericSessionTitle(trimmedTopic) || trimmedTopic.isEmpty {
            sessionTopic = topicFromInitialMessage(message)
            titleEchoesMessage = true
        } else {
            sessionTopic = trimmedTopic
            titleEchoesMessage = false
        }
        guard let config = await resolvedGenerationConfigOrShowError(for: mode) else {
            rollbackOptimisticUserMessage(message)
            return
        }
        markSendPreparation("model")

        self.topic = sessionTopic
        notebookSourceScopeID = Self.nonEmptyTrimmed(notebookScopeID)
        self.titleIsProvisional = titleEchoesMessage
        sessionPromptKind = mode.sessionPromptKindForUserMessage
        errorMessage = nil
        lastGenerationFailed = false
        completedSummary = nil
        isSearching = true

        let context = await loadSourceContext(from: articles)
        isSearching = false
        markSendPreparation("source catalog")
        guard articles.isEmpty || !context.readableSourceIDs.isEmpty else {
            errorMessage = "No readable source content is available for Chat. Fetch or import the source content before starting a review."
            rollbackOptimisticUserMessage(message)
            return
        }

        await applyAttachedSourceContext(context, articles: articles, preloading: preloadSourceIDs)
        markSendPreparation("source text")

        let id = UUID().uuidString
        do {
            try await storage.createReviewSession(
                id: id,
                topic: sessionTopic,
                sourceIDs: activeSourceIDs,
                modelProvider: config.provider.rawValue,
                modelID: config.model,
                modelEffort: config.effort?.rawValue,
                modelSpeed: config.speed?.rawValue,
                goalID: goalID,
                scheduleActivityAt: sessionCreationActivityDate(mode: mode),
                scheduleActivityKind: mode == .review ? .review : .chat,
                chatKind: Self.createdChatKind(fixedSessionID: nil, mode: mode)
            )
            sessionID = id
            sessionActive = true
            markSendPreparation("session row")
            await persistLoadedSourceIDs()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to create in-app review session: \(error.localizedDescription)")
            rollbackOptimisticUserMessage(message)
            return
        }

        // A first question typed beside a video is about the moment it stood at.
        let askedContext = await completeVideoMoments(in: contextualContent, openingArticles: articles)
        if claimOptimisticUserMessage(message) {
            // The bubble went up before the window was read into its context.
            if let index = chatMessages.lastIndex(where: { $0.role == .user && $0.content == message }) {
                chatMessages[index].contextualContent = askedContext
            }
        } else {
            chatMessages.append(Message(
                role: .user,
                content: message,
                contextualContent: askedContext
            ))
        }
        await persistPendingUserMessage(message, contextContent: askedContext, docAnchor: docAnchor)
        markSendPreparation("message row")
        if titleEchoesMessage {
            // Name the chat from the opening message while the reply runs,
            // so the tab never sits on the learner's typed words.
            Task { await self.updateSuggestedSessionTitleIfNeeded(from: nil) }
        }
        await generateQuestion(isFirst: false)
    }

    private func isGenericSessionTitle(_ title: String) -> Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(genericSelectedSourcesTitle) == .orderedSame
    }

    private func topicFromInitialMessage(_ message: String) -> String {
        let collapsed = AttachedImageReference.textOnly(message)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= 80 { return collapsed }
        return String(collapsed.prefix(77)) + "..."
    }
}
