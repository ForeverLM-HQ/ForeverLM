import Foundation

// MARK: - Memory as cards: drafting in the background
//
// docs/memory-design.md, "Drafting in the background". The product owner, 2026-10-01
// (decisions v5, 3): "As the learner reads, watches or finishes a source, AI
// drafts cards in the background (budgeted, BackgroundAISpend, the learner's
// model) into 'To check'". What is decided here is pure: which sources are
// candidates, in what order, how many a day, and when the corner card that
// says cards wait is shown. `AutomaticCardDraftingPass` reads storage and
// drafts through the one `CardDraftingService`.

// MARK: Settings

/// The card settings of Settings › General › Memory review, and whether review
/// questions are written ahead of time, each synced
/// (`SyncedPreferenceKeys.synced`) and read and written over MCP
/// (`get_memory_review_settings` / `set_memory_review_settings`).
enum MemoryCardSettings {
    /// How many new cards a day's review introduces (`MemoryCardQueue`); it
    /// also sets how many sources are drafted in the background a day.
    static let newCardsPerDayKey = MemoryCardQueue.newPerDayPreferenceKey
    /// Whether ForeverLM drafts cards in the background as sources are
    /// finished. Off until the learner turns it on: a source's card is the
    /// learner's to write (product owner, 2026-11-08: "It shouldn't just be
    /// AI making those cards"; `WrittenCard.swift`), which retires decisions
    /// v5, 3's default.
    static let autoDraftKey = "memory.auto_draft_cards"
    /// Whether the "Cards to check" corner card is shown. Its Don't Ask Again
    /// turns it off.
    static let draftNudgesKey = "memory.draft_nudges"
    /// Whether ForeverLM writes review questions ahead of time for the few
    /// sources a review is likely to be about today
    /// (`StudioViewModel.startReviewGuidePrebuild`). On until the learner
    /// turns it off; a review without them still runs.
    static let prepareReviewQuestionsKey = "memory.prepare_review_questions"

    static func newCardsPerDay(defaults: UserDefaults = .standard) -> Int {
        MemoryCardQueue.newPerDay(stored: (defaults.object(forKey: newCardsPerDayKey) as? NSNumber)?.intValue)
    }

    static func setNewCardsPerDay(_ count: Int) {
        PreferenceStore.set(MemoryCardQueue.clampNewPerDay(count), forKey: newCardsPerDayKey)
    }

    static func autoDraftsCards(defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: autoDraftKey) as? NSNumber)?.boolValue ?? false
    }

    static func setAutoDraftsCards(_ on: Bool) {
        PreferenceStore.set(on, forKey: autoDraftKey)
    }

    static func showsDraftNudges(defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: draftNudgesKey) as? NSNumber)?.boolValue ?? true
    }

    static func setShowsDraftNudges(_ on: Bool) {
        PreferenceStore.set(on, forKey: draftNudgesKey)
    }

    static func preparesReviewQuestions(defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: prepareReviewQuestionsKey) as? NSNumber)?.boolValue ?? true
    }

    static func setPreparesReviewQuestions(_ on: Bool) {
        PreferenceStore.set(on, forKey: prepareReviewQuestionsKey)
    }
}

// MARK: Candidates, ranking and the day's limit

enum AutomaticCardDrafting {
    /// How long a consumed source stays a candidate: the cohort's window
    /// (`CohortSelector.windowDays`). A source the day's limit leaves out is
    /// drafted on a later day while it is inside it — leftovers roll forward
    /// ten days — and never once it is out.
    static let windowDays = CohortSelector.windowDays
    /// The cards asked of each source: Make Cards' Auto share.
    static let cardsPerSource = MemoryCardRequestCount.autoPerSource
    /// How many sources a chat must discuss to be a wide chat: one whose
    /// sources are drafted from what it discussed, though none of them was
    /// finished (decisions 2026-09-30, "Automatic": "a chat citing ≥10
    /// sources drafts at most one card per discussed idea").
    static let wideChatSourceCount = 10

    /// The sources discussed by a wide chat the learner wrote in within the
    /// window: a chat that discussed `wideChatSourceCount` sources or more
    /// (`ChatSourceEvidence.discussedSourceIDs`: cited in its turns, never
    /// merely attached). Such a chat is a survey across the library; the
    /// ideas it engaged on each source are what the learner met there, and
    /// those are drafted (`CardDraftingReach.discussed`) — a card a discussed
    /// idea at most. A chat that discussed fewer still lifts no source into
    /// drafting on its own.
    static func wideChatSourceIDs(_ chats: [KnowledgeStore.ChatDiscussion], now: Date) -> Set<String> {
        var sourceIDs = Set<String>()
        for chat in chats where chat.sourceIDs.count >= wideChatSourceCount
            && chat.at <= now && CohortSelector.days(from: chat.at, to: now) <= windowDays {
            sourceIDs.formUnion(chat.sourceIDs)
        }
        return sourceIDs
    }

