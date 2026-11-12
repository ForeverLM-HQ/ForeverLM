import Foundation
import Testing
@testable import ForeverLM

// Memory as cards, stage five: cards made on request. The rules are pure and
// pinned first — how many cards a request asks of each source, the seeds and
// what covers them, the learner's decisions as exemplars, the turn, the
// sampling only past the window, the price, what the model's answer becomes —
// then the service over a store of its own with a canned drafter, the window's
// routing, and `draft_cards`. Every store and defaults suite is a test's own;
// the one test that changes a window's panes puts the layout template back.

// MARK: - Fixtures

private let mitoText = """
Mitochondria couple respiration to ATP synthesis through a proton gradient across the inner membrane.
Uncoupling proteins let protons leak back without making ATP, and the energy is released as heat.
Complex I pumps four protons for each NADH it oxidizes, and complex IV reduces oxygen to water.
"""

/// A route with the window and price a test names. The model is in no
/// catalog, so nothing else trims or prices against it.
private func cardRoute(budget: Int? = nil, input: Double? = 100, output: Double? = 200) -> CardDraftingRoute {
    CardDraftingRoute(
        writing: NotebookWritingRoute(
            provider: .openRouter,
            model: "test/card-drafter",
            writerInputBudget: budget,
            condenserInputBudget: budget,
            inputUSDPerMillion: input,
            outputUSDPerMillion: output
        ),
        inputBudget: { _ in budget }
    )
}

/// The drafter's turns, and the cards a test hands back for them.
private final class CannedDrafter: CardDraftingBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var storedTurns: [String] = []
    private let answer: @Sendable (String) -> [CardDraftingModelCard]

    init(_ answer: @escaping @Sendable (String) -> [CardDraftingModelCard]) {
        self.answer = answer
    }

    var turns: [String] {
        lock.withLock { storedTurns }
    }

    func draftCards(system: String, user: String, maxTokens: Int, source: AIUsageSource, route: CardDraftingRoute) async throws -> [CardDraftingModelCard] {
        lock.withLock { storedTurns.append(user) }
        return answer(user)
    }
}

private func source(
    _ id: String = "src-1",
    text: String = mitoText,
    seeds: [CardDraftingSeed] = [],
    covered: [String] = [],
    exemplars: [CardDraftingExemplar] = [],
    isOpened: Bool = true
) -> CardDraftingSource {
    CardDraftingSource(
        sourceID: id, requestedID: id, title: "Mitochondria", sourceType: "article", kindLabel: "article",
        text: text, seeds: seeds, coveredFronts: covered, exemplars: exemplars, isOpened: isOpened
    )
}

private func request(_ ids: [String] = ["src-1"], count: MemoryCardRequestCount = .auto, focus: String? = nil) -> CardDraftingRequest {
    CardDraftingRequest(notebookID: nil, sourceIDs: ids, count: count, focus: focus, trigger: .requested)
}

/// The drafter's fixed instructions as built in, whatever the host's
/// Settings hold.
private let system = Prompts.cardDrafter

/// Storage on a folder of its own holding src-1 (ready, with text), and a
/// defaults suite of its own for the state rows, so nothing reaches the
/// host's.
private func makeStorage() async throws -> (StorageService, UserDefaults, () -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CardDrafting_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let storage = StorageService(storeRoot: root)
    try await storage.saveSource(mitoArticle())
    let suite = "foreverlm-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    return (storage, defaults, {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    })
}

private func mitoArticle(id: String = "src-1") -> StudioArticle {
    var article = StudioArticle(url: "https://example.com/\(id)", title: "Mitochondria", sourceType: .article, discoveryOrigin: .manual, id: id)
    article.normalizedURL = URLNormalizer.normalize(article.url)
    article.content = mitoText
    article.wordCount = 50
    article.state = .ready
    return article
}

/// A walkthrough of src-1: a question first whose passage the source does
/// not print (a seed the model writes a card from), an explanation on a
/// printed passage, then a question that follows it (a card as it stands,
/// with no model call).
private func saveWalkthrough(_ storage: StorageService) async throws {
    let store = try await storage.notebookFilesKnowledgeStore()
    try store.savePaperWalkthrough(PaperWalkthrough(
        sourceID: "src-1",
        sourceSHA256: PaperContentPreparationService.sha256(mitoText),
        title: "Mitochondria",
        steps: [
            PaperWalkthroughStep(
                id: "step-0", kind: .quiz, title: "Leaks", body: "",
                anchor: PaperWalkthroughAnchor(passage: "words this source never printed anywhere"),
                quiz: PaperWalkthroughQuiz(question: "What do uncoupling proteins do?", answer: "They let protons leak back without making ATP.")
            ),
            PaperWalkthroughStep(
                id: "step-1", kind: .explain, title: "Coupling", body: "Respiration and ATP synthesis are coupled.",
                anchor: PaperWalkthroughAnchor(passage: "couple respiration to ATP synthesis through a proton gradient")
            ),
            PaperWalkthroughStep(
                id: "step-2", kind: .quiz, title: "Check", body: "",
                quiz: PaperWalkthroughQuiz(
                    question: "What couples respiration to ATP synthesis?",
                    answer: "A proton gradient across the inner membrane.",
                    keyPoints: ["protons", "the inner membrane"]
                )
            ),
        ],
        author: .assistant
    ))
}

private func cardsToCheck(_ storage: StorageService, _ defaults: UserDefaults) async throws -> [MemoryCardToCheck] {
    try await storage.memoryCardReviewSnapshot(
        now: Date(), budgetMinutes: nil, newPerDay: 10, deadlines: [], scope: nil,
        includesListings: false, includesToCheck: true, stateDefaults: defaults
    ).toCheck
}

