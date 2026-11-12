import Foundation

// MARK: - Memory as cards: the way into the card review
//
// docs/memory-design.md, "The card review (2026-10-01)". The product owner, the same
// day: keep the ability to "make flashcards and recall based off of all
// notebooks that I have worked on", while "at any given time I'm probably
// working in a notebook". So the review spans every notebook by default and
// can be narrowed to one: the Memory pane's scope control, and the scope its
// opener asks for — every notebook from the rail's Memory row, the daily
// reminder, the Today menu and Open in Other Window; one notebook from that
// notebook's Studio Cards row and its Cards tile's Open in Memory
// (`requestCardReview(scope:)`).
//
// None of them gives the window over: a window that empties itself on one
// click is startling (the product owner asked for the review to ask first).
// Each opens the Memory pane — inside a notebook window, the
// notebook's panes, which leaves the notebook as it was — and only
// the pane's Start Review or Practice gives the window to the review, as does
// a notebook's own Practice, which the learner picks from its Studio's Cards
// menu or row (`startNotebookPractice(notebookID:)`).

// `MemoryReviewScope`, which kept cards a card review deals, is in
// `Shared/Models/MemoryCardSitting.swift`, which the iPhone compiles too.

/// The Memory pane's three sections (`App/MemoryPane.swift`). The sources
/// with how many cards each has, and a verdict on each, are the Library's
/// rows and its No Cards pill (`StudioViewModel+SourceCards.swift`), not a
/// section here: one list of sources.
enum MemoryPaneSection: String, CaseIterable, Identifiable, Sendable {
    /// Today's cards, the promise, Start Review, and the history grid.
    case review
    /// The cards to check: drafts waiting to be kept or skipped
    /// (`MemoryCardTriage`).
    case toCheck
    /// Every kept card, searched and grouped.
    case allCards

    var id: String { rawValue }

    var title: String {
        switch self {
        case .review: return "Review"
        case .toCheck: return "To Check"
        case .allCards: return "All Cards"
        }
    }
}

extension StudioViewModel {

    // MARK: The way in

    /// The way into the card review over `scope`, in the window in scope:
    /// the Memory pane's Review section on that scope, whose Start Review
    /// gives the window to the review. Inside a window holding a notebook
    /// the pane opens among the notebook's panes and the notebook stays
    /// as it was, under the review too. The notebook's Studio Cards row and
    /// its Cards tile's Open in Memory ask for their notebook; every entry
    /// outside a notebook's own controls asks for every notebook. (A
    /// notebook's Practice, which the learner picks from those controls,
    /// deals at once: `startNotebookPractice(notebookID:)`.)
    func requestCardReview(scope: MemoryReviewScope) {
        openMemoryPane(scope: scope, section: .review)
    }

    /// The Memory pane over `scope`, in the window in scope (or
    /// `destinationWindowState`): a pane of the window, a notebook's window
    /// included, on `section` (nil keeps the one it shows).
    /// The rail's Memory row and Open in Other Window ask for every notebook:
    /// Memory spans them all by default (decisions v5, 3), and a notebook is
    /// one click away in the pane.
    func openMemoryPane(
        scope: MemoryReviewScope = .allNotebooks,
        section: MemoryPaneSection? = nil,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        let destination = destinationWindowState ?? activeWindowState
        // Guarded: an @Observable write notifies even when nothing changed.
        if destination.memoryPaneScope != scope { destination.memoryPaneScope = scope }
        if let section, destination.memoryPaneSection != section { destination.memoryPaneSection = section }
        activateCenterTab(.memory, in: destination)
    }

    /// The rail row's Open Beside: the Memory pane over every notebook,
    /// beside the visible pane (or in a notebook's panes).
    func openMemoryPaneBeside() {
        let destination = activeWindowState
        if destination.memoryPaneScope != .allNotebooks { destination.memoryPaneScope = .allNotebooks }
        openCenterTabBeside(.memory)
    }

    /// The scope `windowState`'s Memory pane shows: the one it was opened
    /// on, or every notebook once that notebook is gone from the library.
    func memoryPaneScope(in windowState: StudioWindowState) -> MemoryReviewScope {
        validMemoryReviewScope(windowState.memoryPaneScope)
    }