    /// How many sources are drafted in the background a day: as many as fill
    /// the day's new cards at the cards asked of each (decisions 2026-09-30,
    /// the product owner's call 2), at least one. Ten new cards a day is three sources.
    static func dailySourceLimit(newCardsPerDay: Int) -> Int {
        let cards = MemoryCardQueue.clampNewPerDay(newCardsPerDay)
        return max(1, (cards + cardsPerSource - 1) / cardsPerSource)
    }

    /// The day's count: draft decks created today, by the local calendar. A
    /// deck is one Artifact per source whose record carries its creation time
    /// to every Mac, so the finish trigger, the evening run and the other Mac
    /// read one fact. Make Cards' and an assistant's new decks count too: the
    /// limit is about how many new drafts a day brings, whoever asked.
    static func decksCreatedToday(_ createdAt: [Date], now: Date, calendar: Calendar = .current) -> Int {
        createdAt.filter { calendar.isDate($0, inSameDayAs: now) && $0 <= now }.count
    }

    /// One source background drafting may draft, with what decides it.
    struct Candidate: Equatable, Sendable {
        /// The source as the cohort lists it.
        let sourceID: String
        /// The source the deck is for: the learner's own at a team copy's
        /// address, else `sourceID`.
        let deckSourceID: String
        let title: String
        let consumedAt: Date
        /// Finished by the learner (`SourceConsumption.isFinished`).
        let isFinished: Bool
        let engagement: CohortEngagement
        let confidence: SourceConsumptionConfidence
        /// Active ideas within reach.
        let ideaCount: Int
        /// Its source has a draft deck already: only Make Cards adds to one.
        let hasDeck: Bool
        /// In a notebook with a block on today's calendar or an open Goal.
        let isNeededSoon: Bool
        /// What of it drafting may use (`CardDraftingReach.of`, or for a
        /// source only a wide chat brings, `CardDraftingReach.discussed`).
        let reach: CardDraftingReach
        /// Discussed by a wide chat within the window
        /// (`wideChatSourceIDs`): a candidate though neither finished nor
        /// annotated, drafted from the ideas the chat engaged.
        var isWideChatDiscussed = false
    }

    /// Why a source is not drafted in the background; nil when it may be.
    enum Exclusion: String, Equatable, Sendable {
        /// Consumed more than ten days ago: it rolled out of the window.
        case outsideWindow
        /// Neither finished nor annotated nor discussed by a wide chat: met
        /// only by reading part of it, or only through a narrower chat's
        /// citations.
        case notFinished
        /// No ideas within reach to draft from yet.
        case noIdeas
        /// Its source has a deck: background drafting never adds to one, so
        /// a re-hash never redrafts.
        case hasDeck
    }

    static func exclusion(_ candidate: Candidate, now: Date) -> Exclusion? {
        if candidate.hasDeck { return .hasDeck }
        guard CohortSelector.days(from: candidate.consumedAt, to: now) <= windowDays,
              candidate.consumedAt <= now else { return .outsideWindow }
        // A deliberate finish, or annotated, or discussed by a wide chat:
        // never a source consumed only through a narrower chat's citations,
        // which lifts consumption without either.
        guard candidate.isFinished || candidate.engagement.isAnnotated || candidate.isWideChatDiscussed else {
            return .notFinished
        }
        guard candidate.ideaCount > 0 else { return .noIdeas }
        return nil
    }

    /// Needed soon first, then annotated, then time × depth, then the most
    /// recently consumed (decisions 2026-09-30, "Automatic").
    static func ranked(_ candidates: [Candidate]) -> [Candidate] {
        candidates.sorted { lhs, rhs in
            if lhs.isNeededSoon != rhs.isNeededSoon { return lhs.isNeededSoon }
            if lhs.engagement.isAnnotated != rhs.engagement.isAnnotated { return lhs.engagement.isAnnotated }
            if lhs.engagement.score != rhs.engagement.score { return lhs.engagement.score > rhs.engagement.score }
            if lhs.consumedAt != rhs.consumedAt { return lhs.consumedAt > rhs.consumedAt }
            return lhs.deckSourceID < rhs.deckSourceID
        }
    }

    /// What one run drafts, and what waits.
    struct Plan: Equatable, Sendable {
        /// The sources this run drafts, in rank order.
        let draft: [Candidate]
        /// Candidates left for another day by the limit: they roll forward
        /// while they are inside the window.
        let waiting: Int
        /// The day's sources left before this run.
        let slots: Int
    }

