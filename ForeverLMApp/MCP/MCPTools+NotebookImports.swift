import Foundation
import OSLog

// MARK: - Filing an import in a Notebook
//
// add_source, add_sources and import_paper_from_url take an optional
// notebook_id: the library source an import produced, or the one it found
// already there, joins that Notebook in the same call, the way an import made
// from inside a notebook in the app lands in that notebook
// (docs/notebooks-design.md, "Imports").
//
// The source id is final when each import returns — addSource saves its row,
// the paper import saves only after its metadata model — so membership is
// written at once, and a later identity merge carries it
// (`archivePaperIdentityDuplicate`). The id is used only as given: never a
// window's notebook (`MCPAppWindows`, which get_app_context alone reads), never
// matched by title, and it is checked before anything is imported. What the call did
// with it is said after the import's own answer, never before: the
// recordings mailbox reads "(id: src_…" out of add_source's answer
// (workers/mcp-gateway/src/inbound-mail.ts).

extension MCPDataStore {

    /// The Notebook an import names, checked before anything is imported. nil
    /// when notebook_id is absent or blank (models fill unused slots with "").
    /// A Goal is accepted as `import_review_chat` accepts one
    /// (`resolveMCPChatHome`): a chat filed under a Goal pins the Goal's id
    /// on the imports it asks for, and a Goal's additions reach its Notebook
    /// (`KnowledgeStore.addCompanionSeedSources`). An archived Notebook, and a
    /// team's Notebook this account can only read, refuse the whole call.
    func notebookForImport(notebookID rawNotebookID: String?) throws -> LearningGoalRecord? {
        guard let raw = Self.nilIfBlank(rawNotebookID ?? "") else { return nil }
        let store = try knowledgeStore()
        let notebook = try resolveMCPChatHome(notebookID: raw, store: store)
        guard !notebook.isArchived else {
            throw MCPError.invalidInput(
                "‘\(notebook.title)’ (\(notebook.id)) is archived, so nothing was added. Restore it first, or leave notebook_id out to add to the library only."
            )
        }
        try requireNotebookTeamTakesSources(notebook, store: store)
        return notebook
    }

    /// A team's notebook takes sources only while its team is on this Mac and
    /// this account may edit it (`NotebookImportRefusal.teamRefusal`). Throws
    /// before anything is filed; nothing for a personal notebook.
    func requireNotebookTeamTakesSources(_ notebook: LearningGoalRecord, store: KnowledgeStore) throws {
        guard let teamID = notebook.teamID else { return }
        let team = try store.loadTeam(teamID)
        guard let refusal = NotebookImportRefusal.teamRefusal(for: notebook, team: team) else { return }
        if case .readOnlyTeam = refusal, let team {
            throw MCPError.invalidInput(readOnlyRefusal(team, action: "add sources to ‘\(notebook.title)’") + " Nothing was added.")
        }
        throw MCPError.invalidInput(
            "‘\(notebook.title)’ belongs to team \(teamID), which is not on this Mac, so nothing was added. Call list_teams."
        )
    }

    /// The library row an import produced or matched, found by the address it
    /// deduplicated on — never parsed out of the answer. My Library's active
    /// row first; for a team's Notebook, the team's own row next; then any row
    /// at that address (an archived one), so filing can say why it was left
    /// out.
    func importedLibrarySourceID(url: String, notebook: LearningGoalRecord, store: KnowledgeStore) -> String? {
        if let own = store.activeSourceID(matchingAddress: url, teamID: nil) { return own }
        if let teamID = notebook.teamID, let held = store.activeSourceID(matchingAddress: url, teamID: teamID) {
            return held
        }
        return (store.sourceExistsByNormalizedURL(URLNormalizer.normalize(url)) ?? store.sourceExistsByURL(url))?.id
    }

    /// What filing did with each source an import named.
    struct NotebookFiling: Equatable {
        struct Refusal: Equatable {
            let sourceID: String
            let reason: String
        }

        var filed: [String] = []
        var alreadyIn: [String] = []
        var refused: [Refusal] = []

