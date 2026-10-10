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

private func subject(cards: Int = 0, drafted: Set<String> = [], undrafted: Set<String> = []) -> CardsToCheckBanner.Subject {
    CardsToCheckBanner.Subject(cardCount: cards, draftedSourceIDs: drafted, undraftedSourceIDs: undrafted)
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

    @Test("With drafting off, finished sources with no deck are the subject; with it on the day close drafts them, so they are not named")
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
