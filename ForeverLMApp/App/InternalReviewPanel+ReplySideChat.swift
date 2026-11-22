// Reply side chats, reader selections and synthesis tool calls of the chat panel.
import SwiftUI
import Combine
import UniformTypeIdentifiers
import AppKit
import os

extension InternalReviewPanelContent {
    // MARK: - Words selected in a reply

    /// The bar over a selection in a reply, or the reply's context menu.
    func handleReplySelection(
        _ action: ChatReplySelectionAction,
        passage: String,
        messageID: UUID,
        anchor: ChatSelectionAnchor?
    ) {
        switch action {
        case .quote:
            quoteIntoDraft(passage)
        case .moreDetails:
            requestMoreDetails(aboutPassage: passage, inReplyContaining: messageID)
        case .sideChat:
            openReplySideChat(aboutPassage: passage, inReplyContaining: messageID, anchor: anchor)
        }
    }

    /// The words under "More details" on a selected passage. Fixed, so the
    /// press reads the same in every chat; the passage above them says what
    /// they are about.
    static let moreDetailsAboutPassage = "Tell me more about this."

    /// More details on a passage: the tutor expands those words. The press
    /// goes as a message the learner could have typed — the passage quoted,
    /// the fixed words under it — so the bubble shows which words were meant
    /// and the reply reads back later. While a tutor question is open, or the
    /// composer is armed as a side question, it goes as an aside about the
    /// reply the words came from, so the question stays open and its answer
    /// is protected; otherwise it moves the conversation on like any
    /// follow-up. A press while a turn is running waits under it like any
    /// queued message. The picture tray is left alone: a picture waiting
    /// there belongs to the message the learner is writing.
    func requestMoreDetails(aboutPassage passage: String, inReplyContaining messageID: UUID) {
        let content = ChatQuoteDraft.compose(quote: passage, body: Self.moreDetailsAboutPassage)
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let reply = ReviewChatTranscriptBlock.grouping(manager.chatMessages)
            .first { block in block.answerMessages.contains { $0.id == messageID } }
            .map { ReviewChatReplyReference(blockID: $0.id, line: ReviewChatTranscriptSection.replyLine(of: $0)) }
        let openQuestion = openTutorQuestion
        let asAside = openQuestion != nil || isSideQuestionMode
        let context = asAside
            ? ChatSideQuestion.contextContent(
                openQuestion: openQuestion,
                aboutReply: reply?.line ?? sideQuestionTarget?.line
            )
            : nil
        Task {
            if manager.queuesSendsNow {
                _ = manager.enqueueFollowUp(content, contextualContent: context, docAnchor: nil)
                await manager.resumeQueuedFollowUps()
                return
            }
            await sendReviewChatMessage(content, contextualContent: context)
        }
    }