    /// `scope`, or every notebook when it names no notebook of the open
    /// library (an archived one still counts: its cards are still asked), or
    /// one screen record mode keeps off screen.
    func validMemoryReviewScope(_ scope: MemoryReviewScope) -> MemoryReviewScope {
        guard case .notebook(let id) = scope else { return scope }
        return allNotebooks.contains { $0.id == id } ? scope : .allNotebooks
    }

    /// What the scope control and the review's eyebrow call `scope`.
    func memoryReviewScopeTitle(_ scope: MemoryReviewScope) -> String {
        switch scope {
        case .allNotebooks:
            return "All notebooks"
        case .notebook(let id):
            let title = notebook(id: id)?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? "Notebook" : title
        }
    }

    /// `scope` as storage narrows by it: nil for every notebook; for one,
    /// the notebook as homing's one rule asks it (`NotebookMembership`): a
    /// card rides the sources it is anchored on, so it belongs to every
    /// notebook holding one of them, the open library's team copies resolved
    /// to the learner's own sources the cards are anchored on.
    func memoryCardScope(for scope: MemoryReviewScope) -> MemoryCardScope? {
        guard case .notebook(let id) = scope else { return nil }
        return MemoryCardScope(membership: memoryCardMembership(notebookID: id, goalParents: memoryGoalParents()))
    }

    /// Each of `notebooks` with its scope, for All Cards' By Notebook: the
    /// Goals read once for them all.
    func memoryCardScopes(for notebooks: [LearningGoalRecord]) -> [(title: String, scope: MemoryCardScope)] {
        let goalParents = memoryGoalParents()
        return notebooks.map { notebook in
            (
                title: notebook.title,
                scope: MemoryCardScope(membership: memoryCardMembership(notebookID: notebook.id, goalParents: goalParents))
            )
        }
    }

    /// Each Goal's Notebook, so an item filed under a Goal nested in a
    /// notebook is the notebook's.
    private func memoryGoalParents() -> [String: String] {
        var goalParents: [String: String] = [:]
        for goal in learningGoals {
            if let parent = goal.parentNotebookID { goalParents[goal.id] = parent }
        }
        return goalParents
    }

    /// The notebook `notebookID` as `NotebookMembership` asks it, from what
    /// the view model holds — its approved pool (and `extraSourceIDs`), every
    /// Goal's Notebook, and the open library's team copy aliases — as
    /// `KnowledgeStore.notebookMembership(notebookID:)` reads it from the store.
    private func memoryCardMembership(
        notebookID: String,
        extraSourceIDs: [String] = [],
        goalParents: [String: String]
    ) -> NotebookMembership {
        NotebookMembership(
            notebookID: notebookID,
            memberSourceIDs: (notebook(id: notebookID)?.approvedSourceIDs ?? []) + extraSourceIDs,
            goalParents: goalParents,
            sourceAliases: articlesStore.teamCopyAliases
        )
    }

    /// Notebooks needed within the queue's horizon, whose due and new cards
    /// come first (`MemoryCardQueue`): a Goal ending in a notebook, and a
    /// block of work on today's calendar that names its notebook. Tomorrow's
    /// blocks are not read yet; the Mac reads only today's calendar.
    func memoryCardDeadlines(now: Date = Date()) -> [MemoryCardDeadline] {
        let notebookIDs = Set(notebooks.map(\.id))
        let goalParents = memoryGoalParents()
        func deadline(notebookID: String, at: Date, extraSourceIDs: [String] = []) -> MemoryCardDeadline? {
            guard notebookIDs.contains(notebookID) else { return nil }
            let scope = MemoryCardScope(
                membership: memoryCardMembership(notebookID: notebookID, extraSourceIDs: extraSourceIDs, goalParents: goalParents)
            )
            return MemoryCardDeadline(notebookID: notebookID, at: at, sourceIDs: scope.sourceIDs)
        }
        var deadlines: [MemoryCardDeadline] = []
        for goal in learningGoals where goal.isNotebookGoal && goal.lifecycleStatus == .active {
            guard goal.endAt >= now, goal.endAt.timeIntervalSince(now) <= MemoryCardQueue.deadlineHorizon,
                  let parent = goal.parentNotebookID,
                  let found = deadline(notebookID: parent, at: goal.endAt, extraSourceIDs: goal.approvedSourceIDs)
            else { continue }
            deadlines.append(found)
        }
        for event in DayModel.shared.todayEvents where event.holdsTime && event.start >= now {
            guard let notebookID = event.notebookID,
                  let found = deadline(notebookID: notebookID, at: event.start) else { continue }
            deadlines.append(found)
        }
        return deadlines
    }

