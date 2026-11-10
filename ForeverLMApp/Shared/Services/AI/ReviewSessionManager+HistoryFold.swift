// Part of ReviewSessionManager: the running history digest.

import Foundation

extension ReviewSessionManager {
    // MARK: - Rolling history summary

    /// Where a fold stopped, named the way the saved transcript can find it again.
    struct HistoryDigestCursor: Equatable {
        let exchangeID: String
        let field: ReviewExchangeMessageField
    }

    /// One bounded fold request: the transcript to send and where it ends.
    struct HistoryFoldBatch: Equatable {
        /// "Learner:"/"Tutor:" lines for the model. Empty when the range held
        /// only harness rows, which are covered without a request.
        let transcript: String
        /// Index one past the last message this batch covers.
        let endIndex: Int
        /// The last persisted message in the batch — what gets saved so a
        /// reopened chat can pick up here. nil when nothing in the range has
        /// been persisted yet.
        let cursor: HistoryDigestCursor?
    }

    /// The next slice of not-yet-folded older turns, cut so one request never
    /// carries more than `characterLimit` of transcript. Always advances by at
    /// least one message, so a single oversized turn cannot stall the fold.
    static func historyFoldBatch(
        from messages: [Message],
        coveredMessageCount: Int,
        olderCount: Int,
        characterLimit: Int,
        turnCharacterLimit: Int
    ) -> HistoryFoldBatch? {
        let start = max(0, min(coveredMessageCount, messages.count))
        let end = max(start, min(olderCount, messages.count))
        guard end > start else { return nil }

        var lines: [String] = []
        var usedCharacters = 0
        var cursor: HistoryDigestCursor?
        var index = start
        while index < end {
            let message = messages[index]
            if message.role != .tool,
               let displayContent = displayableMessageContent(role: message.role, content: message.content)?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !displayContent.isEmpty {
                let label = message.role == .user ? "Learner" : "Tutor"
                let line = "\(label): \(String(displayContent.prefix(turnCharacterLimit)))"
                if !lines.isEmpty, usedCharacters + line.count > characterLimit { break }
                lines.append(line)
                usedCharacters += line.count + 2
            }
            if let exchangeID = message.exchangeID, let field = message.exchangeField {
                cursor = HistoryDigestCursor(exchangeID: exchangeID, field: field)
            }
            index += 1
        }
        return HistoryFoldBatch(
            transcript: lines.joined(separator: "\n\n"),
            endIndex: index,
            cursor: cursor
        )
    }

    /// How many leading messages of a rebuilt transcript a saved digest covers,
    /// or nil when the message it stopped on is no longer there (deleted, or an
    /// exchange another device rewrote). The summary is then rebuilt rather than
    /// trusted against a transcript it no longer lines up with.
    static func historyDigestCoveredMessageCount(
        in messages: [Message],
        through digest: ReviewSessionHistoryDigest
    ) -> Int? {
        guard let index = messages.firstIndex(where: {
            $0.exchangeID == digest.throughExchangeID && $0.exchangeField == digest.throughField
        }) else { return nil }
        return index + 1
    }

    /// Keep a summary within `limit`, preferring its newest lines: the oldest
    /// material has already been folded down more than once by then.
    static func boundedHistoryDigest(_ digest: String, limit: Int) -> String {
        guard digest.count > limit else { return digest }
        return "[Earlier summary trimmed]\n" + String(digest.suffix(limit))
    }

    private var historyFoldIsDue: Bool {
        let olderCount = max(0, chatMessages.count - recentMessageLimit)
        return olderCount - historyDigestCoveredMessageCount >= historyDigestFoldBlockMessageCount
    }

    func resetHistoryDigest() {
        historyFoldTask?.cancel()
        historyFoldTask = nil
        historyFoldID = nil
        historyDigest = ""
        historyDigestCoveredMessageCount = 0
    }

    /// Pick up the summary a previous run of this chat saved, so reopening a
    /// long chat folds only what has been said since rather than everything.
    func restorePersistedHistoryDigest(sessionID: String) async {
        do {
            guard let saved = try await storage.loadReviewSessionHistoryDigest(sessionID: sessionID) else { return }
            guard let covered = Self.historyDigestCoveredMessageCount(in: chatMessages, through: saved) else {
                logger.notice("Saved chat summary no longer lines up with the transcript; rebuilding it.")
                return
            }
            historyDigest = saved.digest
            historyDigestCoveredMessageCount = covered
        } catch {
            logger.warning("Could not load the saved chat summary; rebuilding it: \(error.localizedDescription)")
        }
    }

