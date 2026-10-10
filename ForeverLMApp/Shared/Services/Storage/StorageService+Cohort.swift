import Foundation

extension StorageService {

    /// Assemble today's cohort.
    ///
    /// Spine and spacing come from SQL and a pure selector. Bridges need the
    /// in-memory vector index, which is why assembly lives here rather than in
    /// `KnowledgeStore`.
    ///
    /// `budgetMinutes` is the learner's daily time budget (Settings → Memory);
    /// it sizes the spine, the spacing set, and the number of bridges.
    func assembleLearningCohort(
        now: Date = Date(),
        minimumConfidence: SourceConsumptionConfidence = CohortSelector.selectableConfidence,
        restrictToSourceIDs: Set<String>? = nil,
        budgetMinutes: Int = MemoryReviewBudget.minutes
    ) throws -> LearningCohort {
        let store = try cohortKnowledgeStore()
        // Fetched at the looser bar so partly-read sources are available to
        // bridge against, then filtered to the stricter one before selection.
        // Syntopic reading is the reason: the many shallow reads still carry
        // context worth colliding with, even though none of them could carry a
        // review on its own.
        let bridgeable = try store.cohortCandidates(
            now: now,
            minimumConfidence: min(minimumConfidence, CohortSelector.bridgeableConfidence),
            restrictToSourceIDs: restrictToSourceIDs
        )
        let candidates = bridgeable.filter { $0.confidence >= minimumConfidence }
        let selection = CohortSelector.select(candidates: candidates, now: now, budgetMinutes: budgetMinutes)

        var (sources, claimed) = MemoryReviewPlanning.sources(from: selection, now: now)

        let bridges = selectBridges(
            spine: selection.spine,
            candidates: bridgeable,
            claimed: claimed,
            now: now,
            maxBridges: CohortSelector.maxBridges(budgetMinutes: budgetMinutes),
            store: store
        )
        sources.append(contentsOf: bridges)

        let unfinished = try store.unfinishedUnderstandingSourceIDs()
        let day = try memoryReviewDay(now: now, excluding: Set(sources.map(\.sourceID)), store: store)

        return LearningCohort(
            assembledAt: now,
            windowDays: CohortSelector.windowDays,
            sources: sources,
            unfinished: unfinished,
            droppedSpine: selection.droppedSpine,
            droppedSpacing: selection.droppedSpacing,
            touched: day.touched,
            ledger: day.ledger
        )
    }

    /// The day as the ledger recorded it: totals since the start of yesterday,
    /// and the sources opened in that window that are not in the review.
    func memoryReviewDay(
        now: Date = Date(),
        excluding: Set<String> = [],
        store: KnowledgeStore? = nil
    ) throws -> (ledger: MemoryReviewLedger, touched: [CohortTouchedSource]) {
        let store = try store ?? cohortKnowledgeStore()
        let since = MemoryReviewLedger.windowStart(now: now)
        let rows = try store.engagementRows(since: since, now: now)
        let chats = try store.chatDiscussionDates(now: now).filter { $0.value >= since }

        var ledger = MemoryReviewLedger()
        let rowIDs = Set(rows.map(\.sourceID))
        ledger.sourceCount = rowIDs.union(chats.keys).count
        ledger.engagedSeconds = rows.reduce(0) { $0 + $1.engagedSeconds }
        ledger.chatDiscussedCount = chats.count
        ledger.listenedCount = rows.filter(\.listened).count

        let touched = rows
            .filter { !excluding.contains($0.sourceID) }
            .map {
                CohortTouchedSource(
                    sourceID: $0.sourceID,
                    title: $0.title,
                    sourceType: $0.sourceType,
                    lastActivityAt: $0.lastActivityAt,
                    engagedSeconds: $0.engagedSeconds,
                    depth: $0.depth
                )
            }
            .sorted { lhs, rhs in
                if lhs.engagedSeconds != rhs.engagedSeconds { return lhs.engagedSeconds > rhs.engagedSeconds }
                return lhs.sourceID < rhs.sourceID
            }
        return (ledger, touched)
    }

