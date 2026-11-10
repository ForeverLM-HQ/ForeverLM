// Opening and revealing the reader, notebook, artifact and browser surfaces.

import Foundation
import CryptoKit
import Observation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif
import SwiftUI
import AppKit
import SQLite3
import WebKit
import Darwin

extension StudioViewModel {

    // MARK: - Surface accessors

    // Setting one of these to `false` hides only that surface — it never
    // touches what a sibling group is showing.
    var showTasksInReader: Bool {
        get { activeCenterTabs.contains(.tasks) }
        set {
            if newValue {
                activateCenterTab(.tasks)
            } else {
                deactivateCenterTab(.tasks)
            }
        }
    }

    var showNotepadInReader: Bool {
        get { activeCenterTabs.contains(.notepad) }
        set {
            if newValue {
                activateCenterTab(.notepad)
            } else {
                deactivateCenterTab(.notepad)
            }
        }
    }

    /// Brings the source reader forward in its group — the old "a source takes
    /// the slot back". Sibling groups keep whatever they are showing.
    ///
    /// One exception: when `companion` is the visible surface of the Reader's
    /// own pane — Chat, the focused state every launch starts in, or the Docs
    /// pane a source chip was clicked in — the Reader opens *beside* it
    /// instead of over it.
    /// Reading a source and talking or writing about it is the pair this app
    /// is for, and opening a source is no reason to close the conversation or
    /// the doc. The full-window Library is kept the same way: a source
    /// clicked there opens in the Reader beside it, so the list the learner
    /// is working through stays (docs/notebooks-design.md, "The full-window
    /// Library"). With the Reader's pane showing anything else, that surface
    /// is what the source takes back, exactly as before.
    func clearReaderSurfaces(
        keeping companion: StudioCenterTab = .chat,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        let destination = destinationWindowState ?? activeWindowState
        if let readerPane = destination.centerTabGroups.groups.first(where: { $0.tabs.contains(.reader) }),
           readerPane.activeTab == companion || readerPane.activeTab == .library {
            revealReader(beside: readerPane.activeTab, in: destination)
            return
        }
        activateCenterTab(.reader, in: destination)
    }

    /// The rail's Goals row. A place, like Docs: the list of what the
    /// learner is working toward, in deadline order.
    func openGoalsInReader(in destinationWindowState: StudioWindowState? = nil) {
        activateCenterTab(.goals, in: destinationWindowState ?? activeWindowState)
    }

    /// The rail's Ideas row. A place, like Goals: every thought jotted down,
    /// newest first, and the field to jot the next one.
    func openIdeasInReader(in destinationWindowState: StudioWindowState? = nil) {
        activateCenterTab(.ideas, in: destinationWindowState ?? activeWindowState)
    }

    /// The rail's Docs row. Docs is a place, not a document: clicking it
    /// lands on the index of every doc, the same view each time, rather than
    /// on whichever doc happened to be open when the pane was last shown. A
    /// doc reached from a chat or a Notebook still opens itself, through
    /// `revealArtifact`. The index shows in the window the row was clicked in
    /// (or the one named); a doc open in another Studio window stays open.
    func openNotepadInReader(in destinationWindowState: StudioWindowState? = nil) {
        let destination = destinationWindowState ?? activeWindowState
        destination.artifactCanvasNotebookID = nil
        activateCenterTab(.notepad, in: destination)
        artifactIndexRequest = ArtifactIndexRequest(
            section: .docs,
            windowID: destination.id,
            groupID: paneShowing(.notepad, in: destination)
        )
    }

    /// The rail's Sites row: the same place-not-a-page rule as Docs, for the
    /// section that holds Claude artifacts and Codex sites.
    func openSitesInReader(in destinationWindowState: StudioWindowState? = nil) {
        let destination = destinationWindowState ?? activeWindowState
        activateCenterTab(.sites, in: destination)
        artifactIndexRequest = ArtifactIndexRequest(section: .sites, windowID: destination.id)
    }

    /// The Videos pane, where an explainer film is made and played: the pane
    /// with its list and the last film selected. A film is listed in its
    /// notebook's Studio; this pane is where one opens.
    func openVideosInReader() {
        activateCenterTab(.videos)
    }

    /// The Space: every page, site, picture, idea, canvas, list, notebook and
    /// course, on the place the window last showed (`showSpace` chooses one).
    func openArtifactsInReader(in destinationWindowState: StudioWindowState? = nil) {
        let destination = destinationWindowState ?? activeWindowState
        activateCenterTab(.artifacts, in: destination)
    }