    /// Start folding aged-out turns in the background if a block of them is
    /// waiting and no fold is already running. Never awaited: whatever is not
    /// folded when the next turn is assembled rides in the deterministic
    /// transcript compact instead, so a reply never waits on a summary.
    func scheduleHistoryFoldIfNeeded() {
        guard historyFoldTask == nil, sessionActive, let sessionID, historyFoldIsDue else { return }
        // The fold runs on its own Background route (Settings › Background ›
        // Tasks), not the chat's model. With none to run on, the transcript
        // compact carries the older turns, as after a failed fold.
        guard let foldConfig = KeychainService.resolveConfig(for: .chatHistoryCompaction) else { return }

        let foldID = UUID()
        historyFoldID = foldID
        historyFoldTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Ledger rows from the fold belong to this chat, like the turn's own.
            await AIUsageAttribution.$sessionID.withValue(sessionID) {
                await self.foldChatHistory(config: foldConfig, sessionID: sessionID)
            }
            if self.historyFoldID == foldID {
                self.historyFoldTask = nil
                self.historyFoldID = nil
            }
        }
    }

    /// Fold in bounded batches until the backlog is under a block. A failure
    /// ends this run quietly: the transcript compact still covers those turns,
    /// and the next turn schedules another attempt.
    private func foldChatHistory(config: AITaskConfig, sessionID: String) async {
        while !Task.isCancelled, sessionActive, self.sessionID == sessionID, historyFoldIsDue {
            let olderCount = max(0, chatMessages.count - recentMessageLimit)
            guard let batch = Self.historyFoldBatch(
                from: chatMessages,
                coveredMessageCount: historyDigestCoveredMessageCount,
                olderCount: olderCount,
                characterLimit: historyDigestFoldCharacterLimit,
                turnCharacterLimit: historyDigestFoldTurnCharacterLimit
            ), batch.endIndex > historyDigestCoveredMessageCount else { return }

            if batch.transcript.isEmpty {
                // Harness rows only: nothing for the model, nothing to save.
                historyDigestCoveredMessageCount = batch.endIndex
                continue
            }

            // Remember the boundary by identity: a message deleted while the
            // request is out would otherwise shift the count by one.
            let lastFoldedMessageID = chatMessages[batch.endIndex - 1].id
            let existingDigest = historyDigest
            do {
                let updated = try await withSingleSourceUsageAttribution {
                    try await aiService.callChat(
                        config: config,
                        system: Self.historyFoldSystemPrompt,
                        messages: [(role: "user", content: """
                        Existing summary:
                        \(existingDigest.isEmpty ? "(none yet — this is the first fold)" : existingDigest)

                        New turns to fold in:
                        \(batch.transcript)
                        """)],
                        maxTokens: historyDigestTargetOutputTokens
                    )
                }
                guard !Task.isCancelled, self.sessionID == sessionID else { return }
                let trimmed = updated.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    throw AIError.apiError("History compaction returned an empty summary.")
                }
                historyDigest = Self.boundedHistoryDigest(trimmed, limit: historyDigestCharacterLimit)
                let lastFoldedIndex = chatMessages.firstIndex(where: { $0.id == lastFoldedMessageID })
                    ?? (batch.endIndex - 1)
                historyDigestCoveredMessageCount = lastFoldedIndex + 1

                if let cursor = batch.cursor {
                    do {
                        try await storage.saveReviewSessionHistoryDigest(ReviewSessionHistoryDigest(
                            sessionID: sessionID,
                            digest: historyDigest,
                            throughExchangeID: cursor.exchangeID,
                            throughField: cursor.field,
                            updatedAt: Date()
                        ))
                    } catch {
                        // The in-memory summary still serves this run; only the
                        // reopen shortcut is lost until the next fold saves.
                        logger.warning("Could not save the chat summary: \(error.localizedDescription)")
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                if isCancellationLike(error) { return }
                logger.warning("History fold failed; the transcript compact covers these turns until the next turn retries: \(error.localizedDescription)")
                return
            }
        }
    }

    private static let historyFoldSystemPrompt = """
    You maintain the running summary of an ongoing tutoring chat. Fold the new turns into the existing summary and output only the updated summary, dense and chronological. Preserve the learner's goals, decisions made, facts and definitions established, identifiers (source IDs, goal IDs, dates), unresolved questions, and anything either side committed to doing. Drop pleasantries and repetition. Keep the whole summary under 1,500 words: when it grows past that, fold older detail into fewer sentences rather than dropping it.
    """
}
