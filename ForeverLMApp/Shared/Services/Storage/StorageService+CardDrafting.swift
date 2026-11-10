import Foundation
import SQLite3

// MARK: - Memory cards: what drafting reads
//
// docs/memory-design.md, "Drafting". One source at a time, one hop each:
// its whole text, the seeds its deck and kept cards leave uncovered (its
// walkthrough's questions, its review guide's, the learner's highlights and
// notes, its ideas), the questions its cards already ask, the learner's
// decisions on its cards, which the drafter takes as exemplars, and its
// captioned figures, which a card may show. Nothing here
// writes; `CardDraftingService` plans and drafts from it.

/// One requested source as drafting reads it, or why it is left out.
enum CardDraftingLoad: Sendable {
    case source(CardDraftingSource)
    case skipped(CardDraftingSkip)
}

extension StorageService {
    /// Reads `requestedID` for drafting. A team's copy is read as the
    /// learner's own source at its address when they hold one, which is
    /// where its cards are drafted (`saveCardDrafts`). Left out, with the
    /// reason: a source not in the library, one kept from AI or archived, a
    /// spoken script ForeverLM wrote, and one with no text yet.
    ///
    /// - Parameters:
    ///   - decks: every source's draft deck, read once for the request
    ///     (`loadCardDrafts`).
    ///   - excludedSourceIDs: the knowledge boundary
    ///     (`knowledgeSearchExcludedSourceIDs(includeArchived: true)`).
    ///   - stateDefaults: where generation 1's `cards.state.<deckID>` rows
    ///     are read (`cardDeckStates`; generation 2 reads the Card rows).
    ///   - reach: what of the source drafting may use (`CardDraftingReach`):
    ///     whole, or — background drafting of a source the learner has not
    ///     finished — only its ideas within reach and the learner's
    ///     highlights; such a source with no seed left is left out.
    func cardDraftingSource(
        _ requestedID: String,
        decks: [MemoryCardDraftDeck],
        excludedSourceIDs: Set<String>,
        stateDefaults: UserDefaults = .standard,
        reach: CardDraftingReach = .whole
    ) async throws -> CardDraftingLoad {
        let store = try notebookFilesKnowledgeStore()
        guard let requested = try store.loadSourceWithoutContent(requestedID) else {
            return .skipped(CardDraftingSkip(sourceID: requestedID, title: requestedID, reason: "It is not in the library."))
        }
        var sourceID = requestedID
        var source = requested
        if requested.teamID != nil,
           let own = store.activeSourceID(matchingAddress: requested.url, teamID: nil),
           let ownSource = try store.loadSourceWithoutContent(own) {
            sourceID = own
            source = ownSource
        }
        guard source.status == .active else {
            return .skipped(CardDraftingSkip(sourceID: requestedID, title: requested.title, reason: "It is kept from AI or archived."))
        }
        guard !excludedSourceIDs.contains(sourceID), !excludedSourceIDs.contains(requestedID) else {
            return .skipped(CardDraftingSkip(sourceID: requestedID, title: requested.title, reason: "It is kept from AI or archived.", isKeptFromAI: true))
        }
        if TextToSpeechPreparationPolicy.isSpokenScript(url: source.url) {
            return .skipped(CardDraftingSkip(sourceID: requestedID, title: requested.title, reason: "It is a spoken script ForeverLM wrote."))
        }
        guard let stored = await loadSourceContent(sourceID),
              case let text = stored.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            let reason = source.isPaywalled ? "It is paywalled and has no text yet." : "It has no text yet."
            return .skipped(CardDraftingSkip(sourceID: requestedID, title: requested.title, reason: reason))
        }

        let deckID = MemoryCard.draftDeckID(sourceID: sourceID)
        let deck = decks.first { $0.deckID == deckID }
        let state = try cardDeckStates(stateDefaults: stateDefaults)(deckID)

