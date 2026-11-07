import Foundation

// MARK: - Cards to check, as a banner the morning after
//
// docs/memory-design.md, "The morning-after banner". The corner card
// (`CardsToCheckNudge`) says drafted cards wait, but only to a learner who has
// ForeverLM open. The product owner, 2026-10-04: "whenever i consume new content, i
// want the next day to have some notification to let me process those new
// sources into flashcards." So the morning after a source is finished, one
// banner says its cards wait — or, with background drafting off, that the
// sources have none yet. Everything here is pure: what the banner is about,
// what it says, and when it is told or left unsaid. `CardsToCheckNotifications`
// schedules it.
//
// Since 2026-10-15 it is also the day's suggestion to make cards for what was
// added to the library, finished or not (product owner, 2026-10-15: "every
// day, there should also be a suggestion to make cards for all the content i
// added to the library that day; even at the highest level perhaps"): a
// source added today or yesterday that no card covers is named, and the click
// opens a Make Cards chat on all of them at once.

extension Notification.Name {
    /// Asks Studio to take up the cards banner's click in its active window.
    /// `object` is the `[String]` of finished sources with no cards, whose
    /// Make Cards chat opens; empty, To Check opens over every notebook.
    static let requestCardsFromFinished = Notification.Name("requestCardsFromFinished")
}

enum CardsToCheckBanner {
    static let title = "Cards from what you finished"
    /// The title when the library's additions are all it is about.
    static let addedTitle = "Cards from what you added"
    static let goThroughTitle = "Go Through Them"
    static let makeCardsTitle = "Make Cards"

    /// What the banner is about, as the library stands.
    struct Subject: Equatable, Sendable {
        /// Drafts ForeverLM made unasked that wait in To Check.
        let cardCount: Int
        /// The sources those drafts are from.
        let draftedSourceIDs: Set<String>
        /// Sources the learner finished that have no cards yet: background
        /// drafting is off, or its day's limit left them out.
        let undraftedSourceIDs: Set<String>
        /// Sources added to the library today or yesterday that no card
        /// covers, finished or not, and not among the two sets above.
        var addedSourceIDs: Set<String> = []

        var sourceIDs: Set<String> { draftedSourceIDs.union(undraftedSourceIDs).union(addedSourceIDs) }
        var hasDrafts: Bool { cardCount > 0 }

        /// The sources whose cards the click makes: what has none yet, added
        /// or finished. Empty when only drafts wait, whose click opens To
        /// Check; when added sources are named too, the click makes cards.
        var makeCardsSourceIDs: [String] {
            if hasDrafts && addedSourceIDs.isEmpty { return [] }
            return undraftedSourceIDs.union(addedSourceIDs).sorted()
        }
    }

    /// How far back an addition is still news: today and the day before, so a
    /// source added after the last refresh of a day, or on a Mac that was
    /// off, is still told the next morning.
    static let addedWindowDays = 2

    /// Whether a source added at `addedAt` is within the banner's reach.
    static func isRecentlyAdded(_ addedAt: Date, now: Date, calendar: Calendar = .current) -> Bool {
        guard addedAt <= now,
              let from = calendar.date(byAdding: .day, value: -(addedWindowDays - 1), to: calendar.startOfDay(for: now))
        else { return false }
        return addedAt >= from
    }

    /// The subject of the banner: the pile that waits in To Check and, while
    /// background drafting is off, the finished sources no deck covers.
    /// With drafting on, those sources are drafted as they are finished and
    /// reach the pile, so they are not named twice. Nil when there
    /// is nothing to process. `addedSourceIDs` are the recent additions no card
    /// covers (`StorageService.sourcesAddedWithoutCards`): named whether or
    /// not the learner finished them, since background drafting only drafts
    /// what was read.
    static func subject(
        pile: CardsToCheckNudge.Pile?,
        candidates: [AutomaticCardDrafting.Candidate],
        autoDrafts: Bool,
        addedSourceIDs: Set<String> = [],
        now: Date
    ) -> Subject? {
        let drafted = pile?.sourceIDs ?? []
        var undrafted = Set<String>()
        if !autoDrafts {
            for candidate in candidates where AutomaticCardDrafting.exclusion(candidate, now: now) == nil {
                undrafted.insert(candidate.deckSourceID)
            }
        }
        undrafted.subtract(drafted)
        let added = addedSourceIDs.subtracting(drafted).subtracting(undrafted)
        let cardCount = pile?.cardCount ?? 0
        guard cardCount > 0 || !undrafted.isEmpty || !added.isEmpty else { return nil }
        return Subject(
            cardCount: cardCount,
            draftedSourceIDs: drafted,
            undraftedSourceIDs: undrafted,
            addedSourceIDs: added
        )
    }

