// The chat title header, chat actions menu, memory review strip and walkthrough strip of the chat panel.
import SwiftUI
import Combine
import AppKit

extension InternalReviewPanelContent {
    /// Title of the currently selected chat, shown as a header above the transcript.
    /// Prefers the saved session record so renames made in the rail update live;
    /// falls back to the manager's topic for sessions not yet in the saved list.
    var selectedChatTitle: String? {
        guard let sessionID = manager.currentSessionID else { return nil }
        // While the title is just the opening message echoed back (pending the
        // AI-suggested title), don't duplicate the first bubble — show a
        // placeholder. A manual rename diverges from the echoed topic and wins.
        return ChatHeaderTitle.title(
            sessionTitle: vm.reviewSessionLinks.first { $0.id == sessionID }?.title,
            topic: manager.topic,
            isProvisional: manager.titleIsProvisional
        )
    }

    @ViewBuilder
    private var chatTitleHeader: some View {
        if let title = selectedChatTitle {
            let docked = usesDockedHeaderChrome
            let band = docked ? titlebarBandHeight : nil
            chatTitleLabel(title)
            // A title long enough to fill the column would otherwise run under
            // the header's ⋯, which no longer travels with the column's edge.
            // Truncate it a control-gap short of the button, and give up
            // nothing at all when the column already ends left of that.
                .padding(.trailing, chatHeaderTitleClearance)
            // Likewise on the left: the leftmost pane's title would otherwise
            // run under the window's ‹ › and sidebar toggle, which reach past
            // the icon strip into the pane.
                .padding(.leading, chatHeaderTitleLeadingClearance)
            // Match the transcript's readable column: the title begins
            // on the same leading outline instead of floating at panel center.
                .frame(maxWidth: chatColumnMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, chatHeaderGutter)
            // Keep the row as tall as the control the overlay adds, so the
            // button never spills past the header's own bounds.
                .frame(minHeight: chatHeaderControlSize)
            // The ⋯ belongs with the pane's other controls rather than on the
            // reading column's invisible trailing edge. That column is
            // centered and, in a split, capped well short of the pane, which
            // left a control stranded mid-header on a wide pane. Anchored here
            // it lands one control gap in from the pin instead. Quiet chrome
            // (docs/ui-design.md, 2026-10-06): the title, a review's way out
            // while it has the window, the ⋯ and the pane's ×; Copy
            // conversation and the notebook's Chats are the ⋯'s.
                .overlay(alignment: .trailing) {
                    HStack(spacing: StudioPaneClosePlacement.interControlSpacing) {
                        memoryReviewFocusChrome
                        newNotebookChatButton
                        chatActionsMenu
                    }
                    .padding(.trailing, chatHeaderControlTrailingInset)
                }
                .padding(.top, docked ? 0 : 10)
                .padding(.bottom, docked ? 0 : 9)
                .frame(height: band ?? (docked ? StudioPanelChrome.headerHeight : nil))
                // In the titlebar band the row stands on the band's chrome
                // (`studioBandOverlay`), which already keeps the messages from
                // showing through; a backdrop of its own painted the pane's
                // white across the band beside the Review's grey. Only the
                // in-flow row of a window with no band (full screen) is
                // backed here.
                .background(docked && band == nil ? Color(nsColor: .windowBackgroundColor) : Color.clear)
                .help(title)
                .overlay(alignment: .bottom) {
                    if !docked {
                        Rectangle()
                            .fill(Color.primary.opacity(0.07))
                            .frame(height: 1)
                    }
                }
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// The title, or the field renaming it. A click on the title renames the
    /// chat, as Codex's does (product owner, 2026-10-13: "at first it should be a
    /// copy of the codex ... functionality"); Return keeps the new name and
    /// Escape the old. A chat with no row yet, a day's review and a team's
    /// snapshot keep a plain title, selectable to paste elsewhere.
    @ViewBuilder
    private func chatTitleLabel(_ title: String) -> some View {
        if isRenamingChatTitle {
            TextField("Add a title…", text: $chatTitleDraft)
                .textFieldStyle(.plain)
                .font(.subheadline.weight(.medium))
                .focused($chatTitleFieldFocused)
                .onSubmit { commitChatTitleRename() }
                .onExitCommand { isRenamingChatTitle = false }
                .onChange(of: chatTitleFieldFocused) { _, focused in
                    if !focused { commitChatTitleRename() }
                }
                .onChange(of: manager.currentSessionID) { _, _ in isRenamingChatTitle = false }
                .accessibilityLabel("Chat title")
        } else if canRenameChat {
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.disabled)
                .contentShape(Rectangle())
                .onTapGesture { beginChatTitleRename() }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Renames the chat")
        } else {
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
            // A quiz or chat title is worth pasting elsewhere; the titlebar
            // band's WindowDragBlocker keeps a drag here a text selection.
                .textSelection(.enabled)
        }
    }

    /// The chat's saved row, which a rename, a pin and a hide act on; nil
    /// before the chat is saved.
    var openChatRecord: ReviewSessionRecord? {
        guard let sessionID = manager.currentSessionID else { return nil }
        return vm.reviewSessionLinks.first { $0.id == sessionID }
    }

    /// Whether the open chat is the learner's to rename here: saved, not a
    /// day's review (Memory names it), not a team's snapshot.
    var canRenameChat: Bool {
        guard let record = openChatRecord else { return false }
        return !MemoryReviewSession.isMemorySession(record.id) && !record.isTeamSnapshot
    }

    func beginChatTitleRename() {
        guard let record = openChatRecord, canRenameChat else { return }
        chatTitleDraft = record.title
        isRenamingChatTitle = true
        chatTitleFieldFocused = true
    }

    private func commitChatTitleRename() {
        guard isRenamingChatTitle else { return }
        isRenamingChatTitle = false
        let title = chatTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let record = openChatRecord, !title.isEmpty, title != record.title else { return }
        Task { await vm.renameReviewSession(record.id, title: title) }
    }

    /// Whether this panel is the review the window has given itself over to.
    private var showsMemoryReviewFocusChrome: Bool {
        guard let sessionID = manager.currentSessionID else { return false }
        return vm.memoryReviewFocusSessionID == sessionID
    }

    /// What a review in focus puts in the header: the way out
    /// (`MemoryReviewFocusChrome`, shared with the card review). While the
    /// goal is unmet the × ends today's session, and says so first.
    @ViewBuilder
    private var memoryReviewFocusChrome: some View {
        if showsMemoryReviewFocusChrome {
            MemoryReviewFocusChrome(
                onTitlebarBand: usesTitlebarBandHeader,
                controlSize: chatHeaderControlSize,
                leavingEnds: MemoryReviewCommitment.leavingEndsSession(goalTracker.state)
            ) {
                vm.leaveMemoryReviewFocus(sessionID: manager.currentSessionID)
            }
        }
    }

    /// The notebook whose chats the header's ⋯ lists: the window's, in its
    /// primary chat (a second chat beside it opens its own picks in place).
    private var headerNotebookID: String? {
        guard usesDockedHeaderChrome, acceptsGlobalNavigationRequests else { return nil }
        return windowState?.NotebookID
    }

    /// Width the header's trailing controls take, so the title truncates clear
    /// of them however many there are.
    private var chatHeaderControlsWidth: CGFloat {
        // The ⋯, once there is something under it, and the new-chat button
        // before it.
        var width: CGFloat = showsChatActionsMenu ? chatHeaderControlSize : 0
        if showsNewNotebookChatButton {
            if width > 0 { width += StudioPaneClosePlacement.interControlSpacing }
            width += chatHeaderControlSize
        }
        guard showsMemoryReviewFocusChrome else { return width }
        // The review's × in front of it.
        if width > 0 { width += StudioPaneClosePlacement.interControlSpacing }
        return width + chatHeaderControlSize
    }

    /// Whether the header carries New chat: in a notebook window, once this
    /// chat has something in it. A blank chat is already the new one, and the
    /// button would only reload it. Before 2026-10-24 the way to a second
    /// chat in a notebook was ⋯ ▸ Chats in This Notebook ▸ New Chat, or ⌘N,
    /// or a + that showed only under the pointer on the rail's row (product
    /// owner, 2026-10-24: "within the notebook view, how can I actually do a
    /// new chat? This has to be a lot easier").
    private var showsNewNotebookChatButton: Bool {
        headerNotebookID != nil && windowState != nil
            && (manager.currentSessionID != nil || manager.chatMessageCount > 0)
    }

    /// New chat, one press from the chat's header: the notebook's own chat
    /// with its ticked sources (`requestNewChat`), as ⌘N and the ⋯ menu do.
    @ViewBuilder
    private var newNotebookChatButton: some View {
        if showsNewNotebookChatButton, let windowState {
            if usesTitlebarBandHeader {
                TitlebarBandButton(
                    help: "New chat",
                    accessibilityLabel: "New chat",
                    accessibilityIdentifier: "mac.newNotebookChat",
                    controlSize: chatHeaderControlSize,
                    action: { vm.inWindow(windowState) { vm.requestNewChat() } }
                ) {
                    newNotebookChatLabel
                }
            } else {
                Button {
                    vm.inWindow(windowState) { vm.requestNewChat() }
                } label: {
                    newNotebookChatLabel
                        .frame(width: chatHeaderControlSize, height: chatHeaderControlSize)
                }
                .buttonStyle(.hoverWash(cornerRadius: chatHeaderControlSize / 2, inset: -5, opacity: 0.12))
                .help("New chat")
                .accessibilityLabel("New chat")
                .accessibilityIdentifier("mac.newNotebookChat")
            }
        }
    }

    private var newNotebookChatLabel: some View {
        Image(systemName: "square.and.pencil")
            .zoomedSystemFont(size: 11, weight: .semibold)
            .foregroundStyle(.secondary)
    }

    /// The chat this header's ⋯ acts on: a chat that has a row to be opened
    /// elsewhere or addressed. A new chat with nothing in it has none.
    private var chatActionsSessionID: String? { manager.currentSessionID }

    /// The ⋯ is drawn once it holds something: this chat's actions, or, in a
    /// notebook window, the notebook's chats.
    private var showsChatActionsMenu: Bool {
        chatActionsSessionID != nil || headerNotebookID != nil
    }

    /// The header's ⋯: the notebook's chats, where this chat can go — the
    /// pane beside it, another window — its address and its transcript. The
    /// sidebar's row has carried these all along, but the chat in front of
    /// the learner had no menu at all (product owner, 2026-09-21: "I also don't have
    /// a, you know, three dots where I can be like, move to the other
    /// window"). Since 2026-10-06 (Quiet chrome, docs/ui-design.md) it also
    /// holds what stood beside it on the line: **Chats in This Notebook** ▸
    /// (`NotebookChatsMenuItems`, also the notebook rail's Chats menu) and
    /// **Copy Conversation**.
    ///
    /// Docked, this header hangs in the titlebar band, where a SwiftUI `Menu`
    /// label never lights up and its press can be taken by the window drag —
    /// the same reason the Reader's overflow is a `TitlebarBandButton` opening
    /// an `NSHostingMenu`. The items are authored once in SwiftUI below and
    /// built fresh per press; the band path re-injects the view model and the
    /// window, which a hosting menu does not inherit.
    @ViewBuilder
    private var chatActionsMenu: some View {
        if showsChatActionsMenu {
            if usesTitlebarBandHeader, #available(macOS 14.4, *) {
                TitlebarBandButton(
                    help: "More chat actions",
                    accessibilityLabel: "More chat actions",
                    accessibilityIdentifier: "mac.chatActions",
                    controlSize: chatHeaderControlSize,
                    action: {},
                    menu: {
                        NSHostingMenu(rootView: chatActionsMenuItems(sessionID: chatActionsSessionID)
                            .environment(vm)
                            .environment(windowState))
                    }
                ) {
                    chatActionsMenuLabel
                }
            } else {
                Menu {
                    chatActionsMenuItems(sessionID: chatActionsSessionID)
                } label: {
                    chatActionsMenuLabel
                        .frame(width: chatHeaderControlSize, height: chatHeaderControlSize)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .hoverHighlight(cornerRadius: chatHeaderControlSize / 2, inset: -5, opacity: 0.12)
                .help("More chat actions")
                .accessibilityLabel("More chat actions")
                .accessibilityIdentifier("mac.chatActions")
            }
        }
    }

    private var chatActionsMenuLabel: some View {
        Image(systemName: "ellipsis")
            .zoomedSystemFont(size: 11, weight: .semibold)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func chatActionsMenuItems(sessionID: String?) -> some View {
        // A notebook window's chats, which the rail's icon strip lists too
        // (and no longer under the notebook's folder).
        if let notebookID = headerNotebookID, windowState != nil {
            Menu("Chats in This Notebook", systemImage: "bubble.left.and.bubble.right") {
                NotebookChatsMenuItems(notebookID: notebookID, currentSessionID: manager.currentSessionID)
            }
            if sessionID != nil { Divider() }
        }
        if let sessionID {
            chatActionsSessionItems(sessionID: sessionID)
        }
    }

    @ViewBuilder
    private func chatActionsSessionItems(sessionID: String) -> some View {
        // Codex's header menu leads with the chat's own marks: Pin, Rename,
        // and Hide in place of its Archive, as the sidebar row's menu does.
        if let record = openChatRecord, record.id == sessionID, !MemoryReviewSession.isMemorySession(sessionID) {
            let isPinned = vm.isChatPinned(sessionID)
            Button {
                vm.setChatPinned(sessionID, pinned: !isPinned)
            } label: {
                Label(isPinned ? "Unpin Chat" : "Pin Chat", systemImage: isPinned ? "pin.slash" : "pin")
            }
            if canRenameChat {
                Button {
                    beginChatTitleRename()
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
            }
            Button {
                Task { await vm.setReviewSessionHidden(sessionID, hidden: !record.isHidden) }
            } label: {
                Label(record.isHidden ? "Show" : "Hide", systemImage: record.isHidden ? "eye" : "eye.slash")
            }
            Divider()
        }
        OpenStudioDestinationInOtherWindowMenu(
            destination: .chat(sessionID),
            currentWindowState: windowState,
            openNewWindow: { openWindow(id: "studio") }
        )
        Divider()
        // The chat's address, `foreverlm://chat/<id>`: the same item the
        // sidebar row carries, so a chat being read here can be handed to a
        // person or to an assistant on the plugin without going looking for
        // its row.
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
        // The whole transcript, named for what it does (product owner, 2026-09-22,
        // asking for a copy-the-whole-chat button that was already there,
        // wearing each answer's own copy glyph on the header). The header's
        // button went on 2026-10-06 (Quiet chrome): this is the one place.
        Button {
            copyConversation()
        } label: {
            Label("Copy Conversation", systemImage: "doc.on.doc")
        }
        .disabled(manager.chatMessages.isEmpty)
        // Turning an exploring chat into a notebook (product owner, 2026-10-03).
        if !MemoryReviewSession.isMemorySession(sessionID), teamSnapshotRecord == nil,
           !vm.isActiveLibraryReadOnly, manager.chatMessageCount > 0 {
            Divider()
            Button {
                requestNotebookFromChat(sessionID)
            } label: {
                Label("New Notebook from This Chat", systemImage: "rectangle.stack.badge.plus")
            }
        }
        // A memory review is dealt as cards; the conversation under them is
        // one press away, and back.
        if MemoryReviewSession.isMemorySession(sessionID) {
            Divider()
            let showsCards = memoryReviewLayout == .cards
            Button {
                memoryReviewCardIndex = nil
                memoryReviewLayoutRaw = (showsCards ? MemoryReviewLayout.conversation : .cards).rawValue
            } label: {
                Label(
                    showsCards ? "Show as Conversation" : "Show as Cards",
                    systemImage: showsCards ? "text.bubble" : "rectangle.stack"
                )
            }
        }
        // The page passages this chat was opened on (`docOriginMenuTitle`),
        // listed here rather than over the composer.
        if !sessionDocLinks.isEmpty {
            Divider()
            ForEach(sessionDocLinks) { entry in
                Button {
                    vm.revealArtifact(entry.link.artifactID)
                } label: {
                    Label(docOriginMenuTitle(for: entry), systemImage: "arrow.up.left.square")
                }
            }
        }
        // The context ring's breakdown of the context and this chat's cost.
        // The composer draws the ring only once the context is filling up
        // (2026-10-06); this opens the breakdown before that.
        if manager.contextBreakdown != nil {
            Divider()
            Button {
                isContextBreakdownRequested = true
            } label: {
                Label("Context and Cost…", systemImage: "gauge.with.dots.needle.33percent")
            }
        }
    }

    private var memoryReviewLayout: MemoryReviewLayout {
        MemoryReviewLayout(rawValue: memoryReviewLayoutRaw) ?? .cards
    }

    /// The text column of a memory review card, head and exchange alike.
    var memoryReviewCardTextWidth: CGFloat {
        MemoryReviewCardSurface.textColumnWidth(
            columnMaxWidth: chatColumnMaxWidth,
            gutter: chatHeaderGutter,
            zoom: uiZoomScale
        )
    }

    /// Whether this pane draws its memory review as a deck of cards. A walk
    /// playing in the same chat keeps its own deck.
    var showsMemoryReviewCards: Bool {
        isMemoryReviewChat && memoryReviewLayout == .cards && manager.walkthroughPlayback == nil
    }

    /// What the deck deals a card each: today's topics (docs/memory-design.md,
    /// "Review by topic"), or, in a review planned source by source, today's
    /// sources and chats in plan order. Both are drawn as the same card.
    var memoryReviewCardSubjects: [MemoryReviewCardSubject] {
        if manager.isTopicMemoryReview {
            return manager.memoryReviewTopics.map(MemoryReviewCardSubject.init(topic:))
        }
        guard manager.isMemoryReviewSession else { return [] }
        return memoryReviewStripEntries.map { entry in
            MemoryReviewCardSubject(
                sourceID: entry.id,
                title: entry.title,
                ideaIDs: manager.memoryReviewIdeaIDs(forSource: entry.id)
            )
        }
    }

    /// A card carries its own answer field, so the pane's composer steps
    /// aside while the deck is up. It comes back for a side question, which
    /// is typed with the composer's token, and in the conversation layout.
    var hidesComposerForMemoryCard: Bool {
        showsMemoryReviewCards && !isSideQuestionMode
    }

    /// Where the header's ⋯ stops, measured in from the panel's trailing
    /// edge.
    private var chatHeaderControlTrailingInset: CGFloat {
        StudioChatHeaderClearance.controlTrailingInset(
            gutter: chatHeaderGutter,
            chromeClearance: headerTrailingChromeClearance
        )
    }

    /// Trailing padding the title gives up so it truncates before reaching the
    /// header's ⋯. Zero whenever the reading column ends left of it anyway,
    /// which is the common case on a pane wider than the column.
    private var chatHeaderTitleClearance: CGFloat {
        StudioChatHeaderClearance.extraTrailingPadding(
            panelWidth: chatPanelWidth,
            gutter: chatHeaderGutter,
            columnMaxWidth: chatColumnMaxWidth,
            chromeClearance: StudioChatHeaderClearance.titleClearance(
                gutter: chatHeaderGutter,
                chromeClearance: headerTrailingChromeClearance,
                controlSize: chatHeaderControlsWidth
            )
        )
    }

    /// Leading padding the title gives up to start clear of the window's
    /// ‹ › and sidebar toggle. Zero whenever the reading column already
    /// begins right of them, which is the case on a wide pane.
    private var chatHeaderTitleLeadingClearance: CGFloat {
        StudioChatHeaderClearance.extraLeadingPadding(
            panelWidth: chatPanelWidth,
            gutter: chatHeaderGutter,
            columnMaxWidth: chatColumnMaxWidth,
            chromeClearance: headerLeadingChromeClearance
        )
    }

    @MainActor
    func copyConversation() {
        let transcript = ReviewSessionManager.copiedConversationText(from: manager.chatMessages)
        guard !transcript.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcript, forType: .string)
        vm.showToast("Conversation copied")
    }

    /// Whether the transcript takes the height it is given rather than its own:
    /// a fixed host does, and so does the page's side chat card, whose
    /// transcript region has a height of its own (`PageSideChatLayout`).
    private var fillsTranscriptHost: Bool { fillsAvailableSpace || pageSideChat != nil }

    var compactTranscriptPanel: some View {
        VStack(spacing: 0) {
            // The side chat's card draws its own header above this.
            if !usesTitlebarBandHeader, pageSideChat == nil {
                chatTitleHeader
            }
            memoryReviewSourceStrip
            walkthroughPlaybackStrip
            walkthroughCardDeck
            // Kept, not removed, while the card owns the pane, so its scroll
            // position and its handlers survive the first question. A memory
            // review drawn as cards puts the transcript on a card of its own.
            VStack(spacing: 0) {
                if showsMemoryReviewCards {
                    MemoryReviewCardHeader(
                        manager: manager,
                        selectedIndex: memoryReviewCardIndex,
                        textColumnWidth: memoryReviewCardTextWidth,
                        subjects: memoryReviewCardSubjects,
                        sourceTitle: { id in
                            vm.articlesById[id]?.title ?? manager.memoryReviewMaterialTitles[id]
                        }
                    )
                }
                transcriptView
                    // A card's exchange is set larger than the chat
                    // (`MemoryReviewCardSurface.textScale`); its head and
                    // foot keep the chat's size.
                    .environment(
                        \.uiZoomScale,
                        showsMemoryReviewCards ? uiZoomScale * MemoryReviewCardSurface.textScale : uiZoomScale
                    )
                if showsMemoryReviewCards {
                    // The session bar draws the day as segments; the foot
                    // keeps Back and Next.
                    MemoryReviewCardFooter(
                        manager: manager,
                        selectedIndex: $memoryReviewCardIndex,
                        showsSegments: false
                    )
                }
            }
            .modifier(MemoryReviewCardSurface(
                isOn: showsMemoryReviewCards,
                columnMaxWidth: chatColumnMaxWidth,
                gutter: chatHeaderGutter
            ))
            .frame(height: walkthroughFillsPane ? 0 : nil)
            .opacity(walkthroughFillsPane ? 0 : 1)
            .allowsHitTesting(!walkthroughFillsPane)
            .accessibilityHidden(walkthroughFillsPane)
        }
        .animation(.easeInOut(duration: 0.25), value: walkthroughFillsPane)
        // In a fixed host the bottom-aligned layout puts any leftover height
        // *above* the transcript, so a fixed height estimated from the panel
        // size leaves a gap over the chat title. Fill the height instead so
        // the title pins to the top and the composer stays at the bottom.
        .frame(height: fillsTranscriptHost ? nil : transcriptHeight)
        .frame(maxHeight: fillsTranscriptHost ? .infinity : nil)
        .modifier(TranscriptSurface(flat: fillsTranscriptHost))
        // Measured outside the frame, so the card's own height never feeds
        // back into the share it may take.
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
            transcriptPanelHeight = height
        }
        .onChange(of: manager.walkthroughPlayback?.sourceID, initial: true) { _, _ in
            registerWalkthroughDeck()
        }
        // On the band's chrome, so the transcript and its surface never show
        // there.
        .studioBandOverlay(active: usesDockedHeaderChrome) {
            chatTitleHeader
                .background(WindowDragBlocker())
        }
    }


    /// The day's review, as material rather than as a transcript: the sources
    /// today covers, each checked off once its contour has been graded.
    ///
    /// Only a graded contour checks a source off. Being asked about it, or
    /// opening it, is activity — the same line the Schedule draws between what
    /// happened and what was finished.
    @ViewBuilder
    private var memoryReviewSourceStrip: some View {
        if manager.isTopicMemoryReview || (showsMemoryReviewCards && manager.isMemoryReviewSession) {
            // The deck has a session bar where the strip stood: a stepper of
            // topics, or of sources in a review planned source by source, and
            // the model picker out of the composer the card no longer shows
            // (docs/memory-design.md, "Review by topic"). A source-by-source
            // review in the conversation layout keeps the chip strip.
            MemoryReviewSessionBar(
                topics: memoryReviewCardSubjects,
                statusBySource: manager.memoryReviewStatusBySource,
                currentTopicID: manager.memoryReviewCurrentSourceID,
                isBusy: isTurnInFlight,
                columnMaxWidth: chatColumnMaxWidth,
                gutter: chatHeaderGutter,
                separated: !showsMemoryReviewCards,
                select: { subject in selectMemoryReviewSubject(subject) }
            ) {
                if !manager.isTopicMemoryReview {
                    memoryReviewSourcesMenu
                }
                if hidesComposerForMemoryCard, !vm.isScreenRecordModeActive {
                    InlineModelPicker(task: .chat)
                        .id("chat-model")
                }
            }
        } else {
            memoryReviewSourceChipStrip
        }
    }

    /// What the chip strip offered on each source, in a review planned source
    /// by source whose deck has the session bar instead: open it, take it
    /// now, or take it out of the day.
    private var memoryReviewSourcesMenu: some View {
        let entries = memoryReviewStripEntries
        return Menu {
            ForEach(entries) { entry in
                let done = manager.memoryReviewStatusBySource[entry.id] != nil
                Menu(entry.title) {
                    if entry.article != nil {
                        Button("Open in Reader") { Task { await vm.openLinkedSourceInReader(entry.id) } }
                    }
                    if !done, entry.id != manager.memoryReviewCurrentSourceID {
                        Button("Take It Now") { Task { await steerMemoryReview(to: entry) } }
                            .disabled(isTurnInFlight)
                    }
                    Button("Not Something I Read") { Task { await removeMemoryReviewSource(entry) } }
                        .disabled(isTurnInFlight)
                }
            }
        } label: {
            Text(entries.count == 1 ? "1 source" : "\(entries.count) sources")
                .zoomedSystemFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help("Today's sources")
        .accessibilityIdentifier("memory.bar.sources")
    }

    @ViewBuilder
    private var memoryReviewSourceChipStrip: some View {
        let entries = manager.isMemoryReviewSession ? memoryReviewStripEntries : []
        if !entries.isEmpty {
            MemoryReviewSourceStrip(
                sources: entries,
                statusBySource: manager.memoryReviewStatusBySource,
                currentSourceID: manager.memoryReviewCurrentSourceID,
                isBusy: manager.isGenerating || manager.isSearching || manager.isPreparingGeneration,
                bookCoverPath: { memoryReviewBookCoverPath(for: $0) },
                columnMaxWidth: chatColumnMaxWidth,
                gutter: chatHeaderGutter,
                separated: !showsMemoryReviewCards,
                steer: { source in
                    Task { await steerMemoryReview(to: source) }
                },
                open: { sourceID in
                    Task { await vm.openLinkedSourceInReader(sourceID) }
                },
                remove: { source in
                    Task { await removeMemoryReviewSource(source) }
                }
            )
        }
    }

    /// The strip's chips: the day's material in the order the plan takes it,
    /// chats included, then anything attached beside it. A chat is review
    /// material under its own session id without being a source row, so it has
    /// no article and is named from the briefing's header; leaving chats out
    /// hid the source a review opened on, and no chip was current
    /// (2026-09-22, twelve of that day's nineteen sources).
    private var memoryReviewStripEntries: [MemoryReviewStripEntry] {
        let attached = reviewSources
        let attachedByID = Dictionary(attached.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var entries: [MemoryReviewStripEntry] = []
        var seen = Set<String>()
        for id in manager.memoryReviewMaterialInPlanOrder where seen.insert(id).inserted {
            if let article = attachedByID[id] ?? vm.articlesById[id] {
                guard vm.isSourceIncludedInKnowledge(article) else { continue }
                // Screen record mode (admin only): only the sources the take
                // may show. A morning's review is prepared from the whole
                // library, and its strip named the learner's own papers.
                guard vm.isVisibleInRecordingMode(article) else { continue }
                entries.append(MemoryReviewStripEntry(id: id, title: article.title, article: article))
            } else if let title = manager.memoryReviewMaterialTitles[id] {
                // A chat chip: in screen record mode only a chat the take shows.
                if vm.isScreenRecordModeActive {
                    guard let session = vm.reviewSessionLinks.first(where: { $0.id == id }),
                          vm.isVisibleInRecordingMode(session) else { continue }
                }
                entries.append(MemoryReviewStripEntry(id: id, title: title, article: nil))
            }
        }
        for article in attached where seen.insert(article.id).inserted {
            entries.append(MemoryReviewStripEntry(id: article.id, title: article.title, article: article))
        }
        return entries
    }

    /// Where the learner is in the walk this chat plays — step n of m, Back,
    /// Next, a jump to any step — as a strip under the title while a record is
    /// attached: a header widget, not a panel (walkthrough-design.md).
    @ViewBuilder
    private var walkthroughPlaybackStrip: some View {
        if let playback = manager.walkthroughPlayback {
            WalkthroughPlaybackStrip(
                title: playback.walkthrough.title,
                steps: playback.steps,
                currentIndex: playback.currentIndex,
                cardOrdinal: playback.currentStep.map {
                    playback.walkthrough.cardOrdinal(stepIndex: playback.currentIndex, card: playback.revealedBeatCount(of: $0))
                } ?? 0,
                cardCount: playback.walkthrough.cardCount,
                playedStepIDs: playback.playedStepIDs,
                canGoBack: playback.canGoBack,
                canGoNext: playback.canGoNext,
                isBusy: isTurnInFlight,
                // The stage's own Next is the way on; a second pair up here
                // only competes with it.
                showsStepControls: !walkthroughFillsPane,
                columnMaxWidth: chatColumnMaxWidth,
                gutter: chatHeaderGutter,
                back: { Task { await manager.walkthroughBack() } },
                next: { Task { await manager.walkthroughNext() } },
                jump: { index in Task { await manager.showWalkthroughStep(at: index) } },
                leave: {
                    manager.leaveWalkthroughPlayback()
                    // Like the pane's ×, it lands on New chat's greeting
                    // (`StudioViewModel.leaveWalkthroughForNewChat`). A
                    // comparison pane cannot take the window's New chat, so
                    // it stays on the walk's chat.
                    if acceptsGlobalRequests { vm.requestNewChat() }
                }
            )
        }
    }

    /// Walk Through was pressed on a source. The walk is not a chat
    /// (walkthrough-design.md, "the walk leaves the chat"): when its
    /// questions already have a chat, that chat opens under the cards;
    /// otherwise the walk plays in this pane when it has nothing in it or is
    /// already this walk's, and in a fresh pane when it holds another
    /// conversation, which is left exactly as it is (product owner, 2026-09-22:
    /// "it's like over the chat where I'm in, it's so weird").
    @MainActor
    func handleWalkthroughPlayRequest() async {
        guard let request = vm.readerWalkthroughPlayRequest else { return }
        defer { vm.readerWalkthroughPlayRequest = nil }
        // An animation's chat is about the sources the animation is about.
        let aboutSourceIDs = request.isAnimation
            ? (vm.artifacts.first(where: { $0.id == request.sourceID })?.sourceIDs ?? [])
            : [request.sourceID]
        let walkChatID: String?
        if manager.isPlayingWalkthrough(of: request.sourceID) {
            walkChatID = nil
        } else {
            let progress = await vm.loggedRead("the walkthrough's progress") {
                try await vm.storage.loadWalkthroughProgress(request.sourceID)
            }
            walkChatID = (progress ?? nil)?.chatSessionID
        }
        if let walkChatID, walkChatID != manager.currentSessionID {
            if vm.reviewSessionLinks.isEmpty { await vm.loadReviewSessionLinks() }
            if vm.reviewSessionLinks.contains(where: { $0.id == walkChatID }) {
                readsNotebookTicksLive = false
                vm.setContextSources(aboutSourceIDs)
                sessionStore.requestOpen(sessionID: walkChatID, playingWalkthroughOf: request.sourceID)
                return
            }
        }
        // A walk opens in a chat of its own unless this one is empty or
        // already playing it (`walkthroughOpensNewChat`). A chat still
        // waiting to open here — the window's last chat after a relaunch — is
        // a conversation too, and the walk is the later intent, so the open
        // gives way to the new chat.
        if sessionStore.walkthroughOpensNewChat(of: request.sourceID) || requestedResumeSessionID != nil {
            if acceptsGlobalNavigationRequests, vm.reviewChatResumeSessionID != nil {
                vm.reviewChatResumeSessionID = nil
            }
            readsNotebookTicksLive = false
            vm.setContextSources(aboutSourceIDs)
            sessionStore.requestNewChat(playingWalkthroughOf: request.sourceID)
            return
        }
        await startWalkthroughPlayback(sourceID: request.sourceID)
    }

    /// Loads the subject's record into this chat and plays its first step —
    /// or, when this chat has played some of it already, points the Reader
    /// (or the animation's pane) at the step the learner is on. The subject
    /// is a source when the library has one by that id, else the animation.
    @MainActor
    func startWalkthroughPlayback(sourceID: String) async {
        if vm.articlesById[sourceID] == nil {
            var artifact = vm.artifacts.first(where: { $0.id == sourceID })
            if artifact == nil {
                artifact = await vm.loggedRead("the animation") { try await vm.storage.loadArtifact(sourceID) } ?? nil
            }
            guard let artifact, artifact.isAnimation else { return }
            guard await manager.loadWalkthrough(forAnimation: artifact) else {
                if manager.chatTakesWalkthrough(of: sourceID) {
                    vm.showToast("\(artifact.title) has no walkthrough yet")
                }
                return
            }
            if let playback = manager.walkthroughPlayback, !playback.playedStepIDs.isEmpty {
                await manager.showWalkthroughStep(at: playback.currentIndex)
            } else {
                await manager.playWalkthroughStep(at: 0)
            }
            await vm.loadReviewSessionLinks()
            requestComposerFocus()
            return
        }
        guard let article = vm.articlesById[sourceID] else { return }
        // Not loaded either because the source has no walk, or because a chat
        // landed here while it was being read and keeps the pane
        // (`chatTakesWalkthrough`); only the first is news.
        guard await manager.loadWalkthrough(for: article) else {
            if manager.chatTakesWalkthrough(of: sourceID) {
                vm.showToast("\(vm.displayTitle(for: article)) has no walkthrough yet")
            }
            return
        }
        if let playback = manager.walkthroughPlayback, !playback.playedStepIDs.isEmpty {
            await manager.showWalkthroughStep(at: playback.currentIndex)
        } else {
            await manager.playWalkthroughStep(at: 0)
        }
        await vm.loadReviewSessionLinks()
        requestComposerFocus()
    }

    /// The × on a chip takes the source out of today's review: material the
    /// picker counted as read that the learner never actually read, or has no
    /// time for today. The manager records the removal on the session and its
    /// briefing. When the tutor was on that very source, the note goes now as
    /// the learner's own "skip", so the review moves on rather than waiting on
    /// a question about material that is gone; otherwise it rides with their
    /// next message.
    @MainActor
    func removeMemoryReviewSource(_ source: MemoryReviewStripEntry) async {
        let note = await manager.removeMemoryReviewSource(source.id, availableArticles: vm.articles)
        await vm.loadReviewSessionLinks()
        if let note {
            await sendReviewChatMessage(MemoryReviewTopicCardFold.skipMessage(title: source.title), contextualContent: note)
        }
    }

    /// A click on the session bar's stepper: the current topic's question is
    /// already on the card, so nothing; a finished topic opens its card as a
    /// record; a waiting one is taken now, in the learner's own words, with
    /// the topic's id riding beside them so the tutor turns to the right one
    /// and writes its heading.
    @MainActor
    private func selectMemoryReviewSubject(_ topic: MemoryReviewCardSubject) {
        if topic.id == manager.memoryReviewCurrentSourceID { return }
        if manager.memoryReviewStatusBySource[topic.id] != nil {
            guard showsMemoryReviewCards else { return }
            let cards = MemoryReviewCardFold.cards(manager.chatMessages, byTopic: true)
            guard let index = cards.lastIndex(where: { $0.sourceID == topic.id }) else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                memoryReviewCardIndex = index == cards.count - 1 ? nil : index
            }
            return
        }
        if let realTopic = manager.memoryReviewTopics.first(where: { $0.id == topic.id }) {
            Task { await steerMemoryReview(toTopic: realTopic) }
        } else if let entry = memoryReviewStripEntries.first(where: { $0.id == topic.id }) {
            Task { await steerMemoryReview(to: entry) }
        }
    }

    @MainActor
    func steerMemoryReview(toTopic topic: MemoryReviewTopic) async {
        let request = MemoryReviewTopicCardFold.takeNowMessage(title: topic.title)
        let turn = "[ForeverLM] The learner chose \(topic.title) in the session bar; its topic id is \(topic.id). "
            + "Turn to it now: write its \(MemoryReviewSourceTurn.line(sourceID: topic.id)) line, then ask its opening question."
        await sendReviewChatMessage(request, contextualContent: turn)
    }

    /// A click on a chip in the strip is a steer to that source: on one already
    /// checked off it asks to go deeper, on one still waiting it asks to take
    /// it now. Sent as the learner's own words, the way the Next and Go deeper
    /// chips are, with the source's id riding beside the message so the tutor
    /// turns to the right one and writes its heading.
    @MainActor
    func steerMemoryReview(to source: MemoryReviewStripEntry) async {
        let reviewed = manager.memoryReviewStatusBySource[source.id] != nil
        // The source whose contour is open and unanswered is the question
        // already on the card. Asking to "do it now" only re-asks it, and on
        // 2026-09-26 the second wording listed the very ideas the first had
        // left to memory.
        if !reviewed, source.id == manager.memoryReviewCurrentSourceID { return }
        var note: String?
        if manager.offersMemoryReviewSteer, source.id == manager.memoryReviewCurrentSourceID {
            // The source under discussion, once graded: that is the Go deeper
            // chip by another route, so it is recorded as that steer, and a
            // contour that came back whole gets its understanding probe.
            note = await manager.steerMemoryReview(.deeper)
        }
        let request = reviewed
            ? MemoryReviewTopicCardFold.deeperOnMessage(title: source.title)
            : MemoryReviewTopicCardFold.takeNowMessage(title: source.title)
        let probe = note == nil
            ? "ask one probe there, chosen from the ideas its contour grade marked missing or partial."
            : "ask the understanding probe described above."
        let turn = "[ForeverLM] The learner clicked \(source.title) in the review strip; its source id is \(source.id). "
            + "Turn to it now: write its \(MemoryReviewSourceTurn.line(sourceID: source.id)) line, then "
            + (reviewed ? probe : "ask its contour.")
        await sendReviewChatMessage(request, contextualContent: [note, turn].compactMap { $0 }.joined(separator: "\n\n"))
    }

    /// A book chapter's row should draw the book's cover, not the first picture
    /// inside that chapter. Same lookup the shelf and the notepad chips use.
    func memoryReviewBookCoverPath(for article: StudioArticle) -> String? {
        guard let group = article.parentGroup else { return nil }
        return vm.bookCoverPaths[group]
    }

    private var usesTitlebarBandHeader: Bool {
        usesDockedHeaderChrome && titlebarBandHeight != nil
    }

    /// Empty space kept under the last row of the transcript.
    ///
    /// While a reply streams, reserve the lower half of the viewport so the
    /// just-sent message can sit at the center and the answer streams in
    /// beneath it instead of starting at the bottom edge. Once the turn
    /// settles, keep a smaller band so a finished answer still reads with room
    /// under it rather than butting up against the composer.
    var transcriptBottomReserve: CGFloat {
        // A card holds its exchange in its middle; there is nothing to
        // centre a sent answer against.
        guard transcriptViewportHeight > 0, !showsMemoryReviewCards else { return 0 }
        if manager.isGenerating || manager.isSearching {
            return transcriptViewportHeight / 2
        }
        // Proportional on a short panel, so the band never eats a bottom-sheet
        // popover's few visible rows.
        return min(96, transcriptViewportHeight * 0.25)
    }
}
