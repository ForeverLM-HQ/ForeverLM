import Foundation
import Testing
@testable import ForeverLM

@Suite("Studio chat background generation")
@MainActor
struct StudioAssistantSessionStoreTests {
    @Test("Generation preparation is visible and remains leased until every owner finishes")
    func generationPreparationIsVisible() {
        let manager = ReviewSessionManager()

        manager.beginGenerationPreparation()
        manager.beginGenerationPreparation()
        #expect(manager.isPreparingGeneration)
        #expect(manager.hasGenerationWorkInFlight)

        manager.endGenerationPreparation()
        #expect(manager.isPreparingGeneration)

        manager.endGenerationPreparation()
        #expect(!manager.isPreparingGeneration)
        #expect(!manager.hasGenerationWorkInFlight)
    }

    @Test("A send during a turn is queued, not appended, and Stop hands it back")
    func sendDuringTurnIsQueued() {
        let manager = ReviewSessionManager()
        #expect(!manager.queuesSendsNow)

        // The panel holds the preparation lease across the whole turn, and the
        // streaming flag rides inside it; either alone means "queue this".
        manager.beginGenerationPreparation()
        #expect(manager.queuesSendsNow)
        manager.endGenerationPreparation()
        manager.isGenerating = true
        #expect(manager.queuesSendsNow)

        let first = manager.enqueueFollowUp("the ones that are published", contextualContent: "passage")
        let second = manager.enqueueFollowUp("and the preprints")
        #expect(manager.enqueueFollowUp("   ") == nil)
        #expect(manager.queuedFollowUps.map(\.text) == ["the ones that are published", "and the preprints"])
        #expect(manager.queuedFollowUps.first?.contextualContent == "passage")
        // A queued message is not a transcript turn: it must never ride into the
        // running reply's next provider round.
        #expect(manager.chatMessages.isEmpty)

        // Waiting messages keep the composer queueing after the turn ends, so a
        // third send lands behind them rather than jumping the line.
        manager.isGenerating = false
        #expect(manager.queuesSendsNow)

        #expect(manager.removeQueuedFollowUp(second!.id)?.text == "and the preprints")
        #expect(manager.removeQueuedFollowUp(second!.id) == nil)
        #expect(manager.queuedFollowUps.map(\.id) == [first!.id])

        let returned = manager.takeQueuedFollowUps()
        #expect(returned.map(\.text) == ["the ones that are published"])
        #expect(manager.queuedFollowUps.isEmpty)
        #expect(!manager.queuesSendsNow)
    }

    @Test("Send now moves a queued message to the head of the queue and keeps the rest waiting")
    func sendNowJumpsTheQueue() async {
        let manager = ReviewSessionManager()
        manager.isGenerating = true
        manager.canStopGeneration = true
        let first = manager.enqueueFollowUp("first")!
        let second = manager.enqueueFollowUp("second")!
        let third = manager.enqueueFollowUp("third")!

        await manager.sendQueuedFollowUpNow(second.id)
        // The chosen message goes next; the others keep their order behind it.
        // Nothing goes back to the composer: this is not Stop.
        #expect(manager.queuedFollowUps.map(\.id) == [second.id, first.id, third.id])
        #expect(manager.queuesSendsNow)

        // An id that is not queued changes nothing.
        await manager.sendQueuedFollowUpNow(UUID())
        #expect(manager.queuedFollowUps.map(\.id) == [second.id, first.id, third.id])

        // Already at the head: the order stands.
        await manager.sendQueuedFollowUpNow(second.id)
        #expect(manager.queuedFollowUps.map(\.id) == [second.id, first.id, third.id])
    }

    @Test("Only work outside a turn holds the composer")
    func busyOutsideTurnHoldsComposer() {
        let manager = ReviewSessionManager()
        #expect(!manager.isBusyOutsideTurn)

        // Hydrating a saved chat or attaching sources: no turn to queue behind.
        manager.isSearching = true
        #expect(manager.isBusyOutsideTurn)

        // The same flag during a turn's own source lookup is part of the turn.
        manager.beginGenerationPreparation()
        #expect(!manager.isBusyOutsideTurn)
        #expect(manager.queuesSendsNow)
        manager.endGenerationPreparation()
        manager.isGenerating = true
        #expect(!manager.isBusyOutsideTurn)
        manager.isGenerating = false
        manager.isSearching = false
        #expect(!manager.isBusyOutsideTurn)
    }

    @Test("A comparison pane owns its resume request")
    func comparisonPaneResumeRequest() {
        let store = StudioAssistantSessionStore(managerFactory: { ReviewSessionManager() })

        store.requestOpen(sessionID: "chat-two")
        #expect(store.requestedSessionID == "chat-two")

        store.didConsumeOpenRequest(sessionID: "another-chat")
        #expect(store.requestedSessionID == "chat-two")

        store.didConsumeOpenRequest(sessionID: "chat-two")
        #expect(store.requestedSessionID == nil)
    }

    @Test("Opening another chat parks the generating manager")
    func openingAnotherChatKeepsGenerationAlive() {
        let store = StudioAssistantSessionStore(managerFactory: { ReviewSessionManager() })
        let first = store.activeManager
        first.configureNavigationStateForTesting(sessionID: "chat-one", generationInFlight: true)

        guard case .switched = store.prepareToOpen(sessionID: "chat-two") else {
            Issue.record("Opening another chat did not switch managers")
            return
        }

        #expect(store.activeManager !== first)
        #expect(store.backgroundManagersForTesting.contains { $0 === first })
        #expect(first.hasGenerationWorkInFlight)
        #expect(store.isRunning(sessionID: "chat-one"))
    }

