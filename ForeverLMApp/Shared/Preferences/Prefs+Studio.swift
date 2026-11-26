import Foundation

// Generated for step 0 of the typed settings layer from the key census; kept by hand from here on.
// A name is the stored string and is frozen (`UnitTests/Fixtures/preference-keys.golden.json`).

extension Prefs {
    /// The Studio window: tabs, orders, panels, zoom.
    enum Studio {
        /// Studio source participation, layout, and display.
        static let hiddenTabs = AccountKey<[String]?>("studio.hiddenTabs")
        static let tabOrder = AccountKey<[String]?>("studio.tabOrder")
        static let excludedKnowledgeSourceTabs = AccountKey<[String]?>("studio.excludedKnowledgeSourceTabs")
        static let centerTabGroups = AccountKey<[String]?>("studio.centerTabGroups.v1")
        static let courseOrder = AccountKey<[String]?>("studio.courseOrder")
        static let notebookOrder = AccountKey<[String]?>("studio.projectOrder", .record)
        static let chatOrder = AccountKey<[String]?>("studio.chatOrder")
        /// The notebooks the learner pinned to the rail (`NotebookPins`). Like
        /// the orders beside it, an arranged rail is work that has to reach the
        /// other Mac.
        static let pinnedNotebooks = AccountKey<[String]?>("studio.pinnedNotebooks.v1", .record)
        static let expandedPanel = AccountKey<String?>("studio.expandedPanel")
        static let showSearchPanel = AccountKey<Bool?>("studio.showSearchPanel")
        static let navigationRailVisible = AccountKey<Bool?>("studio.navigationRailVisible")
        static let sourceTabBarLayout = AccountKey<String?>("studio.sourceTabBarLayout")
        static let showSourceTabLabels = AccountKey<Bool>("studio.showSourceTabLabels", default: true)
        /// Whether a chat is told, with every message, what is open beside it
        /// (`ChatOpenPanes`). Off by default (product owner, 2026-11-26: "by
        /// default; maybe don't put what's open in the context; but make this
        /// a setting"): the composer's Add What's Open button brings in what is
        /// open at that moment instead.
        static let chatSeesWhatIsOpen = AccountKey<Bool>("studio.chatSeesWhatIsOpen.v1", default: false)
        static let sourceTabIconSize = AccountKey<String?>("studio.sourceTabIconSize")
        /// The one-time integration-tab unpin and its record of which unpins were
        /// Studio's own. They belong with `studio.hiddenTabs`: left device-local,
        /// a rebuild into a fresh preferences container re-applied the default and
        /// then pinned Read AI, Zoom and Slack back over a deliberate unpin.
        static let integrationTabUnpinDefaultsApplied = AccountKey<[String]?>("studio.integrationTabUnpinDefaultsApplied")
        static let integrationTabsUnpinnedByDefault = AccountKey<Any?>("studio.integrationTabsUnpinnedByDefault", coding: .any)
        /// Chat's pinch zoom is one offset per chat panel, in memory on the
        /// panel's session store, so it is neither stored nor synced.
        static let zoomStep = AccountKey<Int?>("uiZoomStep")
        static let metadataVisibility = AccountKey<String?>("metadataVisibility")
        /// No reader is left; the settings catalog still lists the row.
        static let retiredShowReadStatus = AccountKey<Any?>("showReadStatus", coding: .any)
        /// No reader is left; the settings catalog still lists the row.
        static let retiredShowReviewedStatus = AccountKey<Any?>("showReviewedStatus", coding: .any)
        /// No reader is left; the settings catalog still lists the row.
        static let retiredShowSyncSubtitles = AccountKey<Any?>("showSyncSubtitles", coding: .any)
        static let podcastSortMode = AccountKey<String?>("podcastSortMode")
        static let videoSortMode = AccountKey<String?>("videoSortMode")
        static let meetingListOrder = AccountKey<String?>("meetingListOrder")
        /// User-created taxonomy — losing these collapses grouping.
        static let userCourseNames = AccountKey<[String]?>("userCourseNames")
        static let lastSessionWindows = DeviceKey<Data?>("studio.lastSessionWindows", reason: "this Mac's window restore")
        static let lastSessionResumesContent = DeviceKey<Bool?>("studio.lastSessionResumesContent", reason: "this Mac's window restore")
        static let activeTeamID = DeviceKey<String?>("studio.activeTeamID", reason: "the team space this Mac's windows last showed")
        static let libraryShowsRecent = DeviceKey<Bool?>("library.showsRecent.v1", reason: "how this Mac's Library lists its sources")
        /// Codex's unread dot is that app's view; ForeverLM's is this Mac's,
        /// as a notebook's outputs' seen marks are (`ChatReadMarks`).
        static let chatUnreadMarks = DeviceKey<Any?>("chat.unread.v1", coding: .any, reason: "device-local: the chats this Mac shows as unread")
        /// What the learner marked read in the strip's bell, which holds this
        /// Mac's corner cards and notices (`CornerNoticeTray`).
        static let noticeReadMarks = DeviceKey<Any?>("notifications.readMarks.v1", coding: .any, reason: "device-local: what this Mac's bell shows as read")
        static let retiredSourcesPanelWidth = DeviceKey<Any?>.unread("studio.sourcesPanelWidth", reason: "absolute pixels, display-dependent")
        static let retiredLearningProgressPanelHeight = DeviceKey<Any?>.unread("studio.learningProgressPanelHeight", reason: "absolute pixels, display-dependent")
        static let retiredMCPContextTrayHeight = DeviceKey<Any?>.unread("studio.mcpContextTrayHeight", reason: "absolute pixels, display-dependent")
        static let retiredReviewSessionPanelHeight = DeviceKey<Any?>.unread("studio.reviewSessionPanelHeight", reason: "absolute pixels, display-dependent")
        static let retiredAssistantOverlayWidth = DeviceKey<Any?>.unread("studio.assistantOverlay.width", reason: "absolute pixels, display-dependent")
        static let retiredAssistantOverlayHeight = DeviceKey<Any?>.unread("studio.assistantOverlay.height", reason: "absolute pixels, display-dependent")
        /// Transient window state.
        static let retiredChatPoppedOut = DeviceKey<Any?>.unread("studio.chatPoppedOut", reason: "transient window state")
        static let retiredReaderPoppedOut = DeviceKey<Any?>.unread("studio.readerPoppedOut", reason: "transient window state")
        /// Synced until 2026-10-03: the notebooks taken off the rail, when
        /// every notebook was on it unless taken off. The rail lists the
        /// learner's explicit pins now (`NotebookPins`), so nothing reads it,
        /// and schema v2 maps the pins, not this.
        static let retiredUnpinnedNotebooks = DeviceKey<Any?>.unread("studio.unpinnedProjects", reason: "retired with the rail that listed every notebook; never read")
        static let retiredRecordingPrivacyCutoff = DeviceKey<Any?>.unread("studio.recordingPrivacyCutoff", reason: "retired user-facing recording privacy boundary")
        static let unsentChatDrafts = DeviceKey<Data?>("chat.unsentDrafts", reason: "what this Mac's chat boxes held when they were left, JSON; a draft is typed on the Mac being sat at")
        static let dismissedIdleSuggestions = DeviceKey<[String]?>("chat.dismissedIdleSuggestions", reason: "the idle chat suggestions hidden on this Mac; view chrome")
        static let outputsSeenSince = DeviceKey<Date?>("notebook.outputs.seenSince.v1", reason: "when this Mac's Studio first listed notebook outputs; unread dots are this Mac's")
        static let outputsSeenIDs = DeviceKey<[String]?>("notebook.outputs.seenIDs.v1", reason: "the notebook outputs opened on this Mac; unread dots are this Mac's")
        /// Each Docs, Sites and Animations pane remembers whether its list shows,
        /// per Mac. They were read through a wrapper that mirrors writes to the
        /// account, but the keys were never listed as synced, so they have never
        /// left the Mac.
        static let docsListVisible = DeviceKey<Bool>("notepad.artifactListVisible", default: false, reason: "whether this Mac's Docs pane shows its list")
        static let sitesListVisible = DeviceKey<Bool>("sites.listVisible", default: false, reason: "whether this Mac's Sites pane shows its list")
        static let animationsListVisible = DeviceKey<Bool>("animations.listVisible", default: false, reason: "whether this Mac's Animations pane shows its list")

