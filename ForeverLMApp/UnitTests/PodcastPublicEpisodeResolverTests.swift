import Foundation
import Testing
@testable import ForeverLM

/// A private subscriber feed mirrors a public show under a longer name, and
/// Apple transcribes only the public show. The resolver's whole job is exact
/// identity: the show the feed is the private edition of, and the one public
/// episode a row's title names. Every rule here is a place a wrong match would
/// attach another episode's transcript to a row.
@Suite("Podcast public episode resolver")
struct PodcastPublicEpisodeResolverTests {

    private static let privateFeed = "The Peter Attia Drive - Private Subscriber Feed (🔓 for Robin Vale)"

    private static let drive: [PodcastPublicEpisode] = [
        PodcastPublicEpisode(
            trackID: 1000415911177,
            title: "Dom D'Agostino, Ph.D.: ketosis, n=1, exogenous ketones, HBOT, seizures, and cancer",
            episodeNumber: 5,
            webPageURL: "https://peterattiamd.com/domdagostino/"
        ),
        PodcastPublicEpisode(
            trackID: 1000416415276,
            title: "D.A. Wallach: music, medicine, cancer screening, and disruptive technologies",
            episodeNumber: 6,
            webPageURL: nil
        ),
        PodcastPublicEpisode(
            trackID: 1000786906828,
            title: "#406 ‒ Migraine, cluster headache, and tension headache | Brian Grosberg, M.D.",
            episodeNumber: 406,
            webPageURL: nil
        ),
        PodcastPublicEpisode(
            trackID: 1000788234271,
            title: "Blood pressure: how to measure, manage, and treat high blood pressure (AMA #48 rebroadcast)",
            episodeNumber: nil,
            webPageURL: nil
        ),
        PodcastPublicEpisode(
            trackID: 1000579172302,
            title: "How nutrition impacts longevity | Matt Kaeberlein, Ph.D",
            episodeNumber: 222,
            webPageURL: nil
        ),
    ]

    // MARK: - Show identity

