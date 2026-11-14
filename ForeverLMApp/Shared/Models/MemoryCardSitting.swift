import Foundation

// MARK: - Memory as cards: the card review
//
// docs/memory-design.md, "The card review (2026-10-01)". Stage three of
// memory as cards: kept cards are dealt one at a time in the window-filling
// memory focus, self-graded Forgot or Remembered, across every notebook or
// narrowed to one. Everything here is pure (Foundation only), so the Mac's
// review, its Memory pane, the iPhone's card review and the tests read one
// set of rules; the screens and the storage calls live in
// `MemoryCardSessionModel`, `MemoryCardSessionView` and `MemoryPane` on the
// Mac, and in `MobileCardReviewView` on the iPhone (project.yml compiles this
// file, with `NotebookMembership`, `MemoryCardVariation`, `MemoryCardTriage`
// and `FlashcardDeck`, into the phone).

/// Which kept cards a card review deals and the Memory pane counts: every
/// notebook by default, or one (decisions v5, 3: recall spans every notebook,
/// narrowable to one). The Mac's Memory pane and the iPhone's card review
/// both choose by it.
enum MemoryReviewScope: Hashable, Sendable {
    /// Every notebook's cards, and every card in no notebook: the default.
    case allNotebooks
    /// One notebook's cards, its Notebook id: the cards anchored on its
    /// sources (`MemoryCardScope`, over homing's `NotebookMembership`).
    case notebook(String)
}

/// One notebook's share of the kept cards, asked through homing's one rule
/// (`NotebookMembership`, docs/notebooks-design.md "Homing"). A kept card is
/// a derived thing: it carries no notebook of its own (the goal is part of an
/// item's curriculum fingerprint, so Keep leaves it nil) and rides the
/// sources it is anchored on, so it belongs to every notebook holding one of
/// them (docs/memory-design.md, "Cards: identity and Keep"). A team's
/// notebook lists the team's copies of its sources while a card is anchored
/// on the learner's own source at the same address; the membership resolves
/// each copy to that source (`teamCopyAliases`, docs/teams-design.md decision
/// 19). A card made with the notebook, or one of its Goals, as its goal is
/// filed there — the filed rule.
struct MemoryCardScope: Equatable, Sendable {
    /// The notebook as homing asks it: its sources (team copies resolved to
    /// the learner's own), its Goals' Notebook, the aliases.
    let membership: NotebookMembership
    /// Every id the notebook's sources go by — the learner's own source and
    /// each team copy standing for it — which a deadline matches anchors
    /// against (`MemoryCardDeadline.sourceIDs`).
    let sourceIDs: Set<String>

    var notebookID: String { membership.notebookID }

    init(membership: NotebookMembership) {
        self.membership = membership
        var ids = membership.sourceIDs
        for (copy, own) in membership.sourceAliases where membership.sourceIDs.contains(own) {
            ids.insert(copy)
        }
        sourceIDs = ids
    }

    /// The notebook's pool as listed (blank ids dropped), with its team
    /// copies' aliases and its Goals' Notebooks.
    init(
        notebookID: String,
        memberSourceIDs: [String],
        teamCopyAliases: [String: String] = [:],
        goalParents: [String: String] = [:]
    ) {
        self.init(membership: NotebookMembership(
            notebookID: notebookID,
            memberSourceIDs: memberSourceIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            goalParents: goalParents,
            sourceAliases: teamCopyAliases
        ))
    }

    /// Whether `item` is one of the notebook's cards: one of its anchors is
    /// a source in the notebook (by its own id or a team copy's), or it was
    /// made with the notebook, or one of its Goals, as its goal.
    func contains(_ item: MemoryItem) -> Bool {
        contains(anchorSourceIDs: item.sources.map(\.sourceID), goalID: item.goalID)
    }

    func contains(anchorSourceIDs: [String], goalID: String?) -> Bool {
        membership.containsDerived(anyOf: anchorSourceIDs) || membership.containsFiled([goalID])
    }
}

/// Which cards a sitting deals.
enum MemoryCardDeal {
    /// Today's cards in a scope: `MemoryCardQueue.today` over the scope's
    /// items. The day's allowance of new cards is one, whichever notebook the
    /// review is narrowed to, so the new cards already introduced today
    /// outside the scope come off it. No scope is every notebook, and exactly
    /// `MemoryCardQueue.today`.
    static func today(
        items: [MemoryItem],
        attempts: [MemoryAttempt],
        now: Date,
        budgetMinutes: Int?,
        newPerDay: Int,
        deadlines: [MemoryCardDeadline],
        scope: MemoryCardScope?,
        calendar: Calendar = .current
    ) -> MemoryCardQueue.Today {
        guard let scope else {
            return MemoryCardQueue.today(
                items: items,
                attempts: attempts,
                now: now,
                budgetMinutes: budgetMinutes,
                newPerDay: newPerDay,
                deadlines: deadlines,
                calendar: calendar
            )
        }
        let inside = items.filter(scope.contains)
        let outside = items.filter { !scope.contains($0) }
        let elsewhere = MemoryCardQueue.today(
            items: outside,
            attempts: attempts,
            now: now,
            budgetMinutes: nil,
            newPerDay: 0,
            deadlines: [],
            calendar: calendar
        )
        return MemoryCardQueue.today(
            items: inside,
            attempts: attempts,
            now: now,
            budgetMinutes: budgetMinutes,
            newPerDay: max(0, newPerDay - elsewhere.newIntroducedToday),
            deadlines: deadlines,
            calendar: calendar
        )
    }