        /// The line said after an import's own answer. `notebook_id_applied`
        /// is the Notebook's id when the source is in it now, and `none`
        /// otherwise. A batch counts; a single import says what happened.
        func answer(for notebook: LearningGoalRecord, batch: Bool) -> String {
            let name = "\(notebook.isGoal ? "Goal" : "Notebook") ‘\(notebook.title)’"
            let applied = filed.isEmpty && alreadyIn.isEmpty ? "none" : notebook.id
            let reasons = refused.map { "\($0.sourceID): \($0.reason)" }.joined(separator: "; ")
            let detail: String
            if batch {
                let notFiled = refused.isEmpty ? "\(refused.count) not filed" : "\(refused.count) not filed (\(reasons))"
                detail = "\(name): \(filed.count) filed, \(alreadyIn.count) already in it, \(notFiled)."
            } else if !filed.isEmpty {
                detail = "filed in \(name)."
            } else if !alreadyIn.isEmpty {
                detail = "already in \(name)."
            } else if let refusal = refused.first {
                detail = "not filed in \(name): \(refusal.reason)."
            } else {
                detail = "nothing was added, so nothing joined \(name)."
            }
            return "notebook_id_applied: \(applied) — \(detail)"
        }

        /// "Not added: src_1 (the source is archived; …)." for the sources an
        /// add by id could not file; nil when each was filed or already in.
        var notAddedSentence: String? {
            guard !refused.isEmpty else { return nil }
            return "Not added: " + refused.map { "\($0.sourceID) (\($0.reason))" }.joined(separator: "; ") + "."
        }
    }

    /// Files sources in a Notebook through the app's own write
    /// (`StorageService.addCompanionSeedSources`): a team's Notebook gets the
    /// team's copy, file included (`sourceIDsForGoalLibrary`), sync is
    /// scheduled, and every editable team holding a personal Notebook receives
    /// the addition (docs/teams-design.md, decision 10). Never throws: the
    /// import has already happened, so what did not join is said, not raised.
    func fileImportedSources(_ sourceIDs: [String], in notebook: LearningGoalRecord) async -> NotebookFiling {
        let ids = sanitizedSourceIDs(sourceIDs)
        guard !ids.isEmpty else { return NotebookFiling() }
        do {
            // Each source as the Notebook will hold it: its own id, or for a
            // team's Notebook the team's copy of it.
            let checked = try await withStoreGate(.shared) { () -> (filing: NotebookFiling, fresh: [(id: String, heldAs: String)], before: [String: Set<String>]) in
                let store = try knowledgeStore()
                let held = Set((try store.loadLearningGoal(notebook.id) ?? notebook).approvedSourceIDs)
                // What each pool the write reaches held before it: the
                // notebook's, and its Notebook's for a Goal, whose additions
                // reach the Notebook too. The difference is what arrives.
                var before = [notebook.id: held]
                if let parentID = notebook.parentNotebookID, let parent = try store.loadLearningGoal(parentID) {
                    before[parentID] = Set(parent.approvedSourceIDs)
                }
                var filing = NotebookFiling()
                var fresh: [(id: String, heldAs: String)] = []
                for requestedID in ids {
                    guard var source = try store.loadSourceWithoutContent(requestedID), source.status == .active else {
                        filing.refused.append(.init(sourceID: requestedID, reason: "the source is archived; unarchive_source brings it back"))
                        continue
                    }
                    // A personal notebook holds the learner's own row: a team's
                    // copy of the same paper stands in for it only until the
                    // own row is found by address.
                    var id = requestedID
                    if notebook.teamID == nil, source.teamID != nil,
                       let own = store.activeSourceID(matchingAddress: source.url, teamID: nil),
                       let ownSource = try store.loadSourceWithoutContent(own) {
                        id = own
                        source = ownSource
                    }
                    let heldAs: String
                    if let teamID = notebook.teamID, source.teamID != teamID {
                        guard source.teamID == nil else {
                            filing.refused.append(.init(sourceID: id, reason: "the source is in another team's library"))
                            continue
                        }
                        heldAs = try store.teamSourceCopyID(teamID: teamID, url: source.url)
                    } else {
                        guard source.teamID == notebook.teamID else {
                            filing.refused.append(.init(sourceID: id, reason: "the source is in a team's library"))
                            continue
                        }
                        heldAs = id
                    }
                    if held.contains(heldAs) {
                        filing.alreadyIn.append(id)
                    } else {
                        fresh.append((id, heldAs))
                    }
                }
                return (filing, fresh, before)
            }
            var filing = checked.filing
            guard !checked.fresh.isEmpty else { return filing }
            _ = try await notebookFileStorage.addCompanionSeedSources(goalID: notebook.id, sourceIDs: checked.fresh.map(\.id))
            // Read back rather than trusted: a team copy that could not be
            // made is logged by `sourceIDsForGoalLibrary` and left out.
            let (nowHeld, arrivals) = try await withStoreGate(.shared) { () -> (Set<String>, [String: [String]]) in
                let store = try knowledgeStore()
                var nowHeld: Set<String> = []
                var arrivals: [String: [String]] = [:]
                for (poolID, held) in checked.before {
                    let approved = (try store.loadLearningGoal(poolID) ?? (poolID == notebook.id ? notebook : nil))?.approvedSourceIDs ?? []
                    if poolID == notebook.id { nowHeld = Set(approved) }
                    arrivals[poolID] = approved.filter { !held.contains($0) }
                }
                return (nowHeld, arrivals)
            }
            await tickArrivingNotebookSources(arrivals)
            for entry in checked.fresh {
                if nowHeld.contains(entry.heldAs) {
                    filing.filed.append(entry.id)
                } else {
                    let reason = notebook.teamID == nil ? "it could not be filed" : "it could not be copied into the team"
                    filing.refused.append(.init(sourceID: entry.id, reason: reason))
                }
            }
            return filing
        } catch {
            return NotebookFiling(refused: ids.map { .init(sourceID: $0, reason: error.localizedDescription) })
        }
    }

