import Foundation
import OSLog

// Teams in the Studio: which library is open, the roster, sharing into a team,
// and each Notebook's task board. The stored properties live on the view model
// (`activeTeamID`, `teams`, `teamMembersByTeamID`, `notebookTasksByNotebookID`);
// this file is what the rail, Settings and the Notebook page call.
extension StudioViewModel {

    // MARK: - The active library

    var activeTeam: TeamRecord? {
        guard let activeTeamID else { return nil }
        return teams.first { $0.id == activeTeamID }
    }

    /// Whether the library on screen refuses edits: a team the owner shared
    /// read-only. My Library is always the learner's to edit.
    var isActiveLibraryReadOnly: Bool {
        guard let activeTeam else { return false }
        return !activeTeam.canEdit
    }

    var activeLibraryTitle: String {
        activeTeam?.name ?? "My Library"
    }

    /// The row the source list shows for `sourceID`: the learner's own
    /// source when `sourceID` is a team's copy of it (docs/teams-design.md,
    /// decision 19), otherwise `sourceID` itself.
    func canonicalSourceID(_ sourceID: String) -> String {
        articlesStore.teamCopyAliases[sourceID] ?? sourceID
    }

    func team(id: String) -> TeamRecord? {
        teams.first { $0.id == id }
    }

    /// The teams a list of libraries or spaces names: the Space sidebar's
    /// Spaces, the Space's place menu and the account menu's switcher. In
    /// Screen record mode only those the take may show
    /// (`ScreenRecordScope.allowsTeam`), and the library on screen, which the
    /// switcher marks; `teams` stays whole for sharing and sync.
    var shownTeams: [TeamRecord] {
        guard let scope = screenRecordScope else { return teams }
        return teams.filter { team in
            team.id == activeTeamID
                || scope.allowsTeam(createdAt: team.createdAt, holdsShownItem: teamHoldsShownItem(team.id, scope: scope))
        }
    }

    /// Whether a team holds something the take may show: one of its
    /// Notebooks the scope lets on screen, or a page `artifacts` lists, which
    /// is narrowed as it loads (`loadScopedArtifacts`).
    private func teamHoldsShownItem(_ teamID: String, scope: ScreenRecordScope) -> Bool {
        learningGoals.contains { goal in
            goal.isNotebook && goal.teamID == teamID && scope.allowsNotebook(id: goal.id, createdAt: goal.createdAt)
        } || artifacts.contains { artifact in
            (artifactTeamIDs[artifact.id] ?? artifact.teamID.map { [$0] } ?? []).contains(teamID)
        }
    }

    /// The teams a share menu offers for something in My Library: every team
    /// this account may write into.
    var teamsAcceptingShares: [TeamRecord] {
        teams.filter(\.canEdit)
    }

    func loadTeams() async {
        do {
            let loaded = try await storage.loadTeams()
            if loaded != teams { teams = loaded }
            await refreshShareRequests()
            // Assignments and family plans follow the teams
            // (docs/family-design.md): who can be assigned to, what is
            // assigned here, and a family plan a team just started carrying.
            await refreshAssignableMembers()
            await refreshAssignedToMe()
            scheduleFamilyPlanSync()
            // The library on screen may have gone: the owner deleted the team,
            // or this account was removed.
            if let activeTeamID, !loaded.contains(where: { $0.id == activeTeamID }) {
                await setActiveTeam(nil)
            }
        } catch {
            logger.error("Loading teams failed: \(error.localizedDescription)")
        }
    }

    /// Switch the Studio to another library and reload everything that is
    /// scoped by it. Selections that pointed into the previous library are
    /// dropped rather than left dangling.
    func setActiveTeam(_ teamID: String?) async {
        let resolved = teamID.flatMap { id in teams.contains { $0.id == id } ? id : nil }
        guard resolved != activeTeamID else { return }
        activeTeamID = resolved
        activeNotebookId = nil
        // A notebook belongs to its library: every window holding one of the
        // library just left closes it now, before its Add sources could file
        // the new library's rows into it.
        closeNotebooksMissingFromLibrary()
        selectedArticleId = nil
        notebookTasksByNotebookID = [:]
        invalidateFilteredSidebarCache()
        // Which teams' courses the Courses home lists follows the library.
        invalidateCourseDerivedState()
        await refreshArticles()
        await loadLearningGoals()
        await loadReviewSessionLinks()
        await loadArtifacts()
        if resolved != nil {
            // The roster is what a task's assignee menu offers; read it once
            // when the team opens rather than on every Notebook page.
            if let resolved { await refreshTeamMembers(teamID: resolved) }
        }
    }

