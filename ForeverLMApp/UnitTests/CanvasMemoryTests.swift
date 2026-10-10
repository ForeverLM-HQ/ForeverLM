import CoreGraphics
import Foundation
import Testing
@testable import ForeverLM

/// Memory on the Canvas (docs/knowledge-map-design.md, "Memory on the
/// Canvas"): the marks of the kept cards behind each card, Review Here's deal
/// and its tour of the Canvas, the question card's place, and the situated
/// drafter's answer and grounding.
@Suite("Memory on the Canvas")
struct CanvasMemoryTests {
    private static let day = MemoryTutorScheduler.secondsPerDay

    // MARK: Marks

    @Test("A mark counts due (answer counts now: due by now or never answered), fading (overdue past two days) and solid (scheduled ahead)")
    func markCounts() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let cards = [
            card("never", keptAt: now.addingTimeInterval(-3 * Self.day), sourceIDs: ["s1"]),
            card("due", keptAt: now.addingTimeInterval(-20 * Self.day), dueAt: now.addingTimeInterval(-Self.day), answeredAt: now.addingTimeInterval(-5 * Self.day), sourceIDs: ["s1"]),
            card("fading", keptAt: now.addingTimeInterval(-20 * Self.day), dueAt: now.addingTimeInterval(-3 * Self.day), answeredAt: now.addingTimeInterval(-8 * Self.day), sourceIDs: ["s1"]),
            card("later-today", keptAt: now.addingTimeInterval(-20 * Self.day), dueAt: now.addingTimeInterval(3_600), answeredAt: now.addingTimeInterval(-4 * Self.day), sourceIDs: ["s1"]),
            card("solid", keptAt: now.addingTimeInterval(-20 * Self.day), dueAt: now.addingTimeInterval(5 * Self.day), answeredAt: now.addingTimeInterval(-2 * Self.day), sourceIDs: ["s1"]),
        ]
        let mark = try? #require(CanvasMemoryMarks.mark(of: cards, now: now))
        #expect(mark?.cards == 5)
        #expect(mark?.due == 3, "never answered, due and fading; a card due later today waits")
        #expect(mark?.fading == 1)
        #expect(mark?.solid == 2)
        #expect(mark?.lastReviewedAt == now.addingTimeInterval(-2 * Self.day))
        #expect(mark?.dusty == false)
        #expect(CanvasMemoryMarks.mark(of: [], now: now) == nil)
    }

    @Test("A card is dusty when at least half fade, or nothing was answered or kept in 30 days")
    func dusty() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let halfFading = [
            card("a", keptAt: now.addingTimeInterval(-20 * Self.day), dueAt: now.addingTimeInterval(-4 * Self.day), answeredAt: now.addingTimeInterval(-9 * Self.day), sourceIDs: ["s"]),
            card("b", keptAt: now.addingTimeInterval(-20 * Self.day), dueAt: now.addingTimeInterval(3 * Self.day), answeredAt: now.addingTimeInterval(-Self.day), sourceIDs: ["s"]),
        ]
        #expect(try #require(CanvasMemoryMarks.mark(of: halfFading, now: now)).dusty)

        let untouched = [
            card("old", keptAt: now.addingTimeInterval(-60 * Self.day), dueAt: now.addingTimeInterval(20 * Self.day), answeredAt: now.addingTimeInterval(-40 * Self.day), sourceIDs: ["s"]),
        ]
        #expect(try #require(CanvasMemoryMarks.mark(of: untouched, now: now)).dusty)

        let keptLastWeek = [card("new", keptAt: now.addingTimeInterval(-7 * Self.day), sourceIDs: ["s"])]
        let fresh = try #require(CanvasMemoryMarks.mark(of: keptLastWeek, now: now))
        #expect(!fresh.dusty, "a card kept a week ago and waiting for its first review is not dust")
        #expect(fresh.due == 1)

        let keptLongAgo = [card("waiting", keptAt: now.addingTimeInterval(-45 * Self.day), sourceIDs: ["s"])]
        #expect(try #require(CanvasMemoryMarks.mark(of: keptLongAgo, now: now)).dusty)
    }

    @Test("An Idea's mark sums its evidence sources, a card on two of them counted once; a Doc sums what it cites; a team copy reads the learner's own source")
    func ideaSumsEvidence() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let content = KnowledgeMapContent(
            nodes: [
                node("source:s1"), node("source:s2"), node("source:s3"), node("source:team-s4"),
                node("idea:i1", kind: "idea"), node("idea:bare", kind: "idea"), node("doc:d1", kind: "doc"),
            ],
            links: [
                KnowledgeMapLink(a: "idea:i1", b: "source:s1", kind: "idea"),
                KnowledgeMapLink(a: "idea:i1", b: "source:s2", kind: "idea"),
                KnowledgeMapLink(a: "idea:i1", b: "doc:d1", kind: "idea"),
                KnowledgeMapLink(a: "doc:d1", b: "source:s3", kind: "doc"),
                KnowledgeMapLink(a: "source:s1", b: "source:s3", kind: "chat"),
            ]
        )
        let groups = CanvasMemoryMarks.refSources(content: content) { $0 == "team-s4" ? "s4" : $0 }
        #expect(groups["idea:i1"] == ["s1", "s2"], "an Idea's sources are its evidence of kind source")
        #expect(groups["doc:d1"] == ["s3"])
        #expect(groups["source:team-s4"] == ["team-s4", "s4"])
        #expect(groups["idea:bare"] == nil)

        let cards = [
            card("on-s1", keptAt: now.addingTimeInterval(-3 * Self.day), sourceIDs: ["s1"]),
            card("on-both", keptAt: now.addingTimeInterval(-3 * Self.day), dueAt: now.addingTimeInterval(4 * Self.day), answeredAt: now.addingTimeInterval(-Self.day), sourceIDs: ["s1", "s2"]),
            card("on-s3", keptAt: now.addingTimeInterval(-3 * Self.day), sourceIDs: ["s3"]),
            card("on-s4", keptAt: now.addingTimeInterval(-3 * Self.day), sourceIDs: ["s4"]),
        ]
        let marks = CanvasMemoryMarks.marks(for: groups, cards: cards, now: now)
        #expect(marks["idea:i1"]?.cards == 2)
        #expect(marks["idea:i1"]?.due == 1)
        #expect(marks["idea:i1"]?.solid == 1)
        #expect(marks["source:s1"]?.cards == 2)
        #expect(marks["source:s2"]?.cards == 1)
        #expect(marks["doc:d1"]?.cards == 1)
        #expect(marks["source:team-s4"]?.cards == 1)
        #expect(marks["idea:bare"] == nil, "a card with no kept card has no mark")
    }

    @Test("The marks read from a store: each source's kept cards at their schedules, and the read narrowed to the sources asked")
    func marksFromStore() throws {
        let store = try KnowledgeStore(inMemory: true)
        try saveSource(store, id: "src-1", text: Self.mitoText)
        try saveSource(store, id: "src-2", text: Self.sleepText)
        let now = Date()
        // Answered Remembered once: stable for 4.2 days from the answer.
        let fading = try keep(store, "fading", quote: "a proton gradient", keptAt: now.addingTimeInterval(-20 * Self.day))
        _ = try store.recordSelfGradedMemoryCardAttempt(memoryItemID: fading.id, prompt: "Front fading", remembered: true, sessionKey: "earlier", practice: true, at: now.addingTimeInterval(-10 * Self.day))
        let due = try keep(store, "due", quote: "couple respiration to ATP synthesis", keptAt: now.addingTimeInterval(-20 * Self.day))
        _ = try store.recordSelfGradedMemoryCardAttempt(memoryItemID: due.id, prompt: "Front due", remembered: true, sessionKey: "earlier", practice: true, at: now.addingTimeInterval(-5 * Self.day))
        let solid = try keep(store, "solid", quote: "Uncoupling proteins let protons leak back", keptAt: now.addingTimeInterval(-20 * Self.day))
        _ = try store.recordSelfGradedMemoryCardAttempt(memoryItemID: solid.id, prompt: "Front solid", remembered: true, sessionKey: "earlier", practice: true, at: now.addingTimeInterval(-Self.day))
        _ = try keep(store, "never", quote: "without making ATP", keptAt: now.addingTimeInterval(-2 * Self.day))
        _ = try keep(store, "sleep", on: "src-2", quote: "Sleep consolidates", keptAt: now.addingTimeInterval(-60 * Self.day))

        let read = try store.canvasMemoryRead(anchoredOn: ["src-1"])
        #expect(read.items.count == 4, "the cards on src-2 are not read for src-1")
        let cards = CanvasMemoryCard.cards(items: read.items, attempts: read.attempts)
        let mark = try #require(CanvasMemoryMarks.marks(for: ["source:src-1": ["src-1"]], cards: cards, now: now)["source:src-1"])
        #expect(mark.cards == 4)
        #expect(mark.due == 3)
        #expect(mark.fading == 1)
        #expect(mark.solid == 1)
        #expect(!mark.dusty)

        let everything = try store.canvasMemoryRead(anchoredOn: nil)
        let all = CanvasMemoryCard.cards(items: everything.items, attempts: everything.attempts)
        let sleep = try #require(CanvasMemoryMarks.marks(for: ["source:src-2": ["src-2"]], cards: all, now: now)["source:src-2"])
        #expect(sleep.cards == 1)
        #expect(sleep.dusty, "kept two months ago and never answered")
        #expect(try store.canvasMemoryRead(anchoredOn: []).items.isEmpty)
    }

    @Test("The page's Memory payload carries lastReviewedAt as milliseconds since 1970")
    func payload() throws {
        let answered = Date(timeIntervalSince1970: 1_790_000_000)
        let payload = KnowledgeMapMemoryPayload(enabled: true, marks: [
            "source:s": KnowledgeMapMemoryMark(cards: 2, due: 1, fading: 0, solid: 1, lastReviewedAt: answered, dusty: false),
        ])
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        #expect(object?["enabled"] as? Bool == true)
        let mark = (object?["marks"] as? [String: Any])?["source:s"] as? [String: Any]
        #expect((mark?["lastReviewedAt"] as? NSNumber)?.doubleValue == 1_790_000_000_000)
        #expect((mark?["due"] as? NSNumber)?.intValue == 1)
    }

    // MARK: Review Here

    @Test("Review Here deals the due cards — most overdue first, then those never answered — and anchors each to its source's own card before an Idea's")
    func dueDeal() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let (overdue, overdueAnswer) = reviewed("overdue", source: "s1", answeredAt: now.addingTimeInterval(-9 * Self.day))
        let (lessOverdue, lessAnswer) = reviewed("less", source: "s2", answeredAt: now.addingTimeInterval(-5 * Self.day))
        let (notDue, notDueAnswer) = reviewed("not-due", source: "s1", answeredAt: now.addingTimeInterval(-Self.day))
        let never = item("never", source: "s2", keptAt: now.addingTimeInterval(-2 * Self.day))
        let elsewhere = item("elsewhere", source: "s9", keptAt: now.addingTimeInterval(-2 * Self.day))
        let items = [overdue, lessOverdue, notDue, never, elsewhere]
        let anchors = CanvasReviewDeal.anchors(items: items, refs: [
            (ref: "source:s1", sourceIDs: ["s1"]),
            (ref: "idea:i", sourceIDs: ["s1", "s2"]),
        ])
        #expect(anchors["overdue"] == "source:s1")
        #expect(anchors["less"] == "idea:i")
        #expect(anchors["elsewhere"] == nil)

        let dealt = CanvasReviewDeal.deal(
            items: items,
            attempts: [overdueAnswer, lessAnswer, notDueAnswer],
            anchors: anchors,
            positions: [:],
            now: now
        )
        #expect(dealt.kind == .due)
        // No spots: the anchors in the order they first appear in the deal.
        #expect(dealt.entries.map(\.id) == ["overdue", "less", "never"])
        #expect(dealt.anchors == ["overdue": "source:s1", "less": "idea:i", "never": "idea:i"])
    }

    @Test("With nothing due, Review Here practises the weakest cards, at most twelve")
    func practiceDeal() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var items: [MemoryItem] = []
        var attempts: [MemoryAttempt] = []
        for index in 0..<15 {
            // Answered Remembered once, a day apart: every one holds ahead.
            let (card, answer) = reviewed("c\(index)", source: "s", answeredAt: now.addingTimeInterval(-Double(index % 3) * 3_600 - 600))
            items.append(card)
            attempts.append(answer)
        }
        // A forgotten one is the weakest: its stability halved.
        let weak = item("weak", source: "s", keptAt: now.addingTimeInterval(-10 * Self.day))
        attempts.append(graded("weak", .good, at: now.addingTimeInterval(-6 * Self.day)))
        attempts.append(graded("weak", .again, at: now.addingTimeInterval(-2 * Self.day)))
        items.append(weak)
        let anchors = Dictionary(uniqueKeysWithValues: items.map { ($0.id, "source:s") })
        let dealt = CanvasReviewDeal.deal(items: items, attempts: attempts, anchors: anchors, positions: [:], now: now)
        #expect(dealt.kind == .practice)
        #expect(dealt.entries.count == CanvasReviewDeal.practiceLimit)
        #expect(dealt.entries.first?.id == "weak")
    }

    @Test("Review Here asks its cards as a tour: from the top-left-most anchor to the nearest next, an anchor's cards together, anchors with no spot last")
    func tour() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func entry(_ id: String) -> MemoryCardQueue.Entry {
            let item = item(id, source: "s", keptAt: now.addingTimeInterval(-3 * Self.day))
            return MemoryCardQueue.Entry(item: item, schedule: MemoryTutorScheduler.initialSchedule(for: item), bucket: .new, notebookID: nil, daysOverdue: 0)
        }
        let entries = ["far-1", "near-1", "start-1", "far-2", "loose", "start-2", "middle"].map(entry)
        let anchors = [
            "start-1": "idea:start", "start-2": "idea:start",
            "near-1": "idea:near", "middle": "idea:middle",
            "far-1": "idea:far", "far-2": "idea:far",
            "loose": "source:loose",
        ]
        let positions: [String: (x: Double, y: Double)] = [
            "idea:far": (2_000, 2_000),
            "idea:start": (0, 0),
            "idea:middle": (900, 900),
            "idea:near": (300, 0),
        ]
        let toured = CanvasReviewDeal.tour(entries, anchors: anchors, positions: positions)
        #expect(toured.map(\.id) == ["start-1", "start-2", "near-1", "middle", "far-1", "far-2", "loose"])
    }

    @MainActor
    @Test("A review in place is the card review's practice: a card not due is shown and its answer not written, so no interval stretches")
    func practiceNeverStretches() async throws {
        let (storage, cleanup) = try await makeStorage()
        defer { cleanup() }
        let now = Date()
        let face = MemoryCard(cardID: "holding", front: "What couples respiration to ATP synthesis?", back: "A proton gradient.", origin: .drafted, deckID: MemoryCard.draftDeckID(sourceID: "src-1"))
        let kept = try await storage.keepMemoryCard(face, sourceID: "src-1", quote: "a proton gradient", at: now.addingTimeInterval(-10 * Self.day))
        _ = try await storage.recordSelfGradedMemoryCardAttempt(memoryItemID: kept.id, prompt: face.front, remembered: true, sessionKey: "earlier", practice: true, at: now.addingTimeInterval(-Self.day))

        let read = try await storage.canvasMemoryRead(anchoredOn: ["src-1"])
        let dealt = CanvasReviewDeal.deal(
            items: read.items,
            attempts: read.attempts,
            anchors: [kept.id: "source:src-1"],
            positions: ["source:src-1": (0, 0)],
            now: now
        )
        #expect(dealt.kind == .practice)
        let before = MemoryTutorScheduler.schedule(item: kept, attempts: read.attempts)
        let entry = try #require(dealt.entries.first)
        let card = try #require(MemoryCardSitting.Card.dealt(entry, attempts: read.attempts) { _ in nil })
        let session = MemoryCardSessionModel(
            sitting: MemoryCardSitting(key: MemoryCardSitting.newKey(day: "2026-10-05"), kind: .practice, cards: [card]),
            scope: .allNotebooks,
            scopeTitle: "Canvas",
            isCommitted: false,
            sourceTitles: [:],
            storage: storage,
            followup: { MemoryCardSessionModel.Followup(cards: [], dayHasCardsLeft: true) }
        )
        session.showAnswer()
        session.answer(remembered: true)
        await session.waitForWrites()
        #expect(session.saveError == nil)
        let after = try await storage.canvasMemoryRead(anchoredOn: ["src-1"])
        #expect(after.attempts.count == 1, "the practice answer to a card not due is not written")
        #expect(MemoryTutorScheduler.schedule(item: kept, attempts: after.attempts).dueAt == before.dueAt)
    }

    // MARK: The question card's place

    @Test("The question floats right of the card, left when the right has no room, and stays inside the pane")
    func placement() {
        let pane = CGSize(width: 1_200, height: 800)
        let card = CGSize(width: KnowledgeMapReviewPlacement.cardWidth, height: 300)
        let right = KnowledgeMapReviewPlacement.origin(beside: CGRect(x: 300, y: 300, width: 260, height: 130), card: card, pane: pane)
        #expect(right.x == 300 + 260 + KnowledgeMapReviewPlacement.gap)
        // The card's middle (365) less half the question card: typed, since
        // `365 - 150` alone is an Int to the macro and never equals a CGFloat.
        #expect(right.y == CGFloat(365 - 150))
        let left = KnowledgeMapReviewPlacement.origin(beside: CGRect(x: 800, y: 300, width: 260, height: 130), card: card, pane: pane)
        #expect(left.x == 800 - KnowledgeMapReviewPlacement.gap - card.width)
        let low = KnowledgeMapReviewPlacement.origin(beside: CGRect(x: 100, y: 760, width: 260, height: 130), card: card, pane: pane)
        #expect(low.y == 800 - KnowledgeMapReviewPlacement.verticalMargin - 300)
        let docked = KnowledgeMapReviewPlacement.docked(card: card, pane: pane)
        #expect(docked.x == 1_200 - KnowledgeMapReviewPlacement.sideMargin - card.width)
    }

    // MARK: Cards from what the learner made sense of

    @Test("The situated drafter's answer: an anchor's two cards at most, a term's one, each on the passage that prints its quote, refusals said")
    func parsing() throws {
        let idea = SituatedAnchor(
            kind: .idea,
            text: "Uncoupling wastes the gradient as heat",
            sourceIDs: ["src-1"],
            passages: [
                SituatedPassage(sourceID: "src-1", text: "Mitochondria couple respiration to ATP synthesis through a proton gradient."),
                SituatedPassage(sourceID: "src-1", text: "Uncoupling proteins let protons leak back without making ATP."),
            ]
        )
        let term = SituatedAnchor(
            kind: .term,
            text: "Proton leak: protons crossing the inner membrane without making ATP",
            sourceIDs: ["src-2"],
            passages: [SituatedPassage(sourceID: "src-2", text: "Proton leak dissipates the gradient as heat.")]
        )
        let labels = ["src-1": "\u{201C}Mitochondria\u{201D} \u{2014} Wolf \u{00B7} 2024", "src-2": "\u{201C}Heat\u{201D}"]
        let turn = SituatedCardDrafting.Turn(anchors: [idea, term], labels: labels)
        #expect(turn.passages.map(\.handle) == ["P1", "P2", "P3"])
        #expect(turn.userMessage.contains("[A1] Idea, in the learner's own words: Uncoupling wastes the gradient as heat"))
        #expect(turn.userMessage.contains("[P3] From \u{201C}Heat\u{201D}:"))
        #expect(turn.title == "Mitochondria")

        let response = """
        ```json
        {"cards": [
          {"anchor": "A1", "passage": "P1", "front": "What do uncoupling proteins let protons do?", "back": "Leak back across without making ATP.", "why": "The leak bypasses ATP synthase.", "quote": "Uncoupling proteins let protons leak back without making ATP.", "difficulty": "medium"},
          {"anchor": "A1", "passage": "P1", "front": "What couples respiration to ATP synthesis?", "back": "A proton gradient.", "quote": "couple respiration to ATP synthesis through a proton gradient"},
          {"anchor": "A1", "passage": "P2", "front": "A third card on one idea?", "back": "Too many.", "quote": "Uncoupling proteins let protons leak back"},
          {"anchor": "A2", "passage": "P3", "front": "What is proton leak?", "back": "Protons crossing without making ATP.", "quote": "Proton leak dissipates the gradient as heat."},
          {"anchor": "A2", "passage": "P3", "front": "A second card on a term?", "back": "No.", "quote": "Proton leak dissipates the gradient"},
          {"anchor": "A9", "front": "Whose anchor?", "back": "None.", "quote": "heat"},
          {"anchor": "A1", "front": "No answer", "back": " "},
          {"anchor": "A1", "front": "See https://example.com", "back": "A link.", "quote": "proton gradient"}
        ]}
        ```
        """
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let parsed = try SituatedCardDrafting.drafts(from: response, turn: turn, labels: labels, at: now)
        #expect(parsed.drafts.map(\.front) == [
            "What do uncoupling proteins let protons do?",
            "What couples respiration to ATP synthesis?",
            "What is proton leak?",
        ])
        #expect(parsed.drafts.map(\.sourceID) == ["src-1", "src-1", "src-2"])
        #expect(parsed.drafts.map(\.sourceTitle) == ["Mitochondria", "Mitochondria", "Heat"])
        #expect(parsed.drafts.allSatisfy { $0.isRequested && $0.origin == .drafted })
        let seeds = parsed.drafts.compactMap(\.seed)
        #expect(seeds.count == 3)
        #expect(seeds[0].hasPrefix("idea:canvas:") && seeds[0].hasSuffix("#1"))
        #expect(seeds[1].hasPrefix("idea:canvas:") && seeds[1].hasSuffix("#2"))
        #expect(seeds[2].hasPrefix("term:") && seeds[2].hasSuffix("#1"))
        #expect(seeds[0] == SituatedCardDrafting.seedKey(for: idea, card: 1), "the same Idea drafted again is the same seed")
        #expect(parsed.refused.count == 5)
        #expect(throws: SituatedCardDrafting.ParseError.self) {
            _ = try SituatedCardDrafting.drafts(from: "no cards here", turn: turn, labels: labels, at: now)
        }
    }

    @MainActor
    @Test("Situated drafts are saved through saveCardDrafts: a quote its source does not print is reported not grounded, and the same Idea drafted again adds nothing")
    func groundingThroughSaveCardDrafts() async throws {
        let (storage, cleanup) = try await makeStorage()
        defer { cleanup() }
        let anchor = SituatedAnchor(
            kind: .idea,
            text: "Mitochondria run on a proton gradient",
            sourceIDs: ["src-1"],
            passages: [SituatedPassage(sourceID: "src-1", text: "Mitochondria couple respiration to ATP synthesis through a proton gradient.")]
        )
        let backend = CannedSituatedBackend(response: """
        {"cards": [
          {"anchor": "A1", "passage": "P1", "front": "What couples respiration to ATP synthesis in mitochondria?", "back": "A proton gradient.", "quote": "couple respiration to ATP synthesis through a proton gradient"},
          {"anchor": "A1", "passage": "P1", "front": "What powers the gradient?", "back": "Sunlight.", "quote": "the gradient is powered by sunlight"}
        ]}
        """)
        let labels = ["src-1": "\u{201C}Mitochondria\u{201D}"]
        let report = try await SituatedCardDrafter.draft([anchor], labels: labels, storage: storage, backend: backend)
        #expect(report.drafted == 1)
        #expect(report.notGrounded == 1)
        #expect(report.outcome == SituatedCardDrafter.Outcome(drafted: 1, notGrounded: 1, sourceIDs: ["src-1"]))
        #expect(backend.lastSystem == Prompts.situatedCards)

        let again = try await SituatedCardDrafter.draft([anchor], labels: labels, storage: storage, backend: backend)
        #expect(again.drafted == 0)
        #expect(again.alreadyDrafted == 1)
        #expect(again.nothingDraftedMessage.hasPrefix("No new cards"))

        let nothingToStandOn = SituatedAnchor(kind: .idea, text: "An idea with no passage", sourceIDs: ["src-1"])
        let skipped = try await SituatedCardDrafter.draft([nothingToStandOn], labels: labels, storage: storage, backend: backend)
        #expect(skipped.anchorsWithoutPassages == 1)
        #expect(skipped.drafted == 0)
    }

    @Test("The drafting toast names what it drafts from: ideas and arrows, never Canvas cards")
    func anchorsPhrase() {
        let idea = SituatedAnchor(kind: .idea, text: "An idea", sourceIDs: ["s"])
        let arrow = SituatedAnchor(kind: .relation, text: "A \u{2192} B", sourceIDs: ["s"])
        #expect(StudioViewModel.knowledgeMapAnchorsPhrase([idea]) == "1 idea")
        #expect(StudioViewModel.knowledgeMapAnchorsPhrase([idea, idea, arrow]) == "2 ideas and 1 arrow")
        #expect(StudioViewModel.knowledgeMapAnchorsPhrase([arrow, arrow]) == "2 arrows")
    }

    @Test("A passage is cut on whole words around what the query names")
    func passageCut() {
        let words = (1...300).map { "word\($0)" }
        let text = (words[0..<150] + ["mitochondria"] + words[150...]).joined(separator: "  ")
        let cut = SituatedPassageCutter.excerpt(text, query: "How do mitochondria work?", maxLength: 200)
        #expect(cut.contains("mitochondria"))
        #expect(cut.count <= 200)
        #expect(!cut.hasPrefix(" ") && !cut.hasSuffix(" "))
        #expect(text.contains(cut.replacingOccurrences(of: " ", with: "  ")), "the cut is the text's own words")
        #expect(SituatedPassageCutter.excerpt("Short passage.", query: "x") == "Short passage.")
    }

    // MARK: Helpers

    private static let mitoText = "Mitochondria couple respiration to ATP synthesis through a proton gradient. Uncoupling proteins let protons leak back without making ATP."
    private static let sleepText = "Sleep consolidates what was learned during the day."

    private func card(
        _ id: String,
        keptAt: Date,
        dueAt: Date? = nil,
        answeredAt: Date? = nil,
        sourceIDs: Set<String>
    ) -> CanvasMemoryCard {
        let schedule = MemorySchedule(
            memoryItemID: id,
            dueAt: dueAt ?? keptAt.addingTimeInterval(Self.day),
            lastAttemptAt: answeredAt,
            lastSuccessAt: answeredAt,
            stability: answeredAt == nil ? 0 : 4.2,
            repetitionCount: answeredAt == nil ? 0 : 1
        )
        return CanvasMemoryCard(itemID: id, sourceIDs: sourceIDs, schedule: schedule, lastAnsweredAt: answeredAt, keptAt: keptAt)
    }

    private func node(_ ref: String, kind: String = "source") -> KnowledgeMapNode {
        KnowledgeMapNode(ref: ref, kind: kind, type: kind, title: ref, sub: "", detail: [], shore: "")
    }

    private func item(_ id: String, source: String, keptAt: Date) -> MemoryItem {
        let face = MemoryCard(cardID: id, front: "Front of \(id)", back: "Back of \(id)", origin: .drafted)
        return MemoryItem(
            id: id,
            kind: .concept,
            target: face.back,
            rubricJSON: (try? face.rubricJSON()) ?? "",
            sources: [
                MemoryItemSource(
                    id: "anchor-\(id)",
                    memoryItemID: id,
                    sourceID: source,
                    excerpt: "The passage behind \(id)",
                    sourceSHA256: String(repeating: "a", count: 64),
                    sortIndex: 0
                ),
            ],
            createdAt: keptAt,
            updatedAt: keptAt
        )
    }

    private func graded(_ itemID: String, _ rating: MemoryScheduleRating, at: Date) -> MemoryAttempt {
        MemoryAttempt(
            id: "attempt-\(itemID)-\(Int(at.timeIntervalSinceReferenceDate))",
            memoryItemID: itemID,
            prompt: "Front of \(itemID)",
            learnerAnswer: MemoryAttempt.selfGradedAnswer,
            score: rating == .again ? 0 : 1,
            scheduleRating: rating,
            gradeState: .graded,
            attemptedAt: at
        )
    }

    /// A card answered Remembered once at `answeredAt`, due 4.2 days later.
    private func reviewed(_ id: String, source: String, answeredAt: Date) -> (MemoryItem, MemoryAttempt) {
        (item(id, source: source, keptAt: answeredAt.addingTimeInterval(-3 * Self.day)), graded(id, .good, at: answeredAt))
    }

    private func saveSource(_ store: KnowledgeStore, id: String, text: String) throws {
        var source = StudioArticle(url: "https://example.com/\(id)", title: id, sourceType: .article, discoveryOrigin: .manual, id: id)
        source.normalizedURL = URLNormalizer.normalize(source.url)
        source.content = text
        source.state = .ready
        try store.saveSource(source)
    }

    private func keep(_ store: KnowledgeStore, _ id: String, on sourceID: String = "src-1", quote: String, keptAt: Date) throws -> MemoryItem {
        let face = MemoryCard(cardID: id, front: "Front \(id)", back: "Back \(id)", origin: .drafted, deckID: MemoryCard.draftDeckID(sourceID: sourceID))
        return try store.keepMemoryCard(face, sourceID: sourceID, quote: quote, at: keptAt)
    }

    /// Storage on a folder of its own holding src-1.
    private func makeStorage() async throws -> (StorageService, () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CanvasMemory_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = StorageService(storeRoot: root)
        var source = StudioArticle(url: "https://example.com/mito", title: "Mitochondria", sourceType: .article, discoveryOrigin: .manual, id: "src-1")
        source.normalizedURL = URLNormalizer.normalize(source.url)
        source.content = Self.mitoText
        source.wordCount = 20
        source.state = .ready
        try await storage.saveSource(source)
        return (storage, { try? FileManager.default.removeItem(at: root) })
    }
}

/// The drafting model's answer, canned.
private final class CannedSituatedBackend: SituatedCardBackend, @unchecked Sendable {
    let response: String
    private(set) var lastSystem: String?

    init(response: String) {
        self.response = response
    }

    func draft(system: String, user: String, maxTokens: Int, title: String) async throws -> String {
        lastSystem = system
        return response
    }
}