    /// Today's review, for the Memory action.
    ///
    /// The action is never disabled, so a day with nothing due still has to
    /// open on something: the least recently touched consumed sources, marked
    /// `isBacklogOnly` so the tutor says nothing was due before offering them.
    /// An empty result means the library has nothing consumed at all.
    func assembleMemoryReviewCohort(now: Date = Date()) throws -> LearningCohort {
        let cohort = try assembleLearningCohort(now: now)
        guard cohort.isEmpty else { return cohort }

        let store = try cohortKnowledgeStore()
        let candidates = try store.cohortCandidates(
            now: now,
            minimumConfidence: CohortSelector.selectableConfidence
        )
        var backlog = MemoryReviewPlanning.backlogCohort(
            candidates: candidates,
            unfinished: try store.unfinishedUnderstandingSourceIDs(),
            now: now
        )
        let day = try memoryReviewDay(now: now, excluding: Set(backlog.sources.map(\.sourceID)), store: store)
        backlog.touched = day.touched
        backlog.ledger = day.ledger
        return backlog
    }

    /// How much is waiting, without building briefs or touching a single file.
    ///
    /// This is what the ambient count and the notification gate read, so it has
    /// to stay cheap enough to run on every app activation: one query and a pure
    /// selection pass, no review guides, no understanding documents, no vector
    /// index, no disk.
    func cohortDueCount(now: Date = Date()) throws -> Int {
        let candidates = try cohortKnowledgeStore().cohortCandidates(now: now)
        let selection = CohortSelector.select(candidates: candidates, now: now)
        return selection.spine.count + selection.spacing.count
    }

