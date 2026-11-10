// The popover and page side chat layouts and the idle welcome of the chat panel.
import SwiftUI
import Combine
import AppKit

extension InternalReviewPanelContent {
    /// Chat renders at its own zoom: the app step plus whatever a pinch over
    /// this panel has added on top. Applied here rather than around the whole
    /// body so it covers everything chat draws — transcript, header, composer —
    /// while the panels beside it keep the app-wide size.
    var popoverLayout: some View {
        Group {
            if let card = pageSideChat {
                pageSideChatLayout(card)
            } else {
                minimalAssistantLayout
            }
        }
            .dynamicTypeSize(ChatZoom.size(appStep: uiZoomStep, offset: chatZoomOffset))
            .environment(\.uiZoomScale, uiZoomScale)
    }

    /// This panel's pinch offset, held by its session store so it belongs to
    /// this chat host alone and outlives a switch to another chat here.
    private var chatZoomOffset: Int { sessionStore.chatZoomOffset }

    /// Chat's own zoom scale. Read from the stored steps rather than the
    /// environment because this view is the one that *sets* the chat scale for
    /// its subtree — the environment here still holds the app-wide value.
    var uiZoomScale: CGFloat {
        ChatZoom.scale(appStep: uiZoomStep, offset: chatZoomOffset)
    }

    /// Move this chat one zoom step relative to the app UI. Returns false at the
    /// ends of the range so the pinch stops accumulating.
    func stepChatZoom(by delta: Int) -> Bool {
        guard let next = ChatZoom.offset(
            stepping: delta,
            appStep: uiZoomStep,
            offset: sessionStore.chatZoomOffset
        ) else { return false }
        sessionStore.chatZoomOffset = next
        return true
    }

    private var shouldShowTranscript: Bool {
        // The count, not the messages: reading `chatMessages` here would make
        // every streamed token re-evaluate this whole panel. See
        // `ReviewChatTranscriptStack`.
        manager.chatMessageCount > 0
            || manager.isPreparingGeneration
            || manager.isSearching
            || manager.isGenerating
            // Walk Through pressed in an empty chat: the wait for the first
            // step belongs under a working line, not behind the New chat
            // welcome screen.
            || manager.walkthroughPreparationDetail != nil
            // A dealt step adds no chat turn (`playWalkthroughStep`), so a
            // walk in an empty chat has no messages to count; its deck is in
            // the transcript panel, which the welcome screen otherwise hid.
            || manager.walkthroughPlayback != nil
            // Opening a saved chat swaps in a fresh manager, which rebuilds this
            // whole panel with an empty one for a frame before the resume starts.
            // Without this the learner's click on an existing conversation flashes
            // the New chat welcome — the one screen it certainly is not.
            || isResumePending
    }

    /// A saved chat has been clicked and its transcript has not landed yet. The
    /// request outlives the manager swap, so it is the only state that spans the
    /// blank frame between the two.
    var isResumePending: Bool {
        manager.isResumingSession
            || (requestedResumeSessionID != nil && manager.currentSessionID == nil)
    }

    /// A passage handed in from Reader or Docs makes this a contextual composer,
    /// even before the learner sends the first turn. Treating it as an idle chat
    /// leaves the unrelated greeting and suggestions competing with the passage.
    /// Include the global request so the welcome disappears on the same render
    /// that reveals Chat, without waiting for the task below to stage its chip.
    var hasPendingComposerContext: Bool {
        pendingReaderSelection != nil
            || sessionStore.pendingNewChatHandoff != nil
            || (acceptsGlobalRequests && vm.readerSelectionExplanationRequest != nil)
    }

    /// Whether to show the idle welcome hero: a docked/pop-out panel with no
    /// conversation or handed-in context. The bottom-sheet popover keeps its
    /// compact layout.
    var showsIdleWelcome: Bool {
        fillsAvailableSpace && !shouldShowTranscript && !hasPendingComposerContext
    }

    // MARK: - The page's side chat

