import Foundation
import OSLog

/// One managed text completion from the phone, with the same route resolution,
/// request shape, usage ledger, and model check every other phone call uses.
enum MobileManagedTextCall {
    struct Result: Sendable {
        let text: String
        let route: ResolvedAITextRoute
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        return URLSession(configuration: config)
    }()

    static func complete(
        task: AITask,
        system: String,
        messages: [(role: String, content: String)],
        maxTokens: Int,
        jsonMode: Bool = false,
        operation: String,
        sessionID: String? = nil
    ) async throws -> Result {
        guard ManagedAI.isSignedIn else { throw MobileStreamingChatError.notSignedIn }
        let route = try await MobileModelPreferenceStore.shared.resolve(task)
        let request = try MobileOpenRouterChat.request(
            route: route,
            system: system,
            messages: messages,
            maxTokens: maxTokens,
            jsonMode: jsonMode
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MobileStreamingChatError.http(status: 0, body: "\(route.provider) did not return an HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else {
            throw MobileStreamingChatError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? "No response body."
            )
        }
        let parsed = try MobileOpenRouterChat.text(from: data)
        try MobileOpenRouterChat.requireSelectedModel(parsed.json, route: route)
        return Result(text: parsed.text, route: route)
    }
}

enum MobileMemoryReviewPreparationError: LocalizedError {
    case nothingToReview
    case noSourceYieldedIdeas(String?)
    case planWithoutMoves

    var errorDescription: String? {
        switch self {
        case .nothingToReview:
            return "Nothing to review yet. Read or listen to something first."
        case .noSourceYieldedIdeas(let reason):
            return "Today's review could not be prepared: no source yielded ideas." + (reason.map { " \($0)" } ?? "")
        case .planWithoutMoves:
            return "Today's review could not be planned: the planner returned no usable moves."
        }
    }
}