    /// The Memory pane's read of `scope`: today's cards, the practice cards,
    /// the kept cards and — with `includesToCheck` — the cards to check, off
    /// the main actor. A sitting deals kept cards only and leaves the decks
    /// unread.
    func memoryCardReviewSnapshot(
        scope: MemoryReviewScope,
        includesListings: Bool,
        includesToCheck: Bool = true,
        now: Date = Date()
    ) async throws -> MemoryCardReviewSnapshot {
        try await storage.memoryCardReviewSnapshot(
            now: now,
            budgetMinutes: MemoryReviewBudget.minutes,
            newPerDay: MemoryCardSettings.newCardsPerDay(),
            deadlines: memoryCardDeadlines(now: now),
            scope: memoryCardScope(for: scope),
            includesListings: includesListings,
            includesToCheck: includesToCheck
        )
    }

    // MARK: Starting a review

    /// The Memory pane's Start Review: the card review over `scope`, in the
    /// window-filling memory focus of the window in scope — today's cards
    /// there, or, when today holds none there, the scope's new cards as
    /// practice the learner started (a card kept today included, which the
    /// daily review would leave for tomorrow). Nothing starts on a day whose
    /// review was ended early.
    ///
    /// A review chat made for today — on the other Mac or by the phone —
    /// in the topic review's shape is never resumed: no entry reaches that
    /// shape. It stays readable from the history grid.
    func startCardReview(scope: MemoryReviewScope) {
        startCardSitting(scope: scope, kind: nil, commitment: MemoryReviewEngagementTracker.shared.state)
    }

    /// The Memory pane's Practice N New Cards: learner-started practice of
    /// `scope`'s new cards that today's review leaves out — kept today, or
    /// past the day's allowance.
    func startCardPractice(scope: MemoryReviewScope) {
        startCardSitting(scope: scope, kind: .practice, commitment: MemoryReviewEngagementTracker.shared.state)
    }

    /// A notebook's Practice, from its Studio's Cards tile and Cards row and
    /// the Notebook menu's Make ▸ Practice Cards (docs/memory-design.md,
    /// "Practice for a notebook"): every kept card of the notebook and its
    /// undecided drafts, in the window-filling focus of the window in scope —
    /// the cards whose answers count first (due, new, then the drafts), the
    /// kept cards not due yet last.
    /// The learner asked for it, so it makes no commitment and is exempt
    /// from "not on the day of consumption"; storage writes an answer only
    /// for a card due or new (`MemoryCardQueue.answerCounts` with
    /// `practice`), so practice never stretches an interval, and answering a
    /// draft keeps it first. Nothing starts when the notebook has no card.
    /// Returns the work, for a caller that must see it finish; nil when
    /// nothing starts.
    @discardableResult
    func startNotebookPractice(notebookID: String) -> Task<Void, Never>? {
        let window = activeWindowState
        let scope = MemoryReviewScope.notebook(notebookID)
        guard let cardScope = memoryCardScope(for: scope),
              window.memoryCardSession == nil, !startingCardSittingWindowIDs.contains(window.id) else { return nil }
        startingCardSittingWindowIDs.insert(window.id)
        let title = memoryReviewScopeTitle(scope)
        let now = Date()
        return Task { [weak self] in
            guard let self else { return }
            defer { self.startingCardSittingWindowIDs.remove(window.id) }
            do {
                let deal = try await self.storage.memoryCardNotebookPractice(scope: cardScope, now: now)
                // The cards whose answers count first — due, new, then the
                // drafts, whose answer keeps them — and the kept cards not
                // due yet, practice only, last.
                let cards = self.memorySittingCards(deal.kept.answerable, attemptsByItemID: deal.attemptsByItemID)
                    + deal.drafts.compactMap(MemoryCardSitting.Card.draft)
                    + self.memorySittingCards(deal.kept.notDueYet, attemptsByItemID: deal.attemptsByItemID)
                guard !cards.isEmpty else {
                    self.showToast("No cards in \(title) to practice yet.")
                    return
                }
                let sitting = MemoryCardSitting(
                    key: MemoryCardSitting.newKey(day: MemoryReviewGoal.dayKey(for: now)),
                    kind: .practice,
                    cards: cards
                )
                let session = MemoryCardSessionModel(
                    sitting: sitting,
                    scope: scope,
                    scopeTitle: title,
                    isCommitted: false,
                    sourceTitles: self.memorySourceTitles(for: cards),
                    storage: self.storage,
                    // Practice deals the notebook whole and nothing after it.
                    followup: { MemoryCardSessionModel.Followup(cards: [], dayHasCardsLeft: true) },
                    deeper: self.memoryCardDeeperSteps(),
                    answerCheck: self.memoryCardAnswerCheck()
                )
                self.enterMemoryCardFocus(session, in: window)
            } catch {
                self.errorMessage = "The notebook's cards could not be read. \(error.localizedDescription)"
            }
        }
    }