    /// Learner-started practice of new cards: the scope's new cards today's
    /// review leaves out (`dealtToday`) — kept today, which the daily review
    /// never asks on the day they were kept, or past the day's allowance —
    /// oldest kept first. The learner asked for them, so their answers count
    /// (`MemoryCardQueue.answerCounts` with `practice`) and set each card's
    /// schedule from that first answer.
    static func practice(
        items: [MemoryItem],
        attempts: [MemoryAttempt],
        scope: MemoryCardScope?,
        excluding dealtToday: Set<String>,
        calendar: Calendar = .current
    ) -> [MemoryCardQueue.Entry] {
        let attemptsByItemID = Dictionary(grouping: attempts, by: \.memoryItemID)
        var seen = Set<String>()
        var entries: [MemoryCardQueue.Entry] = []
        for item in items where item.status == .active && !dealtToday.contains(item.id) {
            guard scope?.contains(item) ?? true, seen.insert(item.id).inserted else { continue }
            let schedule = MemoryTutorScheduler.schedule(
                item: item,
                attempts: attemptsByItemID[item.id] ?? [],
                calendar: calendar
            )
            guard schedule.isNew else { continue }
            entries.append(MemoryCardQueue.Entry(
                item: item,
                schedule: schedule,
                bucket: .new,
                notebookID: nil,
                daysOverdue: 0
            ))
        }
        return entries.sorted {
            if $0.item.createdAt != $1.item.createdAt { return $0.item.createdAt < $1.item.createdAt }
            return $0.item.id < $1.item.id
        }
    }

    /// A notebook's Practice, which the learner starts from its Studio
    /// (docs/memory-design.md, "Practice for a notebook"): every kept card in
    /// the notebook, not only today's. `answerable` are those whose answer
    /// is written — the due cards, most overdue first, then the new cards,
    /// oldest kept first, one kept today among them (practice the learner
    /// started is exempt from "not on the day of consumption") — and
    /// `notDueYet` the rest, the soonest due first, whose answer is shown and
    /// not written, so practice never stretches an interval. The caller deals
    /// the notebook's undecided drafts between the two
    /// (`MemoryCardSitting.Card.draft`): their answers count, as their first.
    struct NotebookPractice: Equatable, Sendable {
        let answerable: [MemoryCardQueue.Entry]
        let notDueYet: [MemoryCardQueue.Entry]

        var all: [MemoryCardQueue.Entry] { answerable + notDueYet }
    }

    /// Practice has no buckets of its own: a card seen before is `.due`'s,
    /// due yet or not, and `daysOverdue` is 0 for one not due. What an answer
    /// writes is storage's to decide, as for any practice
    /// (`MemoryCardQueue.answerCounts` with `practice`).
    static func notebookPractice(
        items: [MemoryItem],
        attempts: [MemoryAttempt],
        scope: MemoryCardScope,
        now: Date,
        calendar: Calendar = .current
    ) -> NotebookPractice {
        wholePractice(items: items, attempts: attempts, now: now, calendar: calendar, including: scope.contains)
    }

    /// Practice of the kept cards a chat chose for the learner
    /// (`practice_cards`: "show me my cards on mitochondria"), dealt in a
    /// notebook's Practice's order: the chosen cards whose answer is written,
    /// then those not due yet. `itemIDs` are the chosen cards' items; an id
    /// no card among `items` has is dealt nothing.
    static func chosenPractice(
        items: [MemoryItem],
        attempts: [MemoryAttempt],
        itemIDs: Set<String>,
        now: Date,
        calendar: Calendar = .current
    ) -> NotebookPractice {
        wholePractice(items: items, attempts: attempts, now: now, calendar: calendar) { itemIDs.contains($0.id) }
    }

    /// Every active card `including` takes, not only today's, in Practice's
    /// order (`NotebookPractice`).
    private static func wholePractice(
        items: [MemoryItem],
        attempts: [MemoryAttempt],
        now: Date,
        calendar: Calendar,
        including: (MemoryItem) -> Bool
    ) -> NotebookPractice {
        let attemptsByItemID = Dictionary(grouping: attempts, by: \.memoryItemID)
        var seen = Set<String>()
        var due: [MemoryCardQueue.Entry] = []
        var new: [MemoryCardQueue.Entry] = []
        var later: [MemoryCardQueue.Entry] = []
        for item in items where item.status == .active && including(item) {
            guard seen.insert(item.id).inserted else { continue }
            let schedule = MemoryTutorScheduler.schedule(
                item: item,
                attempts: attemptsByItemID[item.id] ?? [],
                calendar: calendar
            )
            if schedule.isNew {
                new.append(MemoryCardQueue.Entry(item: item, schedule: schedule, bucket: .new, notebookID: nil, daysOverdue: 0))
            } else if schedule.dueAt <= now {
                let overdue = Int(max(0, now.timeIntervalSince(schedule.dueAt)) / MemoryTutorScheduler.secondsPerDay)
                due.append(MemoryCardQueue.Entry(item: item, schedule: schedule, bucket: .due, notebookID: nil, daysOverdue: overdue))
            } else {
                later.append(MemoryCardQueue.Entry(item: item, schedule: schedule, bucket: .due, notebookID: nil, daysOverdue: 0))
            }
        }
        func soonerDue(_ lhs: MemoryCardQueue.Entry, _ rhs: MemoryCardQueue.Entry) -> Bool {
            if lhs.schedule.dueAt != rhs.schedule.dueAt { return lhs.schedule.dueAt < rhs.schedule.dueAt }
            return lhs.item.id < rhs.item.id
        }
        func olderKept(_ lhs: MemoryCardQueue.Entry, _ rhs: MemoryCardQueue.Entry) -> Bool {
            if lhs.item.createdAt != rhs.item.createdAt { return lhs.item.createdAt < rhs.item.createdAt }
            return lhs.item.id < rhs.item.id
        }
        return NotebookPractice(
            answerable: due.sorted(by: soonerDue) + new.sorted(by: olderKept),
            notDueYet: later.sorted(by: soonerDue)
        )
    }
}

