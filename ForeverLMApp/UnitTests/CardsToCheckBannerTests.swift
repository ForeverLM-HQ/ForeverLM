import Foundation
import Testing
@testable import ForeverLM

// The morning-after cards banner (docs/memory-design.md, "The morning-after
// banner"): what it is about, what it says, and when a source is told once.
// Pure rules over a ledger of the test's own, so nothing reaches the host's
// defaults or notification centre.

private let day: TimeInterval = 86_400

private func finished(_ id: String, now: Date, hasDeck: Bool = false, ideas: Int = 3) -> AutomaticCardDrafting.Candidate {
    AutomaticCardDrafting.Candidate(
        sourceID: id, deckSourceID: id, title: id, consumedAt: now.addingTimeInterval(-day), isFinished: true,
        engagement: CohortEngagement(engagedSeconds: 900, depth: 1), confidence: .complete,
        ideaCount: ideas, hasDeck: hasDeck, isNeededSoon: false, reach: .whole
    )
}

private func subject(
    cards: Int = 0,
    drafted: Set<String> = [],
    undrafted: Set<String> = [],
    added: Set<String> = []
) -> CardsToCheckBanner.Subject {
    CardsToCheckBanner.Subject(cardCount: cards, draftedSourceIDs: drafted, undraftedSourceIDs: undrafted, addedSourceIDs: added)
}

