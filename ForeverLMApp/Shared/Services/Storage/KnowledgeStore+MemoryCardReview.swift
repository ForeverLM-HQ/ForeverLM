import Foundation

// MARK: - Memory as cards: what the card review and the Memory pane read
//
// docs/memory-design.md, "The card review (2026-10-01)" and "Cards to check".
// One read over the kept cards gives the Memory pane its numbers, its All
// cards list and its To Check, and a sitting its deal, across every notebook
// or narrowed to one (`MemoryCardScope`). Reading writes nothing.

/// Today's cards in a scope, the new cards practice would take, every kept
/// card in the scope, and the cards waiting to be gone through.
struct MemoryCardReviewSnapshot: Sendable {
    /// Today's cards, in the order they are asked (`MemoryCardDeal.today`).
    let today: MemoryCardQueue.Today
    /// The scope's new cards outside today's deal: kept today, or past the
    /// day's allowance (`MemoryCardDeal.practice`).
    let practice: [MemoryCardQueue.Entry]
    /// Every kept card in the scope with a face to show, oldest kept first.
    /// Empty when the read did not ask for them.
    let cards: [MemoryCardListing]
    /// The whole attempt history of each card in `today` and `practice`, by
    /// item id: what each one's wording is chosen from.
    let attemptsByItemID: [String: [MemoryAttempt]]
    /// The scope's cards to check, in the order To Check lists them
    /// (`MemoryCardTriage.toCheck`). Empty when the read did not ask for them.
    let toCheck: [MemoryCardToCheck]

    static let empty = MemoryCardReviewSnapshot(today: .empty, practice: [], cards: [], attemptsByItemID: [:], toCheck: [])

    var counts: MemoryCardDayCounts {
        MemoryCardDayCounts(today: today, practice: practice.count, toCheck: toCheck.count)
    }

    /// A notebook's Studio line, from a read narrowed to it with its
    /// listings and its cards to check: every kept card, the due ones today's
    /// review asks, and the cards to check.
    var notebookCounts: NotebookCardCounts {
        NotebookCardCounts(kept: cards.count, due: today.dueCount, toCheck: toCheck.count)
    }
}

/// What a notebook's Practice deals (`KnowledgeStore.memoryCardNotebookPractice`),
/// in its order: the kept cards whose answer is written (due, then new), its
/// undecided drafts in To Check's order, whose answer keeps them and counts
/// as their first, then the kept cards not due yet, shown and not written
/// (`MemoryCardDeal.notebookPractice`); and each kept card's whole attempt
/// history, which its wording is chosen from.
struct MemoryCardNotebookPractice: Sendable {
    let kept: MemoryCardDeal.NotebookPractice
    /// Drafts only: an item from before cards waiting in To Check is kept
    /// already, and dealt among the kept cards.
    let drafts: [MemoryCardToCheck]
    let attemptsByItemID: [String: [MemoryAttempt]]

    static let empty = MemoryCardNotebookPractice(
        kept: MemoryCardDeal.NotebookPractice(answerable: [], notDueYet: []),
        drafts: [],
        attemptsByItemID: [:]
    )
}

extension KnowledgeStore {
    /// The card review's read. Only items with a face are cards
    /// (`MemoryCard.face`): an item the review cannot show is neither dealt
    /// nor counted. `scope` narrows today's cards, practice, the list and the
    /// cards to check to one notebook's; the day's new-card allowance stays
    /// one across scopes.
    ///
    /// `drafts` are the sources' draft decks as storage read them (their
    /// bodies are files: `StorageService.loadCardDrafts`) and `deckState`
    /// reads one `cards.state.<deckID>` row, asked only for the decks the
    /// cards to check name; nil drafts reads no cards to check. A
    /// deck's cards are offered only while its source is in the library and
    /// on screen (active, not hidden with its collection, and screen record
    /// mode's), the rule an item's anchors are dealt by.
    func memoryCardReviewSnapshot(
        now: Date,
        budgetMinutes: Int?,
        newPerDay: Int,
        deadlines: [MemoryCardDeadline],
        scope: MemoryCardScope?,
        includesListings: Bool = true,
        toCheckFrom drafts: [MemoryCardDraftDeck]? = nil,
        deckState: (String) -> MemoryCardDeckState? = { _ in nil },
        calendar: Calendar = .current
    ) throws -> MemoryCardReviewSnapshot {
        let reviewable = try reviewableMemoryItems()
        let attemptsByItemID = Dictionary(grouping: reviewable.attempts, by: \.memoryItemID)
        let cards = reviewable.items.filter {
            MemoryCard.face(of: $0, attempts: attemptsByItemID[$0.id] ?? []) != nil
        }
        let today = MemoryCardDeal.today(
            items: cards,
            attempts: reviewable.attempts,
            now: now,
            budgetMinutes: budgetMinutes,
            newPerDay: newPerDay,
            deadlines: deadlines,
            scope: scope,
            calendar: calendar
        )
        let practice = MemoryCardDeal.practice(
            items: cards,
            attempts: reviewable.attempts,
            scope: scope,
            excluding: Set(today.entries.map(\.id)),
            calendar: calendar
        )
        let listings: [MemoryCardListing] = includesListings
            ? cards
                .filter { scope?.contains($0) ?? true }
                .sorted {
                    if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                    return $0.id < $1.id
                }
                .compactMap { MemoryCardListing(item: $0, attempts: attemptsByItemID[$0.id] ?? [], calendar: calendar) }
            : []
        var toCheck: [MemoryCardToCheck] = []
        if let drafts {
            toCheck = try memoryCardsToCheck(
                cards: cards,
                attemptsByItemID: attemptsByItemID,
                scope: scope,
                drafts: drafts,
                deckState: deckState,
                now: now
            )
        }
        let dealt = Set(today.entries.map(\.id)).union(practice.map(\.id))
        return MemoryCardReviewSnapshot(
            today: today,
            practice: practice,
            cards: listings,
            attemptsByItemID: attemptsByItemID.filter { dealt.contains($0.key) },
            toCheck: toCheck
        )
    }

