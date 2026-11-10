// Side questions, drafts, dictation and sending a message from the chat panel.
import SwiftUI
import Combine
import UniformTypeIdentifiers
import PDFKit
import WebKit
import AppKit

extension InternalReviewPanelContent {
    // MARK: - Side questions

    /// The newest stretch of the transcript, grouped the way the transcript
    /// draws it: an ordinary block, or a side question's lane. Newest by
    /// time, not by position: a lane about an older reply is drawn up under
    /// that reply.
    private var newestTranscriptSection: ReviewChatTranscriptSection? {
        guard !manager.chatMessages.isEmpty else { return nil }
        let blocks = ReviewChatTranscriptBlock.grouping(manager.chatMessages)
        return ReviewChatTranscriptSection.newest(in: ReviewChatTranscriptSection.grouping(blocks), blocks: blocks)
    }

    /// The newest ordinary reply — the one an aside is about when nothing
    /// names another — as the mark beside the aside refers to it.
    private var newestReplyReference: ReviewChatReplyReference? {
        let blocks = ReviewChatTranscriptBlock.grouping(manager.chatMessages)
        let sections = ReviewChatTranscriptSection.grouping(blocks)
        // Inside a lane, the reply the lane is about; otherwise the last reply.
        if let newest = ReviewChatTranscriptSection.newest(in: sections, blocks: blocks),
           newest.isSideQuestion, let aboutID = newest.aboutBlockID,
           let block = blocks.first(where: { $0.id == aboutID }) {
            return ReviewChatReplyReference(blockID: block.id, line: ReviewChatTranscriptSection.replyLine(of: block))
        }
        guard let block = sections.last(where: { section in
            !section.isSideQuestion && section.blocks.contains { $0.userMessage == nil }
        })?.blocks.last(where: { $0.userMessage == nil }) else {
            return nil
        }
        return ReviewChatReplyReference(blockID: block.id, line: ReviewChatTranscriptSection.replyLine(of: block))
    }

    /// The line the composer's token shows under "Side question" when the
    /// aside is about a reply other than the newest, so the learner can see
    /// which. Nil for the newest reply, where the token alone says enough.
    var sideQuestionTokenAboutLine: String? {
        guard isSideQuestionMode, let target = sideQuestionTarget, let line = target.line else { return nil }
        guard target.blockID != newestReplyReference?.blockID else { return nil }
        return line
    }

    /// The tutor's question the chat is waiting on, when there is one: the last
    /// paragraph of the newest ordinary reply, if it asks something — or, under
    /// a side question, the question that was open when the aside was asked.
    /// Nil while an ordinary turn runs, since what is open is about to change.
    /// A side question's own reply changes nothing: the waiting question is
    /// stored with the aside, so a follow-up typed while that reply is still
    /// being written goes as a side question too, and joins the lane.
    var openTutorQuestion: String? {
        guard let last = newestTranscriptSection else { return nil }
        if last.isSideQuestion { return last.openQuestion }
        guard !isTurnInFlight else { return nil }
        guard let block = last.blocks.last, block.userMessage == nil,
              let reply = block.answerMessages.last(where: { message in
                  message.role == .assistant
                      && ReviewSessionManager.displayableMessageContent(role: .assistant, content: message.content)?
                          .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
              }) else { return nil }
        return ChatSideQuestion.openQuestion(
            in: ReviewSessionManager.displayableMessageContent(role: .assistant, content: reply.content) ?? ""
        )
    }

    /// The footer icon on a reply lands here. On the reply the token is
    /// already about, it takes the token off; on any other reply it arms the
    /// composer for an aside about that one and brings the composer to the
    /// front, since the click was up in the transcript.
    func toggleSideQuestionMode(about reply: ReviewChatReplyReference) {
        if isSideQuestionMode, sideQuestionTarget?.blockID == reply.blockID {
            disarmSideQuestion()
            return
        }
        isSideQuestionMode = true
        sideQuestionTarget = reply
        requestComposerFocus()
    }