        // What the source's cards already ask, and the seeds they came from:
        // the deck's drafts, kept, skipped or still to check, and every card
        // kept on the source — a walkthrough question missed, a course-quiz
        // answer, an item from before cards.
        let anchoredItemIDs = try store.memoryItemIDs(anchoredOn: sourceID)
        let deckCards = deck?.deck.cards ?? []
        var coveredKeys = Set(deckCards.compactMap(\.seed))
        for row in state.cards.values {
            if let seed = row.seed { coveredKeys.insert(seed) }
        }
        var coveredFronts: [String] = deckCards.map(\.front)
        for itemID in anchoredItemIDs {
            guard let item = try store.loadMemoryItem(itemID) else { continue }
            let attempts = try store.loadMemoryAttempts(memoryItemID: itemID)
            if let face = MemoryCard.face(of: item, attempts: attempts) {
                coveredFronts.append(face.front)
            }
        }
        for row in state.cards.values {
            if let edited = row.editedFront?.trimmingCharacters(in: .whitespacesAndNewlines), !edited.isEmpty {
                coveredFronts.append(edited)
            }
        }
        var seenFronts = Set<String>()
        coveredFronts = coveredFronts.filter { seenFronts.insert(Flashcard.normalizedFront($0)).inserted }

        // The seeds, in the order they are offered. Within reach, only what
        // the learner met: their highlights, and the ideas within reach; a
        // walkthrough's or a review guide's questions span the whole source.
        let grounding = MemoryGroundingText(stored)
        var seeds: [CardDraftingSeed] = []
        if reach.isWhole, let walkthrough = try store.loadPaperWalkthrough(sourceID) {
            seeds += CardDraftingSeed.walkSteps(of: walkthrough) { excerpts in
                excerpts.first { grounding.contains($0) }
            }
        }
        if reach.isWhole, let guide = try store.loadSourceReviewGuide(sourceID) {
            seeds += CardDraftingSeed.guideQuestions(in: guide.guide)
        }
        seeds += CardDraftingSeed.highlights(try store.sourceHighlights(sourceID: sourceID))
        let ideas = try store.loadSourceIdeas(sourceIDs: [sourceID])[sourceID] ?? []
        seeds += CardDraftingSeed.ideas(reach.isWhole ? ideas : reach.ideas(ideas) { idea in
            Self.position(of: idea, in: grounding)
        })
        seeds = CardDraftingSeed.uncovered(seeds, coveredKeys: coveredKeys, coveredFronts: seenFronts)
        if !reach.isWhole, seeds.isEmpty {
            return .skipped(CardDraftingSkip(
                sourceID: requestedID,
                title: requested.title,
                reason: "Nothing of it the learner has met is left to draft a card from."
            ))
        }

        let exemplars = try deck.map { deck in
            try Self.cardDraftingExemplars(deck: deck, state: state, store: store)
        } ?? []

        // The pictures a card may show: its captioned figures, read off the
        // file on this Mac, off the storage actor, as a course quiz reads a
        // reading's; for a lecture video, which has no such file, its slides,
        // as a course quiz lists a lecture's (product owner, 2026-10-19: "you
        // should be able to extract pictures from the sources in there
        // usually; like the paper; or youtube video").
        let byMoment = YouTubeTranscriptService.isYouTubeURL(source.url)
        let figures = await Task.detached(priority: .utility) { [sourceID, source, stored] in
            let read = CourseQuizGeneratorService.readingFigures(sourceID: sourceID, filePath: source.resolvedFileLocation, pages: nil)
            guard read.isEmpty else { return read }
            return CardDraftingPictures.slideFigures(
                CourseQuizPictures.slides(from: stored, sourceID: sourceID, byMoment: byMoment)
            )
        }.value