    /// Opens one of the Space's kinds in a column beside what is on screen
    /// (product owner, 2026-09-29: "make sure we can also open 2 different
    /// artifact panes side by side; e.g. docs and ideas"). The pane kept is
    /// one of those kinds already showing — another kind's first, so asking
    /// for Ideas with Docs on screen gives Docs beside Ideas, then the Docs
    /// tab the request came from. With neither on screen it opens beside
    /// the way a rail row does. A kind already on screen stays where it is.
    func openArtifactKindBeside(_ tab: StudioCenterTab) {
        let visible = centerTabGroups.groups.map(\.activeTab)
        guard !visible.contains(tab) else { return }
        let companion = visible.first { $0 != tab && StudioCenterTab.artifactKinds.contains($0) }
            ?? visible.first { $0 == .artifacts }
        if let companion {
            revealCenterTab(tab, beside: companion)
        } else {
            openCenterTabBeside(tab)
        }
    }

    /// The rail's Browser row: the pane with whatever tabs it had.
    func openBrowserInReader() {
        activateCenterTab(.browser)
    }

    /// Opens a page in the Browser pane, in a new tab. The Library profile
    /// unless a profile is named, so a page saved from the tab lands where
    /// the readers can use its cookies.
    func openInBrowser(_ url: URL, profileID: UUID? = nil) {
        activateCenterTab(.browser)
        browserOpenRequest = BrowserOpenRequest(url: url, profileID: profileID)
    }

    /// Brings a specific doc forward — the way back from a chat to the passage
    /// it started on, an output of a notebook's Studio, a doc's link. A doc
    /// filed in the notebook the window holds opens in the notebook's own
    /// Docs (`docsCanvasScope`); any other doc in the global canvas, never in
    /// one scoped to a Notebook it is not filed under, which would silently
    /// show nothing. A Claude artifact or a Codex site comes forward in
    /// Sites, a Markdown doc or a Google Doc in Docs; a record this window
    /// has not loaded is taken for a Doc.
    /// The doc comes forward in the window the request was made in (or the
    /// one named), and in no other: a second Studio window keeps what it shows.
    ///
    /// With `companion` the pane comes forward *beside* that surface, which
    /// stays where it is (the Canvas's Open Beside).
    func revealArtifact(_ artifactID: String, in destinationWindowState: StudioWindowState? = nil, beside companion: StudioCenterTab? = nil) {
        let destination = destinationWindowState ?? activeWindowState
        let section = artifactSection(of: artifactID)
        if section == .docs {
            let scope = docsCanvasScope(for: artifactID, in: destination)
            if destination.artifactCanvasNotebookID != scope { destination.artifactCanvasNotebookID = scope }
        }
        if let companion {
            revealCenterTab(section.centerTab, beside: companion, in: destination)
        } else {
            activateCenterTab(section.centerTab, in: destination)
        }
        artifactRevealRequest = ArtifactRevealRequest(
            artifactID: artifactID,
            section: section,
            windowID: destination.id,
            groupID: paneShowing(section.centerTab, in: destination)
        )
    }

    /// The pane a request for `tab`'s content goes to when the window shows
    /// `tab` in more than one pane (`StudioCenterTab.copyablePlaces`): the
    /// one last clicked in, else the first showing it. Nil when only one pane
    /// can answer, so every canvas of the window may.
    func paneShowing(_ tab: StudioCenterTab, in window: StudioWindowState) -> UUID? {
        let showing = window.centerTabGroups.groups.filter { $0.activeTab == tab }
        guard showing.count > 1 else { return nil }
        return (showing.first { $0.id == window.focusedGroupID } ?? showing[0]).id
    }

    /// The Notebook a doc opens scoped to in `windowState`: the notebook the
    /// window holds when the doc is filed there, so its list and its New Doc
    /// are the notebook's; nil — every doc — otherwise.
    func docsCanvasScope(for artifactID: String, in windowState: StudioWindowState) -> String? {
        guard let notebookID = windowState.NotebookID,
              let record = artifacts.first(where: { $0.id == artifactID }),
              NotebookOutputs.isFiled(record, in: notebookID) else { return nil }
        return notebookID
    }

    /// Docs or Sites for a record id, read from the loaded library.
    func artifactSection(of artifactID: String) -> ArtifactSection {
        artifacts.first(where: { $0.id == artifactID }).map(section(of:)) ?? .docs
    }

