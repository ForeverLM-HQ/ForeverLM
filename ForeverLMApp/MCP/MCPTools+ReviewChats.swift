// MCPDataStore: Review chat import, session search and session links.
import Foundation

extension MCPDataStore {
    func getReviewSessions(topic: String?, sourceId: String? = nil) throws -> String {
        // Screen record mode (admin only): chats the take keeps off screen are
        // dropped after the query, so the unfiltered listing's cap of 20 is
        // lifted while the scope is on and applied to what is left. Nil scope:
        // an empty set and the original LIMIT 20.
        let screenScope = screenRecordScope()
        let screenRecordHidden = try screenRecordHiddenReviewSessionIDs(scope: screenScope)
        return try withDB { db in
            let queried: [[String: Any]]
            if let sourceId, !sourceId.isEmpty {
                queried = try query(db, """
                    SELECT fs.id, fs.topic, fs.started_at, fs.status, fs.overall_score, fs.summary,
                           fs.model_provider, fs.model_id, h.hidden_at,
                           COUNT(fe.id) AS exchange_count
                    FROM review_sessions fs
                    LEFT JOIN hidden_review_sessions h ON h.session_id = fs.id
                    JOIN review_session_sources fss ON fs.id = fss.session_id
                    LEFT JOIN review_exchanges fe ON fe.session_id = fs.id
                    WHERE fss.source_id = ?
                    GROUP BY fs.id, fs.topic, fs.started_at, fs.status, fs.overall_score, fs.summary, fs.model_provider, fs.model_id, h.hidden_at
                    ORDER BY fs.started_at DESC
                """, params: [sourceId])
            } else if let topic, !topic.isEmpty {
                queried = try query(db, """
                    SELECT fs.id, fs.topic, fs.started_at, fs.status, fs.overall_score, fs.summary,
                           fs.model_provider, fs.model_id, h.hidden_at,
                           COUNT(fe.id) AS exchange_count
                    FROM review_sessions fs
                    LEFT JOIN hidden_review_sessions h ON h.session_id = fs.id
                    LEFT JOIN review_exchanges fe ON fe.session_id = fs.id
                    WHERE fs.topic LIKE ?
                    GROUP BY fs.id, fs.topic, fs.started_at, fs.status, fs.overall_score, fs.summary, fs.model_provider, fs.model_id, h.hidden_at
                    ORDER BY fs.started_at DESC
                """, params: ["%\(topic)%"])
            } else {
                queried = try query(db, """
                    SELECT fs.id, fs.topic, fs.started_at, fs.status, fs.overall_score, fs.summary,
                           fs.model_provider, fs.model_id, h.hidden_at,
                           COUNT(fe.id) AS exchange_count
                    FROM review_sessions fs
                    LEFT JOIN hidden_review_sessions h ON h.session_id = fs.id
                    LEFT JOIN review_exchanges fe ON fe.session_id = fs.id
                    GROUP BY fs.id, fs.topic, fs.started_at, fs.status, fs.overall_score, fs.summary, fs.model_provider, fs.model_id, h.hidden_at
                    ORDER BY fs.started_at DESC
                    LIMIT \(screenScope == nil ? 20 : -1)
                """)
            }
            let unfilteredListing = (sourceId ?? "").isEmpty && (topic ?? "").isEmpty
            let visible = screenScope == nil ? queried : queried.filter { row in
                guard let id = row["id"] as? String else { return false }
                return !screenRecordHidden.contains(id)
            }
            let rows = unfilteredListing && screenScope != nil ? Array(visible.prefix(20)) : visible
            let pins = ChatPinRows.read()
            var lines = ["Review sessions (\(rows.count)):"]
            for r in rows {
                let id = r["id"] as? String ?? ""
                let t = r["topic"] as? String ?? ""
                let score = r["overall_score"] as? Double ?? 0
                let status = r["status"] as? String ?? ""
                let exchanges = r["exchange_count"] as? Int ?? 0
                let date = (r["started_at"] as? Double).map { appleToISO($0) } ?? ""
                let summary = r["summary"] as? String ?? ""
                let model = [r["model_provider"] as? String, r["model_id"] as? String]
                    .compactMap { value in
                        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        return trimmed.isEmpty ? nil : trimmed
                    }
                    .joined(separator: " / ")
                // A hidden chat is still the learner's: it stays listed, marked,
                // so an assistant can find it and show it again.
                let hidden = r["hidden_at"] is Double ? " [hidden from the sidebar]" : ""
                let pinned = pins.isPinned(id) ? " [pinned]" : ""
                lines.append("- \(t) (id: \(id)) [\(status)]\(pinned)\(hidden) \(String(format: "%.0f%%", score * 100)) (\(exchanges) exchanges, \(date)\(model.isEmpty ? "" : ", model: \(model)"))\(summary.isEmpty ? "" : " — \(summary)")")
            }
            return lines.joined(separator: "\n")
        }
    }

