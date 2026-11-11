// Part of ReviewSessionManager: memory review sessions, grading tools and resume state.

import Foundation

extension ReviewSessionManager {
    struct MemoryReviewExtraction {
        /// The cohort with every source that has ideas, and no bridge whose
        /// anchor dropped out.
        let cohort: LearningCohort
        /// "Title — reason" for each source that could not be prepared.
        let skipped: [String]
    }

    /// Extracts ideas for every cohort source at once. A source that fails is
    /// dropped from today's review and named in the briefing rather than
    /// reviewed against nothing; only a total failure stops the start.
    func extractIdeas(for cohort: LearningCohort) async -> MemoryReviewExtraction {
        let extraction = ideaExtraction
        var ready = Set<String>()
        var failures: [String: String] = [:]
        await withTaskGroup(of: (String, Result<[SourceIdea], Error>).self) { group in
            for source in cohort.sources {
                group.addTask {
                    // Bind the awaited value before building the tuple. A tuple
                    // built around a `try await` inside a task closure is
                    // miscompiled at -O by Swift 6.3.3 (Xcode 27 beta): the first
                    // element came back empty, so every result landed under the
                    // wrong source, the loop saw no source as prepared, and the
                    // group was torn down while the wrong-keyed children were still
                    // completing — the Memory button crash in build 45. See the
                    // concurrency rule in AGENTS.md.
                    let outcome: Result<[SourceIdea], Error>
                    do {
                        let ideas = try await extraction.prepare(sourceID: source.sourceID)
                        outcome = .success(ideas)
                    } catch {
                        outcome = .failure(error)
                    }
                    return (source.sourceID, outcome)
                }
            }
            for await (sourceID, result) in group {
                switch result {
                case .success(let ideas) where !ideas.isEmpty:
                    ready.insert(sourceID)
                case .success:
                    failures[sourceID] = "no ideas could be extracted."
                case .failure(let error):
                    failures[sourceID] = error.localizedDescription
                }
            }
        }
        let kept = cohort.sources.filter { source in
            guard ready.contains(source.sourceID) else { return false }
            // A bridge whose anchor dropped out has nothing to be put in friction with.
            if let anchor = source.bridgeTo { return ready.contains(anchor) }
            return true
        }
        let skipped = cohort.sources
            .filter { !ready.contains($0.sourceID) }
            .map { "\($0.title) — \(failures[$0.sourceID] ?? "not prepared")" }
        if !skipped.isEmpty {
            logger.notice("Memory review skipped \(skipped.count) source(s) without ideas: \(skipped.joined(separator: "; "), privacy: .public)")
        }
        return MemoryReviewExtraction(
            cohort: LearningCohort(
                assembledAt: cohort.assembledAt,
                windowDays: cohort.windowDays,
                sources: kept,
                unfinished: cohort.unfinished,
                droppedSpine: cohort.droppedSpine,
                droppedSpacing: cohort.droppedSpacing,
                isBacklogOnly: cohort.isBacklogOnly
            ),
            skipped: skipped
        )
    }

    /// The learner steered after a graded contour. Records the steer on that
    /// exchange and, on the third consecutive Next over one kind of source,
    /// makes that kind quick by default. A Go deeper on a topic, or a source,
    /// whose ideas all came back is an understanding probe
    /// (`understandingProbeNote`). Returns the note the tutor needs beside
    /// the learner's words, or nil when nothing changed.
    func steerMemoryReview(_ steer: MemoryReviewSteer) async -> String? {
        guard let sessionID, isMemoryReviewSession else { return nil }
        let coverage: [MemoryIdeaCoverage]?
        do {
            coverage = try await storage.recordMemoryReviewSteer(sessionID: sessionID, steer: steer)
        } catch {
            logger.error("Failed to record memory review steer: \(error.localizedDescription)")
            return nil
        }
        if steer == .deeper { return await understandingProbeNote() }
        guard steer == .next,
              let first = coverage?.first,
              let sourceID = SourceIdea.sourceID(fromIdeaID: first.ideaID) else { return nil }
        let typeOf: (String) -> String? = { [activeArticles] id in
            activeArticles.first { $0.id == id }?.sourceType.rawValue
        }
        guard let sourceType = typeOf(sourceID),
              MemoryReviewDepth.typeDefault(sourceType: sourceType) != .quick else { return nil }
        let steers: [(sourceID: String, steer: MemoryReviewSteer)]
        do {
            steers = try await storage.memoryReviewSteers(sessionID: sessionID)
        } catch {
            logger.error("Reading the memory review steers failed: \(error.localizedDescription, privacy: .public)")
            steers = []
        }
        let recent = Array(steers.suffix(3))
        guard recent.count == 3,
              recent.allSatisfy({ $0.steer == .next && typeOf($0.sourceID) == sourceType }) else { return nil }
        MemoryReviewDepth.setTypeDefault(.quick, sourceType: sourceType)
        for id in memoryReviewDepthBySource.keys where typeOf(id) == sourceType {
            memoryReviewDepthBySource[id] = .quick
        }
        return "[ForeverLM] The learner chose Next three times in a row on \(sourceType) sources, so \(sourceType) sources are now kept quick by default: the contour only. Say so once, in half a sentence, and that a word undoes it."
    }