    /// Docs or Sites for a record: the record's own answer, by its link. A
    /// Google Doc and every Markdown doc are Docs, published or not; a Claude
    /// artifact, a Codex site or a ForeverLM site is a Site. From 2026-09-08
    /// to 2026-09-10 a Markdown doc moved to Sites while it had a page on
    /// foreverlm.com; the product owner reversed that ("sites should only hold actual
    /// sites, published docs stay in docs"), so publication no longer moves
    /// anything. Kept as the one place every canvas and `revealArtifact` ask.
    func section(of artifact: ArtifactRecord) -> ArtifactSection {
        artifact.section
    }

    /// Opens Docs scoped to a Notebook — its list and its New Doc are the
    /// Notebook's — or, with nil, every doc. It opens beside what is on
    /// screen, as a rail row's Open Beside does. (The
    /// Notebook page that placed it right of itself went with the notebook's
    /// Studio, which lists the notebook's Docs among its outputs.)
    func openArtifactsBeside(notebookID: String? = nil) {
        let destination = activeWindowState
        if destination.artifactCanvasNotebookID != notebookID { destination.artifactCanvasNotebookID = notebookID }
        openCenterTabBeside(.notepad)
    }

    /// Opens one notebook in the window in scope — the single definition of
    /// "open a notebook", shared by the rail's folder rows, the Space's rows,
    /// links and Siri. The notebook workspace then draws the window
    /// (`openNotebook(_:in:startsNotebookChat:)`). Opening writes nothing
    /// synced: that window's scene snapshot, which `get_app_context` names,
    /// and the active Notebook (`activeNotebookId`), a preference on this Mac
    /// only. An archived Notebook opens to be read as well, and does not move
    /// the active one.
    func openNotebookInReader(_ notebookID: String) {
        openNotebook(notebookID)
    }

    /// The navigation rail's folder-row interaction. A second click on the
    /// notebook the window holds closes it, and the panes underneath come
    /// back as they were.
    func toggleNotebookInReader(_ notebookID: String) {
        if workbenchNotebookID == notebookID {
            closeNotebook()
        } else {
            openNotebookInReader(notebookID)
        }
    }

    /// The notebook open in the key window (nil while it holds none and its
    /// Space shows). The notebook belongs to the window
    /// (`StudioWindowState.notebook`); this forwards to `activeWindowState`
    /// the way `centerTabGroups` does, so imperative navigation — and an
    /// `inWindow` scope — opens and reads the notebook of the window it acts
    /// in. Views that render one window read their own window's notebook.
    var workbenchNotebookID: String? {
        get { activeWindowState.NotebookID }
        set { activeWindowState.NotebookID = newValue }
    }

    /// Closes `notebookID` in every window that holds it: an archived or
    /// deleted notebook is open nowhere, and each of those windows shows the
    /// Space (`leaveNotebookForSpace`).
    func closeNotebookInEveryWindow(_ notebookID: String) {
        for state in allWindowStates where state.NotebookID == notebookID {
            leaveNotebookForSpace(in: state)
        }
    }

    /// Every window that holds `notebookID` holds `survivorID` instead: a
    /// merged notebook lives on in the one it was folded into, and so does
    /// the last time it was worked in on this Mac.
    func moveNotebookInEveryWindow(_ notebookID: String, to survivorID: String) {
        for state in allWindowStates where state.NotebookID == notebookID {
            state.NotebookID = survivorID
        }
        var recency = notebookRecency
        recency.merge(notebookID, into: survivorID)
        if recency != notebookRecency {
            notebookRecency = recency
            recency.save(to: notebookRecencyDefaults)
        }
    }

    /// Optional Notebook scope for the Docs pane of the window in scope
    /// (`StudioWindowState.artifactCanvasNotebookID`), forwarded the way
    /// `workbenchNotebookID` is so an `inWindow` scope reads and sets its own
    /// window's. Transient UI state rather than persisted navigation: opening
    /// Docs from the rail always clears it and returns to the learner's
    /// complete list.
    var artifactCanvasNotebookID: String? {
        get { activeWindowState.artifactCanvasNotebookID }
        set { activeWindowState.artifactCanvasNotebookID = newValue }
    }

    /// Notebook currently emphasized in the key window's navigation rail.
    /// Opening a notebook makes its folder active. Sticky on purpose — it
    /// survives switching to Schedule or opening a source, so the rail keeps
    /// showing which notebook the learner is working in. Cleared by going back
    /// to the notebook gallery.
    var railScopedNotebook: LearningGoalRecord? {
        railScopedNotebook(in: activeWindowState)
    }

    /// The active Notebook `windowState` holds as its notebook, for that
    /// window's own rail and voice scope.
    func railScopedNotebook(in windowState: StudioWindowState) -> LearningGoalRecord? {
        guard let notebookID = windowState.NotebookID else { return nil }
        return notebooks.first { $0.id == notebookID }
    }

}