    /// A side chat opens over the passage: a popover with a field, where the
    /// tutor answers about these words with the reply, the conversation and
    /// the source text this chat has loaded in view (`ChatReplySideChat`).
    /// This chat is left exactly as it is —
    /// nothing is sent here, nothing is saved, no chat is started. The field
    /// takes focus empty: the learner came to ask something, and no model is
    /// spent until they do. It opens on the side of the words with room for
    /// it to grow at this chat's zoom.
    ///
    /// A side chat already open closes first. Only its X closes it otherwise,
    /// so it is often still up when new words are chosen, and one popover
    /// closing while another opens in the same update left none open when the
    /// new words were in another reply; the new one opens on the next turn.
    private func openReplySideChat(
        aboutPassage passage: String,
        inReplyContaining messageID: UUID,
        anchor: ChatSelectionAnchor?
    ) {
        let replacesOpen = replySideChat.map { open in
            closeReplySideChat(open)
            return true
        } ?? false
        let messages = manager.chatMessages
        let replyIndex = messages.firstIndex(where: { $0.id == messageID })
        let replyText = replyIndex.map { index in
            ReviewSessionManager.displayableMessageContent(role: .assistant, content: messages[index].content) ?? ""
        } ?? ""
        // The exchange before the reply the words are in: only what the
        // learner and tutor said, as the transcript shows it.
        let earlier = messages.prefix(replyIndex ?? messages.count)
        let recentTurns = earlier.compactMap { message -> ChatSideQuestionHandoff.Turn? in
            guard message.role == .user || message.role == .assistant,
                  let text = ReviewSessionManager.displayableMessageContent(role: message.role, content: message.content)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return .init(speaker: message.role == .user ? .learner : .tutor, text: text)
        }
        let context = ChatReplySideChatContext(
            passage: passage,
            replyText: replyText,
            chatTitle: manager.topic,
            recentTurns: recentTurns,
            openQuestion: openTutorQuestion,
            sourceText: manager.loadedSourceText
        )
        let model = ChatReplySideChatModel(
            messageID: messageID,
            anchor: anchor?.rect,
            placement: ChatReplySideChatPlacement.choose(
                room: anchor?.screenRoom,
                fullHeight: ReviewChatSideChatPopover.fullHeight(zoom: uiZoomScale)
            ),
            context: context,
            backend: LiveChatReplySideChatBackend(aiService: AIService())
        )
        if replacesOpen {
            DispatchQueue.main.async { replySideChat = model }
        } else {
            replySideChat = model
        }
    }

    /// A side chat about the whole chat, no words selected (`/side`, the newest
    /// reply's ⋯; Codex's side chat). It hangs off the newest reply, reads the
    /// conversation and the chat's sources, and leaves the chat as it is.
    func openThreadSideChat() {
        let messages = manager.chatMessages
        guard let reply = messages.last(where: { message in
            message.role == .assistant && message.toolActivity == nil
                && ReviewSessionManager.displayableMessageContent(role: .assistant, content: message.content)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }) else {
            vm.showToast("Send a message first: a side chat asks about the conversation.")
            return
        }
        let replacesOpen = replySideChat.map { open in
            closeReplySideChat(open)
            return true
        } ?? false
        let turns = messages.compactMap { message -> ChatSideQuestionHandoff.Turn? in
            guard message.role == .user || message.role == .assistant, message.toolActivity == nil,
                  let text = ReviewSessionManager.displayableMessageContent(role: message.role, content: message.content)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return .init(speaker: message.role == .user ? .learner : .tutor, text: text)
        }
        let model = ChatReplySideChatModel(
            messageID: reply.id,
            anchor: nil,
            context: ChatReplySideChatContext(
                threadTitle: manager.topic,
                turns: turns,
                openQuestion: openTutorQuestion,
                sourceText: manager.loadedSourceText
            ),
            backend: LiveChatReplySideChatBackend(aiService: AIService())
        )
        if replacesOpen {
            DispatchQueue.main.async { replySideChat = model }
        } else {
            replySideChat = model
        }
    }

    /// The popover closed, by the learner or by another taking its place. An
    /// answer still being written stops; the exchange is gone with the view.
    func closeReplySideChat(_ model: ChatReplySideChatModel) {
        guard replySideChat === model else { return }
        model.cancel()
        replySideChat = nil
    }

