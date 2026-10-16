import Foundation

// MARK: - Memory as cards: drafting in the background, and the corner card
//
// docs/memory-design.md, "Drafting in the background". A deliberate finish on
// this Mac — Mark as Read, an article read to its end, a video marked
// watched, listening finished or logged — extracts the source's ideas and
// drafts its cards (`AutomaticCardDraftingPass`, `only` that source); the day
// close drafts the rest of the day's candidates. Both are background spend,
// asked of `backgroundAISpendAllowed()` first, and nothing runs while
// `memory.auto_draft_cards` is off. The drafts wait in To Check, and the
// "Cards to check" corner card says so (`CardsToCheckNudge`).

extension StudioViewModel {
    /// The learner finished `sourceIDs` on this Mac. Their ideas are
    /// extracted — finishing a source is when that happens
    /// (docs/memory-design.md, "Ideas") — and, while background drafting is
    /// on, their cards drafted within the day's limit, at `.utility`. Both are
    /// background spend: nothing is called once the daily background AI
    /// limit says no, and what this left waits for the learner's Make Cards. Finishes
    /// that arrive together — a bulk Mark as Read, one notice in each window
    /// — are one batch, read and drafted once.
    func sourcesWereFinished(_ sourceIDs: [String]) {
        let ids = sourceIDs.filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }
        finishedSourceIDsAwaitingDrafting.formUnion(ids)
        guard finishedSourcesDrainTask == nil else { return }
        finishedSourcesDrainTask = Task(priority: .utility) { [weak self] in
            while let self, !self.finishedSourceIDsAwaitingDrafting.isEmpty {
                let batch = self.finishedSourceIDsAwaitingDrafting.sorted()
                self.finishedSourceIDsAwaitingDrafting.removeAll()
                await self.draftCardsForFinished(batch)
            }
            self?.finishedSourcesDrainTask = nil
        }
    }

    private func draftCardsForFinished(_ sourceIDs: [String]) async {
        let extraction = sourceIdeaExtractionService
        for sourceID in sourceIDs {
            guard await backgroundAISpendAllowed() else { return }
            _ = try? await extraction.prepare(sourceID: sourceID)
        }
        guard MemoryCardSettings.autoDraftsCards() else { return }
        let report = await automaticCardDraftingPass().run(only: Set(sourceIDs))
        if report.draftedCards > 0 || report.waiting != cardsToCheckWaiting {
            await automaticDraftsDidChange()
        }
        for failure in report.failures {
            logger.notice("\(failure, privacy: .public)")
        }
    }

    /// The background drafting pass as this window runs it: its storage, the
    /// spend gate that says once a day when the cap stops it, and the
    /// notebooks it knows are needed soon.
    func automaticCardDraftingPass() -> AutomaticCardDraftingPass {
        AutomaticCardDraftingPass.live(
            storage: storage,
            spendAllowed: { [weak self] in
                await self?.backgroundAISpendAllowed() ?? false
            },
            neededSoonSourceIDs: { [weak self] in
                await self?.automaticCardDraftingNeededSoonSourceIDs() ?? []
            },
            isBeingMade: { sourceID in
                await MainActor.run { CardDraftingCoordinator.shared.isDrafting(sourceID) }
            }
        )
    }

    /// The sources of notebooks needed soon, whose cards are drafted first:
    /// a notebook with a block on today's calendar, or with an open Goal.
    /// Tomorrow's blocks are not read yet; the Mac reads only today's
    /// calendar (`memoryCardDeadlines`).
    func automaticCardDraftingNeededSoonSourceIDs(now: Date = Date()) -> Set<String> {
        let known = Set(notebooks.map(\.id))
        var notebookIDs = Set<String>()
        var sourceIDs = Set<String>()
        for goal in learningGoals where goal.isNotebookGoal && goal.lifecycleStatus == .active && goal.endAt >= now {
            guard let parent = goal.parentNotebookID, known.contains(parent) else { continue }
            notebookIDs.insert(parent)
            sourceIDs.formUnion(goal.approvedSourceIDs)
        }
        for event in DayModel.shared.todayEvents {
            if let notebookID = event.notebookID, known.contains(notebookID) { notebookIDs.insert(notebookID) }
        }
        for notebookID in notebookIDs {
            if let scope = memoryCardScope(for: .notebook(notebookID)) {
                sourceIDs.formUnion(scope.sourceIDs)
            }
        }
        return sourceIDs
    }

    /// Drafts landed in the background: the counts, the Reader's toolbar
    /// and the corner card read them again.
    func automaticDraftsDidChange() async {
        memoryCardRevision &+= 1
        await refreshMemoryCardCounts()
    }

    // MARK: The corner card

    /// What the counts' read says about the background drafts waiting, for
    /// the corner card (`refreshMemoryCardCounts`).
    /// `uncovered` is the sources no card covers, as the same read found
    /// them; nil keeps what the card knew.
    func noteCardsToCheck(_ toCheck: [MemoryCardToCheck], uncovered: Set<String>? = nil, now: Date = Date()) {
        let pile = CardsToCheckNudge.pile(
            drafts: CardsToCheckNudge.pile(toCheck),
            uncovered: uncovered ?? cardsToCheckPile?.uncoveredSourceIDs ?? []
        )
        if pile != cardsToCheckPile { cardsToCheckPile = pile }
        let waiting = AutomaticCardDraftingRun.last()?.waiting(asOf: now) ?? 0
        if waiting != cardsToCheckWaiting { cardsToCheckWaiting = waiting }
        let putOff = CardsToCheckNudge.putOffDay() == MemoryReviewGoal.dayKey(for: now)
        if putOff != cardsToCheckIsPutOff { cardsToCheckIsPutOff = putOff }
    }

    /// Whether `windowState` shows the corner card now
    /// (`CardsToCheckNudge.isShown`). `asksToPlanTheDay` is whether "Plan
    /// your day?" stands in it, which goes first.
    func showsCardsToCheckCard(
        in windowState: StudioWindowState,
        isGettingStarted: Bool,
        asksToPlanTheDay: Bool,
        showsNudges: Bool,
        now: Date = Date()
    ) -> Bool {
        let today = MemoryReviewGoal.dayKey(for: now)
        return CardsToCheckNudge.isShown(
            pile: cardsToCheckPile,
            showsNudges: showsNudges,
            putOffDay: cardsToCheckIsPutOff ? today : nil,
            today: today,
            isMemoryReviewFocused: windowState.memoryReviewFocusSessionID != nil,
            isGettingStarted: isGettingStarted,
            asksToPlanTheDay: asksToPlanTheDay,
            readerSourceIDsOnScreen: windowState.readerSourceIDsOnScreen
        )
    }

    /// The card's line: "14 from 3 sources you finished · 2 more sources to
    /// come", or "5 sources have no cards yet". Nil when the card has nothing
    /// to say.
    var cardsToCheckDetail: String? {
        cardsToCheckPile.map { CardsToCheckNudge.detail($0, waiting: cardsToCheckWaiting) }
    }

    /// Go Through Them: To Check over every notebook, in the window the card
    /// is in; the card is answered for today.
    func goThroughDraftedCards(in windowState: StudioWindowState) {
        putOffCardsToCheck()
        inWindow(windowState) { openCardsToCheck(scope: .allNotebooks) }
    }

    /// Make Cards on the card: the Make Cards sheet for the sources no card
    /// covers, together, so the cards can link what several of them print.
    /// The card is answered for today.
    func makeCardsForUncoveredSources(in windowState: StudioWindowState) {
        let sourceIDs = (cardsToCheckPile?.uncoveredSourceIDs ?? []).sorted()
        putOffCardsToCheck()
        guard !sourceIDs.isEmpty else { return }
        inWindow(windowState) { presentMakeCards(notebookID: nil, sourceIDs: sourceIDs) }
    }

    /// Sources came into the library or became readable: the sources no card
    /// covers are read again for the card and the banner. Event-driven, from
    /// a sources reload that changed something, at `.utility`.
    func refreshCardsToCheckAdditions() async {
        let uncovered: StorageService.UncoveredSources
        do {
            uncovered = try await storage.sourcesWithoutCards(now: Date())
        } catch {
            logger.error("The cards card could not read the sources without cards: \(error.localizedDescription)")
            return
        }
        let drafts = cardsToCheckPile.flatMap { $0.hasDrafts ? CardsToCheckNudge.Pile(cardCount: $0.cardCount, sourceIDs: $0.sourceIDs) : nil }
        let pile = CardsToCheckNudge.pile(drafts: drafts, uncovered: uncovered.all)
        if pile != cardsToCheckPile { cardsToCheckPile = pile }
        await refreshCardsToCheckBanner(uncovered: uncovered)
    }

    /// ×: later. The card goes from every window on this Mac and asks again
    /// tomorrow while drafts still wait.
    func putOffCardsToCheck(now: Date = Date()) {
        CardsToCheckNudge.putOff(on: MemoryReviewGoal.dayKey(for: now))
        cardsToCheckIsPutOff = true
    }

    // MARK: The morning-after banner

    /// Queues, replaces or takes down the next morning's "Cards from what you
    /// finished" banner from what is true now: the drafts waiting in To Check,
    /// while background drafting is off the finished sources no deck covers,
    /// and what was added to the library today or yesterday with no card
    /// (`CardsToCheckBanner.subject`). Called wherever that could have
    /// changed — the counts' read, activation, a settings change — at
    /// `.utility`, never on a timer.
    func refreshCardsToCheckBanner(uncovered known: StorageService.UncoveredSources? = nil) async {
        // Signed out, the library is behind the sign-in wall; the queue keeps
        // what it has until there is a library to read.
        guard ManagedAI.isSignedIn else { return }
        await CardsToCheckNotifications.shared.refresh { [weak self] in
            guard let self else { return nil }
            let autoDrafts = MemoryCardSettings.autoDraftsCards()
            let now = Date()
            var candidates: [AutomaticCardDrafting.Candidate] = []
            if !autoDrafts {
                do {
                    candidates = try await storage.automaticCardDraftingState(now: now).candidates
                } catch {
                    logger.error("The cards banner could not read finished sources: \(error.localizedDescription)")
                    return nil
                }
            }
            // What came into the library today or yesterday with no card: the
            // day's suggestion to make cards, read or not.
            var added = known?.recent ?? []
            if known == nil {
                do {
                    added = try await storage.sourcesAddedWithoutCards(now: now)
                } catch {
                    logger.error("The cards banner could not read what was added: \(error.localizedDescription)")
                    return nil
                }
            }
            return CardsToCheckBanner.subject(
                pile: cardsToCheckPile.flatMap { $0.hasDrafts ? CardsToCheckNudge.Pile(cardCount: $0.cardCount, sourceIDs: $0.sourceIDs) : nil },
                candidates: candidates,
                autoDrafts: autoDrafts,
                addedSourceIDs: added,
                now: now
            )
        }
    }

    /// Don't Ask Again: `memory.draft_nudges` off, on every device.
    func stopCardsToCheckNudges() {
        MemoryCardSettings.setShowsDraftNudges(false)
        Task(priority: .utility) { await refreshCardsToCheckBanner() }
    }
}
