import Foundation
import Testing
@testable import ForeverLM

// Memory as cards, stage six: cards drafted in the background as the learner
// finishes sources, and the corner card that says they wait. The rules are
// pure and pinned first — the day's limit, the candidates and their order,
// what of a source the learner met, the corner card's visibility — then the
// pass over a store of its own with a canned drafter: the triggers, the
// limit counted in decks created today, the gate, no redraft, a failure
// remembered, and the day close that runs it. Every store and defaults suite
// is a test's own.

// MARK: - Fixtures

private let mitoText = """
Mitochondria couple respiration to ATP synthesis through a proton gradient across the inner membrane.
Uncoupling proteins let protons leak back without making ATP, and the energy is released as heat.
Complex I pumps four protons for each NADH it oxidizes, and complex IV reduces oxygen to water.
"""

/// A route with no window and a price, in no catalog, so nothing trims it.
private func testRoute() -> CardDraftingRoute {
    CardDraftingRoute(
        writing: NotebookWritingRoute(
            provider: .openRouter,
            model: "test/card-drafter",
            writerInputBudget: nil,
            condenserInputBudget: nil,
            inputUSDPerMillion: 100,
            outputUSDPerMillion: 200
        ),
        inputBudget: { _ in nil }
    )
}

/// The drafter's turns, and the cards a test hands back for them.
private final class TurnRecorder: CardDraftingBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var storedTurns: [String] = []
    private let answer: @Sendable (String) throws -> [CardDraftingModelCard]

    init(_ answer: @escaping @Sendable (String) throws -> [CardDraftingModelCard]) {
        self.answer = answer
    }

    var turns: [String] { lock.withLock { storedTurns } }

    func draftCards(system: String, user: String, maxTokens: Int, source: AIUsageSource, route: CardDraftingRoute) async throws -> [CardDraftingModelCard] {
        lock.withLock { storedTurns.append(user) }
        return try answer(user)
    }
}

private struct DrafterDown: Error, LocalizedError {
    var errorDescription: String? { "The drafter is down." }
}

/// The card the canned drafter writes for a source: on its first sentence.
private let respirationCard = CardDraftingModelCard(
    front: "What couples respiration to ATP synthesis?",
    back: "A proton gradient across the inner membrane.",
    quote: "couple respiration to ATP synthesis through a proton gradient",
    seed: "I1"
)

/// A store of its own and a defaults suite of its own, so nothing reaches
/// the host's.
private func makeStorage() throws -> (StorageService, UserDefaults, () -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AutoCards_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "foreverlm-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    return (StorageService(storeRoot: root), defaults, {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    })
}

/// A ready article with mitoText, read at `readAt` when given, with two
/// ideas whose text already matches it (so the day close extracts nothing):
/// one on its first sentence, one on its last.
private func seedSource(
    _ id: String,
    title: String = "Mitochondria",
    readAt: Date?,
    on storage: StorageService
) async throws {
    var article = StudioArticle(url: "https://example.com/\(id)", title: title, sourceType: .article, id: id)
    article.content = mitoText
    article.wordCount = 50
    article.state = .ready
    article.readAt = readAt
    try await storage.saveSource(article)
    let hash = PaperContentPreparationService.sha256(mitoText)
    let made = readAt ?? Date()
    let ideas = [
        SourceIdea(
            id: SourceIdea.id(sourceID: id, contentHash: hash, index: 0),
            sourceID: id,
            statement: "A proton gradient couples respiration to ATP synthesis.",
            recallNote: "",
            anchors: [SourceIdeaAnchor(quote: "couple respiration to ATP synthesis through a proton gradient")],
            contentHash: hash,
            sortIndex: 0,
            createdAt: made,
            updatedAt: made
        ),
        SourceIdea(
            id: SourceIdea.id(sourceID: id, contentHash: hash, index: 1),
            sourceID: id,
            statement: "Complex IV reduces oxygen to water.",
            recallNote: "",
            anchors: [SourceIdeaAnchor(quote: "complex IV reduces oxygen to water")],
            contentHash: hash,
            sortIndex: 1,
            createdAt: made,
            updatedAt: made
        ),
    ]
    try await storage.replaceSourceIdeas(sourceID: id, contentHash: hash, ideas: ideas)
}