/// The wording a card is asked in (docs/memory-design.md, "Variations"): its
/// front — the learner's own rewording when they made one — until the card
/// has been remembered twice, then a variant from its state row, never the
/// wording asked last. "Always ask it this way" keeps the front. A variant
/// the learner said asks something else, or one missed more often than the
/// front over three uses, is retired (`MemoryCardVariation.retired`). A card
/// the day close has not reworded yet is asked as kept.
enum MemoryCardWording {
    struct Asked: Equatable, Sendable {
        let text: String
        /// A rewording from the state row, not the front.
        let isVariant: Bool
        /// The first time this card is asked in other words, which the
        /// review says once: "Worded differently on purpose — same answer."
        let isFirstVariedServe: Bool
        /// The rewording's place in the state row's `variants`, which "This
        /// asks something else" records; nil for the front.
        var variantIndex: Int? = nil
    }

    /// Successes a card earns before a variant may stand in for its front.
    static let successesBeforeVariants = 2

    /// `attempts` are the card's item's whole history.
    static func asked(card: MemoryCard, state: MemoryCardState?, attempts: [MemoryAttempt]) -> Asked {
        let front = card.wording(state: state)
        let asFront = Asked(text: front, isVariant: false, isFirstVariedServe: false)
        guard let state, !state.alwaysAsk else { return asFront }
        let successes = attempts.reduce(0) { count, attempt in
            guard attempt.gradeState == .graded, let rating = attempt.scheduleRating, rating != .again else { return count }
            return count + 1
        }
        guard successes >= successesBeforeVariants else { return asFront }

        let retired = Set(state.retiredVariants.map(normalized))
            .union(MemoryCardVariation.retired(variants: state.variants, wording: front, attempts: attempts))
        var active: [String] = []
        for variant in state.variants.map(normalized) where !variant.isEmpty {
            guard variant != front, !retired.contains(variant), !active.contains(variant) else { continue }
            active.append(variant)
        }
        guard !active.isEmpty else { return asFront }

        let lastAsked = attempts
            .filter { !normalized($0.prompt).isEmpty }
            .max {
                if $0.attemptedAt != $1.attemptedAt { return $0.attemptedAt < $1.attemptedAt }
                return $0.id < $1.id
            }
            .map { normalized($0.prompt) }
        let next: String?
        if let lastAsked, let index = active.firstIndex(of: lastAsked) {
            let following = active[(index + 1) % active.count]
            next = following == lastAsked ? nil : following
        } else {
            next = active.first { $0 != lastAsked }
        }
        // The one variant there is was asked last: the front this time.
        guard let next else { return asFront }

        let everyVariant = Set(state.variants.map(normalized)).union(retired)
        let variedBefore = attempts.contains { everyVariant.contains(normalized($0.prompt)) }
        return Asked(
            text: next,
            isVariant: true,
            isFirstVariedServe: !variedBefore,
            variantIndex: state.variants.map(normalized).firstIndex(of: next)
        )
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One sitting of the card review: the cards dealt, where the learner is in
/// them, and what each answer asks storage to write. A value, so the order,
/// the rounds and "Review forgotten" are tested without a screen.
///
/// - The first deal is today's cards in the sitting's scope, in
///   `MemoryCardQueue.today`'s order, or, in learner-started practice, the
///   scope's new cards (`MemoryCardDeal`).
/// - Each card shows its wording; the learner's answer, typed or said, turns
///   it, and is checked by a model (`answerCheck`, docs/memory-design.md "The
///   answer is checked"), whose verdict suggests the grade. Show Answer turns
///   it with nothing typed, as a paper flashcard, and the learner grades
///   themselves (product owner, 2026-10-19: "i can't always type or speak
///   the answer"). Forgot or Remembered — the verdict's, or the learner's own
///   over it — moves on. An answer is for the record only the first time a card is
///   dealt in the sitting: **Review forgotten** deals the round's forgotten
///   cards again and writes nothing (storage would refuse the repeat anyway,
///   since the attempt's id is the sitting's key and the card's), and
///   **Continue** deals more of today's cards, which are recorded like the
///   first.
struct MemoryCardSitting: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        /// Today's review: due and eligible new cards.
        case today
        /// Learner-started practice of new cards, kept today included.
        case practice
    }

