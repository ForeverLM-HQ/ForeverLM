import Foundation
import Testing
@testable import ForeverLM

/// Memory as cards, stage two: the card face in its item, its identity, Keep,
/// retire, start over, self-graded answers, and the `cards.state.<deckID>` row.
@Suite("Memory cards: identity and Keep")
struct MemoryCardTests {
    private static let text = "Mitochondria couple respiration to ATP synthesis through a proton gradient. "
        + "Uncoupling proteins let protons leak back without making ATP."
    private static let quote = "couple respiration to ATP synthesis through a proton gradient"
    private static let day = MemoryTutorScheduler.secondsPerDay
    private static let keptAt = Date(timeIntervalSinceReferenceDate: 812_000_000)

    private func makeStore() throws -> KnowledgeStore {
        let store = try KnowledgeStore(inMemory: true)
        var source = StudioArticle(url: "https://example.com/mito", title: "Mitochondria", sourceType: .article, discoveryOrigin: .manual, id: "src-1")
        source.normalizedURL = URLNormalizer.normalize(source.url)
        source.content = Self.text
        source.state = .ready
        try store.saveSource(source)
        return store
    }

    private func drafted(
        _ cardID: String = "card-A",
        back: String = "A proton gradient across the inner membrane.",
        why: [String] = ["Uncoupling breaks the link and ATP synthesis stops."]
    ) -> MemoryCard {
        MemoryCard(
            cardID: cardID,
            front: "What couples respiration to ATP synthesis?",
            back: back,
            why: why,
            origin: .drafted,
            deckID: MemoryCard.draftDeckID(sourceID: "src-1")
        )
    }

    private func cardlessItem(target: String, criteria: [String], id: String = "cardless-item") -> MemoryItem {
        let rubric = try! JSONSerialization.data(withJSONObject: ["criteria": criteria], options: [.sortedKeys])
        return MemoryItem(
            id: id,
            kind: .concept,
            target: target,
            rubricJSON: String(data: rubric, encoding: .utf8)!,
            sources: [MemoryItemSource(id: "anchor-\(id)", memoryItemID: id, sourceID: "src-1", excerpt: Self.quote, sourceSHA256: "h", sortIndex: 0)],
            createdAt: Self.keptAt,
            updatedAt: Self.keptAt
        )
    }

    // MARK: Identity and the rubric

    @Test("A card's item id is in its own namespace: the same for the same card id, another for another")
    func cardItemIdentity() {
        let id = MemoryTutorIdentity.cardItemID(cardID: "card-A")
        #expect(id.hasPrefix("memory-card-v1-"))
        #expect(id.count == "memory-card-v1-".count + 64)
        #expect(MemoryTutorIdentity.cardItemID(cardID: " card-A\n") == id)
        #expect(MemoryTutorIdentity.cardItemID(cardID: "card-B") != id)
    }