private func object(_ json: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

// MARK: - The pure rules

@Suite("Memory cards: drafting on request")
struct CardDraftingTests {

    // MARK: How many

    @Test("Auto asks about four cards a source and at most forty; a number is shared across the sources, the remainder to the opened and the longest")
    func requestCount() {
        #expect(MemoryCardRequestCount.auto.total(sourceCount: 3) == 12)
        #expect(MemoryCardRequestCount.auto.total(sourceCount: 15) == 40)
        #expect(MemoryCardRequestCount.cards(10).total(sourceCount: 2) == 10)
        #expect(MemoryCardRequestCount.cards(400).total(sourceCount: 2) == 40)
        #expect(MemoryCardRequestCount.auto.total(sourceCount: 0) == 0)
        #expect(MemoryCardRequestCount.choices.map(\.label) == ["Auto", "10", "20", "40"])

        let quotas = MemoryCardRequestCount.cards(10).quotas(for: [
            CardDraftingQuotaInput(sourceID: "short-unopened", isOpened: false, length: 100),
            CardDraftingQuotaInput(sourceID: "long-unopened", isOpened: false, length: 9_000),
            CardDraftingQuotaInput(sourceID: "opened", isOpened: true, length: 50),
        ])
        #expect(quotas == ["opened": 4, "long-unopened": 3, "short-unopened": 3])
        let few = MemoryCardRequestCount.cards(2).quotas(for: [
            CardDraftingQuotaInput(sourceID: "a", isOpened: false, length: 10),
            CardDraftingQuotaInput(sourceID: "b", isOpened: true, length: 10),
            CardDraftingQuotaInput(sourceID: "c", isOpened: false, length: 20),
        ])
        #expect(few == ["a": 0, "b": 1, "c": 1], "fewer cards than sources: the opened source, then the longest")
    }

    @Test("draft_cards' count is auto or a number of cards from 1 to 40, and true is no number")
    func requestCountArgument() {
        #expect(MemoryCardRequestCount(argument: nil) == .auto)
        #expect(MemoryCardRequestCount(argument: NSNull()) == .auto)
        #expect(MemoryCardRequestCount(argument: "auto") == .auto)
        #expect(MemoryCardRequestCount(argument: " Auto ") == .auto)
        #expect(MemoryCardRequestCount(argument: "10") == .cards(10))
        #expect(MemoryCardRequestCount(argument: NSNumber(value: 20)) == .cards(20))
        #expect(MemoryCardRequestCount(argument: NSNumber(value: 1)) == .cards(1))
        #expect(MemoryCardRequestCount(argument: "0") == nil)
        #expect(MemoryCardRequestCount(argument: "41") == nil)
        #expect(MemoryCardRequestCount(argument: "ten") == nil)
        #expect(MemoryCardRequestCount(argument: NSNumber(value: true)) == nil)
        #expect(MemoryCardRequestCount(argument: NSNumber(value: 2.5)) == nil)
        #expect(MemoryCardRequestCount.cards(10).argument as? Int == 10)
        #expect(MemoryCardRequestCount.auto.argument as? String == "auto")
    }

    // MARK: Seeds

    @Test("A review guide's questions with strong answers are read from its own shape")
    func guideQuestions() {
        let guide = """
        KEY IDEAS
        1. Coupling

        REVIEW QUESTIONS AND ANSWER GUIDES
        - **Question:** Why does uncoupling release heat?
        - **Strong answer:** Protons flow back without driving the synthase,
          so the gradient's energy is lost as heat.
        - Probe: Which protein lets them back?
        2. Question: What does complex I pump?
           Strong answer: Four protons for each NADH.
        - Question: A question with no answer guide?
        CONNECTION QUESTION
        Tie the two together.
        """
        let pairs = CardDraftingGuide.questions(in: guide)
        #expect(pairs == [
            CardDraftingGuide.Question(
                question: "Why does uncoupling release heat?",
                strongAnswer: "Protons flow back without driving the synthase, so the gradient's energy is lost as heat."
            ),
            CardDraftingGuide.Question(question: "What does complex I pump?", strongAnswer: "Four protons for each NADH."),
        ])
        let seeds = CardDraftingSeed.guideQuestions(in: guide)
        #expect(seeds.map(\.kind) == [.guideQuestion, .guideQuestion])
        #expect(seeds[0].key == CardDraftingSeedKey.guideQuestion("why does  uncoupling release heat?"), "a key ignores case and spacing")
        #expect(seeds[0].question == "Why does uncoupling release heat?")
        #expect(seeds[0].card == nil)
    }

    @Test("A walkthrough question with a passage its source prints is a card as it stands; one without is a seed; Find it is neither")
    func walkSteps() {
        let walk = PaperWalkthrough(
            sourceID: "src-1",
            sourceSHA256: "h",
            title: "Walk",
            steps: [
                PaperWalkthroughStep(id: "s0", kind: .quiz, title: "", body: "", quiz: PaperWalkthroughQuiz(question: "Unprinted?", answer: "No passage.")),
                PaperWalkthroughStep(id: "s1", kind: .explain, title: "", body: "", anchor: PaperWalkthroughAnchor(passage: "the printed passage")),
                PaperWalkthroughStep(id: "s2", kind: .quiz, title: "", body: "", quiz: PaperWalkthroughQuiz(question: "Printed?", answer: "", keyPoints: ["a", "b"])),
                PaperWalkthroughStep(
                    id: "s3", kind: .figure, title: "", body: "",
                    quiz: PaperWalkthroughQuiz(question: "Which panel?", answer: "B.", kind: .find, targetPanel: "B")
                ),
            ],
            author: .assistant
        )
        let seeds = CardDraftingSeed.walkSteps(of: walk) { excerpts in excerpts.first { $0 == "the printed passage" } }
        #expect(seeds.map(\.key) == ["walk-step:s0", "walk-step:s2"])
        #expect(seeds[0].card == nil)
        #expect(seeds[0].text == "Question: Unprinted?\nAnswer: No passage.")
        #expect(seeds[1].card == CardDraftingSeed.Card(front: "Printed?", back: "a\nb", why: nil, quote: "the printed passage"),
                "a question stored without an answer is answered by its key points")
    }

    @Test("Seeds come in their order, and a seed or question the source's cards already hold is not offered again")
    func uncoveredSeeds() {
        let walk = CardDraftingSeed(kind: .walkStep, key: "walk-step:s1", text: "Question: What couples it?", question: "What couples it?")
        let guide = CardDraftingSeed(kind: .guideQuestion, key: "guide:aaa", text: "Question: Why heat?", question: "Why heat?")
        let highlight = CardDraftingSeed(kind: .highlight, key: "highlight:h1", text: "Highlighted: \u{201C}heat\u{201D}")
        let idea = CardDraftingSeed(kind: .idea, key: "idea:bbb", text: "Idea: Complex I pumps protons.", ideaID: "idea-1")
        let all = [walk, guide, highlight, idea, highlight]
        #expect(CardDraftingSeed.uncovered(all, coveredKeys: [], coveredFronts: []).map(\.key)
            == ["walk-step:s1", "guide:aaa", "highlight:h1", "idea:bbb"])
        #expect(CardDraftingSeed.uncovered(all, coveredKeys: ["highlight:h1"], coveredFronts: [Flashcard.normalizedFront("WHAT couples  it?")]).map(\.key)
            == ["guide:aaa", "idea:bbb"], "a seed drafted once, and a question a card asks, are covered")
        #expect(CardDraftingTurn.handles(for: [walk, guide, highlight, idea, guide]).map { $0.handle } == ["W1", "G1", "H1", "I1", "G2"])
    }

    // MARK: Exemplars

    @Test("The learner's decisions become exemplars: edited before and after, then kept, then skipped; the same source's before the notebook's")
    func exemplars() {
        let deck = MemoryCardDraftDeck(
            deckID: "carddeck-src-1",
            sourceID: "src-1",
            deck: FlashcardDeck(title: "Cards", cards: [
                Flashcard(id: "edited", front: "What couples it?", back: "A gradient."),
                Flashcard(id: "kept", front: "What does complex I pump?", back: "Four protons."),
                Flashcard(id: "skipped", front: "Who wrote it?", back: "Someone."),
                Flashcard(id: "waiting", front: "Still a draft?", back: "Yes."),
                Flashcard(id: "unread", front: "Kept, its item unread?", back: "Yes."),
            ])
        )
        let t = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let row = MemoryCardDeckState(cards: [
            "edited": MemoryCardState(status: .kept, memoryItemID: "item-e", updatedAt: t),
            "kept": MemoryCardState(status: .kept, memoryItemID: "item-k", updatedAt: t.addingTimeInterval(1)),
            "skipped": MemoryCardState(status: .skipped, updatedAt: t.addingTimeInterval(2)),
            "waiting": MemoryCardState(status: .draft, updatedAt: t),
            "unread": MemoryCardState(status: .kept, memoryItemID: "item-u", updatedAt: t),
        ])
        let faces: [String: MemoryCard] = [
            "edited": MemoryCard(cardID: "edited", front: "What links respiration to ATP?", back: "The proton gradient.", origin: .drafted),
            "kept": MemoryCard(cardID: "kept", front: "What does complex I pump?", back: "Four protons.", origin: .drafted),
        ]
        let found = CardDraftingExemplars.from(deck: deck, state: row) { cardID, _ in faces[cardID] }
        #expect(found.map(\.kind) == [.edited, .kept, .skipped], "a draft still waiting, and a kept card whose face was not read, are no exemplar")
        #expect(found[0].draftedFront == "What couples it?")
        #expect(found[0].front == "What links respiration to ATP?")
        #expect(found[1].draftedFront == nil)

        let notebook = [CardDraftingExemplar(kind: .edited, sourceID: "src-2", front: "N?", back: "N.", draftedFront: "n?", draftedBack: "n.", decidedAt: t.addingTimeInterval(100))]
        let chosen = CardDraftingExemplars.chosen(sameSource: found, notebook: notebook)
        #expect(chosen.map(\.sourceID) == ["src-1", "src-2", "src-1", "src-1"], "of each kind, the same source's first")

        let turn = CardDraftingTurn.userMessage(
            source: source(), cardCount: 2, focus: "energy", exemplars: chosen, seeds: [], coveredFronts: [],
            text: "Text.", isSampled: false
        )
        #expect(turn.contains("Focus: energy"))
        #expect(turn.contains("- Before: Q: What couples it? A: A gradient.\n  After: Q: What links respiration to ATP? A: The proton gradient."))
        #expect(turn.contains("Kept as drafted:\n- Q: What does complex I pump? A: Four protons."))
        #expect(turn.contains("Not wanted:\n- Q: Who wrote it?"))
        #expect(!turn.contains("Someone."), "a skip says only that the card was not wanted")
        #expect(!turn.contains("Still a draft?"))
        #expect(turn.hasSuffix("Text:\nText."), "the text comes last, after everything that varies less")
    }

    // MARK: The plan

    @Test("The source's whole text is read; only one too long for the window alone is sampled, with the marker, and a model with no window is sent it whole")
    func samplingOnlyOverTheWindow() throws {
        let long = (0..<400).map { "Paragraph \($0) says protons move across the inner membrane in a measured way." }.joined(separator: "\n")
        let whole = CardDraftingPlanner.plan(
            request: request(count: .cards(4)), sources: [source(text: long)], skipped: [], notebookExemplars: [],
            route: cardRoute(budget: nil), system: system
        )
        let read = try #require(whole.sources.first)
        #expect(!read.isSampled)
        #expect(read.user.hasSuffix("Text:\n" + long))
        #expect(!read.user.contains(CardDraftingSampling.marker))
        #expect(whole.sampledTitles.isEmpty)

        let roomy = CardDraftingPlanner.plan(
            request: request(count: .cards(4)), sources: [source(text: long)], skipped: [], notebookExemplars: [],
            route: cardRoute(budget: 400_000), system: system
        )
        #expect(roomy.sources.first?.isSampled == false)
        #expect(roomy.sources.first?.user.hasSuffix(long) == true)

        let budget = system.count + 9_000
        let tight = CardDraftingPlanner.plan(
            request: request(count: .cards(4)), sources: [source(text: long)], skipped: [], notebookExemplars: [],
            route: cardRoute(budget: budget), system: system
        )
        let sampled = try #require(tight.sources.first)
        #expect(sampled.isSampled)
        #expect(sampled.user.contains("Text \(CardDraftingSampling.marker): "))
        #expect(sampled.user.contains(CardDraftingSampling.gap))
        #expect(system.count + sampled.user.count + CardDraftingPlanner.requestOverheadCharacters <= budget, "the turn fits the window as sent")
        #expect(tight.sampledTitles == ["Mitochondria"])
        #expect(tight.summary == "1 source · 1 sampled")
        #expect(sampled.user.contains("Paragraph 0 says"), "the excerpts start at the start")
        #expect(sampled.user.hasSuffix("Paragraph 399 says protons move across the inner membrane in a measured way."), "and end at the end")

        // A window too small for even the turn's fixed part leaves the
        // source out, and says so.
        let tiny = CardDraftingPlanner.plan(
            request: request(count: .cards(4)), sources: [source(text: long)], skipped: [], notebookExemplars: [],
            route: cardRoute(budget: 2_000), system: system
        )
        #expect(tiny.sources.isEmpty)
        #expect(tiny.skipped.map(\.sourceID) == ["src-1"])
        #expect(tiny.skipped.first?.reason.contains("context window") == true)
    }

    @Test("Evenly spaced excerpts fit their budget, keep the text's order and run from its start to its end")
    func excerpts() {
        let text = (0..<1_000).map { "Line \($0)." }.joined(separator: "\n")
        let sampled = CardDraftingSampling.excerpts(of: text, budget: 3_000)
        #expect(sampled.count <= 3_000)
        #expect(sampled.hasPrefix("Line 0.\n"))
        #expect(sampled.hasSuffix("\nLine 999."))
        let pieces = sampled.components(separatedBy: CardDraftingSampling.gap)
        #expect(pieces.count == CardDraftingSampling.minimumExcerpts)
        let firsts = pieces.compactMap { piece in piece.split(separator: ".").first.flatMap { Int($0.dropFirst(5)) } }
        #expect(firsts.count == pieces.count, "every excerpt starts at a line")
        #expect(firsts == firsts.sorted())
        #expect(CardDraftingSampling.excerpts(of: "short", budget: 3_000) == "short")
    }

    @Test("Free walkthrough cards fill a source's share first; the model is asked for the rest and told what the free ones ask")
    func freeCardsFirst() throws {
        let free = CardDraftingSeed(
            kind: .walkStep, key: "walk-step:s2", text: "Question: What couples it?", question: "What couples it?",
            card: CardDraftingSeed.Card(front: "What couples it?", back: "A gradient.", why: nil, quote: "proton gradient")
        )
        let modelSeed = CardDraftingSeed(kind: .idea, key: "idea:x", text: "Idea: Complex I pumps protons.", ideaID: "idea-x")
        let plan = CardDraftingPlanner.plan(
            request: request(count: .cards(3)), sources: [source(seeds: [free, modelSeed])], skipped: [], notebookExemplars: [],
            route: cardRoute(), system: system
        )
        let planned = try #require(plan.sources.first)
        #expect(planned.quota == 3)
        #expect(planned.free.map(\.key) == ["walk-step:s2"])
        #expect(planned.modelCards == 2)
        #expect(planned.handles["I1"]?.key == "idea:x")
        #expect(planned.user.contains("Cards to write: 2"))
        #expect(planned.user.contains("[I1] Idea: Complex I pumps protons."))
        #expect(!planned.user.contains("[W1]"), "the free card is no seed of the turn")
        #expect(planned.user.contains("The source's cards already ask:\n- What couples it?"))
        #expect(plan.callCount == 1)
        #expect(plan.cardCount == 3)
        #expect(!plan.cost.isFree)
        #expect(plan.cost.label.hasPrefix("about $"))

        // A share the free cards fill makes no call and costs nothing.
        let onlyFree = CardDraftingPlanner.plan(
            request: request(count: .cards(1)), sources: [source(seeds: [free, modelSeed])], skipped: [], notebookExemplars: [],
            route: cardRoute(), system: system
        )
        #expect(onlyFree.callCount == 0)
        #expect(onlyFree.cost.isFree)
        #expect(onlyFree.cardCount == 1)
        #expect(onlyFree.sources.first?.user == "")

        // An unpriced model is never free.
        let unpriced = CardDraftingPlanner.plan(
            request: request(count: .cards(3)), sources: [source()], skipped: [], notebookExemplars: [],
            route: cardRoute(input: nil, output: nil), system: system
        )
        #expect(unpriced.cost.label == "price unknown")
        #expect(!unpriced.cost.isFree)

        // One source named twice — a team's copy and the learner's own — is
        // drafted once.
        let twice = CardDraftingPlanner.plan(
            request: request(["src-1", "src-1-copy"], count: .cards(4)), sources: [source(), source()], skipped: [], notebookExemplars: [],
            route: cardRoute(), system: system
        )
        #expect(twice.sources.count == 1)
        #expect(twice.cardCount == 4)
    }

    // MARK: The answer

    @Test("The model's cards are drafts: a handle names its seed, a card from the text stands on its passage, no more than asked, and a link or a missing answer is refused")
    func answerBecomesDrafts() throws {
        let idea = CardDraftingSeed(kind: .idea, key: "idea:x", text: "Idea: …", ideaID: "idea-x")
        let plan = try #require(CardDraftingPlanner.plan(
            request: request(count: .cards(3)), sources: [source(seeds: [idea])], skipped: [], notebookExemplars: [],
            route: cardRoute(), system: system
        ).sources.first)
        let now = Date(timeIntervalSinceReferenceDate: 812_000_000)
        let answer = CardDraftingAnswer.drafts([
            CardDraftingModelCard(front: "What does complex I pump?", back: "Four protons for each NADH.", why: "The text says so.",
                                  quote: "Complex I pumps four protons for each NADH", seed: "[i1]"),
            CardDraftingModelCard(front: "A second card from the same seed?", back: "No.", quote: "x", seed: "I1"),
            CardDraftingModelCard(front: "What is released as heat?", back: "", quote: "released as heat"),
            CardDraftingModelCard(front: "Where is it? See [the paper](https://example.com)", back: "Here.", quote: "x"),
            CardDraftingModelCard(front: "What does complex IV reduce?", back: "Oxygen, to water.", quote: "complex IV reduces oxygen to water", seed: "Z9"),
            CardDraftingModelCard(front: "One more within the share?", back: "Yes.", quote: "inner membrane"),
            CardDraftingModelCard(front: "One past the share?", back: "Dropped.", quote: "inner membrane"),
        ], plan: plan, isRequested: true, at: now)
        #expect(answer.drafts.map(\.front) == ["What does complex I pump?", "What does complex IV reduce?", "One more within the share?"])
        let first = answer.drafts[0]
        #expect(first.seed == "idea:x")
        #expect(first.ideaID == "idea-x")
        #expect(first.isRequested)
        #expect(first.origin == .drafted)
        #expect(first.sourceID == "src-1")
        #expect(first.draftedAt == Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)))
        #expect(answer.drafts[1].seed == CardDraftingSeedKey.passage("COMPLEX IV reduces, oxygen to water"),
                "a card from the text, or naming no seed it was shown, stands on its passage")
        #expect(answer.refused.map(\.reason) == [
            "Its seed already has a card.",
            "It had no question or no answer.",
            "It wrote a link, which ForeverLM writes itself.",
        ])
    }

    @Test("A source's figures are listed with their instruction; a card pins one to its front or back, and a walkthrough card keeps the figure it was asked beside")
    func figuresOnCards() throws {
        let leak = SourceImageReference(sourceID: "src-1", location: .page(3), crop: PaperFigureRect(x: 0.1, y: 0.2, width: 0.8, height: 0.5))
        let pumping = SourceImageReference(sourceID: "src-1", location: .page(5))
        let figures = [
            CourseQuizFigure(number: 1, reference: leak, page: 3, caption: "Figure 1. Proton leak through UCP1.", label: "Figure 1"),
            CourseQuizFigure(number: 2, reference: pumping, page: 5, caption: "Fig. 2 | Complex I pumping.", label: "Fig. 2"),
        ]

        // A walkthrough question asked beside a figure says so as a seed, and
        // drafted as it stands shows that figure with its question.
        let walk = PaperWalkthrough(
            sourceID: "src-1",
            sourceSHA256: "h",
            title: "Walk",
            steps: [
                PaperWalkthroughStep(
                    id: "s1", kind: .figure, title: "", body: "",
                    anchor: PaperWalkthroughAnchor(figureLabel: "Figure 2b", passage: "Complex I pumps four protons"),
                    quiz: PaperWalkthroughQuiz(question: "How many protons does complex I pump per NADH?", answer: "Four.")
                ),
            ],
            author: .assistant
        )
        let walkSeeds = CardDraftingSeed.walkSteps(of: walk) { _ in "Complex I pumps four protons" }
        #expect(walkSeeds.first?.text.hasSuffix("\nAsked beside: Figure 2b") == true)
        #expect(walkSeeds.first?.card?.figureLabel == "Figure 2b")

        var withFigures = source(seeds: walkSeeds)
        withFigures.figures = figures
        let plan = try #require(CardDraftingPlanner.plan(
            request: request(count: .cards(5)), sources: [withFigures], skipped: [], notebookExemplars: [],
            route: cardRoute(), system: system
        ).sources.first)
        #expect(plan.user.contains(CardDraftingPictures.instruction + "\n\nFigures:\n[F1 · p.3] Figure 1. Proton leak through UCP1.\n[F2 · p.5] Fig. 2 | Complex I pumping."))
        #expect(plan.user.range(of: "Figures:")!.lowerBound < plan.user.range(of: "\nText:")!.lowerBound, "the figures come before the text")

        let now = Date(timeIntervalSinceReferenceDate: 812_000_000)
        let free = CardDraftingAnswer.freeDrafts(plan, isRequested: true, at: now)
        #expect(free.first?.frontImages.map(\.target) == [pumping.urlString], "Figure 2b finds Fig. 2")
        #expect(free.first?.frontImages.first?.alt == "Fig. 2")
        #expect(free.first?.backImages.isEmpty == true)

        // The model's answer, as JSON: a handle as text or as a number.
        let answer: CardDraftingModelAnswer = try MemoryReviewPlanning.decodeJSON("""
            {"cards": [
              {"front": "In the UCP1 study, what does the trace in this figure show leaking?", "back": "Protons.", "quote": "Uncoupling proteins let protons leak back", "figure": "F1", "figure_with": "front", "figure_shows": "a leak trace"},
              {"front": "What does complex IV reduce?", "back": "Oxygen, to water.", "quote": "complex IV reduces oxygen to water", "figure": 2},
              {"front": "Where is the gradient?", "back": "Across the inner membrane.", "quote": "proton gradient across the inner membrane", "figure": "F9", "figure_with": "front"},
              {"front": "What is released as heat?", "back": "The energy of the leak.", "quote": "the energy is released as heat"}
            ]}
            """)
        let drafts = CardDraftingAnswer.drafts(answer.cards, plan: plan, isRequested: true, at: now).drafts
        #expect(drafts.count == 4)
        #expect(drafts[0].frontImages.map(\.target) == [leak.urlString], "the crop rides on the address")
        #expect(drafts[0].frontImages.first?.alt == "a leak trace")
        #expect(drafts[0].backImages.isEmpty)
        #expect(drafts[1].backImages.map(\.target) == [pumping.urlString], "a figure with no side is shown with the answer")
        #expect(drafts[1].frontImages.isEmpty)
        #expect(drafts[2].frontImages.isEmpty && drafts[2].backImages.isEmpty, "a figure the source does not list is no picture")
        #expect(drafts[3].frontImages.isEmpty && drafts[3].backImages.isEmpty)

        // A source with no figures asks for none.
        let bare = try #require(CardDraftingPlanner.plan(
            request: request(count: .cards(2)), sources: [source()], skipped: [], notebookExemplars: [],
            route: cardRoute(), system: system
        ).sources.first)
        #expect(!bare.user.contains("Figures:"))
        #expect(!bare.user.contains(CardDraftingPictures.instruction))
    }

    @Test("A walkthrough question's card keeps the picture its step shows in the walk: a drawn one, or one an earlier step of its chapter showed")
    func walkQuestionCardsKeepTheWalksPicture() throws {
        let figure = SourceImageReference(sourceID: "src-1", location: .page(4))
        let figures = [CourseQuizFigure(number: 1, reference: figure, page: 4, caption: "Figure 3. Cristae.", label: "Figure 3")]
        let walk = PaperWalkthrough(
            sourceID: "src-1",
            sourceSHA256: "h",
            title: "Walk",
            steps: [
                PaperWalkthroughStep(id: "s1", kind: .figure, title: "", body: "", anchor: PaperWalkthroughAnchor(figureLabel: "Figure 3", passage: "Each crista holds its own potential")),
                PaperWalkthroughStep(
                    id: "s2", kind: .quiz, title: "", body: "",
                    quiz: PaperWalkthroughQuiz(question: "In the cristae study, what does each crista hold?", answer: "Its own membrane potential.")
                ),
                PaperWalkthroughStep(
                    id: "s3", kind: .quiz, title: "", body: "",
                    quiz: PaperWalkthroughQuiz(question: "In the cristae study, what makes the potential?", answer: "Proton pumping."),
                    picture: PaperWalkthroughPicture(brief: "Protons pumped across one crista", imageID: "0a1b2c3d-4e5f-6789")
                ),
            ],
            author: .assistant
        )
        let borrowed = CardDraftingPictures.walkImage(walk.cardPicture(of: walk.steps[1]), anchorLabel: nil, in: figures)
        #expect(borrowed?.target == figure.urlString, "an unanchored question borrows the figure the step before it outlined")
        let drawn = CardDraftingPictures.walkImage(walk.cardPicture(of: walk.steps[2]), anchorLabel: nil, in: figures)
        #expect(drawn?.target == GeneratedImageReference(id: "0a1b2c3d-4e5f-6789")?.urlString)
        #expect(drawn?.alt == "Protons pumped across one crista")
        #expect(CardDraftingPictures.walkImage(walk.cardPicture(of: walk.steps[1]), anchorLabel: nil, in: []) == nil, "no file here, no figure")

        // Drafted as it stands, and kept when missed, the card shows it with its question.
        let seeds = CardDraftingSeed.walkSteps(of: walk) { $0.first }
        #expect(seeds.compactMap(\.card?.picture).count == 2)
        var question = SourceMemoryQuestion(sourceID: "src-1", step: walk.steps[2], quiz: try #require(walk.steps[2].quiz))
        question.frontImages = drawn.map { [$0] } ?? []
        #expect(question.card(itemID: "item").frontImages.map(\.target) == [drawn?.target])
    }

    @Test("A lecture video's slides are the pictures its cards may show, each with when it was on screen")
    func slidesAreFigures() {
        let frame = SourceImageReference(sourceID: "video-1", location: .moment(723))
        let listed = CardDraftingPictures.slideFigures([
            CourseQuizSlide(number: 1, reference: frame, seconds: 700, text: "Cardiolipin structure", onScreen: [700...733]),
            CourseQuizSlide(number: 2, reference: SourceImageReference(sourceID: "video-1", location: .moment(900)), seconds: 890, text: ""),
        ])
        #expect(listed.map(\.number) == [1, 2])
        #expect(listed[0].reference == frame)
        #expect(listed[0].caption == "Slide on screen 11:40–12:13: Cardiolipin structure")
        #expect(listed[1].caption.hasSuffix(": (no words recognized)"))
        #expect(CourseQuizPictures.figureBlock(listed, heading: "Figures:")?.contains("[F1] Slide on screen 11:40–12:13") == true)
    }

    @Test("The run's summary names what was added, sampled, not found and failed")
    func resultSummary() {
        var result = CardDraftingResult()
        #expect(result.summary == "No new cards")
        result.sources = [
            CardDraftingSourceOutcome(sourceID: "a", title: "A", added: [Flashcard(id: "1", front: "Q?", back: "A.")], isSampled: true),
            CardDraftingSourceOutcome(
                sourceID: "b", title: "B",
                added: [Flashcard(id: "2", front: "Q?", back: "A."), Flashcard(id: "3", front: "R?", back: "B.")],
                ungrounded: [Flashcard(id: "4", front: "S?", back: "C.")]
            ),
            CardDraftingSourceOutcome(sourceID: "c", title: "C", failure: "The model failed."),
        ]
        #expect(result.summary == "3 cards to check from 2 sources · 1 sampled · 1 not found in its source · 1 source failed")
        #expect(result.draftedSourceIDs == ["a", "b"])
        #expect(CardDraftingProgress(done: 1, total: 5).label == "Drafting cards (2 of 5 sources)")
        #expect(CardDraftingProgress(done: 0, total: 1).label == "Drafting cards")
    }

    // MARK: Where the drafts open

    @Test("In panes the drafts open in a pane of their own beside the Reader, or one showing neither a chat nor the Reader")
    func placementInPanes() {
        typealias Group = StudioCenterTabGroups.Group
        let readerAlone = StudioCenterTabGroups(groups: [
            Group(tabs: [.reader, .chat, .memory, .artifacts], activeTab: .reader),
        ])
        guard case .panes(let split) = CardDraftsPlacement.place(panes: readerAlone, isInMemoryFocus: false) else {
            Issue.record("room for a second pane: the drafts take it")
            return
        }
        #expect(split.groups.map(\.activeTab) == [.reader, .memory])
        #expect(split.groups[0].tabs == [.reader, .chat, .artifacts])

        let readerAndChat = StudioCenterTabGroups(groups: [
            Group(tabs: [.reader, .memory], activeTab: .reader),
            Group(tabs: [.chat, .artifacts], activeTab: .chat),
        ])
        #expect(CardDraftsPlacement.place(panes: readerAndChat, isInMemoryFocus: false) == CardDraftsPlacement.none,
                "never over the chat or the source")

        let readerAndDocs = StudioCenterTabGroups(groups: [
            Group(tabs: [.reader, .memory], activeTab: .reader),
            Group(tabs: [.notepad, .chat], activeTab: .notepad),
        ])
        guard case .panes(let overDocs) = CardDraftsPlacement.place(panes: readerAndDocs, isInMemoryFocus: false) else {
            Issue.record("a pane showing a Doc gives way")
            return
        }
        #expect(overDocs.groups.map(\.activeTab) == [.reader, .memory])
        #expect(!overDocs.groups[0].tabs.contains(.memory))

        let showing = StudioCenterTabGroups(groups: [Group(tabs: [.memory, .reader], activeTab: .memory)])
        #expect(CardDraftsPlacement.place(panes: showing, isInMemoryFocus: false) == .memoryOnScreen)
    }

    // MARK: The tasks

    @Test("Card Drafting is a Background task on the learner's route, counted as background spend, in catalog 30")
    func tasks() {
        #expect(AITask.cardDrafting.rawValue == "card_drafting")
        #expect(AITask.cardDrafting.defaultPrompt == Prompts.cardDrafter)
        for task in [AITask.cardDrafting] {
            #expect(task.isBackgroundWork, "\(task.rawValue) counts as background spend")
            #expect(AITask.backgroundWorkTaskIDs.contains(task.rawValue))
            #expect(task.sourceType == nil)
            #expect(!task.followsChatRoute)
            #expect(task.usesBackgroundModelDefault)
            #expect(!task.requiresVision)
            #expect(AITask.advancedTasks.contains(task))
        }
        #expect(AITaskSettingsCatalog.version >= 30)
        #expect(AITaskSettingsCatalog.descriptor(forRawID: "card_drafting")?.displayName == "Card Drafting")
        #expect(AITaskSettingsCatalog.descriptor(forRawID: "card_variation") == nil, "removed 2026-10-15 with the day close")
        #expect(AIUsageTaskLabel.text(for: "card_drafting") == "Draft Cards")
        #expect(Prompts.cardDrafter.contains("\"seed\""))
        #expect(Prompts.cardDrafter.contains(CardDraftingSampling.marker))
        // v1's flashcard writer is gone for good.
        #expect(AITask(rawValue: "flashcard_writing") == nil)
        #expect(AITaskSettingsCatalog.descriptor(forRawID: "flashcard_writing") == nil)
    }
}