    /// `add_sources` with an optional notebook_id: every item added, updated
    /// or already there joins the Notebook, and the answer ends with how many
    /// did.
    func addSourcesFilingInNotebook(_ items: [[String: Any]], connectorLabel: String?, notebookID: String?) async throws -> String {
        guard let notebook = try await withStoreGate(.shared, { try notebookForImport(notebookID: notebookID) }) else {
            return try addSources(items, connectorLabel: connectorLabel)
        }
        let (batch, sourceIDs) = try await withStoreGate(.exclusive) { () -> (SourceBatchResult, [String]) in
            let batch = try addSourcesBatch(items, connectorLabel: connectorLabel)
            let store = try knowledgeStore()
            return (batch, batch.heldURLs.compactMap { importedLibrarySourceID(url: $0, notebook: notebook, store: store) })
        }
        let filing = await fileImportedSources(sourceIDs, in: notebook)
        return batch.text + "\n" + filing.answer(for: notebook, batch: true)
    }

    /// `import_paper_from_url` with an optional notebook_id, checked before the
    /// download starts. A paper the library already holds — by URL or DOI —
    /// joins the Notebook instead of being imported again.
    func importPaperFilingInNotebook(url: String, sourceURL: String?, title: String?, notebookID: String?) async throws -> String {
        let notebook = try await withStoreGate(.shared) { try notebookForImport(notebookID: notebookID) }
        let outcome: PaperImportOutcome
        if let sourceURL = Self.nilIfBlank(sourceURL ?? "") {
            outcome = try await importPaperFromDownloadURLOutcome(url, sourceURL: sourceURL, title: title)
        } else {
            outcome = try await importPaperFromURLOutcome(url, title: title)
        }
        guard let notebook else { return outcome.message }
        let filing = await fileImportedSources(outcome.sourceID.map { [$0] } ?? [], in: notebook)
        return outcome.message + "\n" + filing.answer(for: notebook, batch: false)
    }

    // MARK: - add_notebook_sources