    /// The side chat leaves for a new chat beside this one, with this chat's
    /// sources, so the question can be gone into from the same material. An
    /// exchange travels as a side question does, its first line carrying the
    /// passage as a quote; a side chat with nothing said yet hands the passage
    /// over the way a Reader selection arrives. This chat is left exactly as
    /// it is. A pane with no neighbour to hand to — the comparison pane, the
    /// pop-out window — sends it to the primary Chat instead.
    func continueReplySideChatInNewChat(_ model: ChatReplySideChatModel) {
        // A side chat about the whole chat with nothing said in it yet: the
        // new chat is this one, branched.
        if model.context.origin == .thread, !model.hasExchange {
            closeReplySideChat(model)
            forkConversation(through: manager.chatMessages)
            return
        }
        let topic = manager.topic.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceIDs = manager.linkedSourceIDs.isEmpty ? reviewSources.map(\.id) : manager.linkedSourceIDs
        let request: ReaderSelectionExplanationRequest
        if let handoff = model.handoff(
            chatTitle: topic,
            openQuestion: model.context.openQuestion,
            sourceIDs: sourceIDs,
            notebookID: linkedResearchNotebookID
        ) {
            request = ReaderSelectionExplanationRequest(sideQuestionHandoff: handoff)
        } else {
            request = ReaderSelectionExplanationRequest(
                sourceIDs: sourceIDs,
                selectedText: model.context.passage,
                contextTitle: topic.isEmpty
                    ? "A reply in another chat"
                    : "A reply in the chat \u{201C}\(topic)\u{201D}"
            )
        }
        closeReplySideChat(model)
        if let onOpenNewChatBeside {
            onOpenNewChatBeside(request)
        } else if request.sideQuestionHandoff != nil {
            vm.requestChatAboutSideQuestion(request)
        } else {
            vm.requestChatAboutPassage(request)
        }
    }

    /// Follows a Page's highlight into the composer's quote when that Page
    /// is open beside this chat or attached to it (`PageSelectionQuote`).
    func mirrorPageSelection(_ selection: LivePageSelection?) {
        let highlight: String? = selection.flatMap { selection in
            let besideChat = openItemsBesideChat.contains { $0.id == selection.artifactID }
            let attached = manager.contextDocs.contains { $0.id == selection.artifactID }
            return besideChat || attached ? selection.text : nil
        }
        let next = PageSelectionQuote.next(
            PageSelectionQuote.State(quote: quotedPassage, mirrored: mirroredPageQuote),
            highlight: highlight
        )
        mirroredPageQuote = next.mirrored
        guard next.quote != quotedPassage else { return }
        quotedPassage = next.quote
        if !next.quote.isEmpty, draft == lastInsertedDefaultPrompt {
            draft = ""
            lastInsertedDefaultPrompt = nil
        }
    }

    private func quoteIntoDraft(_ passage: String) {
        let trimmed = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        composer.quotedAnnotations.append(trimmed)
        // A machine-inserted opener gives way to the quote; words the learner
        // typed stay, with the caret still after them.
        if draft == lastInsertedDefaultPrompt { draft = "" }
        lastInsertedDefaultPrompt = nil
        fileDraft()
        requestComposerFocus()
    }

    @MainActor
    func handleReaderSelectionExplanationRequest() async {
        guard let request = vm.readerSelectionExplanationRequest else { return }
        defer { vm.readerSelectionExplanationRequest = nil }

        let contextBlock = readerSelectionContextBlock(for: request)
        guard !contextBlock.isEmpty else { return }

        // A chat still waiting to open here — the window's last chat after a
        // relaunch, a mark's linked chat — is a conversation too: joining the
        // idle composer in front of it left the passage under that chat once
        // it landed. The passage is the later intent, so it goes to a new
        // chat and the open gives way.
        let opensNewChat = sessionStore.readerSelectionOpensNewChat(for: request) || requestedResumeSessionID != nil
        if opensNewChat, request.isReaderSelection || request.sendsAtOnce,
           acceptsGlobalNavigationRequests, vm.reviewChatResumeSessionID != nil {
            vm.reviewChatResumeSessionID = nil
        }

        // What's New and Find directions are research the learner asked for,
        // sent at once: in this pane when it holds nothing yet, otherwise in a
        // fresh chat, so a conversation under way is never turned into the
        // research.
        if request.sendsAtOnce {
            if opensNewChat {
                readsNotebookTicksLive = false
                vm.setContextSources(request.sourceIDs)
                sessionStore.requestNewChat(handingOff: request)
            } else {
                // Its own task: the turn runs for minutes, and this request's
                // handler should not stay open, or hold the request, that long.
                Task { await startResearchUpdate(request) }
            }
            return
        }

        // A passage from the Reader is a new conversation, not a turn of the
        // one on screen — even when that one is about the same paper. The
        // chat that was open stays exactly as it is (a running turn keeps
        // running, parked), and the passage waits under a fresh chat's composer with its source
        // attached, the way a handed-off exchange does. The idle pool is set
        // rather than added to, as every new-chat route does, so the fresh
        // chat starts from this source and not from what an earlier question
        // left staged.
        if request.isReaderSelection, opensNewChat {
            readsNotebookTicksLive = false
            vm.setContextSources(request.sourceIDs)
            sessionStore.requestNewChat(handingOff: request)
            return
        }

        pendingReaderSelection = request
        // The selection's pictures, fetched by the reader, join the tray the
        // way a dropped picture does; the message carries them as image lines.
        for attachment in request.imageAttachments { manager.attachImage(attachment) }

        // A doc hands over a complete grounding: the sources the highlighted
        // passage cites, and only those. Whatever an idle pane was still
        // holding would otherwise be read as part of the answer to a question
        // it has nothing to do with. A conversation already under way keeps
        // everything it has — `clearStagedSources` refuses there.
        if request.artifactID != nil { manager.clearStagedSources() }
        // The doc rides along by identity, so `read_doc` is offered for the
        // rest of it — the excerpt in the message is one section, not the doc.
        if let doc = request.artifactAttachment { manager.addContextDoc(doc) }

        let articles = request.sourceIDs.compactMap { vm.articlesById[$0] }
        if !articles.isEmpty { await addArticlesToChatContext(articles) }
    }

