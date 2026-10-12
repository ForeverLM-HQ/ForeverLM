import Foundation

// MARK: - Homing: what lives in which notebook (docs/notebooks-design.md, "Homing")
//
// The view model's side of the learner's work that lives in notebooks, and of
// what lives in none, and of the one optional tie between a course and a
// notebook: following (docs/courses-design.md, "A course is its own thing").
// A course lives in no notebook; a notebook may follow it, and "Make Study
// Notebook" makes one that does. Store writes go through `StorageService`;
// the surfaces that call these (a course's page and menus, the Artifacts
// index's notebook filter with "Not in a notebook" and its cards' Add to
// Notebook ▸) decide what to say, in Notebook words
// (`CourseNotebookError.learnerMessage`). Nothing here runs on launch:
// opening the app, or a notebook, writes nothing.

extension StudioViewModel {

    /// Reads which notebooks follow which course again, after a write that
    /// moves links: a course linked or unlinked, a notebook deleted or merged.
    func reloadCourseFollowers() async {
        do {
            courseFollowerNotebookIDs = try await storage.loadCourseFollowers()
        } catch {
            logger.error("Failed to load the notebooks following courses: \(error.localizedDescription)")
        }
    }

    /// The notebooks of the open library that follow a course, by title.
    func notebooksFollowingCourse(_ courseID: String) -> [LearningGoalRecord] {
        let ids = Set(courseFollowerNotebookIDs[courseID] ?? [])
        guard !ids.isEmpty else { return [] }
        return notebooks.filter { ids.contains($0.id) }.sorted(by: NotebooksHomeSort.titleOrder)
    }

    /// Link to Notebook ▸ on a course, as the learner asked it: the notebook
    /// follows the course and gains its sources, then one toast says so. A
    /// refusal says why in the learner's words.
    func followCourseFromMenu(_ courseID: String, inNotebook notebookID: String) async {
        do {
            try await storage.followCourse(courseID: courseID, notebookID: notebookID)
            learningGoals = try await storage.loadLearningGoals()
            await reloadCourseFollowers()
            noteNotebookWork(notebookID)
            if let notebook = notebook(id: notebookID) {
                showToast("\(courseDisplayName(courseID)) is linked to \(NotebookTitle(notebook.title).text)")
            }
        } catch {
            errorMessage = CourseNotebookError.learnerMessage(for: error)
            logger.error("Failed to link course \(courseID, privacy: .public) to a notebook: \(error.localizedDescription)")
        }
    }

    /// Unlink from <Notebook> on a course: the notebook stops following it, so
    /// lectures the course gains no longer join it. The sources the notebook
    /// already holds stay.
    func unfollowCourseFromMenu(_ courseID: String, inNotebook notebookID: String) async {
        do {
            try await storage.unlinkCourseFromNotebook(goalID: notebookID, courseID: courseID)
            learningGoals = try await storage.loadLearningGoals()
            await reloadCourseFollowers()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to unlink course \(courseID, privacy: .public) from a notebook: \(error.localizedDescription)")
        }
    }

    /// Make Study Notebook on a course: a notebook named after the course,
    /// holding its sources and following it, opened in `windowState`. The
    /// course stays what it was; the notebook is a place to ask, search and
    /// make things around it. Asked again, it opens the notebook it made.
    func makeStudyNotebook(forCourse courseID: String, in windowState: StudioWindowState) async {
        do {
            let made = try await storage.makeStudyNotebook(courseID: courseID)
            learningGoals = try await storage.loadLearningGoals()
            await reloadCourseFollowers()
            inWindow(windowState) { openNotebook(made.notebookID, in: windowState) }
            if made.created { showToast("Made a notebook for studying \(courseDisplayName(courseID))") }
        } catch {
            errorMessage = CourseNotebookError.learnerMessage(for: error)
            logger.error("Failed to make a study notebook for \(courseID, privacy: .public): \(error.localizedDescription)")
        }
    }

    // MARK: Homing on screen (shell stage 4)