    /// `add_notebook_sources`: library sources the learner chose, filed in a
    /// Notebook through the same write an import's notebook_id takes
    /// (`fileImportedSources`). A team's Notebook holds the team's copies of the
    /// learner's own sources, file included, and a team this account can only
    /// read refuses the call before anything is filed. The in-app chat calls
    /// it pinned to its own Notebook (`ReviewSessionManager.notebookScopedArguments`).
    func addNotebookSources(notebookID: String?, sourceIDs: [String]) async throws -> String {
        let ids = sanitizedSourceIDs(sourceIDs)
        let goal = try await withStoreGate(.shared) { () -> LearningGoalRecord in
            let store = try knowledgeStore()
            let goal = try resolveMCPNotebookGoal(notebookID: notebookID, store: store)
            try requireNotebookTeamTakesSources(goal, store: store)
            guard !ids.isEmpty else {
                throw MCPError.invalidInput("Provide at least one source_id to add.")
            }
            try validateSourcesExist(ids)
            return goal
        }
        let filing = await fileImportedSources(ids, in: goal)
        let detail = try await withStoreGate(.shared) {
            try companionGoalDetail(try knowledgeStore().loadLearningGoal(goal.id) ?? goal)
        }
        let count = filing.filed.count
        var lines = ["Added \(count) source\(count == 1 ? "" : "s") to Notebook ‘\(goal.title)’ (\(goal.id)) as approved\(goal.teamID != nil && count > 0 ? ", as the team's copies" : "")."]
        if !filing.alreadyIn.isEmpty {
            lines.append("Skipped \(filing.alreadyIn.count) already in the Notebook.")
        }
        if let notAdded = filing.notAddedSentence {
            lines.append(notAdded)
        }
        return lines.joined(separator: " ") + "\n\n" + detail
    }

    /// add_companion_sources and add_goal_sources on a team's Notebook or
    /// Goal: library sources put on it by id are filed as add_notebook_sources
    /// files them (`fileImportedSources`), so the pool holds the team's copies
    /// of the learner's own sources, never their ids, and a team this account
    /// can only read refuses the call before anything is filed. A personal
    /// Notebook or Goal keeps its own write.
    func fileSourcesInTeamPool(_ ids: [String], in goal: LearningGoalRecord) async throws -> NotebookFiling {
        try await withStoreGate(.shared) {
            try requireNotebookTeamTakesSources(goal, store: try knowledgeStore())
        }
        return await fileImportedSources(ids, in: goal)
    }

    // MARK: - Arriving sources come in ticked

    /// After sources joined Notebooks — `arrivals` names, per Notebook, the ids
    /// it holds now and did not before — their chat checkboxes are ticked
    /// where they arrived (`NotebookChatSelection.arrivalsToTick`), so a box
    /// unticked before a source last left the Notebook does not outlive its
    /// return. Only rows naming an arrival are read, and only a row that
    /// changes is written. Called after the store gate is let go; the open
    /// window picks the rows up through its `foreverLMDataDidChange` reload.
    func tickArrivingNotebookSources(_ arrivals: [String: [String]]) async {
        let arrived = Set(arrivals.values.joined())
        guard !arrived.isEmpty else { return }
        // Generation 2: an arrival writes a new Entry stamp, so its untick no longer matches and the
        // source is ticked with no write to the member's state (schema v2 §5.6); the snapshot is read
        // again.
        if NotebookStateStore.isActive { return NotebookStateStore.reload() }
        let rows = NotebookChatSelection.exclusionsFromDefaults().filter { !$0.value.isDisjoint(with: arrived) }
        guard !rows.isEmpty else { return }
        do {
            let updates = try await withStoreGate(.shared) { () -> [(notebookID: String, excluded: [String])] in
                let store = try knowledgeStore()
                var updates: [(notebookID: String, excluded: [String])] = []
                for (notebookID, excluded) in rows {
                    guard let notebook = try store.loadLearningGoal(notebookID), notebook.isNotebook else { continue }
                    let tick = NotebookChatSelection.arrivalsToTick(
                        in: notebook,
                        arrivals: arrivals,
                        contextNotebookIDs: NotebookChatSelection.contextNotebookIDs(
                            of: notebook,
                            putIn: NotebookChatSelection.contextNotebookIDs(notebookID: notebookID)
                        ),
                        approvedOf: { (try? store.loadLearningGoal($0))?.approvedSourceIDs }
                    )
                    guard !tick.isEmpty else { continue }
                    let next = NotebookChatSelection.updated(
                        excluded,
                        setting: tick,
                        inChat: true,
                        pool: try store.notebookContextSourceIDs(notebookID: notebookID)
                    )
                    if Set(next) != excluded { updates.append((notebookID, next)) }
                }
                return updates
            }
            guard !updates.isEmpty else { return }
            for update in updates {
                NotebookChatSelection.write(update.excluded, notebookID: update.notebookID)
            }
            await PreferenceStore.flushPendingWrites()
        } catch {
            // The filing stands; a box left unticked is the learner's to tick.
            logger.error("Could not tick arriving Notebook sources: \(error.localizedDescription, privacy: .public)")
        }
    }
}
