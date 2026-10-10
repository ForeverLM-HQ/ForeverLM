import Foundation

/// A new notebook needs no name (docs/notebooks-design.md, "A notebook names
/// itself"): every "New notebook" on the Mac makes it at once through
/// `createNotebook`, under a placeholder, and ForeverLM names it, title and
/// card description, once it holds a source or a chat exchange.
extension StudioViewModel {

    /// The one way a learner makes a notebook on the Mac: the Space's New ▸
    /// Notebook, New Notebook with This Source and with N Sources, Open in
    /// New Notebook. Made at once, unnamed, holding `sourceIDs` and in
    /// `collectionID`; the caller opens it. Its first source starts the
    /// naming.
    @discardableResult
    func createNotebook(sourceIDs: [String] = [], collectionID: String? = nil) async -> LearningGoalRecord? {
        guard let created = await createUnnamedNotebook() else { return nil }
        if !sourceIDs.isEmpty {
            // "Created notebook" is the toast; the sources arriving is part of it.
            await addSourcesToNotebookContext(sourceIDs, notebookID: created.id, announce: false)
        }
        if let collectionID {
            setNotebook(created.id, inCollection: collectionID, isMember: true)
        }
        return notebook(id: created.id) ?? created
    }

    /// **New ▸ Notebook** in the Space, and in the Space sidebar's ⋯: an empty
    /// notebook made at once, with no form, and opened in `destinationWindowState`
    /// (the window in scope when nil) as a click on it opens it.
    func makeAndOpenNotebook(in destinationWindowState: StudioWindowState?) {
        let window = destinationWindowState ?? activeWindowState
        Task {
            guard let created = await createNotebook() else { return }
            inWindow(window) { openNotebookInReader(created.id) }
        }
    }

    /// An empty notebook under the placeholder ("New notebook", numbered while
    /// that is taken), with the row that lets ForeverLM name it.
    func createUnnamedNotebook() async -> LearningGoalRecord? {
        let placeholder = NotebookNaming.placeholder(
            existingTitles: learningGoals.filter(\.isNotebook).map(\.title)
        )
        guard let created = await createNotebookContext(title: placeholder) else { return nil }
        setNotebookNamingMark(.unnamed(title: created.title), notebookID: created.id)
        // Its AI-drawn cover (schema v2 D53) is queued now and drawn once it is sent and named. The
        // import and split paths never come through here.
        await NotebookCoverService.notebookMadeOneAtATime(created.id, storage: storage)
        return created
    }

    /// The learner typed a name or description for the notebook: ForeverLM
    /// never renames it from now on. Every learner edit of either calls this
    /// (`renameNotebook`, `setNotebookSummary`, MCP update_notebook).
    func notebookNamedByLearner(_ notebookID: String) {
        setNotebookNamingMark(nil, notebookID: notebookID)
        notebookNamingErrors[notebookID] = nil
        // A cover waits for the name it is drawn from.
        NotebookCoverService.current?.wake()
    }

    func setNotebookNamingMark(_ mark: NotebookNaming.Mark?, notebookID: String) {
        NotebookNamingRows.setMark(mark, notebookID: notebookID)
        if notebookNamingMarks[notebookID] != mark {
            notebookNamingMarks[notebookID] = mark
        }
    }

    /// Names every notebook that is ready (`NotebookNaming.decision`). Run
    /// after the notebooks reload, which every change to what a notebook holds
    /// ends in: a source added here, by MCP or on the phone, a chat answered.
    func nameReadyNotebooks() {
        for notebookID in notebookNamingMarks.keys.sorted() where !notebookNamingIDs.contains(notebookID) {
            guard notebookNamingDecision(notebookID) != .keep else { continue }
            Task { await nameNotebookIfReady(notebookID) }
        }
    }

    /// Whether ForeverLM names the notebook now, from what this Mac has loaded.
    func notebookNamingDecision(_ notebookID: String) -> NotebookNaming.Decision {
        guard let notebook = notebook(id: notebookID) else { return .keep }
        return NotebookNaming.decision(
            mark: notebookNamingMarks[notebookID],
            title: notebook.title,
            summary: notebook.summary,
            sources: notebook.approvedSourceIDs.count,
            exchanges: notebookNamingExchangeCount(notebookID)
        )
    }