    @Test("Returning to a background chat restores its live manager")
    func returningToBackgroundChatRestoresLiveManager() {
        let store = StudioAssistantSessionStore(managerFactory: { ReviewSessionManager() })
        let first = store.activeManager
        first.configureNavigationStateForTesting(sessionID: "chat-one", generationInFlight: true)
        _ = store.prepareToOpen(sessionID: "chat-two")

        let second = store.activeManager
        second.configureNavigationStateForTesting(sessionID: "chat-two", generationInFlight: true)
        guard case .switched = store.prepareToOpen(sessionID: "chat-one") else {
            Issue.record("Returning to the running chat did not switch managers")
            return
        }

        #expect(store.activeManager === first)
        #expect(store.backgroundManagersForTesting.contains { $0 === second })
        #expect(first.hasGenerationWorkInFlight)
        #expect(second.hasGenerationWorkInFlight)
    }

    /// A draft archive on a defaults domain of its own: the unit host's
    /// standard defaults are the app's real ones.
    static func isolatedDrafts() -> ChatDraftArchive {
        let suite = "StudioAssistantSessionStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return ChatDraftArchive(defaults: defaults)
    }

    @Test("An unsent draft survives a trip to another chat")
    func unsentDraftIsKeptPerScope() {
        let store = StudioAssistantSessionStore(managerFactory: { ReviewSessionManager() }, drafts: Self.isolatedDrafts())

        store.setDraft("what was the session 7 weeks ago about?", for: .newChat(notebookID: "acme-nexus"))
        store.setDraft("half a question", for: .session("chat-one"))

        #expect(store.draft(for: .newChat(notebookID: "acme-nexus")) == "what was the session 7 weeks ago about?")
        #expect(store.draft(for: .session("chat-one")) == "half a question")
        // A New chat in another Notebook, and the unlinked one, are their own composers.
        #expect(store.draft(for: .newChat(notebookID: "other")).isEmpty)
        #expect(store.draft(for: .newChat(notebookID: nil)).isEmpty)

        store.setDraft("", for: .newChat(notebookID: "acme-nexus"))
        #expect(store.draft(for: .newChat(notebookID: "acme-nexus")).isEmpty)
    }

    @Test("Unlinking a Notebook carries the draft to the unlinked composer")
    func draftFollowsNotebookUnlink() {
        let store = StudioAssistantSessionStore(managerFactory: { ReviewSessionManager() }, drafts: Self.isolatedDrafts())
        store.setDraft("typed before unlinking", for: .newChat(notebookID: "acme-nexus"))

        store.moveDraft(from: .newChat(notebookID: "acme-nexus"), to: .newChat(notebookID: nil))

        #expect(store.draft(for: .newChat(notebookID: "acme-nexus")).isEmpty)
        #expect(store.draft(for: .newChat(notebookID: nil)) == "typed before unlinking")
    }

    @Test("Deleting a chat drops the draft it was holding")
    func deletingChatDropsItsDraft() {
        let store = StudioAssistantSessionStore(managerFactory: { ReviewSessionManager() }, drafts: Self.isolatedDrafts())
        store.activeManager.configureNavigationStateForTesting(sessionID: "chat-one", generationInFlight: false)
        store.setDraft("never sent", for: .session("chat-one"))
        store.setDraft("still mine", for: .newChat(notebookID: nil))

        store.deleteSession("chat-one")

        #expect(store.draft(for: .session("chat-one")).isEmpty)
        #expect(store.draft(for: .newChat(notebookID: nil)) == "still mine")
    }

    @Test("New chat does not stop the current generation")
    func newChatKeepsCurrentGenerationAlive() {
        let store = StudioAssistantSessionStore(managerFactory: { ReviewSessionManager() })
        let running = store.activeManager
        running.configureNavigationStateForTesting(sessionID: "chat-one", generationInFlight: true)
        let requestID = UUID()

        #expect(store.prepareForNewChat(requestID: requestID))
        #expect(store.activeManager !== running)
        #expect(store.backgroundManagersForTesting.contains { $0 === running })
        #expect(running.hasGenerationWorkInFlight)
        #expect(!store.prepareForNewChat(requestID: requestID))
    }

    @Test("A Reader selection joins only an idle composer; any conversation leaves it to a new chat")
    func readerSelectionJoinsOnlyAnIdleComposer() {
        let store = StudioAssistantSessionStore(managerFactory: { ReviewSessionManager() })
        let passage = ReaderSelectionExplanationRequest(sourceID: "paper-a", selectedText: "a closed control loop")

        // An idle composer takes the passage, whatever it has staged.
        #expect(!store.activeManager.hasConversation)
        #expect(!store.readerSelectionOpensNewChat(for: passage))
        store.activeManager.attachSourceIDsForTesting(["paper-a"])
        #expect(!store.readerSelectionOpensNewChat(for: passage))

        // A conversation — even one about the passage's own paper — is left
        // as it is (2026-09-23: "the chat it opens should be a new chat").
        store.activeManager.configureNavigationStateForTesting(sessionID: "chat-a", generationInFlight: false)
        #expect(store.activeManager.hasConversation)
        #expect(store.readerSelectionOpensNewChat(for: passage))

        // A running turn parks rather than joins: the decision is the same.
        store.activeManager.configureNavigationStateForTesting(sessionID: "chat-a", generationInFlight: true)
        #expect(store.readerSelectionOpensNewChat(for: passage))
    }

