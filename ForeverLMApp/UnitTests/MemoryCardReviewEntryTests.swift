import Foundation
import Testing
@testable import ForeverLM

/// Memory as cards, stage three on the Mac: every way into the review opens
/// the Memory pane — over every notebook from the rail, the reminder and the
/// Today menu, over one notebook from its Studio — Start Review gives the
/// window to the card review, and the review writes each first answer once.
///
/// Nothing here begins or ends the day's commitment on the shared tracker:
/// the sittings are started on a day already done (no commitment) or as
/// practice, and the session model is told about its first deal through a
/// closure, so no test writes today's end or "cards finished" into the host's
/// defaults. A pane change writes the layout template, and opening a notebook
/// the active Notebook, into the host's real defaults: each test that can
/// puts them back.
@Suite("Memory cards: the way into the card review")
@MainActor
struct MemoryCardReviewEntryTests {
    private static let text = "Mitochondria couple respiration to ATP synthesis through a proton gradient. "
        + "Uncoupling proteins let protons leak back without making ATP."

    /// A view model on a store of its own, deaf to other tests' change
    /// notices: a reload from its empty store mid-test would drop the
    /// notebooks a test laid out.
    private func makeViewModel() -> (StudioViewModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MemoryCardReview_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (StudioViewModel(storageService: StorageService(storeRoot: root), observeCloudKitChanges: false), root)
    }

    private static let templateKeys = [
        "studio.centerTabGroups.v1",
        "studio.navigationRailVisible",
    ]

    /// The unit host's defaults are the real ones: the layout template a pane
    /// change writes, and the active Notebook an open moves.
    private func capturingSharedDefaults() -> () -> Void {
        let template = Self.templateKeys.map { UserDefaults.standard.object(forKey: $0) }
        let activeNotebookID = ActiveNotebookPreference.notebookID
        return {
            for (key, value) in zip(Self.templateKeys, template) {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
            ActiveNotebookPreference.notebookID = activeNotebookID
        }
    }

    /// A notebook of the library the view model has open.
    private func notebook(_ id: String, sources: [String] = [], in vm: StudioViewModel) -> LearningGoalRecord {
        let now = Date()
        return LearningGoalRecord(
            id: id,
            title: id,
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: now,
            updatedAt: now,
            status: "active",
            items: sources.map { LearningGoalItem(id: "item-\(id)-\($0)", goalID: id, sourceID: $0, addedAt: now) },
            kind: LearningGoalRecord.companionKind,
            teamID: vm.activeTeamID
        )
    }

    /// A source with text, and a card kept on it two days ago (new, and
    /// eligible today).
    private func seedCard(in storage: StorageService) async throws -> (MemoryCard, MemoryItem) {
        var source = StudioArticle(url: "https://example.com/mito", title: "Mitochondria", sourceType: .article, discoveryOrigin: .manual, id: "src-1")
        source.normalizedURL = URLNormalizer.normalize(source.url)
        source.content = Self.text
        source.state = .ready
        try await storage.saveSource(source)
        let card = MemoryCard(
            cardID: "card-\(UUID().uuidString)",
            front: "What couples respiration to ATP synthesis?",
            back: "A proton gradient.",
            origin: .drafted,
            deckID: MemoryCard.draftDeckID(sourceID: "src-1")
        )
        let item = try await storage.keepMemoryCard(
            card, sourceID: "src-1", quote: "couple respiration to ATP synthesis",
            at: Date().addingTimeInterval(-2 * MemoryTutorScheduler.secondsPerDay)
        )
        return (card, item)
    }

    // MARK: Entries

    @Test("Every entry that began the topic review opens the Memory pane over every notebook, and none takes the window")
    func entriesOpenTheMemoryPane() {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, root) = makeViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = vm.activeWindowState

        // The daily reminder and the Today menu: the Review, every notebook.
        window.memoryPaneScope = .notebook("finbow")
        window.memoryPaneSection = .allCards
        vm.requestCardReview(scope: .allNotebooks)
        #expect(vm.activeCenterTabs.contains(.memory))
        #expect(window.memoryPaneScope == .allNotebooks)
        #expect(window.memoryPaneSection == .review)
        #expect(window.memoryReviewFocusSessionID == nil)
        #expect(vm.reviewChatResumeSessionID == nil)
        #expect(vm.pendingMemoryReview == nil)

        // The rail's row, its Open Beside and Open in Other Window: every
        // notebook, on the section the learner left it.
        vm.activateCenterTab(.chat)
        window.memoryPaneScope = .notebook("finbow")
        window.memoryPaneSection = .allCards
        vm.openMemoryPane()
        #expect(vm.activeCenterTabs.contains(.memory))
        #expect(window.memoryPaneScope == .allNotebooks)
        #expect(window.memoryPaneSection == .allCards)
        window.memoryPaneScope = .notebook("finbow")
        vm.openMemoryPaneBeside()
        #expect(vm.activeCenterTabs.contains(.memory))
        #expect(window.memoryPaneScope == .allNotebooks)
        #expect(window.memoryReviewFocusSessionID == nil)
        #expect(StudioWindowDestination.memory.noun == "Memory")
    }