        return .source(CardDraftingSource(
            sourceID: sourceID,
            requestedID: requestedID,
            title: requested.title,
            sourceType: source.sourceType.rawValue,
            kindLabel: NotebookSourceKind.label(source.sourceType),
            text: text,
            seeds: seeds,
            coveredFronts: coveredFronts,
            exemplars: exemplars,
            isOpened: requested.isRead || requested.hasSavedReadingPosition
                || source.isRead || source.hasSavedReadingPosition,
            reach: reach,
            figures: figures
        ))
    }

    /// Where an idea's passage begins in its source's text, as a fraction of
    /// the text: its earliest anchor the text prints. Nil when it prints none.
    static func position(of idea: SourceIdea, in grounding: MemoryGroundingText) -> Double? {
        guard grounding.letterCount > 0 else { return nil }
        let first = idea.anchors.compactMap { grounding.offset(of: $0.quote) }.min()
        return first.map { Double($0) / Double(grounding.letterCount) }
    }

    /// The decided cards of a notebook's sources, as exemplars for drafting
    /// the cards of `except`: the same notebook's taste, after a source's
    /// own. A source kept from AI (`excludedSourceIDs`, the knowledge
    /// boundary) lends none: its cards are words of it. Nil `notebookID` reads
    /// none.
    func cardDraftingNotebookExemplars(
        notebookID: String?,
        decks: [MemoryCardDraftDeck],
        except: Set<String>,
        excludedSourceIDs: Set<String>,
        stateDefaults: UserDefaults = .standard
    ) throws -> [CardDraftingExemplar] {
        guard let notebookID else { return [] }
        let store = try notebookFilesKnowledgeStore()
        let membership = try store.notebookMembership(notebookID: notebookID)
        let scope = MemoryCardScope(membership: membership)
        let states = try cardDeckStates(stateDefaults: stateDefaults)
        var exemplars: [CardDraftingExemplar] = []
        for deck in decks where !except.contains(deck.sourceID)
            && !excludedSourceIDs.contains(deck.sourceID)
            && scope.contains(anchorSourceIDs: [deck.sourceID], goalID: nil) {
            exemplars += try Self.cardDraftingExemplars(deck: deck, state: states(deck.deckID), store: store)
        }
        return exemplars
    }

    /// One deck's decided cards, a kept card read with the face its Memory
    /// item holds (the learner's words when they edited it at Keep).
    /// Bounded: only the newest kept cards' items are read, as many as the
    /// drafter can show.
    private static func cardDraftingExemplars(
        deck: MemoryCardDraftDeck,
        state: MemoryCardDeckState,
        store: KnowledgeStore
    ) throws -> [CardDraftingExemplar] {
        let newestKept = state.cards
            .filter { $0.value.status == .kept && $0.value.memoryItemID != nil }
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .prefix(CardDraftingExemplars.editedLimit + CardDraftingExemplars.keptLimit)
        var faces: [String: MemoryCard] = [:]
        for (cardID, row) in newestKept {
            guard let itemID = row.memoryItemID, let item = try store.loadMemoryItem(itemID),
                  let face = MemoryCard(storedIn: item) else { continue }
            faces[cardID] = face
        }
        return CardDraftingExemplars.from(deck: deck, state: state) { cardID, _ in faces[cardID] }
    }

}

/// What background drafting decides on, read in one hop
/// (`StorageService.automaticCardDraftingState`).
struct AutomaticCardDraftingState: Sendable {
    /// The sources consumed inside the window that the learner finished or
    /// annotated, or that a wide chat discussed, each with what decides it (`AutomaticCardDrafting.exclusion`
    /// and `ranked` do the deciding).
    let candidates: [AutomaticCardDrafting.Candidate]
    /// Draft decks created today: the day's count against the limit.
    let decksCreatedToday: Int
}