    @Test("A walk takes a Reader passage only from what it walks; a passage from any other source opens a new chat")
    func readerSelectionDuringAWalk() {
        let store = StudioAssistantSessionStore(managerFactory: { ReviewSessionManager() })
        let talk = StudioArticle(url: "https://example.com/talk", title: "Talk", sourceType: .article, discoveryOrigin: .manual)
        store.activeManager.walkthroughPlayback = ReviewSessionManager.WalkthroughPlayback(
            subject: .source(talk),
            walkthrough: PaperWalkthrough(
                sourceID: talk.id,
                sourceSHA256: "x",
                title: "W",
                steps: [PaperWalkthroughStep(id: "step-1", kind: .explain, title: "S", body: "B.")],
                author: .app
            ),
            currentIndex: 0,
            // Nothing dealt, so setting it writes no progress anywhere.
            playedStepIDs: []
        )
        // Dealing a walk's cards makes no chat, so the walk is no
        // conversation — and yet it is not an idle composer.
        #expect(!store.activeManager.hasConversation)

        // 2026-09-29: a passage from a paper went under the card of a walk
        // through an unrelated talk.
        let otherPaper = ReaderSelectionExplanationRequest(sourceID: "paper-b", selectedText: "Four properties make mitochondria a tractable place")
        #expect(store.readerSelectionOpensNewChat(for: otherPaper))
        // A passage from the walked source is a question about the card.
        let walked = ReaderSelectionExplanationRequest(sourceID: talk.id, selectedText: "his phase detector")
        #expect(!store.readerSelectionOpensNewChat(for: walked))
        // What's New is research, never a turn of the walk.
        let research = ReaderSelectionExplanationRequest(
            sourceID: talk.id,
            selectedText: "his phase detector",
            researchUpdate: ReaderResearchUpdate(highlightID: "mark-1", sourceDescription: "Talk")
        )
        #expect(store.readerSelectionOpensNewChat(for: research))

        // A question asked on a card gives the walk a chat; the rule holds.
        store.activeManager.configureNavigationStateForTesting(sessionID: "walk-chat", generationInFlight: false)
        #expect(store.readerSelectionOpensNewChat(for: otherPaper))
        #expect(!store.readerSelectionOpensNewChat(for: walked))

        // With the walk left, the chat it made is an ordinary conversation.
        store.activeManager.leaveWalkthroughPlayback()
        #expect(store.readerSelectionOpensNewChat(for: walked))
    }

    @Test("A chat still opening in the pane sends a Reader selection to a new chat, and gives way to it")
    func readerSelectionSupersedesAChatStillOpening() {
        let store = StudioAssistantSessionStore(managerFactory: { ReviewSessionManager() })
        let request = ReaderSelectionExplanationRequest(sourceID: "article-b", selectedText: "a closed control loop")

        // A relaunch asks for the window's last chat while Chat is off
        // screen; the idle composer in front of it is not the place for the
        // passage (2026-09-26, a passage landed in the morning's chat).
        store.requestOpen(sessionID: "chat-a")
        #expect(!store.activeManager.hasConversation)
        #expect(store.readerSelectionOpensNewChat(for: request))
        store.requestNewChat(handingOff: request)
        #expect(store.requestedSessionID == nil)
        #expect(!store.readerSelectionOpensNewChat(for: request))

        // The pane had already started hydrating it: the new chat gets a
        // manager of its own, and the half-loaded one is let go.
        store.requestOpen(sessionID: "chat-a")
        #expect(store.prepareToOpen(sessionID: "chat-a") == .switched)
        let hydrating = store.activeManager
        #expect(store.readerSelectionOpensNewChat(for: request))
        store.requestNewChat(handingOff: request)
        let handoffID = store.pendingNewChatHandoff!.id
        #expect(store.prepareForNewChat(requestID: handoffID))
        #expect(store.activeManager !== hydrating)
        #expect(!store.backgroundManagersForTesting.contains { $0 === hydrating })
        #expect(!store.prepareForNewChat(requestID: handoffID))
        #expect(!store.readerSelectionOpensNewChat(for: request))
    }

    @Test("Walk Through joins only an empty chat or the walk's own; a chat still opening in the pane counts as a conversation and gives way")
    func walkThroughOpensNewChatOverAnyOtherConversation() {
        let store = StudioAssistantSessionStore(managerFactory: { ReviewSessionManager() })
        let walked = "paper-a"

        // An empty chat takes the walk.
        #expect(!store.walkthroughOpensNewChat(of: walked))

        // 2026-09-30: a relaunch asked for the window's last chat while Chat
        // was behind another tab; Walk Through brought the pane up, met an
        // empty chat, and that chat landed under the walk's card.
        store.requestOpen(sessionID: "chat-markov")
        #expect(!store.activeManager.hasConversation)
        #expect(store.walkthroughOpensNewChat(of: walked))
        store.requestNewChat(playingWalkthroughOf: walked)
        #expect(store.requestedSessionID == nil)
        #expect(store.pendingNewChatHandoff?.walkthroughSourceID == walked)
        #expect(!store.walkthroughOpensNewChat(of: walked))

        // The pane had already started hydrating it: the walk's chat gets a
        // manager of its own.
        store.requestOpen(sessionID: "chat-markov")
        #expect(store.prepareToOpen(sessionID: "chat-markov") == .switched)
        let hydrating = store.activeManager
        #expect(store.walkthroughOpensNewChat(of: walked))
        store.requestNewChat(playingWalkthroughOf: walked)
        let handoffID = store.pendingNewChatHandoff!.id
        #expect(store.prepareForNewChat(requestID: handoffID))
        #expect(store.activeManager !== hydrating)
        #expect(!store.walkthroughOpensNewChat(of: walked))

        // A chat reopened from the pane's own list hydrates this manager
        // without asking the store; it is on its way in all the same.
        store.activeManager.isResumingSession = true
        #expect(store.walkthroughOpensNewChat(of: walked))
        store.activeManager.isResumingSession = false

        // A conversation the walk is no part of is left as it is.
        store.activeManager.configureNavigationStateForTesting(sessionID: "chat-markov", generationInFlight: false)
        store.activeManager.chatMessages = [.init(role: .user, content: "Can you search the term Markov blanket across all my sources?")]
        #expect(store.walkthroughOpensNewChat(of: walked))

        // The walk's own chat, holding one of its cards, takes it again.
        let card = WalkthroughStepTurn.Marker(sourceID: walked, stepID: "step-11", index: 10, count: 40)
        store.activeManager.chatMessages.insert(.init(role: .assistant, content: "The constructor's physics lies outside the logic of the tape.", walkthroughStep: card), at: 0)
        #expect(!store.walkthroughOpensNewChat(of: walked))
        #expect(store.walkthroughOpensNewChat(of: "paper-b"))
    }