    /// The chip's one line for the passage. TeX in a selection is folded into
    /// readable text here only; the request itself keeps the markup, so the
    /// model reads exactly what the learner selected.
    func readerSelectionPreview(for request: ReaderSelectionExplanationRequest) -> String {
        let selectedText = request.selectedText
            .foldingTeXForPreview()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedText.isEmpty, request.isPictureOnly {
            return request.imageAttachments.count == 1 ? "Selected picture" : "Selected pictures"
        }
        guard !selectedText.isEmpty else { return "Selected passage" }
        if selectedText.count <= 120 {
            return selectedText
        }
        return String(selectedText.prefix(117)) + "…"
    }

    func readerSelectionContextBlock(for request: ReaderSelectionExplanationRequest) -> String {
        let rawSourceTitle = request.sourceIDs.first.flatMap { vm.articlesById[$0]?.title }
        return request.contextualContent(fallbackTitle: rawSourceTitle)
    }

    /// What's New on a mark (chat-design.md, "What's New"): this chat becomes
    /// a Deep Research chat about the mark's source, the passage and the
    /// research steps go out at once in the learner's name, and the chat links
    /// itself to the mark when that first message is saved.
    ///
    /// It starts the same way from an idle pane as from a fresh one: about the
    /// mark's source alone, and filed under no Notebook, since research into a
    /// passage is not the conversation an idle Notebook composer was waiting for.
    @MainActor
    func startResearchUpdate(_ request: ReaderSelectionExplanationRequest) async {
        if let search = request.directionSearch {
            await startDirectionSearch(search, request: request)
            return
        }
        guard let research = request.researchUpdate else { return }
        pendingReaderSelection = nil
        linkedResearchNotebookID = windowNotebookForNewChat
        readsNotebookTicksLive = false
        vm.setContextSources(request.sourceIDs)
        manager.clearStagedSources()
        let articles = request.sourceIDs.compactMap { vm.articlesById[$0] }
        if !articles.isEmpty { await addArticlesToChatContext(articles) }
        manager.setAssistantMode(.deepResearch)
        // Refused while a turn runs, which a pane holding nothing never has.
        guard manager.isDeepResearchMode else { return }
        manager.pendingSourceHighlightLink = research.highlightID
        await sendReviewChatMessage(
            ReaderSelectionExplanationRequest.researchUpdateMessage,
            contextualContent: readerSelectionContextBlock(for: request)
        )
    }