    struct Card: Equatable, Identifiable, Sendable {
        let itemID: String
        /// The wording asked (`MemoryCardWording`).
        private(set) var prompt: String
        /// The card's own wording — its front, or the learner's rewording —
        /// which a variant stands in for.
        let front: String
        /// The card's id, whose state row keeps its variants.
        let cardID: String
        /// The deck whose `cards.state.<deckID>` row that is.
        let deckID: String?
        let back: String
        let why: [String]
        let frontImages: [MemoryCardImage]
        let backImages: [MemoryCardImage]
        private(set) var isVariant: Bool
        private(set) var isFirstVariedServe: Bool
        /// A variant's place in its state row's `variants`.
        private(set) var variantIndex: Int?
        /// "Always ask it this way" is on: never a variant.
        private(set) var alwaysAsk: Bool
        /// The source the card is anchored on, for its chip; nil when the
        /// library no longer lists it.
        let sourceID: String?
        /// The passage the card quotes, which the Reader beside the review
        /// scrolls to.
        let quote: String?
        /// The other passages the card stands on, beside `quote` in `sourceID`
        /// (a kept card's later anchors): each is a source chip of its own.
        let alsoFrom: [CardSourceLink]
        let isNew: Bool
        /// A card to check that a notebook's Practice deals: not kept yet,
        /// and asked under the item Keep would make of it
        /// (`MemoryTutorIdentity.cardItemID`). Answering it keeps it and
        /// writes the answer as its first; Skip drops it for good, and Edit
        /// keeps it in the learner's words before it is answered. Nil for a
        /// kept card, and once the draft is answered.
        private(set) var draft: MemoryCardToCheck?

        var id: String { itemID }
        var isDraft: Bool { draft != nil }

        init(
            itemID: String,
            prompt: String,
            front: String? = nil,
            cardID: String? = nil,
            deckID: String? = nil,
            back: String,
            why: [String] = [],
            frontImages: [MemoryCardImage] = [],
            backImages: [MemoryCardImage] = [],
            isVariant: Bool = false,
            isFirstVariedServe: Bool = false,
            variantIndex: Int? = nil,
            alwaysAsk: Bool = false,
            sourceID: String? = nil,
            quote: String? = nil,
            alsoFrom: [CardSourceLink] = [],
            isNew: Bool = false,
            draft: MemoryCardToCheck? = nil
        ) {
            self.draft = draft
            self.itemID = itemID
            self.prompt = prompt
            self.front = front ?? prompt
            self.cardID = cardID ?? itemID
            self.deckID = deckID
            self.back = back
            self.why = why
            self.frontImages = frontImages
            self.backImages = backImages
            self.isVariant = isVariant
            self.isFirstVariedServe = isFirstVariedServe
            self.variantIndex = isVariant ? variantIndex : nil
            self.alwaysAsk = alwaysAsk
            self.sourceID = sourceID
            self.quote = quote
            self.alsoFrom = alsoFrom
            self.isNew = isNew
        }

        /// Every passage the card stands on, its own source's first.
        var links: [CardSourceLink] {
            guard let sourceID else { return alsoFrom }
            let own = quote.map { [CardSourceLink(sourceID: sourceID, quote: $0)] } ?? []
            return own + alsoFrom
        }

        /// The card asked in its own words again: after "This asks something
        /// else", and once "Always ask it this way" is on.
        mutating func askInOwnWords() {
            prompt = front
            isVariant = false
            isFirstVariedServe = false
            variantIndex = nil
        }

        mutating func setAlwaysAsk(_ on: Bool) {
            alwaysAsk = on
        }

        /// A draft answered: it is a kept card from here on, so a repeat
        /// round asks it as one.
        mutating func markKept() {
            draft = nil
        }

        /// A card to check as a notebook's Practice deals it: in its drafted
        /// words, under the item Keep makes of it.
        static func draft(_ card: MemoryCardToCheck) -> Card? {
            Card(
                itemID: MemoryTutorIdentity.cardItemID(cardID: card.cardID),
                prompt: card.face.front,
                cardID: card.cardID,
                deckID: card.deckID,
                back: card.face.back,
                why: card.face.why,
                frontImages: card.face.frontImages,
                backImages: card.face.backImages,
                sourceID: card.sourceID,
                quote: card.quote,
                alsoFrom: card.alsoFrom,
                draft: card
            )
        }

        /// The draft kept in the learner's words (Edit, then Keep) as
        /// `itemID`: a new kept card in `face`'s words, its answer still to
        /// give.
        func keptEdited(_ face: MemoryCard, as itemID: String, alsoFrom chosen: [CardSourceLink]? = nil) -> Card {
            Card(
                itemID: itemID,
                prompt: face.front,
                cardID: cardID,
                deckID: deckID,
                back: face.back,
                why: face.why,
                frontImages: face.frontImages,
                backImages: face.backImages,
                sourceID: sourceID,
                quote: quote,
                alsoFrom: chosen ?? alsoFrom,
                isNew: true
            )
        }

        /// A queue entry as a card: its face (`MemoryCard.face`), asked in the
        /// wording its state row and history give it, anchored on its first
        /// passage. Nil for an item with no face to show.
        static func dealt(
            _ entry: MemoryCardQueue.Entry,
            attempts: [MemoryAttempt],
            state: (MemoryCard) -> MemoryCardState?
        ) -> Card? {
            guard let face = MemoryCard.face(of: entry.item, attempts: attempts) else { return nil }
            let row = state(face)
            let asked = MemoryCardWording.asked(card: face, state: row, attempts: attempts)
            let anchors = entry.item.sources.sorted {
                if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
                return $0.id < $1.id
            }
            let anchor = anchors.first
            return Card(
                itemID: entry.item.id,
                prompt: asked.text,
                front: face.wording(state: row),
                cardID: face.cardID,
                deckID: face.stateDeckID(in: entry.item),
                back: face.back,
                why: face.why,
                frontImages: face.frontImages,
                backImages: face.backImages,
                isVariant: asked.isVariant,
                isFirstVariedServe: asked.isFirstVariedServe,
                variantIndex: asked.variantIndex,
                alwaysAsk: row?.alwaysAsk ?? false,
                sourceID: anchor?.sourceID,
                quote: anchor?.excerpt,
                alsoFrom: CardSourceLink.normalized(
                    anchors.dropFirst().map { CardSourceLink(sourceID: $0.sourceID, quote: $0.excerpt) },
                    excluding: anchor.map { CardSourceLink(sourceID: $0.sourceID, quote: $0.excerpt) }
                ),
                isNew: entry.isNew
            )
        }
    }