    @Test("A Doc's passage joins only a conversation already working on that Doc; anything else gets its new chat")
    func docPassageJoinsOnlyAChatWorkingOnItsDoc() {
        let store = StudioAssistantSessionStore(managerFactory: { ReviewSessionManager() })
        let doc = ChatDocAttachment(id: "doc-a", title: "Engineered human resilience", revision: "r1", outline: ["Summary"])
        let nextSection = ReaderSelectionExplanationRequest(
            sourceIDs: [],
            selectedText: "Inhibition is bounded by the druggable targets a human genome encodes",
            contextTitle: "Note: Engineered human resilience — Summary",
            artifactID: doc.id,
            artifactRevision: doc.revision,
            artifactAttachment: doc,
            sectionTitle: "Summary"
        )

        // An idle composer holding the Doc is no conversation: the passage
        // gets the new chat it asked for, filed the way a Doc's chat is.
        store.activeManager.addContextDoc(doc)
        #expect(!store.activeManager.hasConversation)
        #expect(!store.docPassageJoinsOpenChat(nextSection, linkedDocIDs: []))

        // 2026-09-29: the chat rewriting the Doc's first section, its turn
        // still running, takes the next section.
        store.activeManager.configureNavigationStateForTesting(sessionID: "chat-a", generationInFlight: true)
        #expect(store.docPassageJoinsOpenChat(nextSection, linkedDocIDs: []))

        // Another Doc's passage opens a new chat, unless one of its passages
        // already started or joined this chat (a reopened chat holds no docs).
        let otherDoc = ReaderSelectionExplanationRequest(
            sourceIDs: [],
            selectedText: "Small-molecule drug discovery is built around suppression",
            contextTitle: "Note: Mito company ideas",
            artifactID: "doc-b",
            artifactRevision: "r7"
        )
        #expect(!store.docPassageJoinsOpenChat(otherDoc, linkedDocIDs: []))
        #expect(store.docPassageJoinsOpenChat(otherDoc, linkedDocIDs: ["doc-b"]))

        // A passage from a paper is not a Doc's and keeps its own rule.
        let paper = ReaderSelectionExplanationRequest(sourceID: "doc-a", selectedText: "a closed control loop")
        #expect(!store.docPassageJoinsOpenChat(paper, linkedDocIDs: ["doc-a"]))

        // A chat still on its way into the pane is where the passage would
        // land: it gets its new chat.
        store.requestOpen(sessionID: "chat-b")
        #expect(!store.docPassageJoinsOpenChat(nextSection, linkedDocIDs: ["doc-a"]))
        store.didConsumeOpenRequest(sessionID: "chat-b")
        #expect(store.docPassageJoinsOpenChat(nextSection, linkedDocIDs: []))

        // A walk never takes a Doc's passage.
        let talk = StudioArticle(url: "https://example.com/talk", title: "Talk", sourceType: .article, discoveryOrigin: .manual)
        store.activeManager.walkthroughPlayback = ReviewSessionManager.WalkthroughPlayback(
            subject: .source(talk),
            walkthrough: PaperWalkthrough(
                sourceID: talk.id,
                sourceSHA256: "x",
                title: "W",
                steps: [PaperWalkthroughStep(id: "step-1", kind: .explain, title: "S", body: "B.")],
                author: .app
            ),
            currentIndex: 0,
            playedStepIDs: []
        )
        #expect(!store.docPassageJoinsOpenChat(nextSection, linkedDocIDs: ["doc-a"]))
    }

    @Test("A first turn still on its way already makes the chat a conversation")
    func firstTurnInFlightIsAConversation() {
        let manager = ReviewSessionManager()
        manager.attachSourceIDsForTesting(["paper-a"])
        #expect(!manager.hasConversation)

        // The row is not written until the reply lands, but the learner's
        // words are in the transcript: a passage from another paper must not
        // ride into this chat's first reply.
        manager.chatMessages = [.init(role: .user, content: "What does this paper claim?")]
        #expect(manager.hasConversation)
    }

