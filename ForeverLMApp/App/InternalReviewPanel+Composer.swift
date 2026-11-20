// The composer, its context chips and popovers for the chat panel.
import SwiftUI
import Combine
import UniformTypeIdentifiers
import AppKit

extension InternalReviewPanelContent {
    /// Everything between the send and the finished reply. Preparation counts:
    /// source hydration and session setup happen before the request goes out and
    /// are indistinguishable, from the learner's chair, from waiting on tokens.
    var isTurnInFlight: Bool {
        // Hydrating a saved chat borrows `isSearching` to hold the composer, but
        // it is not a turn: the transcript arriving is its own feedback, and a
        // "Searching your library" line flashing under a conversation the learner
        // just opened describes work nobody asked for.
        guard !manager.isResumingSession else { return false }
        return manager.isPreparingGeneration || manager.isSearching || manager.isGenerating
    }

    /// Whether the transcript ends in the working line: a turn in flight, or a
    /// walk getting a step ready. The walk is not a turn — nothing is queued
    /// behind it and the composer stays open — but from the learner's chair it
    /// is the same wait for something to appear, so it runs the same clock.
    var showsWorkingLine: Bool {
        isTurnInFlight || manager.walkthroughPreparationDetail != nil
    }

    /// One rounded composer, as in ChatGPT's (product owner, 2026-10-06: "make the
    /// app more slick; kind of like the chatgpt app … fewer buttons and bells
    /// and whistles"): above the field only what the learner put there (a
    /// passage, pictures); in it the tokens that change how the next message
    /// is read; under it "+" on the leading edge, and the model and its
    /// effort, the mic and send or Stop on the trailing one. It is
    /// Codex's (product owner, 2026-10-11: "make the chat experience more look
    /// chatgpt codex"): a solid card, with the notebook and what is in
    /// context, where the window does not already say it, on a grey tray
    /// behind its top edge, as Codex shows the project there
    /// (`ChatComposerStack`).
    var inputBar: some View {
        VStack(spacing: 6) {
            // Messages sent while a reply is being written wait above the
            // composer, as Codex's queue does, until the turn ends and they go.
            if !manager.queuedFollowUps.isEmpty {
                ReviewChatQueuedMessages(
                    items: manager.queuedFollowUps,
                    edit: { item in returnQueuedFollowUpToComposer(item) },
                    delete: { item in deleteQueuedFollowUp(item) },
                    sendNow: { item in Task { await manager.sendQueuedFollowUpNow(item.id) } }
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            composerStack
        }
        .animation(.easeOut(duration: 0.15), value: manager.queuedFollowUps.map(\.id))
    }

    private var composerStack: some View {
        ChatComposerStack(showsTray: showsComposerContextRow) {
            composerContextRow
        } card: {
            composerCard
        }
        .animation(.easeOut(duration: 0.18), value: showsComposerContextRow)
        // The composer's own hit area, set before the popup is overlaid: a
        // contentShape applied after the overlay clipped every click to the
        // composer's rectangle, so the popup rows, which float above it, took
        // no mouse clicks and only the arrow keys could pick one.
        .contentShape(Rectangle())
        .overlay(alignment: .topLeading) {
            ReviewSlashSuggestionsOverlay(
                composer: composer,
                slashCommands: slashCommands,
                mentions: composerMentions,
                resolveLiveArguments: { command, query in
                    await resolveSlashLiveArguments(for: command, query: query)
                },
                resolveMentions: { query in
                    await resolveMentionItems(matching: query)
                },
                onSelect: { acceptSlashSuggestion($0) }
            )
        }
        .onDrop(
            of: reviewChatDropTypes,
            isTargeted: dropTargetBinding,
            perform: handleDrop
        )
        .animation(.easeOut(duration: 0.18), value: reviewSources.map(\.id))
        .animation(.easeOut(duration: 0.18), value: linkedResearchNotebookID)
        .animation(.easeOut(duration: 0.18), value: dictation.isRecording)
        .animation(.easeOut(duration: 0.18), value: dictation.isTranscribing)
    }

    /// The card itself: the passage, the pictures, the field, and the row of
    /// controls under it.
    private var composerCard: some View {
        VStack(spacing: StudioDesign.Spacing.small) {
            if editingMessage != nil {
                ReviewChatEditingLine(cancel: cancelEditing)
            }
            readerSelectionChip
            pendingImagesRow

            // The box reads the draft itself; this pane only hands it the
            // callbacks, so a keystroke re-renders the box and not the pane.
            ReviewChatComposerBox(
                composer: composer,
                placeholder: chatInputPlaceholder,
                focusRequestID: pageSideChat != nil
                    ? sessionStore.composerFocusRequestID
                    : vm.reviewChatFocusRequestID(in: windowState),
                slashCommands: slashCommands,
                mentions: composerMentions,
                onSubmit: {
                    Task {
                        await submitComposer()
                    }
                },
                onAcceptSuggestion: { acceptSlashSuggestion($0) },
                onDismissSuggestions: { dismissSlashSuggestions() },
                onTextChange: { text in
                    fileDraft()
                    // The first words of a question pause a video playing
                    // beside the chat and start taking its frame.
                    manager.composerTextChanged(text)
                },
                onPasteImages: { pasted in
                    Task { await attachPastedImages(pasted) }
                },
                onPasteCardID: { id in
                    Task { await referencePastedCard(id) }
                },
                onRecallPrevious: { recallPreviousPrompt() },
                onSubmitSideQuestion: {
                    Task { await submitComposer(asSideQuestion: true) }
                },
                removeSideQuestionToken: isSideQuestionMode
                    ? { disarmSideQuestion() }
                    : nil,
                sideQuestionAbout: sideQuestionTokenAboutLine,
                guessQuestion: pendingGuessedQuestion?.typedText,
                skipGuess: pendingGuessedQuestion != nil
                    ? { Task { await sendPendingGuessedQuestion(guess: nil) } }
                    : nil,
                onRemoveQuote: {
                    quotedPassage = ""
                    fileDraft()
                },
                showsDeepResearchToken: showsDeepResearchToken,
                // The mode holds while a turn runs (`setAssistantMode`), as
                // the "+" menu's toggle shows by dimming.
                removeDeepResearchToken: showsDeepResearchToken && !manager.isSearching && !manager.isGenerating
                    ? { manager.setAssistantMode(.assistant) }
                    : nil
            )
            .contentShape(Rectangle())
            .onDrop(
                of: reviewChatDropTypes,
                isTargeted: dropTargetBinding,
                perform: handleDrop
            )

            // Every mode, Deep Research included, runs on the chat's
            // session-scoped model. "+" leads; the model, the mic and send
            // or Stop sit on the trailing edge, as in ChatGPT's composer.
            HStack(spacing: 8) {
                composerAddMenu

                if dictation.isRecording {
                    // The meter takes the rest of the row while the mic is
                    // open: it is the only thing worth looking at then, and
                    // the width is what makes it read as a waveform at all.
                    ReviewDictationWaveform(
                        meter: dictation.meter,
                        onStop: { Task { await finishManualDictationAndSend() } },
                        onKeepInDraft: { Task { await finishManualDictationIntoDraft() } }
                    )
                } else {
                    Spacer(minLength: 0)

                    // Screen record mode keeps the chip: the mode chooses which
                    // sources, chats and Pages show and hides the learner's name,
                    // never what the app can do (product owner, 2026-10-12: "the
                    // functionality of the app is no different").
                    InlineModelPicker(task: .chat)
                        // The chip always shows the model's whole name, so it
                        // takes its width before the row's Spacer.
                        .layoutPriority(1)

                    // The mic stays mid-turn: a dictated message queues behind
                    // the reply like a typed one. Stop takes the trailing edge
                    // below; voice mode waits for the turn to end.
                    composerMicControl
                    if !manager.canStopGeneration {
                        composerVoiceModeButton
                    }

                    // Only once the context is filling up: until then the ring
                    // asks nothing of the learner, and the ⋯'s Context and
                    // Cost… draws it with its breakdown open.
                    if let breakdown = manager.contextBreakdown,
                       isContextBreakdownRequested || Self.contextGaugeAsksForAttention(breakdown) {
                        ChatContextGauge(
                            breakdown: breakdown,
                            sessionCost: manager.sessionCost,
                            isBreakdownRequested: $isContextBreakdownRequested
                        )
                    }

                    // Last in the row so it sits flush right, where the
                    // send/stop control lives in every other chat composer.
                    if manager.canStopGeneration {
                        Button {
                            // Stop is "not that reply", not "not my next
                            // message": what was waiting goes back to the
                            // composer, to send again with one Return or to
                            // rewrite.
                            returnQueuedFollowUpsToComposer()
                            manager.stopGeneration()
                        } label: {
                            // Codex's Stop: a square on the same dark circle
                            // as send, in the place send was.
                            ChatComposerActionCircle(systemImage: "stop.fill", glyphSize: 10)
                        }
                        .buttonStyle(.hoverWash(in: Circle(), inset: -2, opacity: 0.12))
                        .help("Stop")
                        .accessibilityLabel("Stop")
                        .accessibilityIdentifier("mac.chatStop")
                    } else if !isManualDictationPending {
                        ReviewChatSendButton(
                            composer: composer,
                            hasAttachments: !manager.pendingImages.isEmpty,
                            // A team's shared transcript draws no composer.
                            isEnabled: !manager.isBusyOutsideTurn
                        ) {
                            Task { await submitComposer() }
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
            .popover(isPresented: $isSessionBrowserPresented, arrowEdge: .top) {
                sessionBrowserPopover
            }
        }
        // Which plugins the `@` popup offers is the gateway's answer, asked
        // once and shared. Connecting happens on the web, so coming back to the
        // app is the moment a new plugin can appear.
        .task { await ChatPluginPresence.shared.refreshIfStale() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await ChatPluginPresence.shared.refreshIfStale() }
        }
        .padding(.leading, StudioDesign.Spacing.medium)
        .padding(.trailing, StudioDesign.Spacing.small + 2)
        .padding(.top, StudioDesign.Spacing.medium)
        .padding(.bottom, StudioDesign.Spacing.small + 2)
        // A solid card, not glass, so source drops still reach the composer's
        // .onDrop and the field reads as paper the way Codex's does.
        .chatComposerCard(cornerRadius: Self.composerCornerRadius)
        .overlay {
            if showsComposerDropTarget {
                ReviewChatComposerDropTarget(
                    isTargeted: isDropTargeted,
                    payloadDescription: draggedPayloadDescription,
                    cornerRadius: Self.composerCornerRadius
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: showsComposerDropTarget)
        .animation(.easeOut(duration: 0.12), value: isDropTargeted)
    }

    /// The mic, or, while a dictated message is on its way to being sent,
    /// the transcribing mark with its way back into the draft.
    @ViewBuilder
    private var composerMicControl: some View {
        if isManualDictationPending, manualDictationResultDestination == .send {
            // The transcript is on its way to being sent. Until it lands
            // there is still time to change that: the X reroutes it into the
            // draft, where it can be read and edited first.
            HStack(spacing: 6) {
                ReviewDictationTranscribingIndicator()
                Button {
                    Task { await finishManualDictationIntoDraft() }
                } label: {
                    Image(systemName: "xmark")
                        .zoomedSystemFont(size: 8, weight: .semibold)
                        .frame(width: 20, height: 20)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.hoverWash(in: Circle(), opacity: 0.12))
                .help("Keep the transcript in the draft instead of sending it")
                .accessibilityLabel("Don't send the transcript")
                .accessibilityIdentifier("mac.chatDictation.cancelSend")
            }
        } else {
            Button {
                Task {
                    await dictation.startRecording()
                }
            } label: {
                recordButtonLabel
            }
            .buttonStyle(.hoverWash(in: Circle(), opacity: 0.12))
            .disabled(!canUseDictationButton)
            .help(dictationButtonHelp)
            .accessibilityLabel("Dictate message")
            .accessibilityIdentifier("mac.chatDictation")
        }
    }

    /// Voice mode from the chat, as ChatGPT's composer has it beside dictation:
    /// the conversation carries this chat on out loud, knowing what was said,
    /// and what ForeverLM says comes back into the chat when the call ends
    /// (`RealtimeVoiceChatContinuation`). A chat with no row yet starts voice
    /// mode's assistant, which keeps its own voice chat.
    private var composerVoiceModeButton: some View {
        Button {
            guard let chat = manager.voiceContinuationChat else {
                MacRealtimeVoice.startAssistant()
                return
            }
            let manager = manager
            MacRealtimeVoice.continueChat(chat) { note in
                await manager.appendVoiceConversation(note, toSession: chat.sessionID)
            }
        } label: {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.hoverWash(in: Circle(), opacity: 0.12))
        .disabled(manager.isBusyOutsideTurn)
        .help("Continue this chat by voice")
        .accessibilityLabel("Continue this chat by voice")
        .accessibilityIdentifier("mac.chatVoiceMode")
    }

    /// The ring is drawn once the request fills this much of the model's
    /// window: where its own colour turns from the accent to orange, the
    /// first point at which it asks for something (a new chat, fewer
    /// sources). Below it the ⋯'s Context and Cost… draws it with its breakdown open.
    static let contextGaugeAttentionFraction = 0.7

    static func contextGaugeAsksForAttention(_ breakdown: ReviewSessionManager.ChatContextBreakdown) -> Bool {
        breakdown.usedFraction >= contextGaugeAttentionFraction
    }

    /// The modes that are a kind of chat rather than a review or a summary,
    /// where Deep Research is one of the two the learner chooses between.
    private var offersDeepResearch: Bool {
        [.assistant, .shallowRead, .deepRead, .deepResearch].contains(manager.currentPromptMode)
    }

    /// The "Deep research" token at the head of the field.
    private var showsDeepResearchToken: Bool {
        offersDeepResearch && manager.isDeepResearchMode
    }

    /// "+" at the composer's leading edge, as in ChatGPT's: what can be added
    /// to the message, and Deep Research, with no always-visible Chat /
    /// Deep Research pill (product owner, 2026-10-06: "make the app more
    /// slick; kind of like the chatgpt app"). Its menu opens
    /// upward, like the model picker's, since the composer sits at the foot of
    /// the window (`UpwardMenuChip`).
    @ViewBuilder
    private var composerAddMenu: some View {
        if #available(macOS 14.4, *) {
            UpwardMenuChip {
                composerAddMenuItems
            } label: {
                composerAddMenuLabel
            }
            .modifier(ComposerAddMenuChrome())
        } else {
            Menu {
                composerAddMenuItems
            } label: {
                composerAddMenuLabel
            }
            .pickerPillMenu()
            .fixedSize()
            .modifier(ComposerAddMenuChrome())
        }
    }

    /// Codex's "+": full ink, a size up from the controls beside it.
    private var composerAddMenuLabel: some View {
        Image(systemName: "plus")
            .zoomedSystemFont(size: 15, weight: .regular)
            .foregroundStyle(.primary)
            .frame(width: 16, height: 18)
    }

    /// The "+" chip's help and accessibility, shared by both menu routes.
    private struct ComposerAddMenuChrome: ViewModifier {
        func body(content: Content) -> some View {
            content
                .help("Add")
                .accessibilityLabel("Add")
                .accessibilityIdentifier("mac.chatAdd")
        }
    }

    @ViewBuilder
    private var composerAddMenuItems: some View {
        // What a drop from Finder does: a picture goes with the message, a
        // paper, book or text file into the library and this chat.
        Button {
            Task { await addFilesFromOpenPanel() }
        } label: {
            Label("Add Photos and Files…", systemImage: "paperclip")
        }
        // The source picker `/source` opens past its popup.
        Button {
            slashSourcePickerRequest = SlashSourcePickerRequest(seed: "")
        } label: {
            Label("Add Sources…", systemImage: "books.vertical")
        }
        if offersDeepResearch {
            Divider()
            // A Toggle, so the item's own state column shows it is on.
            Toggle(isOn: Binding(
                get: { manager.isDeepResearchMode },
                set: { manager.setAssistantMode($0 ? .deepResearch : .assistant) }
            )) {
                Label("Deep Research", systemImage: "globe")
            }
            .disabled(manager.isSearching || manager.isGenerating)
        }
    }

    /// Add Photos and Files…: the open panel, and then exactly what a drop
    /// of the same files from Finder does (`handleDrop`).
    @MainActor
    private func addFilesFromOpenPanel() async {
        let urls = await FilePanel.open { panel in
            panel.allowsMultipleSelection = true
            panel.allowedContentTypes = Self.chatImageDropTypes
                + supportedBookImportContentTypes
                + [.plainText, UTType(filenameExtension: "md")].compactMap { $0 }
            panel.prompt = "Add"
        }
        for url in urls {
            await addDroppedFile(url)
        }
    }

    /// One file the learner gave this chat, by drop or by the Add menu. A
    /// picture and a PDF are for the message, not the library; anything else
    /// (a book, a text file) is imported as a source and joins the chat.
    @MainActor
    func addDroppedFile(_ url: URL) async {
        if Self.isImageFile(url) {
            await attachImageFile(url)
            return
        }
        if url.isFileURL, url.pathExtension.lowercased() == "pdf" {
            await attachPDFFile(url)
            return
        }
        let previousIDs = Set(vm.contextSourceIds)
        await vm.importDroppedFile(url: url)
        let newArticles = vm.contextSourceArticles.filter { !previousIDs.contains($0.id) }
        await addArticlesToChatContext(newArticles)
    }

    // The record button carries the two quiet voice states; the loud one — the mic
    // actually being open — takes over the whole control row instead (see above).
    @ViewBuilder
    private var recordButtonLabel: some View {
        if dictation.isTranscribing {
            ReviewDictationTranscribingIndicator()
        } else {
            Image(systemName: "mic.fill")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
                .foregroundStyle(.secondary)
        }
    }

    /// Context chips above the composer, echoing how coding assistants pin the
    /// working folder above their input: the canvas this chat was opened from
    /// and the cards added to it, the notebook this chat is filed in, then the
    /// sources and Docs it can reach that no chip already shows. A chat in no
    /// notebook shows no notebook chip, and there is no picker here (product
    /// owner, 2026-10-06: "too much"); a chat's notebook comes from the window
    /// it is opened in. They wrap, so a canvas with many cards takes a second
    /// line rather than the width.
    ///
    /// In its own notebook's window neither chip is drawn (the
    /// ChatGPT composer: nothing over the field the learner did not put
    /// there): the window is that notebook, and its Sources column says what
    /// the chat reads, ticked, with "N of M in chat". A Page attached to the
    /// chat is the exception, since the Sources column does not list it.
    ///
    /// The row is the composer's tray, behind the card's top
    /// edge (`ChatComposerStack`), where Codex shows the project.
    ///
    /// What is open beside the chat has a chip too, in every window, a
    /// notebook's included: the chat is told of it with every
    /// message, so the tray says so, and its × leaves it out
    /// (`onScreenChips`).
    @ViewBuilder
    private var composerContextRow: some View {
        let chips = composerContextChips
        if chips.showsAny {
            FlowLayout(spacing: 8) {
                if let canvasContext = manager.canvasContext {
                    canvasChips(canvasContext)
                }
                if chips.notebook {
                    notebookChip
                }
                onScreenChips(chips.onScreen)
                if let card = chips.card {
                    onScreenCardChip(card)
                }
                openItemChips(chips.open)
                if chips.context {
                    attachedSourcesChip
                }
                if let plan = manager.reviewPlan, manager.offersReviewPlanTool {
                    ReviewPlanChip(
                        plan: plan,
                        earlierTitles: manager.earlierReviewPlanTitles,
                        onBackToPlan: {
                            Task { await sendReviewChatMessage(ChatReviewPlan.backToPlanMessage) }
                        },
                        onGoToTopic: { index, title in
                            Task { await sendReviewChatMessage(ChatReviewPlan.goToTopicMessage(index: index, title: title)) }
                        },
                        onClear: {
                            Task { await manager.clearReviewPlan() }
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Which of the context row's chips are drawn: the notebook's outside its
    /// own window, the "in context" pill when something is, the canvas's,
    /// and one for each source open beside the chat.
    ///
    /// The pill shows in the notebook's own window too. It counts what the
    /// chat has read in full, which the Sources column's ticks do not say:
    /// the notebook's pool is catalog-only, so a source picked with `/source`
    /// left no trace there and read as not added (product owner, 2026-11-10:
    /// "this doesn't seem to add it to the context").
    private var composerContextChips: (notebook: Bool, context: Bool, onScreen: [ChatContextAdditions.OnScreen], card: ChatContextAdditions.CardOnScreen?, open: [ChatContextAdditions.OpenItem], showsAny: Bool) {
        let inOwnNotebookWindow = notebookGuideNotebook != nil
        let notebook = linkedResearchNotebook != nil && !inOwnNotebookWindow
        let context = contextItemCount > 0
        let onScreen = onScreenChipSources
        let card = onScreenCardChipCard
        let open = openItemChipItems
        let plan = manager.reviewPlan != nil && manager.offersReviewPlanTool
        return (notebook, context, onScreen, card, open, notebook || context || plan || !onScreen.isEmpty || card != nil || !open.isEmpty || manager.canvasContext != nil)
    }

    /// The Pages, Sites, web pages and courses on screen in any
    /// window, read as a message sent now reads them
    /// (`ChatOpenPanes.openOnScreen`). Empty for a chat outside a Studio
    /// window.
    var openItemsBesideChat: [ChatContextAdditions.OpenItem] {
        guard let windowState else { return [] }
        return ChatOpenPanes.openOnScreen(chatWindow: windowState, chatSessionID: manager.currentSessionID, vm: vm)
    }

    /// What a chip's × can leave out, as it is open now: each source's id,
    /// the card's, and each open item's key.
    var openKeysBesideChat: [String] {
        var keys = sourcesOnScreenBesideChat.map(\.id)
        if let card = cardOnScreenBesideChat { keys.append(card.id) }
        keys += openItemsBesideChat.map(\.key)
        return keys
    }

    /// The open items the tray gives a chip: less what the learner left out
    /// with a chip's ×, and less a Page the "in context" pill already counts.
    private var openItemChipItems: [ChatContextAdditions.OpenItem] {
        let leftOut = manager.onScreenSourcesLeftOut
        let attachedDocs = Set(manager.contextDocs.map(\.id))
        return openItemsBesideChat.filter { !leftOut.contains($0.key) && !attachedDocs.contains($0.id ?? "") }
    }

    /// The library sources on screen in this chat's window, read as a
    /// message sent now reads them (`ChatOpenPanes.sourcesOnScreen`). Empty
    /// for a chat outside a Studio window.
    var sourcesOnScreenBesideChat: [ChatContextAdditions.OnScreen] {
        guard let windowState else { return [] }
        return ChatOpenPanes.sourcesOnScreen(chatWindow: windowState, vm: vm)
    }

    /// The open sources the tray gives a chip: what the chat is told is on
    /// screen, less what the learner left out with a chip's ×, and less what
    /// the "in context" pill already counts, whose text the chat has read in
    /// and whose × is in that pill's list.
    private var onScreenChipSources: [ChatContextAdditions.OnScreen] {
        let leftOut = manager.onScreenSourcesLeftOut
        let loaded = manager.loadedSourceIDs
        return sourcesOnScreenBesideChat.filter { !leftOut.contains($0.id) && !loaded.contains($0.id) }
    }

    /// The flashcard the Memory pane beside the chat has in front of the
    /// learner, read as a message sent now reads it.
    private var cardOnScreenBesideChat: ChatContextAdditions.CardOnScreen? {
        guard let windowState else { return manager.pinnedCard }
        return ChatOpenPanes.cardOnScreen(chatWindow: windowState, vm: vm, pinned: manager.pinnedCard)
    }

    /// The open card the tray gives a chip: less what the learner left out
    /// with its ×.
    private var onScreenCardChipCard: ChatContextAdditions.CardOnScreen? {
        guard let card = cardOnScreenBesideChat,
              !manager.onScreenSourcesLeftOut.contains(card.id) else { return nil }
        return card
    }

    /// The card open in the Memory pane beside the chat as a chip, like an
    /// open source's (product owner, 2026-10-15: "whatever is open on the
    /// right is actually automatically in the chat context"): the chat is
    /// told of the card with every message (`ChatContextAdditions.cardFraming`),
    /// and the × leaves it out for as long as it stays in front.
    @ViewBuilder
    private func onScreenCardChip(_ card: ChatContextAdditions.CardOnScreen) -> some View {
        ComposerRemovableChip(
            symbol: "rectangle.on.rectangle",
            title: card.question,
            maxTitleWidth: 220,
            help: "Open beside this chat, so the chat sees it",
            removeHelp: "Leave this card out of this chat while it is open",
            accessibilityLabel: "Open beside the chat: card \u{201C}\(card.question)\u{201D}",
            open: nil,
            remove: { manager.leaveOutOnScreenSource(card.id) }
        )
        .accessibilityIdentifier("chat.onScreenCardChip")
    }

    /// A chip for each source open beside the chat (product owner,
    /// 2026-10-13: "perhaps a chat should know at all times what is OPEN;
    /// i.e. it should know i have this youtube video open. and if i don't
    /// want to chat about that; i can click a small X and it will remove it
    /// from context"). The chat already reads what is on screen with every
    /// message, a video with its moment (`ChatContextAdditions.onScreen`);
    /// the chip shows it, and its × leaves the source out of this chat for
    /// as long as it stays open (`ReviewSessionManager.onScreenSourcesLeftOut`).
    /// The source is in front of the learner, so the chip opens nothing.
    @ViewBuilder
    private func onScreenChips(_ sources: [ChatContextAdditions.OnScreen]) -> some View {
        ForEach(sources, id: \.id) { source in
            ComposerRemovableChip(
                symbol: vm.articlesById[source.id]?.sourceType.symbolName ?? "doc",
                title: source.title,
                maxTitleWidth: 220,
                help: "Open beside this chat, so the chat sees it",
                removeHelp: "Leave \u{201C}\(source.title)\u{201D} out of this chat while it is open",
                accessibilityLabel: "Open beside the chat: \(source.title)",
                open: nil,
                remove: { manager.leaveOutOnScreenSource(source.id) }
            )
            .accessibilityIdentifier("chat.onScreenChip")
        }
    }

    /// A chip for each Page, Site, web page or course open in any
    /// window (product owner, 2026-11-08: "put everything that's open into
    /// the context"): every message carries them
    /// (`ChatContextAdditions.openFraming`), the chip says so, and its ×
    /// leaves the item out of this chat for as long as it stays open.
    @ViewBuilder
    private func openItemChips(_ items: [ChatContextAdditions.OpenItem]) -> some View {
        ForEach(items, id: \.key) { item in
            let title = item.title.isEmpty ? (item.url ?? item.kind) : item.title
            ComposerRemovableChip(
                symbol: Self.openItemSymbol(item.kind),
                title: title,
                maxTitleWidth: 220,
                help: "Open in ForeverLM, so the chat sees it",
                removeHelp: "Leave \u{201C}\(title)\u{201D} out of this chat while it is open",
                accessibilityLabel: "Open in ForeverLM: \(item.kind) \(title)",
                open: nil,
                remove: { manager.leaveOutOnScreenSource(item.key) }
            )
            .accessibilityIdentifier("chat.openItemChip")
        }
    }

    private static func openItemSymbol(_ kind: String) -> String {
        switch kind {
        case "Page": return "doc.text"
        case "Site": return "safari"
        case "animation": return "film"
        case "web page": return "globe"
        case "course": return "graduationcap"
        default: return "doc"
        }
    }

    /// Whether the composer draws its tray.
    private var showsComposerContextRow: Bool { composerContextChips.showsAny }

    /// The canvas this chat was opened from as a chip, and a chip for each of
    /// its cards the learner added (`KnowledgeMapChatChipRow`): a click shows
    /// the canvas or the card, an × takes the canvas, or the card from the
    /// next turn, out of the chat.
    @ViewBuilder
    private func canvasChips(_ context: KnowledgeMapChatContext) -> some View {
        KnowledgeMapChatChipRow(
            context: context,
            symbol: { card in
                vm.knowledgeMap(in: windowState).nodesByRef[card.ref].map(KnowledgeMapCardGlyph.symbol(for:)) ?? "rectangle.on.rectangle"
            },
            showCanvas: { vm.showKnowledgeMapChatCanvas(context.canvasID, in: windowState) },
            showCard: { ref in
                vm.task(in: windowState) { await vm.showKnowledgeMapChatCard(ref, canvasID: context.canvasID, in: windowState) }
            },
            removeCard: { manager.removeCanvasCard($0) },
            removeCanvas: { manager.removeCanvasContext() }
        )
    }

    @ViewBuilder
    private var notebookChip: some View {
        if let notebook = linkedResearchNotebook {
            Button {
                vm.openNotebookInReader(notebook.id)
            } label: {
                notebookChipLabel(notebook)
            }
            .buttonStyle(ComposerChipButtonStyle())
            .help("This chat works in \u{201C}\(NotebookTitle(notebook.title).text)\u{201D} — click to open the notebook")
            .accessibilityLabel(notebookChipAccessibilityLabel(notebook))
            .contextMenu { OtherWindowMenuItem(.notebook(notebook.id)) }
        }
    }

    private func notebookChipLabel(_ notebook: LearningGoalRecord) -> some View {
        HStack(spacing: 5) {
            let notebookTitle = NotebookTitle(notebook.title)
            NotebookIconView(notebookID: notebook.id, size: 14, cornerRadius: 3) {
                Text(notebookTitle.displayIcon)
                    .font(.caption2)
            }
            .accessibilityHidden(true)
            Text(notebookTitle.text)
                .lineLimit(1)
                .truncationMode(.tail)
            if let summary = notebookSelectionSummary {
                Text("\u{00B7} \(summary)")
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
        // On the tray the notebook reads in full ink, as Codex's project does.
        .font(.callout)
        .foregroundStyle(.primary)
    }

    private func notebookChipAccessibilityLabel(_ notebook: LearningGoalRecord) -> String {
        "Notebook: \(NotebookTitle(notebook.title).text)"
            + (notebookSelectionSummary.map { ", \($0) sources" } ?? "")
    }

    /// New Notebook from This Chat: the notebook made at once, carrying what
    /// the open chat holds beyond its record.
    func requestNotebookFromChat(_ sessionID: String) {
        notebookFromChatRequest = NotebookFromChatRequest(
            sessionID: sessionID,
            title: selectedChatTitle ?? "",
            openChatSourceIDs: manager.linkedSourceIDs + manager.loadedSourceIDs.sorted()
        )
    }

    /// What this chat is holding, shown above the composer so a drag-in or an
    /// attached Doc gives immediate visible confirmation. "In context" means
    /// source text the model has actually read plus the Docs it can read on
    /// demand. The wider pool it could reach is not counted here: a Notebook is
    /// a focus, not a wall, the whole library stays searchable from any chat,
    /// and the learner narrows or widens a question by asking ("only this
    /// Notebook's sources", "anything in my library"), so a pool size above the
    /// composer answered a question nobody was asking.
    ///
    /// Nothing in context, no chip. An attached Doc or a dragged-in source
    /// shows it on its own, so an explicit gesture never looks like it did
    /// nothing.
    @ViewBuilder
    private var attachedSourcesChip: some View {
        if contextItemCount > 0 {
            Button {
                isContextSourcesPopoverPresented.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(loadedContextSummary)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.18), value: contextItemCount)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(
                        Color.primary.opacity(
                            isContextSourcesPopoverPresented ? 0.09
                                : (isContextSourcesChipHovering ? 0.06 : 0)
                        )
                    )
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { isContextSourcesChipHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isContextSourcesChipHovering)
            .help("Show what this chat has read in")
            .accessibilityLabel("\(contextItemCount) items in context")
            .popover(isPresented: $isContextSourcesPopoverPresented, arrowEdge: .top) {
                contextSourcesPopover
            }
        }
    }

    /// Everything the chat is actually holding that no chip shows: sources
    /// whose text was read in, plus Docs attached by identity, less the ones a
    /// canvas card's chip already names. One number, because the learner asked
    /// one question — what is in the context?
    private var contextItemCount: Int {
        KnowledgeMapChatChips.pillCount(
            loadedSourceIDs: loadedSources.map(\.id),
            docIDs: manager.contextDocs.map(\.id),
            cards: manager.canvasContext?.cards ?? []
        )
    }

    /// What the "In context" popover lists: the sources and Docs the pill
    /// counts. Taking a card's chip away leaves its source or Doc here, to be
    /// removed from the context as any is.
    private var sourcesOutsideChips: [StudioArticle] {
        let shown = KnowledgeMapChatChips.sourceIDs(shownBy: manager.canvasContext?.cards ?? [])
        return loadedSources.filter { !shown.contains($0.id) }
    }

    private var docsOutsideChips: [ChatDocAttachment] {
        let shown = KnowledgeMapChatChips.docIDs(shownBy: manager.canvasContext?.cards ?? [])
        return manager.contextDocs.filter { !shown.contains($0.id) }
    }

    private var loadedContextSummary: String {
        "\(contextItemCount) in context"
    }

    /// What the assistant has actually read — not what it could reach.
    private var contextSourcesPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("In context")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if contextItemCount > 0 {
                    Text("\(contextItemCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if contextItemCount == 0 {
                Text("Nothing loaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        // Docs first: a Doc is attached deliberately, one at a
                        // time, while sources arrive by the dozen from a pool.
                        ForEach(docsOutsideChips) { doc in
                            ContextDocCard(doc: doc) {
                                manager.removeContextDoc(doc.id)
                            }
                        }
                        ForEach(sourcesOutsideChips) { source in
                            ContextSourceCard(
                                source: source,
                                metadataVisibility: metadataVisibility,
                                onOpen: {
                                    isContextSourcesPopoverPresented = false
                                    Task { await vm.openLinkedSourceInReader(source.id) }
                                },
                                onRemove: { removeSourceFromChatContext(source.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
            }

        }
        .frame(width: contextSourcesPopoverWidth)
        .frame(maxHeight: contextSourcesPopoverHeight)
    }

    /// Where this conversation came from, once it has been written down: the
    /// header ⋯'s "Open “<page>” — <section>", falling back to the page alone
    /// when the passage sat under no heading. It brings the page forward, so
    /// the round trip with the page's Discussion closes in both directions.
    /// No line over the composer says "From <page> — <section>" for the whole
    /// chat (the ChatGPT composer: nothing stays over the field that the
    /// learner did not just put there).
    func docOriginMenuTitle(for entry: ArtifactChatLink) -> String {
        let title = vm.artifacts.first { $0.id == entry.link.artifactID }?.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let docName = "\u{201C}\((title?.isEmpty == false ? title : nil) ?? "Untitled page")\u{201D}"
        guard !entry.link.sectionTitle.isEmpty else { return "Open \(docName)" }
        return "Open \(docName) — \(entry.link.sectionTitle)"
    }

    /// `StudioAssistantSessionStore.docPassageJoinsOpenChat`, with the doc
    /// links read for the chat on screen. Links still loaded for the chat
    /// shown before it do not count, and neither does this chat while another
    /// is on its way into the pane.
    func docPassageJoinsThisChat(_ request: ReaderSelectionExplanationRequest) -> Bool {
        guard requestedResumeSessionID == nil else { return false }
        let sessionID = manager.currentSessionID
        let linkedDocIDs = Set(sessionDocLinks.lazy.filter { $0.link.sessionID == sessionID }.map(\.link.artifactID))
        return sessionStore.docPassageJoinsOpenChat(request, linkedDocIDs: linkedDocIDs)
    }

    @MainActor
    func reloadSessionDocLinks() async {
        guard let sessionID = manager.currentSessionID else {
            sessionDocLinks = []
            return
        }
        sessionDocLinks = await vm.chatDocLinks(sessionID: sessionID)
    }

    /// Pictures waiting to go with the next message.
    @ViewBuilder
    private var pendingImagesRow: some View {
        if !manager.pendingImages.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(manager.pendingImages) { attachment in
                        PendingChatImageChip(attachment: attachment) {
                            manager.removePendingImage(attachment.id)
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .accessibilityLabel("\(manager.pendingImages.count) attached \(manager.pendingImages.count == 1 ? "image" : "images")")
        }
    }

    @ViewBuilder
    private var readerSelectionChip: some View {
        if let selection = pendingReaderSelection {
            HStack(spacing: 5) {
                Image(systemName: readerSelectionChipIcon(for: selection))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text(readerSelectionPreview(for: selection))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button {
                    pendingReaderSelection = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.hoverWash(opacity: 0.12))
                .help(readerSelectionChipRemoveHelp(for: selection))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(readerSelectionChipKindLabel(for: selection) + readerSelectionPreview(for: selection))
        }
    }

    private func readerSelectionChipIcon(for selection: ReaderSelectionExplanationRequest) -> String {
        if selection.reviewHandoff != nil { return MemoryReviewSession.sidebarIcon }
        if selection.sideQuestionHandoff != nil { return "arrow.turn.down.right" }
        if selection.isPictureOnly { return "photo" }
        return "text.quote"
    }

    private func readerSelectionChipRemoveHelp(for selection: ReaderSelectionExplanationRequest) -> String {
        if selection.reviewHandoff != nil { return "Remove the review exchange from chat context" }
        if selection.sideQuestionHandoff != nil { return "Remove the side question from chat context" }
        if selection.isPictureOnly { return "Remove the selected picture's note from chat context" }
        return "Remove selected passage from chat context"
    }

    private func readerSelectionChipKindLabel(for selection: ReaderSelectionExplanationRequest) -> String {
        if selection.reviewHandoff != nil { return "From the memory review: " }
        if selection.sideQuestionHandoff != nil { return "From a side question: " }
        if selection.isPictureOnly { return "Selected picture: " }
        return "Selected passage: "
    }

    /// Notebook titles come from current app state, so `/notebook` can offer deterministic
    /// identity choices without asking the model to decide which stored record was meant.
    var slashCommands: [ReviewSlashCommand] {
        var commands = ReviewSlashCommand.all.map { command in
            guard command.kind == .notebook else { return command }
            return command.withArguments(
                vm.notebooks
                    .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                    .map {
                        ReviewSlashCommand.Argument(value: $0.title, display: "Switch to this notebook")
                    }
            )
        }
        // The learner's skills follow the app's own commands. A name is taken
        // once — the store refuses a built-in's name, and two skills of one
        // name (two Macs, before sync met) offer the newer edit.
        var taken = Set(commands.map(\.name))
        for skill in SkillLibrary.shared.skills.sorted(by: { $0.updatedAt > $1.updatedAt }) where !taken.contains(skill.name) {
            taken.insert(skill.name)
            commands.append(.skill(skill))
        }
        return commands
    }

    private var pluginPresence: ChatPluginPresence { ChatPluginPresence.shared }

    /// The connected plugins the open chat can ask — one per plugin this
    /// chat's mode can read, so the `@` popup never offers a question the model
    /// has no tool to answer. The send reads the same list, so a mention is
    /// recognised exactly where it was offered.
    var chatPlugins: [ChatPlugin] {
        pluginPresence.plugins(availableIn: manager.currentPromptMode)
    }

    /// `@slack`, `@linear`, `@github` as the popup offers them.
    private var composerMentions: [ReviewComposerMention] {
        chatPlugins.map { $0.mention(slackWorkspaces: pluginPresence.slackWorkspaces) }
    }

    /// The open chat's record when it is a transcript a team shared. Such a
    /// chat is a snapshot: it has no tutor to answer and nothing to send.
    var teamSnapshotRecord: ReviewSessionRecord? {
        guard let sessionID = manager.currentSessionID,
              let record = vm.reviewSessionLinks.first(where: { $0.id == sessionID }),
              record.isTeamSnapshot else { return nil }
        return record
    }

    func sharedTranscriptFooter(_ snapshot: ReviewSessionRecord) -> some View {
        let teamName = snapshot.teamID.flatMap { vm.team(id: $0)?.name }
        return HStack(spacing: 6) {
            Image(systemName: "person.2")
                .font(.system(size: 11, weight: .medium))
            Text(teamName.map { "Shared transcript from \($0)" } ?? "Shared transcript")
                .font(.callout)
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, StudioDesign.Spacing.medium)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("chat.sharedTranscriptFooter")
    }

    var canSubmitComposer: Bool {
        // Sending while a reply is still generating is allowed: the message is
        // queued, drawn under the running turn, and answered as soon as that
        // turn finishes. Only work outside a turn holds the composer — a saved
        // chat hydrating, sources being attached — because there is no turn for
        // the message to follow. A team's transcript snapshot never sends.
        teamSnapshotRecord == nil &&
        !manager.isBusyOutsideTurn &&
        (
            !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            // A quoted passage on its own is a message: it asks about itself.
            !quotedPassage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            // So is a long paste waiting as an attachment.
            !composer.pastedTexts.isEmpty ||
            !manager.pendingImages.isEmpty ||
            dictation.isRecording ||
            dictation.isTranscribing ||
            manualDictationTranscriptionTask != nil
        )
    }

    var isManualDictationPending: Bool {
        dictation.isRecording || dictation.isTranscribing || manualDictationTranscriptionTask != nil
    }

    /// The one condition where the control cannot act: a recording still being
    /// transcribed. A turn in flight does not stop dictation.
    private var canUseDictationButton: Bool {
        !dictation.isTranscribing &&
        manualDictationTranscriptionTask == nil
    }

    private var dictationButtonHelp: String {
        if dictation.isRecording { return "Stop dictation and send" }
        if dictation.isTranscribing { return "Transcribing…" }
        return "Dictate answer"
    }
}