    /// Bridges: the only selection step whose purpose is to put two ideas in
    /// friction rather than to review either one.
    ///
    /// A neighbour only qualifies if it comes from a *different* time bucket than
    /// the spine source it is drawn against. A paper read the same week is not a
    /// bridge — it is just more of this week's reading, and connecting the two
    /// asks nothing of memory.
    ///
    /// Ranked and topped, never thresholded: NLContextualEmbedding is anisotropic,
    /// so an absolute cosine cutoff means nothing across different sources.
    private func selectBridges(
        spine: [CohortCandidate],
        candidates: [CohortCandidate],
        claimed: Set<String>,
        now: Date,
        maxBridges: Int,
        store: KnowledgeStore
    ) -> [CohortSource] {
        guard !spine.isEmpty, maxBridges > 0 else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.sourceID, $0) })

        var taken = claimed
        var bridges: [CohortSource] = []

        for anchor in spine {
            guard bridges.count < maxBridges else { break }
            guard let probe = try? store.cohortProbeVector(sourceID: anchor.sourceID),
                  !probe.isEmpty else { continue }

            let anchorBucket = CohortSelector.timeBucket(anchor.consumedAt, now: now)
            let ranked = findSimilarSources(queryVector: probe, topK: 40, threshold: 0)

            var addedForAnchor = 0
            for hit in ranked {
                guard addedForAnchor < CohortSelector.maxBridgesPerSpine,
                      bridges.count < maxBridges else { break }
                guard hit.id != anchor.sourceID, !taken.contains(hit.id) else { continue }
                // Must be something the learner actually consumed, or the question
                // is about material they never took in.
                // A partial read qualifies here and nowhere else.
                guard let neighbour = byID[hit.id],
                      neighbour.confidence >= CohortSelector.bridgeableConfidence else { continue }
                guard CohortSelector.timeBucket(neighbour.consumedAt, now: now) != anchorBucket else { continue }

                taken.insert(neighbour.sourceID)
                addedForAnchor += 1
                bridges.append(
                    CohortSource(
                        sourceID: neighbour.sourceID,
                        title: neighbour.title,
                        sourceType: neighbour.sourceType,
                        role: .bridge,
                        consumedAt: neighbour.consumedAt,
                        lastDiscussedAt: neighbour.lastDiscussedAt,
                        reviewCount: neighbour.reviewCount,
                        confidence: neighbour.confidence,
                        bridgeTo: anchor.sourceID,
                        reason: CohortSelector.reason(for: .bridge, candidate: neighbour, now: now),
                        engagement: neighbour.engagement
                    )
                )
            }
        }
        return bridges
    }

    /// Go deeper's analogy partner (`MemoryUnderstandingProbe.AnalogyPartner`):
    /// the source nearest `anchors` — the probed idea's source first — that
    /// sits in another notebook than every anchor, with one of its extracted
    /// ideas to set beside the probed one. The review chat asks it for a topic
    /// whose ideas all came back, the card review for a remembered card.
    ///
    /// Nearness is the bridges' (`selectBridges`): each anchor's first chunk
    /// against the source index, ranked and never thresholded, the anchors'
    /// rankings merged rank by rank. A partner is something the learner can
    /// be shown: active, not hidden, inside the knowledge boundary, and not
    /// one of `excludingSourceIDs` (the review chat's own material, whose
    /// ideas are being asked today). Nil when no source qualifies, which is
    /// not a failure: the probe rotation then leaves the analogy out.
    func understandingAnalogyPartner(
        nearSourceIDs anchors: [String],
        excludingSourceIDs: Set<String> = []
    ) throws -> MemoryUnderstandingProbe.AnalogyPartner? {
        var ordered: [String] = []
        for anchor in anchors where !ordered.contains(anchor) { ordered.append(anchor) }
        guard !ordered.isEmpty else { return nil }
        let store = try cohortKnowledgeStore()
        // A search per anchor, the first few: a topic seldom spans more, and
        // the probed idea's source, which leads, matters most.
        let rankings: [[String]] = ordered.prefix(4).compactMap { anchor in
            guard let probe = try? store.cohortProbeVector(sourceID: anchor), !probe.isEmpty else { return nil }
            return findSimilarSources(queryVector: probe, topK: 40, threshold: 0).map(\.id)
        }
        let anchorSet = Set(ordered)
        let ranked = MemoryUnderstandingProbe.interleaved(rankings)
            .filter { !anchorSet.contains($0) && !excludingSourceIDs.contains($0) }
        guard !ranked.isEmpty else { return nil }
        let notebooks = try store.notebooksHolding(sourceIDs: ordered + ranked)
        let anchorNotebookIDs = Set(ordered.flatMap { notebooks[$0] ?? [] }.map(\.id))
        // Ideas and titles only for the sources the notebook rule leaves in.
        let inAnotherNotebook = ranked.filter {
            MemoryUnderstandingProbe.isInAnotherNotebook(notebooks[$0] ?? [], than: anchorNotebookIDs)
        }
        guard !inAnotherNotebook.isEmpty else { return nil }
        return MemoryUnderstandingProbe.analogyPartner(
            ranked: inAnotherNotebook,
            anchors: ordered,
            notebooksBySource: notebooks,
            titles: try store.visibleSourceTitles(sourceIDs: inAnotherNotebook),
            ideasBySource: try store.loadSourceIdeas(sourceIDs: inAnotherNotebook),
            excluded: try store.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        )
    }

    // MARK: - Understanding documents

    func loadUnderstandingDocument(sourceID: String) throws -> UnderstandingDocument? {
        try cohortKnowledgeStore().loadUnderstandingDocument(sourceID: sourceID)
    }

    func loadUnderstandingDocuments(sourceIDs: [String]) throws -> [String: UnderstandingDocument] {
        try cohortKnowledgeStore().loadUnderstandingDocuments(sourceIDs: sourceIDs)
    }

    @discardableResult
    func saveUnderstandingDocument(
        sourceID: String,
        title: String,
        markdown: String,
        derivedThroughSessionID: String?,
        openThreadCount: Int = 0,
        /// nil leaves whatever the document already recorded; an empty list
        /// clears it. See `KnowledgeStore.saveUnderstandingDocument`.
        discussedIdeaIDs: [String]? = nil
    ) throws -> UnderstandingDocument {
        try cohortKnowledgeStore().saveUnderstandingDocument(
            sourceID: sourceID,
            title: title,
            markdown: markdown,
            derivedThroughSessionID: derivedThroughSessionID,
            openThreadCount: openThreadCount,
            discussedIdeaIDs: discussedIdeaIDs
        )
    }

    func understandingConflictCopies(sourceID: String) throws -> [String] {
        try cohortKnowledgeStore().understandingConflictCopies(sourceID: sourceID)
    }

    /// See `KnowledgeStore.appendThinkFirstTake`.
    @discardableResult
    func appendThinkFirstTake(
        sourceID: String,
        title: String,
        question: String,
        take: String
    ) throws -> UnderstandingDocument {
        try cohortKnowledgeStore().appendThinkFirstTake(
            sourceID: sourceID,
            title: title,
            question: question,
            take: take
        )
    }

    /// The learner's Think first takes on a source, oldest first; empty when
    /// the source has no understanding document.
    func thinkFirstTakes(sourceID: String) throws -> [ThinkFirstTake] {
        try cohortKnowledgeStore().loadUnderstandingDocument(sourceID: sourceID)?.thinkFirstTakes ?? []
    }

    // MARK: - Briefs

    /// Package each source for the planner: what it says, what the learner
    /// marked, and what they have previously made of it.
    ///
    /// A missing review guide is not an error. Guides are generated lazily off a
    /// queue, so a source consumed today may not have one yet — the planner can
    /// still work from title, highlights, and prior understanding.
    func cohortBriefs(for cohort: LearningCohort) throws -> [CohortSourceBrief] {
        let store = try cohortKnowledgeStore()
        let sourceIDs = cohort.sources.map(\.sourceID)
        let highlightsBySource = try store.sourceHighlights(sourceIDs: sourceIDs)
        let understandingBySource = try store.loadUnderstandingDocuments(sourceIDs: sourceIDs)
        let ideasBySource = try store.loadSourceIdeas(sourceIDs: sourceIDs)
        let depthBySource = try store.loadSourceReviewDepths(sourceIDs: sourceIDs)

        return try cohort.sources.map { source in
            // A chat has no review guide; its transcript stands where the
            // guide would, so the tutor knows what was said without the
            // learner being asked to open anything.
            let guide = source.sourceType == ReviewableChat.sourceType
                ? try store.reviewableChat(sessionID: source.sourceID)?
                    .excerpt(maxCharacters: CohortSourceBrief.maxGuideCharacters)
                : try store.loadSourceReviewGuide(source.sourceID)?.guide
            // A highlight the learner wrote a note on is elaborative encoding —
            // they did the work of saying what it meant — so it outranks a bare
            // one however recent, and is labeled as theirs rather than blurred
            // into the same list.
            let highlights = (highlightsBySource[source.sourceID] ?? [])
                .sorted { lhs, rhs in
                    if lhs.hasNote != rhs.hasNote { return lhs.hasNote }
                    return lhs.createdAt > rhs.createdAt
                }
                .map { highlight -> String in
                    highlight.note.isEmpty
                        ? highlight.quote
                        : "\(highlight.quote) — THEIR OWN NOTE: \(highlight.note)"
                }
            let document = understandingBySource[source.sourceID]
            let discussed = document?.discussedIdeaIDs ?? []
            let split = CohortSourceBrief.gradableIdeas(
                ideasBySource[source.sourceID] ?? [],
                discussedIdeaIDs: discussed,
                engagement: source.engagement,
                confidence: source.confidence
            )
            return CohortSourceBrief(
                source: source,
                guide: guide,
                highlights: highlights,
                understanding: document?.markdown,
                understandingHasLearnerEdits: document?.hasLearnerEdits ?? false,
                exemplarQuestions: try store.exemplarQuestions(sourceID: source.sourceID),
                ideas: split.gradable,
                contextIdeas: split.context,
                discussedIdeaIDs: discussed,
                depth: MemoryReviewDepth.effective(
                    sourceDepth: depthBySource[source.sourceID],
                    sourceType: source.sourceType
                )
            )
        }
    }

    /// Briefs for an arbitrary set of sources, for the closer — which works from
    /// what a session actually touched rather than from the cohort it planned.
    func cohortBriefs(forSourceIDs sourceIDs: [String]) throws -> [CohortSourceBrief] {
        let store = try cohortKnowledgeStore()
        let understandingBySource = try store.loadUnderstandingDocuments(sourceIDs: sourceIDs)
        // The closer names which ideas the conversation engaged, so it has to
        // see them. A source with none yet — never read far enough to be
        // extracted — simply has nothing to name.
        let ideasBySource = try store.loadSourceIdeas(sourceIDs: sourceIDs)
        let sources = try store.loadSourcesWithoutContent()
            .filter { sourceIDs.contains($0.id) }

        return sources.map { article -> CohortSourceBrief in
            let document = understandingBySource[article.id]
            return CohortSourceBrief(
                source: CohortSource(
                    sourceID: article.id,
                    title: article.title,
                    sourceType: article.sourceType.rawValue,
                    role: .spine,
                    consumedAt: article.readAt,
                    lastDiscussedAt: nil,
                    reviewCount: 0,
                    confidence: .complete,
                    bridgeTo: nil,
                    reason: "Discussed in the session being closed."
                ),
                guide: nil,
                highlights: [],
                understanding: document?.markdown,
                understandingHasLearnerEdits: document?.hasLearnerEdits ?? false,
                exemplarQuestions: [],
                ideas: ideasBySource[article.id] ?? [],
                discussedIdeaIDs: document?.discussedIdeaIDs ?? []
            )
        }
    }

    /// Summaries of the last few completed reviews, newest first. The planner
    /// reads them so a session can pick up where the previous one stopped.
    func recentReviewSummaries(limit: Int = 3) throws -> [String] {
        try cohortKnowledgeStore().recentReviewSessionSummaries(limit: limit)
    }

    /// A chat as review material, or nil when the session is not one. What
    /// the idea extraction reaches for when a cohort id names no source.
    func loadReviewableChat(sessionID: String) throws -> ReviewableChatTranscript? {
        try cohortKnowledgeStore().reviewableChat(sessionID: sessionID)
    }
}
