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

    @Test("An episode with no cover takes the one Apple holds now; one that has a cover keeps it")
    func filledArtworkOnlyForCoverlessEpisodes() {
        let cover = "https://example.test/cover.jpg"
        let withCover = PodcastEpisodeMetadata(
            storeTrackId: 1, episodeUUID: nil, episodeGUID: nil, episodeTitle: "E", podcastName: "S",
            artworkURL: cover, webPageURL: nil, episodeDescription: nil, enclosureURL: nil,
            ttmlIdentifier: nil, lastDatePlayed: nil, podcastCollectionId: nil
        )
        var row = StudioArticle(url: "apple-podcast://episode/1", title: "E", sourceType: .podcast)
        #expect(StudioViewModel.filledArtworkURL(existing: row, episode: withCover) == cover)
        #expect(StudioViewModel.filledArtworkURL(existing: row, episode: episode("E", show: "S", trackID: 1)) == nil)
        row.artworkURL = "https://example.test/own.jpg"
        #expect(StudioViewModel.filledArtworkURL(existing: row, episode: withCover) == nil)
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

/// What the learner plays in Apple Podcasts is listening, on the day they
/// played it: "quiz me on the podcasts I listened to last week" must find it.
@Suite("Apple Podcasts plays as listening")
struct ApplePodcastsListeningTests {

    /// A local moment in October 2026, so day arithmetic is the store's and
    /// not the test machine's clock.
    private func moment(day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = day
        components.hour = hour; components.minute = minute
        return Calendar.current.date(from: components) ?? Date()
    }

    private func savedEpisode(
        _ store: KnowledgeStore,
        trackID: Int64,
        title: String = "Bioelectric Fields",
        show: String = "Field Notes"
    ) throws -> (id: String, url: String) {
        let url = "apple-podcast://episode/\(trackID)"
        var article = StudioArticle(url: url, title: title, sourceType: .podcast, id: "source-episode-\(trackID)")
        article.normalizedURL = URLNormalizer.normalize(url)
        article.domain = show
        article.discoveryOrigin = .applePodcasts
        try store.saveSource(article)
        return (article.id, url)
    }

    private func listen(_ url: String, at playedAt: Date, title: String = "Bioelectric Fields", show: String = "Field Notes") -> ExternalListen {
        ExternalListen(url: url, title: title, showName: show, playedAt: playedAt)
    }

    @Test("A play lands as listening on its own day, on the Schedule and the day's log, with nothing invented")
    func playIsListeningOnItsDay() throws {
        let store = try KnowledgeStore(inMemory: true)
        let episode = try savedEpisode(store, trackID: 1_001)
        let playedAt = moment(day: 8, 14, 30)

        let recorded = try store.recordExternalListening([listen(episode.url, at: playedAt)], now: moment(day: 12, 9))
        #expect(recorded == [episode.id])

        let entry = try #require(try store.loadScheduledSources().first { $0.placement.sourceID == episode.id })
        #expect(entry.isAutomatic)
        #expect(!entry.placement.isCompleted, "a play is never a completion")
        #expect(Calendar.current.isDate(entry.placement.plannedAt, inSameDayAs: playedAt))
        let day = try #require(entry.activityDays.first)
        #expect(entry.activityDays.count == 1)
        #expect(day.kinds == [.listening])
        #expect(day.completedKinds.isEmpty)
        #expect(day.dayStart == Calendar.current.startOfDay(for: playedAt))
        #expect(day.lastActivityAt == playedAt)
        #expect(!day.hasMeasuredDepth, "Apple says when, not how much")
        #expect(try store.sourceEngagedSeconds(sourceID: episode.id) == 0)

        let log = try #require(try store.loadDayPlan("2026-10-08")).activities
        #expect(log.count == 1)
        #expect(log.first?.kind == .listening)
        #expect(log.first?.targetID == episode.id)
        #expect(log.first?.startMinute == 14 * 60 + 30)
        #expect(log.first?.endMinute == 14 * 60 + 31)
        #expect(log.first?.title == "Bioelectric Fields")
    }

    @Test("A re-sync of the same play writes nothing again")
    func resyncIsIdempotent() throws {
        let store = try KnowledgeStore(inMemory: true)
        let episode = try savedEpisode(store, trackID: 1_002)
        let play = listen(episode.url, at: moment(day: 8, 14, 30))

        #expect(try store.recordExternalListening([play], now: moment(day: 12, 9)) == [episode.id])
        #expect(try store.recordExternalListening([play], now: moment(day: 12, 10)).isEmpty)
        // The same episode twice in one batch is one play.
        #expect(try store.recordExternalListening([play, play], now: moment(day: 12, 11)).isEmpty)

        let entry = try #require(try store.loadScheduledSources().first { $0.placement.sourceID == episode.id })
        #expect(entry.activityDays.count == 1)
        #expect(try #require(try store.loadDayPlan("2026-10-08")).activities.count == 1)
    }

    @Test("A later play of the same episode is another day; an older one never moves the Schedule entry back")
    func playsOnOtherDays() throws {
        let store = try KnowledgeStore(inMemory: true)
        let episode = try savedEpisode(store, trackID: 1_003)

        // Heard in ForeverLM on the 11th, then Apple's history says the 8th.
        try store.recordScheduledSourceActivity(sourceID: episode.id, on: moment(day: 11, 20), kind: .listening)
        #expect(try store.recordExternalListening([listen(episode.url, at: moment(day: 8, 7))], now: moment(day: 12, 9)) == [episode.id])
        var entry = try #require(try store.loadScheduledSources().first { $0.placement.sourceID == episode.id })
        #expect(entry.activityDays.count == 2)
        #expect(Calendar.current.isDate(entry.placement.plannedAt, inSameDayAs: moment(day: 11, 0)))

        // A newer play moves the automatic entry forward, as live listening does.
        #expect(try store.recordExternalListening([listen(episode.url, at: moment(day: 12, 8))], now: moment(day: 12, 9)) == [episode.id])
        entry = try #require(try store.loadScheduledSources().first { $0.placement.sourceID == episode.id })
        #expect(entry.activityDays.count == 3)
        #expect(Calendar.current.isDate(entry.placement.plannedAt, inSameDayAs: moment(day: 12, 0)))
    }

    @Test("Listening already logged in ForeverLM later that day covers the play")
    func inAppListeningLaterThatDayCovers() throws {
        let store = try KnowledgeStore(inMemory: true)
        let episode = try savedEpisode(store, trackID: 1_004)
        try store.recordScheduledSourceActivity(sourceID: episode.id, on: moment(day: 8, 16), kind: .listening)

        #expect(try store.recordExternalListening([listen(episode.url, at: moment(day: 8, 14))], now: moment(day: 12, 9)).isEmpty)

        // Reading the same source that day is not listening, so the play still counts.
        let read = try savedEpisode(store, trackID: 1_005, title: "Gap Junctions")
        try store.recordScheduledSourceActivity(sourceID: read.id, on: moment(day: 8, 16), kind: .reading)
        #expect(try store.recordExternalListening([listen(read.url, at: moment(day: 8, 14), title: "Gap Junctions")], now: moment(day: 12, 9)) == [read.id])
        let day = try #require(try store.loadScheduledSources().first { $0.placement.sourceID == read.id }?.activityDays.first)
        #expect(day.kinds == [.reading, .listening])
    }

    @Test("Hidden sources, hidden episodes and hidden shows are not recorded; a let-back-in episode is")
    func hiddenIsNeverRecorded() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = moment(day: 12, 9)
        let playedAt = moment(day: 8, 14)

        let hiddenSource = try savedEpisode(store, trackID: 2_001)
        try store.setSourceHidden(hiddenSource.id, hidden: true)
        let hiddenEpisode = try savedEpisode(store, trackID: 2_002)
        try store.setPodcastEpisodeHidden(hiddenEpisode.id, hidden: true)
        let inHiddenShow = try savedEpisode(store, trackID: 2_003, show: "Market Talk")
        let letBackIn = try savedEpisode(store, trackID: 2_004, show: "Market Talk")
        _ = try store.setPodcastShowHidden("Market Talk", hidden: true)
        try store.setPodcastEpisodeVisibleOverride(letBackIn.id, visible: true)

        let recorded = try store.recordExternalListening([
            listen(hiddenSource.url, at: playedAt),
            listen(hiddenEpisode.url, at: playedAt),
            listen(inHiddenShow.url, at: playedAt, show: "Market Talk"),
            listen(letBackIn.url, at: playedAt, show: "Market Talk"),
            // Played, but never imported: there is no source to record it on.
            listen("apple-podcast://episode/2999", at: playedAt),
        ], now: now)

        #expect(recorded == [letBackIn.id])
        #expect(try store.loadDayPlan("2026-10-08")?.activities.map(\.targetID) == [letBackIn.id])
    }

    @Test("A play finds its episode by the keys the import dedups on, older spellings included")
    func playFindsItsEpisodeLikeTheImport() throws {
        let store = try KnowledgeStore(inMemory: true)
        let playedAt = moment(day: 8, 14)

        // Imported before the canonical form: the row normalized to "episode/<id>".
        var legacy = StudioArticle(url: "apple-podcast:/episode/3001", title: "Legacy Row", sourceType: .podcast, id: "source-legacy-row")
        legacy.normalizedURL = "episode/3001"
        legacy.domain = "Field Notes"
        try store.saveSource(legacy)

        // A private-feed episode first imported under another identifier: show and title find it.
        var privateEpisode = StudioArticle(
            url: "apple-podcast://episode/local/0d6c1f6e", title: "Members Q&A", sourceType: .podcast, id: "source-members-qa"
        )
        privateEpisode.normalizedURL = URLNormalizer.normalize(privateEpisode.url)
        privateEpisode.domain = "Field Notes"
        try store.saveSource(privateEpisode)

        let recorded = try store.recordExternalListening([
            listen("apple-podcast://episode/3001", at: playedAt, title: "Legacy Row"),
            listen("apple-podcast://episode/private/9f2a", at: playedAt, title: "Members Q&A"),
        ], now: moment(day: 12, 9))

        #expect(Set(recorded) == [legacy.id, privateEpisode.id])
    }

    @Test("A sync pass records plays inside the window, at the moment of each play")
    func listensComeFromRecentPlays() {
        let now = moment(day: 12, 9)
        func episode(_ trackID: Int64, played: Date?) -> PodcastEpisodeMetadata {
            PodcastEpisodeMetadata(
                storeTrackId: trackID, episodeUUID: nil, episodeGUID: nil,
                episodeTitle: "Episode \(trackID)", podcastName: "Field Notes",
                artworkURL: nil, webPageURL: nil, episodeDescription: nil, enclosureURL: nil,
                ttmlIdentifier: nil, lastDatePlayed: played, podcastCollectionId: nil
            )
        }
        let listens = StudioViewModel.applePodcastsListens(from: [
            episode(1, played: moment(day: 8, 14)),
            episode(2, played: nil),
            episode(3, played: now.addingTimeInterval(-31 * 86_400)),
            episode(4, played: now.addingTimeInterval(3_600)),
            episode(5, played: now.addingTimeInterval(-29 * 86_400)),
        ], now: now)

        #expect(listens.map(\.url) == ["apple-podcast://episode/1", "apple-podcast://episode/5"])
        #expect(listens.first?.playedAt == moment(day: 8, 14))
        #expect(listens.first?.title == "Episode 1")
        #expect(listens.first?.showName == "Field Notes")
    }
}