    @Test("Start Review never resumes the day's review chat: a topic-shaped day is not today's review")
    func startReviewRefusesTheTopicShapedDay() {
        let (vm, root) = makeViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let todayID = MemoryReviewSession.sessionID(for: Date())
        vm.reviewSessionLinks = [
            ReviewSessionRecord(id: todayID, title: "Today", createdAt: Date(), status: "active", sourceIDs: []),
        ]

        // The store holds no card, so nothing takes the window either way.
        vm.startCardReview(scope: .allNotebooks)

        #expect(vm.reviewChatResumeSessionID == nil, "the topic chat is not resumed")
        #expect(vm.pendingMemoryReview == nil, "no topic review is planned")
        #expect(vm.activeWindowState.memoryReviewFocusSessionID != todayID)
    }

    @Test("A day kept by the preparation as cards is today's review; an older build's topic-shaped attempt is not")
    func dayRecordShape() throws {
        let cards = MemoryReviewPreparationRunner.Attempt(day: "memory-2026-10-01", at: Date(), succeeded: true, dueCards: 6, newCards: 4)
        #expect(cards.kind == .cards)
        #expect(cards.cardsLine == "6 due · 4 new")
        #expect(MemoryReviewPreparationRunner.preparedDay(of: cards) == "memory-2026-10-01")

        // What a build before cards stored: no kind, a review chat's id.
        let older = #"{"day":"memory-2026-10-01","at":780000000,"succeeded":true,"sessionID":"memory-2026-10-01"}"#
        let topics = try JSONDecoder().decode(MemoryReviewPreparationRunner.Attempt.self, from: Data(older.utf8))
        #expect(topics.kind == .topics)
        #expect(!topics.kind.isResumable)
        #expect(topics.cardsLine == nil)
        #expect(MemoryReviewPreparationRunner.preparedDay(of: topics) == nil, "the morning selects the day's cards anyway")

        let roundTrip = try JSONDecoder().decode(
            MemoryReviewPreparationRunner.Attempt.self,
            from: try JSONEncoder().encode(cards)
        )
        #expect(roundTrip == cards)
        #expect(MemoryReviewPreparationRunner.Attempt(day: "d", at: Date(), succeeded: true, dueCards: 0, newCards: 0).cardsLine == "No cards due")
    }

    @Test("Inside a notebook the Memory pane opens among its panes: over every notebook from the rail, narrowed to it from its Studio")
    func memoryPaneInANotebook() {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, root) = makeViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        vm.learningGoals = [notebook("finbow", in: vm)]
        let window = vm.activeWindowState
        #expect(vm.memoryPaneScope(in: window) == .allNotebooks)

        window.NotebookID = "finbow"
        let showsMemory = { window.centerTabGroups.groups.contains { $0.activeTab == .memory } }
        // The rail's Memory row: recall spans every notebook by default.
        vm.openMemoryPane()
        #expect(window.notebook?.notebookID == "finbow", "the notebook stays open")
        #expect(showsMemory())
        #expect(vm.memoryPaneScope(in: window) == .allNotebooks)

        // The notebook's Studio Cards tile: the same pane, on its Review,
        // narrowed to the notebook, and nothing given over yet.
        window.memoryPaneSection = .allCards
        vm.requestCardReview(scope: .notebook("finbow"))
        #expect(window.notebook?.notebookID == "finbow")
        #expect(showsMemory())
        #expect(window.memoryPaneSection == .review)
        #expect(vm.memoryPaneScope(in: window) == .notebook("finbow"))
        #expect(window.memoryReviewFocusSessionID == nil, "the pane asks before the window is given over")