    /// Where the check of the answer on screen stands
    /// (`MemoryCardAnswerCheck`).
    enum AnswerCheck: Equatable, Sendable {
        /// Sent; the card shows a short wait.
        case checking
        /// The verdict and its line, which suggest the grade.
        case judged(MemoryCardAnswerCheck.Result)
        /// No verdict: no model is set up, or the call failed. The line says
        /// so, and the learner grades themselves; never a grade of the
        /// app's own (AGENTS.md, "AI failures surface").
        case failed(String)
    }

    /// What one answer asks storage to write
    /// (`recordSelfGradedMemoryCardAttempt`).
    struct Answer: Equatable, Sendable {
        let itemID: String
        let prompt: String
        let remembered: Bool
        let practice: Bool
        /// The card to check this answer keeps first, in a notebook's
        /// Practice: its item is made, then the answer is written on it.
        var keeping: MemoryCardToCheck? = nil
    }

    /// The sitting's key: every answer's attempt id is derived from it and
    /// the card (`MemoryTutorIdentity.selfGradedAttemptID`), so a card is
    /// written once per sitting whatever the screen does.
    let key: String
    let kind: Kind
    /// This round's cards: the first deal, a repeat of forgotten cards, or a
    /// further deal.
    private(set) var cards: [Card]
    /// Where the learner is in this round.
    private(set) var position = 0
    /// Whether the current card shows its back.
    private(set) var isAnswerShown = false
    /// What the learner answered the card on screen with, typed or said,
    /// shown over its back to grade themselves against. Nil until they
    /// answer, and when they turned it with Show Answer.
    private(set) var attempt: String?
    /// What the model made of the answer on the card on screen: nil until a
    /// check is begun (and for a review that checks nothing, or a card
    /// turned with Show Answer), then checking, then the verdict or why there
    /// is none.
    private(set) var answerCheck: AnswerCheck?
    /// Counts the answers checked in the sitting, so a verdict that comes
    /// back after its card moved on is dropped.
    private(set) var checkToken = 0
    /// Whether this round repeats cards already answered in the sitting.
    private(set) var isRepeat = false
    /// This round's answers by card.
    private(set) var results: [String: Bool] = [:]
    /// The cards answered for the record in this sitting.
    private(set) var recordedItemIDs: Set<String> = []
    /// The drafts this sitting skipped: dropped for good, never answered.
    private(set) var skippedItemIDs: Set<String> = []
    /// The kept cards deleted in this sitting (`removeCurrent`): out of the
    /// round, and never dealt again by it, unless Undo puts one back.
    private(set) var removedItemIDs: Set<String> = []
    /// Counts the rounds dealt, so Undo puts a card back only into the round
    /// it was deleted from.
    private(set) var roundNumber = 0
    /// Whether every card of the first deal has been answered: the sitting
    /// asked for nothing more than that, so leaving after it is not leaving
    /// early.
    private(set) var firstDealAnswered = false

    init(key: String, kind: Kind, cards: [Card]) {
        self.key = key
        self.kind = kind
        var seen = Set<String>()
        self.cards = cards.filter { seen.insert($0.itemID).inserted }
        self.firstDealAnswered = self.cards.isEmpty
    }

    /// A key for a new sitting: the day it is sat on, and a fresh token, so
    /// two sittings on one day are two keys.
    static func newKey(day: String, token: String = UUID().uuidString) -> String {
        "cards-\(day)-\(token.lowercased())"
    }

    var current: Card? { position < cards.count ? cards[position] : nil }
    var isRoundOver: Bool { position >= cards.count }
    /// "Card 3 of 18": the card on screen, counting from one.
    var cardNumber: Int { min(position + 1, cards.count) }
    var cardCount: Int { cards.count }
    /// How far through the round, 0 to 1, for the bar.
    var progress: Double { cards.isEmpty ? 1 : Double(position) / Double(cards.count) }
    var rememberedCount: Int { results.values.filter { $0 }.count }
    var forgottenCount: Int { results.values.filter { !$0 }.count }
    /// This round's drafts skipped.
    var skippedCount: Int { cards.filter { skippedItemIDs.contains($0.itemID) }.count }
    /// This round's forgotten cards, in the order they were dealt.
    var forgottenCards: [Card] { cards.filter { results[$0.itemID] == false } }

    /// The learner's answer, typed or said, turns the card on screen to its
    /// back. A blank answer turns nothing; Show Answer
    /// (`showAnswerUnanswered`) is the flip without one. True when the back
    /// now shows.
    @discardableResult
    mutating func showAnswer(attempt: String) -> Bool {
        let answered = attempt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current != nil, !isAnswerShown, !answered.isEmpty else { return false }
        self.attempt = answered
        isAnswerShown = true
        return true
    }

    /// Show Answer: the back shows with no answer over it and nothing to
    /// check, and the learner grades themselves, Forgot or Remembered.
    mutating func showAnswerUnanswered() {
        guard current != nil, !isAnswerShown else { return }
        isAnswerShown = true
    }

