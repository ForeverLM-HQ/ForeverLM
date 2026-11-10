import SwiftUI
import AppKit

extension StudioSidebar {
    var sidebarListIdentity: String {
        sidebar.showsRecent ? "recent" : sidebar.sidebarTab.rawValue
    }

    /// Escape leaves a multi-selection the way a click cannot: without opening
    /// anything. Anything else is left for the next responder.
    func collapseMultiSelectionOnEscape() {
        guard let collapsed = SidebarSourceSelection.selectionAfterEscape(
            selection: windowState.sidebarSelectedSourceIDs,
            readerSourceID: sidebarReaderSourceID
        ) else { return }
        windowState.sidebarSelectedSourceIDs = collapsed
    }

    private func selectionHasVisibleRow(_ id: String) -> Bool {
        // An explainer has no row anywhere: it is read from its source's
        // Explain button or context menu (explainer-design.md); an audio
        // overview's carrier from its notebook.
        if let explainer = vm.articlesById[id], GeneratedExplainer.isSpokenScriptURL(explainer.url) {
            return false
        }
        guard windowVM.visibleSidebarSourceIDs.contains(id),
              let article = windowVM.activeTabArticles.first(where: { $0.id == id }) else { return false }
        switch sidebar.sidebarTab {
        case .books:
            // Books render as one cover row per group; chapters never have rows.
            return article.parentGroup == nil
        case .papers:
            if windowVM.activePapersWithPDF.contains(where: { $0.id == id }) { return true }
            if windowVM.activeProcessingPapers.contains(where: { $0.id == id }) { return isProcessingPapersExpanded }
            if windowVM.activePapersWithoutPDF.contains(where: { $0.id == id }) { return isPapersWithoutPDFExpanded }
            if windowVM.activePaywalledPapersWithoutPDF.contains(where: { $0.id == id }) { return isPaywalledPapersExpanded }
            return false
        case .videos:
            guard let group = article.parentGroup else { return true }
            return windowVM.inlineVideoPlaylistGroupNames.contains(group) || sidebar.expandedGroups.contains(group)
        default:
            if sidebar.sidebarTab == .meetings {
                // By date every session has a row of its own.
                if windowVM.meetingListOrder == .byDate { return true }
                guard let group = article.parentGroup else { return false }
                return sidebar.expandedGroups.contains(group)
            }
            return true
        }
    }

    /// Scroll the list to the source another panel just selected — following a
    /// chat citation, say. The view model has already switched to the owning tab,
    /// expanded the parent group, and grown pagination so the row exists; all that
    /// is left is bringing it on screen, where the row's selection wash
    /// makes it stand out.
    ///
    /// Driven by `.task(id:)` rather than `onChange` because switching tabs rebuilds
    /// the list (`.id(sidebarListIdentity)`), and a freshly created view never sees
    /// the change that created it.
    func revealRequestedSource(using proxy: ScrollViewProxy) async {
        guard let request = vm.sidebarRevealRequest,
              let article = vm.articlesById[request.sourceID] else { return }

        // The Papers tab keeps its needs-attention and paywalled sections collapsed,
        // and the user can collapse Processing, so a linked paper in any of those
        // sections has no row until its section opens.
        if sidebar.sidebarTab == .papers {
            if windowVM.activeProcessingPapers.contains(where: { $0.id == request.sourceID }) {
                isProcessingPapersExpanded = true
            } else if windowVM.activePapersWithoutPDF.contains(where: { $0.id == request.sourceID }) {
                isPapersWithoutPDFExpanded = true
            } else if windowVM.activePaywalledPapersWithoutPDF.contains(where: { $0.id == request.sourceID }) {
                isPaywalledPapersExpanded = true
            }
        }

        // Book chapters get no row of their own, so their collection row is the
        // closest anchor the list can actually scroll to.
        let targetID = selectionHasVisibleRow(request.sourceID)
            ? request.sourceID
            : (article.parentGroup ?? request.sourceID)

        // Rows for a tab that just switched — or a section that just expanded —
        // don't exist on this runloop turn, so retry until a scroll lands.
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(120))
            }
            await Task.yield()
            guard !Task.isCancelled else { return }
            let animation: Animation? = attempt == 0 ? .easeInOut(duration: 0.2) : nil
            withAnimation(animation) {
                proxy.scrollTo(targetID, anchor: .center)
            }
        }

        vm.sidebarRevealRequest = nil
    }

}

// MARK: - Source search field

// MARK: - Meeting plugin notice

extension StudioSidebar {
    /// What the Meetings tab should say about a plugin that has gone quiet,
    /// if anything. Read AI meetings only ever arrive through a plugin, so
    /// having any is reason to expect one; a Zoom link can also be added by
    /// hand, so Zoom expects one only once a plugin has pushed some.
    var meetingPluginNotice: MeetingPluginNotice? {
        MeetingPluginNotice.resolve(
            providersInUse: vm.meetingProvidersInUse,
            expectsSync: { candidate in
                candidate == .readAI || vm.articles.contains {
                    $0.sourceType == .meeting
                        && MeetingProvider.forOrigin($0.discoveryOrigin) == candidate
                        && $0.connectorLabel.map { candidate.matches(connectorLabel: $0) } == true
                }
            },
            plugins: meetingPluginSummaries.map {
                MeetingPluginNotice.Plugin(name: $0.name, trouble: $0.attentionSummary)
            },
            hasMCPAddress: meetingPluginSetupAddress != nil
        )
    }

    func meetingPluginActionTitle(for notice: MeetingPluginNotice) -> String {
        notice.action == .copySetupPrompt && didCopyMeetingPluginSetupPrompt
            ? "Copied"
            : notice.actionTitle
    }

    /// The one thing the notice offers. Copying hands over the guide's recipe
    /// with the user's MCP address and the provider filled in — the same
    /// contract Plugins › Build Your Own copies, opening with a
    /// request to find and reconnect the plugin that used to run before
    /// building another — and the toast says where it goes next, since a copy
    /// is invisible on its own.
    func performMeetingPluginAction(_ notice: MeetingPluginNotice) {
        switch notice.action {
        case .copySetupPrompt:
            guard let address = meetingPluginSetupAddress else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(
                UserPluginSetupPrompt.text(mcpURL: address, for: notice.provider),
                forType: .string
            )
            didCopyMeetingPluginSetupPrompt = true
            vm.showToast(
                "Setup prompt copied. Paste it into Claude, ChatGPT, or any coding assistant — it finds and reconnects your \(notice.provider.displayName) plugin, or builds one if none is left, and you approve it once in ForeverLM."
            )
            Task {
                try? await Task.sleep(for: .seconds(2))
                didCopyMeetingPluginSetupPrompt = false
            }
        case .openBuildYourOwn, .showPluginStatus:
            PluginsPlace.requestOpen(.yourPlugins)
        }
    }
}

// MARK: - Zoom recording awaiting conversion

