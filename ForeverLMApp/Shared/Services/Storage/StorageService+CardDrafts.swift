import Foundation
import OSLog

// MARK: - Memory as cards: the sources' draft decks
//
// docs/memory-design.md, "Cards to check". A drafted card waits in its
// source's deck until the learner keeps or skips it in To Check
// (`MemoryCardTriageWriter`). Under generation 2 (an activated store) the deck
// is the source's Cards: each draft a `Card` with status `draft`, its wording
// in its `draft`, synced to every device (`KnowledgeStore+CardRecords`). Under
// generation 1 it is a private Artifact of kind `.flashcards` under the fixed
// id `carddeck-<sourceID>`, no home Notebook, no Notebook links, no team,
// grounded on its source, its body the deck format (`FlashcardDeck`), only
// ever appended to. Nothing here spends: the cards come from an assistant
// (`save_card_drafts`) or from ForeverLM's own drafting.

/// What `saveCardDrafts` did with one source's drafts.
struct MemoryCardDraftsSaved: Equatable, Sendable {
    let sourceID: String
    let deckID: String
    /// The drafts added to the deck, as it holds them.
    var added: [Flashcard] = []
    /// Drafts the deck already holds — the same id, seed or front: drafted
    /// before, and kept or skipped since, so never offered twice.
    var alreadyDrafted: [Flashcard] = []
    /// Drafts whose quote the source's text does not print (or that quote
    /// nothing): not saved, since a card is kept only on a passage its source
    /// prints.
    var ungrounded: [Flashcard] = []
    /// Drafts the deck's Markdown would not give back whole: not saved rather
    /// than saved changed.
    var unreadable: [Flashcard] = []
    /// Passages of other sources a draft named that those sources' texts do not
    /// print (or whose source the library does not hold): the draft is saved
    /// without that link, and the caller is told which.
    var ungroundedLinks: [UngroundedLink] = []
    /// The id a saved draft was given by the caller, by the id it was saved
    /// under, where they differ: under generation 2 a seeded draft is saved as
    /// its source's Card for that seed (`card:<deckSourceID>:<seedKey>`).
    var givenIDs: [String: String] = [:]

    /// The id the caller gave `card`.
    func givenID(of card: Flashcard) -> String { givenIDs[card.id] ?? card.id }

    /// A link a draft named and its source does not support.
    struct UngroundedLink: Equatable, Sendable {
        let front: String
        let link: CardSourceLink
        let reason: String
    }
}

/// The other sources' passages the drafts of one deck name, checked against
/// each source's own text once per source: a link stands only on a passage its
/// source prints, as the card's own quote does. A team's copy of a source is
/// linked at the learner's own source at the same address, as `saveCardDrafts`
/// does for the deck's.
private struct CardDraftLinkSources {
    let deckSourceID: String
    private var grounding: [String: MemoryGroundingText?] = [:]
    /// The text hash of every source a kept link names (`sha256` of its text),
    /// which the draft Card's anchor records.
    private(set) var hashes: [String: String] = [:]
    private var resolved: [String: String?] = [:]

    init(deckSourceID: String) {
        self.deckSourceID = deckSourceID
    }

    /// `links` less those the library or their source's text does not support,
    /// each at its own source's id; the others go into `result`.
    mutating func grounded(
        _ links: [CardSourceLink],
        for card: Flashcard,
        store: KnowledgeStore,
        into result: inout MemoryCardDraftsSaved
    ) -> [CardSourceLink] {
        var kept: [CardSourceLink] = []
        for link in links {
            guard let ownID = ownSourceID(link.sourceID, store: store) else {
                result.ungroundedLinks.append(.init(front: card.front, link: link, reason: "The library holds no source \(link.sourceID)."))
                continue
            }
            guard let text = text(of: ownID, store: store) else {
                result.ungroundedLinks.append(.init(front: card.front, link: link, reason: "Source \(link.sourceID) has no text yet, so no card can stand on a passage of it."))
                continue
            }
            guard text.contains(link.quote) else {
                result.ungroundedLinks.append(.init(front: card.front, link: link, reason: "Source \(link.sourceID)'s text does not print this quote."))
                continue
            }
            kept.append(CardSourceLink(sourceID: ownID, quote: link.quote))
        }
        return CardSourceLink.normalized(
            kept,
            excluding: card.quote.map { CardSourceLink(sourceID: deckSourceID, quote: $0) }
        )
    }