        static let all: [AnyPreferenceKey] = [
            hiddenTabs.erased,
            tabOrder.erased,
            excludedKnowledgeSourceTabs.erased,
            centerTabGroups.erased,
            courseOrder.erased,
            notebookOrder.erased,
            chatOrder.erased,
            pinnedNotebooks.erased,
            expandedPanel.erased,
            showSearchPanel.erased,
            navigationRailVisible.erased,
            sourceTabBarLayout.erased,
            showSourceTabLabels.erased,
            chatSeesWhatIsOpen.erased,
            sourceTabIconSize.erased,
            integrationTabUnpinDefaultsApplied.erased,
            integrationTabsUnpinnedByDefault.erased,
            zoomStep.erased,
            metadataVisibility.erased,
            retiredShowReadStatus.erased,
            retiredShowReviewedStatus.erased,
            retiredShowSyncSubtitles.erased,
            podcastSortMode.erased,
            videoSortMode.erased,
            meetingListOrder.erased,
            userCourseNames.erased,
            lastSessionWindows.erased,
            lastSessionResumesContent.erased,
            activeTeamID.erased,
            libraryShowsRecent.erased,
            chatUnreadMarks.erased,
            noticeReadMarks.erased,
            retiredSourcesPanelWidth.erased,
            retiredLearningProgressPanelHeight.erased,
            retiredMCPContextTrayHeight.erased,
            retiredReviewSessionPanelHeight.erased,
            retiredAssistantOverlayWidth.erased,
            retiredAssistantOverlayHeight.erased,
            retiredChatPoppedOut.erased,
            retiredReaderPoppedOut.erased,
            retiredUnpinnedNotebooks.erased,
            retiredRecordingPrivacyCutoff.erased,
            unsentChatDrafts.erased,
            dismissedIdleSuggestions.erased,
            outputsSeenSince.erased,
            outputsSeenIDs.erased,
            docsListVisible.erased,
            sitesListVisible.erased,
            animationsListVisible.erased,
        ]
    }
}