    @Test("A card's rubric is written in one byte order and reads back as the same card")
    func rubricRoundTrip() throws {
        let figure1 = try #require(MemoryCardImage(
            reference: "![Figure 1](foreverlm://image/src-1/page/3?crop=0.1,0.2,0.4,0.3)"
        ))
        let figure2 = try #require(MemoryCardImage(
            target: "foreverlm://image/generated/12345678-abcd-1234-abcd-123456789abc",
            alt: "Comparison diagram"
        ))
        let card = MemoryCard(
            cardID: "card-A", front: "What does ATP/ADP exchange need?", back: "The carrier.",
            why: ["  It crosses the inner membrane. ", ""], origin: .drafted, deckID: "carddeck-src-1",
            frontImages: [figure1], backImages: [figure1, figure2]
        )
        let rubric = try #require(try JSONSerialization.jsonObject(with: Data(card.rubricJSON().utf8)) as? [String: Any])
        let storedCard = try #require(rubric["card"] as? [String: Any])
        let storedFront = try #require((storedCard["frontImages"] as? [[String: Any]])?.first)
        let storedBack = try #require(storedCard["backImages"] as? [[String: Any]])
        #expect(storedFront["target"] as? String == figure1.target)
        #expect(storedBack.compactMap { $0["alt"] as? String } == [figure1.alt, figure2.alt])
        #expect(try card.rubricJSON() == card.rubricJSON())

        let item = try card.memoryItem(
            id: MemoryTutorIdentity.cardItemID(cardID: card.cardID),
            anchors: [MemorySourceAnchorValidation(sourceID: "src-1", excerpt: Self.quote, sourceSHA256: "h")],
            at: Self.keptAt
        )
        #expect(item.target == "The carrier.")
        #expect(MemoryCard(storedIn: item) == card)

        // A card with no why is graded by its back, and a why that only
        // repeats the back is none.
        let bare = MemoryCard(cardID: "card-B", front: "Q", back: "A", why: ["A"], origin: .assistant)
        #expect(bare.why.isEmpty)
        #expect(try bare.rubricJSON() == #"{"card":{"cardID":"card-B","front":"Q","origin":"assistant"},"criteria":["A"]}"#)

        // A newer device's origin reads as itself; the difficulty an older build stored is read past.
        let future = MemoryItem(
            id: "future", kind: .concept, target: "Back",
            rubricJSON: #"{"card":{"cardID":"c","difficulty":"hard","front":"Front","origin":"lecture"},"criteria":["Back"]}"#,
            sources: item.sources
        )
        let read = try #require(MemoryCard(storedIn: future))
        #expect(read.origin.rawValue == "lecture")
        #expect(read.front == "Front")
        #expect(MemoryCard(storedIn: cardlessItem(target: "Q — A", criteria: ["A"])) == nil)
    }

    @Test("A card face takes a saved animation by its site address, lowercased and bare, and nothing that is not one")
    func animationTargets() throws {
        let id = "77bbc5f1-0c5e-42b0-9b61-9659c875bd5b"
        let address = "foreverlm-site://\(id)/"
        for written in [
            address,
            "foreverlm-site://\(id)",
            "  FOREVERLM-SITE://\(id.uppercased())/  ",
            "foreverlm-site://\(id)/index.html",
        ] {
            let image = try #require(MemoryCardImage(target: written, alt: "Scaling"), "\(written) is an animation")
            #expect(image.target == address)
            #expect(image.animationID == id)
            #expect(image.isAnimation)
            #expect(image.animationURL == URL(string: address))
        }

        // The Markdown line and the bare address read the same, and a missing
        // alt text says what it is.
        let fromMarkdown = try #require(MemoryCardImage(reference: "![Scaling, in motion](\(address))"))
        #expect(fromMarkdown.alt == "Scaling, in motion")
        #expect(fromMarkdown.markdown == "![Scaling, in motion](\(address))")
        #expect(MemoryCardImage(reference: fromMarkdown.markdown) == fromMarkdown)
        #expect(MemoryCardImage(reference: address)?.alt == "Animation")
        #expect(MemoryCardImage(target: address, alt: "  ")?.alt == "Animation")
        #expect(MemoryCardImage(target: "foreverlm://image/src-1/page/2", alt: "")?.alt == "Image")

        // A picture is no animation.
        let picture = try #require(MemoryCardImage(target: "foreverlm://image/src-1/page/2", alt: "Figure"))
        #expect(!picture.isAnimation)
        #expect(picture.animationID == nil)
        #expect(picture.animationURL == nil)

        // What is not the animation's own page is no card face: a step of it,
        // a file of it, a fragment, another scheme, a web address, a local path.
        for refused in [
            "foreverlm-site://\(id)/?step=2",
            "foreverlm-site://\(id)/#top",
            "foreverlm-site://\(id)/pages/two.html",
            "foreverlm-site:///index.html",
            "foreverlm-site://../",
            "https://example.com/\(id)/",
            "foreverlm://site/\(id)",
            "/Users/someone/animation/index.html",
            "",
        ] {
            #expect(MemoryCardImage(target: refused) == nil, "\(refused) is not an animation address")
        }
    }

    @Test("A face keeps its pictures in order, four at most, and only its first animation")
    func faceListCapsOneAnimation() throws {
        let one = try #require(MemoryCardImage(target: "foreverlm-site://anim-one/", alt: "One"))
        let two = try #require(MemoryCardImage(target: "foreverlm-site://anim-two/", alt: "Two"))
        let pictures = try (1...5).map { try #require(MemoryCardImage(target: "foreverlm://image/src-1/page/\($0)", alt: "Figure \($0)")) }

        #expect(MemoryCardImage.faceList([pictures[0], one, two, pictures[1]]) == [pictures[0], one, pictures[1]])
        #expect(MemoryCardImage.faceList([one, two]) == [one])
        #expect(MemoryCardImage.faceList(pictures) == Array(pictures.prefix(MemoryCard.maximumImagesPerFace)))
        #expect(MemoryCardImage.faceList(pictures + [one]) == Array(pictures.prefix(4)), "the animation counts toward the four")
        #expect(MemoryCardImage.faceList([]).isEmpty)

        let split = MemoryCardImage.split([pictures[0], one, pictures[1]])
        #expect(split.pictures == [pictures[0], pictures[1]])
        #expect(split.animation == one)
        #expect(MemoryCardImage.split([pictures[0]]).animation == nil)

        // Every writer of a face goes through it: the card, and a draft.
        let card = MemoryCard(cardID: "card-A", front: "Q", back: "A", origin: .assistant, backImages: [one, pictures[0], two])
        #expect(card.backImages == [one, pictures[0]])
        let capped = Flashcard(
            id: "card-a", front: "Q", back: "A",
            frontImages: [two, one], backImages: [one, two, pictures[0]]
        )
        #expect(capped.frontImages == [two])
        #expect(capped.backImages == [one, pictures[0]])
    }

    @Test("An animation on a face is kept in the same {target, alt} entry as a picture: the rubric, the item and a deck read it back, no schema change")
    func animationStorageRoundTrip() throws {
        let animation = try #require(MemoryCardImage(
            reference: "![Heart rate against body mass](foreverlm-site://77bbc5f1-0c5e-42b0-9b61-9659c875bd5b/)"
        ))
        let chart = try #require(MemoryCardImage(target: "foreverlm://image/src-1/page/3", alt: "Chart"))
        let card = MemoryCard(
            cardID: "card-anim", front: "Why do bigger animals have slower hearts?", back: "Metabolic rate scales as mass to the 3/4.",
            origin: .assistant, deckID: "carddeck-src-1", frontImages: [], backImages: [chart, animation]
        )

        // The rubric stores the animation as an entry like a picture's.
        let rubric = try #require(try JSONSerialization.jsonObject(with: Data(card.rubricJSON().utf8)) as? [String: Any])
        let stored = try #require((rubric["card"] as? [String: Any])?["backImages"] as? [[String: String]])
        #expect(stored == [
            ["target": chart.target, "alt": "Chart"],
            ["target": "foreverlm-site://77bbc5f1-0c5e-42b0-9b61-9659c875bd5b/", "alt": "Heart rate against body mass"],
        ])
        #expect(Set(try #require((rubric["card"] as? [String: Any])).keys) == ["backImages", "cardID", "deckID", "front", "origin"], "no new key")
        #expect(try card.rubricJSON() == card.rubricJSON())

        // Kept, it reads back as the same card; a device that knows no
        // animations reads the entry as no picture and shows the rest.
        let item = try card.memoryItem(
            id: MemoryTutorIdentity.cardItemID(cardID: card.cardID),
            anchors: [MemorySourceAnchorValidation(sourceID: "src-1", excerpt: Self.quote, sourceSHA256: "h")],
            at: Self.keptAt
        )
        #expect(MemoryCard(storedIn: item) == card)
        #expect(MemoryCardImage.readRubric(stored) == [chart, animation])
        #expect(MemoryCardImage.readRubric([["target": "foreverlm-site://x/?step=1", "alt": "A step"]]).isEmpty)

        // A draft waiting in To Check is a deck Page: its Markdown carries the
        // animation as a "Back image:" line and parses to the same draft.
        var drafted = draft(requested: false, id: "card-a")
        drafted.backImages = [animation]
        let deck = FlashcardDeck(title: FlashcardDeck.title(forSourceTitle: "Mitochondria"), cards: [drafted])
        #expect(deck.markdown.contains("Back image: ![Heart rate against body mass](foreverlm-site://77bbc5f1-0c5e-42b0-9b61-9659c875bd5b/)"))
        #expect(FlashcardDeck.parse(deck.markdown, fallbackTitle: "Cards") == deck)
    }

    // MARK: Keep, retire, start over

    @Test("Keep makes the item once on a verified passage, new until the day after; keeping again does nothing")
    func keepIsIdempotent() throws {
        let store = try makeStore()
        let card = drafted()
        let item = try store.keepMemoryCard(card, sourceID: "src-1", quote: Self.quote, ideaID: "idea-1", at: Self.keptAt)
        #expect(item.id == MemoryTutorIdentity.cardItemID(cardID: "card-A"))
        #expect(item.target == card.back)
        // No goal: it is part of the curriculum fingerprint, and two Macs
        // keeping the card from two notebooks must make the same item.
        #expect(item.goalID == nil)
        #expect(item.ideaID == "idea-1")
        #expect(item.sources.map(\.excerpt) == [Self.quote])
        #expect(item.sources.first?.sourceSHA256 == PaperContentPreparationService.sha256(try #require(try store.loadSourceContent("src-1"))))
        let stored = try #require(try store.loadMemoryItem(item.id))
        #expect(MemoryCard(storedIn: stored) == card)
        #expect(MemoryTutorIdentity.hasSameImmutableCurriculum(stored, item))

        let schedule = try #require(try store.loadMemorySchedule(memoryItemID: item.id))
        #expect(schedule.isNew)
        #expect(schedule.dueAt == MemoryTutorScheduler.firstEligibleAt(createdAt: Self.keptAt))

        // Keeping it again — a second click, the other Mac — changes nothing.
        let again = try store.keepMemoryCard(card, sourceID: "src-1", quote: Self.quote, at: Self.keptAt.addingTimeInterval(600))
        #expect(again.id == item.id)
        #expect(again.createdAt == Self.keptAt)
        #expect(try store.loadMemoryItems().count == 1)

        // A different back under a kept card's id is refused: that is a start over.
        #expect(throws: KnowledgeStoreError.self) {
            try store.keepMemoryCard(self.drafted(back: "Something else."), sourceID: "src-1", quote: Self.quote, at: Self.keptAt)
        }
        #expect(try store.loadMemoryItem(item.id)?.target == card.back)
    }

    @Test("Saving an item only when absent never overwrites one already stored, and writes nothing then")
    func saveIfAbsentNeverOverwrites() throws {
        let store = try makeStore()
        let kept = try store.keepMemoryCard(drafted(), sourceID: "src-1", quote: Self.quote, at: Self.keptAt)

        // What a keep racing this one would have written under the same id.
        let rival = try drafted(back: "A rival back.").memoryItem(
            id: kept.id,
            anchors: [MemorySourceAnchorValidation(sourceID: "src-1", excerpt: Self.quote, sourceSHA256: "h")],
            goalID: "notebook-2",
            at: Self.keptAt.addingTimeInterval(60)
        )
        let existing = try store.saveMemoryItemIfAbsent(rival)
        #expect(existing == kept)
        #expect(try store.loadMemoryItem(kept.id) == kept)

        // A rival's keep through the store finds the item and refuses its face.
        #expect(throws: KnowledgeStoreError.self) {
            try store.keepMemoryCard(self.drafted(back: "A rival back."), sourceID: "src-1", quote: Self.quote, at: Self.keptAt)
        }
    }

    @Test("Keep refuses a quote its source does not print, and saves nothing")
    func keepRefusesUngrounded() throws {
        let store = try makeStore()
        #expect(throws: KnowledgeStoreError.self) {
            try store.keepMemoryCard(self.drafted(), sourceID: "src-1", quote: "words the paper never printed", at: Self.keptAt)
        }
        #expect(try store.loadMemoryItems().isEmpty)
    }

    @Test("Retire keeps the item and its attempts and takes it out of today's cards; retiring again does nothing")
    func retire() throws {
        let store = try makeStore()
        let item = try store.keepMemoryCard(drafted(), sourceID: "src-1", quote: Self.quote, at: Self.keptAt)
        let nextDay = Self.keptAt.addingTimeInterval(1.5 * Self.day)
        #expect(try store.memoryCardQueueToday(now: nextDay, budgetMinutes: nil, newPerDay: 10, deadlines: []).entries.map(\.id) == [item.id])
        #expect(try store.recordSelfGradedMemoryCardAttempt(
            memoryItemID: item.id, prompt: drafted().front, remembered: false, sessionKey: "review-1", at: nextDay
        ) == .recorded)

        try store.retireMemoryCard(memoryItemID: item.id, at: nextDay)
        #expect(try store.loadMemoryItem(item.id)?.status == .retired)
        #expect(try store.loadMemoryAttempts(memoryItemID: item.id).count == 1)
        #expect(try store.memoryCardQueueToday(now: nextDay.addingTimeInterval(5 * Self.day), budgetMinutes: nil, newPerDay: 10, deadlines: []).entries.isEmpty)
        try store.retireMemoryCard(memoryItemID: item.id, at: nextDay.addingTimeInterval(60))
        #expect(try store.loadMemoryItem(item.id)?.updatedAt == nextDay)
        // A retired card takes no answer, however due it is.
        #expect(try store.recordSelfGradedMemoryCardAttempt(
            memoryItemID: item.id, prompt: drafted().front, remembered: true, sessionKey: "review-2",
            at: nextDay.addingTimeInterval(5 * Self.day)
        ) == .retired)
        #expect(try store.loadMemoryAttempts(memoryItemID: item.id).count == 1)

        #expect(throws: KnowledgeStoreError.self) { try store.retireMemoryCard(memoryItemID: "no-such-item") }
    }

    @Test("Start over retires the old item and keeps the revision under a new card id on the same passage, new again")
    func startOver() throws {
        let store = try makeStore()
        let old = try store.keepMemoryCard(drafted(), sourceID: "src-1", quote: Self.quote, ideaID: "idea-1", at: Self.keptAt)
        let later = Self.keptAt.addingTimeInterval(3 * Self.day)
        #expect(try store.recordSelfGradedMemoryCardAttempt(
            memoryItemID: old.id, prompt: drafted().front, remembered: true, sessionKey: "review-1",
            at: Self.keptAt.addingTimeInterval(Self.day)
        ) == .recorded)

        let revision = drafted("card-B", back: "The proton-motive force across the inner membrane.", why: [])
        let new = try store.startMemoryCardOver(memoryItemID: old.id, as: revision, at: later)
        #expect(new.id == MemoryTutorIdentity.cardItemID(cardID: "card-B"))
        #expect(new.status == .active)
        #expect(new.target == "The proton-motive force across the inner membrane.")
        #expect(new.goalID == nil)
        #expect(new.ideaID == "idea-1")
        #expect(new.sources.map(\.excerpt) == old.sources.map(\.excerpt))
        #expect(MemoryCard(storedIn: new) == revision)
        #expect(try store.loadMemoryItem(old.id)?.status == .retired)
        #expect(try store.loadMemoryItem(old.id)?.target == old.target, "the old item is retired, never rewritten")
        #expect(try store.loadMemoryAttempts(memoryItemID: old.id).count == 1)
        #expect(try store.loadMemorySchedule(memoryItemID: new.id)?.isNew == true)

        // The revision needs a card id of its own.
        #expect(throws: KnowledgeStoreError.self) {
            try store.startMemoryCardOver(memoryItemID: new.id, as: revision, at: later)
        }
        #expect(throws: KnowledgeStoreError.self) {
            try store.startMemoryCardOver(memoryItemID: new.id, as: self.drafted("card-A"), at: later)
        }
        #expect(try store.loadMemoryItem(new.id)?.status == .active, "a refused start over changes nothing")
        #expect(try store.loadMemoryItems(status: .active).map(\.id) == [new.id])

        // An item may carry a goal; its revision keeps it, under a card id no
        // other device has.
        let withGoal = MemoryItem(
            id: "item-with-goal", kind: .concept, target: "Q — A", rubricJSON: #"{"criteria":["A"]}"#,
            goalID: "notebook-1",
            sources: [MemoryItemSource(id: "anchor-goal", memoryItemID: "item-with-goal", sourceID: "src-1", excerpt: Self.quote, sourceSHA256: "h", sortIndex: 0)],
            createdAt: Self.keptAt, updatedAt: Self.keptAt
        )
        try store.saveMemoryItem(withGoal)
        let revisedWithGoal = try store.startMemoryCardOver(memoryItemID: withGoal.id, as: drafted("card-C"), at: later)
        #expect(revisedWithGoal.goalID == "notebook-1")
        #expect(try store.loadMemoryItem(withGoal.id)?.status == .retired)
    }

    // MARK: Pre-kept cards

    @Test("A question missed on a source is a kept card at once: its item carries the card, the answer as its target")
    func sourceQuestionIsPreKept() throws {
        let store = try makeStore()
        let question = SourceMemoryQuestion(
            sourceID: "src-1",
            stepID: "course-quiz-quiz-1-q-1",
            question: "What do uncoupling proteins do?",
            answer: "They let protons leak back without making ATP.",
            keyPoints: ["protons leak back", "no ATP"],
            excerpts: ["words the source never printed", "Uncoupling proteins let protons leak back"],
            origin: .courseQuiz
        )
        try store.recordSourceQuestionAttempt(question, answer: "No idea.", feedback: "Incorrect.", score: 0, rating: .again, at: Self.keptAt)

        let item = try #require(try store.loadMemoryItems().first)
        #expect(item.id == MemoryTutorIdentity.walkthroughQuestionItemID(
            portableSourceKey: try store.portableMemorySourceKey(sourceID: "src-1"),
            stepID: question.stepID,
            question: question.question
        ))
        #expect(item.target == "They let protons leak back without making ATP.")
        #expect(item.sources.map(\.excerpt) == ["Uncoupling proteins let protons leak back"])
        let card = try #require(MemoryCard(storedIn: item))
        #expect(card == MemoryCard(
            cardID: item.id,
            front: "What do uncoupling proteins do?",
            back: "They let protons leak back without making ATP.",
            why: ["protons leak back", "no ATP"],
            origin: .courseQuiz
        ))
        #expect(card.stateDeckID(in: item) == "carddeck-src-1")
        let first = try #require(try store.loadMemoryAttempts(memoryItemID: item.id).first)
        #expect(first.prompt == question.question)
        #expect(first.attemptType == .discovery)
        // Missed in the morning: due no sooner than tomorrow, never the same day.
        let schedule = try #require(try store.loadMemorySchedule(memoryItemID: item.id))
        #expect(schedule.dueAt >= MemoryTutorScheduler.firstEligibleAt(createdAt: Self.keptAt))

        // A question stored without an answer keeps its key points as the back.
        let unanswered = SourceMemoryQuestion(
            sourceID: "src-1", stepID: "step-9", question: "What leaks?", answer: " ",
            keyPoints: ["protons", "back across the membrane"], excerpts: [Self.quote], origin: .walkthrough
        )
        let face = unanswered.card(itemID: "item-9")
        #expect(face.back == "protons\nback across the membrane")
        #expect(face.why.isEmpty)
    }

    @Test("A missed question's item and its first attempt land together, or neither does")
    func sourceQuestionItemAndAttemptAreOneWrite() throws {
        let store = try makeStore()
        let question = SourceMemoryQuestion(
            sourceID: "src-1", stepID: "step-3", question: "What leaks?", answer: "Protons.",
            keyPoints: [], excerpts: [Self.quote], origin: .walkthrough
        )
        // An attempt storage refuses (a graded answer that is blank) leaves no
        // item behind waiting for an answer that never came.
        #expect(throws: KnowledgeStoreError.self) {
            try store.recordSourceQuestionAttempt(question, answer: "   ", feedback: "Missed.", score: 0, rating: .again, at: Self.keptAt)
        }
        #expect(try store.loadMemoryItems().isEmpty)
        #expect(try store.loadMemoryAttempts().isEmpty)

        try store.recordSourceQuestionAttempt(question, answer: "No idea.", feedback: "Missed.", score: 0, rating: .again, at: Self.keptAt)
        let item = try #require(try store.loadMemoryItems().first)
        #expect(try store.loadMemoryAttempts(memoryItemID: item.id).map(\.attemptType) == [.discovery])
    }

    // MARK: Self-graded answers

    @Test("A self-graded answer is a graded attempt with no chat, in the wording asked, and moves the schedule once")
    func selfGraded() throws {
        let store = try makeStore()
        let item = try store.keepMemoryCard(drafted(), sourceID: "src-1", quote: Self.quote, at: Self.keptAt)
        let answeredAt = Self.keptAt.addingTimeInterval(Self.day + 3_600)
        #expect(try store.recordSelfGradedMemoryCardAttempt(
            memoryItemID: item.id, prompt: "In my words: what links respiration and ATP?", remembered: true,
            sessionKey: "review-1", at: answeredAt
        ) == .recorded)
        #expect(try store.recordSelfGradedMemoryCardAttempt(
            memoryItemID: item.id, prompt: "In my words: what links respiration and ATP?", remembered: true,
            sessionKey: "review-1", at: answeredAt
        ) == .alreadyRecorded, "the same answer sent twice counts once")

        let attempt = try #require(try store.loadMemoryAttempts(memoryItemID: item.id).first)
        #expect(attempt.id == MemoryTutorIdentity.selfGradedAttemptID(sessionKey: "review-1", memoryItemID: item.id))
        #expect(attempt.gradeState == .graded)
        #expect(attempt.learnerAnswer == "(self-graded)")
        #expect(attempt.score == 1)
        #expect(attempt.scheduleRating == .good)
        #expect(attempt.attemptType == .review)
        #expect(attempt.prompt == "In my words: what links respiration and ATP?")
        #expect(attempt.sessionID == nil && attempt.exchangeID == nil)
        let schedule = try #require(try store.loadMemorySchedule(memoryItemID: item.id))
        #expect(!schedule.isNew)
        #expect(schedule.repetitionCount == 1)

        let forgot = MemoryAttempt.selfGraded(id: "answer-2", memoryItemID: item.id, prompt: "Q", remembered: false, at: answeredAt)
        #expect(forgot.score == 0)
        #expect(forgot.scheduleRating == .again)

        #expect(throws: KnowledgeStoreError.self) {
            try store.recordSelfGradedMemoryCardAttempt(memoryItemID: "no-such-item", prompt: "Q", remembered: true, sessionKey: "review-1", at: answeredAt)
        }
        #expect(throws: KnowledgeStoreError.self) {
            try store.recordSelfGradedMemoryCardAttempt(memoryItemID: item.id, prompt: "Q", remembered: true, sessionKey: "  ", at: answeredAt)
        }
    }

    @Test("Storage writes a self-graded answer only for a card due or new and eligible, once a sitting; practice counts a new card at once")
    func selfGradedAnswersCountOnlyWhenDue() throws {
        let store = try makeStore()
        // Kept at nine in the morning of the test machine's own day, which is
        // the day the store counts in.
        let morning = try #require(Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Self.keptAt))
        let item = try store.keepMemoryCard(drafted(), sourceID: "src-1", quote: Self.quote, at: morning)
        let front = drafted().front
        func answer(_ remembered: Bool, _ session: String, practice: Bool = false, at date: Date) throws -> MemoryCardAnswerOutcome {
            try store.recordSelfGradedMemoryCardAttempt(
                memoryItemID: item.id, prompt: front, remembered: remembered, sessionKey: session, practice: practice, at: date
            )
        }

        // Kept a minute ago: not eligible until tomorrow, so a review's answer
        // is not written; learner-started practice is, as its first answer.
        let soon = morning.addingTimeInterval(60)
        #expect(try answer(true, "review-0", at: soon) == .notCounted)
        #expect(try store.loadMemoryAttempts(memoryItemID: item.id).isEmpty)
        #expect(try answer(false, "practice-0", practice: true, at: soon) == .recorded)
        let afterPractice = try #require(try store.loadMemorySchedule(memoryItemID: item.id))
        #expect(afterPractice.repetitionCount == 1)
        // A Forgot at 09:01 would be due at 21:01: not on the day it was kept.
        #expect(afterPractice.dueAt == MemoryTutorScheduler.firstEligibleAt(createdAt: morning))

        // Seen before and not yet due: practice is not written either.
        #expect(try answer(true, "practice-1", practice: true, at: soon.addingTimeInterval(60)) == .notCounted)

        // Due the next day. Forgot, then "Review forgotten" asks it again in
        // the same sitting: that second Forgot is not written, so the
        // stability is halved once.
        let nextDay = afterPractice.dueAt.addingTimeInterval(9 * 3_600)
        #expect(try answer(false, "review-1", at: nextDay) == .recorded)
        let afterForgot = try #require(try store.loadMemorySchedule(memoryItemID: item.id))
        #expect(try answer(false, "review-1", at: nextDay.addingTimeInterval(120)) == .alreadyRecorded)
        #expect(try answer(true, "review-1", at: nextDay.addingTimeInterval(240)) == .alreadyRecorded)
        #expect(try store.loadMemorySchedule(memoryItemID: item.id) == afterForgot)
        #expect(try store.loadMemoryAttempts(memoryItemID: item.id).count == 2)

        // Another sitting once it is due again counts.
        #expect(try answer(true, "review-2", at: afterForgot.dueAt.addingTimeInterval(60)) == .recorded)
        #expect(try store.loadMemoryAttempts(memoryItemID: item.id).count == 3)
    }

    // MARK: The state row

    private func state(
        _ status: MemoryCardStatus,
        at seconds: TimeInterval,
        item: String? = nil,
        front: String? = nil,
        seed: String? = nil
    ) -> MemoryCardState {
        MemoryCardState(
            status: status, memoryItemID: item, editedFront: front,
            variants: status == .kept ? ["Another way to ask it?"] : [],
            retiredVariants: status == .kept ? ["A retired way?"] : [],
            alwaysAsk: front != nil, seed: seed,
            updatedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    @Test("A kept card's edited answer, why and pictures lay over its face, survive the row and the record, and leave the item alone")
    func editedFaceInPlace() throws {
        let kept = drafted()
        let picture = try #require(MemoryCardImage(target: "foreverlm://image/src_a/slide/13", alt: "Figure 2"))
        let edit = MemoryCardFaceEdit(back: "A proton gradient.", why: ["Leak ends ATP."], frontImages: [], backImages: [picture])
        let row = MemoryCardState(status: .kept, memoryItemID: "memory-card-v1-a", editedFace: edit, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))

        // Laid over the face; the front and identity stay, and no edit reads as kept.
        let shown = kept.applying(row)
        #expect(shown.back == "A proton gradient." && shown.why == ["Leak ends ATP."] && shown.backImages == [picture])
        #expect(shown.cardID == kept.cardID && shown.front == kept.front)
        #expect(kept.applying(nil) == kept)
        #expect(kept.applying(MemoryCardState(status: .kept, updatedAt: Date())) == kept)
        #expect(shown.criteria == ["Leak ends ATP."])

        // The preference row keeps it, and an edit changes the tie-break so two devices agree.
        let back = try #require(MemoryCardDeckState(preferenceValue: MemoryCardDeckState(cards: ["card-A": row]).preferenceValue))
        #expect(back.cards["card-A"]?.editedFace == edit)
        var other = row
        other.editedFace = MemoryCardFaceEdit(back: "Another.", why: [], frontImages: [], backImages: [])
        #expect(MemoryCardState.merged(row, other) == MemoryCardState.merged(other, row))

        // The card's record carries it as an element no older reader asks.
        let element = edit.variantElement(at: 1_800_000_000_000)
        #expect(element["text"]?.stringValue == "" && element["retired"]?.boolValue == true)
        #expect(MemoryCardFaceEdit(variantElement: element) == edit)
        let held = KnowledgeStore.mergedVariants([:], from: nil, to: row, at: 1_800_000_000_000)
        #expect(MemoryCardFaceEdit(variantElement: held[MemoryCardFaceEdit.variantKey]) == edit)
        #expect(KnowledgeStore.variantState(held).rewordings.isEmpty)
        var cleared = row
        cleared.editedFace = nil
        #expect(KnowledgeStore.mergedVariants(held, from: row, to: cleared, at: 1)[MemoryCardFaceEdit.variantKey] == nil)
    }

    @Test("A deck's state row survives the property-list trip and reads back whole")
    func stateRowRoundTrip() throws {
        let row = MemoryCardDeckState(cards: [
            "card-A": state(.kept, at: 1_800_000_000.25, item: "memory-card-v1-a", front: "My words?", seed: "walk-step:step-2"),
            "card-B": state(.skipped, at: 1_800_000_100, seed: "highlight:h-1"),
            "card-C": state(.draft, at: 1_800_000_200),
        ])
        let data = try PropertyListSerialization.data(fromPropertyList: row.preferenceValue, format: .binary, options: 0)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        #expect(MemoryCardDeckState(preferenceValue: plist) == row)

        // An entry this build cannot read is left out; something that is not a row is none.
        var value = row.preferenceValue
        var cards = try #require(value["cards"] as? [String: Any])
        cards["card-D"] = ["status": "expired", "t": 1_800_000_300.0]
        value["cards"] = cards
        #expect(MemoryCardDeckState(preferenceValue: value) == row)
        #expect(MemoryCardDeckState(preferenceValue: "not a row") == nil)
    }

    @Test("Two devices' rows merge card by card, the same whichever merges, and a kept card stays kept")
    func stateRowMerge() {
        let mine = MemoryCardDeckState(cards: [
            "newer-there": state(.draft, at: 100),
            "only-here": state(.draft, at: 100),
            "kept-here": state(.kept, at: 100, item: "item-k"),
            "tie": state(.draft, at: 300, front: "Mine?"),
        ])
        let theirs = MemoryCardDeckState(cards: [
            "newer-there": state(.skipped, at: 200),
            "kept-here": state(.skipped, at: 900),
            "tie": state(.draft, at: 300, front: "Theirs?"),
        ])
        let merged = mine.merged(with: theirs)
        #expect(merged == theirs.merged(with: mine))
        #expect(merged.cards["newer-there"]?.status == .skipped)
        #expect(merged.cards["only-here"] != nil)
        #expect(merged.cards["kept-here"]?.status == .kept, "its item exists whatever the other device said")
        #expect(merged.cards["kept-here"]?.memoryItemID == "item-k")
        #expect(merged.cards["tie"] != nil)
    }

    @Test("Read, merge, write: a change lands on the stored row merged with the caller's copy, and nothing else is written")
    func readMergeWrite() throws {
        let deckID = MemoryCard.draftDeckID(sourceID: "src-1")
        let key = MemoryCardDeckState.preferenceKey(deckID: deckID)
        var defaults: [String: Any] = [
            key: MemoryCardDeckState(cards: ["from-the-phone": state(.skipped, at: 500, seed: "idea:abc")]).preferenceValue,
        ]
        var writes: [String] = []
        let local = MemoryCardDeckState(cards: ["started-here": state(.draft, at: 400)])
        let now = Date(timeIntervalSince1970: 600)
        let written = MemoryCardDeckState.updating(
            deckID: deckID,
            local: local,
            read: { defaults[$0] },
            write: { value, key in
                defaults[key] = value
                writes.append(key)
            }
        ) { row in
            row.markKept(cardID: "started-here", memoryItemID: "memory-card-v1-x", at: now)
        }
        #expect(writes == [key])
        #expect(Set(written.cards.keys) == ["from-the-phone", "started-here"])
        #expect(written.cards["started-here"]?.status == .kept)
        #expect(written.cards["started-here"]?.memoryItemID == "memory-card-v1-x")
        #expect(written.cards["started-here"]?.updatedAt == now)
        #expect(MemoryCardDeckState(preferenceValue: try #require(defaults[key])) == written)

        // Starting a card over keeps the new revision with the old one's seed.
        var row = written
        row.cards["started-here"]?.seed = "walk-step:step-4"
        row.cards["started-here"]?.alwaysAsk = true
        row.recordStartOver(from: "started-here", to: "revision", newMemoryItemID: "memory-card-v1-y", at: now)
        #expect(row.cards["revision"]?.status == .kept)
        #expect(row.cards["revision"]?.seed == "walk-step:step-4")
        #expect(row.cards["revision"]?.alwaysAsk == true)
        #expect(row.cards["revision"]?.variants.isEmpty == true)
        #expect(row.cards["started-here"]?.memoryItemID == "memory-card-v1-x")
    }

    @Test("The Mac's update reads and writes the defaults it is given")
    @MainActor
    func stateStoreHonoursItsDefaults() throws {
        let suite = "foreverlm-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let deckID = MemoryCard.draftDeckID(sourceID: "src-1")
        let key = MemoryCardDeckState.preferenceKey(deckID: deckID)
        defaults.set(MemoryCardDeckState(cards: ["from-the-phone": state(.skipped, at: 500)]).preferenceValue, forKey: key)

        let written = MemoryCardStateStore.update(deckID: deckID, defaults: defaults) { row in
            row.markKept(cardID: "kept-here", memoryItemID: "memory-card-v1-k", at: Date(timeIntervalSince1970: 600))
        }
        #expect(Set(written.cards.keys) == ["from-the-phone", "kept-here"])
        #expect(MemoryCardStateStore.load(deckID: deckID, defaults: defaults) == written)
        #expect(UserDefaults.standard.object(forKey: key) == nil, "nothing reached the standard defaults")
    }

    @Test("The state rows sync as one prefix, and a card is asked in the learner's rewording when there is one")
    func syncedPrefixAndWording() {
        #expect(SyncedPreferenceKeys.isSynced(MemoryCardDeckState.preferenceKey(deckID: "carddeck-src-1")))
        #expect(MemoryCardDeckState.deckID(fromPreferenceKey: "cards.state.carddeck-src-1") == "carddeck-src-1")
        #expect(MemoryCardDeckState.deckID(fromPreferenceKey: "cards.state.") == nil)
        #expect(MemoryCardDeckState.deckID(fromPreferenceKey: "flashcards.progress.x") == nil)

        let card = drafted()
        #expect(card.wording(state: nil) == card.front)
        #expect(card.wording(state: state(.kept, at: 1, front: "  My own words?  ")) == "My own words?")
        #expect(card.wording(state: state(.kept, at: 1, front: "   ")) == card.front)
    }

    // MARK: Cards to check: the deck

    /// A card drafted from src-1, as an assistant's `save_card_drafts` mints it.
    private func draft(
        _ front: String = "What couples respiration to ATP synthesis?",
        back: String = "A proton gradient across the inner membrane.",
        seed: String? = "walk-step:step-2",
        requested: Bool = false,
        at date: Date = Self.keptAt,
        id: String
    ) -> Flashcard {
        Flashcard.mint(
            front: front,
            back: back,
            why: "Uncoupling breaks the link and ATP synthesis stops.",
            sourceID: "src-1",
            sourceTitle: "Mitochondria",
            quote: Self.quote,
            seed: seed,
            origin: .assistant,
            isRequested: requested,
            at: date,
            id: id
        )
    }

    @Test("A deck writes each card's minted id, its seed and how it was drafted, and reads them all back")
    func deckFormatRoundTrip() throws {
        let figure1 = try #require(MemoryCardImage(reference: "![Figure 1](foreverlm://image/src-1/page/3)"))
        let figure2 = try #require(MemoryCardImage(reference: "![Figure 2](foreverlm://image/src-1/page/4)"))
        var pictured = draft(requested: true, id: "card-a")
        pictured.frontImages = [figure1]
        pictured.backImages = [figure1, figure2]
        let deck = FlashcardDeck(
            title: FlashcardDeck.title(forSourceTitle: "Mitochondria"),
            cards: [
                pictured,
                draft("Why does uncoupling stop ATP synthesis?", back: "Protons leak back.\nThe synthase is bypassed.", seed: nil, id: "card-b"),
            ]
        )
        let body = deck.markdown
        #expect(FlashcardDeck.isDeckMarkdown(body))
        #expect(body.contains("## What couples respiration to ATP synthesis?\n<!-- card:card-a -->\nA proton gradient"))
        #expect(body.contains("Seed: walk-step:step-2"))
        #expect(body.contains("Origin: assistant"))
        #expect(body.contains("Requested: yes"))
        #expect(body.contains("Front image: ![Figure 1](foreverlm://image/src-1/page/3)"))
        #expect(body.contains("Back image: ![Figure 2](foreverlm://image/src-1/page/4)"))
        #expect(body.contains("Drafted: \(Self.keptAt.formatted(FlashcardDeck.dateStyle))"))
        #expect(body.contains("Source: [Mitochondria](foreverlm://source/src-1 \"\(Self.quote)\")"))

        let read = FlashcardDeck.parse(body, fallbackTitle: "Cards")
        #expect(read == deck)
        #expect(read.title == "Cards to check: Mitochondria")
        let first = try #require(read.cards.first)
        #expect(first.isRequested)
        #expect(first.origin == .assistant)
        #expect(first.draftedAt == Self.keptAt)
        #expect(read.cards[1].back == "Protons leak back.\nThe synthase is bypassed.")
        #expect(!read.cards[1].isRequested)

        // A body written by hand, with no card lines, takes ids from its fronts.
        let handMade = FlashcardDeck.parse(
            "\(FlashcardDeck.formatMarker)\n# Cards\n\n## Q?\nA.\n\n## Q?\nB.\n",
            fallbackTitle: "Cards"
        )
        #expect(handMade.cards.map(\.id) == [
            Flashcard.stableID(front: "Q?", occurrence: 0),
            Flashcard.stableID(front: "Q?", occurrence: 1),
        ])
        #expect(!FlashcardDeck.isDeckMarkdown("# A Doc\n\nText."))
    }

    @Test("Appending adds only cards whose id, seed and front are new, and changes nothing already in the deck")
    func deckAppendsOnly() {
        let first = draft(id: "card-a")
        let deck = FlashcardDeck(title: "Cards to check: Mitochondria", cards: [first])
        let before = deck.markdown
        let appended = deck.appending([
            first,
            draft("Another wording of it?", seed: "walk-step:step-2", id: "card-b"),
            draft("what couples   RESPIRATION to ATP synthesis?", seed: "highlight:h-1", id: "card-c"),
            draft("Which protein lets protons leak back?", back: "Uncoupling protein 1.", seed: "highlight:h-2", id: "card-d"),
            draft("A card that splits?", back: "First line.\n## A heading in the back", seed: "highlight:h-3", id: "card-e"),
            draft("A card read as metadata?", back: "Seed: this line reads as the card's own.", seed: "highlight:h-4", id: "card-f"),
        ])
        #expect(appended.added.map(\.id) == ["card-d"])
        #expect(Set(appended.alreadyDrafted.map(\.id)) == ["card-a", "card-b", "card-c"])
        #expect(Set(appended.unreadable.map(\.id)) == ["card-e", "card-f"])
        #expect(appended.deck.cards.map(\.id) == ["card-a", "card-d"])
        #expect(appended.deck.markdown.hasPrefix(before), "the deck grows at its end, and only there")
    }

    @Test("A draft the learner never went through still holds its seed and front, however old it is")
    func anOldDraftStillHoldsItsSeedAndFront() {
        let old = draft(seed: "walk-step:step-2", at: Self.keptAt.addingTimeInterval(-400 * Self.day), id: "card-a")
        let deck = FlashcardDeck(title: "Cards to check: Mitochondria", cards: [old])

        let again = deck.appending([
            draft(seed: "walk-step:step-2", id: "card-a2"),
            draft("What couples respiration to ATP synthesis?", seed: "highlight:h-9", id: "card-a3"),
            draft("Where is the gradient held?", seed: "highlight:h-4", id: "card-d"),
        ])
        #expect(again.added.map(\.id) == ["card-d"])
        #expect(Set(again.alreadyDrafted.map(\.id)) == ["card-a2", "card-a3"])
        #expect(again.deck.cards.map(\.id) == ["card-a", "card-d"], "the deck only grows")
    }

    @Test("Two Macs that drafted for one source keep both sets of cards, card by card")
    func deckUnion() throws {
        let a = draft(id: "card-a")
        let b = draft("Which protein lets protons leak back?", seed: "s-b", id: "card-b")
        let c = draft("What does the synthase use?", seed: "s-c", id: "card-c")
        let mine = FlashcardDeck(title: "T", cards: [a, b]).markdown
        let theirs = FlashcardDeck(title: "T", cards: [a, c]).markdown
        let union = try #require(FlashcardDeck.union(mine: mine, theirs: theirs))
        #expect(FlashcardDeck.parse(union, fallbackTitle: "T").cards.map(\.id) == ["card-a", "card-b", "card-c"])
        #expect(union.hasPrefix(mine))
        // Nothing new over there: this copy as it is.
        #expect(FlashcardDeck.union(mine: mine, theirs: FlashcardDeck(title: "T", cards: [b]).markdown) == mine)
        // Not two decks: the ordinary Doc merge decides.
        #expect(FlashcardDeck.union(mine: mine, theirs: "# A Doc\n\nText.") == nil)
    }

    // MARK: Cards to check: which wait

    @Test("A draft waits until it is kept or skipped, however old it is")
    func toCheckPile() throws {
        let now = Self.keptAt.addingTimeInterval(3 * Self.day)
        let deckID = MemoryCard.draftDeckID(sourceID: "src-1")
        let deck = MemoryCardDraftDeck(deckID: deckID, sourceID: "src-1", deck: FlashcardDeck(title: "T", cards: [
            draft(id: "card-fresh"),
            draft("Kept?", seed: "s-k", id: "card-kept"),
            draft("Skipped?", seed: "s-s", id: "card-skipped"),
            draft("Kept on the other Mac?", seed: "s-e", id: "card-elsewhere"),
            draft("Drafted a year ago?", seed: "s-o", at: now.addingTimeInterval(-365 * Self.day), id: "card-old"),
        ]))
        var row = MemoryCardDeckState()
        row.markKept(cardID: "card-kept", memoryItemID: "item-k", at: now)
        row.markSkipped(cardID: "card-skipped", seed: "s-s", at: now)
        func pile(_ states: [String: MemoryCardDeckState]) -> [MemoryCardToCheck] {
            MemoryCardTriage.toCheck(
                decks: [deck],
                deckStates: states,
                itemIDs: [MemoryTutorIdentity.cardItemID(cardID: "card-elsewhere")]
            )
        }

        let waiting = pile([deckID: row])
        #expect(waiting.map(\.cardID) == ["card-fresh", "card-old"])
        #expect(MemoryCardTriage.summary(waiting) == "2 cards from 1 source")
        let fresh = try #require(waiting.first)
        #expect(fresh.kind == .draft)
        #expect(fresh.face.deckID == deckID)
        #expect(fresh.face.origin == .assistant)
        #expect(fresh.quote == Self.quote)
        #expect(!fresh.isKeptByDefault)
        #expect(MemoryCardTriage.summary([]) == nil)
    }

    @Test("Of two drafts of one seed or front, from two Macs that drafted before they synced, To Check offers the first, and neither once one is gone through")
    func toCheckOffersOneDraftOfASeed() throws {
        let deckID = MemoryCard.draftDeckID(sourceID: "src-1")
        let mine = FlashcardDeck(title: "T", cards: [
            draft(id: "mine-1"),
            draft("Which protein lets protons leak back?", seed: "s-b", id: "mine-2"),
        ]).markdown
        let theirs = FlashcardDeck(title: "T", cards: [
            draft("Another wording of the coupling?", seed: "walk-step:step-2", id: "theirs-1"),
            draft("which protein lets protons   leak back?", seed: "s-other", id: "theirs-2"),
            draft("What does the synthase use?", seed: "s-c", id: "theirs-3"),
        ]).markdown
        let merged = FlashcardDeck.parse(try #require(FlashcardDeck.union(mine: mine, theirs: theirs)), fallbackTitle: "T")
        #expect(merged.cards.map(\.id) == ["mine-1", "mine-2", "theirs-1", "theirs-2", "theirs-3"], "the deck keeps every card")
        let deck = MemoryCardDraftDeck(deckID: deckID, sourceID: "src-1", deck: merged)
        func pile(_ row: MemoryCardDeckState, itemIDs: Set<String> = []) -> [String] {
            MemoryCardTriage.toCheck(
                decks: [deck],
                deckStates: [deckID: row],
                itemIDs: itemIDs
            ).map(\.cardID)
        }

        #expect(pile(MemoryCardDeckState()) == ["mine-1", "mine-2", "theirs-3"])
        // The other Mac skipped its twin of mine-1's seed and kept its twin of
        // mine-2's front: neither of mine is offered again.
        var row = MemoryCardDeckState()
        row.markSkipped(cardID: "theirs-1", seed: "walk-step:step-2", at: Self.keptAt)
        #expect(pile(row, itemIDs: [MemoryTutorIdentity.cardItemID(cardID: "theirs-2")]) == ["theirs-3"])
    }

    @Test("Keep All keeps every card of a source, asked for or not")
    func keepAll() {
        let deckID = MemoryCard.draftDeckID(sourceID: "src-1")
        let deck = MemoryCardDraftDeck(deckID: deckID, sourceID: "src-1", deck: FlashcardDeck(title: "T", cards: [
            draft(requested: true, id: "asked-1"),
            draft("Asked and unticked?", seed: "s-2", requested: true, id: "asked-2"),
            draft("Drafted unasked?", seed: "s-3", id: "unasked"),
        ]))
        let cards = MemoryCardTriage.toCheck(decks: [deck], deckStates: [:], itemIDs: [])
        let all = MemoryCardTriage.keepAll(cards)
        #expect(all.map(\.card.cardID) == ["asked-1", "asked-2", "unasked"])
        #expect(all.map(\.action) == [.keep, .keep, .keep])
        #expect(MemoryCardTriage.grouped(cards).map(\.sourceID) == ["src-1"])
    }

    @Test("The counts line names what waits — due, new and to check — leaving out a part that is zero")
    func countsLine() {
        #expect(MemoryCardDayCounts(due: 6, new: 4, practice: 0, toCheck: 9).line == "6 due · 4 new · 9 to check")
        #expect(MemoryCardDayCounts(due: 6, new: 0, practice: 0, toCheck: 9).line == "6 due · 9 to check")
        #expect(MemoryCardDayCounts(due: 0, new: 0, practice: 2, toCheck: 9).line == "9 to check")
        #expect(MemoryCardDayCounts(due: 6, new: 4, practice: 0, toCheck: 9).todayLine == "6 due · 4 new")
        #expect(MemoryCardDayCounts(due: 0, new: 0, practice: 0, toCheck: 9).todayLine == nil)
        #expect(MemoryCardDayCounts.zero.line == nil)
    }

    // MARK: Cards to check: going through them

    /// Storage on a folder of its own holding src-1, and a defaults suite of
    /// its own for the state rows, so nothing reaches the host's.
    private func makeStorage() async throws -> (StorageService, UserDefaults, () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MemoryCardTriage_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = StorageService(storeRoot: root)
        var source = StudioArticle(url: "https://example.com/mito", title: "Mitochondria", sourceType: .article, discoveryOrigin: .manual, id: "src-1")
        source.normalizedURL = URLNormalizer.normalize(source.url)
        source.content = Self.text
        source.wordCount = 20
        source.state = .ready
        try await storage.saveSource(source)
        let suite = "foreverlm-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (storage, defaults, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        })
    }

    private func cardsToCheck(_ storage: StorageService, _ defaults: UserDefaults, scope: MemoryCardScope? = nil, at now: Date) async throws -> [MemoryCardToCheck] {
        try await storage.memoryCardReviewSnapshot(
            now: now, budgetMinutes: nil, newPerDay: 10, deadlines: [], scope: scope,
            includesListings: false, includesToCheck: true, stateDefaults: defaults
        ).toCheck
    }

    @Test("Saving drafts grounds each quote on its source and makes the source's private deck once")
    func savingDraftsGroundsAndAppends() async throws {
        let (storage, defaults, cleanup) = try await makeStorage()
        defer { cleanup() }
        var ungrounded = draft("A card on words the paper never printed?", seed: "s-x", id: "card-x")
        ungrounded.quote = "words the paper never printed"
        let saved = try await storage.saveCardDrafts([draft(id: "card-a"), ungrounded], sourceID: "src-1", sourceTitle: "Mitochondria")
        #expect(saved.added.map(\.id) == ["card-a"])
        #expect(saved.ungrounded.map(\.id) == ["card-x"])
        let deck = try #require(try await storage.loadCardDrafts().first)
        #expect(deck.deckID == "carddeck-src-1")
        #expect(deck.deck.cards.map(\.id) == ["card-a"])

        // The same card again adds nothing and writes nothing.
        let store = try await storage.notebookFilesKnowledgeStore()
        let record = try #require(try store.loadArtifact("carddeck-src-1"))
        let again = try await storage.saveCardDrafts([draft(id: "card-a")], sourceID: "src-1", sourceTitle: "Mitochondria")
        #expect(again.added.isEmpty)
        #expect(again.alreadyDrafted.map(\.id) == ["card-a"])
        #expect(try store.loadArtifact("carddeck-src-1")?.updatedAt == record.updatedAt)

        // A source the library does not hold is refused.
        await #expect(throws: KnowledgeStoreError.self) {
            _ = try await storage.saveCardDrafts([self.draft(id: "card-z")], sourceID: "src-missing", sourceTitle: "Missing")
        }
        #expect(try await cardsToCheck(storage, defaults, at: Self.keptAt.addingTimeInterval(60)).map(\.cardID) == ["card-a"])
    }

    @Test("Keep makes the card's item once and marks its row; keeping it again changes nothing")
    func keepIsIdempotent() async throws {
        let (storage, defaults, cleanup) = try await makeStorage()
        defer { cleanup() }
        let now = Self.keptAt.addingTimeInterval(60)
        _ = try await storage.saveCardDrafts([draft(requested: true, id: "card-a")], sourceID: "src-1", sourceTitle: "Mitochondria")
        let card = try #require(try await cardsToCheck(storage, defaults, at: now).first)
        #expect(card.isRequested)

        let result = await MemoryCardTriageWriter.apply([MemoryCardTriageDecision(card: card, action: .keep)], storage: storage, defaults: defaults, at: now)
        let itemID = MemoryTutorIdentity.cardItemID(cardID: "card-a")
        #expect(result.kept == [MemoryCardTriageResult.Kept(cardID: "card-a", memoryItemID: itemID)])
        #expect(result.failed.isEmpty)
        let item = try #require(try await storage.loadMemoryItem(itemID))
        #expect(MemoryCard(storedIn: item) == card.face)
        #expect(item.sources.map(\.excerpt) == [Self.quote])
        #expect(item.goalID == nil)
        let state = try #require(MemoryCardStateStore.state(cardID: "card-a", deckID: card.deckID, defaults: defaults))
        #expect(state.status == .kept)
        #expect(state.memoryItemID == itemID)
        #expect(state.seed == "walk-step:step-2")
        #expect(try await cardsToCheck(storage, defaults, at: now).isEmpty)

        // Again — a second click, an assistant — finds the item and keeps it.
        let again = await MemoryCardTriageWriter.apply([MemoryCardTriageDecision(card: card, action: .keep)], storage: storage, defaults: defaults, at: now)
        #expect(again.kept.map(\.memoryItemID) == [itemID])
        #expect(try await storage.loadMemoryItems().count == 1)
    }

    @Test("Skip drops a draft for good: it leaves To Check and its seed is never drafted again")
    func skipIsForGood() async throws {
        let (storage, defaults, cleanup) = try await makeStorage()
        defer { cleanup() }
        let now = Self.keptAt.addingTimeInterval(60)
        _ = try await storage.saveCardDrafts([draft(id: "card-a")], sourceID: "src-1", sourceTitle: "Mitochondria")
        let card = try #require(try await cardsToCheck(storage, defaults, at: now).first)
        let result = await MemoryCardTriageWriter.apply([MemoryCardTriageDecision(card: card, action: .skip)], storage: storage, defaults: defaults, at: now)
        #expect(result.skipped == ["card-a"])
        #expect(MemoryCardStateStore.state(cardID: "card-a", deckID: card.deckID, defaults: defaults)?.status == .skipped)
        #expect(try await cardsToCheck(storage, defaults, at: now).isEmpty)
        #expect(try await storage.loadMemoryItems().isEmpty)
        // Drafted again from the same seed — or with the same front — it is
        // not offered twice.
        let redrafted = try await storage.saveCardDrafts(
            [draft("A new wording of the same seed?", id: "card-b"), draft(seed: "highlight:h-9", id: "card-c")],
            sourceID: "src-1", sourceTitle: "Mitochondria"
        )
        #expect(redrafted.added.isEmpty)
        #expect(Set(redrafted.alreadyDrafted.map(\.id)) == ["card-b", "card-c"])
    }

    @Test("Edit, then Keep keeps the learner's words; the deck keeps what was drafted")
    func editThenKeep() async throws {
        let (storage, defaults, cleanup) = try await makeStorage()
        defer { cleanup() }
        let now = Self.keptAt.addingTimeInterval(60)
        _ = try await storage.saveCardDrafts([draft(id: "card-a")], sourceID: "src-1", sourceTitle: "Mitochondria")
        let card = try #require(try await cardsToCheck(storage, defaults, at: now).first)
        let edit = MemoryCardEdit(front: "What links respiration to making ATP?", back: "The proton gradient.", why: ["Without it the synthase stops."])
        let result = await MemoryCardTriageWriter.apply([MemoryCardTriageDecision(card: card, action: .keepEdited(edit))], storage: storage, defaults: defaults, at: now)
        let item = try #require(try await storage.loadMemoryItem(MemoryTutorIdentity.cardItemID(cardID: "card-a")))
        #expect(result.kept.count == 1)
        let kept = try #require(MemoryCard(storedIn: item))
        #expect(kept.front == edit.front)
        #expect(kept.back == edit.back)
        #expect(kept.why == edit.why)
        #expect(kept.cardID == "card-a")
        #expect(kept.origin == .assistant)
        // The deck still holds the draft as it was made: what the learner
        // changed is the kept item's face.
        let deck = try #require(try await storage.loadCardDrafts().first)
        #expect(deck.deck.cards.first?.front == "What couples respiration to ATP synthesis?")

        // An edit with no answer keeps nothing.
        _ = try await storage.saveCardDrafts([draft("Another question?", seed: "s-2", id: "card-b")], sourceID: "src-1", sourceTitle: "Mitochondria")
        let other = try #require(try await cardsToCheck(storage, defaults, at: now).first)
        let refused = await MemoryCardTriageWriter.apply(
            [MemoryCardTriageDecision(card: other, action: .keepEdited(MemoryCardEdit(front: "Q?", back: "", why: [])))],
            storage: storage, defaults: defaults, at: now
        )
        #expect(refused.failed.map(\.cardID) == ["card-b"])
        #expect(try await cardsToCheck(storage, defaults, at: now).map(\.cardID) == ["card-b"])
    }

    @Test("A notebook's cards to check are those on its sources, and a deck whose source left the library is not offered")
    func toCheckFollowsTheNotebook() async throws {
        let (storage, defaults, cleanup) = try await makeStorage()
        defer { cleanup() }
        let now = Self.keptAt.addingTimeInterval(60)
        _ = try await storage.saveCardDrafts([draft(id: "card-a")], sourceID: "src-1", sourceTitle: "Mitochondria")
        let holding = MemoryCardScope(notebookID: "notebook-1", memberSourceIDs: ["src-1"])
        let elsewhere = MemoryCardScope(notebookID: "notebook-2", memberSourceIDs: ["src-other"])
        #expect(try await cardsToCheck(storage, defaults, scope: holding, at: now).map(\.cardID) == ["card-a"])
        #expect(try await cardsToCheck(storage, defaults, scope: elsewhere, at: now).isEmpty)
        // The counts carry them, beside today's cards.
        let snapshot = try await storage.memoryCardReviewSnapshot(
            now: now, budgetMinutes: nil, newPerDay: 10, deadlines: [], scope: holding,
            includesListings: false, includesToCheck: true, stateDefaults: defaults
        )
        #expect(snapshot.counts.toCheck == 1)
        #expect(snapshot.counts.line == "1 to check")
        // A sitting reads no deck.
        let sitting = try await storage.memoryCardReviewSnapshot(
            now: now, budgetMinutes: nil, newPerDay: 10, deadlines: [], scope: holding,
            includesListings: false, includesToCheck: false, stateDefaults: defaults
        )
        #expect(sitting.toCheck.isEmpty)

        // A deck's cards are offered only while the library holds its source.
        let store = try await storage.notebookFilesKnowledgeStore()
        #expect(try store.memoryCardDraftSourcesAvailable(["src-1", "src-missing"]) == ["src-1"])
    }

    @Test("A picture can be put on a card to check the pane has moved past")
    @MainActor
    func picturesReachACardWaitingBehindTheOneInFront() throws {
        let state = StudioWindowState()
        StudioWindowRegistry.shared.register(state)
        defer { StudioWindowRegistry.shared.unregister(state) }
        state.memoryPaneSection = .toCheck
        state.memoryCardsWaitingIDs = ["card-a", "card-b"]
        let figure = try #require(MemoryCardImage(reference: "![Figure 3](foreverlm://image/src-1/page/3)"))

        // Neither card is on screen, but the pane has both waiting.
        #expect(MCPDataStore.holdPicturesOnCardToCheck(cardID: "card-a", front: nil, back: [figure]))
        #expect(state.memoryCardPictures["card-a"]?.back?.count == 1)
        // A card the pane does not have is not held.
        #expect(!MCPDataStore.holdPicturesOnCardToCheck(cardID: "card-z", front: nil, back: [figure]))
        #expect(state.memoryCardPictures["card-z"] == nil)
        // Only the To Check pane holds them.
        state.memoryPaneSection = .review
        #expect(!MCPDataStore.holdPicturesOnCardToCheck(cardID: "card-b", front: nil, back: [figure]))
    }

    @Test("A shortened card id names the one card it fits; two fits are refused with full ids")
    func shortenedCardIDsComplete() throws {
        let source = "src_9781ed5d8ff730973e140c24247d0b7671760f5522f2f15c9b77aa0852e6f57b"
        let gist = "card:\(source):gist:\(source)"
        let other = "card:\(source):seed-two"
        let known = [gist, other, "card:src_aaaa:gist:src_aaaa"]
        #expect(CardIDCompletion.resolve(gist, among: known) == .exact)
        // The model's own shortening: whole head, tail written as dots.
        #expect(CardIDCompletion.resolve("card:\(source):gis...", among: known) == .completed(gist))
        #expect(CardIDCompletion.resolve("card:\(source):gis\u{2026}", among: known) == .completed(gist))
        #expect(CardIDCompletion.resolve("card:\(source):gist:src_9781...6f57b", among: known) == .completed(gist))
        // Cut short with no ellipsis.
        #expect(CardIDCompletion.resolve("card:\(source):gist", among: known) == .completed(gist))
        // Two cards fit: no guess.
        #expect(CardIDCompletion.resolve("card:\(source)...", among: known) == .ambiguous([gist, other]))
        // Nothing fits.
        #expect(CardIDCompletion.resolve("card:src_zzzz...", among: known) == .unknown)
        #expect(CardIDCompletion.resolve("...", among: known) == .unknown)
        #expect(try MCPDataStore.completedCardID("card:\(source):gis...", among: known) == gist)
        #expect(throws: MCPError.self) { try MCPDataStore.completedCardID("card:\(source)...", among: known) }
    }
}

