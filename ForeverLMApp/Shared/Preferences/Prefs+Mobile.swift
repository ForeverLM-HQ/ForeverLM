import Foundation

// Generated for step 0 of the typed settings layer from the key census; kept by hand from here on.
// A name is the stored string and is frozen (`UnitTests/Fixtures/preference-keys.golden.json`).

extension Prefs {
    /// The iPhone's own device-local keys.
    enum Mobile {
        static let automaticallyContinuesBooks = DeviceKey<Bool>("ios.listen.automaticallyContinuesBooks", default: false, reason: "iPhone-local: whether this phone plays the next chapter of a book")
        static let hasAskedToAutomaticallyContinueBooks = DeviceKey<Bool>("ios.listen.hasAskedToAutomaticallyContinueBooks", default: false, reason: "iPhone-local: one-shot marker that this phone asked about continuing books")
        static let playbackSpeed = DeviceKey<Float?>("ios.listen.playbackSpeed", reason: "iPhone-local: this phone's listening speed")
        static let lastOpenedNotebookID = DeviceKey<String?>("ios.notebooks.lastOpenedNotebookID", reason: "iPhone-local: the notebook this phone reopens")
        static let retiredLastOpenedNotebookID = DeviceKey<String?>("ios.notebooks.lastOpenedProjectID", reason: "iPhone-local: the notebook this phone reopened, under the name before notebooks; read once and cleared")
        static let offlineSavedSourceIDs = DeviceKey<[String]?>("ios.offline.savedSourceIDs", reason: "iPhone-local: the sources kept on this phone for offline reading")
        static let readAloudConfirmsEstimatedCost = DeviceKey<Bool?>("ios.readAloud.confirmsEstimatedCost", reason: "iPhone-local: whether this phone confirms a narration's cost")
        static let readAloudModel = DeviceKey<String?>("ios.readAloud.model", reason: "iPhone-local: the speech model this phone last used; the account's pick is the synced model row")
        static let readerFontScale = DeviceKey<Double?>("ios.reader.fontScale", reason: "iPhone-local: this phone's reader text size")
        static let siriPendingCommand = DeviceKey<Data?>("ios.siri.pendingCommand", reason: "iPhone-local: a Siri command waiting for this phone's app to open")
        static let spacePagesExpanded = DeviceKey<String>("ios.space.pagesExpanded.v1", default: "", reason: "iPhone-local: which pages' subpages this phone's Space shows")
        static let spaceRecents = DeviceKey<[Any]?>("ios.space.recents.v1", coding: .array, reason: "iPhone-local: this phone's Space Recents")
        static let spaceSort = DeviceKey<String?>("ios.space.sort", reason: "iPhone-local: the sort in this phone's Space")
        static let reviewGrader = DeviceKey<String?>("foreverlm.grader.v1", reason: "which grader this phone's review uses")
        static let todayWidgetSnapshot = DeviceKey<Data?>("widget.today.snapshot", reason: "the Today widget's snapshot, kept in the app group's suite on this phone")
        static let readingChatSpeakReplies = DeviceKey<Bool>("ios.readingChat.speakReplies", default: false, reason: "iPhone-local: whether this phone reads a reading chat's replies aloud")
        static let learningBoutEndedBreaks = DeviceKey<[String: Any]?>("ios.learningBout.endedBreaks.v1", coding: .dictionary, reason: "iPhone-local: the breaks this phone ended, by bout id, for two days")
        static let presentedMoveJobs = DeviceKey<[String]?>("share.presentedMoveJobs", reason: "iPhone-local: the moves whose space this phone already showed the sharing controller for")

        static let all: [AnyPreferenceKey] = [
            automaticallyContinuesBooks.erased,
            hasAskedToAutomaticallyContinueBooks.erased,
            playbackSpeed.erased,
            lastOpenedNotebookID.erased,
            retiredLastOpenedNotebookID.erased,
            offlineSavedSourceIDs.erased,
            readAloudConfirmsEstimatedCost.erased,
            readAloudModel.erased,
            readerFontScale.erased,
            siriPendingCommand.erased,
            spacePagesExpanded.erased,
            spaceRecents.erased,
            spaceSort.erased,
            reviewGrader.erased,
            todayWidgetSnapshot.erased,
            readingChatSpeakReplies.erased,
            learningBoutEndedBreaks.erased,
            presentedMoveJobs.erased,
        ]
    }
}