    /// The check of the answer on screen begins: what to send, and the token
    /// its verdict must come back with. Nil when there is nothing to check —
    /// no back shown, no answer (Show Answer), or a check already begun.
    mutating func beginAnswerCheck() -> (request: MemoryCardAnswerCheck.Request, token: Int, itemID: String)? {
        guard isAnswerShown, answerCheck == nil,
              let card = current, let attempt else { return nil }
        checkToken += 1
        answerCheck = .checking
        let request = MemoryCardAnswerCheck.Request(
            front: card.prompt,
            back: card.back,
            why: card.why,
            quote: card.quote,
            answer: attempt
        )
        return (request, checkToken, card.itemID)
    }

    /// The check's outcome, kept only while its card is still on screen
    /// waiting for it: one that comes back after the card was answered, or
    /// after another check began, is dropped.
    mutating func settleAnswerCheck(_ outcome: AnswerCheck, token: Int) {
        guard token == checkToken, isAnswerShown, answerCheck == .checking, outcome != .checking else { return }
        answerCheck = outcome
    }

    /// The grade the verdict suggests: Remembered for a right answer, Forgot
    /// for one partly right or wrong (`Verdict.remembers`). Nil while there
    /// is no verdict: checking, failed, or nothing checked.
    var verdictRemembers: Bool? {
        guard isAnswerShown, case .judged(let result) = answerCheck else { return nil }
        return result.verdict.remembers
    }

    /// The card on screen back to its question, nothing answered on it.
    private mutating func hideAnswer() {
        isAnswerShown = false
        attempt = nil
        answerCheck = nil
    }

    /// The card on screen asked in its own words, its answer hidden again:
    /// after "This asks something else" on a variant, or "Always ask it this
    /// way". Nothing is answered for it until the learner answers it so.
    mutating func askCurrentInOwnWords() {
        guard position < cards.count, cards[position].isVariant else { return }
        cards[position].askInOwnWords()
        hideAnswer()
    }

    /// "Always ask it this way" on the card on screen, or off again. On,
    /// a card asked in a variant is asked in its own words at once.
    mutating func setCurrentAlwaysAsk(_ on: Bool) {
        guard position < cards.count else { return }
        cards[position].setAlwaysAsk(on)
        if on { askCurrentInOwnWords() }
    }

    /// Records the learner's grade on the card on screen and moves on.
    /// Nothing before its back is shown. Returns what to write, or nil when
    /// nothing is: a repeat round, or a card this sitting already wrote. A
    /// draft answered is kept by the answer (`Answer.keeping`) and is a kept
    /// card from then on.
    @discardableResult
    mutating func answer(remembered: Bool) -> Answer? {
        guard isAnswerShown, let card = current else { return nil }
        results[card.itemID] = remembered
        let keeping = card.draft
        if keeping != nil { cards[position].markKept() }
        position += 1
        hideAnswer()
        if !isRepeat, position >= cards.count { firstDealAnswered = true }
        guard !isRepeat, recordedItemIDs.insert(card.itemID).inserted else { return nil }
        return Answer(
            itemID: card.itemID,
            prompt: card.prompt,
            remembered: remembered,
            practice: kind == .practice,
            keeping: keeping
        )
    }

    /// Skip (S) on a draft a notebook's Practice dealt: it is dropped for
    /// good, as in To Check, and the round moves on without an answer.
    /// Returns the draft to skip; nil for a kept card, or in a repeat round.
    @discardableResult
    mutating func skipCurrentDraft() -> MemoryCardToCheck? {
        guard !isRepeat, let card = current, let draft = card.draft else { return nil }
        skippedItemIDs.insert(card.itemID)
        position += 1
        hideAnswer()
        if position >= cards.count { firstDealAnswered = true }
        return draft
    }

    /// A kept card deleted from the review, for Undo to put back
    /// (`restore`).
    struct Removed: Equatable, Sendable {
        let card: Card
        let round: Int
        /// Whether the first deal counted as answered through before the
        /// delete: deleting the last card of it finishes it.
        let firstDealAnsweredBefore: Bool
    }

    /// Delete on the card on screen: it leaves the round, which moves on
    /// with nothing answered and one card fewer. A draft is skipped, not
    /// deleted, so nil for one; nil too when no card is on screen.
    @discardableResult
    mutating func removeCurrent() -> Removed? {
        guard let card = current, !card.isDraft else { return nil }
        let removed = Removed(card: card, round: roundNumber, firstDealAnsweredBefore: firstDealAnswered)
        cards.remove(at: position)
        results[card.itemID] = nil
        removedItemIDs.insert(card.itemID)
        hideAnswer()
        if !isRepeat, position >= cards.count { firstDealAnswered = true }
        return removed
    }

    /// Undo of a delete: the card comes back in front of the learner, its
    /// question to answer, in the round it left. False once that round is
    /// over and another dealt, or when the card is in the round again.
    @discardableResult
    mutating func restore(_ removed: Removed) -> Bool {
        let itemID = removed.card.itemID
        guard removed.round == roundNumber, removedItemIDs.contains(itemID),
              !cards.contains(where: { $0.itemID == itemID }) else { return false }
        removedItemIDs.remove(itemID)
        cards.insert(removed.card, at: min(position, cards.count))
        hideAnswer()
        if !isRepeat { firstDealAnswered = removed.firstDealAnsweredBefore }
        return true
    }

    /// Edit, then Keep, on a draft before it is answered: the card the
    /// learner kept takes the draft's place, its answer still to give.
    /// Nothing changes when no draft of the round is `itemID`.
    mutating func keepDraft(itemID: String, as kept: Card) {
        guard let index = cards.firstIndex(where: { $0.itemID == itemID && $0.isDraft }) else { return }
        cards[index] = kept
    }

