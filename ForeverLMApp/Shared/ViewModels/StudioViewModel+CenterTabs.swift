// The center area: tab groups, panes, memory review focus and tabs moved between windows.

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

    // MARK: - Memory review focus

    /// The review the active window is giving itself over to, if any.
    var memoryReviewFocusSessionID: String? {
        get { activeWindowState.memoryReviewFocusSessionID }
        set { activeWindowState.memoryReviewFocusSessionID = newValue }
    }

    /// The window becomes the review: rail, Sources, and every other center tab
    /// step aside for it. Nothing underneath is changed, so leaving puts the
    /// workspace back exactly as it was.
    ///
    /// Taking the window is the commitment the review promised before it
    /// started: from here, leaving before the goal ends today's session
    /// (`MemoryReviewEngagementTracker.beginCommittedSession`). A day's
    /// review chat from before cards; the card review enters through
    /// `enterMemoryCardFocus`.
    func enterMemoryReviewFocus(sessionID: String, in windowState: StudioWindowState? = nil) {
        let target = windowState ?? activeWindowState
        target.isVoiceWorkspacePresented = false
        target.memoryReviewFocusSessionID = sessionID
        MemoryReviewEngagementTracker.shared.beginCommittedSession()
    }

    /// Leaves the review. `sessionID` leaves only that review, so a chat that
    /// moved on cannot end a review the learner is still in.
    ///
    /// Leaving is ending: whichever door the learner takes — the × by the
    /// clock, a shortcut to another surface, the pane moved on to another
    /// chat — today's session is over unless its goal is already met. The one
    /// exception is `endingSession: false`, for a review that never began.
    /// A card review asks its sitting too: one whose first deal is answered
    /// through, or that made no commitment (practice, a day already done),
    /// is not left early, so leaving it ends nothing
    /// (`MemoryCardSessionModel.leavingEndsSession`).
    func leaveMemoryReviewFocus(
        sessionID: String? = nil,
        in windowState: StudioWindowState? = nil,
        endingSession: Bool = true
    ) {
        let target = windowState ?? activeWindowState
        guard let focused = target.memoryReviewFocusSessionID else { return }
        if let sessionID, sessionID != focused { return }
        let cardSession = target.memoryCardSession
        target.memoryReviewFocus = nil
        if endingSession, cardSession?.leavingEndsSession ?? true {
            MemoryReviewEngagementTracker.shared.endSession()
        } else {
            MemoryReviewEngagementTracker.shared.abandonCommitment()
        }
        if let cardSession { cardSessionDidEnd(cardSession) }
    }

    // MARK: - Center tab groups

    /// The center area's VS Code-style arrangement: one or two side-by-side groups of
    /// tabs over the five singleton surfaces (Chat, Reader, Schedule, Notepad,
    /// Notebooks).
    /// Tabs rather than modal overlays so the
    /// Sources panel stays visible and hit-testable — sources can be dragged
    /// straight into schedule days or onto a notebook card. The arrangement is
    /// restored independently for each window. The most recently edited layout
    /// is also synced as the template for a newly opened window.
    ///
    /// The complete arrangement is restored on launch. Pane layout is working
    /// state, not a transient modal, so silently replacing it with Chat made the
    /// persistence affordance dishonest and repeatedly discarded the learner's
    /// chosen context.
    var centerTabGroups: StudioCenterTabGroups {
        get { activeWindowState.centerTabGroups }
        set { activeWindowState.centerTabGroups = newValue }
    }

    /// One visible surface per group — or, in a window holding a notebook,
    /// what the notebook's center shows (`visibleCenterTabs(in:)`).
    var activeCenterTabs: Set<StudioCenterTab> {
        visibleCenterTabs(in: activeWindowState)
    }

    /// A source row is navigation on its first click, regardless of the current
    /// center layout. Shift-click remains the explicit multi-selection gesture;
    /// rows remain draggable through their existing drag recognizer.
    var opensSidebarSourcesOnSingleClick: Bool {
        true
    }

    /// Closes `tab`'s tab — the × on it in a strip. With other tabs
    /// open in its pane, the pane shows the neighbouring one and `tab` stays
    /// parked there; as the pane's only tab it closes the way the pane's ×
    /// does (`dismissCenterSurface`).
    ///
    /// `groupID` names the pane whose strip was clicked, which matters for a
    /// place with a copy in several panes (`StudioCenterTab.copyablePlaces`).
    func closeCenterTab(
        _ tab: StudioCenterTab,
        fromGroup groupID: UUID? = nil,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        let destination = destinationWindowState ?? activeWindowState
        var layout = destination.centerTabGroups
        guard let index = layout.index(holding: tab, preferring: groupID, openOnly: true) else { return }
        guard layout.groups[index].closeTab(tab) else {
            dismissCenterSurface(tab, fromGroup: layout.groups[index].id, in: destination)
            return
        }
        // Assigned even when only the strip changed: `==` compares what the
        // panes show, and a background tab closing changes none of that.
        destination.centerTabGroups = layout
    }

    /// Brings `tab` on screen by making it its group's active tab.
    ///
    /// A command can target a window other than the key one — sending a source
    /// to a second Studio window has to reveal that window's Reader, not the
    /// one belonging to the window the menu was opened in.
    func activateCenterTab(
        _ tab: StudioCenterTab,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        // A beta feature's pane opens only where the feature shows
        // (`BetaFeatures`); anywhere else the call changes nothing.
        guard !BetaFeatures.unofferedCenterTabs.contains(tab) else { return }
        let destination = destinationWindowState ?? activeWindowState
        if destination.isVoiceWorkspacePresented {
            destination.isVoiceWorkspacePresented = false
        }
        // Asking for another surface — from a menu, a shortcut, or a source
        // opened out of the review's own strip — is leaving the review. The
        // rail and the tabs are already gone while it runs, so this is the
        // learner choosing to go, and the workspace comes back with them
        // rather than the request landing somewhere they cannot see. A card
        // review yields to Chat too: no chat is on screen in it.
        if destination.memoryReviewFocusYields(to: tab) {
            leaveMemoryReviewFocus(in: destination)
        }
        // A tab already open comes to the front where it is; anything else
        // opens as a new tab in the pane the learner last clicked in, and
        // what that pane showed stays one of its tabs.
        guard let layout = destination.centerTabGroups.activating(
            tab,
            focusedGroupID: destination.focusedGroupID
        ) else { return }
        // Guarded rather than self-assigning: @Observable routes every
        // assignment through withMutation and would invalidate observers (and
        // enqueue a preference save) on a no-op.
        if layout != destination.centerTabGroups { destination.centerTabGroups = layout }
    }

    /// Hides `tab`, which closes its tab. With other tabs open in its pane,
    /// the neighbouring one shows (`Group.closeTab`). As the pane's only tab
    /// it reveals a groupmate instead — the Space, the shell's home surface
    /// (the Notebooks home was until 2026-10-09, docs/notebooks-design.md):
    /// closing the last thing in the center lands on it, not on an empty
    /// Reader. Dismissing the Space itself reveals Chat, since a surface
    /// cannot be replaced by itself. A tab alone in its group dissolves the
    /// group and parks, inactive, at the end of the neighboring one (VS Code's
    /// close-last-editor-closes-the-group); with a single group there is
    /// nowhere to park and the request is ignored.
    func deactivateCenterTab(
        _ tab: StudioCenterTab,
        fromGroup groupID: UUID? = nil,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        let destination = destinationWindowState ?? activeWindowState
        var layout = destination.centerTabGroups
        guard let index = layout.index(holding: tab, preferring: groupID),
              layout.groups[index].activeTab == tab else { return }
        if layout.groups[index].closeTab(tab) {
            destination.centerTabGroups = layout
            return
        }
        if layout.groups[index].tabs.count == 1 {
            guard layout.groups.count > 1 else { return }
            layout.groups.remove(at: index)
            let neighbor = min(index, layout.groups.count - 1)
            layout.groups[neighbor].tabs.append(tab)
            destination.centerTabGroups = layout
            return
        }
        let tabs = layout.groups[index].tabs
        // Closing a surface in a pane shows the Space, the window's home, or
        // Chat when it is the Space that closes.
        let home: StudioCenterTab = tab == .artifacts ? .chat : .artifacts
        if tabs.contains(home) {
            layout.groups[index].activeTab = home
        } else {
            let position = tabs.firstIndex(of: tab) ?? 0
            layout.groups[index].activeTab = tabs[position == 0 ? 1 : position - 1]
        }
        // The closed surface is parked, not a tab behind its home.
        layout.groups[index].openTabs.removeAll { $0 == tab }
        destination.centerTabGroups = layout
    }

    /// Closes the pane containing `tab` by moving all of its tabs into the
    /// adjacent pane. Tabs keep their order and the surviving pane keeps its
    /// current selection. A lone pane cannot be closed because there is no
    /// destination for its permanent tabs.
    func closeCenterPane(
        containing tab: StudioCenterTab,
        fromGroup groupID: UUID? = nil,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        let windowState = destinationWindowState ?? activeWindowState
        var layout = windowState.centerTabGroups
        guard layout.groups.count > 1,
              let source = layout.index(holding: tab, preferring: groupID) else { return }

        let closingTabs = layout.groups.remove(at: source).tabs
        let destination = min(source, layout.groups.count - 1)
        if source < layout.groups.count {
            layout.groups[destination].tabs.insert(contentsOf: closingTabs, at: 0)
        } else {
            layout.groups[destination].tabs.append(contentsOf: closingTabs)
        }
        windowState.centerTabGroups = layout
    }

    /// Dismisses the visible center surface without allowing a one-pane
    /// workspace to become a dead end. A split pane closes into its neighbor;
    /// in the sole remaining pane, dismissal reveals one of that pane's other
    /// destinations instead — except a chat playing a walk, which ends the
    /// walk and opens New chat there (`leaveWalkthroughForNewChat`).
    func dismissCenterSurface(
        _ tab: StudioCenterTab,
        fromGroup groupID: UUID? = nil,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        let destination = destinationWindowState ?? activeWindowState
        // The Reader a card's source opened beside the card review closes
        // back to the review alone; the panes underneath are not on screen.
        if tab == .reader, let session = destination.memoryCardSession {
            session.besideSourceID = nil
            return
        }
        if destination.centerTabGroups.groups.count > 1 {
            closeCenterPane(containing: tab, fromGroup: groupID, in: destination)
        } else if tab == .chat, leaveWalkthroughForNewChat(in: destination) {
            // The walk was the chat's content; the pane stays on Chat.
        } else {
            deactivateCenterTab(tab, fromGroup: groupID, in: destination)
        }
    }

    /// Moves a tab into the pane at `groupIndex`, as its strip's tab at
    /// `position` (out-of-range values clamp), and shows it there: a tab
    /// dropped on a strip. A pane left with no tab dissolves, VS Code style.
    func moveCenterTab(
        _ tab: StudioCenterTab,
        fromGroup groupID: UUID? = nil,
        toGroup groupIndex: Int,
        at position: Int,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        let window = destinationWindowState ?? activeWindowState
        var layout = window.centerTabGroups
        guard let source = layout.index(holding: tab, preferring: groupID) else { return }
        var destination = max(0, min(groupIndex, layout.groups.count - 1))
        var insertAt = position
        if source == destination {
            let open = layout.groups[source].openTabs
            if let current = open.firstIndex(of: tab), current < insertAt { insertAt -= 1 }
        } else {
            let sourceWasAlone = layout.groups[source].openTabs == [tab]
            layout.groups[source].remove(tab)
            if sourceWasAlone {
                // Its parked surfaces go with the pane they are dropped on.
                let parked = layout.groups.remove(at: source).tabs
                if source < destination { destination -= 1 }
                layout.groups[destination].tabs.append(contentsOf: parked)
            }
            layout.groups[destination].tabs.append(tab)
        }
        var open = layout.groups[destination].openTabs.filter { $0 != tab }
        open.insert(tab, at: max(0, min(insertAt, open.count)))
        layout.groups[destination].openTabs = open
        layout.groups[destination].activeTab = tab
        window.centerTabGroups = layout
    }

    /// Slides the whole group containing `tab` one slot left or right. This is
    /// the meaningful move for a tab alone in its group, where a "split" has
    /// nothing to separate: asking to split such a tab to an adjacent slot
    /// resolves to the position it already occupies, so it would do nothing.
    /// A request past either end is ignored.
    func moveCenterGroup(
        containing tab: StudioCenterTab,
        fromGroup groupID: UUID? = nil,
        by offset: Int,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        let window = destinationWindowState ?? activeWindowState
        var layout = window.centerTabGroups
        guard let source = layout.index(holding: tab, preferring: groupID) else { return }
        let destination = source + offset
        guard layout.groups.indices.contains(destination) else { return }
        layout.groups.swapAt(source, destination)
        window.centerTabGroups = layout
    }

    /// Exchanges the two panes that meet at a divider. The destination window
    /// is explicit because a click in a secondary Studio window must never
    /// reorder whichever window happened to be key most recently.
    func swapCenterGroups(
        adjacentToDividerAt dividerIndex: Int,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        let destination = destinationWindowState ?? activeWindowState
        var layout = destination.centerTabGroups
        let trailingIndex = dividerIndex + 1
        guard layout.groups.indices.contains(dividerIndex),
              layout.groups.indices.contains(trailingIndex) else { return }
        layout.groups.swapAt(dividerIndex, trailingIndex)
        destination.centerTabGroups = layout
    }

    /// Context-menu split semantics relative to the tab's current group. A tab
    /// with other tabs open beside it peels into a new adjacent group. A tab
    /// alone in its strip slides that group one slot in the requested
    /// direction; keeping the same Split Left/Right commands makes the action
    /// predictable regardless of the current partition and avoids the
    /// adjacent-index no-op.
    func splitCenterTab(
        _ tab: StudioCenterTab,
        fromGroup groupID: UUID? = nil,
        towardRight: Bool,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        let window = destinationWindowState ?? activeWindowState
        guard let source = window.centerTabGroups.index(holding: tab, preferring: groupID) else { return }
        let sourceID = window.centerTabGroups.groups[source].id
        if window.centerTabGroups.groups[source].openTabs == [tab] {
            moveCenterGroup(containing: tab, fromGroup: sourceID, by: towardRight ? 1 : -1, in: window)
        } else {
            moveCenterTabToNewGroup(tab, fromGroup: sourceID, at: source + (towardRight ? 1 : 0), in: window)
        }
    }

    /// The split button at the end of a pane's strip, and ⌘\: a new pane
    /// beside the pane at `groupIndex` showing `tab` — a fresh copy of it when
    /// the place can stand in several panes (Pages: its list, to pick another
    /// page), else the place itself moved out of the pane that has it, as
    /// Split Right on its tab does. Nothing happens at the pane limit.
    func splitPane(
        at groupIndex: Int,
        showing tab: StudioCenterTab,
        towardRight: Bool = true,
        in window: StudioWindowState
    ) {
        guard !BetaFeatures.unofferedCenterTabs.contains(tab),
              window.centerTabGroups.groups.indices.contains(groupIndex),
              window.centerTabGroups.canCreateDraggedGroup else { return }
        if window.isVoiceWorkspacePresented { window.isVoiceWorkspacePresented = false }
        if window.memoryReviewFocusYields(to: tab) { leaveMemoryReviewFocus(in: window) }
        // Chat beside a Chat already open is a new side chat, and the Reader
        // beside a Reader a side reader; open nowhere, the window's own chat
        // or Reader moves beside.
        var tab = tab
        if StudioCenterTab.windowPlaces.contains(tab),
           window.centerTabGroups.groups.contains(where: { $0.openTabs.contains(tab) }),
           let copy = tab.splitCopy {
            tab = copy
        }
        // A side reader starts on what the pane it was split from reads, or
        // else on the window's Reader's source.
        let splitFrom = window.centerTabGroups.groups[groupIndex]
        let sideReaderSource = splitFrom.activeTab == .secondaryReader
            ? window.sideReaderSources[splitFrom.id]
            : window.readerSourceID(fallingBackTo: selectedArticleId)
        if let layout = window.centerTabGroups.splitting(tab, besidePaneAt: groupIndex, towardRight: towardRight) {
            let newIndex = towardRight ? groupIndex + 1 : groupIndex
            let newID = layout.groups[newIndex].id
            window.centerTabGroups = layout
            window.focusedGroupID = newID
            window.splitFromPane[newID] = splitFrom.id
            if tab == .secondaryReader, let sideReaderSource {
                window.sideReaderSources[newID] = sideReaderSource
            }
            // The copy opens on the list of pages, not on the page beside it.
            if tab == .notepad {
                artifactIndexRequest = ArtifactIndexRequest(section: .docs, windowID: window.id, groupID: newID)
            }
            return
        }
        guard let source = window.centerTabGroups.index(holding: tab, preferring: nil) else { return }
        let sourceID = window.centerTabGroups.groups[source].id
        if source == groupIndex {
            // The pane's own tab: it peels off beside, or a lone one moves.
            splitCenterTab(tab, fromGroup: sourceID, towardRight: towardRight, in: window)
        } else {
            moveCenterTabToNewGroup(tab, fromGroup: sourceID, at: towardRight ? groupIndex + 1 : groupIndex, in: window)
        }
    }

    /// ⌘\: a copy of what the pane last clicked in shows, beside it, when
    /// that place can stand in several panes — a new side chat for a chat.
    func splitFocusedPane(in window: StudioWindowState? = nil) {
        let window = window ?? activeWindowState
        let groups = window.centerTabGroups.groups
        let index = groups.firstIndex(where: { $0.id == window.focusedGroupID }) ?? 0
        guard groups.indices.contains(index), let copy = groups[index].activeTab.splitCopy else { return }
        splitPane(at: index, showing: copy, in: window)
    }

    /// Opens a hidden destination without replacing the surface currently
    /// visible in its group. Navigation rows expose this as "Open Beside" now
    /// that the permanent center tab strip is hidden. An already-visible tab
    /// is simply brought forward. At the two-pane limit, the destination is
    /// activated in the group where it is already parked, replacing that
    /// pane's visible surface so a third pane is never created.
    func openCenterTabBeside(_ tab: StudioCenterTab) {
        guard !BetaFeatures.unofferedCenterTabs.contains(tab) else { return }
        if isVoiceWorkspacePresented { isVoiceWorkspacePresented = false }
        if activeWindowState.memoryCardSession != nil { leaveMemoryReviewFocus(in: activeWindowState) }
        guard let source = centerTabGroups.groups.firstIndex(where: { $0.tabs.contains(tab) }) else { return }

        if centerTabGroups.groups[source].activeTab == tab {
            activateCenterTab(tab)
            return
        }
        guard centerTabGroups.canCreateGroup else {
            let coreTabs: Set<StudioCenterTab> = [.chat, .notepad, .sites, .animations, .artifacts, .browser]
            if coreTabs.contains(tab),
               let replacement = centerTabGroups.groups.firstIndex(where: {
                   !coreTabs.contains($0.activeTab)
               }),
               replacement != source {
                var layout = centerTabGroups
                layout.groups[source].remove(tab)
                layout.groups[replacement].tabs.append(tab)
                layout.groups[replacement].activeTab = tab
                centerTabGroups = layout
                return
            }
            activateCenterTab(tab)
            return
        }
        moveCenterTabToNewGroup(tab, at: source + 1)
    }

    /// Shows `tab` in the pane at `groupIndex` of `destination`, in place of
    /// what that pane showed: a destination from the sidebar dropped on a
    /// pane. A window holding a notebook has no panes to pick from, so there
    /// the tab opens in a pane of the window.
    ///
    /// `startsBlankChat` is the rail's "New chat" row, which means a fresh
    /// conversation in the pane it lands on. `destination` is explicit for the
    /// reason `placeCenterTabAtEdge` takes one: the drop names its own window.
    func replaceCenterPane(
        at groupIndex: Int,
        with tab: StudioCenterTab,
        startsBlankChat: Bool = false,
        in destination: StudioWindowState
    ) {
        guard !BetaFeatures.unofferedCenterTabs.contains(tab) else { return }
        if destination.isVoiceWorkspacePresented { destination.isVoiceWorkspacePresented = false }
        if destination.memoryReviewFocusYields(to: tab) { leaveMemoryReviewFocus(in: destination) }
        let hadTab = destination.centerTabGroups.groups.indices.contains(groupIndex)
            && destination.centerTabGroups.groups[groupIndex].tabs.contains(tab)
        guard let layout = destination.centerTabGroups.replacingPane(at: groupIndex, with: tab) else { return }
        if layout != destination.centerTabGroups { destination.centerTabGroups = layout }
        if startsBlankChat { inWindow(destination) { requestNewChat() } }
        // A Pages copy made here opens on the list of pages, as a split's does.
        // (`paneShowing` is non-nil only while two panes show Pages.)
        if tab == .notepad, !hadTab, paneShowing(.notepad, in: destination) != nil,
           destination.centerTabGroups.groups.indices.contains(groupIndex) {
            artifactIndexRequest = ArtifactIndexRequest(
                section: .docs,
                windowID: destination.id,
                groupID: destination.centerTabGroups.groups[groupIndex].id
            )
        }
    }

    // MARK: Tabs between windows

    /// Where a tab dragged out of another window lands in this one.
    enum CenterTabArrival: Equatable {
        /// On the strip of the pane at `group`, before its tab at `position`
        /// (`.max` is the end). A drop on the pane's body lands at the end.
        case strip(group: Int, position: Int)
        /// At the far edge of the center area, a pane of its own there.
        case edge(leading: Bool)
    }

    /// A tab dragged from one window's strip onto another window (product
    /// owner, 2026-11-08: "If I have two windows open on two screens side by
    /// side, make it easy to move a tab from one window to the next"). The
    /// place opens where it was dropped, showing what it showed there — the
    /// Reader its source, a side reader its source, Pages its page — and
    /// closes in the window it left, as its × would. A Browser arrives on this
    /// window's own pages. A chat moves through the windows' chat stores,
    /// which are view state (`StudioCenterTabGroupsView`), not through here.
    func moveCenterTab(
        _ tab: StudioCenterTab,
        fromGroup originGroupID: UUID,
        of origin: StudioWindowState,
        arriving arrival: CenterTabArrival,
        in destination: StudioWindowState
    ) {
        guard origin !== destination else { return }
        // What it shows, read before the window it leaves lets go of it.
        let sourceID: String?
        switch tab {
        case .reader: sourceID = origin.readerArticleID
        case .secondaryReader: sourceID = origin.sideReaderSources[originGroupID]
        default: sourceID = nil
        }
        let artifactID = tab == .notepad ? origin.openArtifactID : nil
        let place = destination.centerTabGroups.arrivingPlace(for: tab)
        guard let paneID = receiveCenterTab(place, arriving: arrival, in: destination) else { return }
        closeCenterTab(tab, fromGroup: originGroupID, in: origin)
        if let sourceID, articlesById[sourceID] != nil {
            if place == .secondaryReader {
                destination.sideReaderSources[paneID] = sourceID
            } else {
                Task { await selectArticle(sourceID, in: destination) }
            }
        }
        if let artifactID {
            artifactRevealRequest = ArtifactRevealRequest(artifactID: artifactID, section: .docs, windowID: destination.id)
        }
    }

    /// Puts `place`, come in from another window, where `arrival` says, in
    /// front there and in the pane a sidebar click next opens into. Returns
    /// that pane's id; nil when there was nowhere to put it.
    @discardableResult
    func receiveCenterTab(
        _ place: StudioCenterTab,
        arriving arrival: CenterTabArrival,
        in destination: StudioWindowState
    ) -> UUID? {
        if destination.isVoiceWorkspacePresented { destination.isVoiceWorkspacePresented = false }
        if destination.memoryCardSession != nil { leaveMemoryReviewFocus(in: destination) }
        let paneID: UUID?
        switch arrival {
        case .strip(let group, let position):
            let groups = destination.centerTabGroups.groups
            guard !groups.isEmpty else { return nil }
            let index = max(0, min(group, groups.count - 1))
            let target = groups[index].id
            guard let layout = destination.centerTabGroups.receiving(place, inPaneAt: index, at: position) else { return nil }
            destination.centerTabGroups = layout
            paneID = target
        case .edge(let leading):
            if place.canStandInSeveralPanes {
                // A copy: a new pane of its own at the edge, or at the pane
                // limit a tab of the edge pane.
                var layout = destination.centerTabGroups
                guard layout.canCreateDraggedGroup else {
                    let edgePane = leading ? 0 : layout.groups.count - 1
                    return receiveCenterTab(place, arriving: .strip(group: edgePane, position: .max), in: destination)
                }
                layout.groups.insert(.init(tabs: [place], activeTab: place), at: leading ? 0 : layout.groups.count)
                destination.centerTabGroups = layout
            } else {
                placeCenterTabAtEdge(place, leading: leading, in: destination)
            }
            let groups = destination.centerTabGroups.groups
            paneID = (leading ? groups.first : groups.last).flatMap { $0.activeTab == place ? $0.id : nil }
        }
        // The pane may have been dissolved and rebuilt by reconciliation;
        // answer only for one that still shows the place.
        guard let paneID,
              destination.centerTabGroups.groups.contains(where: { $0.id == paneID && $0.activeTab == place }) else { return nil }
        destination.focusedGroupID = paneID
        return paneID
    }

    /// Places a workspace destination at the requested outer edge: a tab
    /// dragged to the side to view it beside the rest. A tab sharing its pane
    /// with other tabs, or a parked one, splits into a new pane there — a third
    /// one too, since the learner chose it (`canCreateDraggedGroup`). A tab
    /// that is its pane's only tab moves the whole pane to that edge. At three
    /// panes the tab joins the edge pane as a tab of its own.
    func placeCenterTabAtEdge(
        _ tab: StudioCenterTab,
        fromGroup groupID: UUID? = nil,
        leading: Bool,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        // A cross-window drag does not necessarily make the window under the
        // pointer key. The drop target therefore supplies its own scene state;
        // menu commands and the model's own call sites continue to resolve through the
        // key-window registry when no explicit destination is provided.
        let destination = destinationWindowState ?? activeWindowState
        if destination.isVoiceWorkspacePresented {
            destination.isVoiceWorkspacePresented = false
        }
        if destination.memoryCardSession != nil { leaveMemoryReviewFocus(in: destination) }
        var layout = destination.centerTabGroups
        guard let source = layout.index(holding: tab, preferring: groupID) else { return }
        let edge = leading ? 0 : layout.groups.count
        let isPaneOfItsOwn = layout.groups[source].openTabs == [tab]

        if isPaneOfItsOwn, layout.groups.count > 1 || layout.groups[source].tabs == [tab] {
            let group = layout.groups.remove(at: source)
            layout.groups.insert(group, at: leading ? 0 : layout.groups.count)
        } else if layout.canCreateDraggedGroup {
            // The only pane's only tab (the Library clicked in the rail fills
            // the window) docks at the edge too, and Chat, else the Reader,
            // takes the rest of the window.
            if isPaneOfItsOwn {
                let remaining = layout.groups[source].tabs.filter { $0 != tab }
                layout.groups[source].activeTab = remaining.contains(.chat)
                    ? .chat
                    : (remaining.contains(.reader) ? .reader : remaining[0])
            }
            layout.groups[source].remove(tab)
            layout.groups.insert(.init(tabs: [tab], activeTab: tab), at: edge)
        } else {
            let target = leading ? 0 : layout.groups.count - 1
            guard target != source else {
                layout.groups[source].activeTab = tab
                destination.centerTabGroups = layout
                return
            }
            layout.groups[source].remove(tab)
            layout.groups[target].tabs.append(tab)
            layout.groups[target].activeTab = tab
        }
        destination.centerTabGroups = layout
    }

    /// Creates or moves the optional comparison Chat pane to a workspace edge.
    /// The pane owns a separate session manager in `StudioView`, so activating
    /// it never replaces the conversation in the primary Chat destination.
    func openSecondaryChatPane(atLeadingEdge: Bool) {
        if isVoiceWorkspacePresented { isVoiceWorkspacePresented = false }
        // A card review shows no chat: a second one opened under it would
        // land where the learner cannot see it.
        if activeWindowState.memoryCardSession != nil { leaveMemoryReviewFocus(in: activeWindowState) }
        var layout = centerTabGroups

        if let source = layout.groups.firstIndex(where: { $0.tabs.contains(.secondaryChat) }) {
            if layout.groups[source].tabs == [.secondaryChat] {
                let group = layout.groups.remove(at: source)
                layout.groups.insert(group, at: atLeadingEdge ? 0 : layout.groups.count)
            } else if layout.canCreateGroup {
                layout.groups[source].remove(.secondaryChat)
                layout.groups.insert(
                    .init(tabs: [.secondaryChat], activeTab: .secondaryChat),
                    at: atLeadingEdge ? 0 : layout.groups.count
                )
            } else {
                layout.groups[source].activeTab = .secondaryChat
                let group = layout.groups.remove(at: source)
                layout.groups.insert(group, at: atLeadingEdge ? 0 : layout.groups.count)
            }
        } else if layout.canCreateGroup {
            layout.groups.insert(
                .init(tabs: [.secondaryChat], activeTab: .secondaryChat),
                at: atLeadingEdge ? 0 : layout.groups.count
            )
        } else {
            let target = atLeadingEdge ? 0 : layout.groups.count - 1
            layout.groups[target].tabs.append(.secondaryChat)
            layout.groups[target].activeTab = .secondaryChat
        }

        centerTabGroups = layout
    }

    /// Closes a side chat's pane: `groupID`'s, the pane whose × was pressed,
    /// when several panes hold one.
    func dismissSecondaryChatPane(
        fromGroup groupID: UUID? = nil,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        let destination = destinationWindowState ?? activeWindowState
        var layout = destination.centerTabGroups
        guard let groupIndex = layout.index(holding: .secondaryChat, preferring: groupID) else { return }
        layout.groups[groupIndex].remove(.secondaryChat)
        if layout.groups[groupIndex].tabs.isEmpty {
            layout.groups.remove(at: groupIndex)
        }
        destination.centerTabGroups = layout
    }

    /// Keep the current Reader visible while revealing Chat immediately to its
    /// right. This is the one-click path used by media readers, where merely
    /// activating Chat could otherwise replace the video the user wants to
    /// discuss.
    func revealChatBesideReader() {
        revealChat(beside: .reader)
    }

    /// Keep `companion` visible while revealing Chat beside it.
    ///
    /// A passage is handed to Chat from the surface it was selected in — the
    /// Reader, a Doc — and that surface is the one thing the handoff must
    /// neither replace nor move: the words stay where they are. If the two
    /// tabs share a group, peel Chat into a new group on the companion's
    /// right, the side the eye reads toward. If they already occupy separate
    /// groups, both panes are already on screen where the learner put them:
    /// bring each tab forward and leave the arrangement alone. Reordering the
    /// panes here swapped a chat-left, reader-right window on every Chat
    /// press, which reads as the layout jumping rather than as an answer
    /// arriving.
    func revealChat(beside companion: StudioCenterTab) {
        if isVoiceWorkspacePresented { isVoiceWorkspacePresented = false }
        let window = activeWindowState
        // A card review shows no chat: asking for one is the learner going.
        if window.memoryCardSession != nil { leaveMemoryReviewFocus(in: window) }
        var layout = centerTabGroups
        guard companion != .chat,
              let chatGroup = layout.groups.firstIndex(where: { $0.tabs.contains(.chat) }),
              let companionGroup = layout.groups.firstIndex(where: { $0.tabs.contains(companion) })
        else { return }

        if chatGroup == companionGroup {
            layout.groups[companionGroup].activeTab = companion
            layout.groups[companionGroup].remove(.chat)

            if layout.canCreateGroup {
                layout.groups.insert(.init(tabs: [.chat], activeTab: .chat), at: companionGroup + 1)
            } else {
                // At the pane limit, reuse the nearest neighbor rather than
                // replacing the companion. If it was rightmost, swap the two
                // groups so Chat still lands on its right.
                let destination = companionGroup < layout.groups.count - 1
                    ? companionGroup + 1
                    : companionGroup - 1
                layout.groups[destination].tabs.insert(.chat, at: 0)
                layout.groups[destination].activeTab = .chat
                if destination < companionGroup {
                    layout.groups.swapAt(destination, companionGroup)
                }
            }
        } else {
            layout.groups[chatGroup].activeTab = .chat
            layout.groups[companionGroup].activeTab = companion
        }

        if layout != centerTabGroups { centerTabGroups = layout }
        reviewChatPanelMode = .chat
        reviewChatFocusRequestID = UUID()
        readerChatSpaceRequestID = UUID()
    }

    /// Keep Chat visible while revealing the Reader beside it. Assistant
    /// citations use this path so opening a source never replaces the
    /// conversation the learner was reading.
    func revealReaderBesideChat() {
        revealReader(beside: .chat)
    }

    /// Keep `companion` visible while revealing the Reader beside it. A source
    /// link is followed from wherever it was written — a chat citation, a
    /// doc's source chip — and the surface it was clicked in is the one thing
    /// the click must not replace. At the two-pane limit there is no room to
    /// create another group, so Reader joins the nearest existing neighbor
    /// while `companion` stays in place.
    func revealReader(
        beside companion: StudioCenterTab,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        revealCenterTab(.reader, beside: companion, in: destinationWindowState)
    }

    /// Keep `companion` visible while revealing `tab` beside it. With both in
    /// one pane, `tab` peels into a new pane next to it; at the two-pane limit
    /// it joins the nearest neighbor as a tab while `companion` stays in place.
    func revealCenterTab(
        _ tab: StudioCenterTab,
        beside companion: StudioCenterTab,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        guard !BetaFeatures.unofferedCenterTabs.contains(tab) else { return }
        let destination = destinationWindowState ?? activeWindowState
        if destination.isVoiceWorkspacePresented { destination.isVoiceWorkspacePresented = false }
        // A card review is all its window shows: a surface revealed under it
        // would land where the learner cannot see it. A link followed in the
        // Reader beside it stays in that Reader (`memoryReviewFocusYields`).
        if destination.memoryCardSession != nil, destination.memoryReviewFocusYields(to: tab) {
            leaveMemoryReviewFocus(in: destination)
        }
        guard companion != tab else {
            var layout = destination.centerTabGroups
            guard let group = layout.groups.firstIndex(where: { $0.tabs.contains(tab) }) else { return }
            layout.groups[group].activeTab = tab
            if layout != destination.centerTabGroups { destination.centerTabGroups = layout }
            return
        }
        var layout = destination.centerTabGroups
        guard let companionGroup = layout.groups.firstIndex(where: { $0.tabs.contains(companion) }),
              let tabGroup = layout.groups.firstIndex(where: { $0.tabs.contains(tab) })
        else { return }

        if companionGroup == tabGroup {
            layout.groups[companionGroup].activeTab = companion
            layout.groups[companionGroup].remove(tab)

            if layout.canCreateGroup {
                layout.groups.insert(
                    .init(tabs: [tab], activeTab: tab),
                    at: companionGroup + 1
                )
            } else {
                let neighbor = companionGroup < layout.groups.count - 1
                    ? companionGroup + 1
                    : companionGroup - 1
                layout.groups[neighbor].tabs.insert(tab, at: 0)
                layout.groups[neighbor].activeTab = tab
            }
        } else {
            layout.groups[companionGroup].activeTab = companion
            layout.groups[tabGroup].activeTab = tab
        }

        if layout != destination.centerTabGroups { destination.centerTabGroups = layout }
    }

    /// Splits `tab` out into a new group at `groupIndex` (0 = far left,
    /// `groups.count` = far right). A tab already alone reorders its whole
    /// group instead — correct for the far-edge drops that pass an index past
    /// its own position, while adjacent menu actions go through
    /// `splitCenterTab(_:towardRight:)` so they do not land back where they
    /// started.
    /// At the pane limit (`draggedGroupCount`) the split request is ignored.
    func moveCenterTabToNewGroup(
        _ tab: StudioCenterTab,
        fromGroup groupID: UUID? = nil,
        at groupIndex: Int,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        let window = destinationWindowState ?? activeWindowState
        var layout = window.centerTabGroups
        guard let source = layout.index(holding: tab, preferring: groupID) else { return }
        if layout.groups[source].tabs == [tab] {
            let group = layout.groups.remove(at: source)
            let destination = max(0, min(source < groupIndex ? groupIndex - 1 : groupIndex, layout.groups.count))
            layout.groups.insert(group, at: destination)
            if layout != window.centerTabGroups { window.centerTabGroups = layout }
            return
        }
        guard layout.canCreateDraggedGroup else { return }
        layout.groups[source].remove(tab)
        let destination = max(0, min(groupIndex, layout.groups.count))
        layout.groups.insert(.init(tabs: [tab], activeTab: tab), at: destination)
        window.centerTabGroups = layout
    }

}
