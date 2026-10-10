import Foundation
import OSLog

/// What one background drafting run did, for the day close's receipt, the
/// corner card and `get_memory_review_settings`.
struct AutomaticCardDraftingReport: Equatable, Sendable {
    /// Cards added to To Check this run.
    var draftedCards = 0
    /// The sources they were drafted from, by title.
    var draftedSources: [String] = []
    /// Candidates the day's limit left for another day.
    var waiting = 0
    /// What waits, not failed: the daily background AI limit, or no model.
    var notes: [String] = []
    /// Sources that could not be drafted, by name, with why: remembered for
    /// a day (`AutomaticCardDraftingFailures`).
    var failures: [String] = []
}

/// Drafts cards in the background as the learner finishes sources
/// (docs/memory-design.md, "Drafting in the background"; decisions v5, 3).
///
/// Two triggers run it: a deliberate finish on this Mac (`only` that source:
/// Mark as Read, an article read to its end, listening or watching logged
/// complete) and the day close (every candidate, ranked). Both read the same
/// facts — the cohort's candidates of the last ten days that have ideas and
/// no draft deck, and the decks created today — so a source drafted when it
/// was finished uses up one of the day's sources, and the evening fills what
/// is left; a source the limit leaves out is a candidate again tomorrow, for
/// ten days. Drafting goes through the one `CardDraftingService`, which
/// drafts one source at a time per source: a Make Cards and a background run
/// never draft one source at once. A source with a deck is never drafted in
/// the background, so a re-hash of its text never redrafts it.
///
/// Background spend, on the learner's Card Drafting route: nothing runs while
/// `memory.auto_draft_cards` is off, nothing is drafted once the daily
/// background AI limit says no (asked before the run and before every model
/// call), and a day's sources are bounded by `memory.new_cards_per_day`.
///
/// `@unchecked` for its `UserDefaults` alone, which Foundation documents as
/// safe to use from any thread; every other stored property is Sendable.
struct AutomaticCardDraftingPass: @unchecked Sendable {
    let storage: StorageService
    let backend: any CardDraftingBackend
    /// The learner's Card Drafting route now; nil when none is configured.
    let route: @Sendable () -> CardDraftingRoute?
    /// Whether background AI may spend now (`StudioViewModel.backgroundAISpendAllowed`).
    let spendAllowed: @Sendable () async -> Bool
    /// `memory.auto_draft_cards`.
    let isOn: @Sendable () -> Bool
    /// `memory.new_cards_per_day`, which sets the day's sources.
    let newCardsPerDay: @Sendable () -> Int
    /// The sources of notebooks needed soon, which rank first.
    let neededSoonSourceIDs: @Sendable () async -> Set<String>
    /// Where the failures, the last run and the cards' state rows are kept.
    let defaults: UserDefaults
    /// Whether a Make Cards run holds the source, queued or drafting
    /// (`CardDraftingCoordinator.isDrafting`). The drafting service sees only
    /// the sources in a lane, and a run's later sources would otherwise be
    /// drafted here first and again by the run, on a plan made before.
    var isBeingMade: @Sendable (String) async -> Bool = { _ in false }

    private static let logger = Logger(subsystem: "com.foreverlm", category: "CardDrafting")

    /// The learner's settings and route on this Mac.
    static func live(
        storage: StorageService,
        spendAllowed: @escaping @Sendable () async -> Bool,
        neededSoonSourceIDs: @escaping @Sendable () async -> Set<String>,
        isBeingMade: @escaping @Sendable (String) async -> Bool
    ) -> AutomaticCardDraftingPass {
        AutomaticCardDraftingPass(
            storage: storage,
            backend: LiveCardDraftingBackend(aiService: AIService()),
            route: { CardDraftingRoute.current() },
            spendAllowed: spendAllowed,
            isOn: { MemoryCardSettings.autoDraftsCards() },
            newCardsPerDay: { MemoryCardSettings.newCardsPerDay() },
            neededSoonSourceIDs: neededSoonSourceIDs,
            defaults: .standard,
            isBeingMade: isBeingMade
        )
    }

    /// One run. `only`, the finish trigger's, drafts those sources when they
    /// are candidates and the day has room; nil, the day close's, drafts the
    /// best ranked candidates the day has room for and names every source
    /// that failed today.
    func run(now: Date = Date(), only: Set<String>? = nil) async -> AutomaticCardDraftingReport {
        var report = await draft(now: now, only: only)
        if only == nil, isOn() { report.failures += namedFailures(now: now) }
        return report
    }

