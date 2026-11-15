// Attachments, drops, context changes and requested chat lifecycle of the chat panel.
import SwiftUI
import Combine
import UniformTypeIdentifiers
import AppKit

extension InternalReviewPanelContent {
    // MARK: - Attached pictures

    static func isImageFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    /// Reads the PDF's text off the main actor and holds it in the composer
    /// as an attachment of the next message (`ChatPastedText.pdfAttachment`).
    /// It is not added to the library and no paper is made of it. A scan
    /// with no selectable text is said so in the chat's error line.
    @MainActor
    func attachPDFFile(_ url: URL) async {
        let text = await Task.detached(priority: .userInitiated) {
            ChatPastedText.extractPDFText(at: url)
        }.value
        guard let text else {
            manager.errorMessage = "\(url.lastPathComponent) has no text this chat can read. Add it to your library to have it read."
            return
        }
        composer.pastedTexts.append(ChatPastedText.pdfAttachment(name: url.lastPathComponent, text: text))
        // Filed with the draft, as a long paste is, so a quit keeps it.
        fileDraft()
    }

    @MainActor
    func attachImageFile(_ url: URL) async {
        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: url)
        }.value
        guard let data, !data.isEmpty else {
            manager.errorMessage = "Could not read \(url.lastPathComponent)."
            return
        }
        await attachImageData(data, name: url.lastPathComponent)
    }

    /// Prepares the picture off the main actor and puts it in the composer's
    /// tray. A file that is not a picture, or one that cannot be converted,
    /// is reported in the chat's error line rather than silently ignored.
    @MainActor
    func attachImageData(_ data: Data, name: String) async {
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try ChatImagePreparation.prepare(data)
            }.value
            manager.attachImage(ChatImageAttachment(prepared: prepared, name: name))
        } catch {
            manager.errorMessage = "\(name): \(error.localizedDescription)"
        }
    }

    @MainActor
    func attachPastedImages(_ pasted: [ChatPastedImage]) async {
        for item in pasted {
            switch item {
            case .file(let url):
                await attachImageFile(url)
            case .bytes(let data, let name):
                await attachImageData(data, name: name)
            }
        }
    }

    /// A Doc dropped on this chat joins its context, the way the Docs row's
    /// "Add to Chat" item does — but into this pane's conversation directly
    /// rather than through the window's chat request: the drop already named
    /// the chat it meant, so there is nothing to route.
    ///
    /// The stored revision is attached, not an editor's unsaved draft: that is
    /// the text `read_doc` returns, so the two cannot disagree about what
    /// the chat is holding.
    @MainActor
    func addDocToChatContext(_ artifactID: String, announces: Bool = true) async {
        do {
            let snapshot = try await vm.artifactMarkdown(artifactID)
            manager.addContextDoc(ChatDocAttachment(snapshot: snapshot))
            if announces { vm.showToast("Added \(snapshot.artifact.title) to Chat") }
        } catch {
            vm.errorMessage = error.localizedDescription
        }
    }

    /// Cards of the canvas, handed to this chat by Add to Chat or Ask in Chat:
    /// they become chips and lines in what the model is told at once, and the
    /// text of the sources and Docs among them is brought in the way a dropped
    /// one is (`addSourceIDsToChatContext`, `addDocToChatContext`), so the
    /// model reads it, not just their names. A Site or Page the card names is
    /// attached; an animation, audio overview or reading has no text to read.
    @MainActor
    func takeCanvasCards(_ handOff: KnowledgeMapChatCards) async {
        let leftOut = manager.addCanvasCards(
            canvasID: handOff.canvasID,
            name: handOff.canvasName,
            cards: handOff.cards,
            replacing: handOff.replaces
        )
        if leftOut > 0 {
            vm.showToast("A chat holds \(KnowledgeMapChatContext.cardLimit) cards at most: \(leftOut) were left out")
        }
        let held = Set(manager.canvasContext?.cards.map(\.ref) ?? [])
        let joined = handOff.cards.filter { held.contains($0.ref) }
        let sourceIDs = vm.knowledgeMapChatSourceIDs(joined)
        if !sourceIDs.isEmpty {
            await addSourceIDsToChatContext(sourceIDs)
        }
        for card in joined {
            guard let item = KnowledgeMap.ItemRef(card.ref), item.kind == .doc,
                  let artifact = vm.artifacts.first(where: { $0.id == item.id }),
                  ["doc", "site"].contains(KnowledgeMapModel.docType(artifact)) else { continue }
            await addDocToChatContext(item.id, announces: false)
        }
    }

    @MainActor
    func addSourceIDsToChatContext(_ ids: [String]) async {
        adoptLiveNotebookSelection()
        vm.addSourcesToContext(ids, explicit: true)
        let articles = ids.compactMap { id in
            vm.articles.first { $0.id == id }
        }
        await addArticlesToActiveOrIdleChat(articles)
    }

    @MainActor
    func addArticlesToChatContext(_ articles: [StudioArticle]) async {
        adoptLiveNotebookSelection()
        for article in articles {
            vm.addSourceToContext(article.id, explicit: true)
        }
        await addArticlesToActiveOrIdleChat(articles)
    }

    @MainActor
    private func addArticlesToActiveOrIdleChat(_ articles: [StudioArticle]) async {
        // The learner named these sources (a drop, an upload, a pick), so the
        // family switch that keeps sources out of ambient search does not apply.
        guard !articles.isEmpty else { return }
        await addArticlesToFocusNotebookPool(articles)
        let sourceIDs = Set(articles.map(\.id))
        await vm.ensureContextSourceContentLoaded(sourceIDs: sourceIDs)
        let refreshedArticles = articles.map { article in
            vm.articlesById[article.id] ?? article
        }
        await manager.addContextSources(refreshedArticles)
        if manager.sessionActive || !manager.chatMessages.isEmpty {
            await vm.loadReviewSessionLinks()
            await vm.loadLearningGoals()
        }
    }

    /// A source pulled into a Notebook's chat joins that Notebook.
    ///
    /// Bringing a source into a Notebook's chat *is* the act of adding it to
    /// the Notebook. Requiring a second curation step in the Notebooks panel
    /// would let the pool drift out of step with what is actually being
    /// studied — and the pool is what the assistant sees, so that drift costs
    /// real answers. Approved rather than pending for the same reason: the
    /// drop is the approval.
    ///
    /// Deliberately not symmetric. Detaching a source from a chat unloads it
    /// from context and leaves the Notebook untouched; removing it from the
    /// Notebook stays a separate, deliberate act.
    @MainActor
    private func addArticlesToFocusNotebookPool(_ articles: [StudioArticle]) async {
        guard let notebook = linkedResearchNotebook else { return }
        let approved = Set(notebook.approvedSourceIDs)
        let newIDs = articles.map(\.id).filter { !approved.contains($0) }
        guard !newIDs.isEmpty else { return }

        do {
            // Same storage call `add_notebook_sources` uses over MCP, so the
            // pool and the other Mac agree. It
            // already re-approves a previously rejected source, which is the
            // behavior we want: using a source overrides an earlier removal.
            try await vm.storage.addCompanionSeedSources(goalID: notebook.id, sourceIDs: newIDs)
            await vm.loadLearningGoals()
        } catch {
            // Surfaced rather than swallowed. A pool that silently fails to
            // grow leaves the Notebook disagreeing with the chat that filled
            // it, and the source never reaches the other device at all.
            vm.errorMessage = "Could not add the source to \(notebook.title). \(error.localizedDescription)"
        }
    }

    @MainActor
    func removeSourceFromChatContext(_ sourceID: String) {
        adoptLiveNotebookSelection()
        vm.removeSourceFromContext(sourceID)
        if reviewSources.isEmpty {
            isContextSourcesPopoverPresented = false
        }
        guard manager.linkedSourceIDs.contains(sourceID) else { return }
        Task {
            await manager.removeContextSource(sourceID, availableArticles: vm.articles)
            await vm.loadReviewSessionLinks()
            await vm.loadLearningGoals()
        }
    }

    @MainActor
    func closeDeletedActiveSession() {
        if let sessionID = manager.currentSessionID {
            sessionStore.setDraft("", for: .session(sessionID))
        }
        manager.endSession()
        clearComposer()
        pendingReaderSelection = nil
    }

    @MainActor
    func resetRequestedChatIfNeeded() {
        guard let requestID = vm.reviewChatResetRequestID else { return }
        // A Doc's passage asks for its new chat before it arrives, and this
        // runs first. When this chat is already working on that Doc the
        // passage joins it instead: nothing is reset, a running turn keeps
        // running, and the passage waits under the composer beside what the
        // learner has typed.
        if let request = vm.readerSelectionExplanationRequest, docPassageJoinsThisChat(request) {
            vm.pendingReviewChatNotebookID = nil
            vm.pendingReviewChatDraft = nil
            vm.pendingReviewChatCanvasQuestions = []
            vm.pendingReviewChatMode = nil
            vm.pendingReviewChatCard = nil
            vm.reviewChatResetRequestID = nil
            return
        }
        if sessionStore.prepareForNewChat(requestID: requestID) {
            return
        }
        // A chat opened beside the Canvas offers its questions; every other
        // fresh chat offers none.
        canvasSuggestedQuestions = vm.pendingReviewChatCanvasQuestions
        vm.pendingReviewChatCanvasQuestions = []
        manager.endSession()
        // A card asked about from the Memory pane is this chat's card from the
        // first moment, whatever takes that pane's place beside it.
        manager.pinnedCard = vm.pendingReviewChatCard
        vm.pendingReviewChatCard = nil
        // Cards asked for with this chat (Ask in Chat, Add to Chat with no
        // chat beside the canvas) are its context from the first moment.
        if let handOff = vm.pendingChatCanvasCards,
           windowState == nil || windowState?.id == handOff.windowID {
            vm.pendingChatCanvasCards = nil
            Task { await takeCanvasCards(handOff) }
        }
        // A request naming a mode of its own — a notebook Studio's Deep
        // research — opens the fresh chat in it, ready for the question.
        if let mode = vm.pendingReviewChatMode {
            vm.pendingReviewChatMode = nil
            manager.setAssistantMode(mode)
        }
        // The Notebook link is settled before the draft, because it is half of
        // the scope the kept draft is filed under. A request naming none is
        // filed in the notebook the window holds: a library chat asked for
        // from one has left it already.
        if let notebookID = vm.pendingReviewChatNotebookID ?? windowNotebookForNewChat,
           vm.notebook(id: notebookID) != nil {
            linkedResearchNotebookID = notebookID
        } else {
            linkedResearchNotebookID = nil
        }
        // A notebook opening in this window asked for this chat: it reads the
        // notebook's ticks live, with nothing written until the learner acts.
        if vm.pendingNotebookChatRequestID == requestID, linkedResearchNotebookID != nil {
            readsNotebookTicksLive = true
            vm.pendingNotebookChatRequestID = nil
        } else {
            readsNotebookTicksLive = false
        }
        // A seeded draft is machine-inserted, so mark it overwritable the same way
        // `explainCurrentReading` does. With nothing seeded, this New chat gets
        // back whatever was left unsent in it before the learner navigated off.
        draft = vm.pendingReviewChatDraft ?? sessionStore.draft(for: currentDraftScope)
        lastInsertedDefaultPrompt = vm.pendingReviewChatDraft
        dayPlanningArmed = vm.pendingReviewChatDraft != nil
            && vm.pendingReviewChatDraft == vm.pendingPlanDayDraft
        vm.pendingPlanDayDraft = nil
        vm.pendingReviewChatDraft = nil
        pendingReaderSelection = nil
        vm.pendingReviewChatNotebookID = nil
        vm.reviewChatResetRequestID = nil
    }

    @MainActor
    func startRequestedReviewChat() async {
        // The Memory row asked for today's review. The cohort is already
        // assembled; the manager plans it and the tutor opens.
        if let pending = vm.pendingMemoryReview {
            vm.pendingMemoryReview = nil
            guard !manager.isSearching, !manager.isGenerating else { return }
            if manager.sessionActive || !manager.chatMessages.isEmpty {
                manager.endSession()
            }
            clearComposer()
            pendingReaderSelection = nil
            let articles = pending.cohort.sources
                .map(\.sourceID)
                .compactMap { vm.articlesById[$0] }
                .filter { vm.isSourceIncludedInKnowledge($0) }
            await manager.startMemoryReview(pending, articles: articles)
            await vm.loadReviewSessionLinks()
            return
        }

        // Generate in the Courses tab: a new, empty chat with the course's
        // opening sentence typed for the learner to finish. The instructions
        // go with that first message (`CoursePlanningChat`).
        if vm.pendingCoursePlanningChat {
            vm.pendingCoursePlanningChat = false
            // From a notebook's Studio the chat is the notebook's: filed in
            // it, its ticked sources already the chat's context
            // (`startCoursePlanningChat(inNotebook:)`).
            let notebook = vm.pendingCoursePlanningNotebookID.flatMap { vm.notebook(id: $0) }
            vm.pendingCoursePlanningNotebookID = nil
            // A turn under way keeps the chat: the press says so rather
            // than doing nothing where the learner can see.
            guard !manager.isSearching, !manager.isGenerating else {
                vm.showToast("Plan the course once this answer finishes")
                return
            }
            if manager.sessionActive || !manager.chatMessages.isEmpty {
                manager.endSession()
            }
            manager.setAssistantMode(.assistant)
            clearComposer()
            pendingReaderSelection = nil
            manager.clearStagedSources()
            linkedResearchNotebookID = notebook?.id
            readsNotebookTicksLive = false
            draft = notebook.map { CoursePlanningChat.openingDraft(notebookTitle: $0.title) }
                ?? CoursePlanningChat.openingDraft
            coursePlanningArmed = true
            requestComposerFocus()
            return
        }

        // A course quiz row asked to take its quiz: a new chat on the lecture
        // sources, the tutor asking the stored questions.
        if let pending = vm.pendingCourseQuiz {
            vm.pendingCourseQuiz = nil
            guard !manager.isSearching, !manager.isGenerating else { return }
            if manager.sessionActive || !manager.chatMessages.isEmpty {
                manager.endSession()
            }
            clearComposer()
            pendingReaderSelection = nil
            let articles = pending.sourceIDs.compactMap { vm.articlesById[$0] }
            await manager.startCourseQuiz(pending, articles: articles)
            await vm.loadReviewSessionLinks()
            return
        }

        // A Learning Companion goal asked for a goal-linked review: seed it with the
        // goal's own sources/topic and stamp goal_id so completing it advances the goal.
        if let pending = vm.pendingCompanionReview {
            vm.pendingCompanionReview = nil
            let articles = pending.sourceIDs
                .compactMap { vm.articlesById[$0] }
                .filter { vm.isSourceIncludedInKnowledge($0) }
            guard !articles.isEmpty else { return }
            guard !manager.isSearching, !manager.isGenerating else { return }
            if manager.sessionActive || !manager.chatMessages.isEmpty {
                manager.endSession()
            }
            clearComposer()
            pendingReaderSelection = nil
            let notebookScopeID: String?
            if let goalID = pending.goalID, vm.notebook(id: goalID) != nil {
                notebookScopeID = goalID
            } else {
                notebookScopeID = nil
            }
            await manager.startSession(
                topic: pending.topic,
                articles: articles,
                goalID: pending.goalID,
                notebookScopeID: notebookScopeID,
                dailyPlanRationale: pending.rationale,
                memoryPlan: pending.memoryPlan
            )
            await vm.loadReviewSessionLinks()
            return
        }

        adoptLiveNotebookSelection()
        guard !reviewSources.isEmpty else { return }
        guard !manager.isSearching, !manager.isGenerating else { return }
        if manager.sessionActive || !manager.chatMessages.isEmpty {
            manager.endSession()
        }
        clearComposer()
        pendingReaderSelection = nil
        guard await syncSynthesisToolContext() else { return }
        await vm.ensureContextSourceContentLoaded()
        await manager.startSession(
            topic: reviewTitle,
            articles: reviewSources,
            goalID: linkedResearchNotebookID,
            notebookScopeID: linkedResearchNotebookID
        )
        await vm.loadReviewSessionLinks()
    }

    func resumeRequestedSessionIfNeeded() async {
        guard let sessionID = requestedResumeSessionID else { return }
        let isStoreRequest = sessionStore.requestedSessionID == sessionID

        switch sessionStore.prepareToOpen(sessionID: sessionID) {
        case .switched:
            return
        case .alreadyLoaded, .needsResume:
            break
        }
        defer {
            sessionStore.didResume(sessionID: sessionID)
            if isStoreRequest {
                sessionStore.didConsumeOpenRequest(sessionID: sessionID)
            } else if acceptsGlobalNavigationRequests {
                vm.reviewChatResumeSessionID = nil
            }
        }

        if vm.reviewSessionLinks.isEmpty {
            await vm.loadReviewSessionLinks()
        }
        guard let session = vm.reviewSessionLinks.first(where: { $0.id == sessionID }) else {
            if let sourceID = sessionStore.takeWalkthroughAfterOpen(sessionID: sessionID) {
                await startWalkthroughPlayback(sourceID: sourceID)
            }
            return
        }

        if manager.currentSessionID == sessionID {
            showAlreadyLoadedSession(session)
        } else {
            await openSessionFromHistory(session)
        }
        // Walk Through opened the walk's own chat: the walk plays on over it.
        if let sourceID = sessionStore.takeWalkthroughAfterOpen(sessionID: sessionID) {
            await startWalkthroughPlayback(sourceID: sourceID)
        }
    }

    @MainActor
    private func showAlreadyLoadedSession(_ session: ReviewSessionRecord) {
        let sourceIDs = manager.linkedSourceIDs.isEmpty ? session.sourceIDs : manager.linkedSourceIDs
        if acceptsGlobalNavigationRequests {
            readsNotebookTicksLive = false
            vm.setContextSources(sourceIDs)
        }
        if let goalID = session.goalID, vm.notebook(id: goalID) != nil {
            linkedResearchNotebookID = goalID
        } else {
            linkedResearchNotebookID = nil
        }
        draft = sessionStore.draft(for: .session(session.id))
        composer.referencedChats = []
        composer.referencedCards = []
        composer.pastedTexts = []
        editingMessage = nil
        chatFind.close()
        lastInsertedDefaultPrompt = nil
        pendingReaderSelection = nil
    }

    @MainActor
    func openSessionFromHistory(_ session: ReviewSessionRecord) async {
        guard session.isLocalMCPSession else { return }
        let sources = vm.linkedSources(for: session).filter { vm.isSourceIncludedInKnowledge($0) }
        if acceptsGlobalNavigationRequests {
            readsNotebookTicksLive = false
            vm.setContextSources(session.sourceIDs)
        }
        let notebookScopeID: String?
        if let goalID = session.goalID, vm.notebook(id: goalID) != nil {
            notebookScopeID = goalID
        } else {
            notebookScopeID = nil
        }
        linkedResearchNotebookID = notebookScopeID
        // A quiz's chat goes on grading where it stopped, while its quiz
        // is still in the course.
        let courseQuiz = await vm.courseQuizChatRequest(forSessionID: session.id)
        await manager.resumeSession(
            session,
            articles: sources,
            notebookScopeID: notebookScopeID,
            courseQuiz: courseQuiz
        )
        draft = sessionStore.draft(for: .session(session.id))
        composer.referencedChats = []
        composer.referencedCards = []
        composer.pastedTexts = []
        editingMessage = nil
        chatFind.close()
        lastInsertedDefaultPrompt = nil
        pendingReaderSelection = nil
        await vm.loadReviewSessionLinks()
        await vm.loadLearningGoals()
    }

    func errorText(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                // Clamped at the boundary as well as at the source. Errors
                // reach this row from providers, storage, sync, and MCP, and a
                // failure that hands back a payload instead of a sentence must
                // never be able to paste it into the chat.
                Text(AIProviderErrorText.clamped(message))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    clearDisplayedError()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.hoverWash)
                .foregroundStyle(.secondary)
                .help("Dismiss error")
            }

            // Nothing can pay for the answer, and retrying cannot succeed — the
            // account, not the model, refused. Offer AI Usage in its place:
            // the key, the limits, and a way to the plan when there is none.
            if AICreditEntitlement.isBlockedByBudget(message) {
                Button {
                    clearDisplayedError()
                    NotificationCenter.default.post(
                        name: .requestOpenStudioSettings,
                        object: SettingsPane.aiKeys
                    )
                } label: {
                    Label("Open API Keys", systemImage: "key.fill")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            } else if manager.canRetryLastGeneration && dictation.errorMessage == nil {
                Button {
                    Task {
                        await manager.retryLastGeneration()
                        await vm.loadReviewSessionLinks()
                        await vm.loadLearningGoals()
                    }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(manager.isGenerating || manager.isSearching)
            }
        }
        .padding(8)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func clearDisplayedError() {
        manager.errorMessage = nil
        dictation.errorMessage = nil
        speech.errorMessage = nil
    }
}