    @Test("Only a source passage is judged against the open chat; docs, reviews and quizzes already asked for a fresh chat")
    func onlyReaderSelectionsAreJudged() {
        #expect(ReaderSelectionExplanationRequest(sourceID: "paper-b", selectedText: "a passage").isReaderSelection)
        // Words selected in a reply and handed to the primary Chat carry a
        // context line but no doc and no handoff, so they are judged the same
        // way; by then the chat has been reset, so they stay in place.
        #expect(
            ReaderSelectionExplanationRequest(
                sourceIDs: ["paper-a"], selectedText: "a passage", contextTitle: "A reply in another chat"
            ).isReaderSelection
        )
        #expect(
            !ReaderSelectionExplanationRequest(
                sourceIDs: ["paper-a"], selectedText: "a passage", contextTitle: "Note: Draft",
                artifactID: "doc-1", artifactRevision: "r1"
            ).isReaderSelection
        )
    }

    @Test("A dismissed comparison pane no longer highlights its chat in the rail")
    func dismissedComparisonPaneReleasesRailHighlight() {
        let withPane = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader], activeTab: .chat),
            .init(tabs: [.secondaryChat], activeTab: .secondaryChat),
        ])
        #expect(
            StudioNavigationRail.highlightedSessionIDs(primary: "chat-one", comparison: "chat-two", layout: withPane)
                == ["chat-one", "chat-two"]
        )

        let withoutPane = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .reader], activeTab: .chat),
            .init(tabs: [.notepad], activeTab: .notepad),
        ])
        #expect(
            StudioNavigationRail.highlightedSessionIDs(primary: "chat-one", comparison: "chat-two", layout: withoutPane)
                == ["chat-one"]
        )
        #expect(
            StudioNavigationRail.highlightedSessionIDs(primary: nil, comparison: "chat-two", layout: withoutPane)
                .isEmpty
        )
    }

    @Test("Opening Docs over the chat releases the chat's rail highlight")
    func hiddenChatTabReleasesRailHighlight() {
        // The chat was open; Docs then replaced it as its pane's active tab.
        // The Chat tab is still in the layout, but nothing on screen is the
        // chat, so its row must not stay selected next to the Docs row.
        let docsOverChat = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .notepad], activeTab: .notepad),
            .init(tabs: [.reader], activeTab: .reader),
        ])
        #expect(
            StudioNavigationRail.highlightedSessionIDs(primary: "chat-one", comparison: nil, layout: docsOverChat)
                .isEmpty
        )
        #expect(!StudioNavigationRail.isChatVisible(layout: docsOverChat, chatPoppedOut: false))

        // A popped-out chat window still shows the chat, so the row keeps the
        // highlight even while the docked Chat tab is hidden behind Docs.
        #expect(
            StudioNavigationRail.highlightedSessionIDs(
                primary: "chat-one", comparison: nil, layout: docsOverChat, chatPoppedOut: true
            ) == ["chat-one"]
        )

        // Bringing Chat back as the active tab restores the highlight.
        let chatBack = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat, .notepad], activeTab: .chat),
            .init(tabs: [.reader], activeTab: .reader),
        ])
        #expect(
            StudioNavigationRail.highlightedSessionIDs(primary: "chat-one", comparison: nil, layout: chatBack)
                == ["chat-one"]
        )

        // A comparison pane whose tab is present but not active is hidden
        // the same way, and its chat's row follows the same rule.
        let hiddenComparison = StudioCenterTabGroups(groups: [
            .init(tabs: [.chat], activeTab: .chat),
            .init(tabs: [.secondaryChat, .notepad], activeTab: .notepad),
        ])
        #expect(
            StudioNavigationRail.highlightedSessionIDs(
                primary: "chat-one", comparison: "chat-two", layout: hiddenComparison
            ) == ["chat-one"]
        )
    }
}

@Suite("The page's side chat")
@MainActor
struct PageSideChatTests {
    private func session(
        _ id: String,
        title: String = "A chat",
        hidden: Bool = false,
        team: String? = nil
    ) -> ReviewSessionRecord {
        ReviewSessionRecord(
            id: id,
            title: title,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            status: "active",
            sourceIDs: [],
            teamID: team,
            hiddenAt: hidden ? Date(timeIntervalSinceReferenceDate: 200) : nil
        )
    }

    private func link(_ id: String, session: ReviewSessionRecord, at seconds: Double) -> ArtifactChatLink {
        ArtifactChatLink(
            link: ArtifactChatLinkRecord(
                id: id,
                artifactID: "page-a",
                sessionID: session.id,
                anchorRevision: "r1",
                anchorStart: 0,
                anchorEnd: 0,
                anchorQuote: "words",
                sectionTitle: "",
                createdAt: Date(timeIntervalSinceReferenceDate: seconds)
            ),
            session: session
        )
    }

    private func opening(passage: ReaderSelectionExplanationRequest? = nil, draft: String? = nil) -> PageSideChatOpening {
        PageSideChatOpening(
            page: PageSideChatPage(
                artifactID: "page-a",
                title: "Mito ideas",
                revision: "r7",
                notebookID: "notebook-1",
                attachment: ChatDocAttachment(id: "page-a", title: "Mito ideas", revision: "r7", outline: ["Intro"])
            ),
            sourceIDs: ["paper-a", "paper-b"],
            passage: passage,
            draft: draft
        )
    }

    @Test("The page's chats list once each, newest link first, without hidden or team transcripts")
    func chatsListUnderAPage() {
        let first = session("chat-1", title: "First")
        let second = session("chat-2", title: "Second")
        let hidden = session("chat-3", hidden: true)
        let team = session("chat-4", team: "team-1")
        let links = [
            link("l1", session: first, at: 10),
            // The same chat asked about a second passage later: one row, and
            // its newest link places it.
            link("l2", session: first, at: 40),
            link("l3", session: second, at: 30),
            link("l4", session: hidden, at: 50),
            link("l5", session: team, at: 60),
        ]
        #expect(PageSideChatChats.sessions(from: links).map(\.id) == ["chat-1", "chat-2"])
        #expect(PageSideChatChats.sessions(from: []).isEmpty)
        #expect(PageSideChatChats.title(of: session("c", title: "  ")) == "Untitled chat")
        #expect(PageSideChatChats.title(of: session("c", title: " Mito ")) == "Mito")
    }

    @Test("A chat about the whole page links to it by its name, at no position")
    func wholePageAnchor() {
        let page = opening().page
        let anchor = page.wholePageAnchor
        #expect(anchor.artifactID == "page-a")
        #expect(anchor.artifactRevision == "r7")
        #expect(anchor.quote == "Mito ideas")
        #expect(anchor.selectionStart == 0 && anchor.selectionEnd == 0)
        #expect(anchor.sectionTitle.isEmpty)

        var unnamed = page
        unnamed.title = "  "
        #expect(unnamed.wholePageAnchor.quote == "Untitled page")
    }

    @Test("The card is 440 at the chat's zoom, kept 16 off a narrow pane, and its transcript is 60% of the pane less the chrome")
    func cardMeasurements() {
        #expect(PageSideChatLayout.width(wanted: 440, paneWidth: 1_000) == 440)
        #expect(PageSideChatLayout.width(wanted: 440, paneWidth: 300) == 268)
        #expect(PageSideChatLayout.width(wanted: 440, paneWidth: 0) == 440)
        #expect(ReviewChatSideChatPopover.width(zoom: 1) == 440)

        #expect(PageSideChatLayout.transcriptHeight(paneHeight: 1_000, zoom: 1) == 450)
        // A short pane keeps a readable transcript rather than none.
        #expect(PageSideChatLayout.transcriptHeight(paneHeight: 300, zoom: 1) == 160)
        #expect(PageSideChatLayout.transcriptHeight(paneHeight: 0, zoom: 1) == 160)
        #expect(PageSideChatLayout.transcriptHeight(paneHeight: 1_000, zoom: 1.2) == 420)
    }