    /// The token comes off, from its ×, Escape, Backspace at the start of the
    /// draft, or the armed icon again. The next message goes as usual.
    func disarmSideQuestion() {
        isSideQuestionMode = false
        sideQuestionTarget = nil
    }

    /// Back from a side question to the tutor's question: answer mode, and the
    /// composer takes focus.
    func returnToOpenQuestion() {
        disarmSideQuestion()
        requestComposerFocus()
    }

    /// More about the side question, here: the composer takes focus with the
    /// token in place and the lane's reply as what it is about, so the next
    /// Return is another side question and its reply joins the lane. Any open
    /// question stays open underneath. The token is already there after a
    /// side question — it stays armed until the learner goes back to the
    /// question — so this is mostly the focus.
    func followUpSideQuestion() {
        guard let lane = newestTranscriptSection, lane.isSideQuestion else { return }
        isSideQuestionMode = true
        if let aboutID = lane.aboutBlockID,
           let block = ReviewChatTranscriptBlock.grouping(manager.chatMessages).first(where: { $0.id == aboutID }) {
            sideQuestionTarget = ReviewChatReplyReference(
                blockID: block.id,
                line: ReviewChatTranscriptSection.replyLine(of: block)
            )
        }
        requestComposerFocus()
    }

    /// More details on a reply: the tutor expands it in a lane under it. The
    /// press is stored as a side question the app wrote — the mark, the More
    /// details mark, the reply's first line, and any open question — with the
    /// fixed words "More details" as the learner's line, so it survives a
    /// reopen and syncs like any aside. A reply that already has its lane is
    /// not asked again; the lane opens. A press while a turn is running waits
    /// under it like any queued message.
    func requestMoreDetails(about reply: ReviewChatReplyReference, existingLaneID: UUID?) {
        if let existingLaneID {
            laneExpansionRequest = ReviewChatLaneExpansionRequest(laneID: existingLaneID, token: UUID())
            return
        }
        let context = ChatSideQuestion.contextContent(
            openQuestion: openTutorQuestion,
            aboutReply: reply.line,
            moreDetails: true
        )
        // The fixed words alone: a picture waiting in the tray belongs to the
        // message the learner is writing, not to this press.
        let content = ChatSideQuestion.moreDetailsQuestion
        Task {
            if manager.queuesSendsNow {
                _ = manager.enqueueFollowUp(content, contextualContent: context, docAnchor: nil)
                await manager.resumeQueuedFollowUps()
                return
            }
            await sendReviewChatMessage(content, contextualContent: context)
        }
    }

    /// The side question leaves the quiz: the aside and every reply it drew
    /// open a new chat as its context, filed under the same Notebook with the
    /// same sources, where the tutor holds nothing back. This chat is left
    /// exactly as it is, its question still open; the token, if armed, is
    /// dropped, since the follow-up is happening elsewhere.
    func openSideQuestionInNewChat() {
        guard let section = newestTranscriptSection, section.isSideQuestion else { return }
        let turns = section.sideQuestionTurns
        guard !turns.isEmpty else { return }
        disarmSideQuestion()
        let handoff = ChatSideQuestionHandoff(
            chatTitle: manager.topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Chat" : manager.topic,
            openQuestion: section.openQuestion,
            turns: turns,
            sourceIDs: manager.linkedSourceIDs,
            notebookID: linkedResearchNotebookID
        )
        let request = ReaderSelectionExplanationRequest(sideQuestionHandoff: handoff)
        if let onOpenNewChatBeside {
            onOpenNewChatBeside(request)
        } else {
            vm.requestChatAboutSideQuestion(request)
        }
    }

    /// The learner lets the open question go. Said in words, so the tutor hears
    /// it the way it would hear the same thing typed. In a quiz's chat the
    /// question is a quiz question, skipped the way Skip Question skips it.
    func skipOpenQuestion() async {
        disarmSideQuestion()
        if manager.courseQuizOpenQuestionNumber != nil {
            await skipCourseQuizQuestion()
            return
        }
        await sendReviewChatMessage("Let's skip that question and move on.")
    }