private func pass(
    _ storage: StorageService,
    _ defaults: UserDefaults,
    drafter: any CardDraftingBackend,
    newCardsPerDay: Int = 10,
    isOn: Bool = true,
    neededSoon: Set<String> = [],
    spendAllowed: @escaping @Sendable () async -> Bool = { true }
) -> AutomaticCardDraftingPass {
    AutomaticCardDraftingPass(
        storage: storage,
        backend: drafter,
        route: { testRoute() },
        spendAllowed: spendAllowed,
        isOn: { isOn },
        newCardsPerDay: { newCardsPerDay },
        neededSoonSourceIDs: { neededSoon },
        defaults: defaults
    )
}

private func cardsToCheck(_ storage: StorageService, _ defaults: UserDefaults) async throws -> [MemoryCardToCheck] {
    try await storage.memoryCardReviewSnapshot(
        now: Date(), budgetMinutes: nil, newPerDay: 10, deadlines: [], scope: nil,
        includesListings: false, includesToCheck: true, stateDefaults: defaults
    ).toCheck
}

private func candidate(
    _ id: String,
    consumedDaysAgo: Double = 0,
    isFinished: Bool = true,
    annotations: Int = 0,
    seconds: Double = 0,
    depth: Double = 1,
    chatDiscussed: Bool = false,
    ideas: Int = 3,
    hasDeck: Bool = false,
    neededSoon: Bool = false,
    wideChat: Bool = false,
    now: Date
) -> AutomaticCardDrafting.Candidate {
    AutomaticCardDrafting.Candidate(
        sourceID: id,
        deckSourceID: id,
        title: id,
        consumedAt: now.addingTimeInterval(-consumedDaysAgo * 86_400),
        isFinished: isFinished,
        engagement: CohortEngagement(
            engagedSeconds: seconds,
            depth: depth,
            chatDiscussedAt: chatDiscussed ? now : nil,
            annotationCount: annotations
        ),
        confidence: isFinished ? .complete : .substantial,
        ideaCount: ideas,
        hasDeck: hasDeck,
        isNeededSoon: neededSoon,
        reach: .whole,
        isWideChatDiscussed: wideChat
    )
}

private func draftToCheck(_ id: String, source: String, requested: Bool = false, origin: MemoryCardOrigin = .drafted) -> MemoryCardToCheck {
    MemoryCardToCheck(
        kind: .draft,
        face: MemoryCard(cardID: id, front: "Q \(id)", back: "A \(id)", origin: origin),
        deckID: MemoryCard.draftDeckID(sourceID: source),
        sourceID: source,
        quote: "a passage",
        seed: nil,
        ideaID: nil,
        draftedAt: Date(),
        isRequested: requested,
        memoryItemID: nil
    )
}

// MARK: - The pure rules