    @Test("The card's grip docks it on the side a drag points to past a third of the page, and only there")
    func dockAfterDrag() {
        #expect(PageSideChatDock.right.afterDrag(translation: -400, paneWidth: 900) == .left)
        #expect(PageSideChatDock.right.afterDrag(translation: -200, paneWidth: 900) == .right)
        #expect(PageSideChatDock.right.afterDrag(translation: 400, paneWidth: 900) == .right)
        #expect(PageSideChatDock.left.afterDrag(translation: 301, paneWidth: 900) == .right)
        #expect(PageSideChatDock.left.afterDrag(translation: -500, paneWidth: 900) == .left)
        // A narrow or unmeasured pane still needs a real drag, never a twitch.
        #expect(PageSideChatDock.right.afterDrag(translation: -60, paneWidth: 0) == .right)
        #expect(PageSideChatDock.right.afterDrag(translation: -81, paneWidth: 0) == .left)
        #expect(PageSideChatDock.left.alignment == .bottomLeading)
        #expect(PageSideChatDock.key.hasPrefix("studio.movableOverlay."), "where the card sits is this Mac's, never synced")
    }

    @Test("A chat's header says New chat until it has a title of its own")
    func headerTitle() {
        #expect(ChatHeaderTitle.title(sessionTitle: nil, topic: "What is X?", isProvisional: true) == "New chat")
        #expect(ChatHeaderTitle.title(sessionTitle: "What is X?", topic: "What is X?", isProvisional: true) == "New chat")
        #expect(ChatHeaderTitle.title(sessionTitle: "On mitochondria", topic: "What is X?", isProvisional: true) == "On mitochondria")
        #expect(ChatHeaderTitle.title(sessionTitle: nil, topic: " What is X? ", isProvisional: false) == "What is X?")
        #expect(ChatHeaderTitle.title(sessionTitle: "", topic: "", isProvisional: false) == "Untitled chat")
    }

    @Test("A page's passage is quoted with its section, and nothing highlighted is a chat about the page")
    func passageRequest() {
        let request = StudioViewModel.notepadSelectionRequest(
            noteTitle: "Mito ideas",
            sectionTitle: "Intro",
            selectedText: "  a closed \n control loop ",
            sourceIDs: ["paper-a"],
            artifactID: "page-a",
            artifactRevision: "r7",
            artifactNotebookID: "notebook-1",
            selectionRange: 3..<20,
            contextExcerpt: "the section"
        )
        #expect(request?.selectedText == "a closed control loop")
        #expect(request?.contextTitle == "Note: Mito ideas — Intro")
        #expect(request?.artifactID == "page-a")
        #expect(request?.artifactNotebookID == "notebook-1")
        #expect(request?.docAnchor?.quote == "a closed control loop")

        #expect(StudioViewModel.notepadSelectionRequest(
            noteTitle: "Mito ideas",
            selectedText: "   ",
            sourceIDs: [],
            artifactID: "page-a",
            artifactRevision: "r7",
            artifactNotebookID: nil,
            selectionRange: nil,
            contextExcerpt: nil
        ) == nil)
    }

    @Test("An opening reaches the card's store as a new chat with the page, sources and words")
    func openingIsHandedToTheStore() {
        let store = StudioAssistantSessionStore(managerFactory: { ReviewSessionManager() })
        let passage = ReaderSelectionExplanationRequest(
            sourceIDs: ["paper-a", "paper-b"],
            selectedText: "a closed control loop",
            contextTitle: "Note: Mito ideas",
            artifactID: "page-a",
            artifactRevision: "r7"
        )
        let page = opening(passage: passage, draft: "Summarise this")
        store.requestOpen(sessionID: "chat-old")
        store.requestNewChat(opening: page)

        // The later intent: a chat waiting to open gives way to it.
        #expect(store.requestedSessionID == nil)
        let handoff = store.pendingNewChatHandoff
        #expect(handoff?.opening == page)
        #expect(handoff?.request == passage)
        #expect(handoff?.opening?.page.notebookID == "notebook-1")
        #expect(handoff?.opening?.page.attachment?.id == "page-a")
        #expect(handoff?.opening?.sourceIDs == ["paper-a", "paper-b"])
        #expect(handoff?.opening?.draft == "Summarise this")

        // A chat about the whole page quotes nothing.
        store.requestNewChat(opening: opening())
        #expect(store.pendingNewChatHandoff?.request == nil)
        #expect(store.pendingNewChatHandoff?.opening != nil)
    }

    @Test("Letting go of the card's chat parks a running turn and ends an idle one")
    func closingTheCardsChat() {
        let store = StudioAssistantSessionStore(managerFactory: { ReviewSessionManager() })
        let idle = store.activeManager
        idle.configureNavigationStateForTesting(sessionID: "chat-idle", generationInFlight: false)
        store.closeActiveChat()
        #expect(store.activeManager !== idle)
        #expect(idle.currentSessionID == nil)
        #expect(store.activeSessionID == nil)
        #expect(store.backgroundManagersForTesting.isEmpty)

        let running = store.activeManager
        running.configureNavigationStateForTesting(sessionID: "chat-running", generationInFlight: true)
        store.closeActiveChat()
        #expect(store.activeManager !== running)
        #expect(store.backgroundManagersForTesting.contains { $0 === running })
        #expect(running.hasGenerationWorkInFlight)
        #expect(store.isRunning(sessionID: "chat-running"))
    }

    @Test("A docked pane taking the chat the card shows releases it from the card, and no other")
    func dockedPaneTakesTheChat() {
        let store = StudioAssistantSessionStore(managerFactory: { ReviewSessionManager() })
        let shown = store.activeManager
        shown.configureNavigationStateForTesting(sessionID: "chat-one", generationInFlight: false)

        store.releaseChat("chat-two")
        #expect(store.activeManager === shown)
        #expect(store.activeSessionID == "chat-one")

        store.releaseChat("chat-one")
        #expect(store.activeManager !== shown)
        #expect(store.activeSessionID == nil)
    }
}