// MARK: - The service, over storage

@Suite("Memory cards: drafting, over storage", .cardWordingPasses)
struct CardDraftingServiceTests {
    @Test("Seeds come first: a walkthrough question its source prints is a card with no model call, and the model drafts the rest from the seeds and the text")
    func seedsFirst() async throws {
        let (storage, defaults, cleanup) = try await makeStorage()
        defer { cleanup() }
        try await saveWalkthrough(storage)
        let materials = try await CardDraftingService.load(request(count: .cards(3)), storage: storage, stateDefaults: defaults)
        let read = try #require(materials.sources.first)
        #expect(read.text == mitoText, "the whole text")
        #expect(read.seeds.map(\.key) == ["walk-step:step-0", "walk-step:step-2"])
        #expect(read.seeds[0].card == nil, "its passage is not in the source")
        #expect(read.seeds[1].card?.quote == "couple respiration to ATP synthesis through a proton gradient")

        let drafter = CannedDrafter { _ in [
            CardDraftingModelCard(front: "What do uncoupling proteins do?", back: "Let protons leak back without making ATP.",
                                  quote: "Uncoupling proteins let protons leak back without making ATP", seed: "W1"),
            CardDraftingModelCard(front: "How many protons does complex I pump for each NADH?", back: "Four.",
                                  quote: "Complex I pumps four protons for each NADH it oxidizes"),
        ] }
        let plan = CardDraftingService.plan(materials, route: cardRoute())
        let result = try await CardDraftingService.shared.run(plan, storage: storage, backend: drafter, gate: .learnerStarted)
        let outcome = try #require(result.sources.first)
        #expect(outcome.added.count == 3)
        #expect(outcome.freeCount == 1)
        #expect(drafter.turns.count == 1)
        #expect(drafter.turns[0].contains("[W1] Question: What do uncoupling proteins do?"))
        #expect(drafter.turns[0].contains("Cards to write: 2"))
        #expect(drafter.turns[0].contains("- What couples respiration to ATP synthesis?"), "the free card's question is not asked again")

        let waiting = try await cardsToCheck(storage, defaults)
        #expect(waiting.count == 3)
        let allRequested = waiting.allSatisfy { $0.isRequested }
        #expect(allRequested, "cards the learner asked for arrive kept by default")
        #expect(Set(waiting.compactMap(\.seed)).isSuperset(of: ["walk-step:step-2", "walk-step:step-0"]))
    }