    /// What the tutor is told beside a Go deeper on a topic, or a source,
    /// whose ideas all came back: the understanding probe after the last one
    /// asked today, on the idea probed least (wanted first), and for an
    /// analogy the nearest source in another notebook with one of its ideas
    /// (`StorageService.understandingAnalogyPartner`), searched off the main
    /// actor; when there is none the rotation skips the analogy. Nil while
    /// anything there is missing or partial, which leaves Go deeper chasing
    /// it, as the conduct says.
    private func understandingProbeNote() async -> String? {
        guard let current = memoryReviewCurrentSourceID else { return nil }
        let topic = memoryReviewTopics.first { $0.id == current }
        let ideaIDs = (topic?.ideaIDs ?? memoryReviewIdeaIDs(forSource: current)).filter { memoryReviewIdea($0) != nil }
        let states = memoryReviewIdeaStates
        guard MemoryUnderstandingProbe.isRecalled(ideaIDs: ideaIDs, states: states) else { return nil }
        let recalled = ideaIDs.filter { states[$0]?.status == .produced }
        let wanted = Set(recalled.filter { memoryReviewIdea($0)?.wanted == true })
        guard let target = MemoryUnderstandingProbe.probeTarget(ideaIDs: recalled, wanted: wanted, states: states) else { return nil }
        var kind = MemoryUnderstandingProbe.next(after: memoryReviewLastProbeKind, includesAnalogy: true)
        var partner: MemoryUnderstandingProbe.AnalogyPartner?
        if kind == .analogy {
            // The probed idea's source leads the search; the topic's other
            // sources follow. Today's material is never a partner: its ideas
            // are being asked today, and an analogy names its partner.
            var anchors: [String] = []
            for sourceID in ([target] + ideaIDs).compactMap(SourceIdea.sourceID(fromIdeaID:)) where !anchors.contains(sourceID) {
                anchors.append(sourceID)
            }
            do {
                partner = try await storage.understandingAnalogyPartner(
                    nearSourceIDs: anchors,
                    excludingSourceIDs: Set(memoryReviewSourceIDs)
                )
            } catch {
                logger.error("Go deeper's analogy partner could not be read: \(error.localizedDescription, privacy: .public)")
            }
            if partner == nil {
                kind = MemoryUnderstandingProbe.next(after: memoryReviewLastProbeKind, includesAnalogy: false)
            }
        }
        memoryReviewLastProbeKind = kind
        return MemoryUnderstandingProbe.reviewNote(
            kind: kind,
            ideaID: target,
            topicID: topic?.id,
            partner: partner
        )
    }

    /// Whether the open session is a day's memory review.
    var isMemoryReviewSession: Bool {
        sessionID.map(MemoryReviewSession.isMemorySession) ?? false
    }

    /// Whether this chat's answers take the answer shape and end with
    /// suggested questions (`Prompts.answerShape`, `Prompts.followUpQuestions`).
    /// A review, a course quiz, a memory review and a walkthrough keep their
    /// own shapes: their next step is the tutor's question or the walk's next
    /// card, not one of the learner's. A walk starting or stopping flips it,
    /// which costs the cached head one miss.
    var offersFollowUpQuestions: Bool {
        courseQuiz == nil && !isMemoryReviewSession && !isTutorLed
            && walkthroughPlayback == nil
    }

    /// What the session record's `source_ids` holds: the review's material
    /// first, then whatever is attached beside it. An ordinary chat has no
    /// material list, so for it this is the attached pool as before.
    var persistedSessionSourceIDs: [String] {
        Self.persistedSessionSourceIDs(reviewMaterial: memoryReviewSourceIDs, attached: activeSourceIDs)
    }