    /// What `startChosenCardPractice` dealt.
    struct ChosenCardPracticeStart: Sendable {
        /// The due and new cards, whose answers count.
        let answerable: Int
        /// The cards not due yet, whose answers are shown and not written.
        let notDueYet: Int
        /// The ids no kept card answers to, in the order they were asked for.
        let unknownCardIDs: [String]
    }

    /// Why `startChosenCardPractice` started nothing, in words a chat can
    /// pass on.
    struct ChosenCardPracticeRefusal: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Practice of the kept cards a chat chose (`practice_cards`): some of
    /// the cards, chosen by what they ask rather than by notebook, which the
    /// Memory pane's notebook menu never could (product owner, 2026-10-13:
    /// "should be able via chat to be like 'please show me flashcards but
    /// only for mitochondria related topics'"). Dealt as
    /// a notebook's Practice is (`MemoryCardDeal.chosenPractice`), in the
    /// window-filling focus of the window in scope. The learner asked for
    /// it, so it makes no commitment, and storage writes an answer only for
    /// a card due or new. `title` says what the cards are about, for a card
    /// whose source the library no longer names. Refused while that window
    /// holds a card review, or when no id names a kept card.
    func startChosenCardPractice(cardIDs: [String], title: String) async throws -> ChosenCardPracticeStart {
        let window = activeWindowState
        guard window.memoryCardSession == nil, !startingCardSittingWindowIDs.contains(window.id) else {
            throw ChosenCardPracticeRefusal(message: "A card review already has the learner's window. It starts once that one is done.")
        }
        startingCardSittingWindowIDs.insert(window.id)
        defer { startingCardSittingWindowIDs.remove(window.id) }
        let now = Date()
        let deal = try await storage.memoryCardChosenPractice(cardIDs: cardIDs, now: now)
        let cards = memorySittingCards(deal.kept.answerable, attemptsByItemID: deal.attemptsByItemID)
            + memorySittingCards(deal.kept.notDueYet, attemptsByItemID: deal.attemptsByItemID)
        guard !cards.isEmpty else {
            throw ChosenCardPracticeRefusal(
                message: "None of these ids names a kept card the review can ask. Pass card_id values list_cards status kept returned; a card still to check is kept first."
            )
        }
        // The window may have started a review of its own while the cards
        // were read.
        guard window.memoryCardSession == nil else {
            throw ChosenCardPracticeRefusal(message: "A card review already has the learner's window. It starts once that one is done.")
        }
        let sitting = MemoryCardSitting(
            key: MemoryCardSitting.newKey(day: MemoryReviewGoal.dayKey(for: now)),
            kind: .practice,
            cards: cards
        )
        let session = MemoryCardSessionModel(
            sitting: sitting,
            scope: .allNotebooks,
            scopeTitle: title,
            isCommitted: false,
            sourceTitles: memorySourceTitles(for: cards),
            storage: storage,
            // The chosen cards are the whole deal: nothing follows them.
            followup: { MemoryCardSessionModel.Followup(cards: [], dayHasCardsLeft: true) },
            deeper: memoryCardDeeperSteps(),
            answerCheck: memoryCardAnswerCheck()
        )
        enterMemoryCardFocus(session, in: window)
        return ChosenCardPracticeStart(
            answerable: deal.kept.answerable.count,
            notDueYet: deal.kept.notDueYet.count,
            unknownCardIDs: deal.unknownCardIDs
        )
    }