extension StorageService {
    /// Background drafting's read (docs/memory-design.md, "Drafting in the
    /// background"): the cohort's candidates consumed within the last ten days
    /// (`cohortCandidates`, never the day close's watermark, so a source the
    /// day's limit leaves out is read again tomorrow), those the learner
    /// finished or annotated, outside the knowledge boundary, each with its
    /// ideas within reach, whether its source has a deck, and whether a
    /// notebook holding it is needed soon; and how many decks were created
    /// today. Writes nothing.
    ///
    /// - Parameter neededSoonSourceIDs: the sources of notebooks with a block
    ///   on today's calendar or an open Goal, which the window knows
    ///   (`StudioViewModel.automaticCardDraftingNeededSoonSourceIDs`).
    func automaticCardDraftingState(
        now: Date = Date(),
        neededSoonSourceIDs: Set<String> = [],
        calendar: Calendar = .current
    ) throws -> AutomaticCardDraftingState {
        let store = try notebookFilesKnowledgeStore()
        // A deck is made by its first draft: under generation 2 its source's first draft Card, under
        // generation 1 its Artifact.
        let deckSourceIDs: Set<String>
        let createdToday: Int
        if try store.recordsMemoryForGeneration2() {
            let firstDrafts = try store.cardRecordDeckFirstDrafts()
            deckSourceIDs = Set(firstDrafts.keys)
            createdToday = AutomaticCardDrafting.decksCreatedToday(Array(firstDrafts.values), now: now, calendar: calendar)
        } else {
            let decks = try store.loadArtifacts(listing: .cardDecksOnly)
            deckSourceIDs = Set(decks.compactMap { MemoryCard.sourceID(fromDraftDeckID: $0.id) ?? $0.sourceIDs.first })
            createdToday = AutomaticCardDrafting.decksCreatedToday(decks.map(\.createdAt), now: now, calendar: calendar)
        }
        let excluded = try store.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        let wideChatSourceIDs = AutomaticCardDrafting.wideChatSourceIDs(try store.chatDiscussions(now: now), now: now)
        let cohort = try store.cohortCandidates(now: now).filter { candidate in
            candidate.sourceType != ReviewableChat.sourceType
                && !excluded.contains(candidate.sourceID)
                && CohortSelector.days(from: candidate.consumedAt, to: now) <= AutomaticCardDrafting.windowDays
                && (candidate.isFinished || candidate.engagement.isAnnotated || wideChatSourceIDs.contains(candidate.sourceID))
        }
        guard !cohort.isEmpty else {
            return AutomaticCardDraftingState(candidates: [], decksCreatedToday: createdToday)
        }
        let ids = cohort.map(\.sourceID)
        let ideasBySource = try store.loadSourceIdeas(sourceIDs: ids)
        let documents = try store.loadUnderstandingDocuments(sourceIDs: ids)
        var candidates: [AutomaticCardDrafting.Candidate] = []
        for candidate in cohort {
            guard let source = try store.loadSourceWithoutContent(candidate.sourceID) else { continue }
            // A spoken script ForeverLM wrote is never drafted
            // (`cardDraftingSource`): not a candidate, rather than a failure
            // named every evening.
            if TextToSpeechPreparationPolicy.isSpokenScript(url: source.url) { continue }
            // A team's copy is drafted onto the learner's own source at its
            // address (`saveCardDrafts`), whose deck is the one that counts.
            var deckSourceID = candidate.sourceID
            if source.teamID != nil, let own = store.activeSourceID(matchingAddress: source.url, teamID: nil) {
                deckSourceID = own
            }
            let ideas = (ideasBySource[candidate.sourceID] ?? []).filter { $0.status == .active }
            let discussedIdeaIDs = documents[candidate.sourceID]?.discussedIdeaIDs ?? []
            // Neither finished nor annotated: here only because a wide chat
            // discussed it, so only what that discussion engaged is drafted.
            let onlyWideChat = !candidate.isFinished && !candidate.engagement.isAnnotated
            let reach = onlyWideChat
                ? CardDraftingReach.discussed(ideas: ideas, discussedIdeaIDs: discussedIdeaIDs)
                : CardDraftingReach.of(
                    isFinished: candidate.isFinished,
                    engagement: candidate.engagement,
                    confidence: candidate.confidence,
                    ideas: ideas,
                    discussedIdeaIDs: discussedIdeaIDs
                )
            let ideaCount = reach.ideaIDs.map { within in ideas.filter { within.contains($0.id) }.count } ?? ideas.count
            candidates.append(AutomaticCardDrafting.Candidate(
                sourceID: candidate.sourceID,
                deckSourceID: deckSourceID,
                title: candidate.title,
                consumedAt: candidate.consumedAt,
                isFinished: candidate.isFinished,
                engagement: candidate.engagement,
                confidence: candidate.confidence,
                ideaCount: ideaCount,
                hasDeck: deckSourceIDs.contains(deckSourceID) || deckSourceIDs.contains(candidate.sourceID),
                isNeededSoon: neededSoonSourceIDs.contains(candidate.sourceID) || neededSoonSourceIDs.contains(deckSourceID),
                reach: reach,
                isWideChatDiscussed: wideChatSourceIDs.contains(candidate.sourceID)
            ))
        }
        return AutomaticCardDraftingState(candidates: candidates, decksCreatedToday: createdToday)
    }
}

extension StorageService {
    /// The sources no card covers: the whole library's, and among them the
    /// ones added today or yesterday.
    struct UncoveredSources: Equatable, Sendable {
        /// Every source in the learner's library without a card: the
        /// learner's goal is at least one card for each (product owner,
        /// 2026-10-16), so the corner card counts the whole backlog.
        var all: Set<String> = []
        /// The part of `all` added today or yesterday, which the morning
        /// banner names (`CardsToCheckBanner`).
        var recent: Set<String> = []
    }

    /// The sources added to the learner's library today or yesterday that no
    /// card covers: the day's suggestion to make cards for everything that
    /// came in, finished or not (`CardsToCheckBanner`).
    func sourcesAddedWithoutCards(now: Date = Date(), calendar: Calendar = .current) throws -> Set<String> {
        try sourcesWithoutCards(now: now, calendar: calendar).recent
    }