    @Test("Make Cards again adds only what is uncovered, and never offers again a seed the learner skipped")
    func idempotentPerSeed() async throws {
        let (storage, defaults, cleanup) = try await makeStorage()
        defer { cleanup() }
        try await saveWalkthrough(storage)
        let route = cardRoute()
        let first = CannedDrafter { _ in [
            CardDraftingModelCard(front: "What do uncoupling proteins do?", back: "Let protons leak back.",
                                  quote: "Uncoupling proteins let protons leak back without making ATP", seed: "W1"),
            CardDraftingModelCard(front: "What happens to the energy when protons leak back?", back: "It is released as heat.",
                                  quote: "the energy is released as heat"),
        ] }
        let plan = CardDraftingService.plan(
            try await CardDraftingService.load(request(count: .cards(3)), storage: storage, stateDefaults: defaults),
            route: route
        )
        _ = try await CardDraftingService.shared.run(plan, storage: storage, backend: first, gate: .learnerStarted)
        let drafted = try await cardsToCheck(storage, defaults)
        #expect(drafted.count == 3)

        // The learner skips the free card and the card on the heat passage.
        let skipped = drafted.filter { $0.seed == "walk-step:step-2" || $0.seed == CardDraftingSeedKey.passage("the energy is released as heat") }
        #expect(skipped.count == 2)
        let triage = await MemoryCardTriageWriter.apply(skipped.map { MemoryCardTriageDecision(card: $0, action: .skip) }, storage: storage, defaults: defaults)
        #expect(triage.skipped.count == 2)

        // Again: every walkthrough seed is covered, to check or skipped, and
        // the model is told every question the source's cards ask.
        let again = try await CardDraftingService.load(request(count: .cards(2)), storage: storage, stateDefaults: defaults)
        let source = try #require(again.sources.first)
        #expect(source.seeds.isEmpty)
        #expect(Set(source.coveredFronts) == [
            "What couples respiration to ATP synthesis?",
            "What do uncoupling proteins do?",
            "What happens to the energy when protons leak back?",
        ])
        let second = CannedDrafter { _ in [
            // The skipped card's passage again, in other words: not offered.
            CardDraftingModelCard(front: "Where does the energy go when protons leak back?", back: "Into heat.",
                                  quote: "the energy is released as heat"),
            CardDraftingModelCard(front: "What does complex IV reduce?", back: "Oxygen, to water.",
                                  quote: "complex IV reduces oxygen to water"),
        ] }
        let result = try await CardDraftingService.shared.run(
            CardDraftingService.plan(again, route: route), storage: storage, backend: second, gate: .learnerStarted
        )
        #expect(second.turns.count == 1)
        #expect(!second.turns[0].contains("[W"), "no walkthrough seed is offered twice")
        #expect(second.turns[0].contains("- What happens to the energy when protons leak back?"))
        let outcome = try #require(result.sources.first)
        #expect(outcome.added.map(\.front) == ["What does complex IV reduce?"])
        #expect(outcome.alreadyDrafted == 1)
        let left = try await cardsToCheck(storage, defaults)
        #expect(Set(left.map(\.face.front)) == ["What do uncoupling proteins do?", "What does complex IV reduce?"], "the skipped cards stay away")
    }

    @Test("A card whose quote its source does not print is reported and never offered")
    func ungroundedIsReported() async throws {
        let (storage, defaults, cleanup) = try await makeStorage()
        defer { cleanup() }
        let drafter = CannedDrafter { _ in [
            CardDraftingModelCard(front: "What does the paper claim about sodium?", back: "Nothing.", quote: "sodium pumps everything everywhere"),
            CardDraftingModelCard(front: "What does complex IV reduce?", back: "Oxygen, to water.", quote: "complex IV reduces oxygen to water"),
        ] }
        let plan = CardDraftingService.plan(
            try await CardDraftingService.load(request(count: .cards(2)), storage: storage, stateDefaults: defaults),
            route: cardRoute()
        )
        let result = try await CardDraftingService.shared.run(plan, storage: storage, backend: drafter, gate: .learnerStarted)
        let outcome = try #require(result.sources.first)
        #expect(outcome.ungrounded.map(\.front) == ["What does the paper claim about sodium?"])
        #expect(outcome.added.map(\.front) == ["What does complex IV reduce?"])
        #expect(result.ungroundedCount == 1)
        #expect(result.summary == "1 card to check · 1 not found in its source")
        #expect(try await cardsToCheck(storage, defaults).map(\.face.front) == ["What does complex IV reduce?"])
    }

    @Test("A background run asks before every model call and drafts nothing paid once the cap says no; a source left out is said")
    func backgroundGateAndLeftOut() async throws {
        let (storage, defaults, cleanup) = try await makeStorage()
        defer { cleanup() }
        var empty = StudioArticle(url: "https://example.com/empty", title: "Empty", sourceType: .article, discoveryOrigin: .manual, id: "src-empty")
        empty.normalizedURL = URLNormalizer.normalize(empty.url)
        try await storage.saveSource(empty)
        let materials = try await CardDraftingService.load(
            CardDraftingRequest(notebookID: nil, sourceIDs: ["src-1", "src-empty", "src-missing"], count: .auto, focus: nil, trigger: .automatic),
            storage: storage, stateDefaults: defaults
        )
        #expect(materials.sources.map(\.sourceID) == ["src-1"])
        #expect(Set(materials.skipped.map(\.sourceID)) == ["src-empty", "src-missing"])
        #expect(materials.skipped.first { $0.sourceID == "src-missing" }?.reason == "It is not in the library.")
        #expect(materials.skipped.first { $0.sourceID == "src-empty" }?.reason == "It has no text yet.")
        let drafter = CannedDrafter { _ in [] }
        let result = try await CardDraftingService.shared.run(
            CardDraftingService.plan(materials, route: cardRoute()),
            storage: storage, backend: drafter, gate: .background({ false })
        )
        #expect(drafter.turns.isEmpty, "nothing was sent")
        #expect(result.sources.first?.failure?.contains("background AI limit") == true)
        #expect(result.skipped.count == 2)
        #expect(try await cardsToCheck(storage, defaults).isEmpty)
    }

    @Test("A drafted card that points at its source unnamed is reworded once or dropped, never saved as it was; a check that cannot run saves nothing")
    func wordingGate() async throws {
        let (storage, defaults, cleanup) = try await makeStorage()
        defer { cleanup() }
        let drafter = CannedDrafter { _ in [
            CardDraftingModelCard(front: "In this lecture, what does complex IV reduce?", back: "Oxygen, to water.",
                                  quote: "complex IV reduces oxygen to water"),
            CardDraftingModelCard(front: "According to the speaker, what leaks back through uncoupling proteins?", back: "Protons.",
                                  quote: "Uncoupling proteins let protons leak back without making ATP"),
            CardDraftingModelCard(front: "How many protons does complex I pump for each NADH?", back: "Four.",
                                  quote: "Complex I pumps four protons for each NADH it oxidizes"),
        ] }
        let wording = CannedCardWording(pointing: ["this lecture", "the speaker"]) { question in
            question.hasPrefix("In this lecture") ? "In mitochondria, what does complex IV reduce?" : nil
        }
        let plan = CardDraftingService.plan(
            try await CardDraftingService.load(request(count: .cards(3)), storage: storage, stateDefaults: defaults),
            route: cardRoute()
        )
        let result = try await CardDraftingService.shared.run(plan, storage: storage, backend: drafter, gate: .learnerStarted, wording: wording)
        let outcome = try #require(result.sources.first)
        let fronts = Set(try await cardsToCheck(storage, defaults).map(\.face.front))
        #expect(fronts == ["In mitochondria, what does complex IV reduce?", "How many protons does complex I pump for each NADH?"])
        #expect(!fronts.contains { $0.localizedCaseInsensitiveContains("this lecture") }, "never saved as it was")
        #expect(outcome.notSaved.map(\.front) == ["According to the speaker, what leaks back through uncoupling proteins?"])
        #expect(outcome.notSaved.first?.reason.contains("points at its source") == true)
        // One check for the pass, one rewording of both failing cards with the
        // source's title, one check of the rewordings.
        #expect(wording.checks.count == 2)
        #expect(wording.checks.first?.contains("Card 3, from \u{201C}Mitochondria\u{201D}") == true)
        #expect(wording.rewordings.count == 1)
        #expect(wording.rewordings.first?.contains("Card 2, from \u{201C}Mitochondria\u{201D}") == true)
        #expect(wording.rewordings.first?.contains("The answers may change too") == true)

        let (unchecked, uncheckedDefaults, uncheckedCleanup) = try await makeStorage()
        defer { uncheckedCleanup() }
        let down = CannedCardWording(failure: CardWordingGate.Unavailable(message: "No model is set up for Card Wording Check."))
        let failed = try await CardDraftingService.shared.run(
            CardDraftingService.plan(
                try await CardDraftingService.load(request(count: .cards(3)), storage: unchecked, stateDefaults: uncheckedDefaults),
                route: cardRoute()
            ),
            storage: unchecked, backend: drafter, gate: .learnerStarted, wording: down
        )
        #expect(failed.sources.first?.failure?.contains("could not be checked") == true)
        #expect(failed.sources.first?.failure?.contains("No model is set up for Card Wording Check.") == true)
        #expect(try await cardsToCheck(unchecked, uncheckedDefaults).isEmpty, "no card is saved unchecked")
    }
}

