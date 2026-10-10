import Foundation

extension MCPDataStore {

    /// Today's cohort review.
    ///
    /// Deliberately returns the cohort and its briefs rather than a plan: the
    /// assistant calling this tool *is* the planner, and it has the whole
    /// conversation as context. The in-app path uses `AIService.planCohortSession`
    /// for the same step because it has no assistant in the loop. When that
    /// path has already planned today's review by topic (docs/memory-design.md,
    /// "Review by topic"), the topics ride along under `topics`, so the
    /// assistant conducts the session the app would rather than a second
    /// plan over the same material.
    func cohortReview(
        startSession: Bool,
        goalID: String?,
        hostSessionID: String? = nil
    ) async throws -> String {
        let now = Date()
        let trimmedGoalID = goalID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let linkedGoalID = trimmedGoalID?.isEmpty == false ? trimmedGoalID : nil

        var restrict: Set<String>?
        var goalInfo: [String: Any]?
        if let linkedGoalID {
            let goal = try requireCompanionGoal(linkedGoalID)
            restrict = Set(goal.items.filter { $0.isApproved }.map(\.sourceID))
            goalInfo = ["id": goal.id, "title": goal.title, "topic": goal.topic ?? goal.title]
        }

        let cohort = try await notebookFileStorage.assembleLearningCohort(
            now: now,
            restrictToSourceIDs: restrict
        )
        guard !cohort.isEmpty else {
            return try jsonString([
                "cohort": [] as [Any],
                "instructions": "Nothing is due and nothing new has been taken in. Say so plainly and do not invent material to review.",
            ])
        }

        let briefs = try await notebookFileStorage.cohortBriefs(for: cohort)
        let recentSummaries = try await notebookFileStorage.recentReviewSummaries(limit: 3)

        var payload: [String: Any] = [
            "window_days": cohort.windowDays,
            "assembled_at": ISO8601DateFormatter().string(from: cohort.assembledAt),
            "cohort": briefs.map(Self.cohortSourcePayload),
            "recent_sessions": recentSummaries,
        ]
        if let goalInfo { payload["goal"] = goalInfo }
        if !cohort.unfinished.isEmpty {
            payload["unfinished_source_ids"] = cohort.unfinished
        }
        // The day's prepared review, when the app planned one by topic.
        let preparedBriefing = try knowledgeStore()
            .loadReviewSessionForSync(MemoryReviewSession.sessionID(for: now))?.briefing
        let topics = Self.cohortTopicsPayload(
            briefing: preparedBriefing,
            cohortSourceIDs: Set(cohort.sources.map(\.sourceID))
        )
        if !topics.isEmpty { payload["topics"] = topics }
        // Surfaced rather than swallowed: a silent truncation reads to the
        // learner as "we covered everything" when it did not.
        if cohort.droppedSpine > 0 || cohort.droppedSpacing > 0 {
            payload["not_included_today"] = [
                "new_sources": cohort.droppedSpine,
                "due_sources": cohort.droppedSpacing,
            ]
        }

        if startSession {
            let sessionID = UUID().uuidString
            let store = try knowledgeStore()
            try store.createReviewSession(
                id: sessionID,
                topic: Self.cohortSessionTopic(cohort: cohort, now: now),
                sourceIDs: cohort.sources.map(\.sourceID),
                goalID: linkedGoalID,
                chatKind: .review
            )
            payload["session_id"] = sessionID
            payload["instructions"] = topics.isEmpty
                ? Self.cohortConductInstructions
                : Self.cohortConductInstructions + "\n\n" + Self.cohortTopicInstructions
        } else {
            payload["instructions"] = "Briefing only — do NOT start the review. Describe what today would cover and why, without asking anything. No session was started."
        }
        return try jsonString(payload)
    }

