// The transcript, its blocks, bubbles, editing and new chat hand-off of the chat panel.
import SwiftUI
import Combine
import AppKit

extension InternalReviewPanelContent {
    /// The one-page transcript for a chat it draws whole, the native one for
    /// every other (`ChatTranscriptPage`).
    var transcriptView: some View {
        ReviewChatTranscriptChooser(showsNative: showsMemoryReviewCards) {
            transcriptScrollView
        } page: {
            transcriptPage
        }
    }

    private var transcriptPage: some View {
        ReviewChatTranscriptPageHost(
            manager: manager,
            isTurnInFlight: isTurnInFlight,
            walkthroughPreparation: manager.walkthroughPreparationDetail,
            turnStartedAt: turnStartedAt,
            errorMessage: manager.errorMessage ?? dictation.errorMessage ?? speech.errorMessage,
            bottomReserve: transcriptBottomReserve,
            layout: ChatTranscriptPage.Layout(
                fontSize: chatBodyFontSize,
                columnMaxWidth: chatColumnMaxWidth,
                messageMaxWidth: chatMessageMaxWidth
            ),
            findMatchID: chatFind.isVisible ? chatFind.currentMatchID : nil,
            findScrollRevision: chatFind.scrollRevision,
            armedSideQuestionBlockID: isSideQuestionMode ? sideQuestionTarget?.blockID : nil,
            editableMessageID: manager.chatMessages.last(where: { $0.role == .user }).flatMap { message in
                editAction(for: message) == nil ? nil : message.id
            },
            laneExpansionRequest: laneExpansionRequest,
            citationContexts: $citationContexts,
            suggestedQuestions: { block, context in
                suggestedQuestions(under: block, context: context)
            },
            lookups: transcriptPageLookups,
            resolvers: transcriptPageResolvers,
            onAction: { action in
                handleTranscriptPageAction(action)
            }
        )
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
            transcriptViewportHeight = height
        }
        .overlay(alignment: .top) {
            if chatFind.isVisible {
                ChatFindBar(find: chatFind, blocks: {
                    ReviewChatTranscriptBlock.grouping(manager.chatMessages)
                })
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .transition(.opacity)
            }
        }
        .onChange(of: showsWorkingLine, initial: true) { _, working in
            turnStartedAt = working ? (turnStartedAt ?? Date()) : nil
        }
        .contentShape(Rectangle())
        .onDrop(
            of: reviewChatDropTypes,
            isTargeted: dropTargetBinding,
            perform: handleDrop
        )
        .overlay {
            if dragVisibility.isDragging {
                Color.clear
                    .contentShape(Rectangle())
                    .onDrop(
                        of: reviewChatDropTypes,
                        isTargeted: dropTargetBinding,
                        perform: handleDrop
                    )
            }
        }
    }

    /// What the page's replies need from the app: the lookups and routes a
    /// reply row is given (`ReviewChatMessageContent`).
    private var transcriptPageResolvers: ChatTranscriptPage.Resolvers {
        let vm = vm
        let notebookCitations = notebookCitations
        return ChatTranscriptPage.Resolvers(
            sourceCard: { sourceToken in
                guard let article = await vm.persistedArticle(forLinkToken: sourceToken) else { return nil }
                let card = await ChatSourceCard.resolved(
                    article: article,
                    collectionTitle: vm.sourceGroupTitle(for: article)
                )
                guard let notebookCitations else { return card }
                return card.inNotebook(notebookCitations.holds(article.id))
            },
            sourceImage: { imageToken in
                await ChatSourceImage.resolved(
                    token: imageToken,
                    articleForSourceID: { sourceID in await vm.persistedArticle(forLinkToken: sourceID) },
                    contentForSourceID: { sourceID in await vm.storage.loadSourceContent(sourceID) },
                    citedPapersForSource: { sourceID in await vm.loadCitedPapers(forSourceID: sourceID) }
                )
            },
            openSource: { link in
                Task {
                    await vm.openLinkedSourceInReader(link.sourceID, at: link.seconds, passage: link.passage, page: link.page)
                }
            },
            openWebURL: { url, title in
                vm.openWebCitationInReader(url, title: title)
            },
            selection: { action, passage, messageID, anchor in
                handleReplySelection(action, passage: passage, messageID: messageID, anchor: anchor)
            }
        )
    }

    /// What the page's rows read from the library and the panel.
    private var transcriptPageLookups: ChatTranscriptLookups {
        let vm = vm
        let sources = reviewSources
        return ChatTranscriptLookups(
            pageTitle: { page in
                let current = vm.artifacts.first(where: { $0.id == page.id })?.title
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let current, !current.isEmpty { return current }
                return page.title.isEmpty ? "Untitled" : page.title
            },
            walkTitle: { id in walkthroughSubjectTitle(id) },
            reviewPosition: { sourceID in
                guard sources.count > 1, let index = sources.firstIndex(where: { $0.id == sourceID }) else { return nil }
                return "\(index + 1) of \(sources.count)"
            },
            savedCardsSubtitle: { saved in ReviewChatSavedCardsView.subtitle(saved, articlesById: vm.articlesById, canonicalID: vm.canonicalSourceID) },
            offersQuizSkip: { context in offersCourseQuizSkip(context: context) }
        )
    }

    /// The messages the transcript shows: while a walk plays, its card's own
    /// conversation (`WalkthroughTranscriptFold`).
    private var transcriptMessages: [ReviewSessionManager.Message] {
        WalkthroughTranscriptFold.cardThread(manager.chatMessages, playback: manager.walkthroughPlayback)
    }

    /// What the learner did on the page, done the way the native rows do it.
    @MainActor
    private func handleTranscriptPageAction(_ action: ChatTranscriptPage.Action) {
        let blocks = ReviewChatTranscriptBlock.grouping(transcriptMessages)
        func block(_ id: UUID) -> ReviewChatTranscriptBlock? { blocks.first { $0.id == id } }
        switch action {
        case .copyAnswer(let blockID):
            guard let block = block(blockID) else { return }
            let text = ReviewSessionManager.copiedAnswerText(from: block.answerMessages)
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .copyMessage(let blockID):
            guard let message = block(blockID)?.userMessage,
                  let text = ReviewSessionManager.displayableMessageContent(role: .user, content: message.content),
                  !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .editMessage(let blockID):
            guard let message = block(blockID)?.userMessage else { return }
            editAction(for: message)?()
        case .sideQuestion(let blockID):
            guard let block = block(blockID) else { return }
            toggleSideQuestionMode(
                about: ReviewChatReplyReference(blockID: block.id, line: ReviewChatTranscriptSection.replyLine(of: block))
            )
        case .moreMenu(let blockID, let rect, let view):
            guard let block = block(blockID) else { return }
            showReplyMenu(for: block, isLatest: block.id == blocks.last?.id, at: rect, in: view)
        case .openPassage(let blockID):
            guard let message = block(blockID)?.userMessage,
                  let passage = ChatPassageOrigin.parse(contextContent: message.contextualContent) else { return }
            openPassageInReader(passage)
        case .openContextSource(let sourceID):
            Task { await vm.openLinkedSourceInReader(sourceID) }
        case .suggestedQuestion(let question):
            askSuggestedQuestion(question)
        case .openMoment(let sourceID, let seconds):
            Task { await vm.openLinkedSourceInReader(sourceID, at: Double(seconds)) }
        case .skipQuizQuestion:
            Task { await skipCourseQuizQuestion() }
        case .steer(let next):
            Task { await steerMemoryReview(next ? .next : .deeper) }
        case .laneAnswer:
            returnToOpenQuestion()
        case .laneSkip:
            Task { await skipOpenQuestion() }
        case .laneFollowUp:
            followUpSideQuestion()
        case .laneNewChat:
            openSideQuestionInNewChat()
        case .resumeWalk(let sourceID):
            Task { await startWalkthroughPlayback(sourceID: sourceID) }
        case .openPage(let id):
            vm.revealArtifact(id, in: windowState)
        case .enlargeAnimation(let id, let title):
            expandedWalkthroughAnimation = WalkthroughEnlargedAnimation(
                id: id,
                title: vm.artifacts.first { $0.id == id }?.title ?? title,
                content: .hosted(url: LinkedPage.localSiteURL(artifactID: id))
            )
        case .openSavedCards(let blockID, let partID, let rect, let view):
            guard let block = block(blockID) else { return }
            let saved = ReviewChatAnswerLayout.items(block.answerMessages).lazy.compactMap { item -> ChatSavedCards? in
                guard case .entry(let entry) = item, entry.id == partID else { return nil }
                return entry.savedCards
            }.first
            guard let saved else { return }
            showSavedCards(saved, at: rect, in: view)
        case .pluginSetup(let blockID, let partID, let index):
            guard let block = block(blockID) else { return }
            for item in ReviewChatAnswerLayout.items(block.answerMessages) {
                guard case .work(let work) = item, work.id == partID else { continue }
                let needs = ChatTranscriptPage.setupNeeds(work)
                if needs.indices.contains(index) { needs[index].openSetup() }
                return
            }
        case .revealBrowser:
            revealChatBrowserTab()
        }
    }

    /// The cards a call saved, in a popover over their card on the page: the
    /// same deck the transcript drew inline, to check, keep and page through.
    @MainActor
    private func showSavedCards(_ saved: ChatSavedCards, at rect: CGRect, in view: NSView) {
        let popover = NSPopover()
        var shownDeck = ReviewChatSavedCardsView(saved: saved)
        shownDeck.onOpenedInMemory = { [weak popover] in popover?.close() }
        let deck = shownDeck
            .padding(16)
            .frame(width: 520)
            .fixedSize(horizontal: true, vertical: true)
            .environment(vm)
            .environment(windowState)
        popover.behavior = .transient
        let host = NSHostingController(rootView: deck)
        // The popover takes the deck's own size, as the cards load in.
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        let anchor = NSRect(
            x: rect.minX,
            y: view.isFlipped ? rect.minY : view.bounds.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        popover.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
    }

    /// A reply's ⋯ on the page: the same lines as the native footer's menu
    /// (`ReviewChatReplyMenu`), doing the same things.
    @MainActor
    private func showReplyMenu(for block: ReviewChatTranscriptBlock, isLatest: Bool, at rect: CGRect, in view: NSView) {
        let replyLine = ReviewChatTranscriptSection.replyLine(of: block)
        let saveToNote: ReviewChatSaveToNoteControl? = replyLine == nil ? nil : ReviewChatSaveToNoteControl(
            savedDocID: answerNoteDocIDs[block.id],
            save: { Task { await saveAnswerToNote(block) } },
            open: { docID in vm.revealArtifact(docID, in: windowState) }
        )
        let addToCanvas: (() -> Void)? = replyLine == nil || !vm.listsCanvases
            ? nil
            : { Task { await vm.addAnswerToCanvas(markdown: ReviewChatSaveToNote.markdown(of: block.answerMessages)) } }
        let canFork = !manager.isGenerating && !manager.isSearching
            && block.answerMessages.contains { $0.exchangeID != nil && $0.exchangeField != nil }
        let discussInNewChat = discussInNewChatAction(for: block.answerMessages)
        // A reply whose More details lane already hangs under it reopens
        // that lane rather than asking a second time.
        let existingLaneID = ReviewChatTranscriptSection.grouping(ReviewChatTranscriptBlock.grouping(transcriptMessages))
            .first { $0.isSideQuestion && $0.isMoreDetails && $0.aboutBlockID == block.id }?.id
        let moreDetails: (() -> Void)? = replyLine == nil ? nil : {
            requestMoreDetails(about: ReviewChatReplyReference(blockID: block.id, line: replyLine), existingLaneID: existingLaneID)
        }
        let offersTryAgain = isLatest && editingMessage == nil && manager.canTakeBackNewestTurn
        let timeLine = block.answerMessages.last(where: { $0.role == .assistant }).map {
            ReviewChatReplyMenu.timeLine($0.createdAt)
        }
        let items = ReviewChatReplyMenu.items(
            timeLine: timeLine,
            savedDocID: saveToNote.map(\.savedDocID),
            offersAddToCanvas: addToCanvas != nil,
            offersDiscussInNewChat: discussInNewChat != nil,
            offersMoreDetails: moreDetails != nil,
            asideActionsOnly: false,
            offersTryAgain: offersTryAgain,
            offersSideChat: isLatest
        )
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            switch item {
            case .time(let line):
                let entry = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                entry.isEnabled = false
                menu.addItem(entry)
                menu.addItem(.separator())
            case .saveToNote:
                menu.addItem(ActionMenuItem(title: item.title, isOn: false) { saveToNote?.save() })
            case .openNote(let docID):
                menu.addItem(ActionMenuItem(title: item.title, isOn: false) { saveToNote?.open(docID) })
            case .addToCanvas:
                menu.addItem(ActionMenuItem(title: item.title, isOn: false) { addToCanvas?() })
            case .branch:
                let entry = ActionMenuItem(title: item.title, isOn: false) { forkConversation(through: block.answerMessages) }
                entry.isEnabled = canFork
                menu.addItem(entry)
            case .discussInNewChat:
                let entry = ActionMenuItem(title: item.title, isOn: false) { discussInNewChat?() }
                entry.isEnabled = canFork
                menu.addItem(entry)
            case .moreDetails:
                menu.addItem(ActionMenuItem(title: item.title, isOn: false) { moreDetails?() })
            case .sideChat:
                menu.addItem(ActionMenuItem(title: item.title, isOn: false) { openThreadSideChat() })
            case .tryAgain:
                menu.addItem(ActionMenuItem(title: item.title, isOn: false) { Task { await manager.tryAgain() } })
            case .tryAgainWith:
                let entry = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                let models = NSMenu()
                models.autoenablesItems = false
                for model in ChatTryAgainModels.entries {
                    models.addItem(ActionMenuItem(
                        title: AIModelCatalog.pickerName(provider: model.provider, modelID: model.modelID),
                        isOn: false
                    ) { tryAgain(with: model) })
                }
                if !ChatTryAgainModels.entries.isEmpty { models.addItem(.separator()) }
                models.addItem(ActionMenuItem(title: "Choose Models…", isOn: false) { ModelPickerSheetRequest.open(.chat) })
                entry.submenu = models
                menu.addItem(entry)
            }
        }
        ChatTryAgainModels.refresh()
        let point = NSPoint(x: rect.minX, y: view.isFlipped ? rect.maxY + 4 : view.bounds.height - rect.maxY - 4)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    private var transcriptScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // The rows live in their own view so a streamed token
                // re-evaluates them and not this panel. Everything handed down
                // here changes at most a few times per turn.
                ReviewChatTranscriptStack(
                    manager: manager,
                    proxy: proxy,
                    isTurnInFlight: isTurnInFlight,
                    walkthroughPreparation: manager.walkthroughPreparationDetail,
                    turnStartedAt: turnStartedAt,
                    errorMessage: manager.errorMessage ?? dictation.errorMessage ?? speech.errorMessage,
                    bottomReserve: transcriptBottomReserve,
                    showsMemoryCards: showsMemoryReviewCards,
                    showsTopicCards: showsMemoryReviewCards,
                    answersAfterGrade: !manager.isTopicMemoryReview,
                    sendMemoryAnswer: { text in Task { await sendReviewChatMessage(text) } },
                    dontRememberMemoryAnswer: {
                        Task { await sendReviewChatMessage(MemoryReviewTutoring.dontRememberMessage) }
                    },
                    memoryCardIndex: memoryReviewCardIndex,
                    minContentHeight: showsMemoryReviewCards ? transcriptViewportHeight : 0,
                    columnMaxWidth: showsMemoryReviewCards ? memoryReviewCardTextWidth : chatColumnMaxWidth,
                    messageMaxWidth: showsMemoryReviewCards
                        ? memoryReviewCardTextWidth - 2 * MemoryReviewCardSurface.contentInset
                        : chatMessageMaxWidth,
                    openContextSource: { sourceID in Task { await vm.openLinkedSourceInReader(sourceID) } },
                    answerOpenQuestion: { returnToOpenQuestion() },
                    skipOpenQuestion: { Task { await skipOpenQuestion() } },
                    followUpSideQuestion: { followUpSideQuestion() },
                    openSideQuestionInNewChat: { openSideQuestionInNewChat() },
                    laneExpansionRequest: laneExpansionRequest,
                    findMatchID: chatFind.isVisible ? chatFind.currentMatchID : nil,
                    citationContexts: $citationContexts,
                    row: { block, context in
                        chatTranscriptBlock(block, context: context)
                    },
                    errorText: { message in
                        errorText(message)
                    }
                )
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                transcriptViewportHeight = height
            }
            .modifier(ChatScrolledUpReader(bottomReserve: transcriptBottomReserve, isScrolledUp: $isTranscriptScrolledUp))
            .overlay(alignment: .top) {
                if chatFind.isVisible {
                    ChatFindBar(find: chatFind, blocks: {
                        ReviewChatTranscriptBlock.grouping(manager.chatMessages)
                    })
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if isTranscriptScrolledUp, !showsMemoryReviewCards {
                    ChatJumpToLatestButton {
                        guard let last = ReviewChatTranscriptBlock.grouping(manager.chatMessages).last else { return }
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                    .padding(.bottom, 10)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isTranscriptScrolledUp)
            .onChange(of: chatFind.scrollRevision) { _, _ in
                guard let id = chatFind.currentMatchID else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            // Started here rather than in the indicator's own `onAppear`: it sits
            // at the end of a LazyVStack, so scrolling away mid-turn would tear it
            // down and the clock would restart at zero on the way back.
            .onChange(of: showsWorkingLine, initial: true) { _, working in
                turnStartedAt = working ? (turnStartedAt ?? Date()) : nil
            }
            .contentShape(Rectangle())
            .onDrop(
                of: reviewChatDropTypes,
                isTargeted: dropTargetBinding,
                perform: handleDrop
            )
            .overlay {
                if dragVisibility.isDragging {
                    Color.clear
                        .contentShape(Rectangle())
                        .onDrop(
                            of: reviewChatDropTypes,
                            isTargeted: dropTargetBinding,
                            perform: handleDrop
                        )
                }
            }
        }
    }

    var sessionBrowserPopover: some View {
        ReviewSessionsPanel(
            compact: false,
            currentSessionID: {
                manager.currentSessionID
            },
            resumeSession: { session in
                isSessionBrowserPresented = false
                Task { await openPickedSession(session) }
            },
            hideSidebar: {
                isSessionBrowserPresented = false
            },
            hideButtonSystemImage: "xmark",
            hideButtonHelp: "Close previous chats",
            deletedActiveSession: {
                closeDeletedActiveSession()
            }
        )
        .frame(width: sessionBrowserPopoverWidth, height: sessionBrowserPopoverHeight)
    }

    @ViewBuilder
    private func chatTranscriptBlock(
        _ block: ReviewChatTranscriptBlock,
        context: ReviewChatTranscriptRowContext
    ) -> some View {
        if block.userMessage == nil, let marker = block.answerMessages.first?.walkthroughStep {
            // Only a walk that is not playing leaves a step turn in the
            // transcript (`WalkthroughTranscriptFold.resting`): its cards
            // come back from here.
            WalkthroughResumeRow(
                title: walkthroughSubjectTitle(marker.sourceID),
                maxContentWidth: chatMessageMaxWidth,
                resume: { Task { await startWalkthroughPlayback(sourceID: marker.sourceID) } }
            )
        } else if let message = block.userMessage {
            // Sources the learner brought in just before this message, above
            // it: their gesture, on their side (`ChatContextAdditions`).
            let stored = ChatContextAdditions.parse(contextContent: message.contextualContent)
            if !stored.added.isEmpty {
                ReviewChatContextAdditionsRow(
                    added: stored.added,
                    maxContentWidth: chatMessageMaxWidth,
                    openSource: { sourceID in Task { await vm.openLinkedSourceInReader(sourceID) } }
                )
            }
            // The moment of a video the question was asked at, with the frame
            // the tutor was shown; a click plays the video from there.
            let moments = ReviewChatVideoMomentRow.moments(in: stored.onScreen)
            if !moments.isEmpty {
                ReviewChatVideoMomentRow(
                    moments: moments,
                    maxContentWidth: chatMessageMaxWidth,
                    open: { sourceID, seconds in
                        Task { await vm.openLinkedSourceInReader(sourceID, at: Double(seconds)) }
                    }
                )
            }
            chatTranscriptMessage(message)
        } else if showsMemoryReviewCards,
                  let opening = MemoryReviewTopicCardFold.opening(in: block.answerMessages)
                    ?? (context.isFirstOnCard ? MemoryReviewTopicCardFold.untitledOpening(in: block.answerMessages) : nil) {
            // The block that opens a card is its question, not a reply: set
            // large, its sources as faces under it, no footer.
            memoryReviewTopicOpening(opening, subjectID: opening.topicID.isEmpty ? context.memoryCardTopicID : opening.topicID)
            memoryReviewTopicLedgerAndSteer(context: context)
        } else {
            let replyLine = ReviewChatTranscriptSection.replyLine(of: block)
            ReviewChatAnswerBlock(
                messages: block.answerMessages,
                showsActions: !context.isLive,
                // A topic card's reply icons show under the pointer only.
                isLatest: context.isLatest && !showsMemoryReviewCards,
                saveToNote: context.isLive || replyLine == nil
                    ? nil
                    : ReviewChatSaveToNoteControl(
                        savedDocID: answerNoteDocIDs[block.id],
                        save: { Task { await saveAnswerToNote(block) } },
                        open: { docID in vm.revealArtifact(docID, in: windowState) }
                    ),
                // The answer as an Idea on the open canvas, where canvases are listed.
                addToCanvas: context.isLive || replyLine == nil || showsMemoryReviewCards || !vm.listsCanvases
                    ? nil
                    : { Task { await vm.addAnswerToCanvas(markdown: ReviewChatSaveToNote.markdown(of: block.answerMessages)) } },
                canFork: !manager.isGenerating &&
                    !manager.isSearching &&
                    block.answerMessages.contains(where: {
                        $0.exchangeID != nil && $0.exchangeField != nil
                    }),
                fork: {
                    forkConversation(through: block.answerMessages)
                },
                discussInNewChat: discussInNewChatAction(for: block.answerMessages),
                // Every finished reply offers both doors: an aside about it,
                // and the tutor expanding it. Neither moves the conversation.
                sideQuestion: context.isLive
                    ? nil
                    : ReviewChatSideQuestionControl(
                        isArmed: isSideQuestionMode && sideQuestionTarget?.blockID == block.id,
                        isFollowUp: context.isInsideAside,
                        toggle: {
                            toggleSideQuestionMode(about: ReviewChatReplyReference(blockID: block.id, line: replyLine))
                        }
                    ),
                moreDetails: context.isLive || replyLine == nil
                    ? nil
                    : {
                        requestMoreDetails(
                            about: ReviewChatReplyReference(blockID: block.id, line: replyLine),
                            existingLaneID: context.moreDetailsLaneID
                        )
                    },
                // A side question's lane has its own Skip, on its Back to
                // the question card.
                skipQuizQuestion: offersCourseQuizSkip(context: context)
                    ? { Task { await skipCourseQuizQuestion() } }
                    : nil,
                asideActionsOnly: showsMemoryReviewCards,
                tryAgain: context.isLatest && !context.isLive && !showsMemoryReviewCards
                    && editingMessage == nil && manager.canTakeBackNewestTurn
                    ? ReviewChatTryAgainControl(
                        retry: { Task { await manager.tryAgain() } },
                        retryWith: { entry in tryAgain(with: entry) }
                    )
                    : nil,
                openSideChat: context.isLatest && !context.isLive && !showsMemoryReviewCards
                    ? { openThreadSideChat() }
                    : nil
            ) {
                // Every step the reply took is one "Worked for" line where the
                // first ran; a topic card draws no thinking among them.
                ForEach(ReviewChatAnswerLayout.items(block.answerMessages, showsThinking: !showsMemoryReviewCards)) { item in
                    chatTranscriptItem(item, isLive: context.isLive)
                        .id(item.id)
                }
            }
            // The two steers a memory review offers once the source under
            // discussion is graded: under the graded reply, under each probe's
            // reply, and under the tutor's offer to move on or stay. They sit
            // under the newest settled reply only. A topic card has its
            // ledger and its two buttons instead.
            if showsMemoryReviewCards {
                memoryReviewTopicLedgerAndSteer(context: context)
            } else if context.isLatest, !context.isLive, manager.offersMemoryReviewSteer,
                      !manager.isGenerating, !manager.isSearching {
                memoryReviewSteerChips
            } else if let questions = suggestedQuestions(under: block, context: context) {
                // The questions the reply suggested, under its footer.
                ChatSuggestedQuestionCards(
                    questions: questions,
                    fontSize: chatBodyFontSize,
                    maxWidth: min(chatMessageMaxWidth, 42 * chatBodyFontSize),
                    send: askSuggestedQuestion
                )
            }
        }
    }

    /// The chat's body size at this pane's zoom, as the reply's web view sets it.
    private var chatBodyFontSize: CGFloat {
        (ChatMarkdownView.baseFontSize * uiZoomScale).rounded()
    }

    /// The suggested questions to draw under this block: only the newest
    /// settled answer's, in the conversation itself, and never in a quiz, a
    /// review or a walk, whose next step is the tutor's.
    func suggestedQuestions(
        under block: ReviewChatTranscriptBlock,
        context: ReviewChatTranscriptRowContext
    ) -> [String]? {
        // `offersFollowUpQuestions` is false in a course quiz, a review, a
        // memory review and while a walk plays; a walk's own step rows are
        // checked too, for the turns it left behind.
        guard context.isLatest, !context.isLive, !context.isInsideAside,
              !manager.isGenerating, !manager.isSearching,
              manager.offersFollowUpQuestions,
              !block.answerMessages.contains(where: { $0.walkthroughStep != nil }),
              let questions = block.answerMessages.last(where: { $0.role == .assistant })?.followUpQuestions,
              !questions.isEmpty else { return nil }
        return questions
    }

    /// A suggested question, asked as the learner's message in this chat.
    /// The draft and any passage waiting in the composer stay where they are.
    func askSuggestedQuestion(_ question: String) {
        // Asked here, never offered again in the notebook's guide.
        if let notebookID = linkedResearchNotebook?.id {
            vm.noteNotebookQuestionAsked(question, notebookID: notebookID)
            notebookQuestionsRevision &+= 1
        }
        Task {
            if manager.queuesSendsNow {
                _ = manager.enqueueFollowUp(question)
                await manager.resumeQueuedFollowUps()
                return
            }
            await sendReviewChatMessage(question)
        }
    }

    /// Save to note: the answer becomes a Doc in this chat's notebook, or an
    /// unfiled one outside a notebook, named after the question it answers.
    /// The toast and the footer's tick confirm it; nothing opens. Its picture
    /// lines become the Doc's own attachments before its body is first
    /// written, in a team notebook too (`createDocKeepingPictures`).
    @MainActor
    private func saveAnswerToNote(_ block: ReviewChatTranscriptBlock) async {
        guard answerNoteDocIDs[block.id] == nil,
              answersBeingSavedToNotes.insert(block.id).inserted else { return }
        defer { answersBeingSavedToNotes.remove(block.id) }
        let markdown = ReviewChatSaveToNote.markdown(of: block.answerMessages)
        guard !markdown.isEmpty else { return }
        let title = ReviewChatSaveToNote.title(
            learnerMessage: learnerMessage(answeredBy: block),
            chatTitle: savedChatTitle,
            answer: markdown
        )
        do {
            let snapshot = try await vm.createDocKeepingPictures(
                title: title,
                homeNotebookID: linkedResearchNotebook?.id,
                markdown: markdown
            )
            answerNoteDocIDs[block.id] = snapshot.artifact.id
        } catch {
            // A read-only team, or a picture this Mac cannot draw: the toast
            // says which, and nothing was saved.
            vm.showToast(error.localizedDescription)
        }
    }

    /// The learner's own words this answer replies to. A More details press
    /// is the app's, not theirs, so it names nothing.
    private func learnerMessage(answeredBy block: ReviewChatTranscriptBlock) -> String? {
        let messages = manager.chatMessages
        guard let firstID = block.answerMessages.first?.id,
              let start = messages.firstIndex(where: { $0.id == firstID }),
              let asked = messages[..<start].last(where: { $0.role == .user }),
              !asked.isMoreDetailsRequest else { return nil }
        return ReviewSessionManager.displayableMessageContent(role: .user, content: asked.content)
    }

    /// The chat's title as the rail lists it, renames included.
    private var savedChatTitle: String {
        let recordTitle = manager.currentSessionID.flatMap { sessionID in
            vm.reviewSessionLinks.first { $0.id == sessionID }?.title
        }
        if let recordTitle, !recordTitle.isEmpty { return recordTitle }
        return manager.topic
    }

    /// Skip, an icon in the newest reply's footer while a quiz question waits
    /// for its answer (product owner, 2026-09-27: "please do allow me to skip
    /// questions in a quiz too"). The memory review's steer chips, which
    /// never share a chat with a quiz, keep that spot to themselves.
    private func offersCourseQuizSkip(context: ReviewChatTranscriptRowContext) -> Bool {
        context.isLatest && !context.isLive && !context.isInsideAside &&
            !showsMemoryReviewCards && !manager.offersMemoryReviewSteer &&
            manager.courseQuizOpenQuestionNumber != nil && !isSkippingQuizQuestion &&
            !manager.isGenerating && !manager.isSearching
    }

    /// The quiz skips its question in the app first, so the skip holds on any
    /// model, then the learner's words go to the tutor with what comes next.
    @MainActor
    func skipCourseQuizQuestion() async {
        guard !isSkippingQuizQuestion else { return }
        isSkippingQuizQuestion = true
        defer { isSkippingQuizQuestion = false }
        guard let note = await manager.skipOpenCourseQuizQuestion() else { return }
        await sendReviewChatMessage("Skip this question.", contextualContent: note)
    }

    /// A topic card's opening: what the tutor said before turning, the
    /// question set large until the topic is graded, and the topic's sources
    /// as faces (a click opens one in the Reader).
    private func memoryReviewTopicOpening(_ opening: MemoryReviewTopicOpening, subjectID: String?) -> some View {
        let topic = subjectID.flatMap { id in memoryReviewCardSubjects.first { $0.id == id } }
        let graded = subjectID.map { manager.memoryReviewStatusBySource[$0] != nil } ?? false
        return MemoryReviewTopicQuestion(preamble: opening.preamble, question: opening.question, isLarge: !graded) {
            if let topic {
                memoryReviewTopicFaces(topic)
            }
        }
    }

    private func memoryReviewTopicFaces(_ topic: MemoryReviewCardSubject) -> some View {
        HStack(spacing: 8) {
            ForEach(topic.sourceIDs, id: \.self) { sourceID in
                let article = memoryReviewFaceArticle(sourceID)
                MemoryReviewSourceFace(
                    title: memoryReviewSourceTitle(sourceID),
                    article: article,
                    bookCoverPath: article.flatMap(memoryReviewBookCoverPath),
                    size: 30,
                    open: article == nil ? nil : { Task { await vm.openLinkedSourceInReader(sourceID) } }
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sources")
        .accessibilityIdentifier("memory.card.faces")
    }

    /// The article behind a face, or nil for a chat and for a source a screen
    /// recording may not show (the strip's rule).
    private func memoryReviewFaceArticle(_ sourceID: String) -> StudioArticle? {
        guard let article = vm.articlesById[sourceID], vm.isVisibleInRecordingMode(article) else { return nil }
        return article
    }

    /// The name of a review source or chat: the article's, or the briefing's
    /// for a chat, which has no article to carry its title.
    private func memoryReviewSourceTitle(_ sourceID: String) -> String {
        vm.articlesById[sourceID]?.title ?? manager.memoryReviewMaterialTitles[sourceID] ?? "a source"
    }

    /// Under the last reply on a topic card: the ledger of the topic's ideas
    /// once its opening answer is graded, and, on the newest card once the
    /// tutor has replied to a graded answer, Go deeper and Next topic.
    @ViewBuilder
    private func memoryReviewTopicLedgerAndSteer(context: ReviewChatTranscriptRowContext) -> some View {
        if context.isLastOnCard, !context.isLive,
           let topicID = context.memoryCardTopicID,
           let topic = memoryReviewCardSubjects.first(where: { $0.id == topicID }) {
            let rows = MemoryReviewTopicCardFold.ledgerRows(
                ideaIDs: topic.ideaIDs,
                states: manager.memoryReviewIdeaStates,
                statement: { manager.memoryReviewIdea($0)?.statement }
            )
            if !rows.isEmpty {
                MemoryReviewTopicLedger(
                    rows: rows,
                    sourceTitle: memoryReviewSourceTitle,
                    article: memoryReviewFaceArticle,
                    bookCoverPath: memoryReviewBookCoverPath,
                    isBusy: isTurnInFlight,
                    open: { sourceID in Task { await vm.openLinkedSourceInReader(sourceID) } },
                    notRead: { sourceID in
                        let entry = MemoryReviewStripEntry(
                            id: sourceID,
                            title: memoryReviewSourceTitle(sourceID),
                            article: vm.articlesById[sourceID]
                        )
                        Task { await removeMemoryReviewSource(entry) }
                    }
                )
            }
            if context.memoryCardFoot == .steer {
                MemoryReviewTopicSteerButtons(
                    isBusy: isTurnInFlight,
                    nextTitle: topic.isTopic ? "Next topic" : "Next source",
                    deeper: { Task { await steerMemoryReview(.deeper) } },
                    next: { Task { await steerMemoryReview(.next) } }
                )
            }
        }
    }

    var goalTracker: MemoryReviewEngagementTracker { MemoryReviewEngagementTracker.shared }

    func updateMemoryGoalPresence(sessionID: String?) {
        if let sessionID, MemoryReviewSession.isMemorySession(sessionID) {
            goalTracker.present(manager, panel: memoryGoalPanelToken, sessionID: sessionID, storage: vm.storage)
        } else {
            goalTracker.dismiss(panel: memoryGoalPanelToken)
        }
    }

    /// The pane carried the review and now carries something else: the learner
    /// left it by a door other than the ×, so the workspace comes back with
    /// them. Only a move *off* the focused review counts — a pane arriving at
    /// it passes through states where it is showing something else, and those
    /// must not end a review that is only just beginning.
    func leaveMemoryReviewFocusIfMovedOff(from previousSessionID: String?, to sessionID: String?) {
        guard let previousSessionID,
              previousSessionID != sessionID,
              vm.memoryReviewFocusSessionID == previousSessionID else { return }
        vm.leaveMemoryReviewFocus(sessionID: previousSessionID)
    }

    private var memoryReviewSteerChips: some View {
        HStack(spacing: 8) {
            memoryReviewSteerChip("Go deeper", systemImage: "arrow.down.right.circle", steer: .deeper)
            memoryReviewSteerChip("Next", systemImage: "arrow.right.circle", steer: .next)
            Spacer(minLength: 0)
        }
        .padding(.top, -6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Memory review steer")
    }

    private func memoryReviewSteerChip(
        _ title: String,
        systemImage: String,
        steer: MemoryReviewSteer
    ) -> some View {
        Button {
            Task { await steerMemoryReview(steer) }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.callout)
                .padding(.horizontal, 4)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(steer == .next
            ? "Move on to the next source"
            : "Stay on this source for a probe: on what did not come back, or past what did")
        .accessibilityIdentifier(steer == .next ? "mac.chatMemoryNext" : "mac.chatMemoryDeeper")
    }

    /// A chip is a spoken steer typed for the learner: it records the steer on
    /// the graded exchange, then sends the word as their message so the tutor
    /// hears it the same way it would hear "next" said aloud.
    @MainActor
    func steerMemoryReview(_ steer: MemoryReviewSteer) async {
        let note = await manager.steerMemoryReview(steer)
        let text = steer == .next ? "Next." : "Go deeper."
        await sendReviewChatMessage(text, contextualContent: note)
    }

    func forkConversation(through messages: [ReviewSessionManager.Message]) {
        Task {
            guard let forkedSession = await manager.forkConversation(through: messages) else {
                return
            }
            await vm.loadReviewSessionLinks()
            vm.requestResumeReviewSession(forkedSession.id)
        }
    }

    @ViewBuilder
    private func chatTranscriptItem(
        _ item: ReviewChatAnswerLayout.Item,
        isLive: Bool
    ) -> some View {
        switch item {
        case .entry(let entry):
            chatTranscriptEntry(entry)
        case .work(let work):
            ReviewChatWorkFold(work: work, isLive: isLive)
        case .pages(_, let pages):
            ReviewChatPageCards(pages: pages)
        }
    }

    /// A row that stands on its own in a reply: its prose, a review's turn to
    /// a source or topic, or the cards a call saved. Thinking and tool steps
    /// are the reply's "Worked for" fold (`ReviewChatAnswerLayout`).
    @ViewBuilder
    private func chatTranscriptEntry(_ entry: ReviewChatTranscriptEntry) -> some View {
        if let message = entry.message {
            chatTranscriptMessage(message)
        } else if let turn = entry.sourceTurn {
            memoryReviewSourceTurnRow(turn)
        } else if entry.activities.count == 1, let activity = entry.activities.first,
                  activity.kind == .sourceTurn, let topicID = activity.turnTargetID {
            // A turn to a topic: a heading in the conversation. On a topic
            // card the opening block draws the turn as the card's question
            // and never reaches here.
            MemoryReviewTopicTurnRow(
                title: activity.title,
                kind: manager.memoryReviewTopics.first { $0.id == topicID }?.kind
            )
        } else if let saved = entry.savedCards {
            ReviewChatSavedCardsView(saved: saved)
        }
    }

    /// The heading the transcript shows when the tutor turns to a source. It
    /// wears the same thumbnail as the source's chip in the strip above, so
    /// the eye can carry one token between the two: the strip says where the
    /// day stands, the heading says where the conversation is right now.
    private func memoryReviewSourceTurnRow(
        _ turn: ReviewSessionManager.Message.ToolActivity.SourcePresentation
    ) -> some View {
        let sources = reviewSources
        let position = sources.firstIndex(where: { $0.id == turn.id })
        return MemoryReviewSourceTurnRow(
            source: turn.source,
            bookCoverPath: memoryReviewBookCoverPath(for: turn.source),
            position: position.map { ($0 + 1, sources.count) },
            open: { Task { await vm.openLinkedSourceInReader(turn.id) } }
        )
    }

    /// The name a resume row gives a walk: its source's, or its animation's.
    private func walkthroughSubjectTitle(_ id: String) -> String {
        if let article = vm.articlesById[id] { return vm.displayTitle(for: article) }
        return vm.artifacts.first(where: { $0.id == id })?.title ?? "this source"
    }

    /// A message in the transcript. A walkthrough step's own turn is drawn
    /// as the card above the chat while the walk plays and is filtered out of
    /// the transcript (`WalkthroughTranscriptFold.cardThread`); with no walk
    /// playing, the walk's turns fold to one resume row.
    private func chatTranscriptMessage(_ message: ReviewSessionManager.Message) -> some View {
        chatBubble(for: message)
    }

    /// The card the walk is on, above the chat — also while a Reader beside
    /// it shows the walk's source, which stays clear to read (product owner,
    /// 2026-09-23: "those cards should be over the chat on the left; not
    /// over the paper").
    @ViewBuilder
    var walkthroughCardDeck: some View {
        if manager.walkthroughPlayback != nil {
            WalkthroughDeckView(
                manager: manager,
                isBusy: isTurnInFlight,
                maxCardHeight: max(220, (transcriptPanelHeight > 0 ? transcriptPanelHeight : transcriptHeight) * 0.6),
                fillsPane: walkthroughFillsPane,
                columnMaxWidth: chatColumnMaxWidth,
                gutter: chatHeaderGutter,
                isFolded: $isWalkthroughCardFolded,
                articleForSourceID: { id in vm.articlesById[id] },
                enlargeAnimation: { expandedWalkthroughAnimation = $0 }
            )
        }
    }

    /// Whether the walk's card takes the whole pane (walkthrough-design.md,
    /// "2026-09-24: the card takes the pane"): a card is up and nothing has
    /// been said under it — no turn in flight, no reply, no error — so there
    /// is no conversation to leave room for. The walk's own work is not
    /// something said: a step being got ready keeps the stage, whose foot
    /// shows the wait (giving way for it would flip the card to its
    /// compact form and back on every step and every reload of the record).
    /// The transcript is read only when no turn is in flight, so a streaming
    /// reply never re-renders the panel token by token. The bottom-sheet
    /// popover keeps the compact card.
    var walkthroughFillsPane: Bool {
        guard fillsAvailableSpace,
              !isWalkthroughCardFolded,
              let playback = manager.walkthroughPlayback,
              let step = playback.currentStep,
              playback.playedStepIDs.contains(step.id),
              !isTurnInFlight,
              manager.errorMessage == nil else { return false }
        return WalkthroughTranscriptFold.cardThread(manager.chatMessages, playback: playback).isEmpty
    }

    /// Tells the window this chat is walking, so a click on a panel in the
    /// Reader answers its Find it card, and takes it back when the walk ends.
    func registerWalkthroughDeck() {
        guard let windowState else { return }
        if manager.walkthroughPlayback != nil {
            if windowState.walkthroughDeckManager !== manager {
                windowState.walkthroughDeckManager = manager
            }
        } else if windowState.walkthroughDeckManager === manager {
            windowState.walkthroughDeckManager = nil
        }
    }

    private func chatBubble(for message: ReviewSessionManager.Message) -> some View {
        ReviewChatBubble(
            message: message,
            citationContext: citationContexts[message.id] ?? .init(),
            maxContentWidth: chatMessageMaxWidth,
            isSpeaking: speech.currentMessageID == message.id && speech.isSpeaking,
            isStreaming: manager.streamingMessageID == message.id,
            linkedNotebookTitle: nil,
            updateLinkedNotebook: nil,
            createNotebook: nil,
            deleteMessage: {
                deleteChatMessage(message)
            },
            canDelete: !manager.isGenerating && !manager.isSearching,
            speakMessage: {
                speakAssistantMessage(message)
            },
            stopSpeaking: {
                speech.stop()
            },
            discussInNewChat: discussInNewChatAction(for: [message]),
            openPassage: { passage in
                openPassageInReader(passage)
            },
            // A page this chat cites is added to its notebook as well.
            webSourcesNotebookID: linkedResearchNotebook?.id,
            editMessage: editAction(for: message)
        )
        .equatable()
    }

    /// Try Again With: the chat moves to `entry`, as the composer's picker
    /// would (a model not yet tried is tested first), and the newest reply is
    /// asked again on it.
    private func tryAgain(with entry: AIModelCatalogEntry) {
        Task { @MainActor in
            if !AIModelQualification.isPassed(provider: entry.provider, model: entry.modelID, role: .chat) {
                let verdict = await Task.detached(priority: .userInitiated) {
                    await AIModelQualification.testBeforeSelecting(provider: entry.provider, model: entry.modelID, role: .chat)
                }.value
                guard verdict == .go else {
                    manager.errorMessage = AIModelQualification.refusalText(name: entry.displayName, role: .chat, verdict: verdict)
                    return
                }
            }
            KeychainService.setTaskRoute(provider: entry.provider, model: entry.modelID, for: .chat)
            ChatRecentModels.record(.init(provider: entry.provider.rawValue, model: entry.modelID, effort: nil))
            await manager.tryAgain()
        }
    }

    /// Edit on the newest learner message, when its turn can be taken back
    /// and the composer can carry all of it (`ChatEditMessage.isEditable`).
    private func editAction(for message: ReviewSessionManager.Message) -> (() -> Void)? {
        guard message.role == .user, editingMessage == nil, manager.canTakeBackNewestTurn,
              let turn = ReviewSessionManager.newestSettledTurn(in: manager.chatMessages),
              manager.chatMessages[turn.userIndex].id == message.id,
              ChatEditMessage.isEditable(message) else { return nil }
        return { beginEditing(message) }
    }

    /// The message's words into the composer, its quote as a quote again;
    /// the send replaces it (`submitComposer`).
    @MainActor
    private func beginEditing(_ message: ReviewSessionManager.Message) {
        guard let exchangeID = message.exchangeID,
              let text = ReviewSessionManager.displayableMessageContent(role: .user, content: message.content)
        else { return }
        editingMessage = ChatEditMessage.Editing(
            exchangeID: exchangeID,
            stashedDraft: draft == lastInsertedDefaultPrompt ? "" : draft,
            stashedQuote: quotedPassage
        )
        if let quoted = ChatQuoteDraft.split(userMessage: text) {
            quotedPassage = quoted.quote
            draft = quoted.body
        } else {
            quotedPassage = ""
            draft = text
        }
        lastInsertedDefaultPrompt = nil
        requestComposerFocus()
    }

    /// Cancel on the editing line: the message stays as it was sent, and the
    /// composer gets back what it held before.
    @MainActor
    func cancelEditing() {
        guard let editing = editingMessage else { return }
        editingMessage = nil
        draft = editing.stashedDraft
        quotedPassage = editing.stashedQuote
        requestComposerFocus()
    }

    /// Opens the source a learner turn's quoted passage was selected in, in
    /// the Reader beside the chat with the words flashed — the way back to
    /// where the question came from (product owner, 2026-09-20). A block from before
    /// the `Source ID:` line names no source; then the chat's one source is
    /// it, or the source whose title the block's `Context:` label carries,
    /// chosen only among this chat's own sources.
    private func openPassageInReader(_ passage: ChatPassageOrigin.Passage) {
        var sourceID = passage.sourceID
        if sourceID == nil {
            let chatSourceIDs = Array(manager.loadedSourceIDs)
            if chatSourceIDs.count == 1 {
                sourceID = chatSourceIDs.first
            } else if let title = passage.contextTitle {
                let matches = chatSourceIDs.filter {
                    vm.articlesById[$0]?.title.trimmingCharacters(in: .whitespacesAndNewlines) == title
                }
                if matches.count == 1 { sourceID = matches.first }
            }
        }
        guard let sourceID else {
            vm.showToast("Source not found in library")
            return
        }
        Task { await vm.openLinkedSourceInReader(sourceID, passage: passage.quote, beside: .chat) }
    }

    // MARK: - Lifting an exchange out of a memory review

    /// True while this pane shows a memory review: the one chat whose turns
    /// offer to be discussed somewhere else, because here they are graded.
    var isMemoryReviewChat: Bool {
        guard let sessionID = manager.currentSessionID else { return false }
        return MemoryReviewSession.isMemorySession(sessionID)
    }

    /// The action for a memory review's saved turn, or nil where the button
    /// must not appear: an ordinary chat, or a turn that has not reached
    /// storage and so has no exchange to lift.
    private func discussInNewChatAction(for messages: [ReviewSessionManager.Message]) -> (() -> Void)? {
        guard isMemoryReviewChat,
              let exchangeID = messages.last(where: { $0.exchangeID != nil })?.exchangeID else { return nil }
        return { discussInNewChat(exchangeID: exchangeID) }
    }

    /// Lifts one exchange out of this review into a new chat. The exchange is
    /// read back from storage rather than from the messages on screen so the
    /// grade's idea coverage and the exchange's own sources come with it, and
    /// the review stays exactly where it is: its transcript, the chips waiting
    /// on Next or Go deeper, and the goal clock are untouched.
    private func discussInNewChat(exchangeID: String) {
        guard let sessionID = manager.currentSessionID else { return }
        let reviewTitle = manager.topic
        let fallbackSourceIDs = manager.linkedSourceIDs
        let openBeside = onOpenNewChatBeside
        Task {
            do {
                let exchanges = try await vm.storage.loadReviewSessionExchanges(sessionID: sessionID)
                guard let exchange = exchanges.first(where: { $0.id == exchangeID }) else {
                    manager.errorMessage = "This exchange has not been saved yet, so it cannot be discussed elsewhere."
                    return
                }
                let sourceIDs = exchange.sourceRefs.isEmpty ? fallbackSourceIDs : exchange.sourceRefs
                let ideas = try await vm.storage.loadSourceIdeas(sourceIDs: sourceIDs, includeRetired: true)
                    .values.flatMap { $0 }
                let handoff = MemoryReviewChatHandoff(
                    exchange: exchange,
                    reviewTitle: reviewTitle,
                    ideas: ideas,
                    fallbackSourceIDs: fallbackSourceIDs
                )
                let request = ReaderSelectionExplanationRequest(reviewHandoff: handoff)
                if let openBeside {
                    openBeside(request)
                } else {
                    vm.requestChatAboutReviewExchange(request)
                }
            } catch {
                manager.errorMessage = error.localizedDescription
            }
        }
    }

    /// This pane was asked to open a new chat on handed-in context. The
    /// running conversation, if any, is parked the way New chat parks it; the
    /// context is staged as the pending chip and its sources are attached, and
    /// the composer takes focus with nothing typed in it.
    @MainActor
    func handleNewChatHandoff() async {
        guard let handoff = sessionStore.pendingNewChatHandoff else { return }
        // A passage of a page the side chat is already working on joins that
        // chat, as ChatGPT's side chat continues one thread (product owner,
        // 2026-10-07: "you decide"; his 2026-09-29 rule already let a passage
        // join a chat on the same Doc): nothing is reset, a running turn keeps
        // running, and the passage waits under the composer beside what has
        // been typed. Checked before the park below, which a join must not do.
        if pageSideChat != nil, let opening = handoff.opening, let passage = handoff.request,
           opening.draft == nil, docPassageJoinsThisChat(passage) {
            defer { sessionStore.didConsumeNewChatHandoff(id: handoff.id) }
            pendingReaderSelection = passage
            for attachment in passage.imageAttachments { manager.attachImage(attachment) }
            let articles = (opening.sourceIDs.isEmpty ? passage.sourceIDs : opening.sourceIDs)
                .compactMap { vm.articlesById[$0] }
            if !articles.isEmpty { await addArticlesToChatContext(articles) }
            if let doc = opening.page.attachment { manager.addContextDoc(doc) }
            requestComposerFocus()
            return
        }
        // A running turn is parked in a fresh manager; the view is then rebuilt
        // around it and this task runs again with the same id, at which point
        // the store answers false and the staging below happens once.
        if sessionStore.prepareForNewChat(requestID: handoff.id) { return }
        defer { sessionStore.didConsumeNewChatHandoff(id: handoff.id) }

        // A walk this pane was playing is left the way its × leaves it, so
        // its outline comes off the page; its place is kept in its record.
        manager.leaveWalkthroughPlayback()
        manager.endSession()
        // A side question lifted out of a Notebook's quiz is filed beside it;
        // every other handoff — a Reader passage, Walk Through, What's New,
        // Find directions — is filed in the notebook its window holds, and
        // outside one starts an unfiled chat.
        // A page's side chat is filed in the page's Notebook, which frames the
        // chat as it frames one opened from the Notebook itself.
        let notebookID = handoff.request?.sideQuestionHandoff?.notebookID
            ?? handoff.opening?.page.notebookID
            ?? windowNotebookForNewChat
        linkedResearchNotebookID = notebookID.flatMap { vm.notebook(id: $0) != nil ? $0 : nil }
        clearComposer()
        manager.clearStagedSources()

        // What's New and Find directions go out as the new chat's first
        // turn; nothing waits under the composer.
        if let request = handoff.request, request.sendsAtOnce {
            Task { await startResearchUpdate(request) }
            return
        }

        pendingReaderSelection = handoff.request
        // A selection's pictures go into the new chat's tray with the passage.
        for attachment in handoff.request?.imageAttachments ?? [] { manager.attachImage(attachment) }

        // A new chat opened to play a walkthrough: the source attaches as the
        // walk's first step is played, and nothing waits under the composer.
        if let sourceID = handoff.walkthroughSourceID {
            await startWalkthroughPlayback(sourceID: sourceID)
            return
        }

        let articles = (handoff.opening?.sourceIDs ?? handoff.request?.sourceIDs ?? [])
            .compactMap { vm.articlesById[$0] }
        if !articles.isEmpty { await addArticlesToChatContext(articles) }
        if let opening = handoff.opening {
            // The page rides along by identity, so `read_doc` is offered for
            // all of it; the excerpt in a passage's message is one section.
            if let doc = opening.page.attachment { manager.addContextDoc(doc) }
            // A Prompt block's words wait under the composer, the writer's to
            // edit and send; machine-inserted, so a typed word replaces them.
            if let words = opening.draft {
                draft = words
                lastInsertedDefaultPrompt = words
            }
        }
        requestComposerFocus()
    }
}