    /// Deals this round's forgotten cards again, in the order they came.
    /// Nothing they answer is written. False when the round is not over or
    /// nothing was forgotten.
    @discardableResult
    mutating func reviewForgotten() -> Bool {
        let again = forgottenCards
        guard isRoundOver, !again.isEmpty else { return false }
        startRound(again, isRepeat: true)
        return true
    }

    /// Deals more of today's cards once a round is over: those this sitting
    /// has not dealt for the record yet, written like the first deal. False
    /// when there are none or the round is not over.
    @discardableResult
    mutating func dealMore(_ more: [Card]) -> Bool {
        guard isRoundOver else { return false }
        var seen = Set<String>()
        let fresh = more.filter {
            !recordedItemIDs.contains($0.itemID) && !removedItemIDs.contains($0.itemID)
                && seen.insert($0.itemID).inserted
        }
        guard !fresh.isEmpty else { return false }
        startRound(fresh, isRepeat: false)
        return true
    }

    private mutating func startRound(_ round: [Card], isRepeat: Bool) {
        cards = round
        position = 0
        hideAnswer()
        results = [:]
        self.isRepeat = isRepeat
        roundNumber += 1
    }
}

// MARK: - The Memory pane's numbers and lists

/// Where a scope's cards stand today: what the Memory pane's Review section
/// says, and — with the cards waiting in To Check — what the Memory row's
/// help and a notebook's Studio say.
struct MemoryCardDayCounts: Equatable, Sendable {
    let due: Int
    let new: Int
    /// New cards outside today's deal that practice would take.
    let practice: Int
    /// Cards waiting in To Check: drafts not yet kept or skipped
    /// (`MemoryCardTriage`).
    let toCheck: Int

    static let zero = MemoryCardDayCounts(due: 0, new: 0, practice: 0)

    init(due: Int, new: Int, practice: Int, toCheck: Int = 0) {
        self.due = due
        self.new = new
        self.practice = practice
        self.toCheck = toCheck
    }

    init(today: MemoryCardQueue.Today, practice: Int, toCheck: Int = 0) {
        self.init(due: today.dueCount, new: today.newCount, practice: practice, toCheck: toCheck)
    }

    var today: Int { due + new }