    /// Record what the learner now understands, after a cohort review.
    ///
    /// Identity is checked here, not trusted from the model: a source the session
    /// never covered cannot have its understanding rewritten, however confidently
    /// the caller asserts it.
    func recordUnderstanding(
        sessionID: String,
        sessionSummary: String,
        updates: [[String: Any]]
    ) async throws -> String {
        let trimmedSession = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSession.isEmpty else {
            throw MCPError.invalidInput("session_id is required.")
        }
        let store = try knowledgeStore()
        guard let session = try store.loadReviewSessionForSync(trimmedSession) else {
            throw MCPError.invalidInput("Unknown session_id \(trimmedSession).")
        }
        let allowed = Set(session.sourceIDs)
        guard !updates.isEmpty else {
            throw MCPError.invalidInput("updates must contain at least one source.")
        }

        var written: [String] = []
        var rejected: [String] = []
        for update in updates {
            guard let sourceID = (update["source_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !sourceID.isEmpty else {
                throw MCPError.invalidInput("Every update needs a source_id.")
            }
            guard allowed.contains(sourceID) else {
                rejected.append(sourceID)
                continue
            }
            guard let markdown = update["understanding_markdown"] as? String,
                  !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPError.invalidInput("Update for \(sourceID) has no understanding_markdown.")
            }
            let title = try store.loadSourcesWithoutContent()
                .first { $0.id == sourceID }?.title ?? sourceID
            _ = try store.saveUnderstandingDocument(
                sourceID: sourceID,
                title: title,
                markdown: markdown,
                derivedThroughSessionID: trimmedSession,
                openThreadCount: update["open_thread_count"] as? Int ?? 0
            )
            written.append(sourceID)
        }

        if !rejected.isEmpty {
            throw MCPError.invalidInput(
                "These sources were not part of session \(trimmedSession) and were not written: "
                + rejected.sorted().joined(separator: ", ")
                + ". Only rewrite understanding for sources the session actually covered."
            )
        }

        try store.completeReviewSession(
            sessionID: trimmedSession,
            overallScore: nil,
            summary: sessionSummary
        )

        return try jsonString([
            "session_id": trimmedSession,
            "understanding_written_for": written.sorted(),
            "status": "completed",
        ])
    }

    // MARK: - Payload

    /// Today's prepared topics as the tool returns them, trimmed to the cohort
    /// this call assembled: a goal-scoped call drops the ideas of sources
    /// outside its pool, and a topic left with none goes. Empty when no
    /// review was prepared today or it was planned source by source.
    static func cohortTopicsPayload(briefing: String?, cohortSourceIDs: Set<String>) -> [[String: Any]] {
        MemoryReviewTutoring.topics(inBriefing: briefing).compactMap { topic -> [String: Any]? in
            let ideaIDs = topic.ideaIDs.filter { id in
                guard let sourceID = SourceIdea.sourceID(fromIdeaID: id) else { return false }
                return cohortSourceIDs.contains(sourceID)
            }
            guard !ideaIDs.isEmpty else { return nil }
            let trimmed = MemoryReviewTopic(id: topic.id, title: topic.title, kind: topic.kind, ideaIDs: ideaIDs, intent: topic.intent)
            var entry: [String: Any] = [
                "topic_id": trimmed.id,
                "title": trimmed.title,
                "kind": trimmed.kind.rawValue,
                "idea_ids": trimmed.ideaIDs,
                "source_ids": trimmed.sourceIDs,
            ]
            if !trimmed.intent.isEmpty { entry["intent"] = trimmed.intent }
            return entry
        }
    }

    static func cohortSourcePayload(_ brief: CohortSourceBrief) -> [String: Any] {
        let source = brief.source
        var entry: [String: Any] = [
            "source_id": source.sourceID,
            "title": source.title,
            "type": source.sourceType,
            "role": source.role.rawValue,
            "why": source.reason,
        ]
        if let bridgeTo = source.bridgeTo { entry["bridge_to"] = bridgeTo }
        if source.confidence == .partial { entry["partial_read"] = true }
        if let guide = brief.guide, !guide.isEmpty {
            entry["guide"] = String(guide.prefix(CohortSourceBrief.maxGuideCharacters))
        }
        if !brief.highlights.isEmpty {
            entry["their_highlights"] = Array(brief.highlights.prefix(CohortSourceBrief.maxHighlights))
        }
        if let understanding = brief.understanding, !understanding.isEmpty {
            entry["their_understanding"] = String(
                understanding.prefix(CohortSourceBrief.maxUnderstandingCharacters)
            )
            entry["understanding_has_learner_edits"] = brief.understandingHasLearnerEdits
        }
        if !brief.exemplarQuestions.isEmpty {
            entry["questions_that_worked_before"] = brief.exemplarQuestions
        }
        if !brief.ideas.isEmpty {
            entry["ideas"] = brief.ideas.map { idea -> [String: Any] in
                var item: [String: Any] = ["idea_id": idea.id, "statement": idea.statement]
                if !idea.recallNote.isEmpty { item["recall_note"] = idea.recallNote }
                if idea.wanted { item["highlighted"] = true }
                return item
            }
            entry["review_depth"] = brief.depth.rawValue
        }
        return entry
    }

