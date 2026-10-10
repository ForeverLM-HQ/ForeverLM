import Foundation
import Testing
@testable import ForeverLM

@Suite("Followed podcast shows")
struct PodcastFollowTests {
    private func episode(_ title: String, show: String, trackID: Int64?, uuid: String? = nil, played: Date? = nil, published: Date? = nil) -> PodcastEpisodeMetadata {
        PodcastEpisodeMetadata(
            storeTrackId: trackID,
            episodeUUID: uuid,
            episodeGUID: nil,
            episodeTitle: title,
            podcastName: show,
            artworkURL: nil,
            webPageURL: nil,
            episodeDescription: nil,
            enclosureURL: nil,
            ttmlIdentifier: nil,
            lastDatePlayed: played,
            podcastCollectionId: nil,
            publishedAt: published
        )
    }

    @Test("An unplayed episode is dated by its publish date, a played one by its last listen")
    func importedEpisodesTakePublishDateWhenNeverPlayed() {
        let published = Date(timeIntervalSince1970: 1_700_000_000)
        let played = Date(timeIntervalSince1970: 1_750_000_000)
        let rows = StudioViewModel.podcastArticles(from: [
            episode("Never played", show: "S", trackID: 1, published: published),
            episode("Played", show: "S", trackID: 2, played: played, published: published),
        ])
        #expect(rows.first { $0.title == "Never played" }?.dateAdded == published)
        #expect(rows.first { $0.title == "Played" }?.dateAdded == played)
    }

    @Test("An unplayed row imported at the wrong minute is re-dated; played and correct rows are left alone")
    func alignedDateMovesOnlyUnplayedMisdatedRows() {
        let published = Date(timeIntervalSince1970: 1_700_000_000)
        var imported = StudioArticle(url: "apple-podcast://episode/1", title: "E", sourceType: .podcast)
        imported.dateAdded = Date(timeIntervalSince1970: 1_760_000_000)
        #expect(StudioViewModel.alignedDateAdded(existing: imported, episode: episode("E", show: "S", trackID: 1, published: published)) == published)
        #expect(StudioViewModel.alignedDateAdded(existing: imported, episode: episode("E", show: "S", trackID: 1, played: Date(), published: published)) == nil)
        #expect(StudioViewModel.alignedDateAdded(existing: imported, episode: episode("E", show: "S", trackID: 1)) == nil)
        var right = imported
        right.dateAdded = published.addingTimeInterval(20)
        #expect(StudioViewModel.alignedDateAdded(existing: right, episode: episode("E", show: "S", trackID: 1, published: published)) == nil)
    }

    @Test("A followed show's episodes join the listened ones once each, listened rows first")
    func mergeKeepsEachEpisodeOnce() {
        let played = episode("#402", show: "The Drive", trackID: 402, played: Date())
        let listened = [played, episode("Other show", show: "Elsewhere", trackID: 9)]
        let followed = [
            episode("#402", show: "The Drive", trackID: 402),
            episode("#401", show: "The Drive", trackID: 401),
            episode("Private one", show: "The Drive", trackID: nil, uuid: "ABC-123"),
        ]

        let merged = SourceDiscovery.mergeEpisodes(listened: listened, followed: followed)

        #expect(merged.map(\.episodeTitle) == ["#402", "Other show", "#401", "Private one"])
        // The listened copy wins, keeping its last-played date.
        #expect(merged.first?.lastDatePlayed != nil)
    }

    @Test("Nothing followed leaves discovery's result untouched")
    func mergeWithoutFollowedShowsIsIdentity() {
        let listened = [episode("A", show: "S", trackID: 1), episode("B", show: "S", trackID: 2)]
        #expect(SourceDiscovery.mergeEpisodes(listened: listened, followed: []).map(\.episodeTitle) == ["A", "B"])
    }
}

@Suite("Blocked Podcast Shows")
struct BlockedPodcastShowTests {