@Suite("Memory cards: drafting in the background", .cardWordingPasses)
struct AutomaticCardDraftingTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("The day's sources fill its new cards at four a source, at least one; ten new cards is three sources")
    func dailyLimit() {
        #expect(AutomaticCardDrafting.dailySourceLimit(newCardsPerDay: 10) == 3)
        #expect(AutomaticCardDrafting.dailySourceLimit(newCardsPerDay: 4) == 1)
        #expect(AutomaticCardDrafting.dailySourceLimit(newCardsPerDay: 5) == 2)
        #expect(AutomaticCardDrafting.dailySourceLimit(newCardsPerDay: 1) == 1)
        #expect(AutomaticCardDrafting.dailySourceLimit(newCardsPerDay: 0) == 1, "clamped to one card")
        #expect(AutomaticCardDrafting.dailySourceLimit(newCardsPerDay: 100) == 25)
        #expect(AutomaticCardDrafting.dailySourceLimit(newCardsPerDay: 500) == 25, "clamped to a hundred cards")
    }

    @Test("The day's count is decks created today, by the local calendar, none from the future")
    func decksCreatedToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12))!
        let created = [
            noon.addingTimeInterval(-3_600),        // this morning
            noon.addingTimeInterval(-13 * 3_600),   // last night
            noon.addingTimeInterval(3_600),         // clock skew
        ]
        #expect(AutomaticCardDrafting.decksCreatedToday(created, now: noon, calendar: calendar) == 1)
    }

    @Test("A candidate is finished or annotated, inside ten days, with ideas and no deck; a chat's citations alone never are")
    func exclusions() {
        #expect(AutomaticCardDrafting.exclusion(candidate("read", now: now), now: now) == nil)
        #expect(AutomaticCardDrafting.exclusion(candidate("marked", isFinished: false, annotations: 2, depth: 0.4, now: now), now: now) == nil)
        #expect(AutomaticCardDrafting.exclusion(candidate("cited", isFinished: false, depth: 0, chatDiscussed: true, now: now), now: now) == .notFinished)
        #expect(AutomaticCardDrafting.exclusion(candidate("half", isFinished: false, depth: 0.7, now: now), now: now) == .notFinished)
        #expect(AutomaticCardDrafting.exclusion(candidate("old", consumedDaysAgo: 11, now: now), now: now) == .outsideWindow)
        #expect(AutomaticCardDrafting.exclusion(candidate("tenth", consumedDaysAgo: 10.5, now: now), now: now) == nil, "ten whole days is still inside")
        #expect(AutomaticCardDrafting.exclusion(candidate("bare", ideas: 0, now: now), now: now) == .noIdeas)
        #expect(AutomaticCardDrafting.exclusion(candidate("decked", hasDeck: true, now: now), now: now) == .hasDeck)
    }

    @Test("A chat that discussed ten sources or more makes each of them a candidate within the window; a narrower or older one makes none")
    func wideChats() {
        let wide = (1...10).map { "w\($0)" }
        let narrow = (1...9).map { "n\($0)" }
        let chats = [
            KnowledgeStore.ChatDiscussion(sessionID: "wide", at: now.addingTimeInterval(-86_400), sourceIDs: Set(wide)),
            KnowledgeStore.ChatDiscussion(sessionID: "narrow", at: now, sourceIDs: Set(narrow)),
            KnowledgeStore.ChatDiscussion(sessionID: "old", at: now.addingTimeInterval(-12 * 86_400), sourceIDs: Set((1...12).map { "o\($0)" })),
            KnowledgeStore.ChatDiscussion(sessionID: "future", at: now.addingTimeInterval(3_600), sourceIDs: Set((1...12).map { "f\($0)" })),
        ]
        #expect(AutomaticCardDrafting.wideChatSourceIDs(chats, now: now) == Set(wide))

        let cited = candidate("w1", isFinished: false, depth: 0, chatDiscussed: true, wideChat: true, now: now)
        #expect(AutomaticCardDrafting.exclusion(cited, now: now) == nil)
        let undiscussed = candidate("w2", isFinished: false, depth: 0, chatDiscussed: true, ideas: 0, wideChat: true, now: now)
        #expect(AutomaticCardDrafting.exclusion(undiscussed, now: now) == .noIdeas, "no idea the chat engaged, nothing to draft")

        // Inside the day's existing limit, behind the sources the learner finished.
        let plan = AutomaticCardDrafting.plan(
            [cited, candidate("read", seconds: 600, now: now)],
            decksCreatedToday: 0, limit: 1, now: now
        )
        #expect(plan.draft.map(\.sourceID) == ["read"])
        #expect(plan.waiting == 1)
    }

    @Test("A source only a wide chat brings is drafted from exactly the ideas its chats engaged, and from none when none was recorded")
    func discussedReach() {
        let first = SourceIdea(id: "i1", sourceID: "s", statement: "One", recallNote: "", contentHash: "h", sortIndex: 0)
        let second = SourceIdea(id: "i2", sourceID: "s", statement: "Two", recallNote: "", contentHash: "h", sortIndex: 1)
        #expect(CardDraftingReach.discussed(ideas: [first, second], discussedIdeaIDs: ["i2", "gone"]).ideaIDs == ["i2"])
        #expect(CardDraftingReach.discussed(ideas: [first, second], discussedIdeaIDs: []).ideaIDs == [])
        #expect(!CardDraftingReach.discussed(ideas: [first, second], discussedIdeaIDs: []).isWhole)
    }

    @Test("Needed soon first, then annotated, then time × depth, then the most recently consumed")
    func ranking() {
        let ranked = AutomaticCardDrafting.ranked([
            candidate("long", seconds: 3_600, now: now),
            candidate("recent", consumedDaysAgo: 0, now: now),
            candidate("older", consumedDaysAgo: 2, now: now),
            candidate("annotated", annotations: 1, now: now),
            candidate("needed", consumedDaysAgo: 5, neededSoon: true, now: now),
        ])
        #expect(ranked.map(\.sourceID) == ["needed", "annotated", "long", "recent", "older"])
    }

    @Test("A run takes the day's slots left after the decks created today; the rest wait and roll forward; a finish drafts only its own source")
    func planningTheDay() {
        let candidates = (1...5).map { candidate("s\($0)", seconds: Double(100 * $0), now: now) }
        let morning = AutomaticCardDrafting.plan(candidates, decksCreatedToday: 0, limit: 3, now: now)
        #expect(morning.draft.map(\.sourceID) == ["s5", "s4", "s3"])
        #expect(morning.waiting == 2)
        #expect(morning.slots == 3)

        let evening = AutomaticCardDrafting.plan(candidates, decksCreatedToday: 2, limit: 3, now: now)
        #expect(evening.draft.map(\.sourceID) == ["s5"], "two of the day's three are used already")
        #expect(evening.waiting == 4)

        let full = AutomaticCardDrafting.plan(candidates, decksCreatedToday: 3, limit: 3, now: now)
        #expect(full.draft.isEmpty)
        #expect(full.waiting == 5)

        let finish = AutomaticCardDrafting.plan(candidates, decksCreatedToday: 0, limit: 3, only: ["s1"], now: now)
        #expect(finish.draft.map(\.sourceID) == ["s1"], "the finished source, whatever its rank")
        #expect(finish.waiting == 4)

        let failed = AutomaticCardDrafting.plan(candidates, decksCreatedToday: 0, limit: 3, failed: ["s5"], now: now)
        #expect(failed.draft.map(\.sourceID) == ["s4", "s3", "s2"], "a source that failed today waits out its retry")
        #expect(failed.waiting == 1)

        var twins = candidates
        twins.append(AutomaticCardDrafting.Candidate(
            sourceID: "team-copy-of-s5", deckSourceID: "s5", title: "s5", consumedAt: now, isFinished: true,
            engagement: CohortEngagement(engagedSeconds: 900, depth: 1), confidence: .complete,
            ideaCount: 2, hasDeck: false, isNeededSoon: false, reach: .whole
        ))
        let deduped = AutomaticCardDrafting.plan(twins, decksCreatedToday: 0, limit: 10, now: now)
        #expect(deduped.draft.filter { $0.deckSourceID == "s5" }.count == 1, "a team copy and its source are one deck")
    }

    @Test("What still waits is the sources eligible now: one that has a deck since drops out, whatever the last run recorded")
    func waitingIsRecounted() {
        let candidates = (1...5).map { candidate("s\($0)", seconds: Double(100 * $0), now: now) }
        // The corner card recounts with no slots, so every eligible source waits.
        #expect(AutomaticCardDrafting.plan(candidates, decksCreatedToday: 0, limit: 0, now: now).waiting == 5)
        let since = candidates.map { $0.deckSourceID == "s2" || $0.deckSourceID == "s3" ? candidate($0.sourceID, hasDeck: true, now: now) : $0 }
        #expect(AutomaticCardDrafting.plan(since, decksCreatedToday: 0, limit: 0, now: now).waiting == 3)
        #expect(AutomaticCardDrafting.plan(since, decksCreatedToday: 0, limit: 0, failed: ["s5"], now: now).waiting == 2)
    }

    @Test("What of a source the learner met: whole when finished, a chat-only source's discussed ideas, a part read's ideas up to where they stopped")
    func reach() {
        let hash = "h"
        let first = SourceIdea(id: "i1", sourceID: "s", statement: "One", recallNote: "", contentHash: hash, sortIndex: 0)
        let second = SourceIdea(id: "i2", sourceID: "s", statement: "Two", recallNote: "", contentHash: hash, sortIndex: 1)
        let finished = CardDraftingReach.of(
            isFinished: true, engagement: CohortEngagement(depth: 1), confidence: .complete,
            ideas: [first, second], discussedIdeaIDs: []
        )
        #expect(finished.isWhole)

        // A chat's lift and an annotation's together read as complete, which
        // the review does not call chat-only: how far they read narrows it.
        let lifted = CardDraftingReach.of(
            isFinished: false, engagement: CohortEngagement(depth: 0.1, chatDiscussedAt: now, annotationCount: 1),
            confidence: .complete, ideas: [first, second], discussedIdeaIDs: ["i2"]
        )
        #expect(lifted.ideaIDs == nil)
        #expect(lifted.readThrough == 0.1)
        let discussed = CardDraftingReach.of(
            isFinished: false, engagement: CohortEngagement(depth: 0.1, chatDiscussedAt: now, annotationCount: 1),
            confidence: .substantial, ideas: [first, second], discussedIdeaIDs: ["i2"]
        )
        #expect(discussed.ideaIDs == ["i2"])
        #expect(discussed.readThrough == nil, "a chat is the evidence; how far they read does not narrow it")
        let undiscussed = CardDraftingReach.of(
            isFinished: false, engagement: CohortEngagement(depth: 0.1, chatDiscussedAt: now, annotationCount: 1),
            confidence: .substantial, ideas: [first, second], discussedIdeaIDs: []
        )
        #expect(undiscussed.ideaIDs == ["i1", "i2"], "nothing recorded keeps every idea, as the review grades it")

        let partial = CardDraftingReach.of(
            isFinished: false, engagement: CohortEngagement(depth: 0.4, annotationCount: 1),
            confidence: .substantial, ideas: [first, second], discussedIdeaIDs: []
        )
        #expect(partial.readThrough == 0.4)
        let positions = ["i1": 0.1, "i2": 0.8]
        #expect(partial.ideas([first, second]) { positions[$0.id] }.map(\.id) == ["i1"])
        #expect(partial.ideas([first, second]) { _ in nil }.isEmpty, "an idea its text does not print is not known to be met")
    }

    @Test("Within reach a source has no free cards, a card a seed at most, the turn says so, and a card naming no seed is refused")
    func narrowedDrafting() throws {
        let seed = CardDraftingSeed.ideas([
            SourceIdea(id: "i1", sourceID: "s", statement: "A proton gradient couples respiration to ATP synthesis.", recallNote: "", contentHash: "h", sortIndex: 0),
        ])
        let source = CardDraftingSource(
            sourceID: "s", requestedID: "s", title: "Mitochondria", sourceType: "article", kindLabel: "article",
            text: mitoText, seeds: seed, coveredFronts: [], exemplars: [], isOpened: true,
            reach: CardDraftingReach(readThrough: 0.4)
        )
        let request = CardDraftingRequest(notebookID: nil, sourceIDs: ["s"], count: .auto, focus: nil, trigger: .automatic)
        let plan = CardDraftingPlanner.plan(request: request, sources: [source], skipped: [], notebookExemplars: [], route: testRoute(), system: "system")
        let sourcePlan = try #require(plan.sources.first)
        #expect(sourcePlan.free.isEmpty)
        #expect(sourcePlan.modelCards == 1, "one seed, one card")
        #expect(sourcePlan.user.contains(CardDraftingTurn.onlySeedsLine))

        let answer = CardDraftingAnswer.drafts([
            CardDraftingModelCard(front: "What does complex IV reduce?", back: "Oxygen.", quote: "complex IV reduces oxygen to water"),
            respirationCard,
        ], plan: sourcePlan, isRequested: false, at: now)
        #expect(answer.drafts.map(\.front) == ["What couples respiration to ATP synthesis?"])
        #expect(answer.refused.count == 1)
        #expect(answer.drafts.allSatisfy { !$0.isRequested }, "background drafts are opt-in")

        let whole = CardDraftingPlanner.plan(
            request: request,
            sources: [CardDraftingSource(
                sourceID: "s", requestedID: "s", title: "Mitochondria", sourceType: "article", kindLabel: "article",
                text: mitoText, seeds: seed, coveredFronts: [], exemplars: [], isOpened: true
            )],
            skipped: [], notebookExemplars: [], route: testRoute(), system: "system"
        )
        #expect(whole.sources.first?.user.contains(CardDraftingTurn.onlySeedsLine) == false)
        #expect(whole.sources.first?.modelCards == MemoryCardRequestCount.autoPerSource)
    }

    @Test("The corner card counts only the drafts ForeverLM made unasked, and says how many sources")
    func pileAndDetail() throws {
        let toCheck = [
            draftToCheck("a", source: "s1"),
            draftToCheck("b", source: "s1"),
            draftToCheck("c", source: "s2"),
            draftToCheck("asked", source: "s3", requested: true),
            draftToCheck("assistant", source: "s4", origin: .assistant),
        ]
        let pile = try #require(CardsToCheckNudge.pile(toCheck))
        #expect(pile.cardCount == 3)
        #expect(pile.sourceIDs == ["s1", "s2"])
        #expect(CardsToCheckNudge.detail(pile, waiting: 0) == "3 from 2 sources you finished")
        #expect(CardsToCheckNudge.detail(pile, waiting: 2) == "3 from 2 sources you finished · 2 more sources to come")
        #expect(CardsToCheckNudge.detail(CardsToCheckNudge.Pile(cardCount: 4, sourceIDs: ["s"]), waiting: 1)
            == "4 from a source you finished · 1 more source to come")
        #expect(CardsToCheckNudge.pile([draftToCheck("asked", source: "s3", requested: true)]) == nil)
    }

    @Test("The corner card waits for drafts, its switch, the next day after ×, and stays off the review, Getting Started, Plan your day? and the Reader on one of its sources")
    func cornerCardVisibility() {
        let pile = CardsToCheckNudge.Pile(cardCount: 5, sourceIDs: ["s1", "s2"])
        func shown(
            pile: CardsToCheckNudge.Pile? = pile,
            nudges: Bool = true,
            putOff: String? = nil,
            focused: Bool = false,
            gettingStarted: Bool = false,
            planTheDay: Bool = false,
            reader: Set<String> = []
        ) -> Bool {
            CardsToCheckNudge.isShown(
                pile: pile, showsNudges: nudges, putOffDay: putOff, today: "2026-10-01",
                isMemoryReviewFocused: focused, isGettingStarted: gettingStarted,
                asksToPlanTheDay: planTheDay, readerSourceIDsOnScreen: reader
            )
        }
        #expect(shown())
        #expect(!shown(pile: nil))
        #expect(!shown(nudges: false), "Don't Ask Again")
        #expect(!shown(putOff: "2026-10-01"), "× is later")
        #expect(shown(putOff: "2026-09-30"), "and asks again the next day")
        #expect(!shown(focused: true))
        #expect(!shown(gettingStarted: true))
        #expect(!shown(planTheDay: true), "one corner card at a time")
        #expect(!shown(reader: ["s2"]), "the Reader's toolbar says it already")
        #expect(shown(reader: ["other"]))
    }

    @Test("The card also counts the library's sources no card covers: alone it is titled for them, with drafts it adds a clause, and a source whose drafts wait is not counted twice")
    func uncoveredSources() throws {
        let drafts = CardsToCheckNudge.Pile(cardCount: 4, sourceIDs: ["s1"])
        #expect(CardsToCheckNudge.pile(drafts: nil, uncovered: []) == nil)
        #expect(CardsToCheckNudge.pile(drafts: drafts, uncovered: []) == drafts)

        let both = try #require(CardsToCheckNudge.pile(drafts: drafts, uncovered: ["s1", "u1", "u2"]))
        #expect(both.uncoveredSourceIDs == ["u1", "u2"])
        #expect(both.allSourceIDs == ["s1", "u1", "u2"])
        #expect(CardsToCheckNudge.heading(both) == "Cards to check")
        #expect(CardsToCheckNudge.detail(both, waiting: 0) == "4 from a source you finished · 2 sources have no cards yet")
        #expect(CardsToCheckNudge.detail(both, waiting: 1)
            == "4 from a source you finished · 1 more source to come · 2 sources have no cards yet")

        let alone = try #require(CardsToCheckNudge.pile(drafts: nil, uncovered: ["u1", "u2", "u3"]))
        #expect(!alone.hasDrafts)
        #expect(CardsToCheckNudge.heading(alone) == "Sources without cards")
        #expect(CardsToCheckNudge.detail(alone, waiting: 3) == "3 sources have no cards yet")
        let one = try #require(CardsToCheckNudge.pile(drafts: nil, uncovered: ["u1"]))
        #expect(CardsToCheckNudge.detail(one, waiting: 0) == "A source has no cards yet")

        func shown(_ pile: CardsToCheckNudge.Pile?, reader: Set<String> = []) -> Bool {
            CardsToCheckNudge.isShown(
                pile: pile, showsNudges: true, putOffDay: nil, today: "2026-10-16",
                isMemoryReviewFocused: false, isGettingStarted: false,
                asksToPlanTheDay: false, readerSourceIDsOnScreen: reader
            )
        }
        #expect(shown(alone), "sources without cards are enough for the card")
        #expect(shown(alone, reader: ["u1"]), "the Reader's toolbar says nothing about a source with no cards")
        #expect(!shown(both, reader: ["s1"]), "but it does about one whose drafts wait")
    }

    @Test("A failure is remembered for a day and cleared by a success; the last run's waiting count is today's only")
    func failuresAndLastRun() throws {
        let suite = "foreverlm-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AutomaticCardDraftingFailures.record(sourceID: "s1", title: "One", message: "down", now: now, defaults: defaults)
        #expect(AutomaticCardDraftingFailures.recent(now: now.addingTimeInterval(3_600), defaults: defaults).map(\.sourceID) == ["s1"])
        #expect(AutomaticCardDraftingFailures.recent(now: now.addingTimeInterval(25 * 3_600), defaults: defaults).isEmpty)
        AutomaticCardDraftingFailures.clear(sourceID: "s1", defaults: defaults)
        #expect(AutomaticCardDraftingFailures.recent(now: now, defaults: defaults).isEmpty)

        AutomaticCardDraftingRun(at: now, draftedCards: 4, draftedSources: 1, waiting: 3).record(defaults: defaults)
        let run = try #require(AutomaticCardDraftingRun.last(defaults: defaults))
        #expect(run.waiting(asOf: now.addingTimeInterval(3_600)) == 3)
        #expect(run.waiting(asOf: now.addingTimeInterval(2 * 86_400)) == 0)
    }

    @Test("The settings read their defaults until set: ten new cards, drafting off (the learner writes a source's card), the card on")
    func settingsDefaults() throws {
        let suite = "foreverlm-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(MemoryCardSettings.newCardsPerDay(defaults: defaults) == 10)
        #expect(!MemoryCardSettings.autoDraftsCards(defaults: defaults))
        #expect(MemoryCardSettings.showsDraftNudges(defaults: defaults))
        defaults.set(250, forKey: MemoryCardSettings.newCardsPerDayKey)
        #expect(MemoryCardSettings.newCardsPerDay(defaults: defaults) == 100)
        defaults.set(true, forKey: MemoryCardSettings.autoDraftKey)
        #expect(MemoryCardSettings.autoDraftsCards(defaults: defaults))
    }

}