    private func notebookNamingExchangeCount(_ notebookID: String) -> Int {
        notebookChats(notebookID: notebookID).reduce(0) { $0 + $1.exchangeCount }
    }

    /// Names the notebook when it is ready, and returns what it did. Without
    /// an AI model the placeholder stays and the notebook's header says why
    /// (`notebookNamingErrors`); at the learner's daily background cap it
    /// waits for the next change. A name or description the learner typed
    /// while the model answered wins: nothing is written over it.
    @discardableResult
    func nameNotebookIfReady(_ notebookID: String) async -> NotebookNaming.Decision {
        let decision = notebookNamingDecision(notebookID)
        guard decision != .keep, let namedNotebook = notebook(id: notebookID),
              notebookNamingIDs.insert(notebookID).inserted else { return .keep }
        defer { notebookNamingIDs.remove(notebookID) }

        let namer: NotebookNamingService.Namer
        if let notebookNamerOverride {
            namer = notebookNamerOverride
        } else {
            do {
                namer = try NotebookNamingService.liveNamer(aiService: aiService)
            } catch {
                notebookNamingErrors[notebookID] = error.localizedDescription
                return .keep
            }
            guard await backgroundAIBudget.check().allowsBackgroundSpend else {
                logger.info("Notebook naming waits for tomorrow: the daily background AI limit is reached")
                return .keep
            }
        }

        let sourceCount = namedNotebook.approvedSourceIDs.count
        let exchangeCount = notebookNamingExchangeCount(notebookID)
        let sources = namedNotebook.approvedSourceIDs.compactMap { id -> (id: String, title: String, kind: String)? in
            guard let article = articlesById[id] ?? articlesById[canonicalSourceID(id)] else { return nil }
            return (id: article.id, title: article.title, kind: article.sourceType.rawValue)
        }
        let chats = notebookChats(notebookID: notebookID)
            .sorted { $0.createdAt < $1.createdAt }
            .filter { $0.exchangeCount > 0 }
            .map { NotebookNamingService.Chat(id: $0.id, title: $0.title) }

        let answer: NotebookNaming.Answer
        do {
            answer = try await NotebookNamingService(storage: storage, name: namer).answer(
                notebookID: notebookID,
                currentTitle: namedNotebook.title,
                instructions: namedNotebook.description,
                sources: sources,
                chats: chats
            )
        } catch {
            notebookNamingErrors[notebookID] = "ForeverLM couldn't name this notebook: \(error.localizedDescription)"
            logger.error("Notebook naming failed for \(notebookID, privacy: .public): \(error.localizedDescription)")
            return .keep
        }

        guard let current = notebook(id: notebookID), let latest = notebookNamingMarks[notebookID],
              NotebookNaming.carries(latest, title: current.title, summary: current.summary) else {
            logger.info("Kept the learner's notebook name over ForeverLM's for \(notebookID, privacy: .public)")
            return .keep
        }
        let summary = NotebookSummary.normalized(answer.summary)
        do {
            try await storage.setLearningGoalTitle(goalID: notebookID, title: answer.title)
            try await storage.setLearningGoalSummary(goalID: notebookID, summary: summary)
        } catch {
            notebookNamingErrors[notebookID] = "ForeverLM couldn't name this notebook: \(error.localizedDescription)"
            logger.error("Saving a notebook's name failed: \(error.localizedDescription)")
            return .keep
        }
        // Named once: it may be named once more. Named twice: never again.
        setNotebookNamingMark(
            decision == .name
                ? NotebookNaming.Mark(title: answer.title, summary: summary, sources: sourceCount, exchanges: exchangeCount)
                : nil,
            notebookID: notebookID
        )
        notebookNamingErrors[notebookID] = nil
        await loadLearningGoals()
        NotebookCoverService.current?.wake()
        return decision
    }
}