    private func draft(now: Date, only: Set<String>?) async -> AutomaticCardDraftingReport {
        var report = AutomaticCardDraftingReport()
        guard isOn() else { return report }
        let state: AutomaticCardDraftingState
        do {
            state = try await storage.automaticCardDraftingState(now: now, neededSoonSourceIDs: await neededSoonSourceIDs())
        } catch {
            report.failures.append("Cards could not be drafted: \(error.localizedDescription)")
            return report
        }
        // A source a Make Cards run holds, drafting or queued, is left to it.
        var candidates: [AutomaticCardDrafting.Candidate] = []
        for candidate in state.candidates {
            if await CardDraftingService.shared.isDrafting(candidate.deckSourceID) { continue }
            if await isBeingMade(candidate.deckSourceID) { continue }
            if candidate.sourceID != candidate.deckSourceID, await isBeingMade(candidate.sourceID) { continue }
            candidates.append(candidate)
        }
        let failed = Set(AutomaticCardDraftingFailures.recent(now: now, defaults: defaults).map(\.sourceID))
        let plan = AutomaticCardDrafting.plan(
            candidates,
            decksCreatedToday: state.decksCreatedToday,
            limit: AutomaticCardDrafting.dailySourceLimit(newCardsPerDay: newCardsPerDay()),
            failed: failed,
            only: only,
            now: now
        )
        report.waiting = plan.waiting
        guard !plan.draft.isEmpty else {
            record(report, now: now)
            return report
        }
        guard let route = route() else {
            report.waiting += plan.draft.count
            report.notes.append("Cards wait to be drafted: no Card Drafting model is set (Settings › AI Models).")
            return report
        }
        guard await spendAllowed() else {
            report.waiting += plan.draft.count
            report.notes.append(Self.capNote(plan.draft.count))
            return report
        }

        var reach: [String: CardDraftingReach] = [:]
        var deckSourceByID: [String: String] = [:]
        for candidate in plan.draft {
            reach[candidate.sourceID] = candidate.reach
            deckSourceByID[candidate.sourceID] = candidate.deckSourceID
        }
        let request = CardDraftingRequest(
            notebookID: nil,
            sourceIDs: plan.draft.map(\.sourceID),
            count: .auto,
            focus: nil,
            trigger: .automatic,
            reach: reach
        )
        let result: CardDraftingResult
        do {
            result = try await CardDraftingService.shared.draft(
                request,
                storage: storage,
                backend: backend,
                route: route,
                gate: .background(spendAllowed),
                stateDefaults: defaults
            )
        } catch {
            if error is CancellationError || Task.isCancelled { return report }
            report.failures.append("Cards could not be drafted: \(error.localizedDescription)")
            return report
        }

        var capped = 0
        for outcome in result.sources {
            if !outcome.added.isEmpty {
                report.draftedCards += outcome.added.count
                report.draftedSources.append(outcome.title)
                AutomaticCardDraftingFailures.clear(sourceID: outcome.sourceID, defaults: defaults)
            } else if outcome.waitsForSpend {
                capped += 1
            } else {
                let reason = outcome.failure ?? (outcome.ungrounded.isEmpty
                    ? "None of the cards drafted from it could be kept."
                    : "None of the cards drafted from it stood on a passage it prints.")
                remember(outcome.sourceID, title: outcome.title, reason: reason, now: now, into: &report, named: only != nil)
            }
        }
        for skip in result.skipped {
            remember(deckSourceByID[skip.sourceID] ?? skip.sourceID, title: skip.title, reason: skip.reason, now: now, into: &report, named: only != nil)
        }
        if capped > 0 {
            report.waiting += capped
            report.notes.append(Self.capNote(capped))
        }
        record(report, now: now)
        Self.logger.notice("Background drafting added \(report.draftedCards) card(s) from \(report.draftedSources.count) source(s); \(report.waiting) wait")
        return report
    }

    private static func capNote(_ count: Int) -> String {
        count == 1
            ? "Cards for 1 source wait: today's background AI limit is reached."
            : "Cards for \(count) sources wait: today's background AI limit is reached."
    }

    /// A source that could not be drafted is not tried again for a day. The
    /// finish trigger names it in its own report; the day close names every
    /// source that failed today (`namedFailures`).
    private func remember(
        _ sourceID: String,
        title: String,
        reason: String,
        now: Date,
        into report: inout AutomaticCardDraftingReport,
        named: Bool
    ) {
        AutomaticCardDraftingFailures.record(sourceID: sourceID, title: title, message: reason, now: now, defaults: defaults)
        if named { report.failures.append(Self.failureLine(title: title, reason: reason)) }
    }

    private func namedFailures(now: Date) -> [String] {
        AutomaticCardDraftingFailures.recent(now: now, defaults: defaults).map {
            Self.failureLine(title: $0.title, reason: $0.message)
        }
    }

    static func failureLine(title: String, reason: String) -> String {
        "Cards for \u{201C}\(title)\u{201D} could not be drafted: \(reason)"
    }

    private func record(_ report: AutomaticCardDraftingReport, now: Date) {
        AutomaticCardDraftingRun(
            at: now,
            draftedCards: report.draftedCards,
            draftedSources: report.draftedSources.count,
            waiting: report.waiting
        ).record(defaults: defaults)
    }
}