    nonisolated static func persistedSessionSourceIDs(reviewMaterial: [String], attached: [String]) -> [String] {
        var seen = Set<String>()
        return (reviewMaterial + attached).filter { seen.insert($0).inserted }
    }

    /// A memory review's material on resume: the record's list, plus any source
    /// its briefing lists that the record lost. Order is the record's, then the
    /// briefing's; nothing is dropped, because the briefing is what the tutor
    /// works from and every source it names must be gradable.
    ///
    /// A source the learner took out of the day (`removeMemoryReviewSource`)
    /// is recorded on the briefing, and stays out whatever the record says:
    /// the record on another device may still carry it.
    /// The ideas a resumed review may grade: those its briefing listed under
    /// `IDEAS`, which for a chat-discussed source is only what the
    /// conversation engaged (`CohortSourceBrief.gradableIdeas`). A briefing
    /// from before that split listed every idea, so every idea stays gradable;
    /// a source the briefing says nothing about keeps what the store has,
    /// which is what a review resumed without a briefing has always used.
    nonisolated static func gradableIdeas(
        _ ideasBySource: [String: [SourceIdea]],
        briefing: String?
    ) -> [String: [SourceIdea]] {
        guard let briefing, !briefing.isEmpty else { return ideasBySource }
        let listed = MemoryReviewTutoring.gradableIdeaIDs(inBriefing: briefing)
        guard !listed.isEmpty else { return ideasBySource }
        return ideasBySource.mapValues { ideas in
            let kept = ideas.filter { listed.contains($0.id) }
            // A source the briefing never listed ideas for is not narrowed to
            // nothing; it is simply not described, and the store stands.
            return kept.isEmpty ? ideas : kept
        }
    }

    nonisolated static func memoryReviewMaterialSourceIDs(recorded: [String], briefing: String?) -> [String] {
        // Seeding with the removed ids keeps them out of both lists below.
        var seen = Set(MemoryReviewTutoring.removedSourceIDs(inBriefing: briefing ?? ""))
        var material = recorded.filter { seen.insert($0).inserted }
        for sourceID in MemoryReviewTutoring.sourceIDs(inBriefing: briefing ?? "")
        where seen.insert(sourceID).inserted {
            material.append(sourceID)
        }
        return material
    }

    /// Whether removing `sourceID` takes away the source the tutor's open
    /// question is about, so the review must move on now rather than wait.
    ///
    /// The tutor's own marks win when it has made any: the last turn line or
    /// grade names the current source. Before the first of either, the open
    /// question can only be the opening one, and the plan says what that is
    /// about: the first move still in play. A tutor that has not spoken yet
    /// has no question standing, so nothing needs replacing.
    nonisolated static func memoryReviewRemovalTakesOpenQuestion(
        removing sourceID: String,
        current: String?,
        anythingGraded: Bool,
        tutorHasAsked: Bool,
        briefing: String?
    ) -> Bool {
        if let current { return current == sourceID }
        guard !anythingGraded, tutorHasAsked, let briefing else { return false }
        return MemoryReviewTutoring.openingMoveSourceIDs(inBriefing: briefing).contains(sourceID)
    }