    /// The sitting behind both: read the scope's cards off the main actor,
    /// then give the window to the review. `kind` nil is today's cards, or
    /// practice when today holds none in the scope. `commitment` is where
    /// today's review stands (the tracker's state; a test names its own):
    /// only today's review on a day still open makes the commitment. Returns
    /// the work, for a caller that must see it finish; nil when nothing
    /// starts.
    @discardableResult
    func startCardSitting(
        scope: MemoryReviewScope,
        kind requested: MemoryCardSitting.Kind?,
        commitment state: MemoryReviewCommitment.State
    ) -> Task<Void, Never>? {
        let window = activeWindowState
        guard window.memoryCardSession == nil, !startingCardSittingWindowIDs.contains(window.id) else { return nil }
        startingCardSittingWindowIDs.insert(window.id)
        let title = memoryReviewScopeTitle(scope)
        let now = Date()
        return Task { [weak self] in
            guard let self else { return }
            defer { self.startingCardSittingWindowIDs.remove(window.id) }
            do {
                let snapshot = try await self.memoryCardReviewSnapshot(
                    scope: scope, includesListings: false, includesToCheck: false, now: now
                )
                let kind = requested ?? (snapshot.today.entries.isEmpty ? .practice : .today)
                let entries = kind == .today ? snapshot.today.entries : snapshot.practice
                let cards = self.memorySittingCards(entries, attemptsByItemID: snapshot.attemptsByItemID)
                guard !cards.isEmpty else {
                    self.showToast(scope == .allNotebooks ? "No cards to review yet." : "No cards in \(title) to review yet.")
                    return
                }
                let sitting = MemoryCardSitting(
                    key: MemoryCardSitting.newKey(day: MemoryReviewGoal.dayKey(for: now)),
                    kind: kind,
                    cards: cards
                )
                // Today's review on a day still open is the commitment;
                // practice, and a day already done, are not.
                let isCommitted = kind == .today && state == .open
                let session = MemoryCardSessionModel(
                    sitting: sitting,
                    scope: scope,
                    scopeTitle: title,
                    isCommitted: isCommitted,
                    sourceTitles: self.memorySourceTitles(for: cards),
                    storage: self.storage,
                    followup: { [weak self] in
                        // Practice deals what today's review leaves out and
                        // nothing after it: today's cards are Start Review's,
                        // and only practice's own cards are answered as
                        // practice.
                        guard kind == .today, let self else {
                            return MemoryCardSessionModel.Followup(cards: [], dayHasCardsLeft: true)
                        }
                        return try await self.memoryCardFollowup(scope: scope)
                    },
                    firstDealAnswered: { dayHasCardsLeft in
                        StudioViewModel.cardReviewAnsweredFirstDeal(isCommitted: isCommitted, dayHasCardsLeft: dayHasCardsLeft)
                    },
                    deeper: self.memoryCardDeeperSteps(),
                    answerCheck: self.memoryCardAnswerCheck()
                )
                self.enterMemoryCardFocus(session, in: window)
            } catch {
                self.errorMessage = "Today's cards could not be read. \(error.localizedDescription)"
            }
        }
    }

