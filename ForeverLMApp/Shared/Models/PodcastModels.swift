// Podcast models, moved out of Models.swift.

import Foundation

/// Audit and staleness proof for the deletion-only podcast ad cleanup.
///
/// The input is preserved separately from canonical `source_content`, so a
/// later contract can be rerun without re-downloading Apple TTML or replacing
/// the learner's last readable transcript while model work is pending.
struct PodcastTranscriptCleanupMetadata: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let cleanerVersion: Int
    let inputSHA256: String
    let cleanSHA256: String
    let preparedAt: Date?
}

struct PodcastTranscriptCleanupCandidate: Sendable {
    let sourceID: String
    let title: String
    let podcastName: String
    let input: String
    let inputSHA256: String
    /// The input is a transcript saved raw, laid out but never formatted, and
    /// is owed the whole formatting pass (speaker names, paragraphs, ad reads)
    /// rather than the ad pass alone (schema 172).
    var formatsTranscript = false
}

/// Who asked for a podcast transcript's formatting pass. A transcript is saved
/// readable first and waits for the pass in `podcast_transcript_cleanup_queue`
/// (schema 172).
enum PodcastTranscriptFormattingRequest: Sendable, Equatable {
    /// Hydration found the transcript on its own: formatted in turn, and not
    /// while the episode is hidden.
    case automatic
    /// The learner asked for this episode: formatted ahead of the rest, hidden
    /// or not.
    case learnerAsked
}

struct PreparedPodcastTranscriptCleanup: Sendable {
    let input: String
    let clean: String
    let metadata: PodcastTranscriptCleanupMetadata
}

/// Info about a matching podcast episode found via the iTunes Search API.
struct PodcastMatchInfo: Codable, Equatable {
    let podcastName: String
    let episodeTitle: String
    let applePodcastsURL: String
}

/// Metadata for a podcast episode looked up from the Apple Podcasts SQLite database.
struct PodcastEpisodeMetadata {
    /// Apple Podcasts public store episode ID. Private RSS feed episodes often store 0 here.
    let storeTrackId: Int64?
    /// Apple Podcasts local episode UUID, used as a stable non-secret ID for private RSS feed episodes.
    let episodeUUID: String?
    /// RSS item GUID. May contain private-feed tokens, so it should not be persisted directly.
    let episodeGUID: String?
    let episodeTitle: String
    let podcastName: String
    let artworkURL: String?
    /// Web page URL for the episode (e.g. Substack post, show notes page)
    let webPageURL: String?
    /// Plain-text or HTML episode notes from Apple Podcasts.
    let episodeDescription: String?
    /// Episode audio/enclosure URL. Private feeds may contain signed URLs, so persist only hashed forms.
    let enclosureURL: String?
    /// Relative TTML transcript path within the Apple Podcasts cache
    let ttmlIdentifier: String?
    /// Core Data timestamp of when the episode was last played
    let lastDatePlayed: Date?
    /// Apple Podcasts store collection ID for the parent podcast (used to construct Apple Podcasts URLs)
    let podcastCollectionId: Int64?
    /// When the episode was published, from the feed. An episode the learner
    /// never played takes this as its date in the library, so a back catalog
    /// sorts in episode order rather than by the minute it was imported.
    var publishedAt: Date? = nil
}

/// A play Apple Podcasts saw, as podcast discovery hands it to the store to
/// record as listening (`KnowledgeStore.recordExternalListening`).
struct ExternalListen: Equatable, Sendable {
    /// The episode's library URL, as discovery mints it (`SourceDiscovery.podcastEpisodeURL`).
    let url: String
    let title: String
    let showName: String
    /// Apple's `ZLASTDATEPLAYED`: the moment of the episode's last play.
    let playedAt: Date
}

/// Describes why Apple Podcasts discovery returned no results,
/// so the UI can guide the user instead of showing a silent empty state.
enum PodcastDiscoveryStatus: Equatable {
    /// Discovery succeeded (may still have zero episodes if none are played)
    case ok
    /// Not running on macOS — Apple Podcasts DB is macOS-only
    case unsupportedPlatform
    /// Apple Podcasts is not installed (database file missing)
    case appNotInstalled
    /// Database exists but macOS denied access to it.
    case permissionDenied
    /// Database exists but SQLite could not open it for a non-permission reason.
    case openFailed(details: String)
    /// Database opened but expected tables/columns are missing (Apple changed the schema)
    case schemaChanged(details: String)
    /// Query executed but returned zero rows
    case noEpisodesFound
}