    /// Find directions on a Goal, Notebook or Idea (docs/directions-design.md):
    /// this chat becomes a Deep Research chat with the home's sources in
    /// context, filed beside the home's Notebook when it has one, and the
    /// request goes out at once in the learner's name. The steps arrive as
    /// the chat's first tool call, `find_directions`.
    @MainActor
    private func startDirectionSearch(_ search: DirectionSearchLaunch, request: ReaderSelectionExplanationRequest) async {
        pendingReaderSelection = nil
        linkedResearchNotebookID = search.notebookID.flatMap { vm.notebook(id: $0) != nil ? $0 : nil }
            ?? windowNotebookForNewChat
        readsNotebookTicksLive = false
        vm.setContextSources(request.sourceIDs)
        manager.clearStagedSources()
        let articles = request.sourceIDs.compactMap { vm.articlesById[$0] }
        if !articles.isEmpty { await addArticlesToChatContext(articles) }
        manager.setAssistantMode(.deepResearch)
        // Refused while a turn runs, which a pane holding nothing never has.
        guard manager.isDeepResearchMode else { return }
        await sendReviewChatMessage(
            search.message,
            contextualContent: request.contextualContent()
        )
    }

    func speakAssistantMessage(_ message: ReviewSessionManager.Message) {
        guard message.role == .assistant,
              let content = ReviewSessionManager.displayableMessageContent(role: message.role, content: message.content)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else { return }
        speech.speak(content, messageID: message.id)
    }

    @MainActor
    func deleteChatMessage(_ message: ReviewSessionManager.Message) {
        if speech.currentMessageID == message.id {
            speech.stop()
        }
        Task {
            await manager.deleteMessage(message)
            await vm.loadReviewSessionLinks()
            await vm.loadLearningGoals()
        }
    }

    @MainActor
    @discardableResult
    func syncSynthesisToolContext() async -> Bool {
        guard let notebook = synthesisNotebook else {
            manager.synthesisToolContext = nil
            return true
        }

        let notebookMaterialsMarkdown: String
        do {
            notebookMaterialsMarkdown = try await vm.storage.notebookMaterialContext(notebookID: notebook.id)
        } catch {
            manager.errorMessage = "Could not load the notebook's files. \(error.localizedDescription)"
            return false
        }

        manager.synthesisToolContext = ReviewSessionManager.SynthesisToolContext(
            title: notebook.title,
            markdown: notebook.notes ?? "",
            instructions: notebook.description,
            researchQuestions: notebook.researchQuestions ?? [],
            repository: notebook.linkedRepository,
            notebookMaterialsMarkdown: notebookMaterialsMarkdown
        )
        return true
    }

    func executeSynthesisToolCall(_ call: ReviewSessionManager.SynthesisToolCall) async {
        guard let notebook = synthesisNotebook else {
            manager.completeSynthesisToolCall(call.id, message: "I do not have a notebook to update yet. Create or link a notebook first.")
            return
        }
        let sourceIDs = manager.linkedSourceIDs.isEmpty ? reviewSources.map(\.id) : manager.linkedSourceIDs
        let updated: LearningGoalRecord?
        switch call.action {
        case .append:
            let currentNotes = notebook.notes ?? ""
            guard !Self.markdownAlreadyContains(call.markdown, in: currentNotes) else {
                manager.completeSynthesisToolCall(call.id, message: "That note is already in \(notebook.title).")
                return
            }
            guard let mergedNotes = await vm.generateNotebookNotesMerge(
                currentNotesMarkdown: currentNotes,
                newInsightMarkdown: call.markdown,
                notebookTitle: notebook.title
            ) else {
                manager.completeSynthesisToolCall(call.id, message: "I tried to update the synthesis, but the app could not merge the note.")
                return
            }
            guard !Self.markdownEquivalent(mergedNotes, currentNotes) else {
                manager.completeSynthesisToolCall(call.id, message: "That note is already in \(notebook.title).")
                return
            }
            updated = await vm.replaceNotebookSynthesisFromChat(
                notebookID: notebook.id,
                markdown: mergedNotes,
                sourceIDs: sourceIDs
            )
        case .replace:
            updated = await vm.replaceNotebookSynthesisFromChat(
                notebookID: notebook.id,
                markdown: call.markdown,
                sourceIDs: sourceIDs
            )
        }

        if let updated {
            linkedResearchNotebookID = updated.id
            await syncSynthesisToolContext()
            let message = call.action == .append
                ? "Merged the note into \(updated.title)."
                : "Updated \(updated.title)."
            manager.completeSynthesisToolCall(call.id, message: message)
        } else {
            manager.completeSynthesisToolCall(call.id, message: "I tried to update the synthesis, but the app could not save it.")
        }
    }

