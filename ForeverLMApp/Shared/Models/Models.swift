import Foundation

enum UITestConfiguration {
    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting")
    }
}

// MARK: - Reading List Studio

enum StudioArticleState: String, Codable {
    case queued      // in the queue, content not yet fetched
    case fetching    // content is being fetched
    case ready       // content fetched, available via MCP
    case error       // fetch failed
}

struct StudioArticle: Identifiable, Codable, Equatable {
    static let unknownPaperAuthor = "Unknown authors"
    static let unknownPaperJournal = "Unknown venue"
    static let unknownPaperYear = "Unknown year"

    /// Whether two source lists would render the same rows.
    ///
    /// Loaded text is not presentation. Hydrating a transcript for a chat send,
    /// or a reader open, must not rebuild every window's filtered sidebar and
    /// re-diff its rows: that rebuild stalled the main thread for seconds per
    /// send on a 4,000-source library. Everything else — state, title, word
    /// count, order, membership — counts as a visible change.
    static func presentationEquals(_ lhs: [StudioArticle], _ rhs: [StudioArticle]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) where !left.hasSamePresentation(as: right) {
            return false
        }
        return true
    }

    /// Equality that ignores the text payloads: canonical content and the raw
    /// ingestion inputs carried for persistence. Copying `self` shares those
    /// strings rather than duplicating them.
    func hasSamePresentation(as other: StudioArticle) -> Bool {
        var comparable = self
        comparable.content = other.content
        comparable.rawPaperContentForPersistence = other.rawPaperContentForPersistence
        comparable.rawArticleContentForPersistence = other.rawArticleContentForPersistence
        comparable.podcastTranscriptInputForPersistence = other.podcastTranscriptInputForPersistence
        return comparable == other
    }

    let id: String
    var url: String {
        didSet { if oldValue != url { edits.note(.url) } }
    }
    var title: String {
        didSet {
            let decoded = title.decodingTitleMarkup()
            if decoded != title {
                title = decoded
            }
            if oldValue != title { edits.note(.title) }
        }
    }
    var domain: String {
        didSet { if oldValue != domain { edits.note(.domain) } }
    }
    /// The team whose library this source belongs to, or nil for the learner's
    /// own library. A team copy is a separate row with a team-scoped id; the
    /// column is what routes it to the team's CloudKit zone and keeps it out of
    /// My Library. Travels in the payload for the web client; on the Mac the
    /// zone a record arrives from is the authority.
    var teamID: String? {
        didSet { if oldValue != teamID { edits.note(.teamID) } }
    }
    var dateAdded: Date {
        didSet { if oldValue != dateAdded { edits.note(.dateAdded) } }
    }
    var content: String?
    var wordCount: Int? {
        didSet { if oldValue != wordCount { edits.note(.wordCount) } }
    }
    var state: StudioArticleState {
        didSet { if oldValue != state { edits.note(.state) } }
    }
    var errorMessage: String? {
        didSet { if oldValue != errorMessage { edits.note(.errorMessage) } }
    }
    /// Typed view over `errorMessage` for the sentinel status flags (paywall,
    /// podcast confirmation, transcript needed). Non-nil only when `errorMessage`
    /// exactly matches a known flag; genuine free-text errors read as nil. Setting
    /// it writes the flag's raw string; setting nil clears `errorMessage`.
    var statusFlag: SourceStatusFlag? {
        get { errorMessage.flatMap(SourceStatusFlag.init(rawValue:)) }
        set { errorMessage = newValue?.rawValue }
    }
    var sourceType: StudioSourceType {
        didSet { if oldValue != sourceType { edits.note(.sourceType) } }
    }
    /// Artwork thumbnail URL (e.g. podcast cover art from Apple Podcasts)
    var artworkURL: String? {
        didSet { if oldValue != artworkURL { edits.note(.artworkURL) } }
    }
    /// Which browser or service this article was discovered from
    var discoveryOrigin: DiscoveryOrigin? {
        didSet { if oldValue != discoveryOrigin { edits.note(.discoveryOrigin) } }
    }
    /// Grouping key for hierarchical display (e.g. book name, course name)
    var parentGroup: String? {
        didSet { if oldValue != parentGroup { edits.note(.parentGroup) } }
    }
    /// Local file path for managed documents (articles, books, courses, papers)
    var localFilePath: String? {
        didSet { if oldValue != localFilePath { edits.note(.localFilePath) } }
    }
    /// For a chapter of a PDF book: the pages of the book's file (`localFilePath`)
    /// that are the chapter, from `book_sources.page_start` and `page_count`.
    /// A PDF book is kept as one file, and everything else about a chapter
    /// (highlights, reading position, figures) still counts pages from the
    /// chapter's first page; only code that opens the file adds the start
    /// (`SourcePDFPages`). Nil when the file is the chapter: an EPUB chapter,
    /// or a PDF book still split into chapter files.
    var bookPages: Range<Int>? {
        didSet { if oldValue != bookPages { edits.note(.bookPages) } }
    }
    /// Fallback web page URL for podcast episodes whose TTML isn't cached locally
    var podcastWebPageURL: String? {
        didSet { if oldValue != podcastWebPageURL { edits.note(.podcastWebPageURL) } }
    }
    /// Author name (user-editable, e.g. for books). Always a name or a list
    /// of names: markup, a web address or a "name" longer than any name is
    /// another field misread as one, and is turned away here as it arrives
    /// (`SourceAuthor`), so no reader's mistake reaches a row or the store.
    var author: String? {
        didSet {
            if let author, !SourceAuthor.isPlausible(author) {
                self.author = nil
            }
            if oldValue != author { edits.note(.author) }
        }
    }
    /// Journal name (e.g. "Nature", "Cell") — populated from Crossref for papers
    var journal: String? {
        didSet { if oldValue != journal { edits.note(.journal) } }
    }
    /// Publication year (e.g. "2024") — populated from Crossref for papers
    var publishedYear: String? {
        didSet { if oldValue != publishedYear { edits.note(.publishedYear) } }
    }
    /// Whether this source is active or archived
    var status: SourceStatus = .active {
        didSet { if oldValue != status { edits.note(.status) } }
    }
    /// When this source was archived (nil if still active)
    var archivedAt: Date? {
        didSet { if oldValue != archivedAt { edits.note(.archivedAt) } }
    }
    /// Canonical normalized URL for deduplication
    var normalizedURL: String? {
        didSet { if oldValue != normalizedURL { edits.note(.normalizedURL) } }
    }
    /// Public URL suitable for shared decks and exports.
    var publicURL: String? {
        didSet { if oldValue != publicURL { edits.note(.publicURL) } }
    }
    /// Podcast match found via iTunes Search API (when YouTube transcript is unavailable)
    var podcastMatch: PodcastMatchInfo?
    /// Temporary store track ID for a podcast match awaiting user confirmation (not persisted long-term)
    var podcastMatchTrackId: Int64?
    /// LLM-suggested sort index within a course group (nil = use default title sort)
    var courseSortIndex: Int? {
        didSet { if oldValue != courseSortIndex { edits.note(.courseSortIndex) } }
    }
    /// Groups a lecture video with its matched PDF notes within a course.
    /// Matched items share the same lectureGroupId (typically the lecture's article id).
    var lectureGroupId: String? {
        didSet { if oldValue != lectureGroupId { edits.note(.lectureGroupId) } }
    }
    /// Whether this source is behind a paywall (persisted in SQLite).
    var isPaywalled: Bool = false {
        didSet { if oldValue != isPaywalled { edits.note(.isPaywalled) } }
    }
    /// What the AI browser saw that makes it think this paper is paywalled,
    /// when the explicit purchase or subscription text that lets it mark the
    /// paper paywalled on its own was not on the page. While this is set the
    /// paper's attention row offers a one-click Mark as Paywalled with the
    /// reason behind it; marking, clearing the paywall status, or attaching a
    /// PDF retires it. Persisted in `papers.paywall_suspicion`.
    var paywallSuspicion: String? {
        didSet { if oldValue != paywallSuspicion { edits.note(.paywallSuspicion) } }
    }
    /// Whether this source is hidden from Studio source lists.
    var isHidden: Bool = false {
        didSet { if oldValue != isHidden { edits.note(.isHidden) } }
    }
    /// Digital Object Identifier for papers — canonical deduplication key
    var doi: String? {
        didSet { if oldValue != doi { edits.note(.doi) } }
    }
    /// For a preprint that has since appeared in a peer-reviewed venue: the DOI
    /// of that published version, resolved from bioRxiv/medRxiv, Crossref, or
    /// OpenAlex. It makes the preprint and the journal record one identity for
    /// deduplication even though neither `doi` nor the PDF text can match.
    /// Excluded from `CodingKeys` for the same reason as `paperContentSHA256`:
    /// it lives in `papers`, and CloudKit already carries it in the source's
    /// portable identity payload rather than in the article body.
    var publishedDOI: String? {
        didSet { if oldValue != publishedDOI { edits.note(.publishedDOI) } }
    }
    /// Proof that this paper completed the mandatory metadata extraction gate.
    /// The setter is intentionally private: ingestion code must use
    /// `completePaperMetadataExtractionAfterLLM()` after a real model response.
    private(set) var paperIngestionMethod: PaperIngestionMethod? {
        didSet { if oldValue != paperIngestionMethod { edits.note(.paperIngestionMethod) } }
    }
    /// SHA-256 of the raw text extracted from this paper's PDF, populated only
    /// after the current cleanup contract has produced canonical text. This is
    /// derived from `paper_content_preparations`, whose metadata already syncs
    /// with the source, rather than a second persisted identity field. It stays
    /// out of `CodingKeys`: CloudKit carries the preparation metadata in its
    /// existing dedicated payload.
    var paperContentSHA256: String?
    /// Storage-derived proof that the current canonical text has a durable
    /// Listen derivative. Excluded from Codable because CloudKit carries that
    /// derivative and its metadata as a separate source asset.
    var paperListenableContentReady = false
    /// Zero-based page index to reopen when returning to a PDF-backed reader.
    var readingPositionPage: Int? {
        didSet { if oldValue != readingPositionPage { edits.note(.readingPositionPage) } }
    }
    /// Structured reader locator, such as an EPUB chapter plus scroll fraction.
    var readingPositionLocator: String? {
        didSet { if oldValue != readingPositionLocator { edits.note(.readingPositionLocator) } }
    }
    /// When the learner marked this web article as read (nil = unread).
    var readAt: Date? {
        didSet { if oldValue != readAt { edits.note(.readAt) } }
    }
    /// When this video was added to the YouTube Liked feed. Only populated for
    /// videos seen by the Liked-feed sync — nil for Safari-discovered rows and
    /// for liked rows that predate the first sync carrying this field.
    var likedAt: Date? {
        didSet { if oldValue != likedAt { edits.note(.likedAt) } }
    }
    /// When the video itself was published to YouTube, as distinct from when it
    /// was liked or added to ForeverLM. Same nil caveats as `likedAt`.
    var videoPublishedAt: Date? {
        didSet { if oldValue != videoPublishedAt { edits.note(.videoPublishedAt) } }
    }
    /// Which user-built plugin added this source (`discoveryOrigin ==
    /// .plugin`). Derived from the OAuth client's registered name at ingest
    /// time; ingest-scoped clients may only update sources carrying their own
    /// label, and bulk removal is keyed on it.
    var connectorLabel: String? {
        didSet { if oldValue != connectorLabel { edits.note(.connectorLabel) } }
    }
    /// The fields this copy's holder changed since it was read from the store
    /// (`KnowledgeStore.readSourceRow`), so that a save writes only those (`written(over:)`). Not
    /// tracking for a copy never read from the store. Not encoded, and ignored by equality.
    var edits = SourceEdits()

    /// In-memory handoff from ingestion/CloudKit to KnowledgeStore. The raw
    /// extraction is deliberately excluded from Codable: CloudKit carries it in
    /// a separate asset so normal source payloads and downstream consumers only
    /// ever see the cleaned `content` value.
    var rawPaperContentForPersistence: String?
    var paperContentPreparationForPersistence: PaperContentPreparationMetadata?
    var rawArticleContentForPersistence: String?
    var articleContentPreparationForPersistence: PaperContentPreparationMetadata?
    var podcastTranscriptInputForPersistence: String?
    var podcastTranscriptCleanupForPersistence: PodcastTranscriptCleanupMetadata?

    var isRead: Bool { readAt != nil }

    /// Whether the reader has a saved page or scroll locator to restore. A
    /// video marked not watched keeps a locator for its epoch
    /// (`VideoWatchProgress.isUnwatchedMarker`), and that is not one.
    var hasSavedReadingPosition: Bool {
        guard readingPositionPage == nil else { return true }
        guard let locator = readingPositionLocator, !locator.isEmpty else { return false }
        return !VideoWatchProgress.isUnwatchedMarker(locator)
    }

    /// Whether the Sources sidebar and the Reader offer Mark as Watched and
    /// Mark as Not Watched: a video, or a course lecture that is a YouTube
    /// video (some playlist lectures are stored as `course` sources and still
    /// record watch progress through the YouTube reader).
    var offersWatchedMarks: Bool {
        sourceType == .video || (sourceType == .course && isYouTubeURL)
    }

    /// Web articles from Reading List or pasted URLs — and every paper, whose text
    /// is usually a local PDF — can be marked read in ForeverLM.
    var supportsReadTracking: Bool {
        supportsReadTracking(web: isWebArticle)
    }

    /// `supportsReadTracking` without the stat — see `cachedResolvedLocalPath`. Both
    /// the sidebar row's read badge and every reader's "Mark as Read" menu item gate
    /// on this while rendering, and `isWebArticle` resolves a local path to get there.
    var cachedSupportsReadTracking: Bool {
        supportsReadTracking(web: cachedIsWebArticle)
    }

    private func supportsReadTracking(web: Bool) -> Bool {
        ForeverLMCore.supportsReadTracking(
            sourceType: sourceType.rawValue,
            isWebArticle: web
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, url, title, domain, dateAdded, content, wordCount, state
        case errorMessage, sourceType
        case artworkURL, discoveryOrigin, parentGroup, localFilePath, podcastWebPageURL
        case author, journal, publishedYear, podcastMatch, podcastMatchTrackId
        case courseSortIndex, lectureGroupId
        case status, archivedAt, normalizedURL, publicURL
        case isPaywalled, isHidden, doi, readingPositionPage, readingPositionLocator, readAt
        case likedAt, videoPublishedAt, connectorLabel
        case paperIngestionMethod
        case paywallSuspicion
        case teamID
        case bookPages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title).decodingTitleMarkup()
        domain = try c.decode(String.self, forKey: .domain)
        dateAdded = try c.decode(Date.self, forKey: .dateAdded)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        wordCount = try c.decodeIfPresent(Int.self, forKey: .wordCount)
        state = try c.decode(StudioArticleState.self, forKey: .state)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        sourceType = try c.decode(StudioSourceType.self, forKey: .sourceType)
        artworkURL = try c.decodeIfPresent(String.self, forKey: .artworkURL)
        discoveryOrigin = try c.decodeIfPresent(DiscoveryOrigin.self, forKey: .discoveryOrigin)
        parentGroup = try c.decodeIfPresent(String.self, forKey: .parentGroup)
        localFilePath = try c.decodeIfPresent(String.self, forKey: .localFilePath)
        podcastWebPageURL = try c.decodeIfPresent(String.self, forKey: .podcastWebPageURL)
        author = SourceAuthor.storable(try c.decodeIfPresent(String.self, forKey: .author))
        journal = try c.decodeIfPresent(String.self, forKey: .journal)
        publishedYear = try c.decodeIfPresent(String.self, forKey: .publishedYear)
        podcastMatch = try c.decodeIfPresent(PodcastMatchInfo.self, forKey: .podcastMatch)
        podcastMatchTrackId = try c.decodeIfPresent(Int64.self, forKey: .podcastMatchTrackId)
        courseSortIndex = try c.decodeIfPresent(Int.self, forKey: .courseSortIndex)
        lectureGroupId = try c.decodeIfPresent(String.self, forKey: .lectureGroupId)
        status = (try? c.decode(SourceStatus.self, forKey: .status)) ?? .active
        archivedAt = try? c.decode(Date.self, forKey: .archivedAt)
        normalizedURL = try? c.decode(String.self, forKey: .normalizedURL)
        publicURL = try? c.decode(String.self, forKey: .publicURL)
        isPaywalled = (try? c.decode(Bool.self, forKey: .isPaywalled)) ?? false
        isHidden = (try? c.decode(Bool.self, forKey: .isHidden)) ?? false
        doi = try c.decodeIfPresent(String.self, forKey: .doi)
        // Unknown future attestations fail closed to nil so this build can
        // demote/reprocess the paper instead of rejecting the whole sync payload.
        paperIngestionMethod = try? c.decodeIfPresent(PaperIngestionMethod.self, forKey: .paperIngestionMethod)
        paywallSuspicion = try? c.decodeIfPresent(String.self, forKey: .paywallSuspicion)
        teamID = try c.decodeIfPresent(String.self, forKey: .teamID)
        readingPositionPage = try c.decodeIfPresent(Int.self, forKey: .readingPositionPage)
        readingPositionLocator = try c.decodeIfPresent(String.self, forKey: .readingPositionLocator)
        readAt = try c.decodeIfPresent(Date.self, forKey: .readAt)
        likedAt = try c.decodeIfPresent(Date.self, forKey: .likedAt)
        videoPublishedAt = try c.decodeIfPresent(Date.self, forKey: .videoPublishedAt)
        connectorLabel = try c.decodeIfPresent(String.self, forKey: .connectorLabel)
        bookPages = try c.decodeIfPresent(Range<Int>.self, forKey: .bookPages)
    }

    private static func normalizedMetadataField(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    var normalizedAuthor: String? { Self.normalizedMetadataField(author) }

    static func canonicalPaperAuthor(_ value: String?) -> String? {
        normalizedMetadataField(value)
    }

    /// Short author display: "First Author et al." for 3+, "A & B" for 2, full name for 1.
    var shortAuthorDisplay: String? { Self.shortAuthorDisplay(author) }

    /// The same rule over a loose author string, for papers that have no `StudioArticle` yet —
    /// a cited-paper candidate read off a slide should read the way it will once imported.
    static func shortAuthorDisplay(_ value: String?) -> String? {
        guard let raw = canonicalPaperAuthor(value), raw != unknownPaperAuthor else { return nil }
        // Paper metadata stores its author list with a semicolon delimiter. Treat that
        // delimiter as structure; do not attempt to parse names themselves.
        var seen = Set<String>()
        let authors = raw
            .split(separator: ";", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)).inserted }
        switch authors.count {
        case 0:
            return nil
        case 1:
            return authors[0]
        case 2:
            return "\(authors[0]) & \(authors[1])"
        default:
            return "\(authors[0]) et al."
        }
    }

    var displayAuthor: String? {
        guard sourceType == .paper else { return normalizedAuthor }
        return shortAuthorDisplay
    }

    /// `domain` as a row may print it: nil when empty or a file path. A source
    /// made with an address that has no host gets that address as its domain
    /// (`init(url:…)`: `URL(string: url)?.host ?? url`); for a book chapter it
    /// is the file's place in the library ("Books/<book id>/Chapters/…"), a
    /// relative path the absolute-path check below does not catch.
    var displayDomain: String? {
        if domain == url, URL(string: url)?.host == nil { return nil }
        return Self.displayDomain(domain)
    }

    /// Book chapters imported before the private container was retired keep
    /// their chapter folder's absolute path in `domain`, and
    /// `rewriteBookFolderReferences` moves it with the folder, so the column
    /// stays. A path is where the file lives, never a byline.
    static func displayDomain(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~/"),
              !trimmed.hasPrefix("file:") else { return nil }
        return trimmed
    }

    var normalizedJournal: String? { Self.normalizedMetadataField(journal) }
    var normalizedPublishedYear: String? { Self.normalizedMetadataField(publishedYear) }

    mutating func prepareForPaperMetadataExtraction() {
        guard sourceType == .paper else { return }
        paperIngestionMethod = nil
        state = .queued
        errorMessage = nil
    }

    /// Leave the paper pipeline for good because the page turned out not to be
    /// a paper: a news story, editorial, or comment piece with no PDF to find.
    /// Clears the paper-only bookkeeping (paywall marker, bibliographic fields,
    /// ingestion attestation) and re-queues the source so the article pipeline
    /// fetches and prepares it like any other web page. Before this existed,
    /// such a page stayed in "Papers that need attention" until a browser-agent
    /// run happened to call it paywalled, which hid it without fixing anything.
    mutating func convertPaperToArticle() {
        guard sourceType == .paper else { return }
        sourceType = .article
        isPaywalled = false
        paywallSuspicion = nil
        paperIngestionMethod = nil
        journal = nil
        publishedYear = nil
        doi = nil
        publishedDOI = nil
        content = nil
        wordCount = nil
        state = .queued
        errorMessage = nil
    }

    /// Persist the successful model-owned metadata boundary before the separate
    /// content-cleanup stage starts. Cleanup can fail or be interrupted without
    /// invalidating metadata the model already returned.
    @discardableResult
    mutating func attestPaperMetadataExtractionAfterLLM() -> Bool {
        guard sourceType == .paper, hasAttestablePaperMetadata else { return false }
        paperIngestionMethod = .llm
        state = .queued
        errorMessage = nil
        return true
    }

    /// Call after a manual metadata edit filled in what the model could not.
    /// The learner is the authority here, so this attests the metadata stage
    /// and clears the extraction failure; the caller still owns Source Content
    /// Cleanup, which is why this never fabricates a cleanup result. A learner
    /// who leaves a field blank because the paper has no such field is answering
    /// the question, so this asks for no more than the extractor does.
    @discardableResult
    mutating func completePaperMetadataFromManualEntry() -> Bool {
        guard sourceType == .paper, hasAttestablePaperMetadata else { return false }
        // An extraction the pipeline already attested owns its own record, and a
        // failure in a later stage is not this stage's to clear.
        guard paperIngestionMethod == nil || paperIngestionMethod == .manual,
              !isPaperContentCleanupFailure else { return true }
        paperIngestionMethod = .manual
        // The metadata failure is resolved either way, so it must not linger on
        // the row. Cleanup that has not run yet is queued work, not an error.
        errorMessage = nil
        state = hasCompletedPaperContentCleanup ? .ready : .queued
        return true
    }

    mutating func failPaperIngestionMetadata(_ message: String) {
        guard sourceType == .paper else { return }
        paperIngestionMethod = nil
        state = .error
        errorMessage = message
    }

    @discardableResult
    mutating func attestPaperIngestionAfterBlankMetadataFailure() -> Bool {
        guard canAttestPaperIngestionAfterBlankMetadataFailure else { return false }
        paperIngestionMethod = .llm
        state = .ready
        errorMessage = nil
        return true
    }

    /// Whole-record CloudKit writes from an older Mac can carry a newer reading
    /// position while omitting paper fields that Mac never understood. Required
    /// paper metadata and its attestation are monotonic: an absent/placeholder
    /// inbound value cannot erase a complete local extraction.
    @discardableResult
    /// A team's copy of a paper inherits the attestation the original earned:
    /// the metadata gate was passed once, for this document, and a copy under
    /// another id is the same document. Nothing else may copy an attestation
    /// across ids, which is why the setter stays private.
    mutating func adoptPaperIngestionAttestation(from original: StudioArticle) {
        guard sourceType == .paper, original.sourceType == .paper else { return }
        paperIngestionMethod = original.paperIngestionMethod
    }

    init(url: String, title: String? = nil, sourceType: StudioSourceType = .manual, artworkURL: String? = nil, discoveryOrigin: DiscoveryOrigin? = nil, parentGroup: String? = nil, localFilePath: String? = nil, publicURL: String? = nil, author: String? = nil, journal: String? = nil, publishedYear: String? = nil, id: String? = nil) {
        self.id = id ?? SourceIdentity.stableID(for: url)
        self.url = url
        self.normalizedURL = URLNormalizer.normalize(url)
        self.title = (title ?? url).decodingTitleMarkup()
        self.domain = URL(string: url)?.host ?? url
        self.dateAdded = Date()
        self.state = .queued
        self.sourceType = sourceType
        self.artworkURL = artworkURL
        self.discoveryOrigin = discoveryOrigin
        self.parentGroup = parentGroup
        self.localFilePath = localFilePath
        self.publicURL = publicURL
        self.author = SourceAuthor.storable(author)
        self.journal = journal
        self.publishedYear = publishedYear
    }
}