@Suite("Cards to check banner")
struct CardsToCheckBannerTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var morning: Date { now.addingTimeInterval(day) }

    @Test("Drafts waiting in To Check are the banner's subject, whatever the drafting switch says")
    func draftsWait() throws {
        let pile = CardsToCheckNudge.Pile(cardCount: 14, sourceIDs: ["a", "b", "c"])
        for autoDrafts in [true, false] {
            let made = try #require(CardsToCheckBanner.subject(pile: pile, candidates: [], autoDrafts: autoDrafts, now: now))
            #expect(made.cardCount == 14)
            #expect(made.draftedSourceIDs == ["a", "b", "c"])
            #expect(made.undraftedSourceIDs.isEmpty)
        }
    }

    @Test("With drafting off, finished sources with no deck are the subject; with it on they are drafted as finished, so they are not named")
    func undraftedSources() throws {
        let candidates = [finished("a", now: now), finished("b", now: now, hasDeck: true), finished("c", now: now, ideas: 0)]
        let off = try #require(CardsToCheckBanner.subject(pile: nil, candidates: candidates, autoDrafts: false, now: now))
        #expect(off.undraftedSourceIDs == ["a"], "a deck covers b, and c has no ideas to draft from")
        #expect(!off.hasDrafts)
        #expect(CardsToCheckBanner.subject(pile: nil, candidates: candidates, autoDrafts: true, now: now) == nil)
    }

    @Test("A source in the pile is not also counted as undrafted, and nothing waiting is no subject")
    func overlapAndNothing() throws {
        let pile = CardsToCheckNudge.Pile(cardCount: 2, sourceIDs: ["a"])
        let made = try #require(CardsToCheckBanner.subject(pile: pile, candidates: [finished("a", now: now)], autoDrafts: false, now: now))
        #expect(made.undraftedSourceIDs.isEmpty)
        #expect(CardsToCheckBanner.subject(pile: nil, candidates: [], autoDrafts: false, now: now) == nil)
    }

    @Test("What the banner says")
    func wording() {
        #expect(CardsToCheckBanner.body(subject(cards: 14, drafted: ["a", "b", "c"])) == "14 cards from 3 sources you finished wait to be checked.")
        #expect(CardsToCheckBanner.body(subject(cards: 1, drafted: ["a"])) == "1 card from a source you finished waits to be checked.")
        #expect(CardsToCheckBanner.body(subject(undrafted: ["a"])) == "A source you finished has no cards yet.")
        #expect(CardsToCheckBanner.body(subject(undrafted: ["a", "b"])) == "2 sources you finished have no cards yet.")
    }

    @Test("What was added with no card is a subject on its own, whether or not it was finished or drafting is on")
    func addedSources() throws {
        for autoDrafts in [true, false] {
            let made = try #require(CardsToCheckBanner.subject(pile: nil, candidates: [], autoDrafts: autoDrafts, addedSourceIDs: ["x", "y"], now: now))
            #expect(made.addedSourceIDs == ["x", "y"])
            #expect(!made.hasDrafts)
            #expect(made.makeCardsSourceIDs == ["x", "y"])
        }
        #expect(CardsToCheckBanner.subject(pile: nil, candidates: [], autoDrafts: true, addedSourceIDs: [], now: now) == nil)
    }

    @Test("An added source already in the pile or named as finished is named once")
    func addedOverlap() throws {
        let pile = CardsToCheckNudge.Pile(cardCount: 4, sourceIDs: ["a"])
        let made = try #require(CardsToCheckBanner.subject(
            pile: pile, candidates: [finished("b", now: now)], autoDrafts: false, addedSourceIDs: ["a", "b", "c"], now: now
        ))
        #expect(made.draftedSourceIDs == ["a"])
        #expect(made.undraftedSourceIDs == ["b"])
        #expect(made.addedSourceIDs == ["c"])
        #expect(made.makeCardsSourceIDs == ["b", "c"], "the click makes cards for everything that has none")
    }

    @Test("Drafts alone still open To Check; added sources turn the click into Make Cards")
    func clickTarget() {
        #expect(subject(cards: 4, drafted: ["a"]).makeCardsSourceIDs.isEmpty)
        #expect(subject(cards: 4, drafted: ["a"], added: ["c"]).makeCardsSourceIDs == ["c"])
    }

    @Test("What the banner says about additions")
    func addedWording() {
        #expect(CardsToCheckBanner.body(subject(added: ["a"])) == "A source you added has no cards yet.")
        #expect(CardsToCheckBanner.body(subject(added: ["a", "b", "c"])) == "3 sources you added have no cards yet.")
        #expect(CardsToCheckBanner.body(subject(cards: 2, drafted: ["a"], added: ["b", "c"]))
            == "2 cards from a source you finished wait to be checked. 2 sources you added have no cards yet.")
        #expect(CardsToCheckBanner.heading(subject(added: ["a"])) == CardsToCheckBanner.addedTitle)
        #expect(CardsToCheckBanner.heading(subject(cards: 2, drafted: ["a"], added: ["b"])) == CardsToCheckBanner.title)
        #expect(CardsToCheckBanner.heading(subject(undrafted: ["a"], added: ["b"])) == CardsToCheckBanner.title)
    }

    @Test("A source added today or yesterday is news; two days ago, or in the future, is not")
    func additionWindow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let noon = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12)))
        func at(day: Int, hour: Int) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour)))
        }
        #expect(CardsToCheckBanner.isRecentlyAdded(try at(day: 15, hour: 1), now: noon, calendar: calendar))
        #expect(CardsToCheckBanner.isRecentlyAdded(try at(day: 14, hour: 0), now: noon, calendar: calendar), "yesterday from midnight")
        #expect(!CardsToCheckBanner.isRecentlyAdded(try at(day: 13, hour: 23), now: noon, calendar: calendar))
        #expect(!CardsToCheckBanner.isRecentlyAdded(try at(day: 15, hour: 13), now: noon, calendar: calendar), "not yet added")
    }

    @Test("Added sources are told once like any other")
    func addedToldOnce() {
        let wait = subject(added: ["x"])
        let queued = CardsToCheckBanner.decide(subject: wait, ledger: .init(), now: now, fireAt: morning)
        #expect(queued.ledger.scheduled?.sourceIDs == ["x"])
        let after = morning.addingTimeInterval(3_600)
        let again = CardsToCheckBanner.decide(subject: wait, ledger: queued.ledger, now: after, fireAt: morning.addingTimeInterval(day))
        #expect(again.decision == .cancel, "yesterday's additions are not asked about twice")
        let fresh = CardsToCheckBanner.decide(subject: subject(added: ["x", "z"]), ledger: queued.ledger, now: after, fireAt: morning.addingTimeInterval(day))
        #expect(fresh.decision == .schedule(fireAt: morning.addingTimeInterval(day)))
    }

    @Test("New sources queue the morning's banner, and nothing waiting takes it down")
    func queuesAndCancels() {
        let wait = subject(cards: 4, drafted: ["a"])
        let queued = CardsToCheckBanner.decide(subject: wait, ledger: .init(), now: now, fireAt: morning)
        #expect(queued.decision == .schedule(fireAt: morning))
        #expect(queued.ledger.scheduled == .init(fireAt: morning, sourceIDs: ["a"]))

        let cleared = CardsToCheckBanner.decide(subject: nil, ledger: queued.ledger, now: now.addingTimeInterval(3_600), fireAt: morning)
        #expect(cleared.decision == .cancel, "the pile was gone before the morning")
        #expect(cleared.ledger.scheduled == nil)
        #expect(cleared.ledger.told.isEmpty, "a banner that never fired told no one")
    }

    @Test("Refreshing before the hour keeps the same banner queued")
    func refreshIsIdempotent() {
        let wait = subject(cards: 4, drafted: ["a"])
        let first = CardsToCheckBanner.decide(subject: wait, ledger: .init(), now: now, fireAt: morning)
        let again = CardsToCheckBanner.decide(subject: wait, ledger: first.ledger, now: now.addingTimeInterval(60), fireAt: morning)
        #expect(again.decision == .schedule(fireAt: morning))
        #expect(again.ledger == first.ledger)
    }

    @Test("A source is told once: after the banner's hour the same sources queue nothing, a pile that shrinks is not news, a new source is")
    func toldOnce() {
        let wait = subject(cards: 14, drafted: ["a", "b"])
        let queued = CardsToCheckBanner.decide(subject: wait, ledger: .init(), now: now, fireAt: morning)

        let after = morning.addingTimeInterval(3_600)
        let same = CardsToCheckBanner.decide(subject: wait, ledger: queued.ledger, now: after, fireAt: morning.addingTimeInterval(day))
        #expect(same.decision == .cancel, "the morning's banner has been and gone")
        #expect(Set(same.ledger.told.keys) == ["a", "b"])

        let shrunk = CardsToCheckBanner.decide(subject: subject(cards: 3, drafted: ["b"]), ledger: same.ledger, now: after, fireAt: morning.addingTimeInterval(day))
        #expect(shrunk.decision == .cancel, "going through a's cards is not a reason to ask again")

        let fresh = CardsToCheckBanner.decide(subject: subject(cards: 7, drafted: ["b", "c"]), ledger: same.ledger, now: after, fireAt: morning.addingTimeInterval(day))
        #expect(fresh.decision == .schedule(fireAt: morning.addingTimeInterval(day)))
        #expect(fresh.ledger.scheduled?.sourceIDs == ["b", "c"], "the banner counts everything that waits")
    }

    @Test("A source told a month ago is forgotten")
    func memoryIsBounded() {
        let old = CardsToCheckBanner.Ledger(told: ["a": now.addingTimeInterval(-Double(CardsToCheckBanner.rememberedDays + 1) * day)], scheduled: nil)
        let outcome = CardsToCheckBanner.decide(subject: subject(cards: 2, drafted: ["a"]), ledger: old, now: now, fireAt: morning)
        #expect(outcome.decision == .schedule(fireAt: morning))
        #expect(outcome.ledger.told.isEmpty)
    }

    @Test("The ledger round-trips through its own defaults")
    func ledgerStorage() throws {
        let suite = "foreverlm-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(CardsToCheckBanner.loadLedger(defaults: defaults) == CardsToCheckBanner.Ledger())
        let ledger = CardsToCheckBanner.Ledger(told: ["a": now], scheduled: .init(fireAt: morning, sourceIDs: ["b"]))
        CardsToCheckBanner.save(ledger, defaults: defaults)
        #expect(CardsToCheckBanner.loadLedger(defaults: defaults) == ledger)
    }
}