// MARK: - The pass, over storage

@Suite("Memory cards: drafting in the background, over storage", .serialized, .cardWordingPasses)
struct AutomaticCardDraftingPassTests {
    @Test("A finished source with ideas and no deck is drafted, unticked, into To Check; it is never drafted again in the background")
    func finishDraftsOnceThenNever() async throws {
        let (storage, defaults, cleanup) = try makeStorage()
        defer { cleanup() }
        try await seedSource("src-read", readAt: Date().addingTimeInterval(-3_600), on: storage)
        let drafter = TurnRecorder { _ in [respirationCard] }

        let first = await pass(storage, defaults, drafter: drafter).run(only: ["src-read"])
        #expect(first.draftedCards == 1)
        #expect(first.draftedSources == ["Mitochondria"])
        #expect(drafter.turns.count == 1)
        let waiting = try await cardsToCheck(storage, defaults)
        #expect(waiting.map(\.face.front) == ["What couples respiration to ATP synthesis?"])
        #expect(waiting.allSatisfy { !$0.isRequested }, "opt-in: background drafts arrive unticked")
        #expect(CardsToCheckNudge.pile(waiting)?.cardCount == 1)

        // A second finish, the evening, or a re-hash of its text: the source
        // has a deck, so only Make Cards adds to it.
        let again = await pass(storage, defaults, drafter: drafter).run()
        #expect(again.draftedCards == 0)
        #expect(drafter.turns.count == 1, "no call")
    }