    /// Asks this panel's composer to take focus. The docked panes answer the
    /// view model's one request, and so does anything that asks through it; the
    /// page's side chat has a request of its own in its store, so opening it
    /// does not pull focus into the docked chat's field.
    func requestComposerFocus() {
        if pageSideChat != nil {
            sessionStore.composerFocusRequestID = UUID()
        } else {
            vm.reviewChatFocusRequestID = UUID()
        }
    }

    /// What the empty field says. "Ask anything", ChatGPT's own, for as long
    /// as the chat goes on (product owner, 2026-10-06: "make the app more slick;
    /// kind of like the chatgpt app"); until then it went blank after the
    /// first turn. What the field is for right now — a guess, an aside, a
    /// passage, a walk's card, a mode — says so instead.
    var chatInputPlaceholder: String {
        if pendingGuessedQuestion != nil {
            return "Your guess first? Return sends both"
        }
        if isSideQuestionMode {
            return openTutorQuestion != nil ? "Ask anything — the quiz waits…" : "Ask an aside about this reply…"
        }
        if let pendingReaderSelection {
            if pendingReaderSelection.reviewHandoff != nil { return "Ask about this exchange…" }
            if pendingReaderSelection.sideQuestionHandoff != nil { return "Go on with the side question…" }
            if pendingReaderSelection.isPictureOnly { return "Ask about this picture…" }
            return "Ask about this passage…"
        }
        // A walk is not a chat: the composer under its card is where a
        // question about that card goes (walkthrough-design.md, "the walk
        // leaves the chat").
        if let playback = manager.walkthroughPlayback {
            let onQuestion = playback.currentStep.flatMap { playback.currentBeat(of: $0) }?.kind == .question
            return onQuestion ? "Answer in your own words, or ask about this card…" : "Ask about this card…"
        }
        if manager.isDeepResearchMode {
            return "Research a question on the web…"
        }
        if manager.currentPromptMode == .shallowRead {
            return "Get the gist of your sources…"
        }
        if manager.currentPromptMode == .deepRead {
            return "Understand your sources in detail…"
        }
        // The Feynman Technique's answers are what the learner knows.
        if manager.isTeachBackSession {
            return "Say what you know…"
        }
        // ChatGPT's page chat says what it is for, in the field.
        if pageSideChat != nil { return "Work with this page…" }
        if let notebook = linkedResearchNotebook {
            return "Ask about \(notebook.title)…"
        }
        let prompt = defaultInitialPrompt
        return prompt.isEmpty ? "Ask anything" : prompt
    }

    var reviewTitle: String {
        if reviewSources.count == 1 {
            return reviewSources[0].title
        }
        if !reviewSources.isEmpty {
            return "Selected sources"
        }
        return ""
    }

    /// Where the composer's text is filed while the learner is somewhere else.
    /// Until a chat has been sent it has no session id, so its draft belongs to
    /// the Notebook the New chat button opened it in.
    var currentDraftScope: ChatDraftScope {
        if let sessionID = manager.currentSessionID {
            return .session(sessionID)
        }
        return .newChat(notebookID: linkedResearchNotebookID)
    }

    /// Puts back whatever was typed into this chat's composer last time. Skipped
    /// while a resume is still pending: the manager is blank for another moment,
    /// so the scope would resolve to the New chat composer rather than the
    /// session about to hydrate, which restores its own draft when it lands.
    @MainActor
    func restoreDraftForCurrentScope() {
        guard manager.currentSessionID != nil || requestedResumeSessionID == nil else { return }
        let kept = sessionStore.draft(for: currentDraftScope)
        guard !kept.isEmpty else { return }
        // A filed draft keeps a quoted passage as the blockquote it would have
        // been sent as, so it comes back to the composer as a quote again and
        // the words below it as words.
        if let quoted = ChatQuoteDraft.split(userMessage: kept) {
            quotedPassage = quoted.quote
            draft = quoted.body
        } else {
            quotedPassage = ""
            draft = kept
        }
        lastInsertedDefaultPrompt = nil
    }