    /// The learner took a source out of today's review, from the × on its
    /// chip in the strip. Its ideas, depth and checkmark leave the session;
    /// its section leaves the briefing and a REMOVED line is recorded there,
    /// so the tutor stops asking about it and a reopen on any device leaves
    /// it out; and it is detached from the chat like any other source.
    ///
    /// The tutor is told in the learner's next message. When the review was
    /// on that very source, waiting would leave a question standing about
    /// material that is gone, so the note is returned for the caller to send
    /// now; otherwise it is staged and nil comes back. Nil also when there
    /// was nothing to remove.
    ///
    /// "On that source" is read off the tutor's turn lines and grades when it
    /// has written any, and off the plan before then: an opening question
    /// carries no turn line when the tutor forgets the one it owes the first
    /// source, and the learner who removes that source must still get a
    /// fresh question (`memoryReviewRemovalTakesOpenQuestion`).
    func removeMemoryReviewSource(_ sourceID: String, availableArticles: [StudioArticle]) async -> String? {
        guard let sessionID, isMemoryReviewSession,
              memoryReviewSourceIDs.contains(sourceID) || activeSourceIDs.contains(sourceID) else { return nil }
        let title = activeArticles.first { $0.id == sourceID }?.title
            ?? availableArticles.first { $0.id == sourceID }?.title
            ?? memoryReviewMaterialTitles[sourceID]
            ?? sourceID
        let wasCurrent = Self.memoryReviewRemovalTakesOpenQuestion(
            removing: sourceID,
            current: memoryReviewCurrentSourceID,
            anythingGraded: !memoryReviewStatusBySource.isEmpty,
            tutorHasAsked: chatMessages.contains { $0.role == .assistant },
            briefing: dailyPlanRationale
        )

        memoryReviewSourceIDs.removeAll { $0 == sourceID }
        memoryReviewIdeasBySource[sourceID] = nil
        memoryReviewDepthBySource[sourceID] = nil
        memoryReviewStatusBySource[sourceID] = nil
        if wasCurrent {
            memoryReviewCurrentSourceID = nil
        }

        if let briefing = dailyPlanRationale {
            let updated = MemoryReviewTutoring.briefing(briefing, removingSource: sourceID, title: title)
            dailyPlanRationale = updated
            do {
                try await storage.setReviewSessionBriefing(sessionID: sessionID, briefing: updated)
            } catch {
                errorMessage = error.localizedDescription
                logger.error("Memory review \(sessionID, privacy: .public): could not record the removal of \(sourceID, privacy: .public) on its briefing: \(error.localizedDescription, privacy: .public)")
            }
        }

        if activeSourceIDs.contains(sourceID) {
            // Detaches it and writes the record, material list included.
            await removeContextSource(sourceID, availableArticles: availableArticles)
        } else {
            do {
                try await storage.updateReviewSessionSources(sessionID: sessionID, sourceIDs: persistedSessionSourceIDs)
            } catch {
                errorMessage = error.localizedDescription
                logger.error("Memory review \(sessionID, privacy: .public): could not write back its sources after removing \(sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        logger.notice("Memory review \(sessionID, privacy: .public): the learner removed \(sourceID, privacy: .public) from today's review.")

        var note = "[ForeverLM] The learner removed \(title) from today's review; its source id is \(sourceID). "
            + "Do not ask about it again, skip any move that names it, and leave it out when you name what did not fit."
        guard wasCurrent else {
            pendingMemoryReviewNotes.append(note)
            return nil
        }
        note += " You were on it: turn to the next source still in the review now — write its "
            + MemoryReviewSourceTurn.line(sourceID: "SOURCE_ID") + " line with that source's id, then ask its contour."
        return note
    }

    /// `set_review_depth` from the tutor: the learner said how much review a
    /// source or a kind of source should get.
    func setReviewDepth(arguments: [String: Any]) async -> AppToolResult {
        guard let rawDepth = (arguments["depth"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let depth = MemoryReviewDepth(rawValue: rawDepth) else {
            return AppToolResult(text: "Error: depth must be one of quick, standard, deep.", isError: true)
        }
        let sourceID = (arguments["source_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceType = (arguments["source_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if let sourceID, !sourceID.isEmpty {
            guard activeSourceIDs.contains(sourceID) || memoryReviewSourceIDs.contains(sourceID) else {
                return AppToolResult(
                    text: "Error: source_id must be one of the sources in this review.",
                    isError: true
                )
            }
            do {
                try await storage.setSourceReviewDepth(sourceID: sourceID, depth: depth)
            } catch {
                return AppToolResult(text: "Error: \(error.localizedDescription)", isError: true)
            }
            memoryReviewDepthBySource[sourceID] = depth
            let title = activeArticles.first { $0.id == sourceID }?.title ?? sourceID
            return AppToolResult(
                text: "\(title) is now reviewed at \(depth.displayName.lowercased()) depth. Confirm in half a sentence and carry on.",
                isError: false
            )
        }
        if let sourceType, !sourceType.isEmpty {
            MemoryReviewDepth.setTypeDefault(depth, sourceType: sourceType)
            for article in activeArticles where article.sourceType.rawValue.lowercased() == sourceType {
                memoryReviewDepthBySource[article.id] = depth
            }
            return AppToolResult(
                text: "\(sourceType) sources are now reviewed at \(depth.displayName.lowercased()) depth by default. Confirm in half a sentence and carry on.",
                isError: false
            )
        }
        return AppToolResult(
            text: "Error: pass source_id for one source or source_type for a kind of source.",
            isError: true
        )
    }

    /// Validate the private grading tool and stage an immutable attempt. The
    /// model never supplies durable identity: an existing target comes from the
    /// manager's cursor, while intake IDs are generated here after source
    /// grounding succeeds.
    func stageMemoryAttempt(
        arguments: [String: Any],
        isFirst: Bool,
        config: AITaskConfig
    ) async -> AppToolResult {
        guard !isFirst else {
            return AppToolResult(
                text: "Error: Do not record a memory attempt before the learner has answered. Ask the first retrieval question now.",
                isError: true
            )
        }
        guard stagedMemoryAttempt == nil else {
            return AppToolResult(
                text: "Error: This learner answer already has a staged memory attempt. Give the final feedback without recording it twice.",
                isError: true
            )
        }
        guard let plan = memoryCompanionPlan, !plan.targets.isEmpty else {
            return AppToolResult(text: "Error: No memory companion plan is active.", isError: true)
        }
        let targetIndex = min(max(0, currentMemoryTargetIndex), plan.targets.count - 1)
        let target = plan.targets[targetIndex]

        guard let score = ToolArgumentNumber.value(arguments["score"]),
              let qualityRaw = arguments["retrieval_quality"] as? String,
              let quality = MemoryRetrievalQuality(rawValue: qualityRaw),
              let rating = MemoryTutorGradeMapping.rating(quality: quality, score: score) else {
            logger.error("record_memory_attempt rejected: score arrived as \(ToolArgumentNumber.describe(arguments["score"]), privacy: .public), retrieval_quality as \(String(describing: arguments["retrieval_quality"]), privacy: .public)")
            return AppToolResult(
                text: "Error: score must be a finite number from 0.0 to 1.0 (it arrived as \(ToolArgumentNumber.describe(arguments["score"]))) and retrieval_quality must be independent, hinted, or not_recalled. Call record_memory_attempt again with the arguments corrected; do not change the grade to make it pass.",
                isError: true
            )
        }
        guard let evaluation = Self.trimmedMemoryToolString(arguments["evaluation"], limit: 4_000) else {
            return AppToolResult(text: "Error: evaluation is required.", isError: true)
        }
        guard let rawMissing = arguments["missing_rubric_elements"] as? [String] else {
            return AppToolResult(text: "Error: missing_rubric_elements is required, even when it is empty.", isError: true)
        }
        let missing = rawMissing.compactMap {
            Self.trimmedMemoryToolString($0, limit: 500)
        }
        guard missing.count == rawMissing.count, missing.count <= 12 else {
            return AppToolResult(text: "Error: missing_rubric_elements must contain at most 12 non-empty strings.", isError: true)
        }
        let misconception = Self.trimmedMemoryToolString(arguments["misconception"], limit: 1_000)
        guard let prompt = lastAssistantQuestion?
            .trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty,
              let learnerAnswer = (chatMessages.last(where: { $0.role == .user })?.content)
            .map({ AttachedImageReference.textOnly($0) })?
            .trimmingCharacters(in: .whitespacesAndNewlines), !learnerAnswer.isEmpty,
              let sessionID else {
            return AppToolResult(
                text: "Error: The current learner answer is not attached to a live review exchange.",
                isError: true
            )
        }

        let memoryItem: MemoryItem?
        let expectedExistingItem: MemoryItem?
        let memoryItemID: String
        let attemptType: MemoryAttemptType
        if let existing = target.memoryItem {
            let forbidden = ["source_id", "semantic_target", "rubric", "evidence_excerpt"]
                .filter { arguments[$0] != nil }
            guard forbidden.isEmpty else {
                return AppToolResult(
                    text: "Error: The active memory item already exists. Omit source_id, semantic_target, rubric, and evidence_excerpt; ForeverLM owns its identity and rubric.",
                    isError: true
                )
            }
            memoryItem = nil
            expectedExistingItem = existing
            memoryItemID = existing.id
            attemptType = .review
        } else {
            guard let sourceID = Self.trimmedMemoryToolString(arguments["source_id"], limit: 200),
                  sourceID == target.sourceID,
                  activeSourceIDs.contains(sourceID) else {
                return AppToolResult(
                    text: "Error: source_id must exactly match the current attached first-review source.",
                    isError: true
                )
            }
            guard let semanticTarget = Self.trimmedMemoryToolString(arguments["semantic_target"], limit: 1_000) else {
                return AppToolResult(text: "Error: semantic_target is required for a first review.", isError: true)
            }
            guard let rawRubric = arguments["rubric"] as? [String] else {
                return AppToolResult(text: "Error: rubric is required for a first review.", isError: true)
            }
            let rubric = rawRubric.compactMap { Self.trimmedMemoryToolString($0, limit: 500) }
            guard rubric.count == rawRubric.count, (1...12).contains(rubric.count),
                  let rubricJSON = Self.sortedMemoryJSON(["criteria": rubric]) else {
                return AppToolResult(
                    text: "Error: rubric must contain 1 to 12 non-empty criteria.",
                    isError: true
                )
            }
            guard let excerpt = Self.trimmedMemoryToolString(arguments["evidence_excerpt"], limit: 2_000),
                  excerpt.count >= 20 else {
                return AppToolResult(
                    text: "Error: evidence_excerpt must be a compact exact source passage of at least 20 characters.",
                    isError: true
                )
            }

            let anchorValidation: MemorySourceAnchorValidation
            do {
                anchorValidation = try await storage.validatedMemorySourceAnchor(
                    sourceID: sourceID,
                    excerpt: excerpt
                )
            } catch {
                return AppToolResult(
                    text: "Error: ForeverLM could not validate canonical source evidence, so no memory was created. \(error.localizedDescription)",
                    isError: true
                )
            }

            let itemID = MemoryTutorIdentity.firstReviewItemID(
                portableSourceKey: anchorValidation.portableSourceKey
            )
            let now = Date()
            let anchor = MemoryItemSource(
                id: MemoryTutorIdentity.firstReviewAnchorID(
                    memoryItemID: itemID
                ),
                memoryItemID: itemID,
                sourceID: sourceID,
                excerpt: anchorValidation.excerpt,
                sourceSHA256: anchorValidation.sourceSHA256,
                sortIndex: 0
            )
            memoryItem = MemoryItem(
                id: itemID,
                kind: .concept,
                target: semanticTarget,
                rubricJSON: rubricJSON,
                learnerContext: misconception,
                goalID: nil,
                sources: [anchor],
                createdAt: now,
                updatedAt: now
            )
            expectedExistingItem = nil
            memoryItemID = itemID
            attemptType = .discovery
        }

        let evidence: [String: Any] = [
            "retrieval_quality": quality.rawValue,
            "missing_rubric_elements": missing,
            "misconception": misconception ?? NSNull(),
            "structured_evaluation": evaluation,
        ]
        guard let evidenceJSON = Self.sortedMemoryJSON(evidence) else {
            return AppToolResult(text: "Error: The structured grading evidence could not be encoded.", isError: true)
        }
        let attempt = MemoryAttempt(
            id: UUID().uuidString,
            memoryItemID: memoryItemID,
            sessionID: sessionID,
            exchangeID: nil,
            attemptType: attemptType,
            prompt: prompt,
            learnerAnswer: learnerAnswer,
            feedback: nil,
            score: score,
            scheduleRating: rating,
            gradeState: .graded,
            evidenceJSON: evidenceJSON,
            attemptedAt: Date(),
            modelProvider: config.provider.rawValue,
            modelID: config.model
        )
        stagedMemoryAttempt = StagedMemoryAttempt(
            item: memoryItem,
            expectedExistingItem: expectedExistingItem,
            attempt: attempt,
            knowledgeNote: misconception,
            shouldAdvance: MemoryTutorGradeMapping.shouldAdvance(quality: quality, score: score)
        )
        return AppToolResult(
            text: "Memory attempt validated and ready to save with the final feedback. Now respond conversationally without exposing the private rubric or evidence.",
            isError: false
        )
    }

    private static func trimmedMemoryToolString(_ value: Any?, limit: Int) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= limit else { return nil }
        return trimmed
    }

    private static func sortedMemoryJSON(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func refreshMemoryStruggleProjections() async throws {
        guard let plan = memoryCompanionPlan else {
            memoryStruggleProjections = [:]
            return
        }
        var projections: [String: MemoryStruggleProjection] = [:]
        var seen = Set<String>()
        for itemID in plan.memoryItemIDs where seen.insert(itemID).inserted {
            if let projection = try await storage.memoryStruggleProjection(
                memoryItemID: itemID,
                limit: 3
            ) {
                projections[itemID] = projection
            }
        }
        memoryStruggleProjections = projections
    }

    private enum PersistedMemoryTargetIdentity {
        case item(String)
        case firstReview(String)

        init?(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed == value else { return nil }
            for prefix in [
                MemoryFirstReviewTargetPrefix.sourceRefreshPortable,
                MemoryFirstReviewTargetPrefix.neverReviewedPortable,
                MemoryFirstReviewTargetPrefix.sourceRefresh,
                MemoryFirstReviewTargetPrefix.neverReviewed,
                "first-review:",
            ] {
                if trimmed.hasPrefix(prefix) {
                    let portableKey = String(trimmed.dropFirst(prefix.count))
                    guard !portableKey.isEmpty else { return nil }
                    self = .firstReview(portableKey)
                    return
                }
            }
            if trimmed.hasPrefix("memory-item:") {
                let itemID = String(trimmed.dropFirst("memory-item:".count))
                guard !itemID.isEmpty else { return nil }
                self = .item(itemID)
                return
            }
            self = .item(trimmed)
        }
    }

    struct RestoredMemoryCompanionState {
        let plan: MemoryCompanionPlan
        let currentTargetIndex: Int
        let needsRetry: Bool
    }

    struct MemoryResumeItems {
        let items: [MemoryItem]
        let firstReviewSourceIDsByPortableKey: [String: String]
    }

    func persistedMemoryTargetIDs(
        for plan: MemoryCompanionPlan?
    ) async throws -> [String] {
        guard let plan else { return [] }
        var targetIDs: [String] = []
        targetIDs.reserveCapacity(plan.targets.count)
        for target in plan.targets {
            if let itemID = target.memoryItemID {
                targetIDs.append(itemID)
            } else {
                let portableKey = try await storage.portableMemorySourceKey(
                    sourceID: target.sourceID
                )
                targetIDs.append("first-review:\(portableKey)")
            }
        }
        return targetIDs
    }

    func memoryItemsForResume(
        sessionID: String,
        targetIDs: [String],
        sessionSourceIDs: [String]
    ) async throws -> MemoryResumeItems {
        var items = try await storage.loadMemoryItemsForSession(sessionID)
        var seen = Set(items.map(\.id))
        var firstReviewSourceIDsByPortableKey: [String: String] = [:]
        for targetID in targetIDs {
            guard let identity = PersistedMemoryTargetIdentity(targetID) else {
                throw KnowledgeStoreError.invalidData(
                    "The saved memory review contains an invalid target identity. It was not reopened as an ordinary chat."
                )
            }
            let itemID: String
            switch identity {
            case .item(let storedID):
                itemID = storedID
            case .firstReview(let portableKey):
                guard let sourceID = try await storage.resolveMemorySourceID(
                    portableSourceKey: portableKey,
                    restrictToSourceIDs: sessionSourceIDs
                ) else {
                    throw KnowledgeStoreError.invalidData(
                        "A saved first-review target no longer resolves inside this review's sources."
                    )
                }
                firstReviewSourceIDsByPortableKey[portableKey] = sourceID
                itemID = MemoryTutorIdentity.firstReviewItemID(
                    portableSourceKey: portableKey
                )
            }
            guard !seen.contains(itemID) else { continue }
            if let item = try await storage.loadMemoryItem(itemID) {
                items.append(item)
                seen.insert(item.id)
            }
        }
        return MemoryResumeItems(
            items: items,
            firstReviewSourceIDsByPortableKey: firstReviewSourceIDsByPortableKey
        )
    }

    func restoreMemoryCompanionPlan(
        targetIDs: [String],
        items: [MemoryItem],
        attempts: [MemoryAttempt],
        session: ReviewSessionRecord,
        firstReviewSourceIDsByPortableKey: [String: String]
    ) throws {
        guard let restored = try Self.restoredMemoryCompanionState(
            targetIDs: targetIDs,
            items: items,
            attempts: attempts,
            session: session,
            firstReviewSourceIDsByPortableKey: firstReviewSourceIDsByPortableKey
        ) else {
            memoryCompanionPlan = nil
            currentMemoryTargetIndex = 0
            lastMemoryAttemptNeedsRetry = false
            return
        }
        memoryCompanionPlan = restored.plan
        currentMemoryTargetIndex = restored.currentTargetIndex
        lastMemoryAttemptNeedsRetry = restored.needsRetry
    }

    static func restoredMemoryCompanionState(
        targetIDs: [String],
        items: [MemoryItem],
        attempts: [MemoryAttempt],
        session: ReviewSessionRecord,
        firstReviewSourceIDsByPortableKey: [String: String]
    ) throws -> RestoredMemoryCompanionState? {
        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let sessionSourceIDs = Set(session.sourceIDs)

        func target(for item: MemoryItem) throws -> MemoryCompanionTarget {
            guard item.status == .active else {
                throw KnowledgeStoreError.invalidData(
                    "A saved memory target is no longer active. The review was not reopened with a substitute."
                )
            }
            let anchoredSourceIDs = MemoryTutorSourceLinkage.orderedSourceIDs(for: item)
            guard let sourceID = anchoredSourceIDs.first,
                  !anchoredSourceIDs.isEmpty,
                  Set(anchoredSourceIDs).isSubset(of: sessionSourceIDs) else {
                throw KnowledgeStoreError.invalidData(
                    "A saved memory target no longer matches this review's source anchors."
                )
            }
            let itemAttempts = attempts.filter { $0.memoryItemID == item.id }
            let last = itemAttempts.max {
                if $0.attemptedAt != $1.attemptedAt { return $0.attemptedAt < $1.attemptedAt }
                return $0.id < $1.id
            }
            let reason: MemoryCompanionReason = {
                let context = item.learnerContext?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !context.isEmpty || last?.scheduleRating == .again || last?.scheduleRating == .hard {
                    return .struggle
                }
                return .due
            }()
            return MemoryCompanionTarget(
                memoryItem: item,
                sourceID: sourceID,
                reason: reason,
                daysOverdue: 0
            )
        }

        let targets: [MemoryCompanionTarget]
        if targetIDs.isEmpty {
            targets = try items.map { try target(for: $0) }
            guard !targets.isEmpty else { return nil }
        } else {
            guard Set(targetIDs).count == targetIDs.count else {
                throw KnowledgeStoreError.invalidData(
                    "The saved memory review contains duplicate target identities."
                )
            }
            targets = try targetIDs.map { targetID in
                guard let identity = PersistedMemoryTargetIdentity(targetID) else {
                    throw KnowledgeStoreError.invalidData(
                        "The saved memory review contains an invalid target identity."
                    )
                }
                switch identity {
                case .item(let itemID):
                    guard let item = itemsByID[itemID] else {
                        throw KnowledgeStoreError.invalidData(
                            "A saved memory target is unavailable. The review was not reopened with a substitute."
                        )
                    }
                    return try target(for: item)
                case .firstReview(let portableKey):
                    guard let sourceID = firstReviewSourceIDsByPortableKey[portableKey],
                          sessionSourceIDs.contains(sourceID) else {
                        throw KnowledgeStoreError.invalidData(
                            "A saved first-review target no longer belongs to this review's sources."
                        )
                    }
                    let deterministicItemID = MemoryTutorIdentity.firstReviewItemID(
                        portableSourceKey: portableKey
                    )
                    if let item = itemsByID[deterministicItemID] {
                        let durable = try target(for: item)
                        guard durable.sourceID == sourceID else {
                            throw KnowledgeStoreError.invalidData(
                                "A saved first-review target no longer matches its canonical source."
                            )
                        }
                        return durable
                    }
                    return MemoryCompanionTarget(
                        memoryItem: nil,
                        sourceID: sourceID,
                        reason: .firstReview,
                        daysOverdue: 0
                    )
                }
            }
        }

        let plan = MemoryCompanionPlan(
            targets: targets,
            topic: session.title,
            goalID: session.goalID,
            generatedAt: Date()
        )

        let targetItemIDs = Set(targets.compactMap(\.memoryItemID))
        let relevantAttempts = attempts.filter { targetItemIDs.contains($0.memoryItemID) }
        guard let last = relevantAttempts.max(by: {
            if $0.attemptedAt != $1.attemptedAt { return $0.attemptedAt < $1.attemptedAt }
            return $0.id < $1.id
        }),
              let lastIndex = targets.firstIndex(where: { $0.memoryItemID == last.memoryItemID }) else {
            return RestoredMemoryCompanionState(
                plan: plan,
                currentTargetIndex: 0,
                needsRetry: false
            )
        }
        let advances = last.scheduleRating == .good || last.scheduleRating == .easy
        return RestoredMemoryCompanionState(
            plan: plan,
            currentTargetIndex: advances ? (lastIndex + 1) % targets.count : lastIndex,
            needsRetry: !advances
        )
    }

    func exchangeID(forSequence sequence: Int) async -> String? {
        guard let sessionID else { return nil }
        do {
            return try await storage.loadReviewSessionExchanges(sessionID: sessionID)
                .first { $0.sequenceNumber == sequence }?
                .id
        } catch {
            logger.error("Reading the review exchanges failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