/// Plans today's review on the phone — the same steps the Mac's Memory row
/// runs, on the records the phone syncs: assemble the cohort, extract any
/// missing ideas, call the planner once, write the briefing on the day's
/// record with the tutor's opening question already in it.
///
/// Two things the Mac has and the phone does not: bridges, which need the
/// Mac's vector index, and the understanding documents and recent-session
/// summaries the planner is otherwise shown. A review prepared here has spine
/// and spacing only and a planner briefed without those two; a review prepared
/// on the Mac has all of it. Either way it is one record, and the other device
/// opens it as it is.
actor MobileMemoryReviewPreparer {
    static let shared = MobileMemoryReviewPreparer()

    private let catalog = MobileCloudSourceCatalog.shared
    private let textStore = MobileCloudSourceTextStore.shared
    private let store = MobileMemoryReviewStore.shared
    private let ideaStore = MobileSourceIdeaStore.shared

    /// Today's review, prepared now or found already prepared.
    func prepare(now: Date = Date()) async throws -> MobileMemoryReviewRecord {
        let sessionID = MemoryReviewSession.sessionID(for: now)
        if let existing = try await store.fetch(sessionID: sessionID) { return existing }

        do {
            _ = try await catalog.loadSources()
        } catch {
            Logger(subsystem: "com.foreverlm.mobile", category: "MemoryReviewPreparer")
                .error("Loading the sources for the review failed: \(error.localizedDescription, privacy: .public)")
        }
        let candidates = await catalog.currentMemoryReviewCandidates(now: now)
        // The learner's daily time budget, the same synced row the Mac reads;
        // the default when it was never set or CloudKit cannot be reached.
        let budgetMinutes = MemoryReviewBudget.clamp(
            (try? await MobileModelPreferenceStore.shared.int(forKey: MemoryReviewBudget.preferenceKey))
                .flatMap { $0 } ?? MemoryReviewBudget.defaultMinutes
        )
        let selection = CohortSelector.select(candidates: candidates, now: now, budgetMinutes: budgetMinutes)
        let (selected, _) = MemoryReviewPlanning.sources(from: selection, now: now)
        var cohort = LearningCohort(
            assembledAt: now,
            windowDays: CohortSelector.windowDays,
            sources: selected,
            unfinished: [],
            droppedSpine: selection.droppedSpine,
            droppedSpacing: selection.droppedSpacing
        )
        if cohort.isEmpty {
            cohort = MemoryReviewPlanning.backlogCohort(candidates: candidates, unfinished: [], now: now)
        }
        guard !cohort.isEmpty else { throw MobileMemoryReviewPreparationError.nothingToReview }
        // The day's ledger and what was opened but not quizzed, from the same
        // synced records, so the phone's briefing says what the Mac's would.
        let day = await catalog.currentMemoryReviewDay(now: now, excluding: Set(cohort.sources.map(\.sourceID)))
        cohort.touched = day.touched
        cohort.ledger = day.ledger

        let sourcesByID = Dictionary(
            await catalog.currentSources(ids: cohort.sources.map(\.sourceID)).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Ideas first: the contour is graded against them, so a source without
        // ideas cannot be reviewed today. Extraction is one billed call per
        // source text and costs nothing when ideas already synced. The calls
        // run side by side — one after another, a cohort of new sources kept
        // the learner watching an empty review for minutes.
        // The catalog reads them where the generation keeps them (a source's `ideas` satellite, §10, once switched).
        var ideasBySource = await catalog.currentSourceIdeas(sourceIDs: cohort.sources.map(\.sourceID))
        var skipped: [String] = []
        let missing = cohort.sources.filter { (ideasBySource[$0.sourceID] ?? []).isEmpty }
        let extracted = await withTaskGroup(of: (CohortSource, Result<[SourceIdea], Error>).self) { group in
            for source in missing {
                let cloudSource = sourcesByID[source.sourceID]
                group.addTask {
                    do {
                        // Bound before the tuple: AGENTS.md's Release miscompile.
                        let ideas = try await self.extractIdeas(for: source, cloudSource: cloudSource, sessionID: sessionID)
                        return (source, .success(ideas))
                    } catch {
                        return (source, .failure(error))
                    }
                }
            }
            var results: [String: (CohortSource, Result<[SourceIdea], Error>)] = [:]
            for await (source, result) in group { results[source.sourceID] = (source, result) }
            return results
        }
        // In cohort order, so the skipped list reads the same run to run.
        for source in missing {
            guard let (_, result) = extracted[source.sourceID] else { continue }
            switch result {
            case .success(let ideas):
                ideasBySource[source.sourceID] = ideas
            case .failure(let error):
                skipped.append("\(source.title) — \(error.localizedDescription)")
            }
        }
        let reviewable = cohort.sources.filter { !(ideasBySource[$0.sourceID] ?? []).isEmpty }
        guard !reviewable.isEmpty else {
            throw MobileMemoryReviewPreparationError.noSourceYieldedIdeas(skipped.first)
        }
        cohort = LearningCohort(
            assembledAt: cohort.assembledAt,
            windowDays: cohort.windowDays,
            sources: reviewable,
            unfinished: cohort.unfinished,
            droppedSpine: cohort.droppedSpine,
            droppedSpacing: cohort.droppedSpacing,
            isBacklogOnly: cohort.isBacklogOnly,
            touched: cohort.touched,
            ledger: cohort.ledger
        )

        var briefs: [CohortSourceBrief] = []
        for source in cohort.sources {
            let cloudSource = sourcesByID[source.sourceID]
            let highlights = await catalog.currentSourceHighlights(sourceID: source.sourceID)
            let typeDefault = (try? await MobileModelPreferenceStore.shared
                .string(forKey: MemoryReviewDepth.typePreferenceKey(sourceType: source.sourceType)))
                .flatMap { MemoryReviewDepth(rawValue: $0) }
            // The phone holds no understanding documents, so it knows of no
            // discussed ideas and the split is a no-op here: every idea stays
            // gradable, as it always has. Written the Mac's way all the same,
            // so the two clients cannot drift the day the field syncs.
            let split = CohortSourceBrief.gradableIdeas(
                ideasBySource[source.sourceID] ?? [],
                discussedIdeaIDs: [],
                engagement: source.engagement,
                confidence: source.confidence
            )
            briefs.append(CohortSourceBrief(
                source: source,
                guide: cloudSource?.sourceReviewGuide?.guide,
                highlights: SourceIdeaDrafting.highlightLines(highlights),
                understanding: nil,
                understandingHasLearnerEdits: false,
                exemplarQuestions: [],
                ideas: split.gradable,
                contextIdeas: split.context,
                depth: MemoryReviewDepth.effective(sourceDepth: nil, typeDefault: typeDefault)
            ))
        }

        let planResult = try await MobileManagedTextCall.complete(
            task: .cohortSessionPlan,
            system: Prompts.cohortSessionPlanner,
            messages: [(role: "user", content: MemoryReviewTutoring.plannerUserMessage(
                cohort: cohort, briefs: briefs, recentSessionSummaries: [], budgetMinutes: budgetMinutes
            ))],
            maxTokens: 2_500,
            jsonMode: true,
            operation: "mobile_memory_review_plan",
            sessionID: sessionID
        )
        let plan: CohortSessionPlan = try MemoryReviewPlanning.decodeJSON(planResult.text)
        let validated = plan.validated(against: cohort, briefs: briefs)
        // Organized by topic, as on the Mac: a plan with no topic that
        // survived validation is a failed plan, not a source-by-source one.
        guard !validated.moves.isEmpty, !validated.topics.isEmpty else {
            throw MobileMemoryReviewPreparationError.planWithoutMoves
        }

        let briefing = MemoryReviewTutoring.briefing(
            cohort: cohort,
            briefs: briefs,
            plan: validated,
            skippedSources: skipped,
            startedAt: now,
            budgetMinutes: budgetMinutes
        )

        // The tutor's opening message, so the review opens onto its first
        // question on whichever device picks it up.
        let opener = try await MobileManagedTextCall.complete(
            task: .chat,
            system: MemoryReviewTutoring.systemPrompt(
                briefing: briefing,
                localClockDescription: MobileMemoryReviewViewModel.localClockDescription()
            ),
            messages: [(role: "user", content: MemoryReviewTutoring.openingRequest(forBriefing: briefing))],
            maxTokens: MobileStreamingChat.responseTokenBudget,
            operation: "mobile_memory_review",
            sessionID: sessionID
        )
        let openingQuestion = opener.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !openingQuestion.isEmpty else { throw MobileStreamingChatError.emptyCompletion }

        return try await store.create(MobileMemoryReviewStore.Draft(
            sessionID: sessionID,
            topic: MemoryReviewSession.title(for: now),
            briefing: briefing,
            sourceIDs: cohort.sources.map(\.sourceID),
            sourceIdentities: cohort.sources.map { Self.sourceIdentity(sourcesByID[$0.sourceID], id: $0.sourceID) },
            modelProvider: opener.route.provider,
            modelID: opener.route.model,
            openingQuestion: openingQuestion,
            startedAt: now
        ))
    }

    /// Extracts one source's ideas and writes them as the records the Mac
    /// reads, with the identity the Mac would have given the same text.
    private func extractIdeas(
        for source: CohortSource,
        cloudSource: MobileCloudSource?,
        sessionID: String
    ) async throws -> [SourceIdea] {
        // A chat the learner had is material of its own (`ReviewableChat`):
        // its text is the transcript, read under the chat prompt, and its
        // ideas name the session as their origin — the same as on the Mac.
        let isChat = source.sourceType == ReviewableChat.sourceType
        let text: String
        var highlights: [SourceHighlight] = []
        if isChat {
            guard let chat = try await catalog.currentReviewableChatTranscript(sessionID: source.sourceID) else {
                throw SourceIdeaExtractionError.noReadableText(source.title)
            }
            text = chat.text
        } else {
            text = try await textStore.loadSourceText(sourceID: source.sourceID)
            highlights = await catalog.currentSourceHighlights(sourceID: source.sourceID)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SourceIdeaExtractionError.noReadableText(source.title)
        }
        let hash = SourceIdeaDrafting.contentHash(text)
        let result = try await MobileManagedTextCall.complete(
            task: .sourceIdeaExtraction,
            system: isChat ? Prompts.chatIdeaExtraction : Prompts.sourceIdeaExtraction,
            messages: [(role: "user", content: SourceIdeaDrafting.userMessage(
                title: source.title,
                sourceType: source.sourceType,
                highlightLines: SourceIdeaDrafting.highlightLines(highlights),
                sourceText: text
            ))],
            maxTokens: 3_000,
            jsonMode: true,
            operation: "mobile_source_idea_extraction",
            sessionID: sessionID
        )
        let decoded: SourceIdeaExtractionResponse = try MemoryReviewPlanning.decodeJSON(result.text)
        let ideas = SourceIdeaDrafting.ideas(
            from: decoded.ideas,
            sourceID: source.sourceID,
            contentHash: hash,
            highlights: highlights,
            originSessionID: isChat ? source.sourceID : nil
        )
        guard !ideas.isEmpty else { throw SourceIdeaExtractionError.noIdeas(source.title) }
        try await ideaStore.save(ideas, sourceIdentity: Self.sourceIdentity(cloudSource, id: source.sourceID))
        return ideas
    }

    /// Portable identity of a source, as the Mac's sync payloads carry it.
    static func sourceIdentity(_ source: MobileCloudSource?, id: String) -> [String: String] {
        var identity: [String: String] = ["sourceID": id]
        if let url = source?.url {
            identity["url"] = url
            identity["normalizedURL"] = source?.normalizedURL ?? MobileSourceURL.normalize(url)
        }
        if let doi = source?.doi { identity["doi"] = doi }
        if let publishedDOI = source?.publishedDOI { identity["publishedDOI"] = publishedDOI }
        return identity
    }
}
