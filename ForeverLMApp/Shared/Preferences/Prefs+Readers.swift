import Foundation

// Generated for step 0 of the typed settings layer from the key census; kept by hand from here on.
// A name is the stored string and is frozen (`UnitTests/Fixtures/preference-keys.golden.json`).

extension Prefs {
    /// Readers and the page editor: how a source or a page is drawn.
    enum Readers {
        /// Reading a paper as published rather than inverted for Dark Mode. It is
        /// a property of the reader and the figures they are reading, not of the
        /// Mac they happen to be at, so it follows the account like the rest of
        /// the display preferences above. See `ReaderDarkMode`.
        static let originalPageColors = AccountKey<Bool>("readerOriginalPageColors", default: false)
        /// How wide a Doc's page is drawn, in points (0 fills the pane). A
        /// reading preference like the zoom step above: a line's measure, the
        /// same on any display, so it follows the account. See `ArtifactPageWidth`.
        static let pageColumnWidth = AccountKey<Double?>("notepad.pageColumnWidth")
        /// How a video source is laid out beside its transcript, and how much of
        /// the pane the video takes. The mode is a reading preference like the
        /// two above; the sizes are *fractions* of the pane (0 means auto), not
        /// the absolute pixel widths excluded below, so they mean the same thing
        /// on a laptop screen and a 6K display and can follow the account with
        /// them.
        static let youtubeTranscriptBesideVideo = AccountKey<Bool>("reader.youtubeTranscriptBesideVideo", default: true)
        static let youtubeVideoPaneFraction = AccountKey<Double>("reader.youtubeVideoPaneFraction", default: 0)
        static let youtubeVideoPaneWidthFraction = AccountKey<Double>("reader.youtubeVideoPaneWidthFraction", default: 0)
        static let meetingVideoPaneFraction = AccountKey<Double>("reader.meetingVideoPaneFraction", default: 0)
        /// A meeting's transcript beside its recording, and the recording
        /// column's share of the pane's width: the same mode and fraction as the
        /// video reader's.
        static let meetingTranscriptBesideVideo = AccountKey<Bool>("reader.meetingTranscriptBesideVideo", default: false)
        static let meetingVideoPaneWidthFraction = AccountKey<Double>("reader.meetingVideoPaneWidthFraction", default: 0)
        static let meetingTranscriptHidden = DeviceKey<Bool>("reader.meetingTranscriptHidden", default: false, reason: "view state: whether this Mac's meeting reader hides the transcript")
        /// What the reader folded in each doc (`ArtifactOutlineFolds`): how one
        /// reader left a doc on one screen, keyed by doc id.
        static let outlineFolds = DeviceKey<[String: Any]?>("docs.outlineFolds", coding: .dictionary, reason: "view state of each doc on this Mac, not a setting")
        /// The notebook workspace's Sources column as the learner dragged it
        /// (`NotebookWorkspaceSizing.sourcesWidthPreferenceKey`).
        static let notebookSourcesColumnWidth = DeviceKey<Double?>("notebook.sourcesColumnWidth", reason: "absolute pixels, display-dependent")
        static let notebookSourcesSort = DeviceKey<String?>("notebook.sources.sort", reason: "the sort of this Mac's notebook Sources column")
        static let webLinksOpenIn = DeviceKey<String?>("webLinks.opensIn", reason: "whether this Mac's links open in its Browser pane or in this Mac's own default browser")
        /// Reasoned at their call sites before 2026-09-14 but never declared here,
        /// which is the one thing this file exists to prevent. Each keeps the
        /// reason its own code gives.
        static let browserProfiles = DeviceKey<Any?>("browser.profiles.v1", coding: .any, reason: "a profile names a data store on this disk; a synced list would name jars another Mac does not have")
        static let browserSession = DeviceKey<Any?>("browser.session.v1", coding: .any, reason: "which tabs are open in this Mac's browser window")
        /// Caches and sync cursors — refetched or rebuilt, and meaningless elsewhere.
        static let recentSourceIDs = DeviceKey<[String]?>("reader.recentSourceIDs", reason: "cache; deliberately out of the sync pipeline")
        static let retiredEnrichedChapterTitles = DeviceKey<Any?>.unread("enrichedChapterTitles", reason: "cache keyed by local PDF path")
        /// Synced until 2026-09-28: the Quiz me switch on a video's transcript
        /// bar. The checkpoint quiz it turned on is gone (a course quiz is taken
        /// in a chat), so nothing reads it.
        static let retiredVideoQuizCheckpoints = DeviceKey<Any?>.unread("reader.videoQuizCheckpoints", reason: "retired with the video checkpoint quiz; never read")
        static let browserLinkedPageProfiles = DeviceKey<[String: Any]?>("browser.linkedPageProfiles.v1", coding: .dictionary, reason: "which browser profile a linked page opens under; the profiles are jars on this disk")

        static let all: [AnyPreferenceKey] = [
            originalPageColors.erased,
            pageColumnWidth.erased,
            youtubeTranscriptBesideVideo.erased,
            youtubeVideoPaneFraction.erased,
            youtubeVideoPaneWidthFraction.erased,
            meetingVideoPaneFraction.erased,
            meetingTranscriptBesideVideo.erased,
            meetingVideoPaneWidthFraction.erased,
            meetingTranscriptHidden.erased,
            outlineFolds.erased,
            notebookSourcesColumnWidth.erased,
            notebookSourcesSort.erased,
            webLinksOpenIn.erased,
            browserProfiles.erased,
            browserSession.erased,
            recentSourceIDs.erased,
            retiredEnrichedChapterTitles.erased,
            retiredVideoQuizCheckpoints.erased,
            browserLinkedPageProfiles.erased,
        ]
    }
}