/// Unsent drafts survive a relaunch, as Codex's composer recovers its drafts.
@Suite("Chat drafts across a relaunch")
@MainActor
struct ChatDraftArchiveTests {
    private func defaults() -> (UserDefaults, String) {
        let suite = "ChatDraftArchiveTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    @Test("A draft written before a quit is there in the next launch's archive")
    func survivesRelaunch() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ChatDraftArchive(defaults: defaults)
        first.set("half a question about LTP", for: .session("chat-one"))
        first.set("in a notebook", for: .newChat(notebookID: "acme-nexus"))
        first.set("", for: .newChat(notebookID: nil))
        first.saveNow()

        let relaunched = ChatDraftArchive(defaults: defaults)
        #expect(relaunched.text(for: .session("chat-one")) == "half a question about LTP")
        #expect(relaunched.text(for: .newChat(notebookID: "acme-nexus")) == "in a notebook")
        #expect(relaunched.text(for: .newChat(notebookID: nil)).isEmpty)

        // Sending empties it, and the next launch has nothing for that chat.
        relaunched.set("", for: .session("chat-one"))
        relaunched.saveNow()
        #expect(ChatDraftArchive(defaults: defaults).text(for: .session("chat-one")).isEmpty)
    }

    @Test("The newest drafts are kept, one per chat, and a giant one is not written")
    func boundedAndNewestLast() {
        var entries: [ChatDraftArchive.Entry] = []
        for index in 0..<(ChatDraftArchive.limit + 5) {
            entries = ChatDraftArchive.updating(entries, scope: "chat:\(index)", text: "draft \(index)")
        }
        #expect(entries.count == ChatDraftArchive.limit)
        #expect(entries.first?.scope == "chat:5")
        entries = ChatDraftArchive.updating(entries, scope: "chat:5", text: "rewritten")
        #expect(entries.last == .init(scope: "chat:5", text: "rewritten"))
        #expect(entries.filter { $0.scope == "chat:5" }.count == 1)

        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let archive = ChatDraftArchive(defaults: defaults)
        let giant = String(repeating: "x", count: ChatDraftArchive.characterLimit + 1)
        archive.set(giant, for: .session("big"))
        archive.set("small", for: .session("small"))
        #expect(archive.text(for: .session("big")) == giant)
        archive.saveNow()
        let relaunched = ChatDraftArchive(defaults: defaults)
        #expect(relaunched.text(for: .session("big")).isEmpty)
        #expect(relaunched.text(for: .session("small")) == "small")
        #expect(ChatDraftArchive.decode(Data("not json".utf8)).isEmpty)
    }
}

/// A long paste is an attachment, as Codex's "Pasted text".
@Suite("Pasted text in the composer")
struct ChatPastedTextTests {
    @Test("What would fold once sent arrives as Pasted text; a short paste stays in the field")
    func threshold() {
        #expect(!ChatPastedText.becomesAttachment("a short question"))
        #expect(ChatPastedText.becomesAttachment(String(repeating: "word ", count: 900)))
        let transcript = (1...40).map { "[00:\($0)] line \($0)" }.joined(separator: "\n")
        #expect(ChatPastedText.becomesAttachment(transcript))
        #expect(ChatPastedText.summary(transcript) == "40 lines")
    }

    @Test("The message carries the words, then each paste; Show in text field puts it after the words")
    func composing() {
        #expect(ChatPastedText.message(typed: "summarize this ", pasted: ["first\npaste", " second "]) ==
            "summarize this\n\nfirst\npaste\n\nsecond")
        #expect(ChatPastedText.message(typed: "  ", pasted: ["only the paste"]) == "only the paste")
        #expect(ChatPastedText.field("", showing: "pasted") == "pasted")
        #expect(ChatPastedText.field("look at", showing: "pasted") == "look at\npasted")
    }
}

/// The queue above the composer, as Codex's.
@Suite("Queued messages above the composer")
@MainActor
struct ChatQueuedMessagesTests {
    @Test("A queued message reads on one line; Delete drops it without touching the rest")
    func oneLineAndDelete() {
        #expect(ReviewChatQueuedMessages.oneLine("first line\n\n  second line ") == "first line second line")
        let manager = ReviewSessionManager()
        let first = manager.enqueueFollowUp("why does LTP need calcium?")
        let second = manager.enqueueFollowUp("and NMDA?")
        #expect(manager.queuedFollowUps.count == 2)
        manager.removeQueuedFollowUp(first!.id)
        #expect(manager.queuedFollowUps.map(\.id) == [second!.id])
    }
}