// MARK: - The window

@Suite("Memory cards: Make Cards in the window", .cardWordingPasses)
@MainActor
struct MakeCardsViewModelTests {
    private func makeViewModel() -> (StudioViewModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MakeCards_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (StudioViewModel(storageService: StorageService(storeRoot: root), observeCloudKitChanges: false), root)
    }

    @Test("The Reader's toolbar counts its source's cards to check from the counts' one read")
    func readerCount() async throws {
        let (vm, root) = makeViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let article = mitoArticle(id: "src-reader-count")
        try await vm.storage.saveSource(article)
        let now = Date()
        _ = try await vm.storage.saveCardDrafts([
            Flashcard.mint(front: "What couples respiration to ATP synthesis?", back: "A gradient.", sourceID: article.id, sourceTitle: article.title,
                           quote: "couple respiration to ATP synthesis", origin: .drafted, isRequested: true, at: now),
            Flashcard.mint(front: "What do uncoupling proteins do?", back: "Leak protons.", sourceID: article.id, sourceTitle: article.title,
                           quote: "Uncoupling proteins let protons leak back", origin: .drafted, isRequested: true, at: now),
        ], sourceID: article.id, sourceTitle: article.title)
        #expect(vm.memoryCardsToCheck(sourceID: article.id) == 0, "nothing is read on its own")
        await vm.refreshMemoryCardCounts()
        #expect(vm.memoryCardsToCheck(sourceID: article.id) == 2)
        #expect(vm.memoryCardsToCheck(sourceID: "another") == 0)
        #expect(CardsToolbarButton.canMakeCards(from: article))
    }