    @Test("A source a Make Cards run holds, queued or drafting, is left to that run")
    func sourceHeldByMakeCardsIsLeftToIt() async throws {
        let (storage, defaults, cleanup) = try makeStorage()
        defer { cleanup() }
        try await seedSource("src-read", readAt: Date().addingTimeInterval(-3_600), on: storage)
        let drafter = TurnRecorder { _ in [respirationCard] }

        var held = pass(storage, defaults, drafter: drafter)
        held.isBeingMade = { $0 == "src-read" }
        let report = await held.run(only: ["src-read"])
        #expect(report.draftedCards == 0)
        #expect(drafter.turns.isEmpty, "no second paid call for a source the run will draft")
        #expect(try await cardsToCheck(storage, defaults).isEmpty)
    }

    @Test("Off, nothing is read or drafted; once the gate says no, nothing is sent and the source waits")
    func switchAndGate() async throws {
        let (storage, defaults, cleanup) = try makeStorage()
        defer { cleanup() }
        try await seedSource("src-read", readAt: Date().addingTimeInterval(-3_600), on: storage)
        let drafter = TurnRecorder { _ in [respirationCard] }

        let off = await pass(storage, defaults, drafter: drafter, isOn: false).run()
        #expect(off == AutomaticCardDraftingReport())
        #expect(drafter.turns.isEmpty)

        let asked = Counter()
        let capped = await pass(storage, defaults, drafter: drafter) {
            asked.increment()
            return false
        }.run()
        #expect(drafter.turns.isEmpty, "nothing was sent")
        #expect(asked.value == 1, "asked before the run")
        #expect(capped.waiting == 1)
        #expect(capped.notes.contains { $0.contains("background AI limit") })
        #expect(try await cardsToCheck(storage, defaults).isEmpty)
        #expect(AutomaticCardDraftingFailures.recent(defaults: defaults).isEmpty, "the cap is not a failure")
    }

