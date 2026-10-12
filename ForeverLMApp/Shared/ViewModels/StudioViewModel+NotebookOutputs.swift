import Foundation

// MARK: - A notebook's outputs, from what the view model holds
//
// The Studio column's list (`NotebookOutputs`, the pure part): this extension
// gathers its inputs from what is in memory — the library's records, its
// courses, the explainers its articles index — and the two things read from
// storage off the main actor, the notebook's walkthroughs and the courses it
// follows. And it opens an output where its kind opens.

extension StudioViewModel {
    /// The notebook's own sources as derived outputs read them, named as the
    /// library lists them (`canonicalSourceID`): a walkthrough or explainer
    /// is kept against the learner's own row, never a team copy's id.
    func notebookOutputMemberIDs(_ notebook: LearningGoalRecord) -> Set<String> {
        Set(notebook.approvedSourceIDs.map { canonicalSourceID($0) })
    }

    /// What the Studio column lists for `notebookID`, newest first: the
    /// records filed in it, the courses it follows, and the walkthroughs and
    /// spoken explainers of its sources and the videos it holds (`NotebookOutputs.outputs`).
    /// `walkthroughs` and `linkedCourseIDs` are what the column read from
    /// storage (`notebookWalkthroughs`, `notebookLinkedCourseIDs`); `runs` are
    /// the audio overviews being written. Reads only what is in memory, so a
    /// view body may ask; screen record mode already scoped the records, and
    /// scopes the explainers here.
    func notebookOutputs(
        notebookID: String,
        walkthroughs: [PaperWalkthroughSummary] = [],
        linkedCourseIDs: Set<String> = [],
        runs: [NotebookOutputs.Run] = [],
        cardRuns: [NotebookOutputs.CardRun] = [],
        pictures: [NotebookOutputs.Picture] = [],
        narrations: [NotebookOutputs.Narration] = []
    ) -> [NotebookOutput] {
        guard let notebook = notebook(id: notebookID) else { return [] }
        let members = notebookOutputMemberIDs(notebook)
        let explainers: [NotebookOutputs.Explainer] = members.compactMap { sourceID in
            guard let explainer = explainer(explaining: sourceID),
                  isVisibleInRecordingMode(explainer),
                  isVisibleInRecordingMode(createdAt: explainer.dateAdded) else { return nil }
            return NotebookOutputs.Explainer(
                id: explainer.id,
                explainedSourceID: sourceID,
                title: displayTitle(for: explainer),
                date: explainer.dateAdded
            )
        }
        let videos: [NotebookOutputs.VideoOverview] = members.compactMap { sourceID in
            guard let video = articlesById[sourceID],
                  GeneratedExplainerVideo.isVideoURL(video.url),
                  isVisibleInRecordingMode(video),
                  isVisibleInRecordingMode(createdAt: video.dateAdded) else { return nil }
            return NotebookOutputs.VideoOverview(
                sourceID: sourceID,
                title: displayTitle(for: video),
                date: video.dateAdded
            )
        }
        let walks: [NotebookOutputs.Walkthrough] = walkthroughs.compactMap { walk in
            guard let article = articlesById[walk.sourceID],
                  isVisibleInRecordingMode(createdAt: walk.generatedAt) else { return nil }
            return NotebookOutputs.Walkthrough(
                sourceID: walk.sourceID,
                title: walk.title.isEmpty ? displayTitle(for: article) : walk.title,
                date: walk.generatedAt
            )
        }
        let shownCourses = Set(visibleCourseGroupNames)
        let courses: [NotebookOutputs.Course] = linkedCourseIDs.filter(shownCourses.contains).map { courseID in
            let sourceIDs = sourceIDsForGroupInOrder(courseID)
            return NotebookOutputs.Course(
                id: courseID,
                title: courseDisplayName(courseID),
                sourceIDs: sourceIDs,
                date: sourceIDs.compactMap { articlesById[$0]?.dateAdded }.max()
            )
        }
        return NotebookOutputs.outputs(
            in: notebookID,
            memberSourceIDs: members,
            records: artifacts.filter { isVisibleInRecordingMode($0) },
            audioOverviewIDs: articlesStore.audioOverviewArtifactIDs,
            runs: runs,
            courses: courses,
            linkedCourseIDs: linkedCourseIDs,
            walkthroughs: walks,
            explainers: explainers,
            videoOverviews: videos,
            cardRuns: cardRuns.filter { isVisibleInRecordingMode(createdAt: $0.draftedAt) },
            pictures: pictures,
            narrations: narrations.filter { isVisibleInRecordingMode(createdAt: $0.date) }
        )
    }

    /// The Make Cards runs on the notebook's own sources, read off the main
    /// actor from just their draft decks (`NotebookOutputs.cardRuns`). None
    /// in a team library, whose decks are each member's own; none from a
    /// read that failed, which is logged.
    func notebookCardRuns(notebookID: String) async -> [NotebookOutputs.CardRun] {
        guard activeTeamID == nil, let notebook = notebook(id: notebookID) else { return [] }
        let members = notebookOutputMemberIDs(notebook)
        do {
            let decks = try await storage.loadCardDrafts(forSourceIDs: members)
            return NotebookOutputs.cardRuns(screenRecordScope?.scopedCardDrafts(decks) ?? decks, memberSourceIDs: members)
        } catch {
            logger.error("Reading a notebook's card runs failed: \(error.localizedDescription)")
            return []
        }
    }