    /// Files the composer for the chat it belongs to: the words, with any
    /// quoted passage ahead of them as the blockquote the message will carry.
    ///
    /// Only what the learner typed is worth keeping. A machine-inserted opener
    /// is regenerated from the chat's own sources, and storing it would freeze
    /// a stale one into the composer on the way back.
    @MainActor
    func fileDraft() {
        let typed = draft == lastInsertedDefaultPrompt ? "" : draft
        // A long paste held as an attachment is filed with the words, so it
        // survives a quit; it comes back in the field.
        let body = composer.pastedTexts.isEmpty ? typed : ChatPastedText.message(typed: typed, pasted: composer.pastedTexts)
        sessionStore.setDraft(
            ChatQuoteDraft.compose(quote: quotedPassage, body: body),
            for: currentDraftScope
        )
    }

    /// ↑ in an empty composer: the last message this chat sent comes back to
    /// edit, its quoted passage as a quote again, as Codex's composer restores
    /// its previous prompt. Its pictures stay with the sent message.
    @MainActor
    func recallPreviousPrompt() {
        guard draft.isEmpty, quotedPassage.isEmpty, composer.pastedTexts.isEmpty,
              let last = manager.chatMessages.last(where: { $0.role == .user && $0.toolActivity == nil }),
              let text = ReviewSessionManager.displayableMessageContent(role: .user, content: last.content)
        else { return }
        if let quoted = ChatQuoteDraft.split(userMessage: text) {
            quotedPassage = quoted.quote
            draft = quoted.body
        } else {
            draft = text
        }
        lastInsertedDefaultPrompt = nil
    }

    /// Empties the composer: the words, the machine-inserted opener it may have
    /// been, and any passage waiting to be quoted.
    @MainActor
    func clearComposer() {
        draft = ""
        // The next words typed start a new question.
        manager.composerTextChanged("")
        quotedPassage = ""
        lastInsertedDefaultPrompt = nil
        coursePlanningArmed = false
        dayPlanningArmed = false
        composer.referencedChats = []
        composer.referencedCards = []
        composer.pastedTexts = []
    }

    private func appendDictation(_ text: String) {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft == lastInsertedDefaultPrompt {
            draft = text
        } else {
            draft += "\n\(text)"
        }
        lastInsertedDefaultPrompt = nil
    }

    @MainActor
    func finishManualDictationIntoDraft() async {
        manualDictationResultDestination = .draft
        guard let text = await finishManualDictationTranscription(),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              manualDictationResultDestination == .draft else {
            if manualDictationResultDestination == .draft {
                manualDictationResultDestination = nil
            }
            return
        }
        appendDictation(text)
        manualDictationResultDestination = nil
    }

    /// The waveform's stop button, and Return while recording. Dictation is
    /// how the learner *says* a message, so the finished transcript goes out
    /// as one — combined with whatever was already typed — rather than landing
    /// in the draft to be sent by a second click. The waveform's X is the way
    /// out of that default: it stops and transcribes into the draft instead,
    /// and while a send is still transcribing the same X reroutes it there
    /// (`finishManualDictationIntoDraft` flips the destination; the send path
    /// sees it changed and stands down). Only while the session is still being
    /// set up does a send fall back to the draft on its own, so the words are
    /// not lost.
    @MainActor
    func finishManualDictationAndSend() async {
        guard canSubmitComposer else {
            await finishManualDictationIntoDraft()
            return
        }
        await submitComposer()
    }