    @Test("The day's limit counts the decks created today, Make Cards' included; what it leaves waits for another day")
    func limitCountsDecksCreatedToday() async throws {
        let (storage, defaults, cleanup) = try makeStorage()
        defer { cleanup() }
        let read = Date().addingTimeInterval(-3_600)
        try await seedSource("src-a", title: "Alpha", readAt: read, on: storage)
        try await seedSource("src-b", title: "Beta", readAt: read.addingTimeInterval(-60), on: storage)
        try await seedSource("src-c", title: "Gamma", readAt: read.addingTimeInterval(-120), on: storage)
        let drafter = TurnRecorder { _ in [respirationCard] }

        // Four new cards a day is one source a day.
        let evening = await pass(storage, defaults, drafter: drafter, newCardsPerDay: 4).run()
        #expect(evening.draftedSources == ["Alpha"], "the most recently consumed first")
        #expect(evening.waiting == 2)
        #expect(AutomaticCardDraftingRun.last(defaults: defaults)?.waiting == 2)

        let later = await pass(storage, defaults, drafter: drafter, newCardsPerDay: 4).run(only: ["src-b"])
        #expect(later.draftedCards == 0, "today's one source is used")
        #expect(later.waiting == 2)

        // Eight new cards a day is two: one is left today.
        let wider = await pass(storage, defaults, drafter: drafter, newCardsPerDay: 8).run()
        #expect(wider.draftedSources.count == 1)
        #expect(wider.waiting == 1)
        #expect(drafter.turns.count == 2)
    }

