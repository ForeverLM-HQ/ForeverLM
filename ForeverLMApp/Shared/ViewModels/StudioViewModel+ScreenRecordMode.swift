// Screen record mode: which items are visible while recording.

import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

extension StudioViewModel {

    var isScreenRecordModeActive: Bool {
        screenRecordScope != nil
    }

    /// Re-derives `screenRecordScope` from the setting and the loaded
    /// Notebooks. Called on `ScreenRecordMode.didChangeNotification` (Studio
    /// windows subscribe) and after every Notebooks load.
    func refreshScreenRecordScope() {
        let goals = learningGoals
        let next = ScreenRecordScope.resolve(
            notebookSourceIDs: { notebookID in
                goals.first { $0.id == notebookID }?.approvedSourceIDs ?? []
            },
            takeSourceIDs: { cutoff in
                goals.filter { $0.createdAt >= cutoff }.flatMap(\.approvedSourceIDs)
            }
        )
        guard next != screenRecordScope else {
            // A Notebooks load can change which courses the recording Notebook follows.
            refreshScreenRecordShownCourses()
            return
        }
        screenRecordScope = next
        invalidateSidebarCachesInEveryWindow()
        // Docs, Sites and Animations are filtered as they load, so the list
        // in memory has to be read again under the new scope.
        guard hasLoadedArtifactsOnce else { return }
        Task { [weak self] in
            guard let self, let reloaded = try? await self.loadScopedArtifacts() else { return }
            self.artifacts = reloaded
        }
    }

    /// Whether a row draws its relative date while recording: only a date from
    /// the take (`ScreenRecordScope.showsDateStamp`); every date when the mode is off.
    func showsDateStamp(_ date: Date) -> Bool {
        screenRecordScope?.showsDateStamp(date) ?? true
    }

    func isVisibleInRecordingMode(createdAt: Date) -> Bool {
        screenRecordScope?.allowsItem(createdAt: createdAt) ?? true
    }

    /// A chat shows while recording only when it was started during the take
    /// (`ScreenRecordScope.allowsItem`, 560f8a8): being filed under the
    /// recording Notebook or about a filmed source is not enough.
    func isVisibleInRecordingMode(_ session: ReviewSessionRecord) -> Bool {
        screenRecordScope?.allowsItem(
            createdAt: session.createdAt,
            notebookIDs: recordingNotebookIDs(linkedTo: [session.goalID])
        ) ?? true
    }

    /// A Doc, Site or Animation shows while recording only when it was made
    /// during the take: being filed under or linked to the recording Notebook,
    /// or citing a filmed source, is not enough.
    func isVisibleInRecordingMode(_ artifact: ArtifactRecord) -> Bool {
        screenRecordScope?.allowsItem(
            createdAt: artifact.createdAt,
            notebookIDs: NotebookMembership.filingNotebookIDs(of: artifact)
        ) ?? true
    }

    /// An Idea shows while recording only when it was jotted during the take.
    func isVisibleInRecordingMode(_ idea: IdeaRecord) -> Bool {
        screenRecordScope?.allowsItem(
            createdAt: idea.createdAt,
            notebookIDs: recordingNotebookIDs(linkedTo: NotebookMembership.filingNotebookIDs(of: idea))
        ) ?? true
    }

    /// A canvas shows while recording only when it was made during the take,
    /// whatever Notebook it belongs to or is placed on it: its name and
    /// layout are the learner's.
    func isVisibleInRecordingMode(_ canvas: KnowledgeMapCanvas) -> Bool {
        screenRecordScope?.allowsItem(
            createdAt: canvas.createdAt,
            notebookIDs: recordingNotebookIDs(linkedTo: [canvas.notebookID])
        ) ?? true
    }

    /// A list of goals or ideas shows while recording only when it was made
    /// during the take: it is filed under no Notebook, and its name is the
    /// learner's own whatever it holds.
    func isVisibleInRecordingMode(_ list: SpaceList) -> Bool {
        isVisibleInRecordingMode(createdAt: list.createdAt)
    }

    /// The Notebook ids an item linked to `goalIDs` is filed under: the ids
    /// themselves and each Goal's parent Notebook, so work filed under a Goal
    /// nested in the recording Notebook counts as filed under the Notebook —
    /// the notebook rule (`NotebookMembership.filingNotebookIDs`), which
    /// `MCPDataStore.screenRecordNotebookIDs` answers for MCP too.
    private func recordingNotebookIDs(linkedTo goalIDs: [String?]) -> [String?] {
        var parents: [String: String] = [:]
        for goalID in goalIDs.compactMap({ $0 }) where parents[goalID] == nil {
            if let parent = learningGoals.first(where: { $0.id == goalID })?.parentNotebookID {
                parents[goalID] = parent
            }
        }
        return NotebookMembership.filingNotebookIDs(goalIDs, goalParents: parents)
    }

    /// A source shows while recording when it belongs to the recording
    /// Notebook, was safely captured during the take, or is public with library
    /// sources on (`ScreenRecordScope.isPublicLibrarySource`).
    func isVisibleInRecordingMode(_ article: StudioArticle) -> Bool {
        screenRecordScope?.allowsSource(
            id: article.id, addedAt: article.dateAdded,
            kind: article.sourceType.rawValue, url: article.url,
            group: article.parentGroup.map(canonicalMeetingGroupID),
            show: article.domain,
            origin: article.discoveryOrigin
        ) ?? true
    }

    /// The same question by id, for rows that carry only a source id (the
    /// Today card, Planner blocks). An id the library does not hold is kept
    /// off screen: there is no date to let it through.
    func isSourceIDVisibleInRecordingMode(_ sourceID: String) -> Bool {
        guard let scope = screenRecordScope else { return true }
        if scope.allowedSourceIDs.contains(sourceID) { return true }
        guard let article = articlesById[sourceID] else { return false }
        return isVisibleInRecordingMode(article)
    }

}