    /// The notebooks an Add to Notebook ▸ menu offers for a thing riding
    /// `sourceIDs`: the open library's notebooks that take new things
    /// (`importableNotebook`), those holding most of its sources first
    /// (`NotebookMembership.suggestions`), then the rest by title, leaving out
    /// the notebooks it lives in already (`livesIn`).
    func notebookChoices(forSourceIDs sourceIDs: [String], livesIn: Set<String> = []) -> [NotebookMenuChoices.Choice] {
        let open = notebooks.filter { importableNotebook($0.id) != nil }
        let candidates = open.map {
            NotebookMembership.Candidate(notebookID: $0.id, sourceIDs: $0.approvedSourceIDs, createdAt: $0.createdAt)
        }
        return NotebookMenuChoices.ordered(
            notebooks: open.map { (id: $0.id, title: $0.title) },
            suggestions: NotebookMembership.suggestions(for: sourceIDs, among: candidates),
            excluding: livesIn
        )
    }

    /// The open library's notebooks a Docs tab entry or a picture lives in
    /// (`NotebookIndexFiling.notebooks`), read against the sidebar's
    /// membership index and each Goal's Notebook.
    func notebooksHolding(_ filing: NotebookIndexFiling) -> Set<String> {
        let context = notebookHoldingContext
        return filing.notebooks(
            among: context.notebookIDs,
            members: notebookMemberSourceIDsByNotebook,
            goalParents: context.goalParents
        )
    }

    /// What `notebooksHolding` reads off the notebooks and Goals: the open
    /// library's notebook ids and each Goal's Notebook. The Space asks once
    /// per item it lists while a notebook filter is on, so these are built
    /// once per change to the notebook lists (`NotebookListsKey`), not per item.
    struct NotebookHoldingContext {
        let key: NotebookListsKey
        let notebookIDs: Set<String>
        let goalParents: [String: String]
    }

    var notebookHoldingContext: NotebookHoldingContext {
        let key = currentNotebookListsKey
        if let cached = notebookHoldingContextCache, cached.key == key {
            return cached
        }
        var goalParents: [String: String] = [:]
        for goal in learningGoals where goal.isGoal {
            if let parent = goal.parentNotebookID, !parent.isEmpty { goalParents[goal.id] = parent }
        }
        let context = NotebookHoldingContext(
            key: key,
            notebookIDs: Set(notebooks.map(\.id)),
            goalParents: goalParents
        )
        notebookHoldingContextCache = context
        return context
    }

    /// Whether a record is listed only in its notebook, and not on the home's
    /// Docs tab or in the global Docs canvas: a mnemonic reading that a
    /// notebook holds (product owner, 2026-10-06, asked whether readings should
    /// leave the Docs for their notebook alone: put them outside the Docs).
    /// A reading in no notebook — one made from a Reader outside a notebook,
    /// or whose notebooks are gone — stays on both, so it is never listed
    /// nowhere.
    func isListedOnlyInItsNotebook(_ artifact: ArtifactRecord) -> Bool {
        artifact.isMnemonicReading
            && !notebooksHolding(.filed(NotebookMembership.filingNotebookIDs(of: artifact))).isEmpty
    }

    /// Add to Notebook ▸ on a Doc, Site or animation: the record joins the
    /// notebook — its home when it had none — in one write
    /// (`setArtifactNotebookMembership`). The learner asked, so the record's
    /// change date moves as any edit's does; nothing is filed for them.
    func addArtifact(_ artifactID: String, toNotebook notebookID: String) async {
        await setArtifactNotebookMembership(artifactID, notebookID: notebookID, isMember: true)
        if let notebook = notebook(id: notebookID), artifacts.first(where: { $0.id == artifactID })?.linkedNotebookIDs.contains(notebookID) == true {
            showToast("Added to \(NotebookTitle(notebook.title).text)")
        }
    }

    /// Remove from Notebook on a Doc, Site or animation.
    func removeArtifact(_ artifactID: String, fromNotebook notebookID: String) async {
        await setArtifactNotebookMembership(artifactID, notebookID: notebookID, isMember: false)
    }

    /// Add to Notebook ▸ on an Idea: a link to the notebook, as Link… makes.
    func addIdea(_ ideaID: String, toNotebook notebookID: String) async {
        await linkIdea(ideaID: ideaID, kind: .notebook, targetIDs: [notebookID])
    }

    /// Remove from Notebook on an Idea: the notebook's link goes.
    func removeIdea(_ ideaID: String, fromNotebook notebookID: String) async {
        await unlinkIdea(ideaID: ideaID, kind: .notebook, targetIDs: [notebookID])
    }
}