    func getReviewSessionTranscript(sessionID: String) throws -> String {
        return try withDB { db in
            let sessions = try query(db, """
                SELECT topic, status, overall_score, summary, model_provider, model_id
                FROM review_sessions
                WHERE id = ?
                LIMIT 1
            """, params: [sessionID])
            guard let session = sessions.first else {
                throw MCPError.notFound("Review session not found: \(sessionID)")
            }
            let topic = session["topic"] as? String ?? "Untitled"
            let status = session["status"] as? String ?? ""
            let score = session["overall_score"] as? Double
            let summary = session["summary"] as? String ?? ""
            let model = [session["model_provider"] as? String, session["model_id"] as? String]
                .compactMap { value in
                    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return trimmed.isEmpty ? nil : trimmed
                }
                .joined(separator: " / ")

            let exchanges = try query(db, """
                SELECT sequence_number, question, user_answer, evaluation, score, knowledge_note
                FROM review_exchanges
                WHERE session_id = ?
                ORDER BY sequence_number ASC
            """, params: [sessionID])

            var lines = ["Review session: \(topic)", "Status: \(status)"]
            if !model.isEmpty {
                lines.append("Last model: \(model)")
            }
            if let score {
                lines.append("Score: \(String(format: "%.0f%%", score * 100))")
            }
            if !summary.isEmpty {
                lines.append("Summary: \(summary)")
            }
            guard !exchanges.isEmpty else {
                lines.append("No exported transcript or recorded exchanges saved for this session.")
                return lines.joined(separator: "\n")
            }

            lines.append("")
            for exchange in exchanges {
                let sequence = exchange["sequence_number"] as? Int ?? 0
                let question = (exchange["question"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let answer = (exchange["user_answer"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let evaluation = (exchange["evaluation"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append("## Exchange \(sequence)")
                if !question.isEmpty, question != RealtimeExchangeLedger.openConversationQuestion {
                    lines.append("Assistant: \(question)")
                }
                if let answer, !answer.isEmpty {
                    lines.append("Learner: \(answer)")
                }
                if let evaluation, !evaluation.isEmpty {
                    lines.append("Assistant: \(evaluation)")
                }
                if let exchangeScore = exchange["score"] as? Double {
                    lines.append("Exchange score: \(String(format: "%.0f%%", exchangeScore * 100))")
                }
                if let note = exchange["knowledge_note"] as? String, !note.isEmpty {
                    lines.append("Note: \(note)")
                }
                lines.append("")
            }
            return lines.joined(separator: "\n")
        }
    }

    func importReviewChat(
        title: String,
        transcript: String,
        transcriptFile: String? = nil,
        sourceIDs requestedSourceIDs: [String]?,
        summary: String?,
        overallScore: Double?,
        modelProvider: String?,
        modelID: String?,
        notebookID: String? = nil,
        sessionID appendToSessionID: String? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        marksReviewed requestedMarksReviewed: Bool? = nil
    ) throws -> String {
        var trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileArgument = transcriptFile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A chat link, `foreverlm://chat/<id>`, names the session as well as
        // its bare id does, whichever layer the argument arrives through.
        let appendTarget = appendToSessionID.map { Self.reviewSessionID(from: $0) }
        guard !trimmedTranscript.isEmpty || !fileArgument.isEmpty else {
            throw MCPError.invalidInput("transcript or transcript_file is required.")
        }

        // The assistant's own record of the chat beats its retelling: a session
        // file holds the turns as the learner saw them, timed, with the source
        // links the answer carried. It is read whole every time, and with
        // session_id the stored chat is brought level with it.
        let record: AssistantTranscriptFile?
        let turns: [ReviewChatTurn]
        if !fileArgument.isEmpty {
            let url = try resolveTranscriptFile(fileArgument)
            do {
                record = try AssistantTranscriptFile.read(at: url)
            } catch let error as AssistantTranscriptFile.ReadError {
                throw MCPError.invalidInput(error.localizedDescription)
            }
            turns = record?.turns ?? []
            if trimmedTitle.isEmpty, let recordTitle = record?.title { trimmedTitle = recordTitle }
        } else {
            record = nil
            turns = parseReviewTranscript(trimmedTranscript)
        }
        guard !trimmedTitle.isEmpty || appendTarget?.isEmpty == false else { throw MCPError.invalidInput("title is required.") }
        guard !turns.isEmpty else { throw MCPError.invalidInput("transcript had no readable messages.") }

        let store = try knowledgeStore()
        let recordProvider = record?.kind == .claudeCodeSession ? "Claude" : nil
        let resolvedProvider = cleanedOptional(modelProvider) ?? recordProvider
        let resolvedModelID = cleanedOptional(modelID) ?? record?.modelID

        if let appendTarget, !appendTarget.isEmpty {
            if let record {
                return try reconcileReviewChat(
                    sessionID: appendTarget,
                    with: record,
                    sourceIDs: requestedSourceIDs.map(sanitizedSourceIDs) ?? [],
                    summary: summary,
                    overallScore: overallScore,
                    modelProvider: resolvedProvider,
                    modelID: resolvedModelID,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    marksReviewed: requestedMarksReviewed,
                    store: store
                )
            }
            return try appendReviewChatChunk(
                to: appendTarget,
                turns: turns,
                sourceIDs: requestedSourceIDs.map(sanitizedSourceIDs) ?? [],
                summary: summary,
                overallScore: overallScore,
                modelProvider: modelProvider,
                modelID: modelID,
                startedAt: startedAt,
                endedAt: endedAt,
                marksReviewed: requestedMarksReviewed,
                store: store
            )
        }
        let marksReviewed = requestedMarksReviewed ?? true

        // Only the ids given: what the app has selected is never a default.
        let resolvedSourceIDs = sanitizedSourceIDs(requestedSourceIDs ?? [])

        let explicitNotebook: LearningGoalRecord?
        if let rawNotebookID = notebookID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawNotebookID.isEmpty {
            explicitNotebook = try resolveMCPChatHome(notebookID: rawNotebookID, store: store)
        } else {
            explicitNotebook = nil
        }

        // The hours the conversation ran: the caller's when it declares them,
        // else the record's own stamps — a session file saw every turn happen.
        let ranFrom = startedAt ?? record?.startedAt
        let ranTo = endedAt ?? record?.endedAt
        let session = try store.importReviewChatSession(
            id: UUID().uuidString,
            title: trimmedTitle,
            turns: turns,
            sourceIDs: resolvedSourceIDs,
            goalID: explicitNotebook?.id,
            summary: summary,
            overallScore: overallScore,
            modelProvider: resolvedProvider,
            modelID: resolvedModelID,
            createdAt: ranFrom ?? Date(),
            endedAt: ranTo,
            // The choice is the chat's, not this call's: every later call with
            // session_id reads it back (`appendMarksReviewed`).
            kind: marksReviewed ? nil : .chat,
            // Under generation 2 the chat records the choice itself, and its kind is the
            // classifier's on what this call knows: a review when scored, else a chat.
            chatKind: ChatKindClassifier.kind(of: ChatKindClassifier.Evidence(
                id: "", kind: marksReviewed ? nil : ReviewSessionKind.chat.rawValue, hasOverallScore: overallScore != nil
            )),
            marksReviewed: marksReviewed
        )
        // An imported review is a completed review, so reflect it on the
        // Schedule: mark any scheduled placements for these sources done instead
        // of leaving them pending with a "Chat started" label. A chat that only
        // researched or discussed its sources (`marksReviewed` false) did not
        // review the learner on them, and leaves the Schedule as it was.
        if marksReviewed {
            try markScheduledSourcesReviewed(resolvedSourceIDs)
        }

        let scoreText = overallScore.map { " Score: \(String(format: "%.0f%%", $0 * 100))." } ?? ""
        let sourcePlural = resolvedSourceIDs.count == 1 ? "" : "s"
        let sourceText: String
        if resolvedSourceIDs.isEmpty {
            sourceText = marksReviewed
                ? " No sources were linked; pass source_ids to mark sources reviewed."
                : " No sources were linked."
        } else if marksReviewed {
            sourceText = " Linked to \(resolvedSourceIDs.count) source\(sourcePlural), now counted as reviewed and marked done on the Schedule."
        } else {
            sourceText = " Linked to \(resolvedSourceIDs.count) source\(sourcePlural), without marking them reviewed."
        }
        let clockText = recordChatOnDayLog(sessionID: session.id, title: session.title, record: record, from: ranFrom, to: ranTo, store: store)
        let notebookText = explicitNotebook.map {
            " Filed under \(Self.companionName($0))."
        } ?? ""
        let originText = record.map { " from \(Self.describe($0))" } ?? ""
        let continueText = record == nil
            ? "A chat too long for one call continues here: pass session_id \(session.id) with each further chunk and its turns are appended."
            : "After each later answer, call again with session_id \(session.id) and the same transcript_file: the stored chat is brought level with the record."
        let savedAs = marksReviewed ? "a completed review session" : "a saved chat"
        // The new chat's id rides on its own line, never beside its title
        // (Prompts.hiddenIDs); the caller keeps it for session_id.
        return "Imported chat '\(session.title)'\(originText) as \(savedAs) with \(turns.count) exchange\(turns.count == 1 ? "" : "s").\(scoreText)\(sourceText)\(notebookText)\(clockText) It now appears in the app's review sessions and its transcript is searchable. \(continueText)\nsession_id: \(session.id)"
    }

    private static func describe(_ record: AssistantTranscriptFile) -> String {
        switch record.kind {
        case .claudeCodeSession: return "its Claude Code session file"
        case .roleLabelledText: return "its transcript file"
        }
    }

    /// `transcript_file` names the assistant's own record of the chat: a
    /// Claude Code session id, which is looked up under the notebooks
    /// directory, or a path, vetted like every other client-provided path
    /// with that directory added to the roots a client may read from.
    func resolveTranscriptFile(_ argument: String) throws -> URL {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        let notebooksRoot = claudeCodeProjectsRoot
        if AssistantTranscriptFile.isSessionID(trimmed) {
            guard let url = AssistantTranscriptFile.claudeCodeSessionFile(id: trimmed, notebooksRoot: notebooksRoot) else {
                throw MCPError.invalidInput(
                    "No Claude Code session \(trimmed) is recorded under \(notebooksRoot.path) on this Mac. Pass the session file's path, or transcript with the turns themselves."
                )
            }
            return try validateClientProvidedPath(url.path, additionalRoots: [notebooksRoot.path])
        }
        let url = try validateClientProvidedPath(trimmed, additionalRoots: [notebooksRoot.path])
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MCPError.invalidInput("File not found: \(trimmed)")
        }
        return url
    }

    /// Puts an imported chat on the day's log at the hours it ran: a chat
    /// had in ChatGPT at two in the afternoon and imported at ten at night
    /// belongs on the clock at two, not at ten. Without a time nothing is
    /// drawn, because the app did not see this hour and must not invent one
    /// (docs/tethered-workday-design.md); a session file's stamps count as
    /// seen.
    ///
    /// A record that stamps its messages is drawn from those stamps, each one
    /// an observation the way a turn of an in-app chat is, so an hour the
    /// learner spent away between two messages is not drawn: on 2026-09-28 a
    /// chat drawn from its first turn to its last covered 14:26–19:04, an
    /// afternoon spent elsewhere. Without stamps, a declared `started_at` and
    /// `ended_at` are drawn as one span. Returns the sentence to append to the
    /// tool's answer.
    private func recordChatOnDayLog(
        sessionID: String,
        title: String,
        record: AssistantTranscriptFile?,
        from: Date?,
        to: Date?,
        store: KnowledgeStore
    ) -> String {
        do {
            let stamps = record?.messages.compactMap(\.timestamp) ?? []
            let spans: [DayActivity]
            if !stamps.isEmpty {
                spans = try store.recordDayActivityObservations(kind: .chat, targetID: sessionID, title: title, at: stamps)
            } else if let from, let to, to > from,
                      let span = try store.recordDayActivitySpan(kind: .chat, targetID: sessionID, title: title, from: from, to: to) {
                spans = [span]
            } else {
                return ""
            }
            return Self.dayLogSentence(for: spans)
        } catch {
            // The chat is imported either way; only its place on the clock
            // is lost, and saying so is better than failing the import.
            return " It could not be put on the day's log: \(error.localizedDescription)"
        }
    }

    /// " It is on the day's log for 2026-09-28 (14:26–14:31, 19:00–19:05)
    /// at the hours it ran." — every sitting named, so an assistant can see a
    /// gap was left undrawn rather than guess.
    static func dayLogSentence(for spans: [DayActivity]) -> String {
        guard !spans.isEmpty else { return "" }
        let byDay = Dictionary(grouping: spans, by: \.dayPlanID)
        let days = byDay.keys.sorted().map { day -> String in
            let clocks = (byDay[day] ?? [])
                .sorted { $0.startMinute < $1.startMinute }
                .map { "\(DayPlan.clockString(minute: $0.startMinute))–\(DayPlan.clockString(minute: $0.endMinute))" }
                .joined(separator: ", ")
            return "\(day) (\(clocks))"
        }
        return " It is on the day's log for \(days.joined(separator: " and ")) at the hours it ran."
    }

    /// Whether a call with session_id counts the sources it adds as reviewed.
    /// The call's own `mark_reviewed` decides when it is given; otherwise the
    /// chat's first import already did. A chat first saved with
    /// `mark_reviewed` false is stored as an ordinary chat (`kind` chat) and
    /// never marks a source reviewed later: on 2026-09-28 a chat saved that way
    /// marked the seven sources a later call linked reviewed, placed them on
    /// the Schedule done and stamped them read. An explicit false on a
    /// chat stored before imports wrote the kind stamps it, so the calls after
    /// it remember; a chat with no kind otherwise reads as the review its first
    /// import defaulted to.
    private func appendMarksReviewed(requested: Bool?, sessionID: String, store: KnowledgeStore) throws -> Bool {
        // Generation 2 reads the chat's own `marks_reviewed`, never its kind (§3.5.13).
        return try store.generation2AppendMarksReviewed(requested: requested, sessionID: sessionID)
    }

    private static func addedSourcesSentence(count: Int, markedReviewed: Bool) -> String {
        guard count > 0 else { return "" }
        let linked = "\(count) more source\(count == 1 ? "" : "s") linked"
        return markedReviewed
            ? " \(linked), now counted as reviewed and marked done on the Schedule."
            : " \(linked), without marking \(count == 1 ? "it" : "them") reviewed."
    }

    /// The record half of `import_review_chat` with `session_id`: the chat's
    /// client record is read whole and the stored exchanges are made equal
    /// to it, so a turn saved before its answer was written is replaced by
    /// the answer, and a turn the record has gained is appended.
    private func reconcileReviewChat(
        sessionID: String,
        with record: AssistantTranscriptFile,
        sourceIDs additionalSourceIDs: [String],
        summary: String?,
        overallScore: Double?,
        modelProvider: String?,
        modelID: String?,
        startedAt: Date?,
        endedAt: Date?,
        marksReviewed requestedMarksReviewed: Bool?,
        store: KnowledgeStore
    ) throws -> String {
        guard let existing = try store.loadReviewSessionForSync(sessionID) else {
            throw MCPError.invalidInput(
                "No review session with id \(sessionID). Import the first chunk of a chat without session_id, then pass the id that call returns with each further chunk."
            )
        }
        let marksReviewed = try appendMarksReviewed(requested: requestedMarksReviewed, sessionID: sessionID, store: store)
        let newSourceIDs = additionalSourceIDs.filter { !existing.sourceIDs.contains($0) }
        let outcome = try store.reconcileReviewChatExchanges(
            sessionID: sessionID,
            turns: record.turns,
            sourceIDs: additionalSourceIDs,
            summary: summary,
            overallScore: overallScore,
            modelProvider: modelProvider,
            modelID: modelID,
            endedAt: endedAt ?? record.endedAt
        )
        if marksReviewed {
            try markScheduledSourcesReviewed(newSourceIDs)
        }
        let clockText = recordChatOnDayLog(
            sessionID: sessionID,
            title: outcome.record.title,
            record: record,
            from: startedAt ?? record.startedAt,
            to: endedAt ?? record.endedAt,
            store: store
        )

        let count = outcome.record.exchangeCount
        let holds = "it holds \(count) exchange\(count == 1 ? "" : "s")"
        let changeText: String
        if outcome.appended == 0, outcome.replaced == 0 {
            changeText = "'\(outcome.record.title)' already matches \(Self.describe(record)); nothing was added and \(holds)."
        } else {
            var parts: [String] = []
            if outcome.appended > 0 { parts.append("\(outcome.appended) exchange\(outcome.appended == 1 ? "" : "s") appended") }
            if outcome.replaced > 0 { parts.append("\(outcome.replaced) stored exchange\(outcome.replaced == 1 ? "" : "s") rewritten from the record") }
            changeText = "'\(outcome.record.title)' now matches \(Self.describe(record)): \(parts.joined(separator: ", ")); \(holds)."
        }
        let scoreText = overallScore.map { " Score: \(String(format: "%.0f%%", $0 * 100))." } ?? ""
        let sourceText = Self.addedSourcesSentence(count: newSourceIDs.count, markedReviewed: marksReviewed)
        return "\(changeText)\(scoreText)\(sourceText)\(clockText) Call again with the same session_id and transcript_file after the next answer."
    }

    /// The append half of `import_review_chat`: a further chunk of a chat whose
    /// first chunk already made the session. A chunk whose turns are exactly
    /// the stored tail is a retried call, not a repeat of the conversation, so
    /// it is acknowledged and stored once. A chunk that declares the hours it
    /// ran is drawn on the day's log as a span of its own, or joined to the
    /// chat's span it continues.
    private func appendReviewChatChunk(
        to sessionID: String,
        turns: [ReviewChatTurn],
        sourceIDs additionalSourceIDs: [String],
        summary: String?,
        overallScore: Double?,
        modelProvider: String?,
        modelID: String?,
        startedAt: Date?,
        endedAt: Date?,
        marksReviewed requestedMarksReviewed: Bool?,
        store: KnowledgeStore
    ) throws -> String {
        guard let existing = try store.loadReviewSessionForSync(sessionID) else {
            throw MCPError.invalidInput(
                "No review session with id \(sessionID). Import the first chunk of a chat without session_id, then pass the id that call returns with each further chunk."
            )
        }
        let marksReviewed = try appendMarksReviewed(requested: requestedMarksReviewed, sessionID: sessionID, store: store)
        let chunk = turns.filter {
            cleanedOptional($0.question) != nil
                || cleanedOptional($0.answer) != nil
                || cleanedOptional($0.evaluation) != nil
        }
        guard !chunk.isEmpty else { throw MCPError.invalidInput("transcript had no readable messages.") }

        let tail = existing.exchanges.sorted { $0.sequenceNumber < $1.sequenceNumber }.suffix(chunk.count)
        let alreadyStored = tail.count == chunk.count && zip(tail, chunk).allSatisfy { exchange, turn in
            exchange.question == (cleanedOptional(turn.question) ?? "")
                && exchange.userAnswer == cleanedOptional(turn.answer)
                && exchange.evaluation == cleanedOptional(turn.evaluation)
        }
        if alreadyStored {
            return "Those \(chunk.count) exchange\(chunk.count == 1 ? "" : "s") are already the end of '\(existing.topic)'; nothing was added. The session holds \(existing.exchangeCount) exchange\(existing.exchangeCount == 1 ? "" : "s")."
        }

        let newSourceIDs = additionalSourceIDs.filter { !existing.sourceIDs.contains($0) }
        let record = try store.appendReviewChatExchanges(
            sessionID: sessionID,
            turns: chunk,
            sourceIDs: additionalSourceIDs,
            summary: summary,
            overallScore: overallScore,
            modelProvider: modelProvider,
            modelID: modelID
        )
        if marksReviewed {
            try markScheduledSourcesReviewed(newSourceIDs)
        }
        let clockText = recordChatOnDayLog(
            sessionID: sessionID,
            title: record.title,
            record: nil,
            from: startedAt,
            to: endedAt,
            store: store
        )

        let scoreText = overallScore.map { " Score: \(String(format: "%.0f%%", $0 * 100))." } ?? ""
        let sourceText = Self.addedSourcesSentence(count: newSourceIDs.count, markedReviewed: marksReviewed)
        return "Appended \(chunk.count) exchange\(chunk.count == 1 ? "" : "s") to '\(record.title)'; it now holds \(record.exchangeCount).\(scoreText)\(sourceText)\(clockText) Pass the same session_id with the next chunk, or stop here: the session is complete as stored."
    }

    /// Parse a role-labeled chat transcript into question/answer exchanges.
    /// Assistant messages form the question side, user messages the answer side;
    /// consecutive same-role messages merge. If no role markers are found the
    /// whole transcript is kept as a single exchange rather than dropped.
    func parseReviewTranscript(_ transcript: String) -> [ReviewChatTurn] {
        ReviewTranscriptParser.turns(from: transcript)
    }

    func searchReviewSessions(queryText: String, limit: Int) throws -> String {
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Provide a non-empty query." }
        let cappedLimit = max(1, min(limit, 50))
        // Screen record mode (admin only): hidden chats are dropped after the
        // query, so the SQL limit is lifted while the scope is on and the
        // requested one applied to what is left. Nil scope: unchanged.
        let screenScope = screenRecordScope()
        let screenRecordHidden = try screenRecordHiddenReviewSessionIDs(scope: screenScope)
        return try withDB { db in
            let like = "%\(trimmed)%"
            let queried = try query(db, """
                SELECT fs.id, fs.topic, fs.status, fs.overall_score, fs.started_at
                FROM review_sessions fs
                WHERE fs.id IN (
                    SELECT fs2.id FROM review_sessions fs2
                    LEFT JOIN review_exchanges fe ON fe.session_id = fs2.id
                    WHERE fs2.topic LIKE ? OR fs2.summary LIKE ?
                       OR fe.question LIKE ? OR fe.user_answer LIKE ? OR fe.evaluation LIKE ?
                )
                ORDER BY fs.started_at DESC
                LIMIT ?
            """, params: [like, like, like, like, like, screenScope == nil ? cappedLimit : -1])
            let rows = screenScope == nil ? queried : Array(queried.filter { row in
                guard let id = row["id"] as? String else { return false }
                return !screenRecordHidden.contains(id)
            }.prefix(cappedLimit))

            guard !rows.isEmpty else {
                return "No review sessions match \"\(trimmed)\"."
            }

            var lines = ["Review sessions matching \"\(trimmed)\" (\(rows.count)):"]
            for r in rows {
                let id = r["id"] as? String ?? ""
                let topic = r["topic"] as? String ?? "Untitled"
                let status = r["status"] as? String ?? ""
                let date = (r["started_at"] as? Double).map { appleToISO($0) } ?? ""
                let scoreText = (r["overall_score"] as? Double).map { " \(String(format: "%.0f%%", $0 * 100))" } ?? ""
                lines.append("- \(topic) (id: \(id)) [\(status)]\(scoreText) — \(date)")
                let snippet = try reviewMatchSnippet(db, sessionID: id, like: like, term: trimmed)
                if !snippet.isEmpty {
                    lines.append("  …\(snippet)…")
                }
            }
            lines.append("\nUse get_review_session_transcript with a session id to read a full match.")
            return lines.joined(separator: "\n")
        }
    }

    private func reviewMatchSnippet(_ db: OpaquePointer, sessionID: String, like: String, term: String) throws -> String {
        let rows = try query(db, """
            SELECT question, user_answer, evaluation
            FROM review_exchanges
            WHERE session_id = ?
              AND (question LIKE ? OR user_answer LIKE ? OR evaluation LIKE ?)
            ORDER BY sequence_number ASC
            LIMIT 1
        """, params: [sessionID, like, like, like])
        guard let row = rows.first else { return "" }
        let candidates = [row["question"] as? String, row["user_answer"] as? String, row["evaluation"] as? String].compactMap { $0 }
        let lowerTerm = term.lowercased()
        for text in candidates {
            guard let range = text.lowercased().range(of: lowerTerm) else { continue }
            let matchOffset = text.distance(from: text.startIndex, to: range.lowerBound)
            let startOffset = max(0, matchOffset - 60)
            let startIndex = text.index(text.startIndex, offsetBy: startOffset)
            let snippet = String(text[startIndex...].prefix(160))
            return snippet.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    func listReviewSessionLinks() throws -> String {
        // Screen record mode (admin only): the chats the take may show. Empty
        // hidden set, and so every link, when the mode is off.
        let screenRecordHidden = try screenRecordHiddenReviewSessionIDs(scope: screenRecordScope())
        let links = try knowledgeStore().loadReviewSessionLinks()
            .filter { !screenRecordHidden.contains($0.id) }
        guard !links.isEmpty else {
            return "No saved review session links."
        }
        var lines = ["Review session links (\(links.count)):"]
        for link in links {
            let fmt = KnowledgeStore.iso8601Formatter
            let urlText = link.url.map { "\n  \($0)" } ?? ""
            let sourceText = link.sourceIDs.isEmpty ? "" : ", sources: \(link.sourceIDs.joined(separator: ", "))"
            lines.append("- [\(link.provider.rawValue)] \(link.title) (id: \(link.id), saved: \(fmt.string(from: link.createdAt))\(sourceText))\(urlText)")
        }
        return lines.joined(separator: "\n")
    }
}
