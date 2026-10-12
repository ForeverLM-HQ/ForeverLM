import Foundation
import OSLog

/// Everything one request reads before anything is planned or spent: each
/// source as drafting reads it, the ones left out and why, and the decided
/// cards of the request's notebook.
struct CardDraftingMaterials: Sendable {
    let request: CardDraftingRequest
    let sources: [CardDraftingSource]
    let skipped: [CardDraftingSkip]
    let notebookExemplars: [CardDraftingExemplar]
}

/// How far a run has come, for the pending row and `list_running_ai_work`.
struct CardDraftingProgress: Equatable, Sendable {
    let done: Int
    let total: Int

    /// "Drafting cards (2 of 5 sources)"
    var label: String {
        total <= 1 ? "Drafting cards" : "Drafting cards (\(min(done + 1, total)) of \(total) sources)"
    }
}

/// Drafts Memory cards from sources, on request and in the background
/// (`AutomaticCardDraftingPass`; docs/memory-design.md, "Drafting on
/// request" and "Drafting in the background"). One process-wide service,
/// so every trigger shares its one rule: a source is drafted by one task at a
/// time (a second request for it waits for the first, then adds only what the
/// first left uncovered), and drafting is idempotent per seed, not per
/// source — a seed drafted once, kept or skipped since, is never offered
/// again (`FlashcardDeck.appending`).
///
/// Each source's turn reads its whole text, sampled with a `[Sampled]` marker
/// only when that one source alone does not fit the route's window (from the
/// model directory). Its walkthrough's questions are drafted free, with no
/// model call; the model drafts the rest from the remaining seeds and the
/// text. Every draft then passes the wording gate (`CardWordingGate`): a card
/// that points at its source unnamed is reworded once or dropped, and a
/// source whose cards could not be checked saves none. Every quote is
/// checked when the drafts are saved (`StorageService.saveCardDrafts`): a
/// card its source does not print is reported and never offered.
///
/// The service holds no storage of its own: callers pass theirs (the view
/// model's, an MCP store's), so a run writes through the same connection the
/// window reads.
actor CardDraftingService {
    static let shared = CardDraftingService()

    /// How many sources are drafted at once.
    static let concurrency = 3

    private var lanes: [String: Task<Void, Never>] = [:]
    private let logger = Logger(subsystem: "com.foreverlm", category: "CardDrafting")

    // MARK: Read

    /// Reads every source the request names, one storage hop each, with the
    /// decks and the knowledge boundary read once. Writes nothing.
    static func load(
        _ request: CardDraftingRequest,
        storage: StorageService,
        stateDefaults: UserDefaults = .standard
    ) async throws -> CardDraftingMaterials {
        let decks = try await storage.loadCardDrafts()
        let excluded = try await storage.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        var sources: [CardDraftingSource] = []
        var skipped: [CardDraftingSkip] = []
        for sourceID in request.sourceIDs {
            try Task.checkCancellation()
            switch try await storage.cardDraftingSource(
                sourceID,
                decks: decks,
                excludedSourceIDs: excluded,
                stateDefaults: stateDefaults,
                reach: request.reach(of: sourceID)
            ) {
            case .source(let source): sources.append(source)
            case .skipped(let skip): skipped.append(skip)
            }
        }
        let notebookExemplars = try await storage.cardDraftingNotebookExemplars(
            notebookID: request.notebookID,
            decks: decks,
            except: Set(sources.map(\.sourceID)),
            excludedSourceIDs: excluded,
            stateDefaults: stateDefaults
        )
        return CardDraftingMaterials(
            request: request,
            sources: sources,
            skipped: skipped,
            notebookExemplars: notebookExemplars
        )
    }

    // MARK: Plan

    /// The plan for what was read, on `route`. Pure and cheap: the Make Cards
    /// sheet plans again on every change of count or focus.
    static func plan(
        _ materials: CardDraftingMaterials,
        count: MemoryCardRequestCount? = nil,
        focus: String?? = nil,
        route: CardDraftingRoute
    ) -> CardDraftingPlan {
        var request = materials.request
        if count != nil || focus != nil {
            request = CardDraftingRequest(
                notebookID: request.notebookID,
                sourceIDs: request.sourceIDs,
                count: count ?? request.count,
                focus: focus ?? request.focus,
                trigger: request.trigger,
                reach: request.reach
            )
        }
        return CardDraftingPlanner.plan(
            request: request,
            sources: materials.sources,
            skipped: materials.skipped,
            notebookExemplars: materials.notebookExemplars,
            route: route
        )
    }

    // MARK: Run

    /// Read, plan and run in one: background drafting's call
    /// (`AutomaticCardDraftingPass`), or any caller that has already shown
    /// the learner the price. Throws when no model is configured.
    func draft(
        _ request: CardDraftingRequest,
        storage: StorageService,
        backend: any CardDraftingBackend = LiveCardDraftingBackend(aiService: AIService()),
        route: CardDraftingRoute? = nil,
        gate: CardDraftingSpendGate,
        wording: (any CardWordingBackend)? = nil,
        stateDefaults: UserDefaults = .standard,
        onProgress: @escaping @Sendable (CardDraftingProgress) async -> Void = { _ in }
    ) async throws -> CardDraftingResult {
        guard let route = route ?? CardDraftingRoute.current() else { throw CardDraftingError.noModel }
        let materials = try await Self.load(request, storage: storage, stateDefaults: stateDefaults)
        let plan = Self.plan(materials, route: route)
        return try await run(plan, storage: storage, backend: backend, gate: gate, wording: wording, onProgress: onProgress)
    }

    /// Drafts every source of `plan`, a few at a time, each in its own lane,
    /// and saves each source's drafts as soon as they are written, so a run
    /// stopped part way keeps what it finished. A background run (`gate`)
    /// asks before every model call and drafts nothing more once the answer
    /// is no; the free cards of a source still land. A plan with no source
    /// to draft answers its left-out sources and spends nothing. Throws only
    /// for cancellation.
    func run(
        _ plan: CardDraftingPlan,
        storage: StorageService,
        backend: any CardDraftingBackend,
        gate: CardDraftingSpendGate,
        wording: (any CardWordingBackend)? = nil,
        onProgress: @escaping @Sendable (CardDraftingProgress) async -> Void = { _ in }
    ) async throws -> CardDraftingResult {
        var result = CardDraftingResult(skipped: plan.skipped)
        let wording = wording ?? CardWordingGate.backend()
        guard !plan.sources.isEmpty else { return result }
        let now = Date()
        let workflowID = UUID().uuidString
        let sources = plan.sources
        let total = sources.count
        let isRequested = plan.request.isRequested
        let system = plan.system
        let route = plan.route
        let width = min(Self.concurrency, total)
        let outcomes: [Int: CardDraftingSourceOutcome] = try await AIUsageAttribution.$activityID.withValue(workflowID) {
            try await withThrowingTaskGroup(of: (Int, CardDraftingSourceOutcome).self) { group in
                var found: [Int: CardDraftingSourceOutcome] = [:]
                var next = 0
                while next < width {
                    let index = next
                    let sourcePlan = sources[index]
                    group.addTask {
                        // Bound before the tuple is built: a tuple around a
                        // `try await` in a task closure miscompiles at -O
                        // (AGENTS.md).
                        let outcome = try await self.inLane(sourcePlan.source.sourceID) {
                            try await Self.draftOne(
                                sourcePlan, system: system, route: route, isRequested: isRequested,
                                storage: storage, backend: backend, gate: gate, wording: wording, at: now
                            )
                        }
                        return (index, outcome)
                    }
                    next += 1
                }
                while let (index, outcome) = try await group.next() {
                    found[index] = outcome
                    await onProgress(CardDraftingProgress(done: found.count, total: total))
                    try Task.checkCancellation()
                    if next < total {
                        let index = next
                        let sourcePlan = sources[index]
                        group.addTask {
                            let outcome = try await self.inLane(sourcePlan.source.sourceID) {
                                try await Self.draftOne(
                                    sourcePlan, system: system, route: route, isRequested: isRequested,
                                    storage: storage, backend: backend, gate: gate, wording: wording, at: now
                                )
                            }
                            return (index, outcome)
                        }
                        next += 1
                    }
                }
                return found
            }
        }
        result.sources = sources.indices.compactMap { outcomes[$0] }
        logger.notice("Drafted \(result.addedCount) card(s) from \(result.sources.count) source(s), \(result.ungroundedCount) not grounded, \(result.sampledTitles.count) sampled, \(result.failures.count) failed")
        for failed in result.failures {
            logger.notice("Card drafting failed for \(failed.sourceID, privacy: .public): \(failed.failure ?? "", privacy: .public)")
        }
        return result
    }

    /// One source: its free cards, then the model's, through the wording
    /// gate, saved to its deck in one append. A model call that fails leaves
    /// the free cards to land; a cancelled one saves nothing for the source.
    /// A check of the wording that cannot be made — no model, a failed call,
    /// today's background limit — saves nothing either: the seeds are offered
    /// again on the next run, and no card is saved unchecked.
    private static func draftOne(
        _ plan: CardDraftingSourcePlan,
        system: String,
        route: CardDraftingRoute,
        isRequested: Bool,
        storage: StorageService,
        backend: any CardDraftingBackend,
        gate: CardDraftingSpendGate,
        wording: any CardWordingBackend,
        at now: Date
    ) async throws -> CardDraftingSourceOutcome {
        var outcome = CardDraftingSourceOutcome(sourceID: plan.source.sourceID, title: plan.source.title)
        outcome.isSampled = plan.isSampled
        var drafts = CardDraftingAnswer.freeDrafts(plan, isRequested: isRequested, at: now)
        let freeIDs = Set(drafts.map(\.id))
        if plan.callsModel {
            if await gate.allowsSpend() {
                do {
                    let cards = try await backend.draftCards(
                        system: system,
                        user: plan.user,
                        maxTokens: plan.maxTokens,
                        source: AIUsageSource(
                            id: plan.source.sourceID,
                            type: plan.source.sourceType,
                            title: plan.source.title
                        ),
                        route: route
                    )
                    // A provider that answered after a stop must not land
                    // cards the learner gave up on.
                    try Task.checkCancellation()
                    let answer = CardDraftingAnswer.drafts(cards, plan: plan, isRequested: isRequested, at: now)
                    drafts += answer.drafts
                    outcome.notSaved += answer.refused
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    outcome.failure = error.localizedDescription
                }
            } else {
                outcome.failure = "Not drafted: today's background AI limit is reached."
                outcome.waitsForSpend = true
            }
        }
        guard !drafts.isEmpty else { return outcome }
        try Task.checkCancellation()
        // Every card stands on its own before it is saved.
        guard await gate.allowsSpend() else {
            outcome.failure = "Not saved: today's background AI limit is reached, so the cards' wording could not be checked."
            outcome.waitsForSpend = true
            return outcome
        }
        do {
            let screened = try await CardWordingGate.screen(
                drafts: drafts,
                sourceTitle: plan.source.title,
                usage: AIUsageSource(id: plan.source.sourceID, type: plan.source.sourceType, title: plan.source.title),
                backend: wording
            )
            try Task.checkCancellation()
            drafts = screened.passed
            outcome.notSaved += screened.refused
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            outcome.failure = "Not saved: the cards' wording could not be checked. \(error.localizedDescription)"
            return outcome
        }
        guard !drafts.isEmpty else { return outcome }
        do {
            let saved = try await storage.saveCardDrafts(drafts, sourceID: plan.source.sourceID, sourceTitle: plan.source.title)
            outcome.added = saved.added
            outcome.alreadyDrafted = saved.alreadyDrafted.count
            outcome.ungrounded = saved.ungrounded
            outcome.notSaved += saved.unreadable.map {
                CardDraftingAnswer.Refused(front: $0.front, reason: "A line of its answer reads as a heading or as the card's own metadata.")
            }
            outcome.freeCount = saved.added.filter { freeIDs.contains(saved.givenID(of: $0)) }.count
        } catch {
            outcome.failure = error.localizedDescription
        }
        return outcome
    }

    /// Runs `work` after every earlier piece of work on `key` has ended, so
    /// two requests never draft one source at once: the second reads the
    /// deck the first appended to, and two appends never race for one
    /// deck's revision. Cancelling the caller cancels the work.
    private func inLane<T: Sendable>(
        _ key: String,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let previous = lanes[key]
        let task = Task<T, Error> {
            await previous?.value
            try Task.checkCancellation()
            return try await work()
        }
        let marker = Task<Void, Never> { _ = await task.result }
        lanes[key] = marker
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        if lanes[key] == marker { lanes[key] = nil }
        return try result.get()
    }

    /// Whether a source is being drafted now, by any request.
    func isDrafting(_ sourceID: String) -> Bool {
        lanes[sourceID] != nil
    }
}