    @MainActor
    /// `asSideQuestion` is ⌥Return: the draft goes as a side question whether or
    /// not the token is in the field. Return sends what the token says.
    func submitComposer(asSideQuestion: Bool = false) async {
        // Think first: while a question waits, what is in the field is the
        // learner's guess at its answer, and Return sends the two together.
        if pendingGuessedQuestion != nil {
            var guessText = draft
            // A guess said rather than typed goes once it is transcribed.
            if isManualDictationPending {
                manualDictationResultDestination = .send
                if let transcript = await finishManualDictationTranscription(),
                   manualDictationResultDestination == .send {
                    guessText = combinedComposerText(draft: guessText, transcript: transcript)
                }
            }
            clearComposer()
            manualDictationResultDestination = nil
            await sendPendingGuessedQuestion(guess: ThinkFirst.take(guessText))
            return
        }
        guard canSubmitComposer else { return }
        // Read before anything below clears the composer.
        let plansCourse = coursePlanningArmed
        let plansDay = dayPlanningArmed

        var answer = draft
        var readerContext: String?
        if isManualDictationPending {
            manualDictationResultDestination = .send
            guard let transcript = await finishManualDictationTranscription(),
                  !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  manualDictationResultDestination == .send else {
                if manualDictationResultDestination == .send {
                    manualDictationResultDestination = nil
                }
                return
            }
            answer = combinedComposerText(draft: answer, transcript: transcript)
        }

        // `/end` stays a command when a passage is waiting to be quoted: the
        // command is what was typed, and the quote is only folded in for a
        // message that is actually going to the tutor.
        let typedTrimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        // A long paste held as an attachment goes after the words typed.
        answer = ChatQuoteDraft.compose(
            quote: quotedPassage,
            body: composer.pastedTexts.isEmpty ? answer : ChatPastedText.message(typed: answer, pasted: composer.pastedTexts)
        )

        // The anchor leaves with the message, not with the click that opened
        // Chat: a passage the learner opened Chat on and then said nothing about
        // is not a conversation, and must not leave a link behind on the doc.
        var docAnchor: ChatDocAnchor?
        let selection = pendingReaderSelection
        if let selection {
            let contextBlock = readerSelectionContextBlock(for: selection)
            if !contextBlock.isEmpty {
                readerContext = contextBlock
            }
            docAnchor = selection.docAnchor
            pendingReaderSelection = nil
        }
        // A page's side chat is always about its page. A chat that quotes no
        // passage links to the page as a whole on its first send, as one that
        // does links to its passage, so the page's Discussion and
        // `list_doc_chats` list it (docs/pages-side-chat-design.md).
        if docAnchor == nil, let card = pageSideChat, manager.currentSessionID == nil {
            docAnchor = card.page.wholePageAnchor
        }

        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        // A picture alone is a message: "what is this?" is implied.
        let hasImages = !manager.pendingImages.isEmpty
        guard !trimmed.isEmpty || hasImages else { return }

        // Intercept `/` slash commands (settings + quick actions) before anything reaches
        // the tutor. Text that starts with `/` but isn't a known command falls through and
        // is sent as a normal message. A message with a picture attached is never a
        // command: the picture is what the learner is sending.
        if !hasImages, let parsed = ReviewSlashCommandParser.parse(typedTrimmed, commands: slashCommands)
            ?? ReviewSlashCommandParser.parseSkillInvocation(typedTrimmed, commands: slashCommands) {
            // The words go; a quoted passage waits for the message it belongs to.
            draft = ""
            lastInsertedDefaultPrompt = nil
            manualDictationResultDestination = nil
            slashSelectionIndex = 0
            await runSlashCommand(parsed.command, argument: parsed.argument)
            return
        }

        // Edit: the message being edited and its reply go first, and this
        // send takes their place. Gone already (another turn came after it),
        // and this is simply the next message.
        if let editing = editingMessage {
            editingMessage = nil
            await manager.takeBackNewestTurn(exchangeID: editing.exchangeID)
        }

        // Chats pointed at with `@` go with this message: their transcripts
        // ride beside it as reference material, and their chips leave the field.
        let referencedChats = composer.referencedChats
        composer.referencedChats = []
        let referencedCards = composer.referencedCards
        composer.referencedCards = []
        clearComposer()
        manualDictationResultDestination = nil
        if let chatContext = await chatMentionContext(for: referencedChats) {
            readerContext = [readerContext, chatContext].compactMap { $0 }.joined(separator: "\n\n")
        }
        // Flashcards pasted by id ride beside the words the same way.
        if let cardContext = ChatReferencedCard.context(referencedCards) {
            readerContext = [readerContext, cardContext].compactMap { $0 }.joined(separator: "\n\n")
        }

        let send = ComposedChatSend(
            text: trimmed,
            typedText: typedTrimmed,
            readerContext: readerContext,
            docAnchor: docAnchor,
            selection: selection,
            plansCourse: plansCourse,
            plansDay: plansDay
        )
        // Think first: a question in a notebook's chat waits for the
        // learner's guess when the notebook's level asks for one.
        if !asSideQuestion, asksForGuess(before: send) {
            pendingGuessedQuestion = send
            requestComposerFocus()
            return
        }
        await dispatchComposerSend(send, asSideQuestion: asSideQuestion, guess: nil)
    }