    /// A team's zone left this account. Its copies are already gone from the
    /// store; the Studio just has to stop showing it.
    func teamWasRemoved(_ teamID: String) async {
        teams.removeAll { $0.id == teamID }
        teamMembersByTeamID[teamID] = nil
        if activeTeamID == teamID {
            await setActiveTeam(nil)
            showToast("You no longer have access to that team; showing My Library")
        }
    }

    /// Docs of the active library only. Every `artifacts` load goes through
    /// here so a team's Docs never sit beside the learner's own.
    ///
    /// A member's drafts of team Docs live in My Library but belong with the
    /// team copies they draft: they are kept out of My Library's list and
    /// loaded beside the team's Docs instead, where the Docs pane opens one
    /// in place of its team copy (hidden from the list, reached through Edit).
    ///
    /// Screen record mode narrows it further (`isVisibleInRecordingMode`), so
    /// the Docs pane, the home's Docs tab and a notebook's Studio all
    /// list only what the take may show.
    func loadScopedArtifacts() async throws -> [ArtifactRecord] {
        try await loadLibraryArtifacts().filter { isVisibleInRecordingMode($0) }
    }

    private func loadLibraryArtifacts() async throws -> [ArtifactRecord] {
        let scope = activeTeamID
        guard let scope else {
            // My Library: everything this account can see — its own records
            // and the teams' — a copy of an own record counted once
            // (docs/teams-design.md, decision 18). A member's draft of a team
            // Doc opens through Edit on the team copy, never as a row.
            return try await storage.myLibraryArtifacts()
                .filter { !TeamContentIdentity.isDraftArtifactID($0.id) }
        }
        let all = try await storage.loadArtifacts()
        let teamDocs = all.filter { $0.teamID == scope }
        let draftIDs = Set(teamDocs.map {
            TeamContentIdentity.draftArtifactID(teamID: scope, teamArtifactID: $0.id)
        })
        return teamDocs + all.filter { $0.teamID == nil && draftIDs.contains($0.id) }
    }

    // MARK: - Drafts of team Docs

    /// The member's draft of a team Doc in the active library, if one exists.
    func teamDocDraftID(for teamArtifactID: String) -> String? {
        guard let activeTeamID else { return nil }
        let draftID = TeamContentIdentity.draftArtifactID(teamID: activeTeamID, teamArtifactID: teamArtifactID)
        return artifacts.contains { $0.id == draftID } ? draftID : nil
    }

    /// The team Doc a draft in the active library belongs to. A draft's id is
    /// a hash of its team copy's, so the answer is one hash per team Doc.
    func teamArtifactID(forDraft artifactID: String) -> String? {
        guard TeamContentIdentity.isDraftArtifactID(artifactID), let activeTeamID else { return nil }
        return artifacts.first { candidate in
            candidate.teamID == activeTeamID
                && TeamContentIdentity.draftArtifactID(teamID: activeTeamID, teamArtifactID: candidate.id) == artifactID
        }?.id
    }

    /// Edit a team Doc: take (or resume) a private draft of it and open that.
    func beginEditingTeamDoc(_ teamArtifactID: String) async {
        do {
            let draftID = try await storage.beginTeamDocDraft(teamArtifactID: teamArtifactID)
            await loadArtifacts()
            revealArtifact(draftID)
        } catch {
            logger.error("Starting a draft of team doc \(teamArtifactID) failed: \(error.localizedDescription)")
            showToast("Could not start a draft: \(error.localizedDescription)")
        }
    }

    /// Publish a draft over its team copy and open the copy. Throws
    /// `ArtifactError.conflict` when the team copy changed since the draft
    /// began in a way the merge cannot combine; the caller asks before
    /// publishing again with `overwrite`.
    func publishTeamDocDraft(_ draftID: String, overwrite: Bool) async throws {
        guard let teamArtifactID = teamArtifactID(forDraft: draftID) else {
            throw ArtifactError.unavailable(draftID)
        }
        let published = try await storage.publishTeamDocDraft(
            draftID: draftID,
            teamArtifactID: teamArtifactID,
            overwrite: overwrite
        )
        showToast("Published \(published.artifact.title) to \(activeLibraryTitle)")
        await loadArtifacts()
        revealArtifact(teamArtifactID)
    }