    @Test("Ready cards open in To Check beside the chat or the Reader, and wait when only a chat or the source could give way")
    func makeCardsRouting() {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, root) = makeViewModel()
        defer { try? FileManager.default.removeItem(at: root) }

        // A notebook's window places them in its panes, as any window does.
        let window = StudioWindowState()
        window.notebook = NotebookWorkspace(notebookID: "nb")
        window.centerTabGroups = StudioCenterTabGroups(groups: [
            StudioCenterTabGroups.Group(tabs: [.chat, .memory], activeTab: .chat),
        ])
        #expect(vm.placeCardDrafts(scope: .notebook("nb"), in: window))
        #expect(window.centerTabGroups.groups.map(\.activeTab) == [.chat, .memory], "a pane of its own beside the chat")
        #expect(window.memoryPaneSection == .toCheck)
        #expect(window.memoryPaneScope == .notebook("nb"))

        // Panes: a pane of its own beside the Reader; none over a chat.
        typealias Group = StudioCenterTabGroups.Group
        let panes = StudioWindowState()
        panes.centerTabGroups = StudioCenterTabGroups(groups: [Group(tabs: [.reader, .memory], activeTab: .reader)])
        #expect(vm.placeCardDrafts(scope: .allNotebooks, in: panes))
        #expect(panes.centerTabGroups.groups.map(\.activeTab) == [.reader, .memory])
        panes.centerTabGroups = StudioCenterTabGroups(groups: [
            Group(tabs: [.reader, .memory], activeTab: .reader),
            Group(tabs: [.chat], activeTab: .chat),
        ])
        let before = panes.centerTabGroups
        panes.memoryPaneSection = .review
        #expect(!vm.placeCardDrafts(scope: .allNotebooks, in: panes))
        #expect(panes.centerTabGroups == before)
        #expect(panes.memoryPaneSection == .review, "nothing changes when there is no place")
    }

    @Test("Make Cards opens no chat: sources the library does not hold give nothing to write, and say so")
    func makeCardsWritesNoChat() {
        let (vm, root) = makeViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(NotebookStudioTile.cards.isMenu)
        #expect(!NotebookStudioTile.cards.makesIntoNotebook)
        let window = StudioWindowState()
        vm.inWindow(window) { vm.requestWriteCards(notebookID: nil, sourceIDs: ["a", " a ", "b", ""]) }
        #expect(window.cardWriting == nil)
        #expect(vm.pendingReviewChatDraft == nil, "no chat is asked to draft them")
        #expect(vm.toastMessage == "These sources have no text to write a card from")

        #expect(MakeMnemonicReadingSheet.clause("It is kept from AI or archived.") == "it is kept from AI or archived")
        #expect(MakeMnemonicReadingSheet.clause("It is a spoken script ForeverLM wrote.") == "it is a spoken script ForeverLM wrote")
    }
}

// MARK: - draft_cards