    /// What a send carries once the composer has given it up: the words,
    /// the passage it quoted and where it came from, and whether it plans a
    /// course. The rest of the send reads it, now or after a guess.
    struct ComposedChatSend {
        let text: String
        /// What was typed, before a quoted passage was folded in.
        let typedText: String
        var readerContext: String?
        let docAnchor: ChatDocAnchor?
        let selection: ReaderSelectionExplanationRequest?
        let plansCourse: Bool
        let plansDay: Bool
    }

    /// Whether Think first asks for a guess before this message: a question,
    /// in a notebook's chat whose level is Also Chat, sent as an ordinary
    /// turn of an ordinary chat — no aside, plugin, course plan, walk, review
    /// or research.
    private func asksForGuess(before send: ComposedChatSend) -> Bool {
        guard let notebookID = linkedResearchNotebook?.id,
              ThinkFirst.asks(.chat, notebookID: notebookID),
              ChatGuess.isQuestion(send.typedText),
              !send.plansCourse,
              !send.plansDay,
              !isSideQuestionMode,
              [.assistant, .shallowRead, .deepRead].contains(manager.currentPromptMode),
              manager.walkthroughPlayback == nil,
              !manager.isMemoryReviewSession,
              ChatPluginRequest.Mention.first(in: send.text, plugins: chatPlugins) == nil else { return false }
        return true
    }

    /// The guess given (Return) or skipped (the token's ×, Escape, or an
    /// empty field): the held question goes now, with the guess beside it
    /// when there is one.
    @MainActor
    func sendPendingGuessedQuestion(guess: String?) async {
        guard let send = pendingGuessedQuestion else { return }
        pendingGuessedQuestion = nil
        ThinkFirstTally.record(.chat, answered: guess != nil)
        await dispatchComposerSend(send, asSideQuestion: false, guess: guess)
    }

