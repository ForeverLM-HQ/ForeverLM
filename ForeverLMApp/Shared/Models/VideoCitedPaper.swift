import Foundation

/// A source another source points at, held as a candidate until the learner decides.
///
/// Born as the papers read off a video's slides, hence the name; the same row now also
/// carries the papers a paper's reference list cites, the papers a meeting mentions, and —
/// since schema 115 — the pages, videos, podcasts and papers an article links to. `kind`
/// says which; every other field keeps its meaning across kinds.
struct VideoCitedPaper: Identifiable, Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable {
        /// Resolved to a real paper, waiting on the learner.
        case pending
        /// Read off a slide, but no matching paper could be resolved. Surfaced rather than
        /// dropped, so a failed lookup never reads as an absent citation.
        case unresolved
        /// Imported into the library. `importedSourceID` points at the paper source.
        case imported
        /// The learner waved this one off. Kept as a row so it stays dismissed across
        /// devices, and so the decision can be undone.
        case dismissed
    }

    /// What kind of source the candidate is, which decides how it is described and, on
    /// import, which pipeline adds it. Read deterministically off the URL by
    /// `StudioViewModel.detectSourceType`; a model never chooses it.
    enum Kind: String, Codable, Sendable, CaseIterable {
        case paper
        case article
        case video
        case podcast
        /// An X post. Named after the source type it imports as.
        case xPost

        /// The word a list row uses beside the site.
        var label: String {
            switch self {
            case .paper: return "Paper"
            case .article: return "Article"
            case .video: return "Video"
            case .podcast: return "Podcast"
            case .xPost: return "Post"
            }
        }

        /// The kind a URL imports as, folding the storage-only states of a web page
        /// (`manual`, `unclassified`, and everything typed from a local path) into
        /// `article`: a link is always a web page, and an unknown web page is an article
        /// until the article pipeline says otherwise.
        init(sourceType: StudioSourceType) {
            switch sourceType {
            case .paper: self = .paper
            case .video: self = .video
            case .podcast: self = .podcast
            case .xPost: self = .xPost
            case .article, .book, .course, .meeting, .manual, .unclassified: self = .article
            }
        }
    }

    let id: String
    /// The source whose slides, transcript, notes, references or links this was read from.
    var sourceID: String
    /// Title as read from the slide, before resolution. Plain text, like a source's: a
    /// catalog's `Cytochrome <i>c</i>` is kept as "Cytochrome c".
    var title: String
    var authors: String?
    var year: String?
    var journal: String?
    var doi: String?
    /// Canonical landing page or PDF URL, once resolved.
    var url: String?
    /// When the slide this was read from first comes on screen. Drives seeks and ordering;
    /// the reader overlay keys on the slide's own on-screen windows, reached through
    /// `slideImagePath`, and falls back to this only for rows that match no slide.
    var slideTimeSeconds: Double?
    /// Relative path to the stored slide frame. This is the paper's tie to its slide —
    /// timestamps resolve only to the storyboard's tile interval, so two slides can round
    /// onto the same one — as well as the evidence shown for what was read.
    var slideImagePath: String?
    var status: Status
    /// The paper source created on import. Carried through sync so a second Mac knows this
    /// candidate is already satisfied instead of offering it again.
    var importedSourceID: String?
    /// What kind of source this is. Every candidate written before schema 115 is a paper.
    var kind: Kind
    /// For a source read off an article's links: one line on what the article says about
    /// it, so the list can be judged without opening every link. Nil for the paper kinds
    /// read from slides, transcripts and reference lists, whose bibliographic fields say
    /// enough.
    var context: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        sourceID: String,
        title: String,
        authors: String? = nil,
        year: String? = nil,
        journal: String? = nil,
        doi: String? = nil,
        url: String? = nil,
        slideTimeSeconds: Double? = nil,
        slideImagePath: String? = nil,
        status: Status = .pending,
        importedSourceID: String? = nil,
        kind: Kind = .paper,
        context: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sourceID = sourceID
        self.title = title.decodingTitleMarkup()
        self.authors = authors
        self.year = year
        self.journal = journal
        self.doi = doi
        self.url = url
        self.slideTimeSeconds = slideTimeSeconds
        self.slideImagePath = slideImagePath
        self.status = status
        self.importedSourceID = importedSourceID
        self.kind = kind
        self.context = context
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceID, title, authors, year, journal, doi, url
        case slideTimeSeconds, slideImagePath, status, importedSourceID
        case kind, context, createdAt, updatedAt
    }

    /// `kind` and `context` arrived with schema 115. A record written by an older build —
    /// or by a Mac still on one — carries neither, and every such candidate is a paper.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sourceID = try container.decode(String.self, forKey: .sourceID)
        title = try container.decode(String.self, forKey: .title).decodingTitleMarkup()
        authors = try container.decodeIfPresent(String.self, forKey: .authors)
        year = try container.decodeIfPresent(String.self, forKey: .year)
        journal = try container.decodeIfPresent(String.self, forKey: .journal)
        doi = try container.decodeIfPresent(String.self, forKey: .doi)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        slideTimeSeconds = try container.decodeIfPresent(Double.self, forKey: .slideTimeSeconds)
        slideImagePath = try container.decodeIfPresent(String.self, forKey: .slideImagePath)
        status = try container.decode(Status.self, forKey: .status)
        importedSourceID = try container.decodeIfPresent(String.self, forKey: .importedSourceID)
        // An unknown kind from a newer build reads as a paper rather than failing the
        // whole record: the row still lists, and the URL still says what it is on import.
        kind = try container.decodeIfPresent(String.self, forKey: .kind).flatMap(Kind.init(rawValue:)) ?? .paper
        context = try container.decodeIfPresent(String.self, forKey: .context)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    /// Stand-in label for a paper the slide credited without printing its title — the small
    /// "Hayashida et al. BMC Medicine, 2023" under a figure. Replaced by the real title once a
    /// lookup resolves it. A credit with no author either — "(PNAS, 1980 77:3430-4)" — leads
    /// with its venue, "PNAS, 1980": the card over it already says it is a cited paper.
    static func attributionLabel(authors: String?, journal: String?, year: String?) -> String {
        let lead = authors?
            .split(separator: ";")
            .first
            .map { "\($0.trimmingCharacters(in: .whitespacesAndNewlines)) et al." }
        let parts = [lead, journal, year].compactMap { $0 }
        return parts.isEmpty ? "Cited paper" : parts.joined(separator: ", ")
    }

    /// Compact line under the title in list rows.
    ///
    /// For a paper, "authors · journal · year", with the authors collapsed to the app's
    /// usual "Islam et al." rather than the stored list: a resolved paper often carries ten
    /// of them, and spelled out they wrap to more lines than the title they sit under and
    /// outweigh it. An attribution-only candidate already names all three of these in its
    /// title, so it takes no subtitle instead of saying it twice.
    ///
    /// For a source read off an article's links, the site it lives on and what kind of
    /// source it is — "youtube.com · Video" — which is what the learner weighs before
    /// adding it.
    var displaySubtitle: String? {
        if kind != .paper {
            let parts = [linkedSiteName, kind.label].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        guard !isAttributionOnly else { return nil }
        let parts = [StudioArticle.shortAuthorDisplay(authors), journal, year]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The host of `url` without a leading "www.", for the subtitle of a linked source.
    var linkedSiteName: String? {
        guard let url, let host = URLComponents(string: url)?.host?.lowercased() else { return nil }
        let trimmed = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether this candidate came from an attribution rather than a printed title, which
    /// decides how it can be looked up: there is no title here to match against.
    var isAttributionOnly: Bool {
        title == Self.attributionLabel(authors: authors, journal: journal, year: year)
    }

    /// Key used to collapse the same source appearing several times — on several slides,
    /// or linked twice from one article. A DOI is definitive; a URL is the next-most
    /// definitive identity there is, and the only one a linked page has; a normalized title
    /// is the fallback for a citation with neither.
    var dedupKey: String {
        if let doi, !doi.isEmpty {
            return "doi:\(doi.lowercased())"
        }
        if let url, !url.isEmpty {
            return "url:\(URLNormalizer.normalize(url))"
        }
        return "title:\(VideoCitedPaper.normalizeTitle(title))"
    }

    /// "H₂O₂" and "H2O2" are one title here, as they are to the catalog lookups.
    static func normalizeTitle(_ value: String) -> String {
        PaperWalkthroughCitation.foldedTitle(value)
    }
}