    /// A notebook's Practice (docs/memory-design.md, "Practice for a
    /// notebook"): every kept card in `scope`, those whose answer is written
    /// apart from those not due yet (`MemoryCardDeal.notebookPractice`), and
    /// its undecided drafts in To Check's order. `drafts` and `deckState` are what the snapshot reads
    /// the cards to check from. Reading writes nothing.
    func memoryCardNotebookPractice(
        scope: MemoryCardScope,
        now: Date,
        toCheckFrom drafts: [MemoryCardDraftDeck],
        deckState: (String) -> MemoryCardDeckState?,
        calendar: Calendar = .current
    ) throws -> MemoryCardNotebookPractice {
        let reviewable = try reviewableMemoryItems()
        let attemptsByItemID = Dictionary(grouping: reviewable.attempts, by: \.memoryItemID)
        let cards = reviewable.items.filter {
            MemoryCard.face(of: $0, attempts: attemptsByItemID[$0.id] ?? []) != nil
        }
        let kept = MemoryCardDeal.notebookPractice(
            items: cards,
            attempts: reviewable.attempts,
            scope: scope,
            now: now,
            calendar: calendar
        )
        let toCheck = try memoryCardsToCheck(
            cards: cards,
            attemptsByItemID: attemptsByItemID,
            scope: scope,
            drafts: drafts,
            deckState: deckState,
            now: now
        )
        let dealt = Set(kept.all.map(\.id))
        return MemoryCardNotebookPractice(
            kept: kept,
            drafts: toCheck.filter { $0.kind == .draft },
            attemptsByItemID: attemptsByItemID.filter { dealt.contains($0.key) }
        )
    }

    /// The cards to check in `scope` (every notebook when nil), in To
    /// Check's order (`MemoryCardTriage.toCheck`): the drafts of the decks
    /// whose sources may be shown, and the items from before cards among
    /// `cards` (the items with a face, with their attempts).
    private func memoryCardsToCheck(
        cards: [MemoryItem],
        attemptsByItemID: [String: [MemoryAttempt]],
        scope: MemoryCardScope?,
        drafts: [MemoryCardDraftDeck],
        deckState: (String) -> MemoryCardDeckState?,
        now: Date
    ) throws -> [MemoryCardToCheck] {
        let available = try memoryCardDraftSourcesAvailable(Set(drafts.map(\.sourceID)))
        let decks = (screenRecordScope()?.scopedCardDrafts(drafts) ?? drafts).filter { deck in
            available.contains(deck.sourceID)
                && (scope?.contains(anchorSourceIDs: [deck.sourceID], goalID: nil) ?? true)
        }
        let legacy = cards.filter { item in
            MemoryCard(storedIn: item) == nil && (scope?.contains(item) ?? true)
        }
        var deckStates: [String: MemoryCardDeckState] = [:]
        for deckID in MemoryCardTriage.deckIDs(decks: decks, legacyItems: legacy) {
            if let row = deckState(deckID) { deckStates[deckID] = row }
        }
        return MemoryCardTriage.toCheck(
            decks: decks,
            deckStates: deckStates,
            itemIDs: Set(try loadAllMemoryItemIDs()),
            legacyItems: legacy,
            attemptsByItemID: attemptsByItemID,
            now: now
        )
    }

    /// Which of `sourceIDs` a draft deck's cards may be offered for: sources
    /// in the library (active, not hidden with their collection) and, in
    /// screen record mode, on screen — what an item's anchors must be for the
    /// item to be dealt (`reviewableMemoryItems`).
    func memoryCardDraftSourcesAvailable(_ sourceIDs: Set<String>) throws -> Set<String> {
        guard !sourceIDs.isEmpty,
              let shown = try screenRecordNarrowedMemorySourceIDs(sourceIDs), !shown.isEmpty else { return [] }
        let ids = Array(shown).sorted()
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var available = Set<String>()
        try queryBind("""
            SELECT id FROM source_projection
            WHERE status = 'active' AND is_collection_hidden = 0 AND id IN (\(placeholders))
        """, bind: { statement in
            for (index, id) in ids.enumerated() {
                self.bind(statement, index + 1, id)
            }
        }) { statement in
            if let id = self.string(statement, 0) { available.insert(id) }
        }
        return available
    }
}