/// The fields a copy of a source has changed since it was read from the store, noted by each field's
/// own observer when its value changes. Equal to every other, so two copies of one source still compare
/// by what they hold and the sidebar's change checks are unmoved.
struct SourceEdits: Equatable, Sendable {
    /// What `persistSourceRows` writes from a `StudioArticle`, one bit each.
    enum Field: Int, CaseIterable {
        case url, title, domain, teamID, dateAdded, wordCount
        case state, errorMessage, sourceType, artworkURL, discoveryOrigin, parentGroup
        case localFilePath, podcastWebPageURL, author, journal, publishedYear, status
        case archivedAt, normalizedURL, publicURL, courseSortIndex, lectureGroupId, isPaywalled
        case paywallSuspicion, isHidden, doi, publishedDOI, paperIngestionMethod, readingPositionPage
        case readingPositionLocator, readAt, likedAt, videoPublishedAt, connectorLabel, bookPages
    }

    /// False for a copy never read from the store, which a save writes whole.
    private(set) var isTracking = false
    private var bits: UInt64 = 0

    init() {}

    private init(isTracking: Bool) { self.isTracking = isTracking }

    /// A copy just read: tracking, and nothing changed yet.
    static var read: SourceEdits { SourceEdits(isTracking: true) }

    mutating func note(_ field: Field) {
        guard isTracking else { return }
        bits |= 1 << UInt64(field.rawValue)
    }