@Suite("Memory cards: draft_cards over MCP", .cardWordingPasses)
struct CardDraftingMCPTests {
    /// A store of its own holding one source, under an id of its own: the
    /// runs a test starts are the app's one coordinator's, which
    /// `list_cards` reports by source, and the suites run side by side.
    private func makeStore() async throws -> (MCPDataStore, String, UserDefaults, () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DraftCardsMCP_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "foreverlm-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = MCPDataStore(dbPath: root.appendingPathComponent("knowledge.db").path, cardStateDefaults: defaults)
        let sourceID = "src-mcp-\(UUID().uuidString.lowercased())"
        try await store.notebookFileStorage.saveSource(mitoArticle(id: sourceID))
        return (store, sourceID, defaults, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        })
    }

    private func waitForWork(_ workID: String) async throws {
        for _ in 0..<400 where MCPRunningWork.shared.snapshot.contains(where: { $0.id == workID }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test("draft_cards is registered as paid, self-gated, open-world work with a popup, in the study chats, with the approval argument")
    @MainActor
    func registration() throws {
        let tool = try #require(MCPToolRegistry.shared.tools.first { $0.name == "draft_cards" })
        let properties = try #require(tool.inputSchema["properties"] as? [String: Any])
        for name in ["source_ids", "notebook_id", "count", "focus", "confirm_cost", "approved_spend_usd"] {
            #expect(properties[name] != nil, "\(name)")
        }
        #expect(tool.inputSchema["anyOf"] == nil)
        #expect(tool.description.contains("cancel_ai_work"))
        #expect(tool.description.contains("confirm_cost"))
        #expect(tool.description.contains("list_sources"))
        #expect(MCPToolRegistry.paidWorkToolNames.contains("draft_cards"))
        #expect(MCPToolRegistry.selfGatedToolNames.contains("draft_cards"))
        let annotations = MCPToolRegistry.annotations(for: "draft_cards")
        #expect(annotations["openWorldHint"] as? Bool == true)
        #expect(annotations["destructiveHint"] as? Bool == false)
        #expect(annotations["readOnlyHint"] as? Bool == false)
        #expect(MCPToolActivityTitle.shownToolNames.contains("draft_cards"))
        let title = try #require(MCPToolActivityTitle.forTool("draft_cards", arguments: [:]))
        #expect(title.text(subjectName: "Mitochondria") == "Drafting cards for Mitochondria")
        #expect(ReviewSessionManager.studySurfaceToolNames.contains("draft_cards"))
        #expect(ReviewSessionManager.studySurfaceToolNames.contains("save_card_drafts"))
    }

    @Test("draft_cards leaves out an archived source with its reason instead of refusing the call")
    func archivedSourceIsLeftOut() async throws {
        let (store, sourceID, _, cleanup) = try await makeStore()
        defer { cleanup() }
        var archived = mitoArticle(id: "src-archived-\(UUID().uuidString.lowercased())")
        archived.title = "Archived chapter"
        archived.status = .archived
        try await store.notebookFileStorage.saveSource(archived)
        let quoted = try object(try await store.draftCards(
            arguments: ["source_ids": [sourceID, archived.id], "count": "10"],
            backend: CannedDrafter { _ in [] }, route: cardRoute()
        ))
        #expect(quoted["status"] as? String == "awaiting_confirmation")
        let leftOut = try #require(quoted["left_out"] as? [[String: Any]])
        #expect(leftOut.map { $0["source_id"] as? String } == [archived.id])
        #expect(leftOut.first?["title"] as? String == "Archived chapter", "archived is not private: the title is said")
        #expect((leftOut.first?["reason"] as? String)?.contains("archived") == true)
    }

    @Test("draft_cards refuses an unknown source naming list_sources, prices first and starts nothing until agreed")
    func quoteThenApprove() async throws {
        let (store, sourceID, defaults, cleanup) = try await makeStore()
        defer { cleanup() }
        let drafter = CannedDrafter { _ in [] }
        for arguments: [String: Any] in [[:], ["source_ids": [sourceID], "count": "41"], ["notebook_id": "missing"]] {
            await #expect(throws: MCPError.self) {
                _ = try await store.draftCards(arguments: arguments, backend: drafter, route: cardRoute())
            }
        }
        do {
            _ = try await store.draftCards(arguments: ["source_ids": [sourceID, "no-such-source"]], backend: drafter, route: cardRoute())
            Issue.record("an unknown source refuses the whole call")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("no-such-source"))
            #expect(error.localizedDescription.contains("list_sources"))
        }

        let quoted = try object(try await store.draftCards(arguments: ["source_ids": [sourceID], "count": "10"], backend: drafter, route: cardRoute()))
        #expect(quoted["status"] as? String == "awaiting_confirmation")
        #expect(quoted["work_id"] == nil)
        #expect(quoted["card_count"] as? Int == 10)
        let estimate = try #require((quoted["estimate"] as? [String: Any])?["drafting"] as? [String: Any])
        #expect(estimate["estimated_cost_usd"] is Double)
        #expect(estimate["model"] as? String == "test/card-drafter")
        #expect(drafter.turns.isEmpty)

        let tooLow = try object(try await store.draftCards(
            arguments: ["source_ids": [sourceID], "confirm_cost": true, "approved_spend_usd": 0.000001],
            backend: drafter, route: cardRoute()
        ))
        #expect(tooLow["status"] as? String == "approval_too_low")
        #expect(tooLow["work_id"] == nil)
        #expect(drafter.turns.isEmpty)
        #expect(try await cardsToCheck(store.notebookFileStorage, defaults).isEmpty)
    }

    @Test("Agreed, draft_cards drafts in the background, the cards wait in To Check, and list_cards says what the run drafted")
    func startsInTheBackground() async throws {
        let (store, sourceID, defaults, cleanup) = try await makeStore()
        defer { cleanup() }
        let drafter = CannedDrafter { _ in [
            CardDraftingModelCard(front: "What does complex IV reduce?", back: "Oxygen, to water.", quote: "complex IV reduces oxygen to water"),
            CardDraftingModelCard(front: "What does the paper say of sodium?", back: "Nothing.", quote: "sodium pumps everything everywhere"),
        ] }
        let started = try object(try await store.draftCards(
            arguments: ["source_ids": [sourceID], "count": "2", "confirm_cost": true],
            backend: drafter, route: cardRoute()
        ))
        #expect(started["status"] as? String == "started")
        #expect(started["cost_confirmed_by"] == nil)
        let workID = try #require(started["work_id"] as? String)
        try await waitForWork(workID)
        #expect(!MCPRunningWork.shared.snapshot.contains { $0.id == workID })
        let waiting = try await cardsToCheck(store.notebookFileStorage, defaults)
        #expect(waiting.map(\.face.front) == ["What does complex IV reduce?"])
        #expect(waiting.first?.isRequested == true)

        let listed = try object(try await store.listCards(status: nil, notebookID: nil, sourceID: sourceID, limit: nil))
        let runs = try #require(listed["drafting"] as? [[String: Any]])
        let done = try #require(runs.first { $0["state"] as? String == "done" })
        let row = try #require((done["sources"] as? [[String: Any]])?.first)
        #expect(row["source_id"] as? String == sourceID)
        #expect(row["not_grounded"] as? [String] == ["What does the paper say of sodium?"])
        #expect((row["added_card_ids"] as? [String]) == waiting.map(\.cardID))
    }

    @Test("A free model starts at once, and says why no confirmation was needed")
    func freeStartsAtOnce() async throws {
        let (store, sourceID, _, cleanup) = try await makeStore()
        defer { cleanup() }
        let started = try object(try await store.draftCards(
            arguments: ["source_ids": [sourceID], "count": "1"],
            backend: CannedDrafter { _ in [] }, route: cardRoute(input: 0, output: 0)
        ))
        #expect(started["status"] as? String == "started")
        #expect(started["cost_confirmed_by"] as? String == "free_model")
        try await waitForWork(try #require(started["work_id"] as? String))
    }
}

// MARK: - The cards a chat saved

/// docs/memory-design.md, "The cards in the chat": a chat's `save_card_drafts`
/// is drawn in the reply as the cards, stored with the reply as one link line,
/// and read back as the cards when the chat is reopened.
@Suite("Memory cards: the cards a chat saved", .cardWordingPasses)
struct ChatSavedCardsTests {
    /// A `save_card_drafts` result as `MCPDataStore.saveCardDrafts` writes it:
    /// six saved on one source, three the deck already held, one quote the
    /// source does not print — the reply the product owner could not find on 2026-10-06.
    private static let result = """
    {"saved_count":2,"kept_by_default":true,"message":"Saved 2 cards to check.","sources":[\
    {"source_id":"src-1","source_title":"Mitochondria","saved_card_ids":["c-1","c-2"],\
    "already_drafted":[{"front":"Old?","card_id":"c-0"}],\
    "not_grounded":[{"front":"Sodium?","quote":"sodium","reason":"…"}]}]}
    """

    @Test("A result names the cards it saved and the deck already held, their source, and what was not saved")
    func parsesTheResult() throws {
        let cards = try #require(ChatSavedCards.parse(toolResult: Self.result))
        #expect(cards.cardIDs == ["c-1", "c-2", "c-0"])
        #expect(cards.sourceIDs == ["src-1"])
        #expect(cards.notSavedCount == 1)
        #expect(cards.label == "3 cards to check")
        // A call that saved nothing keeps its ordinary row, which says why.
        #expect(ChatSavedCards.parse(toolResult: #"{"saved_count":0,"sources":[{"source_id":"src-1","saved_card_ids":[]}]}"#) == nil)
        #expect(ChatSavedCards.parse(toolResult: "Error: nothing was saved.") == nil)
    }