    @Test("A member feed's name begins with the public show's name")
    func showIdentityByPrefix() {
        #expect(PodcastPublicEpisodeResolver.showIdentityMatches(
            collectionName: "The Peter Attia Drive",
            showName: Self.privateFeed
        ))
        #expect(PodcastPublicEpisodeResolver.showIdentityMatches(
            collectionName: "The Peter Attia Drive",
            showName: "the peter attia drive"
        ))
        // A longer word is not a qualifier: "The Drive" is not "The Driver".
        #expect(!PodcastPublicEpisodeResolver.showIdentityMatches(
            collectionName: "The Drive",
            showName: "The Driver - Members"
        ))
        // The feed's name must begin with the show's, not merely contain it.
        #expect(!PodcastPublicEpisodeResolver.showIdentityMatches(
            collectionName: "Making Sense with Sam Harris",
            showName: Self.privateFeed
        ))
    }

    @Test("Show name candidates run from the whole name to its shortest qualifier-free prefix")
    func showNameCandidates() {
        let candidates = PodcastPublicEpisodeResolver.publicShowNameCandidates(Self.privateFeed)
        #expect(candidates == [
            Self.privateFeed,
            "The Peter Attia Drive - Private Subscriber Feed",
            "The Peter Attia Drive",
        ])
        #expect(PodcastPublicEpisodeResolver.publicShowNameCandidates("Huberman Lab") == ["Huberman Lab"])
        #expect(PodcastPublicEpisodeResolver.publicShowNameCandidates("   ") == [])
    }

    @Test("A bare hostname is not a show")
    func hostLikeShowNames() {
        #expect(PodcastPublicEpisodeResolver.isHostLikeShowName("peterattiamd.com"))
        #expect(PodcastPublicEpisodeResolver.isHostLikeShowName("a16z.com"))
        #expect(PodcastPublicEpisodeResolver.isHostLikeShowName("feeds.simplecast.com"))
        #expect(!PodcastPublicEpisodeResolver.isHostLikeShowName("The Peter Attia Drive"))
        #expect(!PodcastPublicEpisodeResolver.isHostLikeShowName("Acquired"))
        #expect(!PodcastPublicEpisodeResolver.isHostLikeShowName(""))
    }

    // MARK: - Episode identity

    @Test("Episode numbers are read from the feed's labels and nowhere else")
    func episodeNumbers() {
        #expect(PodcastPublicEpisodeResolver.episodeNumber(inTitle: "#05 – Dom D’Agostino, Ph.D.: ketosis") == 5)
        #expect(PodcastPublicEpisodeResolver.episodeNumber(inTitle: "#400 ‒ AMA #87: Environmental pollution") == 400)
        #expect(PodcastPublicEpisodeResolver.episodeNumber(inTitle: "#113: Normative errors") == 113)
        #expect(PodcastPublicEpisodeResolver.episodeNumber(inTitle: "365 ‒ Training for longevity") == 365)
        #expect(PodcastPublicEpisodeResolver.episodeNumber(inTitle: "E151: WW3 risk, War with Iran?") == 151)
        #expect(PodcastPublicEpisodeResolver.episodeNumber(inTitle: "Ep. 12 - The one about sleep") == 12)
        // A number that is part of the title is not a label.
        #expect(PodcastPublicEpisodeResolver.episodeNumber(inTitle: "10 rules for better sleep") == nil)
        #expect(PodcastPublicEpisodeResolver.episodeNumber(inTitle: "2024 in review: what we learned") == nil)
        #expect(PodcastPublicEpisodeResolver.episodeNumber(inTitle: "Dom D'Agostino, Ph.D.: ketosis") == nil)
        #expect(PodcastPublicEpisodeResolver.episodeNumber(inTitle: "AMA #48 rebroadcast") == nil)
    }

    @Test("Title keys fold the typography two feeds disagree on")
    func titleKeys() {
        let curly = "#05 – Dom D’Agostino, Ph.D.: ketosis, n=1,\u{FEFF} exogenous  ketones | Matt Kaeberlein, Ph.D."
        let plain = "#05 - Dom D'Agostino, Ph.D.: ketosis, n=1, exogenous ketones | Matt Kaeberlein, Ph.D"
        #expect(PodcastPublicEpisodeResolver.identityKey(curly) == PodcastPublicEpisodeResolver.identityKey(plain))
        #expect(
            PodcastPublicEpisodeResolver.identityKeyWithoutEpisodeLabel(curly)
                == PodcastPublicEpisodeResolver.identityKey("Dom D'Agostino, Ph.D.: ketosis, n=1, exogenous ketones | Matt Kaeberlein, Ph.D")
        )
    }

    @Test("The episode number decides when the row's title carries one")
    func matchByNumber() {
        let match = PodcastPublicEpisodeResolver.match(
            "#05 – Dom D’Agostino, Ph.D.: ketosis, n=1, exogenous ketones, HBOT, seizures, and cancer",
            in: Self.drive
        )
        #expect(match?.trackID == 1000415911177)
        // The public side dropped the label from older titles; the number
        // still finds the episode when the private title differs in wording.
        #expect(PodcastPublicEpisodeResolver.match(
            "#06 – D.A. Wallach: music, medicine, longevity, and disruptive technologies",
            in: Self.drive
        )?.trackID == 1000416415276)
        #expect(PodcastPublicEpisodeResolver.match(
            "#222 ‒ How nutrition impacts longevity | Matt Kaeberlein, Ph.D.",
            in: Self.drive
        )?.trackID == 1000579172302)
    }

    @Test("Without a number the folded title decides, label or no label")
    func matchByTitle() {
        #expect(PodcastPublicEpisodeResolver.match(
            "Blood pressure: how to measure, manage, and treat high blood pressure (AMA #48 rebroadcast)",
            in: Self.drive
        )?.trackID == 1000788234271)
        // The public side may carry a label the row lacks.
        #expect(PodcastPublicEpisodeResolver.match(
            "Migraine, cluster headache, and tension headache | Brian Grosberg, M.D.",
            in: Self.drive
        )?.trackID == 1000786906828)
        #expect(PodcastPublicEpisodeResolver.match("An episode nobody published", in: Self.drive) == nil)
    }

    @Test("A number the show never used falls back to the title, and an ambiguous number needs the title")
    func numberFallbacks() {
        // No public episode 999; the title still identifies it.
        #expect(PodcastPublicEpisodeResolver.match(
            "#999 - How nutrition impacts longevity | Matt Kaeberlein, Ph.D",
            in: Self.drive
        )?.trackID == 1000579172302)
        // Two public episodes share a number (a rebroadcast filed under the
        // original's): only the title can pick one.
        let reused = Self.drive + [
            PodcastPublicEpisode(trackID: 42, title: "Ketosis revisited (rebroadcast)", episodeNumber: 5, webPageURL: nil)
        ]
        #expect(PodcastPublicEpisodeResolver.match("#05 - Ketosis revisited (rebroadcast)", in: reused)?.trackID == 42)
        #expect(PodcastPublicEpisodeResolver.match("#05 - Something else entirely", in: reused) == nil)
    }

    // MARK: - Resolution

    /// The catalog here is a table, which no rate limit applies to, so the
    /// searches are not spaced unless a test asks for a gap: the production
    /// 3.2 s between searches made a three-candidate feed name a six-second
    /// test.
    private static func makeResolver(
        searchCalls: Counter = Counter(),
        listCalls: Counter = Counter(),
        shows: [PodcastPublicEpisodeResolver.PublicShow]? = [
            .init(collectionID: 1400828889, name: "The Peter Attia Drive"),
            .init(collectionID: 733163012, name: "Making Sense with Sam Harris"),
        ],
        episodes: [PodcastPublicEpisode]? = drive,
        spacing: Duration = .zero
    ) -> PodcastPublicEpisodeResolver {
        PodcastPublicEpisodeResolver(
            searchShows: { _ in
                await searchCalls.increment()
                return shows
            },
            listEpisodes: { _, _ in
                await listCalls.increment()
                return episodes
            },
            requestSpacing: spacing
        )
    }

    actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    @Test("A private-feed episode resolves to its public twin, and the show is looked up once")
    func resolvesPrivateFeedEpisode() async {
        let searchCalls = Counter()
        let listCalls = Counter()
        let resolver = Self.makeResolver(searchCalls: searchCalls, listCalls: listCalls)

        let first = await resolver.resolve(
            showName: Self.privateFeed,
            episodeTitle: "#05 – Dom D’Agostino, Ph.D.: ketosis, n=1, exogenous ketones, HBOT, seizures, and cancer",
            homeDir: "/tmp"
        )
        #expect(first == .matched(Self.drive[0], showName: "The Peter Attia Drive"))

        let second = await resolver.resolve(
            showName: Self.privateFeed,
            episodeTitle: "#406 ‒ Migraine, cluster headache, and tension headache | Brian Grosberg, M.D.",
            homeDir: "/tmp"
        )
        #expect(second == .matched(Self.drive[2], showName: "The Peter Attia Drive"))
        #expect(await searchCalls.value == 1)
        #expect(await listCalls.value == 1)
    }

    @Test("A show with no public edition, and an episode with no public twin, are distinct answers")
    func absentAnswers() async {
        let noShow = Self.makeResolver(shows: [
            .init(collectionID: 1, name: "Some Other Show"),
        ])
        #expect(await noShow.resolve(showName: "A Members-Only Show", episodeTitle: "#1 - Hello", homeDir: "/tmp") == .noPublicShow)

        let resolver = Self.makeResolver()
        #expect(await resolver.resolve(
            showName: Self.privateFeed,
            episodeTitle: "#900 – A members-only bonus episode",
            homeDir: "/tmp"
        ) == .noMatchingEpisode)

        // A hostname names no show at all; nothing is looked up.
        let searchCalls = Counter()
        let host = Self.makeResolver(searchCalls: searchCalls)
        #expect(await host.resolve(showName: "peterattiamd.com", episodeTitle: "#05 - Dom", homeDir: "/tmp") == .noPublicShow)
        #expect(await searchCalls.value == 0)
    }

    @Test("Transport failures stay failures rather than becoming absences")
    func failuresAreRetryable() async {
        let searchDown = Self.makeResolver(shows: nil)
        #expect(await searchDown.resolve(showName: Self.privateFeed, episodeTitle: "#05 - Dom", homeDir: "/tmp") == .failed)

        let listDown = Self.makeResolver(episodes: nil)
        #expect(await listDown.resolve(showName: Self.privateFeed, episodeTitle: "#05 - Dom", homeDir: "/tmp") == .failed)
    }

    @Test("Two public shows the feed's name begins with is not an identity")
    func ambiguousShows() async {
        let resolver = Self.makeResolver(shows: [
            .init(collectionID: 1, name: "The Peter Attia Drive"),
            .init(collectionID: 2, name: "The Peter Attia Drive"),
        ])
        #expect(await resolver.resolve(showName: Self.privateFeed, episodeTitle: "#05 - Dom", homeDir: "/tmp") == .noPublicShow)
    }

    @Test("Catalog searches keep the resolver's spacing, so a name with several candidates cannot trip the rate limit")
    func searchesArePaced() async {
        let searchCalls = Counter()
        // No show matches, so every candidate of the name is searched in turn.
        let resolver = Self.makeResolver(searchCalls: searchCalls, shows: [], spacing: .milliseconds(40))
        let clock = ContinuousClock()
        let started = clock.now
        #expect(await resolver.resolve(showName: Self.privateFeed, episodeTitle: "#05 - Dom", homeDir: "/tmp") == .noPublicShow)
        let elapsed = clock.now - started
        let calls = await searchCalls.value
        #expect(calls >= 2)
        #expect(elapsed >= .milliseconds(40) * (calls - 1), "\(calls) searches took \(elapsed)")
    }
}
