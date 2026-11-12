import Foundation
import OSLog

/// The two queries behind a Notebook's no-query "Suggested to add" list — one per
/// search branch, because the branches want different text.
struct NotebookRecommendationSeed {
    /// Every signal the Notebook carries, for the semantic branch. Blurring the
    /// Notebook's subject together with what it already holds is exactly what a
    /// "more like this" vector should do.
    let embeddingText: String

    /// What the Notebook says it is *about* — title, topic, research questions,
    /// instructions, child goals, open questions — for the lexical branch.
    ///
    /// Deliberately narrower than `embeddingText`. The lexical branch turns words
    /// into exact constraints and ranks by how many a source satisfies, so feeding
    /// it the titles of the sources the Notebook already holds lets their incidental
    /// vocabulary take every constraint slot: on the GDF15 Notebook the twelve
    /// constraints came out as `psychobiological`, `cf`, `mtdna`, `saliva`,
    /// `proxy`, `epigenetic` … and a paper titled "Mapping the GDF15 arm of the
    /// integrated stress response" — matching the Notebook's own subject exactly —
    /// fell to rank 82 of 165. Anchored on the Notebook's identity instead, that
    /// paper leads the list.
    let lexicalQuery: String
}

/// Builds the queries behind a Notebook's no-query "Suggested to add" list.
/// `NLContextualEmbedding` silently drops text after 256 tokens, so every signal
/// gets its own small word budget instead of letting a long instructions field or the
/// first few source titles crowd the rest of the Notebook out.
///
/// Rejected and pending sources are intentionally absent: only approved sources define
/// what the Notebook has accepted as context. The caller still excludes *all* attached
/// source IDs from the candidate results so none can be re-proposed.
func notebookSourceRecommendationSeed(
    goal: LearningGoalRecord,
    childGoals: [LearningGoalRecord],
    articlesById: [String: StudioArticle]
) -> NotebookRecommendationSeed {
    func words(_ values: [String], limit: Int) -> String? {
        let normalized = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
            .split(whereSeparator: { $0.isWhitespace })
        guard !normalized.isEmpty else { return nil }
        return normalized.prefix(limit).joined(separator: " ")
    }

    // Eight titles sampled across the ordered pool represent the existing context more
    // faithfully than the first eight (often consecutive chapters of the same book).
    let approved = goal.approvedSourceIDs
    let sourceSampleSize = 8
    let sampledSourceIDs: [String]
    if approved.count <= sourceSampleSize {
        sampledSourceIDs = approved
    } else {
        let stride = Double(approved.count) / Double(sourceSampleSize)
        sampledSourceIDs = (0..<sourceSampleSize).map {
            approved[min(Int(Double($0) * stride), approved.count - 1)]
        }
    }

    let activeChildGoals = childGoals.filter {
        LearningGoalStatus.parse($0.status) != .archived
    }
    let openGaps = ([goal] + activeChildGoals)
        .flatMap { $0.gaps ?? [] }
        .filter(\.isOpen)
        .sorted { ($0.severity ?? 0) > ($1.severity ?? 0) }

    var sections: [String] = []
    var identity: [String] = []

    // `isIdentity` marks the sections describing what the Notebook is about, as opposed
    // to what it already holds (existing source titles) or what the learner has already
    // concluded (synthesis notes). Only those reach the lexical branch — see
    // `NotebookRecommendationSeed.lexicalQuery`.
    func add(_ label: String, values: [String], wordLimit: Int, isIdentity: Bool = false) {
        guard let value = words(values, limit: wordLimit) else { return }
        sections.append("\(label): \(value)")
        if isIdentity { identity.append(value) }
    }

    // A placeholder title ("New notebook") says nothing of the subject: a
    // blank notebook seeds nothing, rather than whatever sits near "new".
    let title = NotebookNaming.isPlaceholder(goal.title) ? "" : goal.title
    add("Notebook", values: [title, goal.topic ?? ""], wordLimit: 12, isIdentity: true)
    add("Research questions", values: goal.researchQuestions ?? [], wordLimit: 28, isIdentity: true)
    add(
        "Existing sources",
        values: sampledSourceIDs.compactMap { articlesById[$0]?.title },
        wordLimit: 32
    )
    add("Instructions", values: [goal.description ?? ""], wordLimit: 12, isIdentity: true)
    add(
        "Goals",
        values: activeChildGoals.flatMap { [$0.title, $0.topic ?? "", $0.description ?? ""] },
        wordLimit: 10,
        isIdentity: true
    )
    add("Open questions", values: openGaps.map(\.summary), wordLimit: 8, isIdentity: true)
    add("Synthesis", values: [goal.notes ?? ""], wordLimit: 8)

    return NotebookRecommendationSeed(
        embeddingText: sections.joined(separator: "\n"),
        lexicalQuery: identity.joined(separator: " ")
    )
}

extension StudioViewModel {

    // MARK: - Notebooks
    //
    // A Notebook is an open-ended companion LearningGoalRecord (`isNotebook`).
    // Its source pool (approvedSourceIDs) is the Notebook's MCP source context, and its
    // `notes` field holds the Notebook synthesis notes Markdown.

    // MARK: - Notebook chat selection
    //
    // The checkboxes beside a notebook's sources pick which of them its chats
    // read: its own, and those of the context notebooks the learner put in
    // (`NotebookChatContext`), a linked notebook's sources reaching nothing
    // until then. The learner's own, synced as `notebook.chatExcluded.<notebookID>`
    // and `notebook.chatContextNotebooks.<notebookID>` (`NotebookChatSelection`);
    // membership and links are untouched. New chats, and a chat not yet sent,
    // follow the ticks; a chat under way keeps its catalog.

    /// The notebook's context notebooks: one per link, in link order, each
    /// with its own approved sources (none for one this Mac has no record of).
    func notebookContextNotebooks(_ notebook: LearningGoalRecord) -> [NotebookChatContext.ContextNotebook] {
        NotebookChatSelection.contextNotebooks(of: notebook) { id in
            self.notebook(id: id).flatMap { $0.isNotebook ? $0.approvedSourceIDs : nil }
        }
    }

    /// The learner's two rows for the notebook, as this window holds them.
    func notebookChatSelection(_ notebookID: String) -> NotebookChatContext.Selection {
        NotebookChatContext.Selection(
            excluded: notebookChatExclusions[notebookID] ?? [],
            contextNotebookIDs: notebookChatContextNotebooks[notebookID] ?? []
        )
    }

    /// What the notebook's chats draw on: its own sources in study order,
    /// then those of each context notebook put in, in link order.
    func notebookChatPool(_ notebook: LearningGoalRecord) -> [String] {
        NotebookChatContext.chatPool(
            own: notebook.approvedSourceIDs,
            linked: notebookContextNotebooks(notebook),
            selection: notebookChatSelection(notebook.id)
        )
    }

    /// The sources a new chat in `notebook` reads: its chat pool, in order,
    /// minus the unticked.
    func notebookChatSourceIDs(_ notebook: LearningGoalRecord) -> [String] {
        NotebookChatSelection.chatSourceIDs(
            pool: notebookChatPool(notebook),
            excluded: notebookChatExclusions[notebook.id] ?? []
        )
    }