    /// The run's sources: the best ranked candidates the day's slots take,
    /// or — the finish trigger — those of `only` among them, in their place.
    /// A source that failed lately (`failed`) waits out its retry.
    static func plan(
        _ candidates: [Candidate],
        decksCreatedToday: Int,
        limit: Int,
        failed: Set<String> = [],
        only: Set<String>? = nil,
        now: Date
    ) -> Plan {
        var seen = Set<String>()
        let eligible = ranked(candidates.filter { candidate in
            exclusion(candidate, now: now) == nil
                && !failed.contains(candidate.deckSourceID)
                && seen.insert(candidate.deckSourceID).inserted
        })
        let slots = max(0, limit - decksCreatedToday)
        let pool = only.map { wanted in
            eligible.filter { wanted.contains($0.sourceID) || wanted.contains($0.deckSourceID) }
        } ?? eligible
        let draft = Array(pool.prefix(slots))
        return Plan(draft: draft, waiting: eligible.count - draft.count, slots: slots)
    }
}

// MARK: What failed, and the last run

/// Sources background drafting could not draft, remembered on this Mac for a
/// day so the next trigger does not bill the same call, and named in the day
/// close's status line. A source the daily cap stopped is not a failure.
enum AutomaticCardDraftingFailures {
    static let key = "memory.autoDraft.failures.v1"
    static let retryInterval: TimeInterval = 24 * 60 * 60

    struct Record: Equatable, Sendable {
        let sourceID: String
        let title: String
        let failedAt: Date
        let message: String
    }

    static func record(
        sourceID: String,
        title: String,
        message: String,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        var entries = pruned(defaults.dictionary(forKey: key) as? [String: [String: Any]] ?? [:], now: now)
        entries[sourceID] = [
            "title": String(title.prefix(200)),
            "at": now.timeIntervalSinceReferenceDate,
            "message": String(message.prefix(300)),
        ]
        defaults.set(entries, forKey: key)
    }

    /// The failures still in their retry interval, newest first.
    static func recent(now: Date = Date(), defaults: UserDefaults = .standard) -> [Record] {
        let entries = defaults.dictionary(forKey: key) as? [String: [String: Any]] ?? [:]
        return pruned(entries, now: now).compactMap { sourceID, entry in
            guard let at = entry["at"] as? Double else { return nil }
            return Record(
                sourceID: sourceID,
                title: entry["title"] as? String ?? sourceID,
                failedAt: Date(timeIntervalSinceReferenceDate: at),
                message: entry["message"] as? String ?? ""
            )
        }
        .sorted { $0.failedAt > $1.failedAt }
    }

    static func clear(sourceID: String, defaults: UserDefaults = .standard) {
        guard var entries = defaults.dictionary(forKey: key) as? [String: [String: Any]],
              entries.removeValue(forKey: sourceID) != nil else { return }
        defaults.set(entries, forKey: key)
    }

    private static func pruned(_ entries: [String: [String: Any]], now: Date) -> [String: [String: Any]] {
        entries.filter { _, entry in
            guard let at = entry["at"] as? Double else { return false }
            let age = now.timeIntervalSinceReferenceDate - at
            return age >= 0 && age < retryInterval
        }
    }
}

/// What this Mac's last background drafting run did, for the corner card's
/// "2 more sources to come" and `get_memory_review_settings`.
struct AutomaticCardDraftingRun: Codable, Equatable, Sendable {
    static let key = "memory.autoDraft.lastRun.v1"

    var at: Date
    var draftedCards: Int
    var draftedSources: Int
    /// Candidates the day's limit left for another day.
    var waiting: Int

    static func last(defaults: UserDefaults = .standard) -> AutomaticCardDraftingRun? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(AutomaticCardDraftingRun.self, from: data)
    }

    func record(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// What still waits, as of `now`: a count a day or more old says nothing
    /// about today's candidates.
    func waiting(asOf now: Date) -> Int {
        let age = now.timeIntervalSince(at)
        return age >= 0 && age < 24 * 60 * 60 ? waiting : 0
    }
}

// MARK: The corner card

/// "Cards to check · 14 from 3 sources you finished": the corner card that
/// says cards drafted in the background wait (decisions 2026-09-30, "Entry
/// points"). A sibling of "Plan your day?" (`PlanTheDayCard`), in the same
/// place, one at a time. Go Through Them opens To Check; × is later, asked
/// again the next day; Don't Ask Again turns `memory.draft_nudges` off.
///
/// Since 2026-10-16 it also counts the library's sources that no card covers,
/// read or not. Product owner, 2026-10-16: "my goal is to have at least 1
/// flashcard for each piece of content that's in the library; and it should
/// really help me understand and piece together these ideas." Make Cards
/// opens the sheet for them together, with its count and price, so the cards
/// can link the ideas that several sources print (`CardSourceLinker`).
enum CardsToCheckNudge {
    static let title = "Cards to check"
    /// The title when sources without cards are all the card has to say.
    static let uncoveredTitle = "Sources without cards"
    static let goThroughTitle = "Go Through Them"
    static let chooseSourcesTitle = "Choose Sources"