    private mutating func ownSourceID(_ id: String, store: KnowledgeStore) -> String? {
        if let known = resolved[id] { return known }
        var own: String?
        if let source = try? store.loadSourceWithoutContent(id), source.status == .active {
            own = source.id
            if source.teamID != nil, let mine = store.activeSourceID(matchingAddress: source.url, teamID: nil) { own = mine }
        }
        resolved[id] = own
        return own
    }

    private mutating func text(of id: String, store: KnowledgeStore) -> MemoryGroundingText? {
        if let known = grounding[id] { return known }
        var loaded: MemoryGroundingText?
        if let content = try? store.loadSourceContent(id),
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            loaded = MemoryGroundingText(content)
            hashes[id] = PaperContentPreparationService.sha256(content)
        }
        grounding[id] = loaded
        return loaded
    }
}

extension StorageService {
    private static let cardDraftsLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
        category: "MemoryCards"
    )

    /// Adds drafted cards to `sourceID`'s draft deck: under generation 2 as
    /// draft Cards (`saveCardDraftRecords`), under generation 1 into the
    /// deck's Artifact, made the first time. Either is the learner's own
    /// record, private wherever the cards were asked for, so it never follows
    /// a notebook into a team. Each draft's
    /// quote is checked against the source's text (`MemoryGroundingText`, the
    /// matcher Keep grounds with); a draft the source does not print is
    /// returned in `ungrounded` and never saved. A draft is added only when
    /// its id, seed and front are new to the deck (`FlashcardDeck.appending`);
    /// nothing already in the deck changes. Nothing is written when nothing is
    /// added. Throws for a source the library does not hold, one with no
    /// text, and a deck whose body is still downloading from iCloud.
    ///
    /// The drafts' own `sourceID` is replaced by the deck's; their ids, seeds,
    /// times, origin and `isRequested` are kept as given (`Flashcard.mint`
    /// makes one). A team's copy of a source is drafted onto the learner's own
    /// source at the same address when they hold one, as a kept card is
    /// anchored (docs/teams-design.md, decision 19); `result.sourceID` names
    /// the source the deck is for.
    @discardableResult
    func saveCardDrafts(
        _ drafts: [Flashcard],
        sourceID requestedSourceID: String,
        sourceTitle: String
    ) throws -> MemoryCardDraftsSaved {
        let store = try notebookFilesKnowledgeStore()
        guard let requested = try store.loadSourceWithoutContent(requestedSourceID) else {
            throw KnowledgeStoreError.invalidData("Source \(requestedSourceID) is not in the library.")
        }
        var sourceID = requestedSourceID
        if requested.teamID != nil,
           let own = store.activeSourceID(matchingAddress: requested.url, teamID: nil) {
            sourceID = own
        }
        let deckID = MemoryCard.draftDeckID(sourceID: sourceID)
        var result = MemoryCardDraftsSaved(sourceID: sourceID, deckID: deckID)
        guard let content = try store.loadSourceContent(sourceID),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KnowledgeStoreError.invalidData("Source \(sourceID) has no text yet, so no card can stand on a passage of it.")
        }
        let grounding = MemoryGroundingText(content)
        var linkSources = CardDraftLinkSources(deckSourceID: sourceID)
        var grounded: [Flashcard] = []
        for draft in drafts {
            var card = draft
            card.sourceID = sourceID
            card.sourceTitle = sourceTitle
            card = card.asWritten
            guard let quote = card.quote, grounding.contains(quote) else {
                result.ungrounded.append(card)
                continue
            }
            card.alsoFrom = linkSources.grounded(card.alsoFrom, for: card, store: store, into: &result)
            grounded.append(card)
        }
        if try store.recordsMemoryForGeneration2() {
            try saveCardDraftRecords(
                grounded, sourceID: sourceID, content: content, linkHashes: linkSources.hashes,
                into: &result, store: store
            )
            return result
        }

        let existing = try store.loadArtifact(deckID)
        let current: FlashcardDeck
        let revision: String?
        if let existing {
            let snapshot = try artifactMarkdown(deckID)
            current = FlashcardDeck.parse(snapshot.markdown, fallbackTitle: existing.title)
            revision = snapshot.revision
        } else {
            current = FlashcardDeck(title: FlashcardDeck.title(forSourceTitle: sourceTitle))
            revision = nil
        }
        let appended = current.appending(grounded)
        result.added = appended.added
        result.alreadyDrafted = appended.alreadyDrafted
        result.unreadable = appended.unreadable
        guard !appended.added.isEmpty else { return result }

        if let revision {
            let written = try writeArtifactMarkdown(
                artifactID: deckID,
                markdown: appended.deck.markdown,
                expectedRevision: revision
            )
            try keepDeckPrivate(written.artifact, sourceID: sourceID, store: store)
        } else {
            _ = try createArtifact(
                title: appended.deck.title,
                homeNotebookID: nil,
                linkedNotebookIDs: [],
                markdown: appended.deck.markdown,
                teamID: nil,
                artifactID: deckID,
                sourceIDs: [sourceID],
                kind: .flashcards
            )
        }
        scheduleSoonCloudKitSyncForCardDrafts()
        return result
    }

    /// Generation 2's half of `saveCardDrafts`: the grounded drafts appended to the source's deck of
    /// Cards by the deck's rules (`FlashcardDeck.appending`: an id, seed or front the deck holds is drafted
    /// already), each new one saved as a draft Card. A seeded draft takes its seed's Card id,
    /// `card:<deckSourceID>:<seedKey>`, so two Macs drafting one seed make one Card; when a Card already
    /// has that id, the draft keeps the id it was minted with. A Card is never written over.
    private func saveCardDraftRecords(
        _ grounded: [Flashcard],
        sourceID: String,
        content: String,
        linkHashes: [String: String],
        into result: inout MemoryCardDraftsSaved,
        store: KnowledgeStore
    ) throws {
        let deck = try store.cardRecordDecks(sourceIDs: [sourceID]).first?.deck ?? FlashcardDeck(title: "")
        var givenIDs: [String: String] = [:]
        var named: [Flashcard] = []
        for card in grounded {
            guard let seed = card.seed else {
                named.append(card)
                continue
            }
            let id = SyncIdentity.cardDraftID(deckSourceID: sourceID, seedKey: seed)
            if try store.cardRecordExists(id) || named.contains(where: { $0.id == id }) {
                named.append(card)
                continue
            }
            givenIDs[id] = card.id
            named.append(Flashcard(
                id: id, front: card.front, back: card.back, why: card.why, sourceID: card.sourceID, sourceTitle: card.sourceTitle,
                quote: card.quote, seed: card.seed, ideaID: card.ideaID, draftedAt: card.draftedAt,
                origin: card.origin, isRequested: card.isRequested, frontImages: card.frontImages, backImages: card.backImages,
                alsoFrom: card.alsoFrom
            ))
        }
        let appended = deck.appending(named)
        result.added = appended.added
        result.alreadyDrafted = appended.alreadyDrafted
        result.unreadable = appended.unreadable
        result.givenIDs = givenIDs.filter { id, _ in appended.added.contains { $0.id == id } }
        guard !appended.added.isEmpty else { return }
        try store.saveCardDraftRecords(
            appended.added, deckSourceID: sourceID, textHash: PaperContentPreparationService.sha256(content), linkHashes: linkHashes
        )
        scheduleSoonCloudKitSyncForCardDrafts()
        MemoryCardStateStore.reload()
    }

    /// A deck record saved back — as a Doc, its kind dropped,
    /// perhaps filed under a Notebook — is put back to what a deck is: kind
    /// `.flashcards`, no home, no Notebook links, grounded on its source.
    private func keepDeckPrivate(_ record: ArtifactRecord, sourceID: String, store: KnowledgeStore) throws {
        guard record.kind != .flashcards || record.homeNotebookID != nil
                || !record.linkedNotebookIDs.isEmpty || record.sourceIDs != [sourceID] else { return }
        if record.homeNotebookID != nil || !record.linkedNotebookIDs.isEmpty {
            Self.cardDraftsLogger.notice("Took draft deck \(record.id, privacy: .public) out of the Notebooks an older build filed it under")
        }
        var repaired = record
        repaired.kind = .flashcards
        repaired.homeNotebookID = nil
        repaired.linkedNotebookIDs = []
        repaired.sourceIDs = [sourceID]
        repaired.updatedAt = Date()
        try store.saveArtifactRecord(repaired)
    }

    /// Every source's draft deck: under generation 2 its Cards
    /// (`KnowledgeStore.cardRecordDecks`); under generation 1 its Artifact,
    /// read and parsed, a deck whose body is not on this Mac yet (iCloud
    /// still downloading it) or cannot be read left out, and logged, until
    /// it can be.
    func loadCardDrafts() throws -> [MemoryCardDraftDeck] {
        try loadCardDrafts(forSourceIDs: nil)
    }

    /// The draft decks of `sourceIDs` alone, read and parsed, as
    /// `loadCardDrafts` reads every one: a notebook's Studio reads its own
    /// sources' decks for its Make Cards runs (`NotebookOutputs.cardRuns`)
    /// without parsing the library's. Nil reads every deck.
    func loadCardDrafts(forSourceIDs sourceIDs: Set<String>?) throws -> [MemoryCardDraftDeck] {
        if let sourceIDs, sourceIDs.isEmpty { return [] }
        let store = try notebookFilesKnowledgeStore()
        if try store.recordsMemoryForGeneration2() { return try store.cardRecordDecks(sourceIDs: sourceIDs) }
        var decks: [MemoryCardDraftDeck] = []
        for record in try store.loadArtifacts(listing: .cardDecksOnly) {
            guard let sourceID = MemoryCard.sourceID(fromDraftDeckID: record.id) ?? record.sourceIDs.first else { continue }
            if let sourceIDs, !sourceIDs.contains(sourceID) { continue }
            do {
                let snapshot = try artifactMarkdown(record.id)
                decks.append(MemoryCardDraftDeck(
                    deckID: record.id,
                    sourceID: sourceID,
                    deck: FlashcardDeck.parse(snapshot.markdown, fallbackTitle: record.title)
                ))
            } catch {
                Self.cardDraftsLogger.notice(
                    "Draft deck \(record.id, privacy: .public) is not readable yet: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return decks
    }
}

extension StorageService {
    /// How storage reads a deck's state for the card readers (To Check, drafting, Practice): under
    /// generation 2 every deck's from the Card rows, read once now, so a state another device wrote is
    /// what they read; under generation 1 a deck's `cards.state.<deckID>` row from `stateDefaults`.
    func cardDeckStates(stateDefaults: UserDefaults) throws -> (String) -> MemoryCardDeckState {
        let store = try notebookFilesKnowledgeStore()
        if try store.recordsMemoryForGeneration2() {
            let decks = try store.cardRecordStates()
            return { decks[$0] ?? MemoryCardDeckState() }
        }
        return { MemoryCardStateStore.preferenceRow(deckID: $0, defaults: stateDefaults) }
    }
}

// MARK: - The cards a chat saved

/// One card a chat saved, as the reply's cards draw it: its face and where it
/// stands now (docs/memory-design.md, "The cards in the chat").
struct ChatSavedCard: Equatable, Identifiable, Sendable {
    enum Standing: Equatable, Sendable {
        /// Waiting in To Check, as To Check offers it: what Keep decides.
        case toCheck(MemoryCardToCheck)
        case kept
        case skipped
        /// Neither kept nor skipped, and no longer offered: drafted more than
        /// 14 days ago, or a twin of a card gone through, or its source gone.
        case notOffered
    }

    let id: String
    let sourceID: String
    let face: MemoryCard
    /// The passage it quotes, which Show Passage opens.
    let quote: String?
    let standing: Standing

    var toCheck: MemoryCardToCheck? {
        if case .toCheck(let card) = standing { return card }
        return nil
    }
}

extension StorageService {
    /// The cards `cards` names, in its order, each with where it stands: one
    /// To Check would offer is `.toCheck` with the entry To Check holds (the
    /// same `MemoryCardTriage.toCheck` read over the named sources' decks);
    /// any other is kept or skipped by its deck's state, kept when its item
    /// exists, else no longer offered. A card no named deck holds is left
    /// out. Reading writes nothing.
    func chatSavedCards(
        _ cards: ChatSavedCards,
        stateDefaults: UserDefaults = .standard
    ) throws -> [ChatSavedCard] {
        let store = try notebookFilesKnowledgeStore()
        // The link names the sources the call saved on, but a card is also found by its own id: a link whose
        // source id no longer matches the deck (a source merged or re-keyed since) must not make a saved
        // draft read as gone.
        var deckSources = Set(cards.sourceIDs)
        if try store.recordsMemoryForGeneration2() {
            for id in cards.cardIDs {
                if let source = try store.cardRecordRows(cardID: id).first?.deckSource { deckSources.insert(source) }
            }
        }
        let loadedDecks = try loadCardDrafts(forSourceIDs: deckSources)
        let decks = store.screenRecordScope()?.scopedCardDrafts(loadedDecks) ?? loadedDecks
        let deckStates = try cardDeckStates(stateDefaults: stateDefaults)
        let available = try store.memoryCardDraftSourcesAvailable(Set(decks.map(\.sourceID)))
        let itemIDs = Set(try store.loadAllMemoryItemIDs())
        var states: [String: MemoryCardDeckState] = [:]
        for deck in decks { states[deck.deckID] = deckStates(deck.deckID) }
        let offered = MemoryCardTriage.toCheck(
            decks: decks.filter { available.contains($0.sourceID) },
            deckStates: states,
            itemIDs: itemIDs
        )
        let offeredByID: [String: MemoryCardToCheck] = Dictionary(
            offered.map { ($0.cardID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var found: [String: ChatSavedCard] = [:]
        for deck in decks {
            for card in deck.deck.cards where cards.cardIDs.contains(card.id) && found[card.id] == nil {
                let state = states[deck.deckID]?.cards[card.id]
                let standing: ChatSavedCard.Standing
                if let entry = offeredByID[card.id] {
                    standing = .toCheck(entry)
                } else if state?.status == .kept
                            || itemIDs.contains(card.id)
                            || itemIDs.contains(MemoryTutorIdentity.cardItemID(cardID: card.id)) {
                    standing = .kept
                } else if state?.status == .skipped {
                    standing = .skipped
                } else {
                    standing = .notOffered
                }
                found[card.id] = ChatSavedCard(
                    id: card.id,
                    sourceID: deck.sourceID,
                    face: MemoryCard(
                        cardID: card.id,
                        front: state?.editedFront ?? card.front,
                        back: card.back,
                        why: card.why.map { [$0] } ?? [],
                        origin: card.origin ?? .drafted,
                        deckID: deck.deckID,
                        frontImages: card.frontImages,
                        backImages: card.backImages
                    ),
                    quote: card.quote,
                    standing: standing
                )
            }
        }
        return cards.cardIDs.compactMap { found[$0] }
    }
}

// MARK: - Going through the cards to check

/// Writes what the learner decided in To Check, or what `triage_cards` was
/// asked: the Memory items first, through storage, then each deck's state
/// once, on the main actor (`MemoryCardStateStore.update`: the decided cards'
/// Card rows under generation 2, the `cards.state.<deckID>` row under
/// generation 1), so the state never says kept before the item exists; under
/// generation 2 it returns once the rows landed, so the caller's next read of
/// the cards sees them. A decision storage refuses is reported and leaves its
/// card to check.
///
/// - Keep a draft: its item is made once (`keepMemoryCard`), on its quote,
///   checked again against the source's text; the row marks it kept with its
///   seed. Edit, then Keep: the same, in the learner's words.
/// - Skip a draft: the row marks it skipped; its seed is never drafted again.
enum MemoryCardTriageWriter {
    @MainActor
    static func apply(
        _ decisions: [MemoryCardTriageDecision],
        storage: StorageService,
        defaults: UserDefaults = .standard,
        at now: Date = Date()
    ) async -> MemoryCardTriageResult {
        var result = MemoryCardTriageResult()
        var rowChanges: [String: [(inout MemoryCardDeckState) -> Void]] = [:]
        var deckOrder: [String] = []
        func change(_ deckID: String, _ body: @escaping (inout MemoryCardDeckState) -> Void) {
            if rowChanges[deckID] == nil { deckOrder.append(deckID) }
            rowChanges[deckID, default: []].append(body)
        }
        func fail(_ card: MemoryCardToCheck, _ reason: String) {
            result.failed.append(MemoryCardTriageResult.Failure(cardID: card.cardID, reason: reason))
        }

        var seen = Set<String>()
        for decision in decisions where seen.insert(decision.card.cardID).inserted {
            let card = decision.card
            switch decision.action {
            case .keep, .keepEdited:
                let face: MemoryCard?
                if case .keepEdited(let edit) = decision.action {
                    face = MemoryCardTriage.editedFace(card, edit)
                } else {
                    face = card.face
                }
                guard let face else {
                    fail(card, "A card needs a front and a back to be kept.")
                    continue
                }
                guard let quote = card.quote else {
                    fail(card, "This card quotes no passage of its source, so it cannot be kept.")
                    continue
                }
                var alsoFrom = card.alsoFrom
                if case .keepEdited(let edit) = decision.action, let chosen = edit.alsoFrom { alsoFrom = chosen }
                do {
                    let item = try await storage.keepMemoryCard(
                        face,
                        sourceID: card.sourceID,
                        quote: quote,
                        alsoFrom: alsoFrom,
                        ideaID: card.ideaID,
                        at: now
                    )
                    result.kept.append(MemoryCardTriageResult.Kept(cardID: card.cardID, memoryItemID: item.id))
                    let seed = card.seed
                    change(card.deckID) { $0.markKept(cardID: card.cardID, memoryItemID: item.id, seed: seed, at: now) }
                } catch {
                    fail(card, error.localizedDescription)
                }
            case .skip:
                result.skipped.append(card.cardID)
                let seed = card.seed
                change(card.deckID) { $0.markSkipped(cardID: card.cardID, seed: seed, at: now) }
            }
        }

        for deckID in deckOrder {
            let changes = rowChanges[deckID] ?? []
            MemoryCardStateStore.update(deckID: deckID, defaults: defaults) { row in
                for change in changes { change(&row) }
            }
        }
        await MemoryCardStateStore.settled(defaults: defaults)
        return result
    }
}

// MARK: - Changing a kept card

/// What a change to a kept card writes, shared by All Cards' editor and menu
/// and `update_card` (docs/memory-design.md, "Cards: identity and Keep"):
///
/// - a new front alone rewords the card in its deck's state (`editedFront`:
///   the Card's `front` variant under generation 2, the `cards.state.<deckID>`
///   row under generation 1); the item and its schedule are untouched, and the
///   front it was kept with clears the rewording;
/// - a new back or why starts it over: the item is retired with its answers
///   and a revision under a new card id is kept on the same passages, first
///   asked the day after (`KnowledgeStore.startMemoryCardOver`), then
///   recorded in the row (`MemoryCardDeckState.recordStartOver`).
///
/// "Always ask it this way" is `MemoryCardStateStore.setAlwaysAsk`, and
/// retiring is `StorageService.retireMemoryCard`. The rows are written on the
/// main actor, after the item, never while a lock is held.
enum MemoryCardEditWriter {
    /// The deck whose `cards.state.<deckID>` row holds a kept card's state:
    /// the deck it was kept from, else its anchor source's
    /// (`MemoryCard.stateDeckID`).
    static func stateDeckID(_ card: MemoryCardListing) -> String? {
        card.face.deckID ?? card.sourceIDs.first.map(MemoryCard.draftDeckID(sourceID:))
    }

    /// The card's own wording now: the learner's rewording, else its front.
    static func wording(_ card: MemoryCardListing, defaults: UserDefaults = .standard) -> String {
        let state = stateDeckID(card).flatMap {
            MemoryCardStateStore.state(cardID: card.face.cardID, deckID: $0, defaults: defaults)
        }
        return card.face.wording(state: state)
    }

    /// A new front alone: the card reworded in its row, its item and schedule
    /// untouched. False, with nothing written, when the front is empty or is
    /// the wording the card is asked in already.
    @MainActor
    @discardableResult
    static func reword(
        _ card: MemoryCardListing,
        front: String,
        defaults: UserDefaults = .standard,
        at now: Date = Date()
    ) -> Bool {
        let front = front.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !front.isEmpty, front != wording(card, defaults: defaults),
              let deckID = stateDeckID(card) else { return false }
        let face = card.face
        let reworded: String? = front == face.front ? nil : front
        MemoryCardStateStore.update(deckID: deckID, defaults: defaults) { row in
            var state = row.cards[face.cardID] ?? MemoryCardState(status: .kept, memoryItemID: card.itemID, updatedAt: now)
            state.status = .kept
            state.memoryItemID = card.itemID
            state.editedFront = reworded
            state.updatedAt = now
            row.cards[face.cardID] = state
        }
        return true
    }

    /// "Start this card over?": the card retired with its answers and its
    /// revision kept under a new card id, in `edit`'s words or, with none, as
    /// it is asked now. Returns the revision's card id and item.
    @MainActor
    static func startOver(
        _ card: MemoryCardListing,
        edit: MemoryCardEdit?,
        storage: StorageService,
        defaults: UserDefaults = .standard,
        at now: Date = Date()
    ) async throws -> (cardID: String, item: MemoryItem) {
        let face = card.face
        let revision = MemoryCard(
            cardID: UUID().uuidString,
            front: edit?.front ?? wording(card, defaults: defaults),
            back: edit?.back ?? face.back,
            why: edit?.why ?? face.why,
            origin: face.origin,
            deckID: face.deckID,
            frontImages: edit?.frontImages ?? face.frontImages,
            backImages: edit?.backImages ?? face.backImages
        )
        let item = try await storage.startMemoryCardOver(memoryItemID: card.itemID, as: revision, at: now)
        if let deckID = stateDeckID(card) {
            MemoryCardStateStore.update(deckID: deckID, defaults: defaults) { row in
                row.recordStartOver(from: face.cardID, to: revision.cardID, newMemoryItemID: item.id, at: now)
            }
        }
        await MemoryCardStateStore.settled(defaults: defaults)
        return (revision.cardID, item)
    }
}