/// Side chats a split makes: Chat beside a Chat opens a second-chat pane, one
/// store per pane (product owner, 2026-11-07: "just like in a terminal window,
/// we need to be able to have like two things side by side whenever we want").
@Suite("Side chats side by side")
@MainActor
struct StudioSideChatSplitTests {
    private static func makeViewModel() -> StudioViewModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SideChatSplit_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return StudioViewModel(storageService: StorageService(storeRoot: root))
    }

    /// Keeps the developer's synced layout out of the test's rearranging.
    private static func capturedLayout() -> () -> Void {
        let key = "studio.centerTabGroups.v1"
        let prior = UserDefaults.standard.stringArray(forKey: key)
        return {
            if let prior { UserDefaults.standard.set(prior, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    @Test("Chat, the Reader and the Browser split into a side pane, Pages into a copy, and nothing else copies")
    func splitCopies() {
        #expect(StudioCenterTab.chat.splitCopy == .secondaryChat)
        #expect(StudioCenterTab.secondaryChat.splitCopy == .secondaryChat)
        #expect(StudioCenterTab.reader.splitCopy == .secondaryReader)
        #expect(StudioCenterTab.secondaryReader.splitCopy == .secondaryReader)
        #expect(StudioCenterTab.browser.splitCopy == .secondaryBrowser)
        #expect(StudioCenterTab.secondaryBrowser.splitCopy == .secondaryBrowser)
        #expect(StudioCenterTab.notepad.splitCopy == .notepad)
        #expect(StudioCenterTab.library.splitCopy == nil)
    }

    @Test("the split button beside a chat opens side chats up to four panes, and each × closes its own")
    func chatSplitsIntoSideChats() {
        let restore = Self.capturedLayout()
        defer { restore() }
        let vm = Self.makeViewModel()
        let window = vm.activeWindowState
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.artifacts, .chat, .reader], activeTab: .chat, openTabs: [.chat]),
        ])

        vm.splitPane(at: 0, showing: .chat, in: window)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.chat, .secondaryChat])
        let first = vm.centerTabGroups.groups[1].id
        #expect(window.focusedGroupID == first)

        // ⌘\ from the side chat makes another beside it.
        vm.splitFocusedPane(in: window)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.chat, .secondaryChat, .secondaryChat])
        let second = vm.centerTabGroups.groups[2].id

        // A fourth, and no fifth.
        vm.splitFocusedPane(in: window)
        #expect(vm.centerTabGroups.groups.count == 4)
        let third = vm.centerTabGroups.groups[3].id
        vm.splitFocusedPane(in: window)
        #expect(vm.centerTabGroups.groups.count == StudioCenterTabGroups.draggedGroupCount)

        // A side chat's × closes its own pane.
        vm.dismissSecondaryChatPane(fromGroup: second, in: window)
        #expect(vm.centerTabGroups.groups.map(\.id) == [vm.centerTabGroups.groups[0].id, first, third])
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.chat, .secondaryChat, .secondaryChat])
    }

    @Test("Chat open nowhere moves beside rather than making a side chat")
    func parkedChatMovesBeside() {
        let restore = Self.capturedLayout()
        defer { restore() }
        let vm = Self.makeViewModel()
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.artifacts, .chat, .reader], activeTab: .artifacts, openTabs: [.artifacts]),
        ])

        vm.splitPane(at: 0, showing: .chat, in: vm.activeWindowState)

        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.artifacts, .chat])
        #expect(!vm.centerTabGroups.groups.contains { $0.tabs.contains(.secondaryChat) })
    }

    @Test("the Reader splits into a side reader on the same source, and the stored layout leaves it out")
    func readerSplitsIntoSideReader() {
        let restore = Self.capturedLayout()
        defer { restore() }
        let vm = Self.makeViewModel()
        let window = vm.activeWindowState
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.artifacts, .reader, .chat], activeTab: .reader, openTabs: [.reader]),
        ])
        window.readerArticleID = "paper-zeta"

        vm.splitPane(at: 0, showing: .reader, in: window)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.reader, .secondaryReader])
        let side = vm.centerTabGroups.groups[1].id
        #expect(window.sideReaderSources[side] == "paper-zeta")
        // The window's Reader still reads its own source.
        #expect(window.readerArticleID == "paper-zeta")

        // ⌘\ from the side reader starts the next one on the side reader's source.
        window.sideReaderSources[side] = "paper-eta"
        vm.splitFocusedPane(in: window)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.reader, .secondaryReader, .secondaryReader])
        #expect(window.sideReaderSources[vm.centerTabGroups.groups[2].id] == "paper-eta")

        // Side panes are this run's alone.
        let stored = vm.centerTabGroups.persistedRepresentation
        #expect(stored.count == 1)
        #expect(!stored.joined().contains("secondaryReader"))
        #expect(StudioCenterTabGroups.fromPersisted(["reader*", "secondaryReader*"])?.groups.count == 1)
    }

    @Test("the Browser splits into a side browser that knows the pane it came from")
    func browserSplitsIntoSideBrowser() {
        let restore = Self.capturedLayout()
        defer { restore() }
        let vm = Self.makeViewModel()
        let window = vm.activeWindowState
        vm.centerTabGroups = StudioCenterTabGroups(groups: [
            .init(tabs: [.artifacts, .browser, .chat], activeTab: .browser, openTabs: [.browser]),
        ])
        let browserPane = vm.centerTabGroups.groups[0].id

        vm.splitPane(at: 0, showing: .browser, in: window)
        #expect(vm.centerTabGroups.groups.map(\.activeTab) == [.browser, .secondaryBrowser])
        #expect(window.splitFromPane[vm.centerTabGroups.groups[1].id] == browserPane)
        #expect(StudioCenterTab.browser.splitCopy == .secondaryBrowser)
        #expect(!vm.centerTabGroups.persistedRepresentation.joined().contains("secondaryBrowser"))
    }

    @Test("four panes have four names for the chat, no two alike")
    func fourPaneNames() {
        #expect((0..<4).map { ChatOpenPanes.positionName(index: $0, count: 4) }
            == ["Left", "Middle left", "Middle right", "Right"])
        #expect((0..<3).map { ChatOpenPanes.positionName(index: $0, count: 3) } == ["Left", "Middle", "Right"])
        #expect(ChatOpenPanes.positionName(index: 0, count: 1) == nil)
    }

    @Test("each side-chat pane keeps its own store, and a gone pane's store goes unless it is answering")
    func storesPerPane() {
        let chats = StudioComparisonChatStores(makeStore: {
            StudioAssistantSessionStore(managerFactory: { ReviewSessionManager() })
        })
        let left = UUID()
        let right = UUID()
        #expect(chats.store(forPane: left) === chats.store(forPane: left))
        #expect(chats.store(forPane: left) !== chats.store(forPane: right))
        #expect(chats.store(forPane: nil) === chats.unpaned)
        #expect(chats.paneCountForTesting == 2)

        chats.prune(keepingPanes: [left])
        #expect(chats.paneCountForTesting == 1)
        #expect(chats.all.count == 2)
    }
}