    /// Covered means a draft deck on the source or any Memory item anchored
    /// on it. Left out: a team's copy, a source kept from AI or archived, a
    /// spoken script ForeverLM wrote, one still fetching or failed, a
    /// paywalled one, and one with no text.
    func sourcesWithoutCards(now: Date = Date(), calendar: Calendar = .current) throws -> UncoveredSources {
        var result = UncoveredSources()
        for row in try readSourceCardCoverage().withoutCards {
            result.all.insert(row.id)
            if CardsToCheckBanner.isRecentlyAdded(row.dateAdded, now: now, calendar: calendar) {
                result.recent.insert(row.id)
            }
        }
        return result
    }

    /// Every source in the library that can have cards and how many it has:
    /// the Memory pane's Sources section, which goes through all of them
    /// (product owner, 2026-10-16: "go through ALL the sources in my library
    /// and come up with at least one flashcard; and then the option to
    /// generate more"). One set-based read of the card anchors, not a query
    /// per source.
    func sourceCardCoverage() throws -> SourceCardCoverage {
        try readSourceCardCoverage()
    }

    /// The kept cards on one source, newest first: what its Library row's
    /// card count lists (`SourceCardsTrailer`). Only active items, as the
    /// count counts them (`activeMemoryItemCountsBySource`).
    func keptCards(onSource sourceID: String) throws -> [MemoryItem] {
        let store = try notebookFilesKnowledgeStore()
        return try store.memoryItemIDs(anchoredOn: sourceID)
            .compactMap { try store.loadMemoryItem($0) }
            .filter { $0.status == .active }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func readSourceCardCoverage() throws -> SourceCardCoverage {
        let store = try notebookFilesKnowledgeStore()
        let excluded = try store.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        let sources = try store.loadSourcesWithoutContent().filter {
            $0.teamID == nil && $0.status == .active && $0.state == .ready && !$0.hasPaywallMarker
                && ($0.wordCount.map { $0 > 0 } ?? true)
                && !TextToSpeechPreparationPolicy.isSpokenScript(url: $0.url)
                && !excluded.contains($0.id)
        }
        guard !sources.isEmpty else { return SourceCardCoverage() }
        let drafted: Set<String>
        if try store.recordsMemoryForGeneration2() {
            drafted = Set(try store.cardRecordDeckFirstDrafts().keys)
        } else {
            let decks = try store.loadArtifacts(listing: .cardDecksOnly)
            drafted = Set(decks.compactMap { MemoryCard.sourceID(fromDraftDeckID: $0.id) ?? $0.sourceIDs.first })
        }
        let anchored = try store.sourceIDsAnchoringMemoryItems()
        let kept = try store.activeMemoryItemCountsBySource()
        return SourceCardCoverage(rows: sources.map { source in
            SourceCardRow(
                id: source.id,
                title: source.title,
                sourceType: source.sourceType,
                dateAdded: source.dateAdded,
                state: SourceCardState(
                    keptCards: kept[source.id] ?? 0,
                    hasDrafts: drafted.contains(source.id),
                    isAnchored: anchored.contains(source.id)
                )
            )
        })
    }
}

extension KnowledgeStore {
    /// How many active Memory items each source anchors: one read for the
    /// whole library. A source with none is absent.
    func activeMemoryItemCountsBySource() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        try query("""
            SELECT mis.source_id, COUNT(DISTINCT mis.memory_item_id)
            FROM memory_item_sources mis
            JOIN memory_items mi ON mi.id = mis.memory_item_id
            WHERE mi.status = 'active'
            GROUP BY mis.source_id
        """) { statement in
            if let id = self.string(statement, 0) { counts[id] = Int(sqlite3_column_int64(statement, 1)) }
        }
        return counts
    }

    /// Every source that has a Memory item anchored on it, whatever the
    /// item's status: one read for the whole library.
    func sourceIDsAnchoringMemoryItems() throws -> Set<String> {
        var ids = Set<String>()
        try query("SELECT DISTINCT source_id FROM memory_item_sources") { statement in
            if let id = self.string(statement, 0) { ids.insert(id) }
        }
        return ids
    }

    /// The Memory items with an anchor on `sourceID`, whatever their status,
    /// by id.
    func memoryItemIDs(anchoredOn sourceID: String) throws -> [String] {
        var ids: [String] = []
        try queryBind("""
            SELECT DISTINCT memory_item_id FROM memory_item_sources
            WHERE source_id = ?
            ORDER BY memory_item_id
        """, bind: { statement in
            self.bind(statement, 1, sourceID)
        }) { statement in
            if let id = self.string(statement, 0) { ids.append(id) }
        }
        return ids
    }
}