/// The pictures a Mac renders for the iPhone and hangs on the card (`Card.pictures`, 2026-10-19).
@Suite("Memory cards: pictures for the iPhone")
struct CardPictureKeyTests {
    @Test("A slide, a video frame, a book's image and a drawing are published; a PDF page and an animation are not")
    func whatIsPublished() throws {
        func image(_ target: String) throws -> MemoryCardImage { try #require(MemoryCardImage(target: target)) }
        #expect(CardPictureKey.isPublished(try image("foreverlm://image/src_a/slide/3")))
        #expect(CardPictureKey.isPublished(try image("foreverlm://image/src_a/at/265")))
        #expect(CardPictureKey.isPublished(try image("foreverlm://image/chapter-3/img/2")))
        #expect(CardPictureKey.isPublished(try image("foreverlm://image/generated/0a1b2c3d-4e5f")))
        #expect(!CardPictureKey.isPublished(try image("foreverlm://image/src_a/page/9")))
        #expect(!CardPictureKey.isPublished(try image("foreverlm-site://35d74165-5461-4c72-92b5-c1925d3dcef4/")))
    }

    @Test("The key is the same for one address everywhere and differs between addresses")
    func keyIsStable() {
        let key = CardPictureKey.key("foreverlm://image/src_a/slide/3")
        #expect(key.count == 24)
        #expect(key == CardPictureKey.key("foreverlm://image/src_a/slide/3"))
        #expect(key != CardPictureKey.key("foreverlm://image/src_a/slide/4"))
        #expect(CardPictureKey.role(key) == "picture." + key)
    }

    @Test("A stored face's picture addresses are read out of its escaped rubric, once each")
    func targetsInStoredFace() {
        let json = #"{"back":"Drp1.","rubric":"{\"card\":{\"backImages\":[{\"alt\":\"Fission\",\"target\":\"foreverlm://image/src_a/slide/13\"},{\"alt\":\"Again\",\"target\":\"foreverlm://image/src_a/slide/13\"},{\"alt\":\"Leak\",\"target\":\"foreverlm://image/src_a/at/90?crop=0.1000,0.2000,0.5000,0.5000\"}]}}"}"#
        #expect(CardPictures.targets(inFaceJSON: json) == [
            "foreverlm://image/src_a/slide/13",
            "foreverlm://image/src_a/at/90?crop=0.1000,0.2000,0.5000,0.5000",
        ])
    }
}
