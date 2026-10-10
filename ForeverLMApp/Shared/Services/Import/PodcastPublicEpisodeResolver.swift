import Foundation
import OSLog

/// One episode of a show as Apple's public catalog lists it.
struct PodcastPublicEpisode: Sendable, Equatable {
    /// Apple's store track id, the identity the transcript API is keyed by.
    let trackID: Int64
    let title: String
    /// The feed's `<itunes:episode>` number, when the publisher sets one.
    let episodeNumber: Int?
    /// The episode's own web page, when the feed names one.
    let webPageURL: String?
}

enum PodcastPublicEpisodeResolution: Sendable, Equatable {
    /// The public catalog holds this episode; `showName` is the catalog's name
    /// for the show, which may be shorter than the feed the row came from.
    case matched(PodcastPublicEpisode, showName: String)
    /// Apple's catalog has no show this feed is the private edition of.
    case noPublicShow
    /// The show exists publicly but no episode carries this one's identity.
    case noMatchingEpisode
    /// A transport or token failure; nothing here says the episode is absent.
    case failed
}

/// Finds the public Apple Podcasts episode behind a row that has no public
/// identity of its own: an episode from a private subscriber feed, or a row
/// that was filed under the episode's web page.
///
/// Member feeds (Supercast, Patreon, Apple's own subscriptions) mirror the
/// public show under a longer name — "The Peter Attia Drive - Private
/// Subscriber Feed (🔓 for …)" — and the episodes in them carry the public
/// show's titles and numbering. Apple transcribes the public catalog, never a
/// private feed, so the public twin is where the transcript lives.
///
/// Identity is exact or nothing. The show matches when the catalog's name is
/// the feed's name, or the feed's name begins with it at a word boundary. An
/// episode matches by its number within that show when the row's title carries
/// one, and otherwise by its title with typography folded — dashes, quotes,
/// invisible characters — with or without the leading number. A match that is
/// not unique is no match.
actor PodcastPublicEpisodeResolver {
    static let shared = PodcastPublicEpisodeResolver()

    struct PublicShow: Sendable, Equatable {
        let collectionID: Int64
        let name: String
    }

    typealias ShowSearch = @Sendable (String) async -> [PublicShow]?
    typealias EpisodeListing = @Sendable (Int64, String) async -> [PodcastPublicEpisode]?

    private let searchShows: ShowSearch
    private let listEpisodes: EpisodeListing
    private var collectionByShowName: [String: Int64?] = [:]
    private var episodesByCollection: [Int64: [PodcastPublicEpisode]] = [:]
    private var lastITunesRequest: ContinuousClock.Instant?
    private let requestSpacing: Duration

    /// The iTunes Search API allows roughly twenty calls a minute per address.
    static let iTunesRequestSpacing: Duration = .seconds(3.2)

    /// `requestSpacing` is the gap kept between catalog searches; it is the
    /// iTunes limit unless a test stands in for the catalog, which no rate
    /// limit applies to.
    init(
        searchShows: ShowSearch? = nil,
        listEpisodes: EpisodeListing? = nil,
        requestSpacing: Duration = PodcastPublicEpisodeResolver.iTunesRequestSpacing
    ) {
        self.searchShows = searchShows ?? Self.searchShowsInITunes
        self.listEpisodes = listEpisodes ?? Self.listEpisodesInAppleCatalog
        self.requestSpacing = requestSpacing
    }

    // MARK: - Resolution

    func resolve(showName: String, episodeTitle: String, homeDir: String) async -> PodcastPublicEpisodeResolution {
        let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "PodcastIdentity")
        let showKey = Self.identityKey(showName)
        guard !showKey.isEmpty, !Self.isHostLikeShowName(showName) else { return .noPublicShow }

        let collectionID: Int64
        if let cached = collectionByShowName[showKey] {
            guard let cached else { return .noPublicShow }
            collectionID = cached
        } else {
            switch await findPublicShow(named: showName) {
            case .found(let show):
                collectionByShowName[showKey] = show.collectionID
                collectionID = show.collectionID
            case .absent:
                collectionByShowName[showKey] = .some(nil)
                log.info("No public Apple Podcasts show stands behind \(showName, privacy: .public)")
                return .noPublicShow
            case .failed:
                return .failed
            }
        }

        let episodes: [PodcastPublicEpisode]
        if let cached = episodesByCollection[collectionID] {
            episodes = cached
        } else {
            guard let listed = await listEpisodes(collectionID, homeDir) else { return .failed }
            episodesByCollection[collectionID] = listed
            episodes = listed
        }

        guard let match = Self.match(episodeTitle, in: episodes) else {
            log.info("No public episode carries the identity of \(episodeTitle, privacy: .public)")
            return .noMatchingEpisode
        }
        let publicShowName = publicShowNames[collectionID] ?? showName
        return .matched(match, showName: publicShowName)
    }

    private var publicShowNames: [Int64: String] = [:]

    private enum ShowLookup {
        case found(PublicShow)
        case absent
        case failed
    }

    /// Searches the catalog for the feed's name, then for each shorter form of
    /// it — the name with a trailing qualifier cut off — until a show whose
    /// name the feed's name begins with turns up. The first search usually
    /// suffices: iTunes ranks the public show first for its private edition.
    private func findPublicShow(named showName: String) async -> ShowLookup {
        var sawFailure = false
        for candidate in Self.publicShowNameCandidates(showName) {
            await paceITunesRequest()
            guard let shows = await searchShows(candidate) else {
                sawFailure = true
                continue
            }
            let matches = shows.filter { Self.showIdentityMatches(collectionName: $0.name, showName: showName) }
            // Several public shows whose names the feed's name begins with is
            // not an identity; the longest name is the most specific claim,
            // and only an unambiguous one counts.
            let longest = matches.map(\.name.count).max()
            let best = matches.filter { $0.name.count == longest }
            if best.count == 1, let show = best.first {
                publicShowNames[show.collectionID] = show.name
                return .found(show)
            }
        }
        return sawFailure ? .failed : .absent
    }

    private func paceITunesRequest() async {
        let clock = ContinuousClock()
        if let last = lastITunesRequest {
            let due = last + requestSpacing
            let now = clock.now
            if due > now {
                try? await Task.sleep(for: due - now)
            }
        }
        lastITunesRequest = clock.now
    }

    // MARK: - Identity rules

    /// A podcast row's `domain` is the show's name when discovery filed it and
    /// a bare hostname when a pasted link did. Only a named show can be looked
    /// up; a hostname says nothing about which show the page belongs to.
    nonisolated static func isHostLikeShowName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return false }
        return trimmed.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+$"#, options: .regularExpression) != nil
    }

    /// The feed's name, then each prefix of it cut at a qualifier boundary,
    /// longest first: "The Drive - Private Subscriber Feed (for X)" yields the
    /// whole name, "The Drive - Private Subscriber Feed", and "The Drive".
    nonisolated static func publicShowNameCandidates(_ showName: String) -> [String] {
        let full = showName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return [] }
        var candidates = [full]
        let separators = [" - ", " – ", " — ", " ‒ ", " (", ": ", " | ", " [", " •"]
        var cuts: [Int] = []
        for separator in separators {
            var searchRange = full.startIndex..<full.endIndex
            while let range = full.range(of: separator, range: searchRange) {
                cuts.append(full.distance(from: full.startIndex, to: range.lowerBound))
                searchRange = range.upperBound..<full.endIndex
            }
        }
        for cut in Set(cuts).sorted(by: >) {
            let prefix = String(full.prefix(cut)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard prefix.count >= 3, !candidates.contains(prefix) else { continue }
            candidates.append(prefix)
        }
        return candidates
    }

    /// The catalog's show is the feed's show when the names agree, or when the
    /// feed's name begins with the catalog's name and continues with a
    /// qualifier rather than more letters ("The Drive" is not "The Driver").
    nonisolated static func showIdentityMatches(collectionName: String, showName: String) -> Bool {
        let collection = identityKey(collectionName)
        let show = identityKey(showName)
        guard !collection.isEmpty, !show.isEmpty else { return false }
        if collection == show { return true }
        guard show.hasPrefix(collection) else { return false }
        let next = show[show.index(show.startIndex, offsetBy: collection.count)]
        return !(next.isLetter || next.isNumber)
    }

    /// A leading episode number: "#05 – Title", "#113: Title", "365 ‒ Title",
    /// "Ep. 12 - Title", "E151: Title". A number that runs straight into words
    /// ("10 rules for …", "2024 in review") is part of the title, not a label.
    nonisolated static func episodeNumber(inTitle title: String) -> Int? {
        let pattern = #"^\s*(?:#|(?:ep(?:isode)?\.?|e)\s*#?)?\s*(\d{1,4})\s*[-–—‒:|.]\s+"#
        let folded = foldTypography(title)
        guard let match = folded.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let label = folded[match]
        let digits = label.filter(\.isNumber)
        guard let number = Int(digits), number > 0 else { return nil }
        // "#05 –" and "E151:" are labels; a bare "2024 -" at the start is too,
        // but a bare number without a marker only counts when the separator
        // is a dash, the way feeds without "#" number their episodes.
        let hasMarker = label.contains("#") || label.lowercased().contains("e")
        if !hasMarker, !label.contains("-") { return nil }
        return number
    }

    /// Case, diacritics, dash and quote variants, invisible characters and
    /// whitespace runs folded away, and a trailing period dropped, so the same
    /// title typed twice by two feeds compares equal.
    nonisolated static func identityKey(_ value: String) -> String {
        var key = foldTypography(value)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        key = key.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while key.hasSuffix(".") { key.removeLast() }
        return key.trimmingCharacters(in: .whitespaces)
    }

    /// The identity key with a leading episode label removed, so "#05 – X"
    /// and "X" agree.
    nonisolated static func identityKeyWithoutEpisodeLabel(_ value: String) -> String {
        let pattern = #"^\s*(?:#|(?:ep(?:isode)?\.?|e)\s*#?)?\s*\d{1,4}\s*[-–—‒:|.]\s+"#
        let folded = foldTypography(value)
        let stripped = folded.replacingOccurrences(
            of: pattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return identityKey(stripped)
    }

    private nonisolated static func foldTypography(_ value: String) -> String {
        var folded = value
        for (variant, plain) in [
            ("\u{2010}", "-"), ("\u{2011}", "-"), ("\u{2012}", "-"), ("\u{2013}", "-"),
            ("\u{2014}", "-"), ("\u{2015}", "-"), ("\u{2212}", "-"),
            ("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{201A}", "'"), ("\u{2032}", "'"),
            ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{201E}", "\""),
            ("\u{2026}", "..."),
            ("\u{00A0}", " "), ("\u{2009}", " "), ("\u{202F}", " "),
            ("\u{FEFF}", ""), ("\u{200B}", ""), ("\u{200C}", ""), ("\u{200D}", ""), ("\u{00AD}", ""),
        ] {
            folded = folded.replacingOccurrences(of: variant, with: plain)
        }
        return folded
    }

    /// The one public episode this title names, or nil. The episode number is
    /// the strongest identity a feed carries, so it decides first; a title
    /// without a number falls back to the folded title, then to the folded
    /// title with the public side's own label removed. Every rule requires a
    /// single hit.
    nonisolated static func match(_ title: String, in episodes: [PodcastPublicEpisode]) -> PodcastPublicEpisode? {
        if let number = episodeNumber(inTitle: title) {
            let numbered = episodes.filter { $0.episodeNumber == number }
            if numbered.count == 1 { return numbered[0] }
            if numbered.count > 1 {
                // A publisher who reuses a number (a rebroadcast filed under
                // the original's number) leaves the title to decide.
                let byTitle = numbered.filter { titlesAgree($0.title, title) }
                return byTitle.count == 1 ? byTitle[0] : nil
            }
            // A row whose title carries a number the public side never set
            // still matches by title: labels are the feed's, not the episode's.
        }
        let exact = episodes.filter { titlesAgree($0.title, title) }
        return exact.count == 1 ? exact[0] : nil
    }

    private nonisolated static func titlesAgree(_ lhs: String, _ rhs: String) -> Bool {
        let left = identityKey(lhs)
        let right = identityKey(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        let leftStripped = identityKeyWithoutEpisodeLabel(lhs)
        let rightStripped = identityKeyWithoutEpisodeLabel(rhs)
        guard !leftStripped.isEmpty, !rightStripped.isEmpty else { return false }
        return leftStripped == rightStripped
    }

    // MARK: - Apple's catalog

    private struct ITunesShowSearchResponse: Decodable {
        struct Show: Decodable {
            let collectionId: Int64
            let collectionName: String
        }
        let results: [Show]
    }

    /// iTunes Search for shows by name. Nil is a transport failure; an empty
    /// list is a real answer.
    private static let searchShowsInITunes: ShowSearch = { term in
        guard var components = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(ITunesShowSearchResponse.self, from: data)
            return decoded.results.map { PublicShow(collectionID: $0.collectionId, name: $0.collectionName) }
        } catch {
            return nil
        }
    }

    private struct CatalogEpisodesPage: Decodable {
        struct Episode: Decodable {
            struct Attributes: Decodable {
                let name: String
                let episodeNumber: Int?
                let websiteUrl: String?
            }
            let id: String
            let attributes: Attributes
        }
        let data: [Episode]
        let next: String?
    }

    /// Every episode of a show from the same catalog service the transcript
    /// API lives on, fifty a page, with the feed's episode numbers. The iTunes
    /// lookup API stops at a show's latest 200 episodes and drops the numbers,
    /// which is why the catalog is asked instead. Nil is a failure (a token that
    /// could not be minted, a transport error); the caller keeps the row
    /// retryable rather than deciding the episode is absent.
    private static let listEpisodesInAppleCatalog: EpisodeListing = { collectionID, homeDir in
        let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "PodcastIdentity")
        var path: String? = "/v1/catalog/us/podcasts/\(collectionID)/episodes?limit=50&l=en-US"
        var episodes: [PodcastPublicEpisode] = []
        var pages = 0
        var refreshedToken = false
        while let nextPath = path, pages < 200 {
            guard let url = URL(string: "https://amp-api.podcasts.apple.com" + nextPath) else { return nil }
            guard let bearer = await StudioViewModel.obtainPodcastBearerToken(
                homeDir: homeDir,
                forceRefresh: refreshedToken
            ) else {
                log.warning("Could not obtain an Apple Podcasts token to list show \(collectionID)")
                return nil
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { return nil }
                if http.statusCode == 401, !refreshedToken {
                    StudioViewModel.invalidateCachedPodcastBearerTokens(homeDir: homeDir)
                    refreshedToken = true
                    continue
                }
                guard http.statusCode == 200 else {
                    log.warning("Apple catalog returned \(http.statusCode) listing show \(collectionID)")
                    return nil
                }
                let page = try JSONDecoder().decode(CatalogEpisodesPage.self, from: data)
                for episode in page.data {
                    guard let trackID = Int64(episode.id) else { continue }
                    episodes.append(PodcastPublicEpisode(
                        trackID: trackID,
                        title: episode.attributes.name,
                        episodeNumber: episode.attributes.episodeNumber,
                        webPageURL: episode.attributes.websiteUrl
                    ))
                }
                path = page.next
                pages += 1
            } catch {
                log.warning("Listing show \(collectionID) failed: \(error.localizedDescription)")
                return nil
            }
        }
        return episodes
    }
}
