import Foundation
import OSLog

/// Searches the iTunes Search API to find Apple Podcasts episodes matching a YouTube video.
///
/// When a YouTube URL is pasted, this service:
/// 1. Extracts the video title from the YouTube page
/// 2. Searches the iTunes podcast episode catalog for a match
/// 3. Returns the Apple Podcasts URL so the user can open it, view the transcript, and sync
actor PodcastFinderService {

    static let shared = PodcastFinderService()

    private let logger = Logger(subsystem: "com.foreverlm", category: "PodcastFinder")
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    struct PodcastMatch: Sendable {
        let podcastName: String
        let episodeTitle: String
        let applePodcastsURL: String
        let artworkURL: String?
        /// Episode store track ID extracted from the Apple Podcasts URL (the `i=` parameter).
        /// Used by `fetchPodcastTranscript` to download the TTML transcript.
        let storeTrackId: Int64?
    }

    struct EpisodeCandidate: Sendable {
        let wrapperType: String?
        let collectionName: String
        let trackName: String
        let trackViewURL: String?
        let collectionViewURL: String
        let artworkURL: String?
        let trackId: Int64?
    }

    /// Given a YouTube URL, try to find the same content as an Apple Podcasts episode.
    /// Returns the best match, or nil if nothing relevant was found.
    ///
    /// Strategy: first find the podcast *show* by channel name, then search for the
    /// specific episode within that show's collection. This avoids matching episodes
    /// from unrelated podcasts that happen to share keywords in the title.
    func findPodcast(forYouTubeURL urlString: String) async -> PodcastMatch? {
        // Step 1: Get video metadata via oEmbed (title + channel name)
        guard let meta = await fetchYouTubeMetadata(urlString) else {
            logger.warning("Could not extract YouTube metadata for: \(urlString)")
            return nil
        }

        // Step 2: Find the podcast show by channel name
        logger.info("Looking up podcast show for channel: \(meta.channelName)")
        if let collectionId = await findPodcastShow(channelName: meta.channelName) {
            // Step 3: Search for the episode within this specific podcast
            logger.info("Searching collection \(collectionId) for episode: \(meta.title)")
            if let match = await searchEpisodesInCollection(
                collectionId: collectionId,
                episodeTitle: meta.title,
                preferredPodcastName: meta.channelName
            ) {
                return match
            }
            logger.info("No episode match in collection \(collectionId), falling back to broad search")
        }

        // Fallback 1: title-only search can recover older episodes that aren't in the
        // limited collection lookup window for long-running feeds.
        logger.info("Falling back to title-only search: \(meta.title)")
        if let match = await searchITunes(query: meta.title, preferredPodcastName: meta.channelName) {
            return match
        }

        // Fallback 2: broad search with channel + title.
        let query = "\(meta.channelName) \(meta.title)"
        logger.info("Falling back to broad search: \(query)")
        return await searchITunes(query: query, preferredPodcastName: meta.channelName)
    }

    /// Look up a podcast show by channel name and return its iTunes collection ID.
    private func findPodcastShow(channelName: String) async -> Int64? {
        let cleaned = Self.cleanSearchQuery(channelName)
        guard !cleaned.isEmpty else { return nil }

        guard var components = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "term", value: cleaned),
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return nil }

            let result = try JSONDecoder().decode(ITunesPodcastSearchResponse.self, from: data)
            let exact = result.results.filter {
                Self.exactIdentityKey($0.collectionName) == Self.exactIdentityKey(cleaned)
            }
            guard exact.count == 1, let show = exact.first else { return nil }
            logger.info("Found podcast show: \(show.collectionName) (ID: \(show.collectionId))")
            return show.collectionId
        } catch {
            logger.error("Podcast show lookup failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Search for episodes within a specific podcast collection using the iTunes lookup API.
    private func searchEpisodesInCollection(
        collectionId: Int64,
        episodeTitle: String,
        preferredPodcastName: String? = nil
    ) async -> PodcastMatch? {
        // iTunes lookup API: get recent episodes for a collection
        guard var components = URLComponents(string: "https://itunes.apple.com/lookup") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "id", value: String(collectionId)),
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcastEpisode"),
            // The API is capped at 200. Using the full window avoids missing
            // matches for longer-running shows like All-In.
            URLQueryItem(name: "limit", value: "200"),
        ]
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return nil }

            let result = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
            let episodes = result.results
                .filter { $0.wrapperType == "podcastEpisode" }
                .map(Self.episodeCandidate(from:))
            guard !episodes.isEmpty else { return nil }

            guard let best = Self.exactEpisodeCandidate(
                from: episodes,
                query: episodeTitle,
                preferredPodcastName: preferredPodcastName
            ) else {
                logger.info("No episode had the exact requested title and show identity")
                return nil
            }

            let match = PodcastMatch(
                podcastName: best.collectionName,
                episodeTitle: best.trackName,
                applePodcastsURL: best.trackViewURL ?? best.collectionViewURL,
                artworkURL: best.artworkURL,
                storeTrackId: Self.extractStoreTrackId(trackId: best.trackId, episodeURL: best.trackViewURL ?? best.collectionViewURL)
            )
            logger.info("Matched exact episode identity: \(match.episodeTitle)")
            return match
        } catch {
            logger.error("Collection episode lookup failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// The episode an Apple Podcasts episode link names, with no search: the
    /// link carries the episode's store track id (`?i=`) and its show's
    /// collection id (`/id…`). A title search could only guess, and missed
    /// both ways: a pasted link's row is titled by its host until fetched, and
    /// an assistant's shortened title is not Apple's (2026-10-02, "Roche will
    /// pay Manifold Bio $55M up front and up to $2B for next-generation brain
    /// shuttles" against Apple's longer one). The episode's title and show come
    /// from the show's recent episodes when the episode is among them, and
    /// otherwise from the show's catalog record and the episode page's own
    /// title. Nil for any other address, or when Apple names no title.
    func findPodcast(forApplePodcastsURL urlString: String) async -> PodcastMatch? {
        guard let identity = Self.applePodcastsEpisodeIdentity(fromURL: urlString) else { return nil }
        logger.info("Apple Podcasts link names episode \(identity.trackId)")

        var showName: String?
        var artworkURL: String?
        if let collectionId = identity.collectionId,
           let results = await lookupShowAndEpisodes(collectionId) {
            if let episode = results.first(where: { $0.wrapperType == "podcastEpisode" && $0.trackId == identity.trackId }) {
                return PodcastMatch(
                    podcastName: episode.collectionName,
                    episodeTitle: episode.trackName,
                    applePodcastsURL: episode.trackViewUrl ?? urlString,
                    artworkURL: episode.artworkUrl100,
                    storeTrackId: identity.trackId
                )
            }
            // Apple lists a show's latest 200 episodes; an older one is still
            // named by its page.
            if let show = results.first(where: { $0.wrapperType != "podcastEpisode" }) {
                showName = show.collectionName
                artworkURL = show.artworkUrl100
            }
        }
        guard let showName,
              let episodeTitle = await episodePageTitle(urlString) else { return nil }
        return PodcastMatch(
            podcastName: showName,
            episodeTitle: episodeTitle,
            applePodcastsURL: urlString,
            artworkURL: artworkURL,
            storeTrackId: identity.trackId
        )
    }

    /// The store track id (`?i=`) and show collection id (`/id…`) of an Apple
    /// Podcasts episode link. Nil for a show page or any other address.
    nonisolated static func applePodcastsEpisodeIdentity(fromURL urlString: String) -> (collectionId: Int64?, trackId: Int64)? {
        guard let components = URLComponents(string: urlString),
              components.host?.lowercased() == "podcasts.apple.com",
              let value = components.queryItems?.first(where: { $0.name == "i" })?.value,
              let trackId = Int64(value) else { return nil }
        let collectionId = components.path.split(separator: "/")
            .last(where: { $0.hasPrefix("id") })
            .flatMap { Int64($0.dropFirst(2)) }
        return (collectionId, trackId)
    }

    /// A show's catalog record followed by its latest episodes.
    private func lookupShowAndEpisodes(_ collectionId: Int64) async -> [ITunesEpisode]? {
        guard var components = URLComponents(string: "https://itunes.apple.com/lookup") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "id", value: String(collectionId)),
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcastEpisode"),
            URLQueryItem(name: "limit", value: "200"),
        ]
        guard let url = components.url else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(ITunesSearchResponse.self, from: data).results
        } catch {
            logger.error("Show lookup failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// The title an Apple Podcasts episode page gives its episode.
    private func episodePageTitle(_ urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let fetched = try? await session.data(for: request),
              (fetched.1 as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: fetched.0, encoding: .utf8) else { return nil }
        return Self.episodeTitle(inApplePodcastsPage: html)
    }

    nonisolated static func episodeTitle(inApplePodcastsPage html: String) -> String? {
        let metas = HTMLTagAttributes.tags(named: "meta", in: html)
        for (attribute, value) in [("name", "apple:title"), ("property", "og:title")] {
            for tag in metas where tag[attribute]?.lowercased() == value {
                let title = (tag["content"] ?? "").decodingHTMLEntities()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { return title }
            }
        }
        return nil
    }

    /// Search for a podcast episode by title/show name (for web URL podcasts).
    func findPodcast(byTitle title: String) async -> PodcastMatch? {
        logger.info("Searching for podcast by title: \(title)")
        return await searchITunes(query: title)
    }

    /// Search iTunes directly with a query string (useful for manual searches too).
    func searchITunes(query: String, preferredPodcastName: String? = nil) async -> PodcastMatch? {
        // Clean up the query: remove common YouTube suffixes
        let cleaned = Self.cleanSearchQuery(query)
        guard !cleaned.isEmpty else { return nil }

        guard var components = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "term", value: cleaned),
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcastEpisode"),
            URLQueryItem(name: "limit", value: "5"),
        ]

        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                logger.warning("iTunes API returned non-200 status")
                return nil
            }

            let result = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
            let candidates = result.results.map(Self.episodeCandidate(from:))

            guard let best = Self.exactEpisodeCandidate(
                from: candidates,
                query: cleaned,
                preferredPodcastName: preferredPodcastName
            ) else {
                logger.info("No podcast episodes found for: \(cleaned)")
                return nil
            }

            let episodeURL = best.trackViewURL ?? best.collectionViewURL
            let trackId = Self.extractStoreTrackId(trackId: best.trackId, episodeURL: episodeURL)

            let match = PodcastMatch(
                podcastName: best.collectionName,
                episodeTitle: best.trackName,
                applePodcastsURL: episodeURL,
                artworkURL: best.artworkURL,
                storeTrackId: trackId
            )
            logger.info("Found exact podcast match: \(match.podcastName) — \(match.episodeTitle)")
            return match
        } catch {
            logger.error("iTunes search failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - YouTube Metadata via oEmbed

    private struct YouTubeMetadata {
        let title: String
        let channelName: String
    }

    /// Uses the YouTube oEmbed API to get video title and channel name reliably.
    private func fetchYouTubeMetadata(_ urlString: String) async -> YouTubeMetadata? {
        guard let videoId = YouTubeTranscriptService.extractVideoId(from: urlString) else { return nil }

        let watchURL = "https://www.youtube.com/watch?v=\(videoId)"
        guard var components = URLComponents(string: "https://www.youtube.com/oembed") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "url", value: watchURL),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return nil }

            let json = try JSONDecoder().decode(OEmbedResponse.self, from: data)
            return YouTubeMetadata(title: json.title, channelName: json.author_name)
        } catch {
            logger.warning("oEmbed fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    private struct OEmbedResponse: Decodable {
        let title: String
        let author_name: String
    }

    // MARK: - Query Cleanup

    static func cleanSearchQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractStoreTrackId(trackId: Int64?, episodeURL: String) -> Int64? {
        if let trackId {
            return trackId
        }
        guard let components = URLComponents(string: episodeURL),
              let iParam = components.queryItems?.first(where: { $0.name == "i" }),
              let value = iParam.value else { return nil }
        return Int64(value)
    }

    static func exactEpisodeCandidate(
        from candidates: [EpisodeCandidate],
        query: String,
        preferredPodcastName: String? = nil
    ) -> EpisodeCandidate? {
        let titleKey = exactIdentityKey(query)
        let showKey = preferredPodcastName.map(exactIdentityKey)
        let exact = candidates.filter { candidate in
            guard candidate.wrapperType == "podcastEpisode",
                  exactIdentityKey(candidate.trackName) == titleKey else { return false }
            guard let showKey else { return true }
            return exactIdentityKey(candidate.collectionName) == showKey
        }
        guard exact.count == 1 else { return nil }
        return exact[0]
    }

    private static func exactIdentityKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func episodeCandidate(from episode: ITunesEpisode) -> EpisodeCandidate {
        EpisodeCandidate(
            wrapperType: episode.wrapperType,
            collectionName: episode.collectionName,
            trackName: episode.trackName,
            trackViewURL: episode.trackViewUrl,
            collectionViewURL: episode.collectionViewUrl,
            artworkURL: episode.artworkUrl100,
            trackId: episode.trackId
        )
    }

    // MARK: - iTunes API Response Models

    private struct ITunesSearchResponse: Decodable {
        let resultCount: Int
        let results: [ITunesEpisode]
    }

    private struct ITunesEpisode: Decodable {
        let wrapperType: String?
        let collectionName: String    // podcast name
        let trackName: String         // episode title
        let trackId: Int64?           // Apple episode store track ID
        let trackViewUrl: String?     // Apple Podcasts episode URL
        let collectionViewUrl: String // Apple Podcasts podcast URL
        let artworkUrl100: String?    // artwork
    }

    private struct ITunesPodcastSearchResponse: Decodable {
        let resultCount: Int
        let results: [ITunesPodcastShow]
    }

    private struct ITunesPodcastShow: Decodable {
        let collectionId: Int64
        let collectionName: String
    }
}

// MARK: - HTML Entity Decoding

private extension String {
    func decodingHTMLEntities() -> String {
        var result = self
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
        ]
        for (entity, char) in entities {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        return result
    }
}