    /// Every field, for a copy put back whole by assignment (an earlier copy restored after a step that
    /// saved), which no field's observer sees: its save writes it whole, as every save did before.
    mutating func noteAll() {
        guard isTracking else { return }
        bits = (1 << UInt64(Field.allCases.count)) - 1
    }

    func contains(_ field: Field) -> Bool { bits & (1 << UInt64(field.rawValue)) != 0 }

    static func == (_: SourceEdits, _: SourceEdits) -> Bool { true }
}

extension StudioArticle {
    /// This copy as a save writes it over `stored`, the row as the store holds it now: a field this copy
    /// changed since it was read keeps this copy's value, and every other field takes the stored one.
    /// `PaperMetadataBackfillPatch` is the same rule for its fields. Every column whose
    /// value a save changes is sent with a new stamp and wins on every device, so a copy held across
    /// another device's change (a long ingestion's snapshot, the view model's copy before its reload)
    /// would otherwise send the old value back. A field changed and changed back still counts as
    /// changed, so a retry that puts a state back is written. `keptStored` says the copy lacked a stored
    /// value it had not changed, so whoever shows it is behind. Nil for a copy never read from the store,
    /// or one of another source: that is written whole, as before.
    ///
    /// The fields are the ones `persistSourceRows` writes; one left out is written from the copy, as
    /// before, never dropped. Not merged: `content` and the `…ForPersistence` handoffs, which a save
    /// writes only when the copy carries them, and the derived `paperContentSHA256` and
    /// `paperListenableContentReady`, which no save writes.
    func written(over stored: StudioArticle) -> (article: StudioArticle, keptStored: Bool)? {
        guard edits.isTracking, stored.id == id else { return nil }
        var merged = self
        var keptStored = false
        func keep<Value: Equatable>(_ field: SourceEdits.Field, _ keyPath: WritableKeyPath<StudioArticle, Value>) {
            guard !edits.contains(field) else { return }
            let current = stored[keyPath: keyPath]
            guard current != self[keyPath: keyPath] else { return }
            merged[keyPath: keyPath] = current
            keptStored = true
        }
        keep(.url, \.url)
        keep(.title, \.title)
        keep(.domain, \.domain)
        keep(.teamID, \.teamID)
        keep(.dateAdded, \.dateAdded)
        keep(.wordCount, \.wordCount)
        keep(.state, \.state)
        keep(.errorMessage, \.errorMessage)
        keep(.sourceType, \.sourceType)
        keep(.artworkURL, \.artworkURL)
        keep(.discoveryOrigin, \.discoveryOrigin)
        keep(.parentGroup, \.parentGroup)
        keep(.localFilePath, \.localFilePath)
        keep(.podcastWebPageURL, \.podcastWebPageURL)
        keep(.author, \.author)
        keep(.journal, \.journal)
        keep(.publishedYear, \.publishedYear)
        keep(.status, \.status)
        keep(.archivedAt, \.archivedAt)
        keep(.normalizedURL, \.normalizedURL)
        keep(.publicURL, \.publicURL)
        keep(.courseSortIndex, \.courseSortIndex)
        keep(.lectureGroupId, \.lectureGroupId)
        keep(.isPaywalled, \.isPaywalled)
        keep(.paywallSuspicion, \.paywallSuspicion)
        keep(.isHidden, \.isHidden)
        keep(.doi, \.doi)
        keep(.publishedDOI, \.publishedDOI)
        keep(.paperIngestionMethod, \.paperIngestionMethod)
        keep(.readingPositionPage, \.readingPositionPage)
        keep(.readingPositionLocator, \.readingPositionLocator)
        keep(.readAt, \.readAt)
        keep(.likedAt, \.likedAt)
        keep(.videoPublishedAt, \.videoPublishedAt)
        keep(.connectorLabel, \.connectorLabel)
        keep(.bookPages, \.bookPages)
        return (merged, keptStored)
    }
}