    /// "Keep podcasts quick": how much of a memory review a source, or a kind
    /// of source, gets by default. Never a form; said in conversation.
    func setReviewDepth(sourceID: String?, sourceType: String?, depth rawDepth: String) throws -> String {
        let trimmedDepth = rawDepth.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let depth = MemoryReviewDepth(rawValue: trimmedDepth) else {
            throw MCPError.invalidInput("depth must be one of quick, standard, deep.")
        }
        let trimmedSource = sourceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedType = sourceType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let trimmedSource, !trimmedSource.isEmpty {
            let store = try knowledgeStore()
            try store.setSourceReviewDepth(sourceID: trimmedSource, depth: depth)
            return try jsonString(["source_id": trimmedSource, "review_depth": depth.rawValue])
        }
        if let trimmedType, !trimmedType.isEmpty {
            MemoryReviewDepth.setTypeDefault(depth, sourceType: trimmedType)
            return try jsonString(["source_type": trimmedType, "review_depth": depth.rawValue])
        }
        throw MCPError.invalidInput("Pass source_id for one source or source_type for a kind of source.")
    }

    static func cohortSessionTopic(cohort: LearningCohort, now: Date) -> String {
        let spine = cohort.sources(in: .spine)
        if let first = spine.first {
            return spine.count > 1
                ? "\(first.title) and \(spine.count - 1) more"
                : first.title
        }
        return "Memory review"
    }

    /// Added to the conduct instructions when `topics` is present: the plan
    /// is made, so the moves are the topics.
    static let cohortTopicInstructions = """
    ForeverLM has already planned today's review by topic: `topics` lists them in order, each with \
    the ideas it cues (`idea_ids`, listed under `ideas` on the sources in `source_ids`). Those are \
    your moves. Ask each topic as one opening question answerable from any of its sources, credit \
    every cued idea that comes back whichever source it belongs to, then go after what did not \
    come back one idea at a time before moving on. Never read out an idea the learner has not \
    produced. Once everything a topic cues has come back, going deeper on it means the \
    understanding probes above, not more recall.
    """

    static let cohortConductInstructions = """
    Conduct one review conversation over this cohort. You are the planner: decide 5–8 \
    moves before you start, then work them in order.

    `role` tells you what each source is for. `spine` is what the session is about — \
    recently taken in, not yet reviewed. `spacing` is due again. A `bridge` exists only \
    so you can put it in friction with the spine source named in `bridge_to`; do not \
    review a bridge on its own.

    At least one question must span two sources from different times. That is the point \
    of this session — a run of single-source recall questions is a failure, and the \
    learner can get that from a flashcard app.

    Ask one question at a time, and compose fresh wording every time: this review has \
    no stored questions to recite (the learner's kept cards are asked as worded, \
    through get_due_cards or memory_review, never here). Require production from memory before \
    offering any hint. Keep each prompt focused, precise, tractable, and genuinely \
    effortful. On conceptual material \
    do not ask what the source says — ask them to classify a case as fitting or not, to \
    locate where two accounts disagree, to say why it matters, or to apply it to \
    something that was not in the source.

    `their_understanding` is what they have previously made of the source, including \
    anything they got wrong. When `understanding_has_learner_edits` is true they have \
    corrected that document by hand: trust their correction over your earlier note. \
    Never read this material out before they attempt an answer.

    A `their_highlights` entry marked THEIR OWN NOTE is the learner's own elaboration: \
    build on what they wrote rather than restating the passage. A bridge flagged as a \
    partial read is one they never finished — say so, and ask only about the part they \
    reached.

    When an idea has come back in full and the learner asks to go deeper, push past \
    recall into understanding with ONE understanding probe at a time, rotating the four \
    kinds so no idea meets the same one twice: \(MemoryUnderstandingProbe.kindsLine). For \
    the analogy, set the idea beside one from a source the learner keeps in another \
    notebook (search_sources_semantic finds sources near it, list_notebook_sources says \
    which notebook holds one), name that idea in the question, and skip the analogy when \
    there is none. \
    Never probe an idea that has not come back. After their answer, say in two or three \
    sentences what it got and what it missed or could add, with no score and no \
    flattery. A probe is never a gate: moving on is always one word away.

    Do not end because a question count was reached. Continue until the learner says \
    they are done. Before you close, ask them once what they want brought back next \
    time, in their own words, and record it as theirs — deciding what is worth \
    returning to is work only they can do. Only then call record_understanding with the session_id, a \
    session_summary of at most three lines, and a rewritten understanding_markdown for \
    every source you actually discussed — the complete replacement document, compacted, \
    not a patch and not an append.
    """
}