    private static func markdownAlreadyContains(_ addition: String, in notes: String) -> Bool {
        let normalizedAddition = normalizedMarkdownForDuplicateCheck(addition)
        let normalizedNotes = normalizedMarkdownForDuplicateCheck(notes)
        guard !normalizedAddition.isEmpty else { return true }
        if normalizedNotes.contains(normalizedAddition) { return true }

        let additionWithoutHeading = normalizedMarkdownForDuplicateCheck(
            addition
                .split(whereSeparator: \.isNewline)
                .drop(while: { String($0).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") })
                .joined(separator: "\n")
        )
        return !additionWithoutHeading.isEmpty && normalizedNotes.contains(additionWithoutHeading)
    }

    private static func markdownEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        normalizedMarkdownForDuplicateCheck(lhs) == normalizedMarkdownForDuplicateCheck(rhs)
    }

    private static func normalizedMarkdownForDuplicateCheck(_ markdown: String) -> String {
        markdown
            .lowercased()
            .replacingOccurrences(of: #"(?m)^#+\s*chat insight\s*-\s*.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^#+\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    func startReview(with articles: [StudioArticle], topic: String) async {
        let articles = articles.filter { vm.isSourceIncludedInKnowledge($0) }
        guard !articles.isEmpty else {
            speech.speak("I could not find readable sources for that review.")
            return
        }
        if manager.sessionActive || !manager.chatMessages.isEmpty {
            manager.endSession()
        }
        readsNotebookTicksLive = false
        vm.setContextSources(articles.map(\.id))
        clearComposer()
        speech.stop()
        await vm.ensureContextSourceContentLoaded()
        await manager.startSession(topic: topic, articles: articles)
        await vm.loadReviewSessionLinks()
        await vm.loadLearningGoals()
    }

    func articles(for items: [SchedulePlanItem]) -> [StudioArticle] {
        items.compactMap { item in
            vm.articles.first { $0.id == item.sourceID }
        }
    }

    @MainActor
    func refreshDefaultDraft() {
        guard !manager.sessionActive, manager.chatMessages.isEmpty else {
            if draft == lastInsertedDefaultPrompt {
                draft = ""
            }
            lastInsertedDefaultPrompt = nil
            return
        }

        let prompt = defaultInitialPrompt
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft == lastInsertedDefaultPrompt {
            draft = prompt
            lastInsertedDefaultPrompt = prompt
        }
    }

    func contextNoun(for type: StudioSourceType) -> (singular: String, plural: String) {
        switch type {
        case .article, .unclassified: return ("article", "articles")
        case .paper: return ("paper", "papers")
        case .podcast: return ("podcast", "podcasts")
        case .book: return ("book", "books")
        case .course: return ("course", "courses")
        case .meeting: return ("meeting", "meetings")
        case .video: return ("video", "videos")
        case .xPost: return ("post", "posts")
        case .manual: return ("source", "sources")
        }
    }

    func setDropTargeted(_ targeted: Bool) {
        dropTargetResetTask?.cancel()
        if targeted {
            isDropTargeted = true
            return
        }

        dropTargetResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            isDropTargeted = false
        }
    }

    /// Puts a dropped Board card's words in the composer, after what is already
    /// typed, and marks the chat to link to the card on the next send.
    @MainActor
    func addBoardCardToChat(_ taskID: String) {
        guard let task = vm.loadedNotebookTask(taskID) else { return }
        let words = StudioViewModel.boardCardChatDraft(task)
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = typed.isEmpty ? words : typed + "\n\n" + words
        manager.pendingNotebookTaskLink = task.id
        vm.reviewChatFocusRequestID = UUID()
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        StudioDragVisibility.shared.endSoon()
        chatDropLogger.notice("drop: \(providers.count) item(s): \(providers.map { $0.registeredTypeIdentifiers.joined(separator: ",") }.joined(separator: " | "), privacy: .public)")
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.studioArtifact.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.studioArtifact.identifier) { data, _ in
                    guard let data,
                          let transfer = try? JSONDecoder().decode(StudioArtifactTransfer.self, from: data) else { return }
                    Task { @MainActor in
                        await addDocToChatContext(transfer.artifactID)
                    }
                }
                continue
            }