    /// The walkthroughs of the notebook's own sources, read off the main
    /// actor for just those sources, as screen record mode allows. None in a
    /// team library: a walkthrough rides its source, which is the learner's
    /// own.
    func notebookWalkthroughs(notebookID: String) async -> [PaperWalkthroughSummary] {
        guard activeTeamID == nil, let notebook = notebook(id: notebookID) else { return [] }
        let members = Array(notebookOutputMemberIDs(notebook))
        let loaded: [PaperWalkthroughSummary]
        do {
            loaded = try await storage.paperWalkthroughSummaries(forSources: members)
        } catch {
            logger.error("Reading a notebook's walkthroughs failed: \(error.localizedDescription)")
            return []
        }
        let scope = screenRecordScope
        return loaded.filter { scope?.allowsSourceDerived(createdAt: $0.generatedAt, sourceID: $0.sourceID) ?? true }
    }

    /// The courses the notebook follows (`notebook_course_links`).
    func notebookLinkedCourseIDs(notebookID: String) async -> Set<String> {
        do {
            return Set(try await storage.linkedCourseIDsForNotebook(goalID: notebookID))
        } catch {
            logger.error("Reading a notebook's courses failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Opens an output where its kind opens, in `windowState` — the window
    /// its row was clicked in, named because opening can await. In a window
    /// holding a notebook every kind lands in the document slot: a Doc, Site
    /// or animation in its canvas (`revealArtifact`; a Doc filed in the
    /// notebook in the notebook's own Docs), a course in its page, and a
    /// walkthrough, an explainer or an audio overview's script in the Reader
    /// — a walkthrough with its walk playing in the chat beside it, a
    /// narration with its source read aloud. A team's
    /// record listed in My Library opens in its team's library; an overview
    /// still being written opens nothing.
    func openNotebookOutput(_ output: NotebookOutput, in windowState: StudioWindowState) async {
        switch output.kind {
        case .cards:
            // The run's cards wait in To Check, narrowed to the notebook.
            openCardsToCheck(
                scope: windowState.notebook.map { MemoryReviewScope.notebook($0.notebookID) } ?? .allNotebooks,
                in: windowState
            )
        case .picture:
            // A picture opens in its sheet, which the Studio column draws
            // (`NotebookStudioColumn`); nothing here to open it in.
            break
        case .doc, .site, .animation, .mnemonicReading:
            if let teamID = output.teamID, teamID != activeTeamID {
                await openTeamArtifact(output.targetID, in: windowState)
            } else {
                revealArtifact(output.targetID, in: windowState)
            }
        case .audioOverview:
            guard !output.isPending else { return }
            let carrierID = GeneratedAudioOverview.carrierSourceID(artifactID: output.targetID)
            guard articlesById[carrierID] != nil else {
                showToast("This audio overview's script has not reached this Mac yet")
                return
            }
            await selectArticle(carrierID, in: windowState, revealingReader: true)
        case .course:
            await openCourseInItsLibrary(output.targetID, in: windowState)
        case .walkthrough:
            guard articlesById[output.targetID] != nil else {
                showToast("The source this walkthrough is of is not in this library")
                return
            }
            await selectArticle(output.targetID, in: windowState, revealingReader: true)
            inWindow(windowState) { requestWalkthroughPlayback(for: output.targetID) }
        case .narration:
            // The source in the Reader, and its narration playing: a
            // narration is listened to, not looked at.
            guard let article = articlesById[output.targetID] else {
                showToast("The source this narration is of is not in this library")
                return
            }
            await selectArticle(output.targetID, in: windowState, revealingReader: true)
            ArticleSpeechService.shared.startTextToSpeech(article: article)
        case .videoOverview:
            guard articlesById[output.targetID] != nil else {
                showToast("This video is not in this library")
                return
            }
            await selectArticle(output.targetID, in: windowState, revealingReader: true)
        case .explainer:
            if let explained = output.sourceIDs.first {
                await openExplainer(output.targetID, explaining: explained, in: windowState)
            } else {
                await selectArticle(output.targetID, in: windowState, revealingReader: true)
            }
        }
    }

    /// Opens an explainer in `windowState`'s Reader. An explainer has no
    /// row of its own, so the source it explains stays selected as its
    /// list's account of what the Reader shows — before the open, as the
    /// source's own Open Explainer selects it, and again after it, since
    /// opening in a window that is not key selects the opened id there.
    func openExplainer(_ explainerID: String, explaining sourceID: String, in windowState: StudioWindowState) async {
        let selection: Set<String> = [sourceID]
        windowState.sidebarSelectedSourceIDs = selection
        await selectArticle(explainerID, in: windowState, revealingReader: true)
        if windowState.sidebarSelectedSourceIDs != selection { windowState.sidebarSelectedSourceIDs = selection }
    }

    /// Whether an output's row offers Remove from Notebook: a Doc, Site or
    /// animation of the open library, in a notebook that takes changes. A
    /// course, a walkthrough or an explainer is the notebook's through what
    /// it holds, not through a link of its own, and an audio overview's row
    /// offers Delete instead (`AudioOverviewOutputRow`).
    func canRemoveFromNotebook(_ output: NotebookOutput, notebookID: String) -> Bool {
        guard [.doc, .site, .animation, .mnemonicReading].contains(output.kind), output.teamID == activeTeamID else { return false }
        return notebookTakesMadeThings(notebookID)
    }
}