    /// Throw the draft away; the team copy stands as it is.
    func discardTeamDocDraft(_ draftID: String) async {
        let teamArtifactID = teamArtifactID(forDraft: draftID)
        do {
            try await storage.deleteArtifact(draftID)
            await loadArtifacts()
            if let teamArtifactID { revealArtifact(teamArtifactID) }
        } catch {
            logger.error("Discarding draft \(draftID) failed: \(error.localizedDescription)")
            showToast("Could not discard the draft: \(error.localizedDescription)")
        }
    }

    // MARK: - Lifecycle

    /// Creates the team and reports the outcome as a Studio toast. The error is
    /// rethrown as well, because the toast overlay lives in the Studio window
    /// and a caller in another window (Settings) has to show the failure
    /// itself or the learner sees nothing happen.
    @discardableResult
    func createTeam(name: String) async throws -> TeamRecord {
        do {
            let team = try await storage.createTeam(name: name)
            await loadTeams()
            // The roster the share came back with is already in the store;
            // without this the new card reads "0 members" until the pane is
            // reopened (seen 2026-09-07 in the Dev build).
            teamMembersByTeamID[team.id] = (try? await storage.loadTeamMembers(teamID: team.id)) ?? []
            showToast("Created team \(team.name)")
            return team
        } catch {
            logger.error("Creating a team failed: \(error.localizedDescription, privacy: .public)")
            showToast("Could not create the team: \(error.localizedDescription)")
            throw error
        }
    }

    func renameTeam(_ teamID: String, name: String) async {
        do {
            try await storage.renameTeam(teamID, name: name)
            await loadTeams()
        } catch {
            showToast("Could not rename the team: \(error.localizedDescription)")
        }
    }

    func leaveTeam(_ teamID: String) async {
        do {
            let name = team(id: teamID)?.name ?? "the team"
            try await storage.leaveTeam(teamID)
            await teamWasRemoved(teamID)
            await loadTeams()
            showToast("Left \(name)")
        } catch {
            showToast("Could not leave the team: \(error.localizedDescription)")
        }
    }

    func deleteTeam(_ teamID: String) async {
        do {
            let name = team(id: teamID)?.name ?? "the team"
            try await storage.deleteTeam(teamID)
            await teamWasRemoved(teamID)
            await loadTeams()
            showToast("Deleted \(name)")
        } catch {
            showToast("Could not delete the team: \(error.localizedDescription)")
        }
    }

    func members(of teamID: String) -> [TeamMemberRecord] {
        teamMembersByTeamID[teamID] ?? []
    }

    /// The signed-in account as the share sees it, for "assign to me" and for
    /// stamping who created a task.
    func currentMember(of teamID: String) -> TeamMemberRecord? {
        members(of: teamID).first(where: \.isCurrentUser)
    }

    func refreshTeamMembers(teamID: String) async {
        do {
            teamMembersByTeamID[teamID] = try await storage.refreshTeamMembers(teamID: teamID)
        } catch {
            // The cached roster is better than none; a fetch that failed
            // (offline, or a team with no share yet) is not worth a toast.
            if let cached = try? await storage.loadTeamMembers(teamID: teamID) {
                teamMembersByTeamID[teamID] = cached
            }
            logger.info("Team roster refresh for \(teamID) skipped: \(error.localizedDescription)")
        }
    }

    // MARK: - Sharing into a team

    func shareSources(_ sourceIDs: [String], withTeam teamID: String) async {
        guard let team = team(id: teamID) else { return }
        do {
            let copies = try await storage.shareSources(sourceIDs, withTeam: teamID)
            showToast(copies.count == 1
                ? "Shared 1 source with \(team.name)"
                : "Shared \(copies.count) sources with \(team.name)")
            if activeTeamID == teamID { await refreshArticles() }
        } catch {
            logger.error("Sharing sources with team \(teamID) failed: \(error.localizedDescription)")
            showToast("Could not share with \(team.name): \(error.localizedDescription)")
        }
    }

    // MARK: - Share requests