    /// What the card is about: the drafts ForeverLM made in the background
    /// that wait in To Check (not asked for, not an assistant's), and the
    /// library's sources no card covers.
    struct Pile: Equatable, Sendable {
        let cardCount: Int
        let sourceIDs: Set<String>
        /// Sources in the library that no card covers
        /// (`StorageService.sourcesWithoutCards`), apart from `sourceIDs`.
        var uncoveredSourceIDs: Set<String> = []

        var hasDrafts: Bool { cardCount > 0 }
        var isEmpty: Bool { cardCount == 0 && uncoveredSourceIDs.isEmpty }
        /// Every source the card names, for what a read mark is about.
        var allSourceIDs: Set<String> { sourceIDs.union(uncoveredSourceIDs) }
    }

    /// The drafts alone: nil when none wait.
    static func pile(_ toCheck: [MemoryCardToCheck]) -> Pile? {
        let drafts = toCheck.filter { $0.kind == .draft && !$0.isRequested && $0.face.origin == .drafted }
        guard !drafts.isEmpty else { return nil }
        return Pile(cardCount: drafts.count, sourceIDs: Set(drafts.map(\.sourceID)))
    }

    /// `drafts` with the sources no card covers. A source whose drafts wait
    /// is not also uncovered. Nil when there is nothing to say.
    static func pile(drafts: Pile?, uncovered: Set<String>) -> Pile? {
        let added = uncovered.subtracting(drafts?.sourceIDs ?? [])
        guard drafts?.hasDrafts == true || !added.isEmpty else { return nil }
        return Pile(cardCount: drafts?.cardCount ?? 0, sourceIDs: drafts?.sourceIDs ?? [], uncoveredSourceIDs: added)
    }

    /// The card's title: "Sources without cards" when those are all there is
    /// to say.
    static func heading(_ pile: Pile) -> String {
        pile.hasDrafts ? title : uncoveredTitle
    }

    /// "14 from 3 sources you finished · 2 more sources to come", "5 sources
    /// have no cards yet", or both: "14 from 3 sources you finished · 5
    /// sources have no cards yet".
    static func detail(_ pile: Pile, waiting: Int) -> String {
        let added = pile.uncoveredSourceIDs.count
        guard pile.hasDrafts else {
            return added == 1 ? "A source has no cards yet" : "\(added) sources have no cards yet"
        }
        let sources = pile.sourceIDs.count
        var line = sources == 1
            ? "\(pile.cardCount) from a source you finished"
            : "\(pile.cardCount) from \(sources) sources you finished"
        if waiting > 0 {
            line += waiting == 1 ? " · 1 more source to come" : " · \(waiting) more sources to come"
        }
        if added > 0 {
            line += added == 1 ? " · 1 source has no cards yet" : " · \(added) sources have no cards yet"
        }
        return line
    }

    /// Whether a window shows the card: drafts wait, the learner has not
    /// turned it off or put it off today, and the window is not given to the
    /// memory review, to Getting Started, to "Plan your day?" (one corner
    /// card at a time; this one waits) or to the Reader on one of the pile's
    /// sources, whose toolbar already says "Cards · N to check".
    static func isShown(
        pile: Pile?,
        showsNudges: Bool,
        putOffDay: String?,
        today: String,
        isMemoryReviewFocused: Bool,
        isGettingStarted: Bool,
        asksToPlanTheDay: Bool,
        readerSourceIDsOnScreen: Set<String>
    ) -> Bool {
        guard let pile, !pile.isEmpty, showsNudges, putOffDay != today else { return false }
        guard !isMemoryReviewFocused, !isGettingStarted, !asksToPlanTheDay else { return false }
        return pile.sourceIDs.isDisjoint(with: readerSourceIDsOnScreen)
    }

    /// The day this Mac put the card off: × or Go Through Them. Device-local,
    /// like "Plan your day?"'s ledger: the card is asked on this Mac.
    static let putOffKey = "memory.draftNudge.putOffOn.v1"

    static func putOffDay(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: putOffKey)
    }

    static func putOff(on day: String, defaults: UserDefaults = .standard) {
        defaults.set(day, forKey: putOffKey)
    }
}