// MARK: - What was added, read from storage
//
// `StorageService.sourcesAddedWithoutCards`: which additions the banner may name.

private func added(
    _ id: String,
    addedDaysAgo: Double = 0,
    now: Date,
    state: StudioArticleState = .ready,
    words: Int? = 50,
    paywalled: Bool = false
) -> StudioArticle {
    var article = StudioArticle(url: "https://example.com/\(id)", title: id, sourceType: .article, discoveryOrigin: .manual, id: id)
    article.normalizedURL = URLNormalizer.normalize(article.url)
    article.content = "Some text about \(id)."
    article.wordCount = words
    article.state = state
    article.isPaywalled = paywalled
    article.dateAdded = now.addingTimeInterval(-addedDaysAgo * day)
    return article
}

@Suite("Sources added without cards")
struct SourcesAddedWithoutCardsTests {
    private func storage() throws -> (StorageService, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AddedWithoutCards_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (StorageService(storeRoot: root), root)
    }

    @Test("Recent, ready, uncovered sources are named; old, unfetched, empty and paywalled ones are not")
    func namesWhatCanBeDrafted() async throws {
        let (storage, root) = try storage()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try await storage.saveSource(added("today", now: now))
        try await storage.saveSource(added("long-ago", addedDaysAgo: 5, now: now))
        try await storage.saveSource(added("fetching", now: now, state: .fetching))
        try await storage.saveSource(added("empty", now: now, words: 0))
        try await storage.saveSource(added("paywalled", now: now, paywalled: true))
        #expect(try await storage.sourcesAddedWithoutCards(now: now) == ["today"])
    }

    @Test("A library with nothing added names nothing")
    func nothingAdded() async throws {
        let (storage, root) = try storage()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await storage.sourcesAddedWithoutCards(now: Date()).isEmpty)
    }
}