        // A notebook the library no longer holds is no scope.
        vm.learningGoals = []
        #expect(vm.memoryPaneScope(in: window) == .allNotebooks)
    }

    @Test("A notebook's scope is homing's membership: its member sources, a team copy resolved to the learner's own")
    func notebookScope() throws {
        let (vm, root) = makeViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        vm.learningGoals = [notebook("team-nb", sources: ["team-copy", "own"], in: vm)]
        vm.articlesStore.teamCopyAliases = ["team-copy": "own-twin"]

        #expect(vm.memoryCardScope(for: .allNotebooks) == nil)
        let scope = try #require(vm.memoryCardScope(for: .notebook("team-nb")))
        #expect(scope.notebookID == "team-nb")
        #expect(scope.membership.sourceIDs == ["own-twin", "own"], "the membership holds the learner's own rows")
        #expect(scope.sourceIDs == ["team-copy", "own-twin", "own"])
        #expect(vm.memoryReviewScopeTitle(.notebook("team-nb")) == "team-nb")
        #expect(vm.memoryReviewScopeTitle(.allNotebooks) == "All notebooks")
        #expect(vm.memoryReviewScopeTitle(.notebook("gone")) == "Notebook")
    }

    // MARK: Starting and leaving

    @Test("Start Review deals today's cards in the window-filling focus, which any surface — Chat included — leaves")
    func startReviewTakesTheWindow() async throws {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, root) = makeViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let (card, item) = try await seedCard(in: vm.storage)
        let window = vm.activeWindowState

        // A day already done: the review makes no commitment.
        await vm.startCardSitting(scope: .allNotebooks, kind: nil, commitment: .done(streak: 1))?.value
        let session = try #require(window.memoryCardSession)
        #expect(session.sitting.kind == .today)
        #expect(session.sitting.cards.map(\.itemID) == [item.id])
        #expect(session.sitting.cards.first?.prompt == card.front)
        #expect(session.sitting.cards.first?.sourceID == "src-1")
        #expect(!session.isCommitted)
        #expect(!session.leavingEndsSession)
        #expect(session.scopeTitle == "All notebooks")
        #expect(window.memoryReviewFocusSessionID == session.id)
        #expect(session.id.hasPrefix("cards-"))

        // One review a window at a time.
        #expect(vm.startCardSitting(scope: .allNotebooks, kind: nil, commitment: .done(streak: 1)) == nil)

        // The Reader a card's source opened keeps the review through a link
        // followed in it, and closes back to the review alone.
        session.besideSourceID = "src-1"
        vm.revealReader(beside: .chat, in: window)
        vm.activateCenterTab(.reader, in: window)
        #expect(window.memoryCardSession === session, "a link in the Reader beside stays in it")
        vm.dismissCenterSurface(.reader, in: window)
        #expect(session.besideSourceID == nil)
        #expect(window.memoryCardSession === session)

        // A request for any surface, Chat included, is the learner going.
        vm.activateCenterTab(.chat, in: window)
        #expect(window.memoryCardSession == nil)
        #expect(window.memoryReviewFocusSessionID == nil)
    }

    @Test("A notebook with no card due starts practice of its new cards; a notebook without cards starts nothing")
    func notebookPractice() async throws {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, root) = makeViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        var source = StudioArticle(url: "https://example.com/mito", title: "Mitochondria", sourceType: .article, discoveryOrigin: .manual, id: "src-1")
        source.normalizedURL = URLNormalizer.normalize(source.url)
        source.content = Self.text
        source.state = .ready
        try await vm.storage.saveSource(source)
        // Kept just now: not asked by today's review, but practice takes it.
        let card = MemoryCard(cardID: "kept-today", front: "What leaks protons?", back: "Uncoupling proteins.", origin: .drafted, deckID: MemoryCard.draftDeckID(sourceID: "src-1"))
        let item = try await vm.storage.keepMemoryCard(card, sourceID: "src-1", quote: "Uncoupling proteins let protons leak back")
        vm.learningGoals = [notebook("finbow", sources: ["src-1"], in: vm), notebook("empty", sources: ["src-2"], in: vm)]
        let window = vm.activeWindowState

        await vm.startCardSitting(scope: .notebook("empty"), kind: nil, commitment: .done(streak: 1))?.value
        #expect(window.memoryCardSession == nil)

        await vm.startCardSitting(scope: .notebook("finbow"), kind: nil, commitment: .open)?.value
        let session = try #require(window.memoryCardSession)
        #expect(session.sitting.kind == .practice)
        #expect(session.sitting.cards.map(\.itemID) == [item.id])
        #expect(session.scopeTitle == "finbow")
        #expect(!session.isCommitted, "practice makes no commitment")
        vm.leaveMemoryReviewFocus(in: window)
        #expect(window.memoryCardSession == nil)
    }

    @Test("Practice deals only its own cards: they count as practice, and no Continue leads into today's review")
    func practiceStaysPractice() async throws {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, root) = makeViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        // A card kept two days ago is today's; one kept just now is practice's.
        let (_, todays) = try await seedCard(in: vm.storage)
        let card = MemoryCard(cardID: "kept-now", front: "What leaks protons?", back: "Uncoupling proteins.", origin: .drafted, deckID: MemoryCard.draftDeckID(sourceID: "src-1"))
        let keptNow = try await vm.storage.keepMemoryCard(card, sourceID: "src-1", quote: "Uncoupling proteins let protons leak back")
        let window = vm.activeWindowState

        await vm.startCardSitting(scope: .allNotebooks, kind: .practice, commitment: .done(streak: 1))?.value
        let session = try #require(window.memoryCardSession)
        #expect(session.sitting.kind == .practice)
        #expect(session.sitting.cards.map(\.itemID) == [keptNow.id])
        session.showAnswer(attempt: "An answer")
        session.answer(remembered: true)
        await session.waitForWrites()
        await session.waitForFollowup()
        #expect(session.waitingCards.isEmpty, "today's card is Start Review's")
        let practised = try await vm.storage.loadMemoryAttempts(memoryItemID: keptNow.id)
        let untouched = try await vm.storage.loadMemoryAttempts(memoryItemID: todays.id)
        #expect(practised.count == 1, "a card kept today counts in practice the learner started")
        #expect(untouched.isEmpty)
        vm.leaveMemoryReviewFocus(in: window)
        #expect(window.memoryCardSession == nil)
    }

    @Test("A day whose review was ended early still deals today's cards, with no commitment")
    func endedDayKeepsGoing() async throws {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, root) = makeViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, item) = try await seedCard(in: vm.storage)
        let window = vm.activeWindowState

        await vm.startCardSitting(scope: .allNotebooks, kind: nil, commitment: .ended(afterSeconds: 120))?.value
        let session = try #require(window.memoryCardSession)
        #expect(session.sitting.kind == .today)
        #expect(session.sitting.cards.map(\.itemID) == [item.id])
        #expect(!session.isCommitted, "the day stays ended; Keep Going promises nothing")
        vm.leaveMemoryReviewFocus(in: window)
        #expect(window.memoryCardSession == nil)
    }

    @Test("A chat review keeps its focus for its own chat; a card review yields to every surface")
    func focusYields() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MemoryCardFocus_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let window = StudioWindowState()
        #expect(!window.memoryReviewFocusYields(to: .reader))

        window.memoryReviewFocusSessionID = "memory-2026-10-01"
        #expect(!window.memoryReviewFocusYields(to: .chat))
        #expect(window.memoryReviewFocusYields(to: .reader))
        #expect(window.memoryCardSession == nil)

        let session = MemoryCardSessionModel(
            sitting: MemoryCardSitting(key: "cards-2026-10-01-x", kind: .today, cards: []),
            scope: .allNotebooks,
            scopeTitle: "All notebooks",
            isCommitted: false,
            sourceTitles: [:],
            storage: StorageService(storeRoot: root),
            followup: { .init(cards: [], dayHasCardsLeft: true) }
        )
        window.memoryReviewFocus = .cards(session)
        #expect(window.memoryReviewFocusSessionID == "cards-2026-10-01-x")
        #expect(window.memoryCardSession === session)
        #expect(window.memoryReviewFocusYields(to: .chat))
        #expect(window.memoryReviewFocusYields(to: .memory))
        #expect(window.memoryReviewFocusYields(to: .reader))
        // The Reader a card's source opened beside the review is the review's.
        session.besideSourceID = "src-1"
        #expect(!window.memoryReviewFocusYields(to: .reader))
        #expect(window.memoryReviewFocusYields(to: .chat))

        window.memoryReviewFocusSessionID = nil
        #expect(window.memoryReviewFocus == nil)
    }

    // MARK: The session

    @Test("The card review writes each first answer once under the sitting's key, and tells the day once its first deal is answered")
    func sessionWritesFirstAnswersOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MemoryCardSession_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let (card, item) = try await seedCard(in: storage)
        let told = Box<[Bool]>([])
        let session = MemoryCardSessionModel(
            sitting: MemoryCardSitting(
                key: "cards-test-1",
                kind: .today,
                cards: [MemoryCardSitting.Card(itemID: item.id, prompt: card.front, back: card.back, isNew: true)]
            ),
            scope: .allNotebooks,
            scopeTitle: "All notebooks",
            isCommitted: true,
            sourceTitles: [:],
            storage: storage,
            followup: { .init(cards: [], dayHasCardsLeft: false) },
            firstDealAnswered: { told.value.append($0) }
        )
        #expect(session.leavingEndsSession, "a committed review with its card unanswered")

        // Nothing is graded before the back is shown.
        session.answer(remembered: true)
        #expect(session.sitting.cardNumber == 1)
        session.showAnswer(attempt: "An answer")
        session.answer(remembered: false)
        #expect(!session.leavingEndsSession, "its one card is answered")
        await session.waitForWrites()
        await session.waitForFollowup()

        var attempts = try await storage.loadMemoryAttempts(memoryItemID: item.id)
        #expect(attempts.count == 1)
        #expect(attempts.first?.id == MemoryTutorIdentity.selfGradedAttemptID(sessionKey: "cards-test-1", memoryItemID: item.id))
        #expect(attempts.first?.prompt == card.front)
        #expect(attempts.first?.learnerAnswer == MemoryAttempt.selfGradedAnswer)
        #expect(attempts.first?.scheduleRating == .again)
        #expect(session.saveError == nil)
        #expect(told.value == [false], "no notebook has a card left: the day is told so")
        #expect(session.waitingCards.isEmpty)

        // Review forgotten: shown again, never written, the day not told twice.
        session.reviewForgotten()
        #expect(session.sitting.isRepeat)
        session.showAnswer(attempt: "An answer")
        session.answer(remembered: true)
        await session.waitForWrites()
        await session.waitForFollowup()
        attempts = try await storage.loadMemoryAttempts(memoryItemID: item.id)
        #expect(attempts.count == 1)
        #expect(told.value == [false])
    }

    @Test("An answer the store refuses is said under the card, and the review goes on")
    func sessionSaysAnUnsavedAnswer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MemoryCardUnsaved_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = MemoryCardSessionModel(
            sitting: MemoryCardSitting(
                key: "cards-test-2",
                kind: .today,
                cards: [
                    MemoryCardSitting.Card(itemID: "no-such-item", prompt: "Q", back: "A"),
                    MemoryCardSitting.Card(itemID: "another", prompt: "Q2", back: "A2"),
                ]
            ),
            scope: .allNotebooks,
            scopeTitle: "All notebooks",
            isCommitted: false,
            sourceTitles: [:],
            storage: StorageService(storeRoot: root),
            followup: { .init(cards: [], dayHasCardsLeft: true) }
        )
        session.showAnswer(attempt: "An answer")
        session.answer(remembered: true)
        await session.waitForWrites()
        #expect(session.saveError?.hasPrefix("Your answer to the last card was not saved.") == true)
        #expect(session.sitting.cardNumber == 2, "the review moves on")
    }

    // MARK: A notebook's Practice

    /// A source of its own with text — so its deck's state row in the host's
    /// defaults is nobody's — two cards kept on it (two days ago, eligible
    /// today; and just now) and three drafts waiting to be checked.
    private func seedNotebookCards(in storage: StorageService) async throws -> (sourceID: String, kept: [MemoryItem], drafts: [Flashcard]) {
        let sourceID = "src-practice-\(UUID().uuidString.lowercased())"
        var source = StudioArticle(url: "https://example.com/\(sourceID)", title: "Mitochondria", sourceType: .article, discoveryOrigin: .manual, id: sourceID)
        source.normalizedURL = URLNormalizer.normalize(source.url)
        source.content = Self.text
        source.state = .ready
        try await storage.saveSource(source)
        func face(_ id: String, _ front: String, _ back: String) -> MemoryCard {
            MemoryCard(cardID: "\(id)-\(UUID().uuidString)", front: front, back: back, origin: .drafted, deckID: MemoryCard.draftDeckID(sourceID: sourceID))
        }
        let older = try await storage.keepMemoryCard(
            face("older", "What couples respiration to ATP synthesis?", "A proton gradient."),
            sourceID: sourceID, quote: "couple respiration to ATP synthesis",
            at: Date().addingTimeInterval(-2 * MemoryTutorScheduler.secondsPerDay)
        )
        let keptToday = try await storage.keepMemoryCard(
            face("today", "What leaks protons back?", "Uncoupling proteins."),
            sourceID: sourceID, quote: "Uncoupling proteins let protons leak back"
        )
        let now = Date()
        let drafts = [
            Flashcard.mint(front: "What do mitochondria couple?", back: "Respiration and ATP synthesis.", sourceID: sourceID, sourceTitle: "Mitochondria", quote: "Mitochondria couple respiration", origin: .drafted, isRequested: false, at: now),
            Flashcard.mint(front: "Through what?", back: "A proton gradient.", sourceID: sourceID, sourceTitle: "Mitochondria", quote: "through a proton gradient", origin: .drafted, isRequested: false, at: now),
            Flashcard.mint(front: "Without making what?", back: "ATP.", sourceID: sourceID, sourceTitle: "Mitochondria", quote: "without making ATP", origin: .drafted, isRequested: false, at: now),
        ]
        let saved = try await storage.saveCardDrafts(drafts, sourceID: sourceID, sourceTitle: "Mitochondria")
        #expect(saved.added.count == 3)
        return (sourceID, [older, keptToday], drafts)
    }

    @Test("A notebook's Practice deals its kept cards and then its cards to check, makes no commitment, and starts nothing for a notebook with no card")
    func notebookPracticeDealsKeptAndDrafts() async throws {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, root) = makeViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let (sourceID, kept, drafts) = try await seedNotebookCards(in: vm.storage)
        vm.learningGoals = [notebook("finbow", sources: [sourceID], in: vm), notebook("empty", sources: ["src-none"], in: vm)]
        let window = vm.activeWindowState

        await vm.startNotebookPractice(notebookID: "empty")?.value
        #expect(window.memoryCardSession == nil)
        #expect(vm.toastMessage == "No cards in empty to practice yet.")

        await vm.startNotebookPractice(notebookID: "finbow")?.value
        let session = try #require(window.memoryCardSession)
        #expect(session.sitting.kind == .practice)
        #expect(!session.isCommitted, "practice the learner started makes no commitment")
        #expect(session.scopeTitle == "finbow")
        #expect(session.scope == .notebook("finbow"))
        let cards = session.sitting.cards
        #expect(cards.prefix(2).map(\.itemID) == kept.map(\.id), "kept cards first, the one kept today among them")
        #expect(cards.dropFirst(2).map(\.cardID) == drafts.map(\.id), "then the cards to check, in To Check's order")
        let allDrafts = cards.dropFirst(2).allSatisfy { $0.isDraft }
        #expect(allDrafts)
        #expect(cards.first?.sourceID == sourceID)
        #expect(session.sourceTitles[sourceID] == nil || session.sourceTitles[sourceID] == "Mitochondria")
        vm.leaveMemoryReviewFocus(in: window)
        #expect(window.memoryCardSession == nil)
    }

    @Test("In a notebook's Practice, answering a draft keeps it and writes its first answer; Skip drops it; Edit keeps it in the learner's words; a card not due is shown and not written")
    func notebookPracticeRecordingRules() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MemoryCardPractice_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "foreverlm-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = StorageService(storeRoot: root)
        let (sourceID, kept, drafts) = try await seedNotebookCards(in: storage)
        // The older card was answered this morning in another sitting: it is
        // not due again yet.
        #expect(try await storage.recordSelfGradedMemoryCardAttempt(
            memoryItemID: kept[0].id, prompt: "What couples respiration to ATP synthesis?", remembered: true, sessionKey: "earlier"
        ) == .recorded)
        let scope = MemoryCardScope(notebookID: "nb", memberSourceIDs: [sourceID])
        let deal = try await storage.memoryCardNotebookPractice(scope: scope, now: Date(), stateDefaults: defaults)
        #expect(deal.drafts.map(\.cardID) == drafts.map(\.id))
        let session = MemoryCardSessionModel(
            sitting: MemoryCardSitting(
                key: "cards-practice-test",
                kind: .practice,
                cards: deal.kept.answerable.map { MemoryCardSitting.Card(itemID: $0.item.id, prompt: "Q", back: "A", isNew: $0.isNew) }
                    + deal.drafts.compactMap(MemoryCardSitting.Card.draft)
                    + deal.kept.notDueYet.map { MemoryCardSitting.Card(itemID: $0.item.id, prompt: "Q", back: "A", isNew: $0.isNew) }
            ),
            scope: .notebook("nb"),
            scopeTitle: "nb",
            isCommitted: false,
            sourceTitles: [:],
            storage: storage,
            stateDefaults: defaults,
            followup: { .init(cards: [], dayHasCardsLeft: true) }
        )
        let deckID = MemoryCard.draftDeckID(sourceID: sourceID)
        // The card kept today counts and comes first; the one answered this
        // morning is not due, and comes after the drafts.
        #expect(deal.kept.answerable.map(\.item.id) == [kept[1].id])
        #expect(deal.kept.notDueYet.map(\.item.id) == [kept[0].id])
        #expect(session.sitting.cards.map(\.itemID).last == kept[0].id)

        // Kept today: practice the learner started counts it.
        session.showAnswer(attempt: "An answer")
        session.answer(remembered: true)
        await session.waitForWrites()
        #expect(try await storage.loadMemoryAttempts(memoryItemID: kept[1].id).count == 1)

        // A draft answered is kept, and its answer is its first.
        session.showAnswer(attempt: "An answer")
        session.answer(remembered: false)
        await session.waitForWrites()
        let keptDraftID = MemoryTutorIdentity.cardItemID(cardID: drafts[0].id)
        let keptDraft = try #require(try await storage.loadMemoryItem(keptDraftID))
        #expect(keptDraft.target == drafts[0].back)
        let firstAnswer = try await storage.loadMemoryAttempts(memoryItemID: keptDraftID)
        #expect(firstAnswer.count == 1)
        #expect(firstAnswer.first?.scheduleRating == .again)
        #expect(firstAnswer.first?.prompt == drafts[0].front)
        #expect(MemoryCardStateStore.state(cardID: drafts[0].id, deckID: deckID, defaults: defaults)?.status == .kept)

        // Skip drops the next one for good, with no item and no answer.
        session.skipCurrentDraft()
        await session.waitForWrites()
        #expect(MemoryCardStateStore.state(cardID: drafts[1].id, deckID: deckID, defaults: defaults)?.status == .skipped)
        #expect(try await storage.loadMemoryItem(MemoryTutorIdentity.cardItemID(cardID: drafts[1].id)) == nil)

        // Edit, then Keep, before the answer: kept in the learner's words,
        // then answered as the kept card it is.
        let edit = MemoryCardEdit(front: "What is made without ATP?", back: "Nothing: the protons leak back.", why: [])
        let keptEdited = await session.keepCurrentDraft(edited: edit)?.value
        #expect(keptEdited == true)
        #expect(session.sitting.current?.isDraft == false)
        #expect(session.sitting.current?.prompt == "What is made without ATP?")
        let editedID = MemoryTutorIdentity.cardItemID(cardID: drafts[2].id)
        #expect(try await storage.loadMemoryItem(editedID)?.target == "Nothing: the protons leak back.")
        session.showAnswer(attempt: "An answer")
        session.answer(remembered: true)
        await session.waitForWrites()
        #expect(try await storage.loadMemoryAttempts(memoryItemID: editedID).first?.prompt == "What is made without ATP?")

        // Answered this morning and not due: shown, not written.
        session.showAnswer(attempt: "An answer")
        session.answer(remembered: false)
        await session.waitForWrites()
        #expect(try await storage.loadMemoryAttempts(memoryItemID: kept[0].id).count == 1, "an early answer never moves the schedule")
        #expect(session.saveError == nil)
        #expect(session.sitting.isRoundOver)
        #expect(session.sitting.skippedCount == 1)

        // What is left to check in the notebook: nothing.
        let after = try await storage.memoryCardNotebookPractice(scope: scope, now: Date(), stateDefaults: defaults)
        #expect(after.drafts.isEmpty)
        #expect(after.kept.all.count == 4)
    }

    @Test("A notebook's Cards line counts its kept, due and to-check cards through homing's membership, a team copy's own source included")
    func notebookCardCounts() async throws {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let (vm, root) = makeViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let (sourceID, _, _) = try await seedNotebookCards(in: vm.storage)
        // The team's notebook lists its copy; the cards stand on the learner's own source.
        vm.learningGoals = [notebook("team-nb", sources: ["team-copy"], in: vm), notebook("empty", sources: ["src-none"], in: vm)]
        vm.articlesStore.teamCopyAliases = ["team-copy": sourceID]

        let counts = try #require(await vm.notebookCardCounts(notebookID: "team-nb"))
        #expect(counts == NotebookCardCounts(kept: 2, due: 0, toCheck: 3))
        #expect(counts.line == "2 kept · 3 to check")
        let empty = try #require(await vm.notebookCardCounts(notebookID: "empty"))
        #expect(empty.isEmpty)

        // The row opens To Check while cards wait there, else the Review.
        let window = vm.activeWindowState
        vm.inWindow(window) { vm.openNotebookCards(notebookID: "team-nb", counts: counts) }
        #expect(window.memoryPaneSection == .toCheck)
        #expect(vm.memoryPaneScope(in: window) == .notebook("team-nb"))
        vm.inWindow(window) { vm.openNotebookCards(notebookID: "team-nb", counts: NotebookCardCounts(kept: 2, due: 1, toCheck: 0)) }
        #expect(window.memoryPaneSection == .review)
        #expect(window.memoryReviewFocusSessionID == nil, "opening the cards gives no window over")
        #expect(StudioWindowDestination.memoryReview(notebookID: "team-nb").noun == "Memory")
    }

    // MARK: Go Deeper

    private typealias Probe = MemoryUnderstandingProbe

    /// A sitting whose answers the store refuses (no such items): what Go
    /// Deeper shows does not wait on them.
    private func deeperSession(cards count: Int, stub: GoDeeperStub, root: URL) -> MemoryCardSessionModel {
        MemoryCardSessionModel(
            sitting: MemoryCardSitting(
                key: "cards-deeper-\(UUID().uuidString)",
                kind: .today,
                cards: (1...count).map {
                    MemoryCardSitting.Card(itemID: "card-\($0)", prompt: "Front \($0)", back: "Back \($0)", why: ["Why \($0)."], sourceID: "src-\($0)")
                }
            ),
            scope: .allNotebooks,
            scopeTitle: "All notebooks",
            isCommitted: false,
            sourceTitles: ["src-1": "Mitochondria"],
            storage: StorageService(storeRoot: root),
            followup: { .init(cards: [], dayHasCardsLeft: true) },
            deeper: stub.steps
        )
    }

    @Test("Go Deeper answers the card Remembered as Remembered does, then asks a question past it where the next card would be")
    func goDeeperAnswersRememberedThenAsks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MemoryCardDeeper_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let (card, item) = try await seedCard(in: storage)
        let stub = GoDeeperStub()
        let question = Probe.CardQuestion(kind: .principle, text: "What general rule is this an instance of?")
        stub.question = .success(question)
        let session = MemoryCardSessionModel(
            sitting: MemoryCardSitting(
                key: "cards-deeper-1",
                kind: .today,
                cards: [
                    MemoryCardSitting.Card(itemID: item.id, prompt: card.front, back: card.back, sourceID: "src-1", isNew: true),
                    MemoryCardSitting.Card(itemID: "next-card", prompt: "Next", back: "Card"),
                ]
            ),
            scope: .allNotebooks,
            scopeTitle: "All notebooks",
            isCommitted: false,
            sourceTitles: ["src-1": "Mitochondria"],
            storage: storage,
            followup: { .init(cards: [], dayHasCardsLeft: true) },
            deeper: stub.steps
        )
        #expect(session.offersGoDeeper)

        // Nothing before the back is shown.
        session.goDeeper()
        #expect(session.deeper == nil)
        #expect(session.sitting.cardNumber == 1)

        session.showAnswer(attempt: "An answer")
        session.goDeeper()
        #expect(session.sitting.results[item.id] == true, "answered Remembered")
        #expect(session.sitting.current?.itemID == "next-card")
        #expect(session.deeper?.card.itemID == item.id)
        #expect(session.deeper?.stage == .writingQuestion)
        #expect(session.currentSourceTitle == "Mitochondria", "the heading names the panel's card, not the next one")

        await session.waitForDeeper()
        #expect(session.deeper?.stage == .asking(question))
        #expect(session.deeper?.takesAnswer == true)
        #expect(stub.partnerSources == ["src-1"])
        let request = try #require(stub.questionRequests.first)
        #expect(request.front == card.front && request.back == card.back && request.sourceTitle == "Mitochondria")
        #expect(request.kinds == [.principle, .transfer, .falsify], "no partner: no analogy")
        #expect(stub.questionCardIDs == [item.id])

        // The answer the same way Remembered writes it.
        await session.waitForWrites()
        let attempts = try await storage.loadMemoryAttempts(memoryItemID: item.id)
        #expect(attempts.count == 1)
        #expect(attempts.first?.id == MemoryTutorIdentity.selfGradedAttemptID(sessionKey: "cards-deeper-1", memoryItemID: item.id))
        #expect(attempts.first?.scheduleRating == .good)

        // Return sends; the reply comes under it.
        stub.reply = .success("It names the gradient; it could add what spends it.")
        session.sendDeeperAnswer()
        #expect(session.deeper?.stage == .asking(question), "an empty answer is not sent")
        session.deeperDraft = "  Stored energy is spent where it is needed.  "
        session.sendDeeperAnswer()
        #expect(session.deeperDraft.isEmpty)
        #expect(session.deeper?.stage == .replying(question, answer: "Stored energy is spent where it is needed."))
        #expect(session.deeper?.takesAnswer == false)
        await session.waitForDeeper()
        #expect(session.deeper?.stage == .replied(question, answer: "Stored energy is spent where it is needed.",
                                                 reply: "It names the gradient; it could add what spends it."))
        #expect(stub.replyRequests.first?.question == question)
        #expect(stub.replyRequests.first?.answer == "Stored energy is spent where it is needed.")

        // Next Card: the panel goes, the next card is on screen.
        session.leaveDeeper()
        #expect(session.deeper == nil)
        #expect(session.sitting.current?.itemID == "next-card")
        #expect(!session.sitting.isAnswerShown)
    }

    @Test("Go Deeper's kinds rotate across the sitting, the analogy offered with its partner only when there is one")
    func goDeeperRotates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MemoryCardDeeperRotation_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = GoDeeperStub()
        let partner = Probe.AnalogyPartner(sourceID: "far", sourceTitle: "Cities as organisms", notebookTitle: "Urbanism", statement: "Cities scale sublinearly.")
        stub.partner = partner
        stub.question = .success(Probe.CardQuestion(kind: .transfer, text: "Where else does this hold?"))
        let session = deeperSession(cards: 3, stub: stub, root: root)

        session.showAnswer(attempt: "An answer")
        session.goDeeper()
        await session.waitForDeeper()
        #expect(stub.questionRequests[0].kinds == [.principle, .transfer, .falsify, .analogy])
        #expect(stub.questionRequests[0].partner == partner)
        #expect(session.deeper?.partner == partner)
        session.leaveDeeper()

        // The writer chose transfer; the next card starts after it.
        stub.partner = nil
        session.showAnswer(attempt: "An answer")
        session.goDeeper()
        await session.waitForDeeper()
        #expect(stub.questionRequests[1].kinds == [.falsify, .principle, .transfer])
        #expect(stub.questionRequests[1].partner == nil)
        #expect(stub.partnerSources == ["src-1", "src-2"])
        session.leaveDeeper()

        // Next Card while the question is still being written drops it.
        session.showAnswer(attempt: "An answer")
        session.goDeeper()
        session.leaveDeeper()
        for _ in 0..<5 { await Task.yield() }
        #expect(session.deeper == nil)
        #expect(session.sitting.isRoundOver)
    }

    @Test("A question or a reply that fails is said under the panel, with nothing of the app's own in its place, and Next Card still goes on")
    func goDeeperFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MemoryCardDeeperFailure_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = GoDeeperStub()
        stub.question = .failure(GoDeeperStubFailure(message: "The model is not answering."))
        let session = deeperSession(cards: 3, stub: stub, root: root)

        session.showAnswer(attempt: "An answer")
        session.goDeeper()
        await session.waitForDeeper()
        #expect(session.deeper?.stage == .noQuestion)
        #expect(session.deeper?.question == nil)
        #expect(session.deeper?.failure == "The question could not be written. The model is not answering.")
        session.leaveDeeper()
        #expect(session.sitting.current?.itemID == "card-2")

        // A reply that fails puts the answer back to send again.
        let question = Probe.CardQuestion(kind: .falsify, text: "What result would break it?")
        stub.question = .success(question)
        stub.reply = .failure(GoDeeperStubFailure(message: "The model is not answering."))
        session.showAnswer(attempt: "An answer")
        session.goDeeper()
        await session.waitForDeeper()
        session.deeperDraft = "A gradient that does not form."
        session.sendDeeperAnswer()
        await session.waitForDeeper()
        #expect(session.deeper?.stage == .asking(question))
        #expect(session.deeper?.failure == "The reply could not be written. The model is not answering.")
        #expect(session.deeperDraft == "A gradient that does not form.")
        stub.reply = .success("It names the test; it could say what the gradient would show.")
        session.sendDeeperAnswer()
        await session.waitForDeeper()
        #expect(session.deeper?.failure == nil)
        if case .replied = session.deeper?.stage {} else { Issue.record("the reply did not arrive on the second send") }
        session.leaveDeeper()

        // A bare fact fits no kind: said in one line, no failure.
        stub.question = .success(nil)
        session.showAnswer(attempt: "An answer")
        session.goDeeper()
        await session.waitForDeeper()
        #expect(session.deeper?.stage == .noQuestion)
        #expect(session.deeper?.failure == nil)
        session.leaveDeeper()
        #expect(session.sitting.isRoundOver)
    }

    @Test("A card review made without Go Deeper's steps offers none")
    func goDeeperNeedsSteps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MemoryCardNoDeeper_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = MemoryCardSessionModel(
            sitting: MemoryCardSitting(key: "cards-no-deeper", kind: .today, cards: [MemoryCardSitting.Card(itemID: "a", prompt: "Q", back: "A")]),
            scope: .allNotebooks,
            scopeTitle: "All notebooks",
            isCommitted: false,
            sourceTitles: [:],
            storage: StorageService(storeRoot: root),
            followup: { .init(cards: [], dayHasCardsLeft: true) }
        )
        #expect(!session.offersGoDeeper)
        session.showAnswer(attempt: "An answer")
        session.goDeeper()
        #expect(session.deeper == nil)
        #expect(session.sitting.cardNumber == 1, "nothing was answered")
    }
}

/// Go Deeper's steps, stubbed: what each was asked, and what it answers.
@MainActor
private final class GoDeeperStub {
    var partner: MemoryUnderstandingProbe.AnalogyPartner?
    var question: Result<MemoryUnderstandingProbe.CardQuestion?, Error> = .success(nil)
    var reply: Result<String, Error> = .success("")
    private(set) var partnerSources: [String] = []
    private(set) var questionRequests: [MemoryUnderstandingProbe.CardQuestionRequest] = []
    private(set) var questionCardIDs: [String] = []
    private(set) var replyRequests: [MemoryUnderstandingProbe.CardReplyRequest] = []

    var steps: MemoryCardSessionModel.DeeperSteps {
        MemoryCardSessionModel.DeeperSteps(
            partner: { [unowned self] sourceID in
                self.partnerSources.append(sourceID)
                return self.partner
            },
            question: { [unowned self] request, cardID in
                self.questionRequests.append(request)
                self.questionCardIDs.append(cardID)
                return try self.question.get()
            },
            reply: { [unowned self] request, _ in
                self.replyRequests.append(request)
                return try self.reply.get()
            }
        )
    }
}

private struct GoDeeperStubFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A mutable cell a `@MainActor` closure can append to.
@MainActor
private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