    /// Whether one of the notebook's own sources has its box ticked. A
    /// source that is not in the pool reads as ticked: it would arrive so.
    /// A row per source asks, so it reads one dictionary and nothing more.
    func isNotebookSourceInChat(_ sourceID: String, notebookID: String) -> Bool {
        notebookChatExclusions[notebookID]?.contains(sourceID) != true
    }

    /// A context notebook's box: nil while it is out of the notebook's chats,
    /// else its ticked sources and all it has, counting only sources a chat
    /// could read, as `notebookChatTally` does.
    func notebookContextNotebookTally(_ contextNotebookID: String, in notebook: LearningGoalRecord) -> (inChat: Int, total: Int)? {
        let tally = NotebookChatContext.tally(
            of: contextNotebookID,
            linked: notebookContextNotebooks(notebook),
            selection: notebookChatSelection(notebook.id)
        ) { id in
            guard let article = self.articlesById[id] else { return false }
            return self.isSourceIncludedInKnowledge(article)
        }
        return tally.map { (inChat: $0.ticked, total: $0.total) }
    }

    /// Ticks (`inChat`) or unticks the notebook's `sourceIDs`. Ticking a
    /// source only a context notebook out of the chats holds puts that
    /// notebook in with that source alone (`NotebookChatContext.settingSources`);
    /// `contextNotebookID` names the group whose box was ticked. The unticked
    /// row is kept to the notebook's pool on the way through, so an empty
    /// `sourceIDs` with `inChat` true re-normalizes it after the pool
    /// changed; the context notebooks' row keeps every id it names
    /// (`NotebookChatContext.stored`). Allowed for a read-only team member
    /// too: the ticks are the member's own preference, not a write to the
    /// team's notebook.
    func setNotebookSources(_ sourceIDs: [String], inChat: Bool, through contextNotebookID: String? = nil, notebookID: String) {
        guard let notebook = notebook(id: notebookID), notebook.isNotebook else { return }
        let linked = notebookContextNotebooks(notebook)
        let next = NotebookChatContext.settingSources(
            sourceIDs,
            inChat: inChat,
            through: contextNotebookID,
            own: notebook.approvedSourceIDs,
            linked: linked,
            selection: notebookChatSelection(notebookID)
        )
        storeNotebookChatSelection(next, notebook: notebook, linked: linked)
    }

    /// A context notebook's own box (`inChat`): puts one that is out into the
    /// notebook's chats as the learner left it, its unticked sources still
    /// unticked, and ticks every source of one already in; unticked, takes
    /// it out, leaving its sources' boxes as they were for when it comes
    /// back (`NotebookChatContext.settingContextNotebooks`). The member's
    /// own, like the source boxes.
    func setNotebookContextNotebooks(_ contextNotebookIDs: [String], inChat: Bool, notebookID: String) {
        guard let notebook = notebook(id: notebookID), notebook.isNotebook else { return }
        let linked = notebookContextNotebooks(notebook)
        let next = NotebookChatContext.settingContextNotebooks(
            contextNotebookIDs,
            inChat: inChat,
            linked: linked,
            selection: notebookChatSelection(notebookID)
        )
        storeNotebookChatSelection(next, notebook: notebook, linked: linked)
    }

    /// Writes the rows that changed, sorted, the unticked kept to the
    /// notebook's pool and the context notebooks as they are.
    private func storeNotebookChatSelection(
        _ selection: NotebookChatContext.Selection,
        notebook: LearningGoalRecord,
        linked: [NotebookChatContext.ContextNotebook]
    ) {
        let stored = NotebookChatContext.stored(selection, own: notebook.approvedSourceIDs, linked: linked)
        let excluded = Set(stored.excluded)
        if excluded != (notebookChatExclusions[notebook.id] ?? []) {
            notebookChatExclusions[notebook.id] = excluded.isEmpty ? nil : excluded
            NotebookChatSelection.write(stored.excluded, notebookID: notebook.id)
        }
        let context = Set(stored.contextNotebookIDs)
        if context != (notebookChatContextNotebooks[notebook.id] ?? []) {
            notebookChatContextNotebooks[notebook.id] = context.isEmpty ? nil : context
            NotebookChatSelection.writeContextNotebooks(stored.contextNotebookIDs, notebookID: notebook.id)
        }
    }

    /// Ticks or unticks every source the notebook's chats draw on, its own
    /// and those of the context notebooks put in. A context notebook stays in
    /// or out as it was.
    func setAllNotebookSourcesInChat(_ inChat: Bool, notebookID: String) {
        guard let notebook = notebook(id: notebookID) else { return }
        setNotebookSources(notebookChatPool(notebook), inChat: inChat, notebookID: notebookID)
    }

    /// "8 of 12": the ticked sources and the chat pool, both counting only
    /// sources a chat could read (present in the library and in knowledge).
    /// A context notebook's sources count while it is in the chats.
    func notebookChatTally(_ notebook: LearningGoalRecord) -> (inChat: Int, total: Int) {
        let readable = notebookChatPool(notebook).filter { id in
            guard let article = articlesById[id] else { return false }
            return isSourceIncludedInKnowledge(article)
        }
        let excluded = notebookChatExclusions[notebook.id] ?? []
        return (readable.filter { !excluded.contains($0) }.count, readable.count)
    }

    /// Moves an unsent chat's context from one notebook selection to the next,
    /// keeping whatever else the learner put in it. False, and nothing changed,
    /// when the context no longer holds the old selection: something else
    /// (the Reader, a drop) replaced it since, and that choice stands.
    @discardableResult
    func followNotebookSelection(from old: [String], to new: [String]) -> Bool {
        let previous = orderedUniqueSourceIDs(old).filter { id in
            guard let article = articlesById[id] else { return false }
            return isSourceIncludedInKnowledge(article)
        }
        let held = Set(contextSourceIds)
        guard previous.allSatisfy(held.contains) else { return false }
        let previousSet = Set(previous)
        setContextSources(new + contextSourceIds.filter { !previousSet.contains($0) })
        return true
    }

    /// After sources joined notebooks — `arrivals` names, per notebook, the
    /// ids it holds now and did not before — their boxes are ticked where
    /// they arrived, and in every notebook whose chats read the notebook they
    /// arrived in: an untick left
    /// behind when a source last left the notebook, by whatever route or
    /// device, never outlives its return. Only rows naming an arrival are
    /// looked at; `setNotebookSources` writes only a row that changes.
    func tickArrivingNotebookSources(_ arrivals: [String: [String]]) {
        let arrived = Set(arrivals.values.joined())
        guard !arrived.isEmpty else { return }
        // An arrival writes a new Entry stamp, so its untick no longer matches and the
        // source is ticked with no write to the member's state (schema v2 §5.6); the snapshot is read
        // again.
        NotebookStateStore.reload()
    }

    /// The ids `notebookID` holds now that are not in `heldBefore`: what an
    /// add brought, team copies included, read after the reload.
    func notebookArrivals(in notebookID: String, heldBefore: Set<String>) -> [String: [String]] {
        [notebookID: (notebook(id: notebookID)?.approvedSourceIDs ?? []).filter { !heldBefore.contains($0) }]
    }