    @Test("The stored line reads back as the same cards, whatever their ids hold, and splits the reply around it")
    func storedLineRoundTrips() throws {
        let cards = ChatSavedCards(
            cardIDs: ["card:src-1:a b", "x)y](z", "c,d&e=f"],
            sourceIDs: ["src-1"],
            notSavedCount: 2
        )
        let stored = ChatSavedCards.storing("Made from the passage.\n\nOne quote did not match.", with: cards)
        #expect(stored.hasPrefix("[3 cards to check](foreverlm://cards?source=src-1&card="))
        #expect(ChatSavedCards.split(stored) == [
            .cards(cards),
            .text("Made from the passage.\n\nOne quote did not match."),
        ])
        #expect(ChatSavedCards.prose(of: stored) == "Made from the passage.\n\nOne quote did not match.")
        // The running build's own scheme reads too, as a deep link arrives.
        let devLink = try #require(URL(string: cards.destination.replacingOccurrences(of: "foreverlm://", with: "\(ForeverLMRuntimeIdentity.urlScheme)://")))
        #expect(ChatSavedCards.parse(devLink) == cards)
        // No cards, no line.
        #expect(ChatSavedCards.storing("Done.", with: nil) == "Done.")
    }

    @Test("Only a line that is nothing but the link is drawn as cards; a link inside a sentence stays prose")
    func inlineLinkStaysProse() {
        let link = ChatSavedCards(cardIDs: ["c-1"], sourceIDs: ["src-1"]).markdownLine
        let inline = "They are here: \(link), waiting."
        #expect(ChatSavedCards.split(inline) == [.text(inline)])
        #expect(ChatSavedCards.split("Plain reply.") == [.text("Plain reply.")])
        #expect(ChatSavedCards.split("[a link](https://example.com/cards?card=1)") == [.text("[a link](https://example.com/cards?card=1)")])
    }

    @Test("The in-app chat's model is told the cards are on screen, and the result still reads as the same cards")
    func modelIsToldTheCardsAreShown() throws {
        let noted = ChatSavedCards.notingShownInChat(Self.result)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(noted.utf8)) as? [String: Any])
        #expect(object["shown_in_chat"] as? String == ChatSavedCards.shownInChatNote)
        #expect(ChatSavedCards.parse(toolResult: noted) == ChatSavedCards.parse(toolResult: Self.result))
        #expect(ChatSavedCards.notingShownInChat("Error: no.") == "Error: no.")
    }

    @Test("Two calls in a turn are one set of cards")
    func callsMerge() {
        let first = ChatSavedCards(cardIDs: ["a", "b"], sourceIDs: ["s1"], notSavedCount: 1)
        let second = ChatSavedCards(cardIDs: ["b", "c"], sourceIDs: ["s2"], notSavedCount: 2)
        #expect(first.merging(second) == ChatSavedCards(cardIDs: ["a", "b", "c"], sourceIDs: ["s1", "s2"], notSavedCount: 3))
    }

    @Test("The header counts the cards as they stand")
    func headerCounts() {
        func card(_ id: String, _ standing: ChatSavedCard.Standing) -> ChatSavedCard {
            ChatSavedCard(
                id: id, sourceID: "src-1",
                face: MemoryCard(cardID: id, front: "Q?", back: "A.", origin: .assistant),
                quote: nil, standing: standing
            )
        }
        let saved = ChatSavedCards(cardIDs: ["a", "b", "c"], sourceIDs: ["src-1"])
        let waiting = MemoryCardToCheck(
            kind: .draft, face: MemoryCard(cardID: "a", front: "Q?", back: "A.", origin: .assistant),
            deckID: "carddeck-src-1", sourceID: "src-1", quote: "q", seed: nil, ideaID: nil,
            draftedAt: Date(), isRequested: true, memoryItemID: nil
        )
        #expect(ReviewChatSavedCardsView.title(nil, saved: saved) == "3 cards to check")
        #expect(ReviewChatSavedCardsView.title([card("a", .toCheck(waiting))], saved: saved) == "1 card to check")
        #expect(ReviewChatSavedCardsView.title([card("a", .kept), card("b", .kept)], saved: saved) == "2 cards kept")
        #expect(ReviewChatSavedCardsView.title(
            [card("a", .toCheck(waiting)), card("b", .kept), card("c", .skipped)], saved: saved
        ) == "3 cards · 1 to check · 1 kept · 1 skipped")
    }

    @Test("A card to check takes pictures put on it, replaced per face, drawn one not twice")
    func cardToCheckTakesHeldPictures() throws {
        let figure = try #require(MemoryCardImage(reference: "![Figure 1](foreverlm://image/src-1/page/1)"))
        let drawn = try #require(MemoryCardImage(reference: "![Drawn](foreverlm://image/src-1/page/2)"))
        let card = MemoryCardToCheck(
            kind: .draft, face: MemoryCard(cardID: "a", front: "Q?", back: "A.", origin: .assistant, backImages: [drawn]),
            deckID: "carddeck-src-1", sourceID: "src-1", quote: "q", seed: nil, ideaID: nil,
            draftedAt: Date(), isRequested: true, memoryItemID: nil
        )
        let held = card.replacingImages(back: [drawn, figure])
        #expect(held.face.backImages == [drawn, figure])
        #expect(held.face.frontImages.isEmpty, "a face left nil keeps its own pictures")
        #expect(held.face.front == "Q?" && held.face.back == "A." && held.sourceID == "src-1" && held.quote == "q")
        #expect(held.addingBackImage(drawn).face.backImages == [drawn, figure], "a picture the card shows is not added twice")
        #expect(card.replacingImages(back: []).face.backImages.isEmpty, "[] takes the pictures off")
        #expect(card.replacingImages(front: [figure]).face.backImages == [drawn])
    }

    @Test("Storage reads each saved card's face and where it stands: to check, kept, skipped; a card no deck holds is left out")
    func storageReadsWhereEachStands() async throws {
        let (storage, defaults, cleanup) = try await makeStorage()
        defer { cleanup() }
        let now = Date()
        let drafts = [
            Flashcard.mint(front: "What couples respiration to ATP synthesis?", back: "A proton gradient.", sourceID: "src-1", sourceTitle: "Mitochondria",
                           quote: "couple respiration to ATP synthesis through a proton gradient", origin: .assistant, isRequested: true, at: now),
            Flashcard.mint(front: "What do uncoupling proteins do?", back: "Let protons leak back.", sourceID: "src-1", sourceTitle: "Mitochondria",
                           quote: "Uncoupling proteins let protons leak back without making ATP", origin: .assistant, isRequested: true, at: now),
            Flashcard.mint(front: "What does complex IV reduce?", back: "Oxygen, to water.", sourceID: "src-1", sourceTitle: "Mitochondria",
                           quote: "complex IV reduces oxygen to water", origin: .assistant, isRequested: true, at: now),
        ]
        let saved = try await storage.saveCardDrafts(drafts, sourceID: "src-1", sourceTitle: "Mitochondria")
        let ids = saved.added.map(\.id)
        #expect(ids.count == 3)
        let cards = ChatSavedCards(cardIDs: ids + ["not-in-any-deck"], sourceIDs: ["src-1"])

        let first = try await storage.chatSavedCards(cards, stateDefaults: defaults)
        #expect(first.map(\.id) == ids)
        #expect(first.allSatisfy { $0.toCheck != nil })
        #expect(first.map(\.face.front) == drafts.map(\.front))

        let keep = try #require(first[0].toCheck), skip = try #require(first[1].toCheck)
        let triage = await MemoryCardTriageWriter.apply([
            MemoryCardTriageDecision(card: keep, action: .keep),
            MemoryCardTriageDecision(card: skip, action: .skip),
        ], storage: storage, defaults: defaults)
        #expect(triage.failed.isEmpty)

        let after = try await storage.chatSavedCards(cards, stateDefaults: defaults)
        #expect(after.map(\.standing.label) == ["kept", "skipped", "toCheck"])
    }

    private static let config = AITaskConfig(provider: .openRouter, apiKey: "test-key", model: "z-ai/glm-5.3-flash")

    @Test("A turn's saved cards are drawn as their own row, stored at the head of its reply, and drawn again when the chat reopens")
    @MainActor
    func turnStoresAndReopensTheCards() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatSavedCards_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        try await storage.createReviewSession(id: "chat", topic: "Mitochondria", sourceIDs: [])
        let manager = ReviewSessionManager(storage: storage)
        manager.configureNavigationStateForTesting(sessionID: "chat", generationInFlight: false)
        await manager.saveLearnerMessageForTesting("turn this into flashcards")
        manager.beginTurnForTesting()

        let row = try #require(manager.completeSaveCardDraftsForTesting(result: Self.result))
        let cards = try #require(row.savedCards)
        #expect(row.detail == "3 cards to check")
        // Its own entry, drawn as the cards, not folded into the turn's steps.
        let entries = ReviewChatTranscriptEntry.grouping(manager.chatMessages)
        #expect(entries.compactMap(\.savedCards) == [cards])

        let reply = try #require(try await manager.settleReplyForTesting("Made from the passage you selected.", config: Self.config))
        // The row shows the prose alone and is still stamped with its exchange.
        #expect(reply.content == "Made from the passage you selected.")
        #expect(reply.exchangeID != nil)
        let exchanges = try await storage.loadReviewSessionExchanges(sessionID: "chat")
        let stored = try #require(exchanges.first?.evaluation)
        #expect(stored == cards.markdownLine + "\n\nMade from the passage you selected.")

        let reopened = ReviewSessionManager.reconstructedSavedCardsForTesting(from: exchanges)
        #expect(reopened.map(\.role) == ["user", "tool", "assistant"])
        #expect(reopened[1].savedCards == cards)
        #expect(reopened[2].content == "Made from the passage you selected.")

        // The next turn saved none: its reply carries no line.
        await manager.saveLearnerMessageForTesting("thanks")
        manager.beginTurnForTesting()
        _ = try await manager.settleReplyForTesting("You're welcome.", config: Self.config)
        let next = try await storage.loadReviewSessionExchanges(sessionID: "chat")
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
        #expect(next.last?.evaluation == "You're welcome.")
    }
}

private extension ChatSavedCard.Standing {
    var label: String {
        switch self {
        case .toCheck: return "toCheck"
        case .kept: return "kept"
        case .skipped: return "skipped"
        case .notOffered: return "notOffered"
        }
    }
}
