import Testing
@testable import ForeverLM

@Suite("Podcast Finder Matching")
struct PodcastFinderServiceTests {

    @Test("Uses direct track ID when iTunes payload provides one")
    func usesDirectTrackId() {
        let result = PodcastFinderService.extractStoreTrackId(
            trackId: 1000757784841,
            episodeURL: "https://podcasts.apple.com/us/podcast/all-in/id1502871393?uo=4"
        )

        #expect(result == 1000757784841)
    }

    @Test("Falls back to i parameter when direct track ID is missing")
    func fallsBackToTrackIdInURL() {
        let result = PodcastFinderService.extractStoreTrackId(
            trackId: nil,
            episodeURL: "https://podcasts.apple.com/us/podcast/all-in/id1502871393?i=1000757784841&uo=4"
        )

        #expect(result == 1000757784841)
    }

    @Test("Resolves only an exact episode identity")
    func resolvesExactEpisodeIdentity() {
        let show = PodcastFinderService.EpisodeCandidate(
            wrapperType: "track",
            collectionName: "All-In with Chamath, Jason, Sacks & Friedberg",
            trackName: "All-In with Chamath, Jason, Sacks & Friedberg",
            trackViewURL: "https://podcasts.apple.com/us/podcast/all-in/id1502871393?uo=4",
            collectionViewURL: "https://itunes.apple.com/us/podcast/all-in/id1502871393?mt=2&uo=4",
            artworkURL: nil,
            trackId: 1502871393
        )

        let episode = PodcastFinderService.EpisodeCandidate(
            wrapperType: "podcastEpisode",
            collectionName: "All-In with Chamath, Jason, Sacks & Friedberg",
            trackName: "E151: WW3 risk, War with Iran?, 4.9% GDP, startup failures growing, new Speaker & more",
            trackViewURL: "https://podcasts.apple.com/us/podcast/e151/id1502871393?i=1000757784841&uo=4",
            collectionViewURL: "https://itunes.apple.com/us/podcast/all-in/id1502871393?mt=2&uo=4",
            artworkURL: nil,
            trackId: 1000757784841
        )

        let best = PodcastFinderService.exactEpisodeCandidate(
            from: [show, episode],
            query: episode.trackName,
            preferredPodcastName: episode.collectionName
        )

        #expect(best?.trackId == 1000757784841)
    }

    @Test("An Apple Podcasts episode link names its episode and its show")
    func applePodcastsLinkNamesItsEpisode() {
        let identity = PodcastFinderService.applePodcastsEpisodeIdentity(
            fromURL: "https://podcasts.apple.com/us/podcast/roche-will-pay-manifold-bio-%2455m-up-front-and-up-to/id1796836887?i=1000735033082"
        )
        #expect(identity?.trackId == 1000735033082)
        #expect(identity?.collectionId == 1796836887)

        // A show page names no episode, and no other host is Apple's.
        #expect(PodcastFinderService.applePodcastsEpisodeIdentity(fromURL: "https://podcasts.apple.com/us/podcast/biotechtv-news/id1796836887") == nil)
        #expect(PodcastFinderService.applePodcastsEpisodeIdentity(fromURL: "https://example.com/podcast/id1796836887?i=1000735033082") == nil)
    }

    @Test("An Apple Podcasts page's own title is the episode's")
    func readsEpisodeTitleFromApplePage() {
        let html = """
        <head><title>Roche will pay Manifold Bio $5… - BiotechTV - News - Apple Podcasts</title>
        <meta property="og:description" content="Podcast Episode · BiotechTV - News · November 3, 2025 · 16m">
        <meta content="Roche will pay Manifold Bio $55M up front, and up to $2B in biobucks, to collaborate on multiple next-generation brain shuttles for neurological diseases" name="apple:title">
        <meta property="og:title" content="Something else"></head>
        """
        #expect(PodcastFinderService.episodeTitle(inApplePodcastsPage: html)
            == "Roche will pay Manifold Bio $55M up front, and up to $2B in biobucks, to collaborate on multiple next-generation brain shuttles for neurological diseases")
        #expect(PodcastFinderService.episodeTitle(inApplePodcastsPage: #"<meta property="og:title" content="Q&amp;A with the founders">"#)
            == "Q&A with the founders")
        #expect(PodcastFinderService.episodeTitle(inApplePodcastsPage: "<head></head>") == nil)
    }
}