    /// Re-read the open requests: the ones this Mac can answer, and every
    /// open one by team for the cards. Called when teams load and when the
    /// team zones deliver a change.
    func refreshShareRequests() async {
        do {
            fulfillableShareRequests = try await storage.fulfillableShareRequests()
            let open = try await storage.loadOpenShareRequests()
            openShareRequestsByTeamID = Dictionary(grouping: open, by: \.teamID)
        } catch {
            logger.error("Loading share requests failed: \(error.localizedDescription)")
        }
    }

    /// The open request standing for an address in a team, from the last refresh.
    func openShareRequest(teamID: String, url: String) -> ShareRequestRecord? {
        openShareRequestsByTeamID[teamID]?.first { $0.url == url }
    }

    /// Whether this Mac could answer a request: the team is editable here and
    /// My Library holds the source.
    func canFulfil(_ request: ShareRequestRecord) -> Bool {
        fulfillableShareRequests.contains { $0.request.id == request.id }
    }

    /// Request on a card: ask the team for the source the card could not add.
    /// The answer is the card's next state.
    func requestShare(_ href: String, teamID: String, artifactID: String?, title: String? = nil) async -> ArtifactReferenceStatus {
        guard let team = team(id: teamID) else { return .failed("This team is no longer on this Mac.") }
        do {
            let request = try await storage.requestShare(
                teamID: teamID, url: href, title: title, artifactID: artifactID, requestedBy: currentMember(of: teamID)
            )
            await refreshShareRequests()
            showToast("Asked \(team.name) for the source")
            return canFulfil(request) ? .fulfillable(request) : .requested(request)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Share on a card or on the request in the strip's bell: answer with this
    /// Mac's copy.
    @discardableResult
    func fulfilShareRequest(_ requestID: String) async -> ShareRequestRecord? {
        do {
            guard let pending = try await storage.loadShareRequest(requestID) else {
                showToast("That request is gone")
                return nil
            }
            let request = try await storage.fulfilShareRequest(requestID, resolvedBy: currentMember(of: pending.teamID))
            await refreshShareRequests()
            if activeTeamID == request.teamID { await refreshArticles() }
            showToast("Shared \(request.title ?? "the source") with \(team(id: request.teamID)?.name ?? "the team")")
            return request
        } catch {
            logger.error("Fulfilling share request \(requestID) failed: \(error.localizedDescription)")
            showToast("Could not share: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func declineShareRequest(_ requestID: String) async -> ShareRequestRecord? {
        do {
            guard let pending = try await storage.loadShareRequest(requestID) else { return nil }
            let request = try await storage.declineShareRequest(requestID, resolvedBy: currentMember(of: pending.teamID))
            await refreshShareRequests()
            return request
        } catch {
            logger.error("Declining share request \(requestID) failed: \(error.localizedDescription)")
            showToast("Could not decline: \(error.localizedDescription)")
            return nil
        }
    }

    /// Answer every request this Mac can, at once — the bell's Share All.
    func fulfilAllShareRequests() async {
        for item in fulfillableShareRequests {
            _ = await fulfilShareRequest(item.request.id)
        }
    }

    func shareNotebook(
        _ notebookID: String,
        withTeam teamID: String,
        includeSources: Bool = true,
        includeDocs: Bool = true
    ) async {
        guard let team = team(id: teamID) else { return }
        do {
            _ = try await storage.shareNotebook(
                notebookID,
                withTeam: teamID,
                includeSources: includeSources,
                includeDocs: includeDocs
            )
            let title = notebook(id: notebookID)?.title ?? "the notebook"
            showToast("Shared \(title) with \(team.name)")
            if activeTeamID == teamID {
                await refreshArticles()
                await loadLearningGoals()
                await loadArtifacts()
            }
        } catch {
            logger.error("Sharing notebook \(notebookID) with team \(teamID) failed: \(error.localizedDescription)")
            showToast("Could not share with \(team.name): \(error.localizedDescription)")
        }
    }

    func shareArtifact(_ artifactID: String, withTeam teamID: String) async {
        guard let team = team(id: teamID) else { return }
        do {
            let copy = try await storage.shareArtifact(artifactID, withTeam: teamID)
            let original = artifacts.first { $0.id == artifactID }
            let title = original?.title ?? "the Page"
            // The sources it carries and cites went with it (docs/teams-design.md,
            // decision 16); the toast says how many, and whether any stayed behind.
            var toast = "Shared \(title) with \(team.name)"
            let travelled = copy.carriedSources.count
            if travelled > 0 {
                toast += travelled == 1 ? " with 1 source" : " with \(travelled) sources"
            }
            let failed = copy.carriedSources.failed.count
            if failed > 0 {
                toast += failed == 1 ? "; 1 source could not be copied" : "; \(failed) sources could not be copied"
            }
            showToast(toast)
            if activeTeamID == teamID {
                await loadArtifacts()
                if travelled > 0 { await refreshArticles() }
            } else {
                await refreshArtifactTeamIDs()
            }
        } catch {
            logger.error("Sharing doc \(artifactID) with team \(teamID) failed: \(error.localizedDescription)")
            showToast("Could not share with \(team.name): \(error.localizedDescription)")
        }
    }

    /// The teams holding a copy of a Doc in My Library, for the Docs pane
    /// header. Empty while a team is the active library: a copy is not shared
    /// onward.
    func teamsHoldingDoc(_ artifactID: String) async -> [TeamRecord] {
        guard activeTeamID == nil else { return [] }
        return (try? await storage.teamsHoldingArtifact(artifactID)) ?? []
    }

    /// Open a team's record listed in My Library (decision 18): a Doc opens
    /// only from the library that holds it, so the team becomes the active
    /// library first and the record comes forward there — in `window` when
    /// one is named, since the switch awaits and a scope does not outlive it.
    func openTeamArtifact(_ artifactID: String, in window: StudioWindowState? = nil) async {
        let reveal = { [self] in
            if let window { inWindow(window) { revealArtifact(artifactID) } } else { revealArtifact(artifactID) }
        }
        guard let record = artifacts.first(where: { $0.id == artifactID }), let teamID = record.teamID else {
            reveal()
            return
        }
        if activeTeamID != teamID {
            await setActiveTeam(teamID)
            guard activeTeamID == teamID else { return }
        }
        if !artifacts.contains(where: { $0.id == artifactID }) { await loadArtifacts() }
        guard artifacts.contains(where: { $0.id == artifactID }) else {
            showToast("That team no longer has this \(record.section.noun)")
            return
        }
        reveal()
    }

    /// Open a team's copy of a Doc from the original: the team becomes the
    /// active library, then its copy comes forward in Docs. A Doc opens only
    /// from the library that holds it (`open(_:)` is library-scoped), so the
    /// switch has to come first.
    func openTeamCopy(ofDoc artifactID: String, inTeam teamID: String) async {
        // Resolved before the switch: the original is in the library open now.
        guard let original = artifacts.first(where: { $0.id == artifactID }) else { return }
        guard let copyID = try? await storage.teamArtifactCopyID(teamID: teamID, original: original) else { return }
        await setActiveTeam(teamID)
        guard activeTeamID == teamID else { return }
        if !artifacts.contains(where: { $0.id == copyID }) { await loadArtifacts() }
        guard artifacts.contains(where: { $0.id == copyID }) else {
            showToast("That team no longer has this page")
            return
        }
        revealArtifact(copyID)
    }

    /// Share a course with a team (docs/teams-design.md, decision 21): the
    /// team gets its own copy of the course and everything on its path, and
    /// each member takes it with their own progress. Sharing it again brings
    /// the team's copy up to date.
    func shareCourse(_ courseID: String, withTeam teamID: String) async {
        guard let team = team(id: teamID) else { return }
        do {
            let copy = try await storage.shareCourse(courseID, withTeam: teamID)
            var toast = "Shared \(courseDisplayName(courseID)) with \(team.name)"
            let travelled = copy.carriedSources.count
            if travelled > 0 {
                toast += travelled == 1 ? " with 1 source" : " with \(travelled) sources"
            }
            let failed = copy.carriedSources.failed.count
            if failed > 0 {
                toast += failed == 1 ? "; 1 source could not be copied" : "; \(failed) sources could not be copied"
            }
            showToast(toast)
            courseTeamIDs = try await storage.loadCourseTeamIDs()
            courseMetadata = try await storage.loadCourseMetadata()
            await refreshCourseOutline()
            if activeTeamID == teamID { await refreshArticles() }
        } catch {
            logger.error("Sharing course \(courseID) with team \(teamID) failed: \(error.localizedDescription)")
            showToast("Could not share with \(team.name): \(error.localizedDescription)")
        }
    }

    /// The teams holding a copy of a course of My Library.
    func teamsHoldingCourse(_ courseID: String) async -> [TeamRecord] {
        guard courseTeamIDs[courseID] == nil else { return [] }
        return (try? await storage.teamsHoldingCourse(courseID)) ?? []
    }

    /// Open a course from the Courses home in the library that holds its
    /// sources: a team's course opens in that team's library, since its
    /// lectures and readings are the team's rows, which only a team library
    /// lists — the way a team's Doc listed in My Library opens (decision 18).
    /// The learner's own courses open wherever they are.
    func openCourseInItsLibrary(_ courseID: String, in window: StudioWindowState? = nil) async {
        if let teamID = courseTeamIDs[courseID], teamID != activeTeamID {
            await setActiveTeam(teamID)
            guard activeTeamID == teamID else { return }
        }
        guard allCourseGroupNames.contains(courseID) else {
            showToast("That team no longer has this course")
            return
        }
        openCourse(courseID, in: window)
    }

    func shareChat(_ sessionID: String, withTeam teamID: String) async {
        guard let team = team(id: teamID) else { return }
        do {
            // A chat filed under a Notebook the team also holds lands beneath the
            // team's copy of that Notebook.
            let session = reviewSessionLinks.first { $0.id == sessionID }
            let teamNotebookID = session?.goalID.map {
                TeamContentIdentity.notebookID(teamID: teamID, originalNotebookID: $0)
            }
            var resolvedNotebook: String?
            if let teamNotebookID {
                let goals = try await storage.loadLearningGoals()
                if goals.contains(where: { $0.id == teamNotebookID }) {
                    resolvedNotebook = teamNotebookID
                }
            }
            _ = try await storage.shareChat(sessionID, withTeam: teamID, notebookID: resolvedNotebook)
            showToast("Shared the transcript with \(team.name)")
            if activeTeamID == teamID { await loadReviewSessionLinks() }
        } catch {
            logger.error("Sharing chat \(sessionID) with team \(teamID) failed: \(error.localizedDescription)")
            showToast("Could not share with \(team.name): \(error.localizedDescription)")
        }
    }

    // MARK: - Tasks

    func tasks(for notebookID: String) -> [NotebookTaskRecord] {
        notebookTasksByNotebookID[notebookID] ?? []
    }

    func loadNotebookTasks(notebookID: String) async {
        do {
            notebookTasksByNotebookID[notebookID] = try await storage.loadNotebookTasks(notebookID: notebookID)
        } catch {
            logger.error("Loading tasks for \(notebookID) failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func saveNotebookTask(_ task: NotebookTaskRecord) async -> NotebookTaskRecord? {
        do {
            var stamped = task
            if stamped.createdByRecordName == nil, let teamID = notebook(id: task.notebookID)?.teamID,
               let me = currentMember(of: teamID) {
                stamped.createdByRecordName = me.userRecordName
                stamped.createdByDisplayName = me.displayName
            }
            let saved = try await storage.saveNotebookTask(stamped)
            await loadNotebookTasks(notebookID: task.notebookID)
            return saved
        } catch {
            logger.error("Saving task \(task.id) failed: \(error.localizedDescription)")
            showToast("Could not save the task: \(error.localizedDescription)")
            return nil
        }
    }

    func deleteNotebookTask(_ taskID: String, notebookID: String) async {
        do {
            try await storage.deleteNotebookTask(taskID)
            await loadNotebookTasks(notebookID: notebookID)
        } catch {
            logger.error("Deleting task \(taskID) failed: \(error.localizedDescription)")
            showToast("Could not delete the task: \(error.localizedDescription)")
        }
    }

    /// How many tasks a Notebook still has open, and how many of those are the
    /// signed-in member's, for the inspector summary and the rail badge.
    func openTaskSummary(for notebookID: String) -> (open: Int, mine: Int) {
        let tasks = tasks(for: notebookID).filter { $0.status != .done }
        let me = notebook(id: notebookID)?.teamID.flatMap { currentMember(of: $0)?.userRecordName }
        let mine = me.map { id in tasks.filter { $0.assigneeRecordName == id }.count } ?? 0
        return (tasks.count, mine)
    }
}