    @Test("A source read part way and annotated is drafted from what was met only: its highlight and the ideas in the part read")
    func partReadDraftsWhatWasMet() async throws {
        let (storage, defaults, cleanup) = try makeStorage()
        defer { cleanup() }
        try await seedSource("src-part", readAt: nil, on: storage)
        _ = try await storage.recordScheduledSourceActivity(
            sourceID: "src-part", on: Date().addingTimeInterval(-3_600), kind: .reading, fraction: 0.4, engagedSeconds: 900
        )
        let now = Date()
        try await storage.saveSourceHighlight(SourceHighlight(
            id: "h1", sourceID: "src-part", quote: "Uncoupling proteins let protons leak back", note: "", color: .yellow,
            anchor: ReaderTextAnchor(exact: "Uncoupling proteins let protons leak back"), pdfAnchor: nil, createdAt: now, updatedAt: now
        ))
        let drafter = TurnRecorder { _ in [
            CardDraftingModelCard(front: "What does complex IV reduce?", back: "Oxygen, to water.", quote: "complex IV reduces oxygen to water"),
            respirationCard,
            CardDraftingModelCard(front: "What do uncoupling proteins do?", back: "Let protons leak back.",
                                  quote: "Uncoupling proteins let protons leak back without making ATP", seed: "H1"),
        ] }
        let report = await pass(storage, defaults, drafter: drafter).run()
        let turn = try #require(drafter.turns.first)
        #expect(turn.contains(CardDraftingTurn.onlySeedsLine))
        #expect(turn.contains("A proton gradient couples respiration to ATP synthesis."))
        #expect(!turn.contains("Complex IV reduces oxygen to water."), "an idea past where they stopped is not offered")
        #expect(report.draftedCards == 2, "the card that names no seed is not offered")
        let fronts = Set(try await cardsToCheck(storage, defaults).map(\.face.front))
        #expect(fronts == ["What couples respiration to ATP synthesis?", "What do uncoupling proteins do?"])
    }

    @Test("A source that fails is remembered for a day, not tried again, and named by the day close's run")
    func failureIsRemembered() async throws {
        let (storage, defaults, cleanup) = try makeStorage()
        defer { cleanup() }
        try await seedSource("src-read", readAt: Date().addingTimeInterval(-3_600), on: storage)
        let down = TurnRecorder { _ in throw DrafterDown() }

        let finish = await pass(storage, defaults, drafter: down).run(only: ["src-read"])
        #expect(finish.failures == [AutomaticCardDraftingPass.failureLine(title: "Mitochondria", reason: "The drafter is down.")])
        #expect(AutomaticCardDraftingFailures.recent(defaults: defaults).map(\.sourceID) == ["src-read"])

        let evening = await pass(storage, defaults, drafter: down).run()
        #expect(down.turns.count == 1, "not billed again today")
        #expect(evening.failures == finish.failures, "the evening's status line names it")
    }

}

/// A count a `@Sendable` closure can bump.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