    /// After an inbound refresh reloaded the notebooks as `refreshed`: diffs
    /// them against `notebookSyncBaseline`, what the last inbound refresh
    /// left (else `inMemory`, what the window held before this reload), and
    /// ticks what joined. The baseline, not `learningGoals`, because a local
    /// reload between the record landing and this refresh would already hold
    /// the new member, and nothing would look new.
    func noteInboundNotebooks(_ refreshed: [LearningGoalRecord], inMemory: [LearningGoalRecord]) async {
        let before = notebookSyncBaseline ?? inMemory
        notebookSyncBaseline = refreshed
        guard refreshed != before else { return }
        await tickNotebookArrivalsFromSync(before: before, after: refreshed)
    }

    /// After an inbound sync change reloaded the notebooks (`before` is what
    /// this Mac held until then): a source that joined a notebook on another
    /// device — the web, the iPhone, another Mac, a teammate — arrives ticked
    /// here as an add on this Mac does, so a client that writes the
    /// membership and never the row is covered. An untick made after the
    /// source joined stands (`NotebookChatSelection.inboundArrivals`).
    /// Only rows naming an arrival are read, and only their write dates.
    func tickNotebookArrivalsFromSync(before: [LearningGoalRecord], after: [LearningGoalRecord]? = nil) async {
        let arrivals = NotebookChatSelection.inboundArrivals(before: before, after: after ?? learningGoals)
        let arrived = Set(arrivals.values.joined().map(\.sourceID))
        guard !arrived.isEmpty else { return }
        // An arrival writes a new Entry stamp, so its untick no longer matches and the
        // source is ticked with no write to the member's state (schema v2 §5.6); the snapshot is read
        // again.
        NotebookStateStore.reload()
    }

    /// Replaces the notebook's links to its context notebooks. Linking puts
    /// nothing into its chats (`addContextNotebook` links and puts in); a
    /// notebook unlinked here leaves them, its id dropped from the row and
    /// its sources' unticks with it. Only the ids this Mac unlinks leave the
    /// row: one it does not know is linked stays for the device that put it
    /// in. Returns whether the links were saved.
    @discardableResult
    func setRelatedNotebooks(_ relatedNotebookIDs: [String], notebookID: String) async -> Bool {
        let held = notebook(id: notebookID)?.relatedNotebookIDs ?? []
        let unlinked = held.filter { !relatedNotebookIDs.contains($0) }
        let linkedNow = relatedNotebookIDs.filter { !held.contains($0) }
        do {
            try await storage.setRelatedNotebooks(
                notebookID: notebookID,
                relatedNotebookIDs: relatedNotebookIDs
            )
            await loadLearningGoals()
            setNotebookContextNotebooks(unlinked, inChat: false, notebookID: notebookID)
            // Generation 2: "Uses context from" writes the link and this member's tick (schema v2
            // D52); links made before stay unticked.
            if !linkedNow.isEmpty {
                setNotebookContextNotebooks(linkedNow, inChat: true, notebookID: notebookID)
            }
            return true
        } catch {
            logger.error("Failed to update Notebook context links: \(error.localizedDescription)")
            showToast("Could not save the notebook")
            return false
        }
    }

    /// Add a Notebook to Context: links `contextNotebookID` to the notebook
    /// and puts it into its chats, in one step (product owner, 2026-10-02: "make
    /// sure that notebooks can put other notebooks into context relatively
    /// easily"). Its sources' boxes stay as they were
    /// (`NotebookChatContext.puttingIn`). A notebook already linked is only
    /// put in.
    func addContextNotebook(_ contextNotebookID: String, to notebookID: String) async {
        guard contextNotebookID != notebookID, let notebook = notebook(id: notebookID) else { return }
        var links = notebook.relatedNotebookIDs ?? []
        if !links.contains(contextNotebookID) {
            links.append(contextNotebookID)
            guard await setRelatedNotebooks(links, notebookID: notebookID) else { return }
        }
        guard let linkedNotebook = self.notebook(id: notebookID) else { return }
        let linked = notebookContextNotebooks(linkedNotebook)
        let next = NotebookChatContext.puttingIn(
            [contextNotebookID],
            linked: linked,
            selection: notebookChatSelection(notebookID)
        )
        storeNotebookChatSelection(next, notebook: linkedNotebook, linked: linked)
    }

    /// Take Out of Context: unlinks `contextNotebookID` from the notebook,
    /// which drops it from the chats' row too (`setRelatedNotebooks`).
    func takeContextNotebookOut(_ contextNotebookID: String, of notebookID: String) async {
        guard let notebook = notebook(id: notebookID) else { return }
        await setRelatedNotebooks((notebook.relatedNotebookIDs ?? []).filter { $0 != contextNotebookID }, notebookID: notebookID)
    }

    /// Link a Notebook to the GitHub repository it is about — `owner/repo`, an
    /// `owner/repo.git` remote, or a github.com URL — or unlink it with an
    /// empty draft. The Repository row refuses an entry that does not parse
    /// before calling here, so a storage error is a real failure, not bad input.
    func setNotebookRepository(_ repository: String, notebookID: String) async {
        do {
            try await storage.setNotebookRepository(notebookID: notebookID, repository: repository)
            await loadLearningGoals()
        } catch {
            logger.error("Failed to update Notebook repository: \(error.localizedDescription)")
            showToast("Could not save repository")
        }
    }

    /// Move a Goal's deadline from its row (product owner, 2026-09-20: "pls let me
    /// change the timeline for each goal"). The chosen day is stored as **Set a
    /// goal** stores one, at the start of that date, so the two agree about
    /// which day a deadline is.
    func setGoalDeadline(goalID: String, endAt: Date) async {
        let day = Calendar.current.startOfDay(for: endAt)
        do {
            try await storage.setLearningGoalDeadline(goalID: goalID, endAt: day)
            await loadLearningGoals()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Moving goal deadline failed: \(error.localizedDescription)")
        }
    }

    /// Mark a Notebook or Goal done, archived, or active again. Storage runs on the
    /// `StorageService` actor, so the main actor only publishes the reload.
    func setGoalStatus(goalID: String, status: LearningGoalStatus) async {
        let isNotebook = notebook(id: goalID)?.isNotebook == true
        do {
            try await storage.setLearningGoalStatus(goalID: goalID, status: status)
            await loadLearningGoals()
            guard isNotebook else { return }

            if status == .archived {
                if activeNotebookId == goalID {
                    activeNotebookId = notebooks.first?.id
                }
                closeNotebookInEveryWindow(goalID)
                showToast("Archived notebook")
            } else if status == .active {
                showToast("Restored notebook")
            }
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Updating goal status failed: \(error.localizedDescription)")
        }
    }

    /// Create a new Notebook and make it active.
    func createNotebookContext(
        title: String,
        description: String? = nil,
        summary: String? = nil
    ) async -> LearningGoalRecord? {
        let cleanTitle = normalizedNotebookTitle(title)
        let calendar = Calendar.current
        let startAt = calendar.startOfDay(for: Date())
        // A Notebook has no deadline, and since schema 120 that is what tells it
        // from a Goal. The old today + 30 days was never read by any Notebook
        // surface, but it now reads as "a Goal, due in a month".
        let endAt = LearningGoalRecord.openEndedEndAt

        do {
            let goal = try await storage.createCompanionGoal(
                title: cleanTitle,
                description: description,
                summary: summary,
                topic: cleanTitle,
                startAt: startAt,
                endAt: endAt,
                dailyTarget: 3,
                discoveryEnabled: false,
                seedSourceIDs: [],
                teamID: activeTeamID
            )
            activeNotebookId = goal.id
            await loadLearningGoals()
            showToast("Created notebook")
            return notebook(id: goal.id) ?? goal
        } catch {
            logger.error("Failed to create Notebook: \(error)")
            showToast("Could not create the notebook")
            return nil
        }
    }