    /// ChatGPT's page chat as a card (docs/pages-side-chat-design.md): a header,
    /// the transcript once a conversation exists, and the composer — this
    /// pane's own, so "+", the model, the mic, tools and citations all work.
    /// The card's frame, corners and shadow are drawn around this by
    /// `PageSideChatLayer`.
    private func pageSideChatLayout(_ card: PageSideChatPresentation) -> some View {
        VStack(spacing: 0) {
            pageSideChatHeader(card)
            if shouldShowTranscript {
                Divider()
                // A fixed region: the transcript is a web view that cannot
                // report how tall its content is (`PageSideChatLayout`).
                compactTranscriptPanel
                    .frame(height: PageSideChatLayout.transcriptHeight(paneHeight: card.paneHeight, zoom: uiZoomScale))
                Divider()
            } else if let error = manager.errorMessage ?? dictation.errorMessage ?? speech.errorMessage {
                errorText(error)
                    .padding(.horizontal, 14)
            }
            inputBar
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 10)
        }
    }

    /// Minimize, the chat's title with its menu, the actions (the page's chats,
    /// a new one, the way into the docked Chat pane) and the close ×.
    private func pageSideChatHeader(_ card: PageSideChatPresentation) -> some View {
        HStack(spacing: 4) {
            Button(action: card.onMinimize) {
                Image(systemName: "minus")
                    .zoomedSystemFont(size: 12, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: chatHeaderControlSize, height: chatHeaderControlSize)
            }
            .buttonStyle(.hoverWash(cornerRadius: chatHeaderControlSize / 2, inset: 0, opacity: 0.12))
            .help("Minimize")
            .accessibilityLabel("Minimize the page chat")
            .accessibilityIdentifier("mac.pageSideChatMinimize")

            Menu {
                pageSideChatChatsMenuItems(card)
            } label: {
                HStack(spacing: 4) {
                    Text(pageSideChatTitle)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .zoomedSystemFont(size: 9, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("This page's chats")
            .accessibilityIdentifier("mac.pageSideChatChats")

            Spacer(minLength: 0)

            Menu {
                pageSideChatActionItems(card)
            } label: {
                Image(systemName: "circle.grid.2x3.fill")
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                    .frame(width: chatHeaderControlSize, height: chatHeaderControlSize)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .hoverHighlight(cornerRadius: chatHeaderControlSize / 2, inset: 0, opacity: 0.12)
            .help("More chat actions")
            .accessibilityLabel("More chat actions")
            .accessibilityIdentifier("mac.pageSideChatActions")

            // The card goes away and lets go of its chat, which stays saved
            // and listed under the page; minimize is the way to keep it.
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .zoomedSystemFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: chatHeaderControlSize, height: chatHeaderControlSize)
            }
            .buttonStyle(.hoverWash(cornerRadius: chatHeaderControlSize / 2, inset: 0, opacity: 0.12))
            .help("Close")
            .accessibilityLabel("Close the page chat")
            .accessibilityIdentifier("mac.pageSideChatClose")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// The header's title: the chat's own, or "New chat" before it has a row.
    private var pageSideChatTitle: String { selectedChatTitle ?? "New chat" }

    /// The title's menu: this page's chats, the open one ticked, then a new
    /// chat and the docked pane.
    @ViewBuilder
    private func pageSideChatChatsMenuItems(_ card: PageSideChatPresentation) -> some View {
        if !card.chats.isEmpty {
            Section("Chats about this page") {
                ForEach(card.chats) { chat in
                    Button {
                        card.onOpenChat(chat.id)
                    } label: {
                        if chat.id == manager.currentSessionID {
                            Label(PageSideChatChats.title(of: chat), systemImage: "checkmark")
                        } else {
                            Text(PageSideChatChats.title(of: chat))
                        }
                    }
                }
            }
            Divider()
        }
        Button {
            card.onNewChat()
        } label: {
            Label("New Chat", systemImage: "square.and.pencil")
        }
        pageSideChatOpenInChatButton(card)
    }

    /// The ⋮⋮ menu: the docked pane, this chat's address and its transcript.
    /// "Open in Other Window" is not here: the card shows the chat, and a
    /// second window would draw it again.
    @ViewBuilder
    private func pageSideChatActionItems(_ card: PageSideChatPresentation) -> some View {
        pageSideChatOpenInChatButton(card)
        if let sessionID = manager.currentSessionID {
            Divider()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    StudioEntityLink.chat(sessionID).markdownDestination,
                    forType: .string
                )
                vm.showToast("Link copied")
            } label: {
                Label("Copy Link", systemImage: "link")
            }
            Button {
                copyConversation()
            } label: {
                Label("Copy Conversation", systemImage: "doc.on.doc")
            }
            .disabled(manager.chatMessages.isEmpty)
        }
    }

    /// Moves this chat into the docked Chat pane. Between turns only: the card
    /// letting go of a running turn would stop it.
    private func pageSideChatOpenInChatButton(_ card: PageSideChatPresentation) -> some View {
        Button {
            card.onOpenInChat()
        } label: {
            Label("Open in Chat", systemImage: "arrow.up.right.square")
        }
        .disabled(manager.currentSessionID == nil || isTurnInFlight)
    }

    private var minimalAssistantLayout: some View {
        VStack(spacing: 8) {
            if shouldShowTranscript {
                compactTranscriptPanel
            }
            if showsIdleWelcome {
                // ChatGPT's empty chat: the greeting, the composer and the few
                // starting points under it stand together as one group a little
                // above the middle, and the composer slides to the foot once
                // the chat begins. The 2026-10-11 Codex layout (greeting in the
                // middle, composer pinned to the foot, suggestions just above
                // it) left a void between them (product owner, 2026-11-08:
                // "this spacing looks terrible").
                Spacer(minLength: 12)
                idleWelcomeHeading
                    .padding(.bottom, StudioDesign.Spacing.large)
                    .transition(.opacity)
                    .task(id: vm.hasCompletedInitialQueueLoad) { await refreshReadNextSuggestions() }
            }
            if !shouldShowTranscript,
               let error = manager.errorMessage ?? dictation.errorMessage ?? speech.errorMessage {
                errorText(error)
                    .frame(maxWidth: chatColumnMaxWidth)
            }
            if let snapshot = teamSnapshotRecord {
                // A transcript a team shares is read: nobody continues it, so
                // the composer gives way to a line saying where it came from.
                sharedTranscriptFooter(snapshot)
                    .frame(maxWidth: chatColumnMaxWidth)
            } else if !hidesComposerForMemoryCard {
                // One width with or without a transcript, so the first send
                // leaves the composer where it was.
                inputBar
                    .frame(maxWidth: chatColumnMaxWidth)
            }
            // After the composer, so the composer keeps its place in the view
            // tree (and its focus) when the first send swaps the welcome for
            // the transcript. The suggestions take the composer's width, so
            // their rows line up under its edges.
            if showsIdleWelcome {
                idleWelcomeOffers
                    .frame(maxWidth: chatColumnMaxWidth)
                    .padding(.top, StudioDesign.Spacing.xSmall)
                    .transition(.opacity)
                // Twice the space above the group, which lifts it to about
                // two fifths of the way down, where ChatGPT's sits.
                Spacer(minLength: 12)
                Spacer(minLength: 12)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: shouldShowTranscript)
        .frame(maxWidth: .infinity)
        // ⌘F finds in this chat while focus, or the last click, is in it; a
        // Reader beside it keeps ⌘F otherwise.
        .background(ReaderShortcutTarget(find: { chatFind.show() }, isPrimaryCandidate: false))
        .contentShape(Rectangle())
        .onDrop(
            of: reviewChatDropTypes,
            isTargeted: dropTargetBinding,
            perform: handleDrop
        )
    }

    // MARK: - Idle welcome (empty chat)

    /// One suggested next step shown as a row while the chat is empty. Each is
    /// backed by live app state — today's plan, the latest saved session, or the
    /// source open in the reader. The two fixed prompts are the workflows every
    /// learner starts from: planning the day and setting a goal.
    private struct IdleSuggestion: Identifiable {
        let id: String
        let systemImage: String
        let title: String
        /// What hiding this row remembers. Scoped to the thing being suggested
        /// rather than the row's category — see `IdleSuggestionDismissals`.
        let dismissalKey: String
        let action: @MainActor () async -> Void
        /// Where the row opens something another window can show instead —
        /// a chat to resume — for its right-click Open in Other Window.
        var otherWindowDestination: StudioWindowDestination? = nil
        /// Why this row is on offer, shown on hover. Nil for rows whose
        /// title already says it.
        var help: String? = nil
        /// Today's plan: the row opens it in a popover instead of running
        /// `action`.
        var todayPlan: IdleTodayPlan? = nil
    }

    /// Today's pending planned items and what can be done with them: the
    /// plan's own row opens them.
    private struct IdleTodayPlan {
        let items: [SchedulePlanItem]
        let start: (SchedulePlanItem) -> Void
        let markDone: (SchedulePlanItem) -> Void
        let quiz: () -> Void
    }

    /// How many suggestions the empty chat offers under the composer: ChatGPT
    /// offers a few starting points and no more (product owner, 2026-10-06: "cleaner
    /// and fewer buttons and bells and whistles"). The rest wait their turn:
    /// hiding one brings up the next.
    static let idleSuggestionLimit = 3

    /// Names the Notebook rather than the hour. What the learner came here for is
    /// the work, not the time of day, and the Notebook name earns the largest
    /// type on an otherwise empty chat.
    ///
    /// Keyed on the Notebook this chat is *linked* to, not the one open in the
    /// Notebooks overlay: a chat that hasn't adopted it isn't working in it, and
    /// heading it with that name would misstate where answers come from.
    private var idleGreetingTitle: String {
        linkedResearchNotebook?.title ?? timeOfDayGreeting
    }

    private var timeOfDayGreeting: String {
        let base: String
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: base = "Good morning"
        case 12..<18: base = "Good afternoon"
        default: base = "Good evening"
        }
        guard let name = MacAccountUser.firstName else { return base }
        return "\(base), \(name)"
    }

    /// Today's plan, as its row names it: what is still planned for today,
    /// and which goal it serves. It deliberately never congratulates: the app
    /// cannot see whether anything was understood — only that no planned item
    /// is outstanding — and an empty plan is the ordinary state, not an
    /// achievement.
    private func idleTodayPlanTitle(_ schedule: IdleScheduleSnapshot) -> String {
        let pending = schedule.pendingToday
        let count = pending.count == 1 ? "1 source" : "\(pending.count) sources"
        let completedToday = schedule.today?.completedCount ?? 0
        let progress = completedToday > 0 ? "\(count) to go today" : "\(count) planned today"
        let goalTitles = orderedUniqueGoalTitles(in: pending)
        if goalTitles.count == 1, let goal = goalTitles.first {
            return "\(progress) for \u{201C}\(goal)\u{201D}"
        }
        return progress
    }

    private func orderedUniqueGoalTitles(in items: [SchedulePlanItem]) -> [String] {
        var seen = Set<String>()
        var titles: [String] = []
        for tag in items.flatMap(\.goalTags) {
            let title = tag.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, seen.insert(title).inserted else { continue }
            titles.append(title)
        }
        return titles
    }

    /// What the empty chat shows above the composer: in a notebook workspace,
    /// the chat filed in the window's notebook shows that notebook's heading;
    /// everywhere else the greeting.
    @ViewBuilder
    private var idleWelcomeHeading: some View {
        if let notebook = notebookGuideNotebook {
            let notebookTitle = NotebookTitle(notebook.title)
            NotebookChatGuideHeading(
                notebookID: notebook.id,
                icon: notebookTitle.displayIcon,
                title: notebookTitle.text.isEmpty ? "Untitled notebook" : notebookTitle.text,
                summary: notebook.displaySummary,
                columnWidth: idleWelcomeColumnWidth
            )
        } else {
            // The greeting alone. Its subtitle went on 2026-10-06: most days
            // it said "Ready when you are.", and the day's plan it otherwise
            // named is the first suggestion under the composer.
            Text(idleGreetingTitle)
                .font(.system(size: 24, weight: .medium, design: .serif))
                // Notebook titles run longer than "Good afternoon".
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: idleWelcomeColumnWidth)
                .frame(maxWidth: .infinity)
        }
    }

    /// What the empty chat offers under the composer: the notebook guide's
    /// chips and chats, or at most `idleSuggestionLimit` suggestions.
    @ViewBuilder
    private var idleWelcomeOffers: some View {
        if let context = manager.canvasContext {
            // A chat about a canvas: its questions, when it has any, and the
            // maps the canvas can draw from the cards.
            VStack(alignment: .leading, spacing: StudioDesign.Spacing.small) {
                if !canvasSuggestedQuestions.isEmpty {
                    canvasQuestionCards
                }
                // The Ask draws on the canvas open on this Mac: not offered
                // for another canvas's cards.
                if context.canvasID == vm.knowledgeMap.mapID {
                    KnowledgeMapChatOffers(offersQuestionMap: context.holdsQuestion) { tool in
                        vm.startCanvasAsk(tool, from: context)
                    }
                }
            }
        } else if !canvasSuggestedQuestions.isEmpty {
            canvasQuestionCards
        } else if let notebook = notebookGuideNotebook {
            notebookGuide(notebook)
        } else {
            homeOffers
        }
    }

    /// How many saved sources Home's empty chat lists under the composer.
    static let homeToReadLimit = 6

    /// Home's empty chat, outside a notebook or a canvas: what the learner
    /// saved and has not finished, newest first, in place of the suggestions
    /// (product owner, 2026-11-09: "it just opens cleanly and it shows basically
    /// a list of recent things we added to the reading list"). With nothing
    /// waiting, the suggestions as before.
    @ViewBuilder
    private var homeOffers: some View {
        let waiting = vm.toReadSources()
        if waiting.isEmpty {
            idleSuggestions
        } else {
            HomeToReadList(
                sources: Array(waiting.prefix(Self.homeToReadLimit)),
                totalCount: waiting.count,
                // As the Read next suggestion opens its source.
                open: { sourceID in Task { await vm.openSourceInReader(sourceID) } },
                showAll: windowState.map { state in { vm.openLibraryRecent(in: state) } }
            )
        }
    }

    /// The questions drawn from the canvas this chat was opened beside: a
    /// click puts one in the composer, to send or to change.
    private var canvasQuestionCards: some View {
        ChatSuggestedQuestionCards(
            questions: canvasSuggestedQuestions,
            fontSize: 13,
            maxWidth: idleComposerMaxWidth,
            send: fillComposerWithCanvasQuestion
        )
        .accessibilityIdentifier("chat.canvasQuestions")
    }

    /// The composer takes the question: in place of what it holds when that
    /// is empty or was put there by the app, else on a line of its own.
    private func fillComposerWithCanvasQuestion(_ question: String) {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft == lastInsertedDefaultPrompt {
            draft = question
            lastInsertedDefaultPrompt = question
        } else {
            draft += "\n\(question)"
            lastInsertedDefaultPrompt = nil
        }
        vm.reviewChatFocusRequestID = UUID()
    }

    /// The notebook whose guide this empty chat shows: the one the chat is
    /// filed in, while its window holds that notebook.
    var notebookGuideNotebook: LearningGoalRecord? {
        guard let notebook = linkedResearchNotebook,
              windowState?.NotebookID == notebook.id else { return nil }
        return notebook
    }

    /// The notebook guide under the composer (`NotebookChatGuide`): no model
    /// call on open — the chips that ask when pressed, and the notebook's
    /// chats. Its heading, `NotebookChatGuideHeading`, stands above the
    /// composer.
    private func notebookGuide(_ notebook: LearningGoalRecord) -> some View {
        let tally = vm.notebookChatTally(notebook)
        // Read again when this chat keeps or asks a question, or another
        // device's row arrives.
        _ = notebookQuestionsRevision
        return NotebookChatGuide(
            inChat: tally.inChat,
            total: tally.total,
            columnWidth: idleWelcomeColumnWidth,
            chats: vm.notebookChats(notebookID: notebook.id)
                .filter { $0.id != manager.currentSessionID }
                .map { NotebookChatGuide.RecentChat(id: $0.id, title: $0.title.isEmpty ? "Untitled chat" : $0.title, date: $0.createdAt) },
            questions: vm.notebookQuestionOffer(notebook),
            suggestQuestions: {
                Task { await suggestNotebookQuestions() }
            },
            askQuestion: { question in
                clearComposer()
                pendingReaderSelection = nil
                askSuggestedQuestion(question)
            },
            review: {
                Task { await startNotebookReviewFromIdle(notebook) }
            },
            teachBack: {
                Task { await startNotebookTeachBackFromIdle(notebook) }
            },
            openChat: { sessionID in
                if let windowState {
                    vm.inWindow(windowState) { vm.requestResumeReviewSession(sessionID) }
                } else {
                    vm.requestResumeReviewSession(sessionID)
                }
            }
        )
        .onReceive(NotificationCenter.default.publisher(for: PreferenceStore.didChangeRemotely)) { note in
            let keys = note.userInfo?[PreferenceStore.changedKeysKey] as? Set<String> ?? []
            if keys.contains(where: { $0.hasPrefix(NotebookSuggestedQuestions.preferenceKeyPrefix) }) {
                notebookQuestionsRevision &+= 1
            }
        }
        // Chat › Side Chat (⌥⌘S, Codex's key): the window's docked chat opens
        // its side chat about the whole conversation, as `/side` does.
        .onReceive(NotificationCenter.default.publisher(for: .openThreadSideChat)) { note in
            guard let windowState, note.object as? UUID == windowState.id,
                  let sessionID = manager.currentSessionID, sessionID == windowState.chatSessionID else { return }
            openThreadSideChat()
        }
    }

    /// The guide's Suggest questions: the request goes out as the learner's
    /// message, and the answer's suggested questions are its cards. They are
    /// kept with the notebook, for its sources as they stand now, so the
    /// guide offers them in its next chats without asking a model again
    /// (`NotebookSuggestedQuestions`).
    @MainActor
    private func suggestNotebookQuestions() async {
        guard !manager.isSearching, !manager.isGenerating else { return }
        let notebookID = linkedResearchNotebook?.id
        clearComposer()
        pendingReaderSelection = nil
        await sendReviewChatMessage(NotebookChatGuide.suggestQuestionsPrompt)
        guard let notebookID, let notebook = vm.notebooks.first(where: { $0.id == notebookID }),
              let questions = manager.chatMessages.last(where: { $0.role == .assistant })?.followUpQuestions,
              !questions.isEmpty else { return }
        vm.keepNotebookQuestions(questions, notebook: notebook)
        notebookQuestionsRevision &+= 1
    }

    /// At most `idleSuggestionLimit` suggestions under the composer, as quiet
    /// rows with no card around them and no header (2026-10-06, ChatGPT's
    /// new chat; they were a card of up to seven under a Today card), in the
    /// order `allIdleSuggestions` ranks them; the restore link once every one
    /// has been hidden.
    @ViewBuilder
    private var idleSuggestions: some View {
        let state = idleWelcomeState(idleScheduleSnapshot)
        if state.hasContent {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(state.suggestions) { suggestion in
                    IdleSuggestionRow(suggestion: suggestion) {
                        withAnimation(.easeOut(duration: 0.18)) {
                            IdleSuggestionDismissals.shared.dismiss(suggestion.dismissalKey)
                        }
                    }
                }
                if state.showsRestore {
                    restoreIdleSuggestionsButton
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, StudioDesign.Spacing.small)
        }
    }

    /// Shown only once everything on offer has been hidden. Dismissals are
    /// allowed to be permanent precisely because this exists: the quietest
    /// possible way back, and absent entirely while anything is still on screen.
    private var restoreIdleSuggestionsButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                IdleSuggestionDismissals.shared.restoreAll()
            }
        } label: {
            Text("Show suggestions")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash)
        .help("Bring back everything you've hidden here")
    }

    /// One suggested action as a quiet row under the composer: a bare
    /// monochrome glyph and the title in secondary type, brightening under the
    /// pointer, and a dismiss button that appears with it. No chevron, no card:
    /// ChatGPT's starting points read as text, not as a panel.
    ///
    /// The action and the dismiss are siblings sharing one background rather than
    /// nested buttons — a Button inside another Button's label swallows clicks
    /// unpredictably on macOS. The dismiss keeps its slot in the layout while
    /// invisible so the title doesn't reflow under the cursor. The row paints
    /// its own hover wash, so its action button takes `.plain`.
    private struct IdleSuggestionRow: View {
        let suggestion: IdleSuggestion
        let onDismiss: () -> Void
        @State private var isHovered = false
        @State private var isShowingTodayPlan = false

        private var dismissGlyph: some View {
            Image(systemName: "xmark")
                .zoomedSystemFont(size: 8, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Circle())
        }

        var body: some View {
            HStack(spacing: 0) {
                Button {
                    if suggestion.todayPlan != nil {
                        isShowingTodayPlan = true
                    } else {
                        Task { await suggestion.action() }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: suggestion.systemImage)
                            .zoomedSystemFont(size: 12, weight: .regular)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(suggestion.title)
                            .font(.system(size: 13))
                            .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(suggestion.help ?? "")
                .accessibilityIdentifier("mac.chatSuggestion.\(suggestion.id)")
                .popover(isPresented: $isShowingTodayPlan, arrowEdge: .bottom) {
                    if let plan = suggestion.todayPlan {
                        IdleTodayPlanList(plan: plan) { isShowingTodayPlan = false }
                    }
                }

                // Built only under the pointer, so a stale tracking state can
                // never turn a click into a dismissal the learner couldn't see
                // coming, and a hidden glyph holds its place. A button at
                // opacity 0 is still a live control, and while an assistive
                // app reads the screen SwiftUI walks every control in the
                // window for each one an update builds (2026-10-03).
                Group {
                    if isHovered {
                        Button(action: onDismiss) {
                            dismissGlyph
                        }
                        .buttonStyle(.hoverWash(in: Circle(), inset: 0, opacity: 0.10))
                        .help("Hide this suggestion")
                        .accessibilityLabel("Hide suggestion: \(suggestion.title)")
                    } else {
                        dismissGlyph
                            .hidden()
                    }
                }
                .padding(.trailing, 6)
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.05 : 0))
            )
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            // Right-click reaches the same dismiss without depending on hover,
            // which a keyboard- or trackpad-averse pass over the row never gets.
            .contextMenu {
                if let destination = suggestion.otherWindowDestination {
                    OtherWindowMenuItem(destination)
                    Divider()
                }
                Button("Hide This Suggestion", action: onDismiss)
            }
        }
    }

    /// The schedule facts the idle welcome is built from, resolved once per
    /// render. The greeting, the suggestions and the welcome state would each
    /// rebucket the whole Schedule for themselves, so an empty chat would rebuild
    /// it four to six times per body pass. Pure/in-memory.
    private struct IdleScheduleSnapshot {
        /// Today's row on the unified Schedule across all goals.
        let today: ScheduleDay?
        /// Pending items planned for today across all Schedules.
        let pendingToday: [SchedulePlanItem]
        /// Deliberate placements still live: planned for any future day, or
        /// overdue by less than `idleSuggestionRecency`. Automatic activity
        /// anchors never appear here — `scheduledSources` carries them, but
        /// they are history, not a plan.
        let livePlacements: [ScheduledSourceEntry]

        init(
            today: ScheduleDay?,
            livePlacements: [ScheduledSourceEntry],
            isSourceVisible: (String) -> Bool = { _ in true }
        ) {
            self.today = today
            self.pendingToday = today?.items.filter { !$0.isCompleted && isSourceVisible($0.sourceID) } ?? []
            self.livePlacements = livePlacements
        }
    }

    private var idleScheduleSnapshot: IdleScheduleSnapshot {
        // Screen record mode: only the recording Notebook's sources and safe
        // public captures from the take are planned on screen.
        let isSourceVisible: (String) -> Bool = { vm.isSourceIDVisibleInRecordingMode($0) }
        let earliest = Date().addingTimeInterval(-Self.idleSuggestionRecency)
        return IdleScheduleSnapshot(
            today: vm.unifiedScheduleDays(containing: Date()).first(where: \.isToday),
            livePlacements: vm.scheduledSources.filter { entry in
                !entry.isAutomatic
                    && !entry.placement.isCompleted
                    && entry.placement.plannedAt >= earliest
                    && isSourceVisible(entry.placement.sourceID)
            },
            isSourceVisible: isSourceVisible
        )
    }

    /// Day-scoped, so hiding today's plan clears today only — tomorrow's plan
    /// still gets to introduce itself.
    private var idleTodayScheduleDismissalKey: String {
        "today-schedule:\(IdleSuggestionDismissals.dayScope())"
    }

    /// Today's plan in its row's popover: every pending planned item, each
    /// row opening its source and its leading circle checking it off — the
    /// one completion by hand (schedule-design.md) — and Quiz me on these
    /// under them, which starts a review of the whole day. Planning itself
    /// happens in the conversation. The welcome keeps only its greeting
    /// and a few suggestions (the product owner: "cleaner and fewer buttons and bells
    /// and whistles"), so the plan sits behind its row.
    private struct IdleTodayPlanList: View {
        let plan: IdleTodayPlan
        let close: () -> Void

        /// Taller than this, the list scrolls.
        private static let rowsBeforeScrolling = 8

        private var rows: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(plan.items) { item in
                    IdleScheduleItemRow(
                        item: item,
                        action: {
                            close()
                            plan.start(item)
                        },
                        onMarkDone: { plan.markDone(item) }
                    )
                }
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                if plan.items.count > Self.rowsBeforeScrolling {
                    ScrollView { rows }
                        .frame(height: 300)
                } else {
                    rows
                }

                // The day's primary action under the list it acts on.
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 1)
                    .padding(.top, 2)
                Button {
                    close()
                    plan.quiz()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle")
                            .zoomedSystemFont(size: 12, weight: .medium)
                            .foregroundStyle(.primary)
                            .frame(width: 20)
                        Text(plan.items.count == 1 ? "Quiz me on this source" : "Quiz me on these")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash)
                .help("Start a review of today's sources")
            }
            .padding(.vertical, 10)
            .frame(width: 340, alignment: .leading)
        }
    }

    /// One pending planned item in today's plan. Clicking the row starts
    /// the item: source into context, opened in the reader, chat kept alongside.
    /// The leading circle is the only way this list ever gets checked off by
    /// hand — opening a source records history, never completion — so it is a
    /// real control rather than a bullet, and a sibling of the open button
    /// rather than nested inside it (a Button inside another Button's label
    /// swallows clicks on macOS).
    private struct IdleScheduleItemRow: View {
        let item: SchedulePlanItem
        let action: () -> Void
        let onMarkDone: () -> Void
        @State private var isHovered = false
        @State private var isCheckHovered = false

        /// What the app has actually seen happen with this source today. Never
        /// a completion claim — that is what the check is for.
        private var activityHint: String? {
            if item.activityKinds.contains(.review) { return "reviewed" }
            if item.activityKinds.contains(.chat) { return "discussed" }
            if item.activityKinds.contains(.listening) { return "played" }
            if item.activityKinds.contains(.watching) { return "played" }
            if item.activityKinds.contains(.reading) { return "opened" }
            return nil
        }

        var body: some View {
            HStack(spacing: 0) {
                Button(action: onMarkDone) {
                    Image(systemName: isCheckHovered ? "checkmark.circle" : "circle")
                        .zoomedSystemFont(size: 11)
                        .foregroundStyle(isCheckHovered ? Color.primary : Color.secondary.opacity(0.55))
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .buttonStyle(.hoverWash(in: Circle(), inset: 0))
                .onHover { isCheckHovered = $0 }
                .padding(.leading, 8)
                .help("Mark as done")
                .accessibilityLabel("Mark done: \(item.title)")

                Button(action: action) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.title)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let activityHint {
                            Text(activityHint)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .zoomedSystemFont(size: 8, weight: .semibold)
                            .foregroundStyle(.tertiary)
                            .opacity(isHovered ? 1 : 0)
                    }
                    .padding(.leading, 4)
                    .padding(.trailing, 12)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(item.isMissingSource)
                .opensInOtherWindow(sourceID: item.isMissingSource ? nil : item.sourceID)
                .help("Open this source")
            }
            .background(Color.primary.opacity(isHovered ? 0.05 : 0))
            .onHover { isHovered = $0 }
        }
    }

    /// The Notebook a fresh chat should suggest reviewing: the active Notebook
    /// when it has approved sources, otherwise any Notebook that does.
    var idleSuggestedReviewNotebook: LearningGoalRecord? {
        let candidates = vm.notebooks.filter { !$0.approvedSourceIDs.isEmpty }
        if let activeID = vm.activeNotebookId,
           let active = candidates.first(where: { $0.id == activeID }) {
            return active
        }
        return candidates.first
    }

    /// How stale a suggestion may be before it stops being a suggestion. A plan
    /// abandoned two months ago is not the next thing to do, and offering it
    /// as one is how this screen came to advertise work nobody meant to resume.
    private static let idleSuggestionRecency: TimeInterval = 14 * MemoryTutorScheduler.secondsPerDay

    /// The most overdue still-live placement, resolved through the day model so
    /// the row can start it exactly like today's plan does. Used when today is
    /// clear but the plan has recent work left elsewhere.
    private func idleNextScheduledItem(
        in livePlacements: [ScheduledSourceEntry]
    ) -> (item: SchedulePlanItem, goalTitle: String?)? {
        guard let next = livePlacements
            .min(by: { $0.placement.plannedAt < $1.placement.plannedAt }) else { return nil }
        // The day model drops placements whose source was archived or deleted,
        // so a resolved item is also proof the source is still openable.
        guard let item = vm.unifiedScheduleDays(containing: next.placement.plannedAt)
            .flatMap(\.items)
            .first(where: { $0.id == next.id }) else { return nil }
        return (item, item.goalTags.first?.title)
    }

    private static func readNextDismissalKey(_ pick: ReadNextSuggestion) -> String {
        "read-next:\(pick.sourceID)"
    }

    /// How many picks to hold, so hiding one has a next to fall back on.
    private static let readNextPickCount = 5

    /// Kinds of source a learner reads, watches or listens to on their own
    /// time. Meetings, course handouts and posts are left out: a meeting was
    /// attended, not queued, and a post is too slight to be the next thing.
    private static let readNextSourceTypes: Set<StudioSourceType> = [.article, .paper, .book, .podcast, .video, .manual]

    /// Its own storage actor and connection. The first ranking of a session
    /// loads every chunk vector into the shared index, which takes seconds on
    /// a large library; on the view model's storage lane that load would sit
    /// in front of the next chat send.
    private static let readNextStorage = StorageService()

    /// Finds the "Read next" picks for the empty chat. The pool is gathered
    /// here from what the active library already holds in memory; the ranking
    /// (`StorageService.readNextSuggestions`) reads the database and the
    /// vector index on `readNextStorage`, at utility priority.
    private func refreshReadNextSuggestions() async {
        guard vm.hasCompletedInitialQueueLoad else { return }
        let planned = Set(vm.scheduledSources.lazy.filter { !$0.placement.isCompleted }.map(\.placement.sourceID))
        let candidates = Set(vm.articles.lazy.filter { article in
            article.state == .ready
                && article.status == .active
                && !article.isHidden
                && Self.readNextSourceTypes.contains(article.sourceType)
                && !planned.contains(article.id)
                && vm.isSourceIDVisibleInRecordingMode(article.id)
        }.map(\.id))
        let storage = Self.readNextStorage
        let limit = Self.readNextPickCount
        let result = await Task(priority: .utility) {
            try await storage.readNextSuggestions(candidateIDs: candidates, limit: limit)
        }.result
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let picks):
            readNextSuggestions = picks
        case .failure(let error):
            vm.logger.error("Read next suggestions failed: \(error.localizedDescription, privacy: .public)")
            readNextSuggestions = []
        }
    }

    /// Sending this opens the Learning goal workflow in the tutor prompt:
    /// confirm topic and deadline, create the Notebook and Goal, discover and
    /// approve sources, then pace them onto the Schedule.
    static let setGoalPrompt = "I want to set a learning goal. Help me settle on the topic and deadline, find sources for it in my library, and plan a schedule."

    /// Every suggestion the current state supports, most useful first, before
    /// the learner's dismissals are applied. `idleWelcomeState` filters this
    /// down to what renders — keeping both lets the empty state tell "nothing
    /// to suggest" apart from "everything suggested has been hidden".
    private func allIdleSuggestions(_ schedule: IdleScheduleSnapshot) -> [IdleSuggestion] {
        var suggestions: [IdleSuggestion] = []

        // Today's plan leads, as its card stood over everything else until
        // 2026-10-06; its row opens the plan (`IdleTodayPlanList`).
        if !schedule.pendingToday.isEmpty {
            let items = schedule.pendingToday
            suggestions.append(IdleSuggestion(
                id: "today-plan",
                systemImage: "checklist",
                title: idleTodayPlanTitle(schedule),
                dismissalKey: idleTodayScheduleDismissalKey,
                action: {},
                help: "Today's plan: open a source, check one off, or quiz yourself on them",
                todayPlan: IdleTodayPlan(
                    items: items,
                    start: { item in Task { await vm.startScheduleItem(item) } },
                    markDone: { item in Task { await vm.markScheduleSourceDone(sourceID: item.sourceID) } },
                    quiz: { Task { await startTodayReviewFromIdle(items) } }
                )
            ))
        }

        if let plan = vm.memoryCompanionPlan, !plan.isEmpty {
            suggestions.append(IdleSuggestion(
                id: "memory-check",
                systemImage: "brain.head.profile",
                title: "Memory check · \(MemoryReviewBudget.clamp(memoryBudgetMinutes)) min",
                dismissalKey: "memory-check:\(StudioViewModel.dailyReviewPlanCacheDay())",
                action: { await startMemoryCompanionFromIdle(plan) }
            ))
        }

        // When today has pending sources, the quiz action lives in today's
        // plan (IdleTodayPlanList's footer), right under the list it acts on —
        // so it isn't repeated as a suggestion row here. The continue/review
        // fallbacks are only for when today is already clear.
        if schedule.pendingToday.isEmpty {
            if let next = idleNextScheduledItem(in: schedule.livePlacements) {
                // Nothing left for today, but the Schedule still has work —
                // point at it rather than falling back to a generic review.
                let title = next.goalTitle.map { "Continue \u{201C}\($0)\u{201D}" } ?? "Continue your schedule"
                suggestions.append(IdleSuggestion(
                    id: "continue-schedule",
                    systemImage: "arrow.forward.circle",
                    title: title,
                    dismissalKey: "continue-schedule:\(next.item.id)",
                    action: { await vm.startScheduleItem(next.item) }
                ))
            } else if let notebook = idleSuggestedReviewNotebook {
                suggestions.append(IdleSuggestion(
                    id: "notebook-review",
                    systemImage: "graduationcap",
                    title: "Review \u{201C}\(notebook.title)\u{201D}",
                    dismissalKey: "notebook-review:\(notebook.id)",
                    action: { await startNotebookReviewFromIdle(notebook) }
                ))
            }
        }

        // Planning the day is the one thing worth doing in any empty chat, so it
        // is always on offer. By the afternoon it plans tomorrow, the same turn
        // `/plan` takes, and hiding it hides it for the rest of the day only.
        let plansTomorrow = Calendar.current.component(.hour, from: Date()) >= DayPlan.planTomorrowFromHour
        suggestions.append(IdleSuggestion(
            id: "plan-day",
            systemImage: "calendar.day.timeline.left",
            title: plansTomorrow ? "Plan tomorrow" : "Plan my day",
            dismissalKey: "plan-day:\(DayPlan.dateString(for: Date()))",
            action: { await startPlanDayFromIdle() }
        ))

        // Only a chat from the last two weeks is something to "resume". The
        // list is newest-first, so an old first entry means there is nothing
        // recent — not that this one deserves promoting.
        if let session = vm.filteredReviewSessionLinks().first(where: \.isLocalMCPSession),
           session.createdAt >= Date().addingTimeInterval(-Self.idleSuggestionRecency) {
            let sessionTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sessionTitle.isEmpty {
                suggestions.append(IdleSuggestion(
                    id: "resume-session",
                    systemImage: "clock.arrow.circlepath",
                    title: "Resume \u{201C}\(sessionTitle)\u{201D}",
                    dismissalKey: "resume-session:\(session.id)",
                    action: { await openPickedSession(session) },
                    otherWindowDestination: session.isLocalMCPSession ? .chat(session.id) : nil
                ))
            }
        }

        // The first pick not already hidden, so declining one surfaces the
        // next. When every pick is hidden the first one stands for them, which
        // keeps "everything hidden" true for the restore link.
        let readNextPicks = readNextSuggestions.filter { vm.articlesById[$0.sourceID] != nil }
        if let pick = readNextPicks.first(where: { !IdleSuggestionDismissals.shared.isDismissed(Self.readNextDismissalKey($0)) })
            ?? readNextPicks.first,
           let article = vm.articlesById[pick.sourceID] {
            let verb: String
            switch article.sourceType {
            case .podcast: verb = "Listen to"
            case .video: verb = "Watch"
            default: verb = "Read"
            }
            let nearestTitle = vm.articlesById[pick.nearestReadSourceID]?.title
            suggestions.append(IdleSuggestion(
                id: "read-next",
                systemImage: "books.vertical",
                title: "\(verb) \u{201C}\(article.title)\u{201D}",
                dismissalKey: Self.readNextDismissalKey(pick),
                action: { await vm.openSourceInReader(pick.sourceID) },
                help: nearestTitle.map { "Close to \u{201C}\($0)\u{201D}, from your recent reading" }
            ))
        }

        // `selectedArticle` outlives the reader that showed it, so this asked
        // about a source that had not been on screen for days. Offer it only
        // while a Reader in this chat's own window shows it — the key
        // window's tabs and the app-wide Reader flag said nothing about this
        // one — and not for a source the learner left out of the chat.
        let leftOut = manager.onScreenSourcesLeftOut
        if let shown = sourcesOnScreenBesideChat.first(where: { !leftOut.contains($0.id) }),
           let article = vm.articlesById[shown.id] {
            suggestions.append(IdleSuggestion(
                id: "explain-reading",
                systemImage: "text.book.closed",
                title: "Explain what I'm reading",
                dismissalKey: "explain-reading:\(article.id)",
                action: { explainCurrentReading(article) }
            ))
        }

        // With nothing planned there is nothing to continue, so offer the way in:
        // the chat workflow that settles the goal and lays out the Schedule. It
        // sorts last, becoming the primary row only when it is the sole one.
        // Waits for the first library load: before it, "nothing planned" is
        // just "not read yet", and this row would flash at a learner whose
        // schedule is seconds away.
        if schedule.livePlacements.isEmpty, vm.hasCompletedInitialQueueLoad {
            suggestions.append(IdleSuggestion(
                id: "set-goal",
                systemImage: "target",
                title: "Set a learning goal",
                // No instance to scope to, so this one stays hidden until the
                // learner asks for it back with the restore link.
                dismissalKey: "set-goal",
                action: { await startGoalSetupFromIdle() }
            ))
        }

        return suggestions
    }

    /// What the idle state actually shows, after dismissals.
    private struct IdleWelcomeState {
        /// The first `idleSuggestionLimit` not hidden.
        let suggestions: [IdleSuggestion]
        /// Everything on offer has been hidden, so the restore link is the way
        /// back — the reason a dismissal is never a dead end.
        let showsRestore: Bool

        var hasContent: Bool { !suggestions.isEmpty || showsRestore }
    }

    /// Resolved in one pass: the plan lookup and the suggestion list are each
    /// walked once per render rather than once per question asked about them.
    private func idleWelcomeState(_ schedule: IdleScheduleSnapshot) -> IdleWelcomeState {
        let dismissals = IdleSuggestionDismissals.shared
        let all = allIdleSuggestions(schedule)
        let visible = all.filter { !dismissals.isDismissed($0.dismissalKey) }
        return IdleWelcomeState(
            suggestions: Array(visible.prefix(Self.idleSuggestionLimit)),
            showsRestore: !all.isEmpty && visible.isEmpty
        )
    }

    /// Hands the learner to the tutor's Learning goal workflow: it asks for the
    /// topic and deadline, then creates the Notebook/Goal, discovers sources, and
    /// paces them onto the Schedule through the same tools the Notebooks panel uses.
    @MainActor
    private func startGoalSetupFromIdle() async {
        guard !manager.isSearching, !manager.isGenerating else { return }
        clearComposer()
        pendingReaderSelection = nil
        await sendReviewChatMessage(Self.setGoalPrompt)
    }

    /// Sends what `/plan` sends: the chat that plans the day into the Mac's
    /// Calendar, where the Now chip shows it filling in.
    @MainActor
    private func startPlanDayFromIdle() async {
        guard !manager.isSearching, !manager.isGenerating else { return }
        clearComposer()
        pendingReaderSelection = nil
        await sendReviewChatMessage(
            ReviewSlashCommandParser.planDayRequest(nil),
            contextualContent: ReviewSlashCommandParser.planDayContextContent
        )
    }

    @MainActor
    private func startTodayReviewFromIdle(_ items: [SchedulePlanItem]) async {
        let todayArticles = articles(for: items)
        guard !todayArticles.isEmpty else { return }
        await startReview(with: todayArticles, topic: "Today's review")
    }

    @MainActor
    private func startMemoryCompanionFromIdle(_ plan: MemoryCompanionPlan) async {
        guard !plan.isEmpty, !manager.isSearching, !manager.isGenerating else { return }
        await vm.refreshMemoryCompanionPlan(surfaceErrors: true)
        guard let plan = vm.memoryCompanionPlan, !plan.isEmpty else {
            vm.showToast("Nothing is due for a memory check right now.")
            return
        }
        vm.startCompanionReview(
            goalID: plan.goalID,
            sourceIDs: plan.sourceIDs,
            topic: plan.topic,
            rationale: "Prioritize durable retrieval: revisit unresolved struggles first, then due memories, then newly consumed material that has not yet been recalled.",
            memoryPlan: plan
        )
    }

    /// The sources a chat started from a notebook's guide reads: its own and
    /// those of the context notebooks put in, as a review started from outside
    /// the panel reads them (`requestNotebookReview`), less the ones unticked.
    /// Nil, with a toast when every box is unticked, when there is nothing.
    @MainActor
    private func notebookArticlesForGuideChat(_ notebook: LearningGoalRecord, toStart what: String) -> [StudioArticle]? {
        let readable = vm.notebookChatPool(notebook)
            .compactMap { vm.articlesById[$0] }
            .filter { vm.isSourceIncludedInKnowledge($0) }
        let unticked = vm.notebookChatExclusions[notebook.id] ?? []
        let notebookArticles = readable.filter { !unticked.contains($0.id) }
        guard !notebookArticles.isEmpty else {
            if !readable.isEmpty {
                vm.showToast("Tick a source in \u{201C}\(notebook.title)\u{201D} to \(what).")
            }
            return nil
        }
        return notebookArticles
    }

    @MainActor
    func startNotebookReviewFromIdle(_ notebook: LearningGoalRecord) async {
        guard let notebookArticles = notebookArticlesForGuideChat(notebook, toStart: "review it") else { return }
        guard !manager.isSearching, !manager.isGenerating else { return }
        linkedResearchNotebookID = notebook.id
        readsNotebookTicksLive = false
        vm.setContextSources(notebookArticles.map(\.id))
        clearComposer()
        pendingReaderSelection = nil
        guard await syncSynthesisToolContext() else { return }
        await vm.ensureContextSourceContentLoaded()
        await manager.startSession(
            topic: notebook.title,
            articles: notebookArticles,
            goalID: notebook.id,
            notebookScopeID: notebook.id
        )
        await vm.loadReviewSessionLinks()
        await vm.loadLearningGoals()
    }

    /// The Feynman Technique from the notebook's guide: a chat on the
    /// notebook's ticked sources that opens by asking the learner what they
    /// know of it, from memory (`ReviewSessionManager.startTeachBack`).
    @MainActor
    func startNotebookTeachBackFromIdle(_ notebook: LearningGoalRecord) async {
        guard let notebookArticles = notebookArticlesForGuideChat(notebook, toStart: "start the \(TeachBack.title)") else { return }
        guard !manager.isSearching, !manager.isGenerating else { return }
        // Asked for from a chat in the notebook, it leaves that chat as it is.
        if manager.sessionActive || !manager.chatMessages.isEmpty {
            manager.endSession()
        }
        linkedResearchNotebookID = notebook.id
        readsNotebookTicksLive = false
        vm.setContextSources(notebookArticles.map(\.id))
        clearComposer()
        pendingReaderSelection = nil
        guard await syncSynthesisToolContext() else { return }
        await vm.ensureContextSourceContentLoaded()
        await manager.startTeachBack(notebookID: notebook.id, notebookTitle: notebook.title, articles: notebookArticles)
        await vm.loadReviewSessionLinks()
        await vm.loadLearningGoals()
    }

    @MainActor
    private func explainCurrentReading(_ article: StudioArticle) {
        adoptLiveNotebookSelection()
        vm.addSourceToContext(article.id)
        draft = "Explain the key ideas of \u{201C}\(article.title)\u{201D}."
        lastInsertedDefaultPrompt = draft
        requestComposerFocus()
    }
}
