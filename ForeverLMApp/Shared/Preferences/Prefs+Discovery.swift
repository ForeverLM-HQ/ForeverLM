import Foundation

// Generated for step 0 of the typed settings layer from the key census; kept by hand from here on.
// A name is the stored string and is frozen (`UnitTests/Fixtures/preference-keys.golden.json`).

extension Prefs {
    /// Source discovery: podcasts, YouTube, the browsers' reading lists.
    enum Discovery {
        /// Plugin toggles and discovery scope.
        static let youtubeAutoImportEnabled = AccountKey<Bool?>("youtube.autoImportEnabled")
        static let youtubeLikedTranscriptFormattingEnabled = AccountKey<Bool?>("youtube.likedTranscriptFormattingEnabled")
        static let applePodcastDiscoveryScope = AccountKey<String?>("studio.applePodcastDiscoveryScope")
        static let youtubeFallbackShows = AccountKey<[String]?>("podcasts.youtubeFallbackShows")
        /// Whether a model reads the references the free pass left without a link
        /// when a paper is added (`PaperReferenceModelReading`). A spending
        /// decision, so it follows the account.
        static let paperReferenceModelReading = AccountKey<Bool>("papers.references.modelReading", default: true)
        /// Shows whose episodes are never imported. This one has to sync or it
        /// does not work: both Macs read the same Apple Podcasts library, so a
        /// block held on one of them is undone by the other importing the same
        /// episodes and syncing the rows straight back. (The follow list next to
        /// it in the preference store is deliberately not here — it only adds
        /// episodes that already reach both Macs through sync anyway, so a
        /// per-Mac follow costs nothing.)
        static let blockedPodcastShows = AccountKey<[String]?>("podcasts.blockedShows", .record)
        /// Shows the learner follows whole: discovery brings in every episode
        /// Apple Podcasts holds for them, not only the listened ones. It steers a
        /// Mac-only import rather than describing a source.
        static let followedPodcastShows = DeviceKey<[String]?>("podcasts.followedShows", reason: "a follow only adds episodes that already reach every Mac through sync, so a per-Mac follow costs nothing")
        /// `defaults write` escape hatches. Moving them to SQLite would remove the
        /// CLI workaround entirely. (Note: these are currently broken for an
        /// unrelated reason — the sandboxed and non-sandboxed builds read different
        /// preference domains, so `defaults write com.foreverlm` targets a plist the
        /// dev builds never read.)
        static let preferredBrowser = DeviceKey<String?>("preferredBrowser", reason: "defaults-write escape hatch")
        static let readingListSafari = DeviceKey<Bool?>("readingListSafari", reason: "per-Mac browser choice from setup; each Mac has its own browsers")
        static let readingListChrome = DeviceKey<Bool?>("readingListChrome", reason: "per-Mac browser choice from setup; each Mac has its own browsers")
        static let readingListBrave = DeviceKey<Bool?>("readingListBrave", reason: "per-Mac browser choice from setup; each Mac has its own browsers")
        static let readingListImportSince = DeviceKey<Double?>("readingList.importSince", reason: "per-Mac Reading List backlog cutoff from setup; qualifies the per-Mac browser choice")
        static let readingListImportWindow = DeviceKey<String?>("readingList.importWindow", reason: "per-Mac Reading List backlog choice from setup; names the cutoff above")
        static let browserAccessPromptDismissed = DeviceKey<Any?>("discovery.browserAccessPromptDismissed", coding: .any, reason: "whether this Mac's browser-access prompt was dismissed; the permission is per Mac")
        static let podcastAccessPromptDismissed = DeviceKey<Any?>("discovery.podcastAccessPromptDismissed", coding: .any, reason: "whether this Mac's podcast-access prompt was dismissed; the permission is per Mac")
        static let retiredYouTubeHiddenChannels = DeviceKey<Any?>.unread("youtube.hiddenChannels", reason: "retired: migrated into the hidden-channels table, which syncs, and then removed")

        static let all: [AnyPreferenceKey] = [
            youtubeAutoImportEnabled.erased,
            youtubeLikedTranscriptFormattingEnabled.erased,
            applePodcastDiscoveryScope.erased,
            youtubeFallbackShows.erased,
            paperReferenceModelReading.erased,
            blockedPodcastShows.erased,
            followedPodcastShows.erased,
            preferredBrowser.erased,
            readingListSafari.erased,
            readingListChrome.erased,
            readingListBrave.erased,
            readingListImportSince.erased,
            readingListImportWindow.erased,
            browserAccessPromptDismissed.erased,
            podcastAccessPromptDismissed.erased,
            retiredYouTubeHiddenChannels.erased,
        ]
    }
}