            // A Board card dropped in: its words wait under the composer, and the
            // chat links itself to the card when the message is sent.
            if provider.hasItemConformingToTypeIdentifier(UTType.boardCard.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.boardCard.identifier) { data, _ in
                    guard let data,
                          let taskID = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !taskID.isEmpty else { return }
                    Task { @MainActor in addBoardCardToChat(taskID) }
                }
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.studioGroup.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.studioGroup.identifier) { data, _ in
                    guard let data,
                          let transfer = try? JSONDecoder().decode(StudioGroupTransfer.self, from: data) else { return }
                    Task { @MainActor in
                        let articles = vm.sourceIDsForGroupInOrder(transfer.groupName).compactMap { id in
                            vm.articles.first { $0.id == id }
                        }
                        await addArticlesToChatContext(articles)
                    }
                }
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.studioArticle.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.studioArticle.identifier) { data, error in
                    guard let data,
                          let transfer = try? JSONDecoder().decode(StudioArticleTransfer.self, from: data) else {
                        chatDropLogger.notice("drop: the source payload did not read (\(data?.count ?? -1) bytes, \(error?.localizedDescription ?? "no error", privacy: .public))")
                        return
                    }
                    Task { @MainActor in
                        // The payload is the snapshot of what the learner picked
                        // up; the live selection may have moved on by the drop.
                        await addSourceIDsToChatContext(transfer.draggedSourceIDs)
                    }
                }
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.studioSourceID.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.studioSourceID.identifier) { data, _ in
                    guard let data,
                          let sourceID = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !sourceID.isEmpty else { return }
                    Task { @MainActor in
                        await addSourceIDsToChatContext([sourceID])
                    }
                }
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data = data as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        // A picture is for the message, not the library: there
                        // is no image source type, and what the learner means
                        // by dropping a screenshot is "look at this". A PDF
                        // is the same (`addDroppedFile`).
                        await addDroppedFile(url)
                    }
                }
                continue
            }

            // Picture bytes without a file: an image dragged out of a browser or
            // another app, or one the catcher read off the pasteboard.
            if let imageType = provider.registeredTypeIdentifiers
                .compactMap({ UTType($0) })
                .first(where: { $0.conforms(to: .image) }) {
                handled = true
                let name = provider.suggestedName ?? "Dropped image.\(imageType.preferredFilenameExtension ?? "png")"
                provider.loadDataRepresentation(forTypeIdentifier: imageType.identifier) { data, _ in
                    guard let data, !data.isEmpty else { return }
                    Task { @MainActor in
                        await attachImageData(data, name: name)
                    }
                }
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                    let text: String?
                    if let string = item as? String {
                        text = string
                    } else if let data = item as? Data {
                        text = String(data: data, encoding: .utf8)
                    } else {
                        text = nil
                    }
                    guard let text else { return }
                    Task { @MainActor in
                        let previousIDs = Set(vm.contextSourceIds)
                        await vm.importDroppedText(text)
                        let newArticles = vm.contextSourceArticles.filter { !previousIDs.contains($0.id) }
                        await addArticlesToChatContext(newArticles)
                    }
                }
            }
        }
        return handled
    }
}