    /// Go Deeper's steps for a card review (docs/memory-design.md, "Go Deeper
    /// on a card"): the analogy's partner from the source index, off the main
    /// actor (`StorageService.understandingAnalogyPartner`), and the question
    /// and the reply on the Go Deeper task's route, resolved at each press so
    /// a model picked mid-review is the one asked. A partner that cannot be
    /// read only leaves the analogy out; a model that is not set up, or that
    /// fails, is said under the panel.
    func memoryCardDeeperSteps() -> MemoryCardSessionModel.DeeperSteps {
        let storage = storage
        let ai = aiService
        let logger = logger
        func config() throws -> AITaskConfig {
            KeychainService.seedGoDeeperRoute()
            guard let config = KeychainService.resolveConfig(for: .cardGoDeeper, explicitlyAuthorizedBackgroundUsage: true) else {
                throw GoDeeperUnavailable(
                    message: KeychainService.backgroundAIUnavailableMessage(for: .cardGoDeeper)
                        ?? "No model is set up for Go Deeper. Sign in and check Settings › AI Models."
                )
            }
            return config
        }
        return MemoryCardSessionModel.DeeperSteps(
            partner: { sourceID in
                do {
                    return try await storage.understandingAnalogyPartner(nearSourceIDs: [sourceID])
                } catch {
                    logger.error("Go Deeper's analogy partner could not be read: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            },
            question: { request, cardID in
                try await ai.goDeeperQuestion(request, cardID: cardID, config: try config())
            },
            reply: { request, cardID in
                try await ai.goDeeperReply(request, cardID: cardID, config: try config())
            }
        )
    }

    /// Check's step for a card review (docs/memory-design.md, "The answer is
    /// checked"): the Card Answer Check task's route, resolved at each check
    /// so a model picked mid-review is the one asked. The learner pressed
    /// Check, so the background-usage consent is not asked again. No model
    /// set up is said on the card, and the learner grades themselves.
    func memoryCardAnswerCheck() -> MemoryCardSessionModel.AnswerCheckStep {
        let ai = aiService
        return { request, cardID, sourceTitle in
            KeychainService.seedCardAnswerCheckRoute()
            guard let config = KeychainService.resolveConfig(for: .cardAnswerCheck, explicitlyAuthorizedBackgroundUsage: true) else {
                throw CardAnswerCheckUnavailable(
                    message: KeychainService.backgroundAIUnavailableMessage(for: .cardAnswerCheck)
                        ?? "No model is set up for Card Answer Check. Sign in and check Settings › AI Models."
                )
            }
            return try await ai.checkCardAnswer(request, cardID: cardID, sourceTitle: sourceTitle, config: config)
        }
    }

    /// Check with no model to ask: said on the card in the words Settings
    /// would use.
    struct CardAnswerCheckUnavailable: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Queue entries as the sitting's cards: each card's face in the wording
    /// its state row and history give it. An entry with no face is dropped.
    func memorySittingCards(
        _ entries: [MemoryCardQueue.Entry],
        attemptsByItemID: [String: [MemoryAttempt]]
    ) -> [MemoryCardSitting.Card] {
        entries.compactMap { entry in
            MemoryCardSitting.Card.dealt(entry, attempts: attemptsByItemID[entry.id] ?? []) { face in
                face.stateDeckID(in: entry.item).flatMap {
                    MemoryCardStateStore.state(cardID: face.cardID, deckID: $0)
                }
            }
        }
    }

    private func memorySourceTitles(for cards: [MemoryCardSitting.Card]) -> [String: String] {
        var titles: [String: String] = [:]
        for sourceID in cards.flatMap({ card in (card.sourceID.map { [$0] } ?? []) + card.alsoFrom.map(\.sourceID) }) where titles[sourceID] == nil {
            if let title = articlesById[canonicalSourceID(sourceID)]?.title, !title.isEmpty {
                titles[sourceID] = title
            }
        }
        return titles
    }

    /// After a round: today's cards still waiting in `scope`, and whether
    /// any notebook still has a card today.
    private func memoryCardFollowup(scope: MemoryReviewScope) async throws -> MemoryCardSessionModel.Followup {
        let scoped = try await memoryCardReviewSnapshot(scope: scope, includesListings: false, includesToCheck: false)
        let cards = memorySittingCards(scoped.today.entries, attemptsByItemID: scoped.attemptsByItemID)
        guard scope != .allNotebooks else {
            return MemoryCardSessionModel.Followup(cards: cards, dayHasCardsLeft: !scoped.today.entries.isEmpty)
        }
        let everywhere = try await memoryCardReviewSnapshot(scope: .allNotebooks, includesListings: false, includesToCheck: false)
        return MemoryCardSessionModel.Followup(cards: cards, dayHasCardsLeft: !everywhere.today.entries.isEmpty)
    }

    /// Go Deeper with no model to ask: said under the panel in the words
    /// Settings would use.
    struct GoDeeperUnavailable: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Today's review has answered its first deal through: nothing it
    /// promised is left, so the commitment is released, and when no notebook
    /// has a card left today the day is done, whatever the minutes say
    /// (decisions 2026-09-30, call 1).
    static func cardReviewAnsweredFirstDeal(isCommitted: Bool, dayHasCardsLeft: Bool) {
        let tracker = MemoryReviewEngagementTracker.shared
        if !dayHasCardsLeft {
            tracker.finishDayByCards()
        } else if isCommitted {
            tracker.abandonCommitment()
        }
    }

    // MARK: The focus

    /// The card review takes `windowState` (the window in scope when nil):
    /// rail, Sources and every pane step aside, as for any memory review. A
    /// review that made the commitment begins it.
    func enterMemoryCardFocus(_ session: MemoryCardSessionModel, in windowState: StudioWindowState? = nil) {
        let target = windowState ?? activeWindowState
        target.isVoiceWorkspacePresented = false
        target.memoryReviewFocus = .cards(session)
        if session.isCommitted {
            MemoryReviewEngagementTracker.shared.beginCommittedSession()
        }
    }

    /// A card review left its window (`leaveMemoryReviewFocus`): the counts
    /// the rail and the Memory pane show are read again once its answers
    /// have landed. The session is held until what follows its last round
    /// is read too, so a Done pressed on the last card still tells the day
    /// its cards ran out. (The reminder is about the next morning, which the
    /// review did not change; activation asserts it again.)
    func cardSessionDidEnd(_ session: MemoryCardSessionModel) {
        Task { [weak self] in
            await session.waitForWrites()
            await session.waitForFollowup()
            guard let self else { return }
            self.memoryCardRevision &+= 1
            await self.refreshMemoryCardCounts()
        }
    }

    /// A card's chip: the Reader opens beside the review, at the passage the
    /// card quotes, without ending it. The window's Reader shows the source,
    /// so it is there when the review is left.
    func openCardSourceBesideReview(sourceID: String, quote: String?, in windowState: StudioWindowState) async {
        guard let session = windowState.memoryCardSession,
              let article = articlesById[canonicalSourceID(sourceID)] else {
            showToast("Source not found in library")
            return
        }
        session.besideSourceID = article.id
        await selectArticle(article.id, in: windowState)
        requestReaderPassage(quote, for: article.id)
    }

    // MARK: All cards

    /// The deck whose `cards.state.<deckID>` row holds a listed card's state:
    /// the deck it was kept from, else its anchor source's
    /// (`MemoryCard.stateDeckID`).
    func memoryCardStateDeckID(_ card: MemoryCardListing) -> String? {
        MemoryCardEditWriter.stateDeckID(card)
    }

    /// The card editor's Save. A new front alone rewords the card: the state
    /// row's edited front, the item and its schedule untouched (back to the
    /// kept front clears it). A new back or why starts the card over
    /// (`startMemoryCardOver`). An edit that changes nothing writes nothing.
    /// `update_card` writes through the same `MemoryCardEditWriter`.
    func applyMemoryCardEdit(_ edit: MemoryCardEdit, to card: MemoryCardListing) async {
        let face = card.face
        guard edit.back == face.back, edit.why == face.why else {
            await startMemoryCardOver(card, revisedFace: edit)
            return
        }
        guard MemoryCardEditWriter.reword(card, front: edit.front) else { return }
        memoryCardRevision &+= 1
    }

    /// "Start this card over?": the card is retired with its answers and a
    /// revision under a new card id is kept on the same passages, first
    /// asked tomorrow (`MemoryCardEditWriter.startOver`). With no edit the
    /// revision is the card as it is asked now.
    func startMemoryCardOver(_ card: MemoryCardListing, revisedFace edit: MemoryCardEdit?) async {
        do {
            _ = try await MemoryCardEditWriter.startOver(card, edit: edit, storage: storage)
            memoryCardRevision &+= 1
            await refreshMemoryCardCounts()
        } catch {
            errorMessage = "The card could not be started over. \(error.localizedDescription)"
        }
    }

    /// All Cards' "Always Ask in Its Own Words", or "Let Its Wording Vary":
    /// the card's rewordings kept out of its rotation, or let back in, on
    /// every device (`MemoryCardStateStore.setAlwaysAsk`).
    func setMemoryCardAlwaysAsk(_ on: Bool, for card: MemoryCardListing) {
        guard let deckID = memoryCardStateDeckID(card) else { return }
        MemoryCardStateStore.setAlwaysAsk(
            on,
            cardID: card.face.cardID,
            memoryItemID: card.itemID,
            deckID: deckID
        )
        memoryCardRevision &+= 1
    }

    /// Retires a card: never asked again; its item and answers stay.
    func retireMemoryCard(_ card: MemoryCardListing) async {
        do {
            try await storage.retireMemoryCard(memoryItemID: card.itemID)
            memoryCardRevision &+= 1
            await refreshMemoryCardCounts()
        } catch {
            errorMessage = "The card could not be retired. \(error.localizedDescription)"
        }
    }

    // MARK: Counts

    /// Today's cards across every notebook, for the Memory row's help, and
    /// the daily reminder, which says a review is ready only when the morning
    /// it fires on holds a card (`MemoryReviewPreparationRunner
    /// .refreshReminder`). Driven by events — activation, the morning's
    /// selection — never by a timer.
    func refreshMemoryCardState() async {
        await refreshMemoryCardCounts()
        await MemoryReviewPreparationRunner.shared.refreshReminder()
    }

    /// Today's cards and the cards to check across every notebook, for the
    /// Memory row's help (`memoryCardCounts.line`, "6 due · 4 new · 9 to
    /// check"), each
    /// source's cards to check for the Reader's toolbar
    /// (`memoryCardsToCheckBySource`), and the background drafts the corner
    /// card names (`cardsToCheckPile`): read again
    /// when a review ends, a card is retired, started over, kept or skipped,
    /// and when another device or an assistant changed the library. A failed
    /// read leaves the last counts standing rather than inventing zero.
    func refreshMemoryCardCounts() async {
        let recordingRevision = recordingScopeRevision
        do {
            let snapshot = try await memoryCardReviewSnapshot(scope: .allNotebooks, includesListings: false)
            guard recordingRevision == recordingScopeRevision else { return }
            let counts = snapshot.counts
            if counts != memoryCardCounts { memoryCardCounts = counts }
            let bySource = Dictionary(grouping: snapshot.toCheck, by: \.sourceID).mapValues(\.count)
            if bySource != memoryCardsToCheckBySource { memoryCardsToCheckBySource = bySource }
            // The sources no card covers are read once for the card and the
            // banner; a failed read leaves what the card knew standing.
            var uncovered: StorageService.UncoveredSources?
            do {
                uncovered = try await storage.sourcesWithoutCards(now: Date())
            } catch {
                logger.error("Failed to read the sources without cards: \(error.localizedDescription)")
            }
            guard recordingRevision == recordingScopeRevision else { return }
            // "More sources to come" is the last run's count, kept a day; it is
            // read against the sources still eligible now, and only while the
            // run says something waits, so the common refresh costs nothing.
            var eligibleSources: Int?
            let now = Date()
            if (AutomaticCardDraftingRun.last()?.waiting(asOf: now) ?? 0) > 0 {
                do {
                    let state = try await storage.automaticCardDraftingState(now: now)
                    let failed = Set(AutomaticCardDraftingFailures.recent(now: now).map(\.sourceID))
                    eligibleSources = AutomaticCardDrafting.plan(
                        state.candidates, decksCreatedToday: 0, limit: 0, failed: failed, now: now
                    ).waiting
                } catch {
                    logger.error("Failed to read the sources still to draft: \(error.localizedDescription)")
                }
                guard recordingRevision == recordingScopeRevision else { return }
            }
            noteCardsToCheck(snapshot.toCheck, uncovered: uncovered?.all, eligibleSources: eligibleSources, now: now)
            Task(priority: .utility) { await refreshCardsToCheckBanner(uncovered: uncovered) }
        } catch {
            logger.error("Failed to read today's cards: \(error.localizedDescription)")
        }
    }
}