    private func episode(show: String, title: String) -> PodcastEpisodeMetadata {
        PodcastEpisodeMetadata(
            storeTrackId: nil,
            episodeUUID: "\(show)-\(title)",
            episodeGUID: nil,
            episodeTitle: title,
            podcastName: show,
            artworkURL: nil,
            webPageURL: nil,
            episodeDescription: nil,
            enclosureURL: nil,
            ttmlIdentifier: nil,
            lastDatePlayed: nil,
            podcastCollectionId: nil
        )
    }

    /// Runs `body` with the blocked-show preference restored afterwards. The
    /// list lives in `UserDefaults.standard`, which the test process shares.
    private func withRestoredBlockList(_ body: () throws -> Void) rethrows {
        let key = SourceDiscovery.blockedPodcastShowsPreferenceKey
        let original = UserDefaults.standard.stringArray(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try body()
    }

    @Test("A blocked show's episodes are dropped before they can become sources")
    func blockedEpisodesNeverReachTheLibrary() {
        let episodes = [
            episode(show: "EPIC RADIO", title: "#038"),
            episode(show: "The Metabolic Link", title: "Mitochondria, Muscle, & Aging"),
            episode(show: "EPIC RADIO", title: "#037"),
        ]

        let kept = SourceDiscovery.removingBlockedShows(from: episodes, blockedShows: ["EPIC RADIO"])

        #expect(kept.map(\.episodeTitle) == ["Mitochondria, Muscle, & Aging"])
        // Nothing blocked is the identity, not an empty library.
        #expect(SourceDiscovery.removingBlockedShows(from: episodes, blockedShows: []).count == 3)
    }

    @Test("A blocked name matches the show however it is spelled or padded")
    func blockedNameMatchingIsTrimmedAndCaseFolded() {
        let episodes = [episode(show: "EPIC RADIO", title: "#038")]

        #expect(SourceDiscovery.removingBlockedShows(from: episodes, blockedShows: ["  epic radio "]).isEmpty)
        #expect(SourceDiscovery.removingBlockedShows(from: episodes, blockedShows: ["Epic"]).count == 1)
    }

    @Test("Blocking and letting a show back in round-trip through the preference")
    func blockRoundTripsThroughThePreference() throws {
        try withRestoredBlockList {
            UserDefaults.standard.removeObject(forKey: SourceDiscovery.blockedPodcastShowsPreferenceKey)
            #expect(!SourceDiscovery.isPodcastShowBlocked("EPIC RADIO"))

            #expect(SourceDiscovery.setPodcastShowBlocked("EPIC RADIO", blocked: true))
            #expect(SourceDiscovery.isPodcastShowBlocked("epic radio"))
            #expect(SourceDiscovery.blockedPodcastShowNames() == ["EPIC RADIO"])
            // A second block is not a change, so it must not report one.
            #expect(!SourceDiscovery.setPodcastShowBlocked("EPIC RADIO", blocked: true))

            #expect(SourceDiscovery.setPodcastShowBlocked("  epic radio  ", blocked: false))
            #expect(!SourceDiscovery.isPodcastShowBlocked("EPIC RADIO"))
            // The last name out clears the key rather than leaving an empty array.
            #expect(UserDefaults.standard.object(forKey: SourceDiscovery.blockedPodcastShowsPreferenceKey) == nil)
            #expect(!SourceDiscovery.setPodcastShowBlocked("EPIC RADIO", blocked: false))
        }
    }

    @Test("An empty show name is never blockable")
    func blankShowNameIsRefused() throws {
        try withRestoredBlockList {
            #expect(!SourceDiscovery.setPodcastShowBlocked("   ", blocked: true))
            #expect(!SourceDiscovery.isPodcastShowBlocked(""))
        }
    }

    /// Generation 2 syncs the list as each show's import-blocked mark (`BlockedShowsSync`), so the
    /// preference row is no synced preference.
    @Test("The blocked list syncs as import-blocked marks, not as a preference row")
    func blockedListIsAMarkNotAPreference() {
        let key = SourceDiscovery.blockedPodcastShowsPreferenceKey
        #expect(!SyncedPreferenceKeys.isSynced(key, for: .two))
        #expect(SyncedPreferenceKeys.generation2MovedKeys.contains(key))
    }
}