    /// "Cards from what you added" when additions are all there is to say.
    static func heading(_ subject: Subject) -> String {
        subject.hasDrafts || !subject.undraftedSourceIDs.isEmpty ? title : addedTitle
    }

    /// "14 cards from 3 sources you finished wait to be checked." or "2
    /// sources you finished have no cards yet." Added sources follow in a
    /// sentence of their own: "5 sources you added have no cards yet."
    static func body(_ subject: Subject) -> String {
        var sentences: [String] = []
        if subject.hasDrafts {
            let cards = subject.cardCount == 1 ? "1 card" : "\(subject.cardCount) cards"
            let sources = subject.draftedSourceIDs.count
            let from = sources == 1 ? "a source" : "\(sources) sources"
            sentences.append("\(cards) from \(from) you finished \(subject.cardCount == 1 ? "waits" : "wait") to be checked.")
        } else if !subject.undraftedSourceIDs.isEmpty {
            sentences.append(noCards(subject.undraftedSourceIDs.count, verb: "finished"))
        }
        if !subject.addedSourceIDs.isEmpty {
            sentences.append(noCards(subject.addedSourceIDs.count, verb: "added"))
        }
        return sentences.joined(separator: " ")
    }

    private static func noCards(_ count: Int, verb: String) -> String {
        count == 1 ? "A source you \(verb) has no cards yet." : "\(count) sources you \(verb) have no cards yet."
    }

    // MARK: Telling once

    /// What this Mac has said and what it has queued, device-local: a banner
    /// is about the Mac that shows it, and the phone has its own reminder.
    struct Ledger: Codable, Equatable, Sendable {
        /// A source the learner was told about, and when. A source is told
        /// once: going through half its cards, or a pile that shrinks, is
        /// never news.
        var told: [String: Date] = [:]
        var scheduled: Scheduled?

        struct Scheduled: Codable, Equatable, Sendable {
            let fireAt: Date
            let sourceIDs: [String]
        }
    }

    enum Decision: Equatable, Sendable {
        /// Nothing new to say: take the queued banner down.
        case cancel
        /// Queue the banner for `fireAt`, replacing any queued one.
        case schedule(fireAt: Date)
    }

    /// How long a told source is remembered: past the window a source can be
    /// drafted in, it is not offered again anyway.
    static let rememberedDays = 30

    /// Whether to queue a banner for `fireAt` (the next morning's hour), and
    /// the ledger afterwards. A banner whose time has passed counts as told —
    /// delivered, or missed on a Mac that was off, which the corner card
    /// still covers — so the same sources never come back as a second one;
    /// sources finished since are new and queue the next.
    static func decide(
        subject: Subject?,
        ledger: Ledger,
        now: Date,
        fireAt: Date,
        calendar: Calendar = .current
    ) -> (decision: Decision, ledger: Ledger) {
        var ledger = ledger
        if let scheduled = ledger.scheduled, scheduled.fireAt <= now {
            for id in scheduled.sourceIDs { ledger.told[id] = scheduled.fireAt }
            ledger.scheduled = nil
        }
        let cutoff = calendar.date(byAdding: .day, value: -rememberedDays, to: now) ?? .distantPast
        ledger.told = ledger.told.filter { $0.value >= cutoff }
        guard let subject, !subject.sourceIDs.subtracting(ledger.told.keys).isEmpty else {
            ledger.scheduled = nil
            return (.cancel, ledger)
        }
        ledger.scheduled = Ledger.Scheduled(fireAt: fireAt, sourceIDs: subject.sourceIDs.sorted())
        return (.schedule(fireAt: fireAt), ledger)
    }

    // MARK: Storage

    /// Device-local, listed in `SyncedPreferenceKeys.excluded`.
    static let ledgerKey = "memory.draftBanner.ledger.v1"

    static func loadLedger(defaults: UserDefaults = .standard) -> Ledger {
        guard let data = defaults.data(forKey: ledgerKey),
              let ledger = try? JSONDecoder().decode(Ledger.self, from: data) else { return Ledger() }
        return ledger
    }

    static func save(_ ledger: Ledger, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: ledgerKey)
    }
}