    /// The send itself: the plugin a message mentions, a side question's
    /// mark or the learner's guess, a walk's card, the marks above them, and
    /// the message, sent now or queued under a reply still being written.
    @MainActor
    private func dispatchComposerSend(_ send: ComposedChatSend, asSideQuestion: Bool, guess: String?) async {
        let trimmed = send.text
        var readerContext = send.readerContext
        let docAnchor = send.docAnchor
        let selection = send.selection
        let plansCourse = send.plansCourse
        let plansDay = send.plansDay

        // `@slack do xyz`: a message that mentions a connected plugin is a
        // question for that service. The learner's words go as typed, mention
        // included; the plugin rides beside them as a mark the model reads
        // as "answer this from Slack, live" (`ChatPluginRequest`). A mention
        // with nothing else asks the plugin's default question.
        var messageText = trimmed
        let mention = ChatPluginRequest.Mention.first(in: trimmed, plugins: chatPlugins)
        if let mention, ChatPluginRequest.Mention.removing(mention.range, from: trimmed).isEmpty {
            messageText = mention.plugin.defaultRequest(repository: linkedResearchNotebook?.repository)
        }

        // A side question carries its mark beside the message, with the reply
        // it is about and the tutor's open question, if any, so a reopened chat
        // still knows what it was about and what was waiting. Once one has
        // gone, the next message is assumed to be a follow-up about the same
        // reply: the token stays until the learner answers or skips the
        // question, or takes it off. ⌥Return sends one the same way, about the
        // newest reply when none is armed.
        let openQuestion = openTutorQuestion
        if (asSideQuestion || isSideQuestionMode), sideQuestionTarget == nil {
            sideQuestionTarget = newestReplyReference
        }
        // A chat with no reply yet has nothing to ask beside: the message
        // goes as usual.
        let sendsSideQuestion = (asSideQuestion || isSideQuestionMode) && sideQuestionTarget != nil
        isSideQuestionMode = sendsSideQuestion
        if !sendsSideQuestion { sideQuestionTarget = nil }
        // An answer to the newest walkthrough step's question carries the
        // grading brief, so the tutor's reply is the grade (walkthrough-
        // design.md). A side question beside the step is not an answer.
        // Asked on a card the learner went back to: the message belongs to
        // that card, and the tutor reads the card's words above it.
        await manager.bringWalkthroughCardIntoChat()
        if !sendsSideQuestion, let grading = manager.takeWalkthroughAnswerContext() {
            readerContext = [readerContext, grading].compactMap { $0 }.joined(separator: "\n\n")
        }
        // A side question's mark, or Think first's guess, which never goes
        // with an aside (`ChatGuess`).
        let baseContext: String?
        if sendsSideQuestion {
            baseContext = ChatSideQuestion.contextContent(
                openQuestion: openQuestion,
                aboutReply: sideQuestionTarget?.line,
                referenceContext: readerContext
            )
        } else if let guess {
            baseContext = ChatGuess.contextContent(guess: guess, referenceContext: readerContext)
        } else {
            baseContext = readerContext
        }
        // The plugin mark goes first; the request builder reads it off and
        // hands what is under it to the side-question and reference parsing.
        let pluginContext = mention.map {
            ChatPluginRequest.contextContent(for: $0.plugin, referenceContext: baseContext)
        } ?? baseContext
        // Generate's chat: the course-planning instructions go on top, the
        // way a skill's do, so every later turn re-reads them.
        // The day-planning chat carries its rules the same way, so the chat
        // shows one line and the model reads the rest.
        let messageContext = plansCourse
            ? ChatSkillRequest.contextContent(for: CoursePlanningChat.skill, referenceContext: pluginContext)
            : plansDay
                ? ChatSkillRequest.contextContent(for: ReviewSlashCommandParser.planDaySkill, referenceContext: pluginContext)
                : pluginContext
        // The pictures leave with the text, as image lines the bubble draws
        // and the turn sends as image parts; the tray empties here.
        let content = manager.outgoingMessageContent(text: messageText)
        if manager.queuesSendsNow {
            // A reply is still being written: the message waits under it and
            // goes the moment the turn ends, the way a follow-up typed into
            // Claude mid-answer does. Nothing here blocks the learner.
            if let queued = manager.enqueueFollowUp(content, contextualContent: messageContext, docAnchor: docAnchor),
               let selection {
                queuedReaderSelections[queued.id] = selection
            }
            // Only acts when nothing is running to send it after — the last
            // turn failed and this new message is the learner moving on.
            await manager.resumeQueuedFollowUps()
            return
        }
        await sendReviewChatMessage(content, contextualContent: messageContext, docAnchor: docAnchor)
        // The doc that handed over this passage is usually open beside the chat.
        // Tell it a conversation now hangs off that passage, so its Discussion
        // sidebar is right without waiting for the doc to be reopened.
        if docAnchor != nil { vm.artifactChatLinksRevision = UUID() }
    }
}