    /// Today's review alone, for the Review section: "6 due · 4 new", "6 due",
    /// "4 new"; nil when nothing is waiting today.
    var todayLine: String? {
        var parts: [String] = []
        if due > 0 { parts.append("\(due) due") }
        if new > 0 { parts.append("\(new) new") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Everything waiting: "6 due · 4 new · 9 to check", any part that is
    /// zero left out ("6 due · 9 to check", "9 to check"); nil when nothing
    /// waits at all.
    var line: String? {
        var parts: [String] = []
        if let todayLine { parts.append(todayLine) }
        if toCheck > 0 { parts.append("\(toCheck) to check") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A notebook's cards as its Studio's Cards row says them
/// (docs/notebooks-design.md, "Studio"): "42 kept · 6 due · 9 to check" —
/// every kept card on its sources (a team copy resolved to the learner's own
/// source, an item filed under the notebook or one of its Goals counted;
/// `MemoryCardScope`), the due ones among them that today's review in the
/// notebook asks (the Memory pane's "6 due" narrowed to it), and its cards to
/// check.
struct NotebookCardCounts: Equatable, Sendable {
    let kept: Int
    let due: Int
    let toCheck: Int

    init(kept: Int, due: Int, toCheck: Int) {
        self.kept = kept
        self.due = due
        self.toCheck = toCheck
    }

    /// No card kept and none to check: the Studio shows no Cards row.
    var isEmpty: Bool { kept == 0 && toCheck == 0 }

    /// "42 kept · 6 due · 9 to check", any part that is zero left out; nil
    /// when the notebook has no card at all.
    var line: String? {
        var parts: [String] = []
        if kept > 0 { parts.append("\(kept) kept") }
        if due > 0 { parts.append("\(due) due") }
        if toCheck > 0 { parts.append("\(toCheck) to check") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// One kept card as the Memory pane's All cards lists it.
struct MemoryCardListing: Equatable, Identifiable, Sendable {
    let itemID: String
    let face: MemoryCard
    /// The sources the card is anchored on, best first.
    let sourceIDs: [String]
    /// The passages the card is anchored on, best first: one per anchor, so a
    /// card that stands on several sources lists each with its passage.
    let links: [CardSourceLink]
    /// The item's goal: none for a card kept since cards, possibly a
    /// notebook for an item from before them.
    let goalID: String?
    let schedule: MemorySchedule

    var id: String { itemID }
    var isNew: Bool { schedule.isNew }

    init(itemID: String, face: MemoryCard, sourceIDs: [String], links: [CardSourceLink] = [], goalID: String? = nil, schedule: MemorySchedule) {
        self.itemID = itemID
        self.face = face
        self.sourceIDs = sourceIDs
        self.links = links
        self.goalID = goalID
        self.schedule = schedule
    }

    /// A kept item as a listing, with the face it shows (`MemoryCard.face`);
    /// nil for an item with none.
    init?(item: MemoryItem, attempts: [MemoryAttempt], calendar: Calendar = .current) {
        guard let face = MemoryCard.face(of: item, attempts: attempts) else { return nil }
        let anchors = item.sources.sorted {
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            return $0.id < $1.id
        }
        self.init(
            itemID: item.id,
            face: face,
            sourceIDs: anchors.map(\.sourceID),
            links: anchors.map { CardSourceLink(sourceID: $0.sourceID, quote: $0.excerpt) },
            goalID: item.goalID,
            schedule: MemoryTutorScheduler.schedule(item: item, attempts: attempts, calendar: calendar)
        )
    }

    func belongs(to scope: MemoryCardScope) -> Bool {
        scope.contains(anchorSourceIDs: sourceIDs, goalID: goalID)
    }
}

/// What the learner changed in a kept card's editor: a new front alone
/// rewords it; a new back, why or image list starts it over.
struct MemoryCardEdit: Equatable, Sendable {
    let front: String
    let back: String
    let why: [String]
    let frontImages: [MemoryCardImage]
    let backImages: [MemoryCardImage]
    /// The other sources a draft is kept on, as the learner left them; nil
    /// keeps the draft's own. Only a draft's Keep reads it: a kept card's
    /// anchors never change (`KnowledgeStore.startMemoryCardOver`).
    let alsoFrom: [CardSourceLink]?

    init(
        front: String,
        back: String,
        why: [String],
        frontImages: [MemoryCardImage] = [],
        backImages: [MemoryCardImage] = [],
        alsoFrom: [CardSourceLink]? = nil
    ) {
        self.front = front
        self.back = back
        self.why = why
        self.frontImages = frontImages
        self.backImages = backImages
        self.alsoFrom = alsoFrom
    }

    /// The same edit, kept on these other sources.
    func keptOn(_ alsoFrom: [CardSourceLink]) -> MemoryCardEdit {
        MemoryCardEdit(front: front, back: back, why: why, frontImages: frontImages, backImages: backImages, alsoFrom: alsoFrom)
    }
}

/// The All cards list: searched, and grouped by source or by notebook.
enum MemoryCardCatalog {
    enum Grouping: String, CaseIterable, Identifiable, Sendable {
        case source
        case notebook

        var id: String { rawValue }
        var title: String {
            switch self {
            case .source: return "By Source"
            case .notebook: return "By Notebook"
            }
        }
    }

    struct Group: Equatable, Identifiable, Sendable {
        /// The source or notebook id; `unfiledID` for cards in no notebook.
        let id: String
        let title: String
        let cards: [MemoryCardListing]
        /// By source, for a book's chapter: the book's title. The chapters
        /// of one book sit together under it, in chapter order.
        var book: String? = nil
    }

    /// The group of cards anchored on sources no notebook holds.
    static let unfiledID = "memory.cards.unfiled"

    /// Cards whose front (as asked, when the learner reworded it), back,
    /// why or source title holds every word of `query`, ignoring case and
    /// accents. An empty query keeps every card.
    static func search(
        _ cards: [MemoryCardListing],
        query: String,
        wording: (MemoryCardListing) -> String = { $0.face.front },
        sourceTitle: (String) -> String?
    ) -> [MemoryCardListing] {
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return cards }
        return cards.filter { card in
            let haystack = fold(
                ([wording(card), card.face.front, card.face.back] + card.face.why
                    + card.sourceIDs.compactMap(sourceTitle)).joined(separator: "\n")
            )
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// By source: one group per card's first anchor, titled by the source,
    /// in title order; a book's chapter is placed by its book's title (`book`),
    /// then by its own, so one book's chapters stay together in chapter order
    /// rather than interleaving with another book's "1)", "2)" (product owner,
    /// 2026-11-14: "it says by source, but clearly isn't"). By notebook: one group per notebook holding one of a
    /// card's sources (a card in two notebooks is listed in both), in the
    /// order `notebooks` gives, then the cards no notebook holds. Within a
    /// group, cards keep their order: oldest kept first.
    static func grouped(
        _ cards: [MemoryCardListing],
        by grouping: Grouping,
        sourceTitle: (String) -> String?,
        book: (String) -> String? = { _ in nil },
        notebooks: [(title: String, scope: MemoryCardScope)]
    ) -> [Group] {
        switch grouping {
        case .source:
            var order: [String] = []
            var bySource: [String: [MemoryCardListing]] = [:]
            for card in cards {
                let key = card.sourceIDs.first ?? unfiledID
                if bySource[key] == nil { order.append(key) }
                bySource[key, default: []].append(card)
            }
            return order
                .map { key in
                    Group(
                        id: key,
                        title: key == unfiledID ? "No source" : (sourceTitle(key) ?? "Source not in the library"),
                        cards: bySource[key] ?? [],
                        book: key == unfiledID ? nil : book(key)
                    )
                }
                .sorted {
                    let shelf = ($0.book ?? $0.title).localizedStandardCompare($1.book ?? $1.title)
                    if shelf != .orderedSame { return shelf == .orderedAscending }
                    let order = $0.title.localizedStandardCompare($1.title)
                    if order != .orderedSame { return order == .orderedAscending }
                    return $0.id < $1.id
                }
        case .notebook:
            var groups: [Group] = []
            var filed = Set<String>()
            for notebook in notebooks {
                let members = cards.filter { $0.belongs(to: notebook.scope) }
                guard !members.isEmpty else { continue }
                filed.formUnion(members.map(\.itemID))
                groups.append(Group(id: notebook.scope.notebookID, title: notebook.title, cards: members))
            }
            let unfiled = cards.filter { !filed.contains($0.itemID) }
            if !unfiled.isEmpty {
                groups.append(Group(id: unfiledID, title: "In no notebook", cards: unfiled))
            }
            return groups
        }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