    /// Create a deadline-bound Goal. A Notebook is optional: the learner says
    /// what they want to be true and by when, and tagging it to a source pool
    /// is a separate thought they may not have had yet. This is deliberately a
    /// local persistence action: setting a Goal should not require opening a
    /// chat or making an AI request.
    func createGoal(
        title: String,
        deadline: Date,
        notebookID: String? = nil,
        artifactID: String? = nil
    ) async -> LearningGoalRecord? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }
        let resolvedNotebookID = (notebookID?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
        if let resolvedNotebookID, notebook(id: resolvedNotebookID)?.isNotebook != true { return nil }
        let resolvedArtifactID = (artifactID?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }

        let calendar = Calendar.current
        let startAt = calendar.startOfDay(for: Date())
        let endAt = calendar.startOfDay(for: deadline)
        guard endAt > startAt else {
            showToast("Choose a future deadline")
            return nil
        }

        do {
            let goal = try await storage.createCompanionGoal(
                title: trimmedTitle,
                topic: trimmedTitle,
                startAt: startAt,
                endAt: endAt,
                dailyTarget: 3,
                discoveryEnabled: false,
                seedSourceIDs: [],
                parentNotebookID: resolvedNotebookID,
                artifactID: resolvedArtifactID
            )
            await loadLearningGoals()
            showToast("Set goal")
            return learningGoals.first(where: { $0.id == goal.id }) ?? goal
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to create Goal: \(error.localizedDescription)")
            showToast("Could not create Goal")
            return nil
        }
    }

    /// Move one Goal onto another row's place in the Goals tab (product owner,
    /// 2026-09-20: "allow me to reshuffle these"): the drop of a row on a
    /// row. The order written is every open Goal as the tab reads them with
    /// the one moved, so a drag inside In flight never disturbs Later, and
    /// a Goal that crosses the horizon later keeps its place.
    func reorderGoals(from sourceID: String, to destinationID: String) async {
        guard sourceID != destinationID else { return }
        var ids = allGoals.filter { !$0.isDone && !$0.isArchived }.map(\.id)
        guard let sourceIndex = ids.firstIndex(of: sourceID),
              let destinationIndex = ids.firstIndex(of: destinationID) else { return }
        ids.remove(at: sourceIndex)
        ids.insert(sourceID, at: destinationIndex)
        await applyGoalOrder(ids)
    }

    /// Move one Goal up (`by: -1`) or down (`by: 1`) within the open Goals,
    /// the context menu's route to the same order a drag makes.
    func moveGoal(_ goalID: String, by delta: Int) async {
        var ids = allGoals.filter { !$0.isDone && !$0.isArchived }.map(\.id)
        guard let index = ids.firstIndex(of: goalID) else { return }
        let target = index + delta
        guard ids.indices.contains(target) else { return }
        ids.swapAt(index, target)
        await applyGoalOrder(ids)
    }

    /// Whether a Goal can move one step in a direction: the row's Move up
    /// and Move down are disabled at the ends of the list.
    func canMoveGoal(_ goalID: String, by delta: Int) -> Bool {
        let ids = allGoals.filter { !$0.isDone && !$0.isArchived }.map(\.id)
        guard let index = ids.firstIndex(of: goalID) else { return false }
        return ids.indices.contains(index + delta)
    }

    /// Whether any open Goal in this library was placed by hand — when the
    /// tab offers the way back to deadline order.
    var hasHandOrderedGoals: Bool {
        allGoals.contains { $0.sortOrder != nil && !$0.isDone && !$0.isArchived }
    }

    /// Forget every placement, so the Goals read by deadline again.
    func sortGoalsByDeadline() async {
        await applyGoalOrder([])
    }

    private func applyGoalOrder(_ orderedIDs: [String]) async {
        do {
            try await storage.reorderLearningGoals(goalIDs: orderedIDs)
            await loadLearningGoals()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Reordering Goals failed: \(error.localizedDescription)")
            showToast("Could not reorder the Goals")
        }
    }

    /// Put sources on a Goal: a drop on its row (product owner, 2026-09-19: "allow
    /// me to drag sources onto goals"). The sources join the Goal's approved
    /// pool the way a Notebook's do, and a Goal tagged to a Notebook hands them
    /// on to that Notebook's pool too (`addCompanionSeedSources`). Unlike a drop
    /// on a Notebook this never changes the active Notebook: a Goal is not a
    /// source context, so putting a paper on it should not move the chat's
    /// scope. Sources already on the Goal are skipped and said so.
    @discardableResult
    func addSourcesToGoal(goalID: String, sourceIDs: [String]) async -> LearningGoalRecord? {
        let ids = orderedUniqueSourceIDs(sourceIDs)
        guard !ids.isEmpty, let goal = learningGoals.first(where: { $0.id == goalID }), goal.isGoal else { return nil }

        let existingSourceIDs = Set(goal.approvedSourceIDs.map(canonicalSourceID))
        let newSourceIDs = ids.filter { !existingSourceIDs.contains(canonicalSourceID($0)) }
        let skippedCount = ids.count - newSourceIDs.count
        guard !newSourceIDs.isEmpty else {
            showToast(ids.count > 1 ? "Sources already on “\(goal.title)”" : "Source already on “\(goal.title)”")
            return goal
        }

        // The Goal's Notebook is the notebook these reach.
        let parentID = goal.parentNotebookID
        let parentHeldBefore = Set(parentID.flatMap { notebook(id: $0) }?.approvedSourceIDs ?? [])
        applyOptimisticNotebookItems(goalID: goalID, sourceIDs: newSourceIDs)
        do {
            try await storage.addCompanionSeedSources(goalID: goalID, sourceIDs: newSourceIDs)
            await loadLearningGoals()
            if let parentID {
                tickArrivingNotebookSources(notebookArrivals(in: parentID, heldBefore: parentHeldBefore))
            }
            let addedText = newSourceIDs.count == 1 ? "Added 1 source" : "Added \(newSourceIDs.count) sources"
            if skippedCount > 0 {
                showToast("\(addedText) to “\(goal.title)”; \(skippedCount) already there")
            } else {
                showToast("\(addedText) to “\(goal.title)”")
            }
            return learningGoals.first(where: { $0.id == goalID })
        } catch {
            await loadLearningGoals()
            logger.error("Failed to add sources to Goal: \(error.localizedDescription)")
            showToast("Could not add to “\(goal.title)”")
            return nil
        }
    }

    /// Save the Goal editor (product owner, 2026-09-20; `GoalEditorSheet`): each
    /// changed field goes through the write that already exists for it, so a
    /// new title never rewrites the deadline and an untouched tag is not
    /// re-stamped. The first failure is reported and the rest is left; the
    /// list reloads once either way. `update_learning_goal` is the same move
    /// over MCP.
    func updateGoal(goalID: String, _ changes: GoalEdit.Changes) async {
        guard !changes.isEmpty else { return }
        do {
            if let title = changes.title {
                try await storage.setLearningGoalTitle(goalID: goalID, title: title)
            }
            if let deadline = changes.deadline {
                try await storage.setLearningGoalDeadline(goalID: goalID, endAt: Calendar.current.startOfDay(for: deadline))
            }
            if changes.retagsNotebook {
                try await storage.setLearningGoalParentNotebook(goalID: goalID, parentNotebookID: changes.notebookID)
            }
            if changes.relinksArtifact {
                try await storage.setLearningGoalArtifact(goalID: goalID, artifactID: changes.artifactID)
            }
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Saving a Goal's edits failed: \(error.localizedDescription)")
            showToast("Could not save the goal")
        }
        await loadLearningGoals()
    }

    /// Start making progress on a Goal in a chat (product owner, 2026-09-20: "if I
    /// click a goal, I basically want a way to like start making progress on
    /// it. Like maybe start a chat that has the sources"): a fresh chat with
    /// the Goal's sources in context, framed by its Notebook when it has one,
    /// and an unsent opening line naming the Goal for the learner to edit or
    /// send. A chat is filed under a Notebook, not a Goal, so the Goal is
    /// named in the line rather than stamped on the session; a review
    /// (`startCompanionReview`) is the route that counts toward the Goal.
    func requestGoalChat(_ goal: LearningGoalRecord) {
        pendingReviewChatNotebookID = goal.parentNotebookID.flatMap { notebook(id: $0)?.id }
        setContextSources(goal.approvedSourceIDs)
        pendingReviewChatDraft = Self.goalChatDraft(goal)
        reviewChatPanelMode = .chat
        isChatTabActive = true
        reviewChatResetRequestID = UUID()
        reviewChatFocusRequestID = UUID()
    }

    /// The unsent opening line for a chat started from a Goal: the sentence,
    /// when it is due, and what the sources are for. Pure, so it can be tested.
    nonisolated static func goalChatDraft(
        _ goal: LearningGoalRecord,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let due = goal.endAt.formatted(Date.FormatStyle(locale: locale, calendar: calendar).weekday(.wide).day().month(.wide))
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: goal.endAt)).day ?? 0
        var draft = "I'm working on my goal “\(goal.title)”"
        if days < 0 {
            draft += ", which was due \(due)."
        } else if days == 0 {
            draft += ", due today."
        } else {
            draft += ", due \(due) (\(days) day\(days == 1 ? "" : "s") away)."
        }
        let count = goal.approvedSourceIDs.count
        if count == 1 {
            draft += " Help me make progress on it with the source in context."
        } else if count > 1 {
            draft += " Help me make progress on it with the \(count) sources in context."
        } else {
            draft += " Help me work out where to start."
        }
        return draft
    }

    /// The artifact a Goal is for, from the loaded library; nil when the Goal
    /// names none or names a record that is gone.
    func goalArtifact(_ goal: LearningGoalRecord) -> ArtifactRecord? {
        guard let artifactID = goal.linkedArtifactID else { return nil }
        return artifacts.first(where: { $0.id == artifactID })
    }

    /// Open the artifact a Goal is for: a click on the Goal's row. A team's
    /// record opens in that team's library, the way it does from the
    /// Artifacts home; one that is gone says so instead of opening nothing.
    func openGoalArtifact(_ goal: LearningGoalRecord) async {
        guard let artifactID = goal.linkedArtifactID else { return }
        if !hasLoadedArtifactsOnce { await loadArtifacts() }
        guard artifacts.contains(where: { $0.id == artifactID }) else {
            showToast("That page or site is no longer in your library")
            return
        }
        await openTeamArtifact(artifactID)
    }

    /// Rename a Notebook in place. Title is display metadata only: discovery topic,
    /// instructions, source membership, child Goals, and sync identity stay untouched.
    func renameNotebook(_ notebookID: String, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let resolvedTitle = String(trimmed.prefix(90))

        do {
            try await storage.setLearningGoalTitle(goalID: notebookID, title: resolvedTitle)
            notebookNamedByLearner(notebookID)
            if let index = learningGoals.firstIndex(where: { $0.id == notebookID }) {
                learningGoals[index].title = resolvedTitle
                learningGoals[index].updatedAt = Date()
            }
        } catch {
            logger.error("Failed to rename Notebook: \(error)")
            showToast("Could not rename the notebook")
        }
    }

    // MARK: - "Add sources" candidates

    /// Library sources worth adding to a Notebook, ranked, with everything already in the
    /// pool filtered out.
    ///
    /// Two modes, both excluding every source already attached to the goal in any state —
    /// approved and pending are visibly in the pool, and rejected is tombstoned so it must
    /// never be re-proposed:
    ///
    /// - With a query: the shared hybrid ranking, the same one the sidebar search and the
    ///   MCP `search_sources_semantic` tool use.
    /// - Without a query: recommendations — nearest neighbours to an embedding of the
    ///   Notebook's defining context: title/topic, research questions, instructions,
    ///   approved source titles, nested Goals, open understanding gaps, and synthesis.
    ///   Pure vector search here, with no lexical branch: this deliberately compact
    ///   context seed is not a term query, and scoring it as one is noise.
    ///
    /// Main-actor work is limited to snapshotting the exclusion set and article map; the
    /// embed and the search both run off-main.
    func notebookSourceCandidates(goalID: String, query: String) async -> [SourceSearchResult] {
        guard let goal = notebook(id: goalID) else { return [] }
        let excluded = Set(goal.items.map(\.sourceID))
        // A team Notebook holds the team's copies, and the list resolves a
        // copy to the learner's own row (docs/teams-design.md, decision 19),
        // so an own row already attached as its copy is not suggested again.
        let excludedRows = Set(goal.items.map { canonicalSourceID($0.sourceID) })
        let articlesById = self.articlesById
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayLimit = 40

        func visible(_ ids: [(id: String, score: Float)]) -> [SourceSearchResult] {
            var seen = Set<String>()
            return ids.compactMap { candidate in
                guard !excluded.contains(candidate.id), let article = articlesById[candidate.id],
                      !excludedRows.contains(article.id), seen.insert(article.id).inserted else { return nil }
                return SourceSearchResult(article: article, score: candidate.score, bestMatch: nil)
            }
            .prefix(displayLimit)
            .map { $0 }
        }

        if trimmed.isEmpty {
            let seed = notebookSourceRecommendationSeed(
                goal: goal,
                childGoals: goals(inNotebook: goal.id),
                articlesById: articlesById
            )
            guard !seed.embeddingText.isEmpty else { return [] }

            var seedVector: [Float]?
            do {
                seedVector = try await aiService.embedText(seed.embeddingText)
            } catch {
                logger.error("Notebook source recommendations failed to embed: \(error.localizedDescription)")
            }

            // Over-fetch by the pool size: a Notebook holding 100 sources would
            // otherwise spend its whole result page on what it already has.
            let topK = min(displayLimit + excluded.count, 400)

            // Ranked by the same hybrid engine the typed search uses, rather than by
            // cosine similarity alone. A pooled contextual vector cannot represent a
            // rare token — see `SourceSearchEngine.lexicalWeight` — so a Notebook named
            // for a gene symbol was suggesting whatever sat near its seed paragraph in
            // embedding space while the papers naming that gene in their titles never
            // appeared. The lexical branch is what can retrieve them.
            guard !seed.lexicalQuery.isEmpty else {
                guard let seedVector else { return [] }
                return visible(await storage.findSimilarSources(queryVector: seedVector, topK: topK))
            }
            let hits = await storage.searchSources(
                queryText: seed.lexicalQuery,
                queryVector: seedVector,
                limit: topK
            )
            return visible(hits.map { (id: $0.sourceId, score: $0.score) })
        }

        var queryVector: [Float]?
        do {
            queryVector = try await aiService.embedText(trimmed)
        } catch {
            // Same degradation as the sidebar search: the lexical branch is the one that
            // actually retrieves a rare term, so a failed embed narrows results rather
            // than taking the picker down.
            logger.error("Notebook source search failed to embed; searching without the semantic branch: \(error.localizedDescription)")
        }
        let limit = min(displayLimit + excluded.count, 400)
        let hits = await storage.searchSources(queryText: trimmed, queryVector: queryVector, limit: limit)
        return visible(hits.map { (id: $0.sourceId, score: $0.score) })
    }

    /// A library book that answers to the notebook's search words.
    struct NotebookBookCandidate: Identifiable, Equatable {
        var id: String { group }
        /// The book's group id, which its chapters carry as `parentGroup`.
        let group: String
        let title: String
        let author: String?
        /// Every chapter in reading order, whether or not the notebook holds it.
        let chapterIDs: [String]
        /// The chapters the notebook does not hold yet; what its + adds.
        let missingChapterIDs: [String]
    }

    /// The library's books whose own title, subtitle or author answer to the
    /// words, in the order the sidebar's Books tab ranks them. A book is a
    /// group of chapter sources, not a source, so `notebookSourceCandidates`
    /// can only ever find its chapters: "Radical Life Extension" the book sat
    /// in the library while the search listed a paper and a chapter instead.
    /// Books the notebook already holds whole are left out.
    func notebookBookCandidates(goalID: String, query: String) -> [NotebookBookCandidate] {
        guard let goal = notebook(id: goalID) else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = SidebarSearchQuery(parsing: trimmed.lowercased())
        guard !parsed.isEmpty else { return [] }
        let held = Set(goal.items.flatMap { [$0.sourceID, canonicalSourceID($0.sourceID)] })
        return visibleBookGroupNames.compactMap { group in
            let name = bookDisplayName(group)
            let author = bookDisplayAuthor(group)
            let subtitle = bookDisplaySubtitle(group)
            guard Self.sidebarGroupMatchesSearch(
                parsed,
                metadata: [group, name, subtitle, author].compactMap { $0 },
                titles: [group, name, subtitle].compactMap { $0 },
                authors: [author].compactMap { $0 }
            ) else { return nil }
            let chapters = sourceIDsForGroupInOrder(group)
                .filter { articlesById[$0]?.sourceType == .book }
            let missing = chapters.filter { !held.contains($0) }
            guard !chapters.isEmpty, !missing.isEmpty else { return nil }
            return NotebookBookCandidate(
                group: group,
                title: name,
                author: author,
                chapterIDs: chapters,
                missingChapterIDs: missing
            )
        }
        .sorted { a, b in
            // The book named for the words leads the ones that only mention them.
            let exactA = a.title.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
            let exactB = b.title.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
            if exactA != exactB { return exactA }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    /// Add sources to a Notebook's pool (its MCP source context). `announce`
    /// false keeps the success toasts quiet, for a control whose own mark
    /// flipping is the answer (the Sources sidebar's +) and for a caller that
    /// files many rows one at a time and sums them up once (Discover's import);
    /// a failure still says so, and what is written is the same.
    @discardableResult
    func addSourcesToNotebookContext(
        _ sourceIDs: [String],
        notebookID: String? = nil,
        announce: Bool = true
    ) async -> LearningGoalRecord? {
        let ids = orderedUniqueSourceIDs(sourceIDs)
        guard !ids.isEmpty else { return nil }

        let resolvedID: String
        if let notebookID {
            resolvedID = notebookID
        } else if let activeNotebookId {
            resolvedID = activeNotebookId
        } else {
            // No active Notebook — create one to receive the sources.
            guard let created = await createUnnamedNotebook() else {
                return nil
            }
            resolvedID = created.id
        }

        // A team Notebook holds the team's copies; the list hands over own ids.
        let existingSourceIDs = Set((notebook(id: resolvedID)?.approvedSourceIDs ?? []).map(canonicalSourceID))
        let newSourceIDs = ids.filter { !existingSourceIDs.contains(canonicalSourceID($0)) }
        let skippedCount = ids.count - newSourceIDs.count

        guard !newSourceIDs.isEmpty else {
            activeNotebookId = resolvedID
            if announce {
                showToast(ids.count > 1 ? "Sources already in the notebook" : "Source already in the notebook")
            }
            return notebook(id: resolvedID)
        }

        // What the notebook held before, to tell what arrived once the write
        // lands (team copies replace the own ids handed over).
        let heldBefore = Set(notebook(id: resolvedID)?.approvedSourceIDs ?? [])

        // Show the rows immediately. Appending the seed items to the in-memory record
        // makes them render this frame, before the SQLite write and the full
        // loadLearningGoals() reconcile (a 1+2·N query reload of every goal) land.
        // The reconcile still runs below and replaces this with canonical state.
        activeNotebookId = resolvedID
        applyOptimisticNotebookItems(goalID: resolvedID, sourceIDs: newSourceIDs)

        do {
            try await storage.addCompanionSeedSources(goalID: resolvedID, sourceIDs: newSourceIDs)
            await loadLearningGoals()
            // The sources arrive in the notebook's chat checkboxes ticked.
            tickArrivingNotebookSources(notebookArrivals(in: resolvedID, heldBefore: heldBefore))
            // Adding a source is working in the notebook: the next window
            // opens it, and the home's Recent order leads with it.
            noteNotebookWork(resolvedID)
            if announce, skippedCount > 0 {
                let addedText = newSourceIDs.count == 1 ? "Added 1 source" : "Added \(newSourceIDs.count) sources"
                let skippedText = skippedCount == 1 ? "1 already in the notebook" : "\(skippedCount) already in the notebook"
                showToast("\(addedText); \(skippedText)")
            } else if announce {
                showToast(newSourceIDs.count > 1 ? "Added \(newSourceIDs.count) sources to the notebook" : "Added source to the notebook")
            }
            return notebook(id: resolvedID)
        } catch {
            // The write failed, so drop the optimistic rows by reconciling with the DB.
            await loadLearningGoals()
            logger.error("Failed to add sources to Notebook: \(error)")
            showToast("Could not add to the notebook")
            return nil
        }
    }

    /// Link a whole course to a Notebook. The current course sources appear
    /// immediately, while storage persists the course subscription that makes
    /// future lectures and materials flow into the Notebook automatically.
    @discardableResult
    func linkCourseToNotebookContext(
        courseID: String,
        sourceIDs: [String],
        notebookID: String? = nil
    ) async -> LearningGoalRecord? {
        let ids = orderedUniqueSourceIDs(sourceIDs)
        let resolvedID: String
        if let notebookID {
            resolvedID = notebookID
        } else if let activeNotebookId {
            resolvedID = activeNotebookId
        } else {
            guard let created = await createUnnamedNotebook() else {
                return nil
            }
            resolvedID = created.id
        }

        // A team Notebook holds the team's copies; the list hands over own ids.
        let existingSourceIDs = Set((notebook(id: resolvedID)?.approvedSourceIDs ?? []).map(canonicalSourceID))
        let newSourceIDs = ids.filter { !existingSourceIDs.contains(canonicalSourceID($0)) }
        let heldBefore = Set(notebook(id: resolvedID)?.approvedSourceIDs ?? [])
        activeNotebookId = resolvedID
        applyOptimisticNotebookItems(goalID: resolvedID, sourceIDs: newSourceIDs)

        do {
            try await storage.linkCourseToNotebook(
                goalID: resolvedID,
                courseID: courseID,
                sourceIDs: ids
            )
            await loadLearningGoals()
            // The course's lectures arrive in the notebook's chat checkboxes ticked.
            tickArrivingNotebookSources(notebookArrivals(in: resolvedID, heldBefore: heldBefore))
            noteNotebookWork(resolvedID)
            showToast("Linked the course to \(notebookToastName(resolvedID))")
            return notebook(id: resolvedID)
        } catch {
            await loadLearningGoals()
            logger.error("Failed to link course to Notebook: \(error)")
            showToast("Could not link the course to \(notebookToastName(resolvedID))")
            return nil
        }
    }

    /// Append approved seed items to the in-memory Notebook record so dropped rows render
    /// instantly, ahead of the DB write and full reload. Mirrors `addCompanionSeedSources`:
    /// a rejected tombstone flips to approved, a brand-new source appends as an approved
    /// seed. Ids are provisional (`optimistic-…`); the reload replaces them with canonical
    /// rows. The pool view keys on source id, so that swap is invisible. Edits a
    /// copy and assigns it once: every write to `learningGoals` runs its didSet,
    /// which rebuilds the plans and the Sources sidebar's notebook marks.
    private func applyOptimisticNotebookItems(goalID: String, sourceIDs: [String]) {
        guard let index = learningGoals.firstIndex(where: { $0.id == goalID }) else { return }
        let approved = LearningGoalItemReviewState.approved.rawValue
        let seed = LearningGoalItemOrigin.seed.rawValue
        let now = Date()
        var goal = learningGoals[index]
        for sourceID in sourceIDs {
            if let itemIndex = goal.items.firstIndex(where: { $0.sourceID == sourceID }) {
                guard goal.items[itemIndex].reviewState != approved else { continue }
                goal.items[itemIndex].reviewState = approved
            } else {
                goal.items.append(
                    LearningGoalItem(
                        id: "optimistic-\(goalID)-\(sourceID)",
                        goalID: goalID,
                        sourceID: sourceID,
                        addedAt: now,
                        origin: seed,
                        reviewState: approved
                    )
                )
            }
        }
        guard goal != learningGoals[index] else { return }
        learningGoals[index] = goal
    }

    /// Takes `sourceIDs` out of the in-memory Notebook record at once, ahead of
    /// the DB write, so a Sources row's mark clears on the click. The reload
    /// that follows writes the stored state back, tombstones included.
    private func applyOptimisticNotebookItemRemoval(goalID: String, sourceIDs: [String]) {
        guard let index = learningGoals.firstIndex(where: { $0.id == goalID }) else { return }
        let removed = Set(sourceIDs)
        var goal = learningGoals[index]
        goal.items.removeAll { removed.contains($0.sourceID) }
        guard goal.items.count != learningGoals[index].items.count else { return }
        learningGoals[index] = goal
    }

    /// Remove a single source from a Notebook's pool.
    func removeSourceFromNotebookContext(_ sourceID: String, notebookID: String? = nil) async {
        guard let resolvedID = notebookID ?? activeNotebookId else { return }
        do {
            try await storage.removeCompanionSources(goalID: resolvedID, sourceIDs: [sourceID])
            await loadLearningGoals()
            // Drops the source's unticked box with it, so adding it back brings it back ticked.
            setNotebookSources([], inChat: true, notebookID: resolvedID)
            showToast("Removed source from the notebook")
        } catch {
            logger.error("Failed to remove source from Notebook: \(error)")
            showToast("Could not remove from the notebook")
        }
    }

    /// Remove multiple sources from a Notebook's pool. `announce` false keeps
    /// the success toast quiet, as for `addSourcesToNotebookContext`.
    func removeSourcesFromNotebookContext(
        _ sourceIDs: [String],
        notebookID: String? = nil,
        announce: Bool = true
    ) async {
        guard let resolvedID = notebookID ?? activeNotebookId else { return }
        let ids = orderedUniqueSourceIDs(sourceIDs)
        guard !ids.isEmpty else { return }
        do {
            try await storage.removeCompanionSources(goalID: resolvedID, sourceIDs: ids)
            await loadLearningGoals()
            setNotebookSources([], inChat: true, notebookID: resolvedID)
            if announce {
                showToast(ids.count == 1 ? "Removed source from the notebook" : "Removed \(ids.count) sources from the notebook")
            }
        } catch {
            // Puts back whatever a caller took out of the record ahead of the write.
            await loadLearningGoals()
            logger.error("Failed to remove sources from Notebook: \(error)")
            showToast("Could not remove from the notebook")
        }
    }

    // MARK: - The Sources sidebar's notebook marks
    //
    // While a window works in a notebook (its Notebooks pane showed it, and it
    // is still the open one), the Sources list marks the notebook's sources and
    // offers + on the rest. Membership is the notebook's approved pool, the set
    // `addSourcesToNotebookContext` deduplicates against; related notebooks'
    // pools are not this notebook's. A team notebook holds the team's copies,
    // which the list shows as the learner's own rows (`canonicalSourceID`).

    /// Rebuilds the membership index from `learningGoals` and the team-copy
    /// aliases, publishing only what changed.
    func refreshNotebookSidebarIndex() {
        let index = Self.notebookSidebarIndex(goals: learningGoals, rowID: canonicalSourceID)
        if index.members != notebookMemberSourceIDsByNotebook {
            notebookMemberSourceIDsByNotebook = index.members
            notebookMembershipRevision &+= 1
        }
        if index.titles != notebookTitlesByNotebook {
            notebookTitlesByNotebook = index.titles
        }
        if index.teams != notebookTeamIDsByNotebook {
            notebookTeamIDsByNotebook = index.teams
        }
    }

    /// Each active Notebook's approved sources, named by `rowID`, its title,
    /// and, for a team's Notebook, its team.
    static func notebookSidebarIndex(
        goals: [LearningGoalRecord],
        rowID: (String) -> String
    ) -> (members: [String: Set<String>], titles: [String: String], teams: [String: String]) {
        var members: [String: Set<String>] = [:]
        var titles: [String: String] = [:]
        var teams: [String: String] = [:]
        for goal in goals where goal.isNotebook && !goal.isArchived {
            titles[goal.id] = goal.title
            members[goal.id] = Set(goal.approvedSourceIDs.map(rowID))
            if let teamID = goal.teamID { teams[goal.id] = teamID }
        }
        return (members, titles, teams)
    }

    /// The notebook `windowState` works in: the one it holds, while that is
    /// an active notebook of the open library. Nil for a window holding none
    /// (its gallery), an archived notebook, or once another library opened —
    /// My Library's notebook marks nothing in a team's list, nor a team's in
    /// another's. What another window holds never counts here.
    func sidebarNotebook(in windowState: StudioWindowState) -> SidebarNotebook? {
        guard let notebookID = windowState.NotebookID,
              notebookTeamIDsByNotebook[notebookID] == activeTeamID,
              let title = notebookTitlesByNotebook[notebookID] else { return nil }
        return SidebarNotebook(notebookID: notebookID, title: title)
    }

    /// How much of `rowIDs` (Sources-list ids) the notebook holds.
    func notebookMembership(of rowIDs: [String], in notebookID: String) -> NotebookMembershipState {
        NotebookMembershipState(rowIDs: rowIDs, members: notebookMemberSourceIDsByNotebook[notebookID] ?? [])
    }

    /// Takes the sources `rowIDs` stand for out of the notebook: in a team
    /// notebook, the team's copies of them. The mark clears on the call; a
    /// failed write puts it back.
    func removeSourcesFromNotebook(_ rowIDs: [String], notebookID: String, announce: Bool = true) async {
        guard let notebook = notebook(id: notebookID) else { return }
        let memberIDs = Self.notebookMemberIDs(
            standingFor: rowIDs,
            approved: notebook.approvedSourceIDs,
            rowID: canonicalSourceID
        )
        guard !memberIDs.isEmpty else { return }
        applyOptimisticNotebookItemRemoval(goalID: notebookID, sourceIDs: memberIDs)
        await removeSourcesFromNotebookContext(memberIDs, notebookID: notebookID, announce: announce)
    }

    /// A notebook as a toast names it: its title in quotes, or "the notebook".
    private func notebookToastName(_ notebookID: String) -> String {
        notebook(id: notebookID).map { "\u{201C}\($0.title)\u{201D}" } ?? "the notebook"
    }

    /// "Add All to <Notebook>" on a Sources group. A course — a YouTube
    /// playlist is one — is linked, as a course dropped on the notebook is
    /// (`NotebookSourceDropHandler`), so its later lectures join too; any other
    /// group (a meeting series) adds the sources it holds today.
    func addGroupToNotebook(_ groupName: String, notebookID: String) async {
        let ids = sourceIDsForGroupInOrder(groupName)
        if allCourseGroupNames.contains(groupName) {
            await linkCourseToNotebookContext(courseID: groupName, sourceIDs: ids, notebookID: notebookID)
        } else {
            await addSourcesToNotebookContext(ids, notebookID: notebookID)
        }
    }

    /// "Remove All from <Notebook>" on a Sources group: the rows `rowIDs`
    /// leave the notebook, and a course it follows stops feeding it first, so
    /// a later lecture does not bring the course back.
    func removeGroupFromNotebook(_ groupName: String, rowIDs: [String], notebookID: String) async {
        if allCourseGroupNames.contains(groupName) {
            do {
                try await storage.unlinkCourseFromNotebook(goalID: notebookID, courseID: groupName)
            } catch {
                logger.error("Failed to unlink course from Notebook: \(error.localizedDescription)")
                showToast("Could not take the course out of \(notebookToastName(notebookID))")
                return
            }
            await reloadCourseFollowers()
        }
        await removeSourcesFromNotebook(rowIDs, notebookID: notebookID)
    }

    /// The approved members whose Sources row is one of `rowIDs`, in pool order.
    static func notebookMemberIDs(
        standingFor rowIDs: [String],
        approved: [String],
        rowID: (String) -> String
    ) -> [String] {
        let rows = Set(rowIDs)
        return approved.filter { rows.contains(rowID($0)) }
    }

    /// Replace a Notebook's synthesis notes with the supplied Markdown and attach the
    /// reviewed sources to the Notebook pool.
    func replaceNotebookSynthesisFromChat(notebookID: String, markdown: String, sourceIDs: [String]) async -> LearningGoalRecord? {
        let cleanMarkdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanMarkdown.isEmpty else {
            showToast("Nothing to save to the notebook")
            return nil
        }

        do {
            try await storage.setLearningGoalNotes(goalID: notebookID, notes:cleanMarkdown)
            let cleanSourceIDs = orderedUniqueSourceIDs(sourceIDs)
            if !cleanSourceIDs.isEmpty {
                try await storage.addCompanionSeedSources(goalID: notebookID, sourceIDs: cleanSourceIDs)
            }
            await loadLearningGoals()
            showToast("Updated the notebook")
            return notebook(id: notebookID)
        } catch {
            logger.error("Failed to replace Notebook synthesis from chat: \(error)")
            showToast("Could not update the notebook")
            return nil
        }
    }

    private func normalizedNotebookTitle(_ title: String) -> String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return "Notebook" }
        return String(cleanTitle.prefix(90))
    }

    /// Merge a new chat insight into existing Notebook notes Markdown via the AI service.
    /// Operates purely on Markdown strings.
    func generateNotebookNotesMerge(
        currentNotesMarkdown: String,
        newInsightMarkdown: String,
        notebookTitle: String
    ) async -> String? {
        let cleanInsight = newInsightMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanInsight.isEmpty else {
            showToast("Nothing to merge into the notebook")
            return nil
        }
        guard let config = KeychainService.resolveConfig(for: .notebookNotesMerge) else {
            showToast("Configure an AI model in Settings first")
            return nil
        }

        let cleanCurrentNotes = currentNotesMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = notebookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let userPrompt = """
        Merge the new chat insight into the existing Notebook notes Markdown.

        Notebook title:
        \(cleanTitle.isEmpty ? "Notebook" : cleanTitle)

        Existing Notebook notes Markdown:
        \(cleanCurrentNotes.isEmpty ? "(empty)" : cleanCurrentNotes)

        New chat insight:
        \(cleanInsight)

        Return the complete updated Notebook notes Markdown only.

        Requirements:
        - Integrate the new insight into the most relevant existing section when possible.
        - Create a meaningful new section only when the insight does not fit existing content.
        - Do not create timestamp headings such as "Chat Insight".
        - Do not duplicate claims, bullets, or sections already present.
        - Preserve useful existing content and headings.
        - Keep the result skimmable with concise headings and bullets.
        - Do not include metadata, HTML, JSON, or explanations outside the Markdown.
        """

        do {
            let merged = try await aiService.chat(
                system: "You carefully merge research chat insights into an existing Notebook notes Markdown document. Return only the complete revised Markdown.",
                messages: [(role: "user", content: userPrompt)],
                config: config,
                maxTokens: 2600
            )
            let cleaned = Self.cleanMergedNotesMarkdown(merged)
            guard !cleaned.isEmpty else {
                showToast("AI returned no changes to the notebook's notes")
                return nil
            }
            return cleaned
        } catch {
            logger.error("Failed to merge Notebook notes: \(error.localizedDescription)")
            showToast(error.localizedDescription)
            return nil
        }
    }

    private static func cleanMergedNotesMarkdown(_ response: String) -> String {
        var markdown = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if markdown.hasPrefix("```") {
            markdown = markdown.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if markdown.hasSuffix("```") {
                markdown = String(markdown.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
