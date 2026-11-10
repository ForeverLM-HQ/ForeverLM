import Foundation
#if os(macOS)
@testable import ForeverLM
#endif

// Platform-neutral source-catalog value types shared by the iOS app and the
// macOS-hosted unit tests (MobileVoiceSourceResolverTests).

struct MobileCloudSource: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let sourceType: String
    let dateAdded: Date
    /// Layered on after the catalog parse, from the synced audio manifests.
    var hasAudio: Bool
    let isArchived: Bool
    /// Canonical ingestion state from the Mac (`queued`, `ready`, `error`).
    /// Manifest/Siri fallbacks represent already-playable material and default
    /// to ready because they do not carry the Source payload.
    var state: String = "ready"
    // Paper metadata from the synced StudioArticle payload. Defaulted so the
    // Siri/manifest fallback constructors — which have no payload to read —
    // stay valid; only the CloudKit catalog parse fills these in.
    var author: String? = nil
    var journal: String? = nil
    var publishedYear: String? = nil
    /// The Mac's stored word count, already carried in the Source payload. The
    /// phone reads it to size a book's remaining chapters before their
    /// narration exists, so a chapter's price confirmation can state what the
    /// whole book will cost.
    var wordCount: Int? = nil
    /// The Mac's hierarchical grouping key (`StudioArticle.parentGroup`): the
    /// owning book/course/meeting-group id for chapters, lectures and meeting
    /// artifacts; nil for standalone sources.
    var parentGroup: String? = nil
    /// Explicit order within `parentGroup` (books/courses). nil sorts after,
    /// by title.
    var courseSortIndex: Int? = nil
    /// The Mac's per-source hidden flag (its `hidden_sources` join).
    var isHidden: Bool = false
    /// The Mac's paywall marker: its `is_paywalled` column, or the
    /// `paywall` sentinel it also stores in `error_message`. Both fold into
    /// this one flag at parse time. A marked source has neither synced text nor
    /// an attached document, so the phone can only explain why.
    var isPaywalled: Bool = false
    /// Episode stays visible even when its whole podcast show is hidden.
    var visiblePodcastEpisodeOverride: Bool = false
    /// Video stays visible even when its whole YouTube channel is hidden.
    var visibleYouTubeVideoOverride: Bool = false
    /// Remote artwork the Mac stored for this source (podcast feed art, etc.).
    var artworkURL: String? = nil
    /// The source's original URL — carried so video rows can derive their
    /// YouTube thumbnail exactly as the Mac does.
    var url: String? = nil
    /// Path below the shared ForeverLM iCloud Documents root. Paper readers use
    /// this to open the original file directly; `url` remains the fallback for
    /// older paper payloads whose local path was not populated.
    var localFilePath: String? = nil
    /// Pre-generated on the Mac from the cleaned canonical source text and
    /// synced as part of the encrypted CloudKit Source payload. Today's
    /// memory review reads it (`MobileMemoryReviewPreparer`).
    var sourceReviewGuide: MobileCloudSourceReviewGuide? = nil
    /// Exact size of the synced listen-ready derivative. Older payloads omit
    /// it; those sources stay unpriced until a current payload arrives.
    var listenableCharacterCount: Int? = nil
    /// Vision explanations and page geometry prepared from the original PDF on
    /// the Mac. The phone renders the corresponding shared iCloud PDF page.
    var paperFigures: [SyncedPaperFigure] = []
    /// The source's walkthrough, read on the phone as a deck of cards
    /// (`MobileWalkthroughDeckView`); nil when the Mac has written none.
    var walkthroughDeck: MobileWalkthroughDeck? = nil
    /// Explicit cross-device consumption signal. Reader positions remain resume
    /// state and do not qualify a source for first-review intake.
    var readAt: Date? = nil
    /// The Mac's resume locator (`sources.reading_position_locator`). For a
    /// video it is its `VideoWatchProgress`, which is how the phone knows a
    /// course lecture has been watched.
    var readingPositionLocator: String? = nil
    /// Portable identity fields used to reconcile a MemoryItem that arrives
    /// before, or names a deduplicated variant of, its Source record.
    var normalizedURL: String? = nil
    var doi: String? = nil
    var publishedDOI: String? = nil
    /// A PDF book's chapter kept as a run of its book's pages (`Source.meta.pageStart`, 0-based, and
    /// `meta.pageCount`): its `files.pdf` is the whole book's file, the same FileRef on every chapter.
    /// Both nil when the chapter's PDF, if it has one, is the chapter.
    var pageStart: Int? = nil
    var pageCount: Int? = nil

    /// Watched to the end, by the Mac's measure (`isEssentiallyWatched`).
    var isWatched: Bool {
        VideoWatchProgress(encoded: readingPositionLocator)?.isEssentiallyWatched == true
    }

    /// The row-thumbnail image URL, in the Mac's `SourceThumbnail` order:
    /// explicit artwork first, else the YouTube thumbnail derived from the
    /// URL. nil renders the tinted type icon, as before.
    var thumbnailURL: URL? {
        if let artworkURL, let parsed = URL(string: artworkURL) { return parsed }
        if let url { return MobileSourceArtwork.youtubeThumbnailURL(for: url) }
        return nil
    }

    /// A book chapter whose synced document is a PDF. A book imported from a
    /// PDF is one file whose chapters are runs of its pages (`pageStart`,
    /// `pageCount`); one imported before that is split into one PDF per
    /// chapter, found by its `.pdf` path. That file is the only place the
    /// chapter's figures, plates and layout exist — synced text has none of
    /// them — so those chapters read as their document, exactly like a paper.
    /// EPUB chapters have no PDF and read their illustrated reader document
    /// instead. A page-range chapter's url ends in `#page=N`, never `.pdf`, so
    /// its run says it, not its url.
    var isPDFBackedBookChapter: Bool {
        isPageRangeBookChapter
            || (sourceType == "book"
                && MobileSourceFilePath.relativePDFPath(localFilePath: localFilePath, url: url) != nil)
    }

    /// A book chapter kept as a run of its book's pages. Either key says so: a
    /// run that names only one of them is refused where the document opens
    /// (`MobileBookChapterPages.invalid`), never read as the whole book.
    var isPageRangeBookChapter: Bool {
        sourceType == "book" && (pageStart != nil || pageCount != nil)
    }

    /// Archived web article HTML is a rich reader document just like an EPUB
    /// chapter. The path may be portable or an older Mac-specific absolute path.
    var isArchivedArticle: Bool {
        guard let localFilePath else { return false }
        let normalized = localFilePath.replacingOccurrences(of: "\\", with: "/").lowercased()
        return normalized.hasSuffix(".html")
            && (normalized.hasPrefix("articles/") || normalized.contains("/articles/"))
    }

    /// "Picard M · Nature Metabolism · 2024" when metadata is known; the
    /// domain-based subtitle otherwise. Rows and voice-agent listings use this
    /// so a paper reads like a citation instead of a hostname.
    var citationSubtitle: String? {
        let parts = [author, journal, publishedYear].compactMap { value -> String? in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        if parts.isEmpty { return subtitle }
        return parts.joined(separator: " · ")
    }

    /// The subtitle a synced `domain` gives a row: nil when empty or a file
    /// path. Book chapters imported before the private container was retired
    /// keep their folder's absolute path there; the Mac's
    /// `StudioArticle.displayDomain` holds back the same values.
    static func subtitle(fromDomain domain: String?) -> String? {
        guard let trimmed = domain?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~/"),
              !trimmed.hasPrefix("file:") else { return nil }
        return trimmed
    }
}

/// A source is complete only at the actual end of the reflowed document. Keep
/// this separate from persisted resume position: partial progress is useful for
/// reopening, but it is never evidence that the learner consumed the source.
enum MobileReadingCompletion {
    static let endFraction = 0.995

    static func reachedEnd(_ fraction: Double) -> Bool {
        fraction.isFinite && fraction >= endFraction
    }
}

/// AVPlayer normally posts `AVPlayerItemDidPlayToEndTime`, but that notification
/// can race an interruption or scene transition at the final instant. The
/// periodic playback clock is an independent completion witness. Its tolerance
/// is deliberately tiny: this recognizes the natural final clock tick, not a
/// partially listened source.
enum MobileAudioPlaybackCompletion {
    static let endTolerance: TimeInterval = 0.1

    static func reachedEnd(elapsed: TimeInterval, duration: TimeInterval) -> Bool {
        elapsed.isFinite
            && duration.isFinite
            && duration > 0
            && elapsed >= max(0, duration - endTolerance)
    }
}

/// Portable identity attached to a synced MemoryItem source anchor. Source IDs
/// remain authoritative; these fields only reconcile an anchor when the exact
/// ID is absent on this device after deterministic source deduplication.
struct MobileMemorySourceIdentity: Decodable, Equatable, Sendable {
    let sourceID: String
    let url: String?
    let normalizedURL: String?
    let doi: String?
    let publishedDOI: String?
}

/// Pure delivery-order-independent relationship projection. Kept beside the
/// mobile Source value type so macOS contract tests can exercise the same code
/// the iPhone catalog uses without compiling its CloudKit/UI actor.
enum MobileMemorySourceIdentityResolver {
    struct Index {
        private let exactSourceIDs: Set<String>
        private let sourceIDsByNormalizedURL: [String: [String]]
        private let sourceIDsByDOI: [String: [String]]
        private let sourceIDsByPublishedDOI: [String: [String]]
        private let normalizeURL: (String) -> String

        init(sources: [MobileCloudSource], normalizeURL: @escaping (String) -> String) {
            let orderedSources = sources.sorted { $0.id < $1.id }
            exactSourceIDs = Set(orderedSources.map(\.id))
            self.normalizeURL = normalizeURL
            var byURL: [String: [String]] = [:]
            var byDOI: [String: [String]] = [:]
            var byPublishedDOI: [String: [String]] = [:]
            for source in orderedSources {
                if let url = Self.clean(source.normalizedURL).map(normalizeURL)
                    ?? Self.clean(source.url).map(normalizeURL) {
                    byURL[url, default: []].append(source.id)
                }
                if let doi = Self.normalizedDOI(source.doi) {
                    byDOI[doi, default: []].append(source.id)
                }
                if let publishedDOI = Self.normalizedDOI(source.publishedDOI) {
                    byPublishedDOI[publishedDOI, default: []].append(source.id)
                }
            }
            sourceIDsByNormalizedURL = byURL
            sourceIDsByDOI = byDOI
            sourceIDsByPublishedDOI = byPublishedDOI
        }

        func resolvedSourceID(
            _ sourceID: String,
            identity: MobileMemorySourceIdentity?
        ) -> String {
            guard !exactSourceIDs.contains(sourceID), let identity else { return sourceID }
            for doi in [Self.normalizedDOI(identity.doi), Self.normalizedDOI(identity.publishedDOI)]
                .compactMap({ $0 }) {
                if let match = sourceIDsByDOI[doi]?.first { return match }
                if let match = sourceIDsByPublishedDOI[doi]?.first { return match }
            }
            if let url = Self.clean(identity.normalizedURL).map(normalizeURL)
                ?? Self.clean(identity.url).map(normalizeURL),
               let match = sourceIDsByNormalizedURL[url]?.first {
                return match
            }
            return sourceID
        }

        func remap(
            item: MemoryItem,
            identities: [MobileMemorySourceIdentity]
        ) -> MemoryItem {
            let identitiesBySourceID = Dictionary(
                identities.map { ($0.sourceID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let remapped = item.sources.map { anchor -> MemoryItemSource in
                let resolvedSourceID = resolvedSourceID(
                    anchor.sourceID,
                    identity: identitiesBySourceID[anchor.sourceID]
                )
                guard resolvedSourceID != anchor.sourceID else { return anchor }
                return MemoryItemSource(
                    id: anchor.id,
                    memoryItemID: anchor.memoryItemID,
                    sourceID: resolvedSourceID,
                    locatorJSON: anchor.locatorJSON,
                    excerpt: anchor.excerpt,
                    sourceSHA256: anchor.sourceSHA256,
                    sortIndex: anchor.sortIndex
                )
            }
            return item.replacingSources(remapped)
        }

        private static func clean(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }

        private static func normalizedDOI(_ value: String?) -> String? {
            clean(value)?.lowercased()
        }
    }

    static func remap(
        item: MemoryItem,
        identities: [MobileMemorySourceIdentity],
        sources: [MobileCloudSource],
        normalizeURL: @escaping (String) -> String
    ) -> MemoryItem {
        Index(sources: sources, normalizeURL: normalizeURL)
            .remap(item: item, identities: identities)
    }
}

/// Pure, lexical path normalization shared by the iOS reader and macOS-hosted
/// contract tests. Source paths are sync identity, so this deliberately never
/// touches the filesystem or guesses from a title.
enum MobileSourceFilePath {
    static func relativePDFPath(localFilePath: String?, url: String?) -> String? {
        for candidate in [localFilePath, url].compactMap({ $0 }) {
            if let relative = relativePDFPath(candidate) { return relative }
        }
        return nil
    }

    private static func relativePDFPath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("://") else { return nil }

        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty else { return nil }

        let relativeComponents: ArraySlice<String>
        if trimmed.hasPrefix("/") {
            guard let documentsIndex = components.lastIndex(of: "Documents"),
                  components.indices.contains(documentsIndex + 1),
                  isContentRoot(components[documentsIndex + 1]),
                  components.indices.contains(documentsIndex + 2) else {
                return nil
            }
            relativeComponents = components[(documentsIndex + 2)...]
        } else if isContentRoot(components[0]), components.count > 1 {
            relativeComponents = components[1...]
        } else {
            relativeComponents = components[...]
        }

        var standardized: [String] = []
        for component in relativeComponents {
            switch component {
            case ".":
                continue
            case "..":
                guard !standardized.isEmpty else { return nil }
                standardized.removeLast()
            default:
                standardized.append(component)
            }
        }
        guard !standardized.isEmpty else { return nil }
        let relative = standardized.joined(separator: "/")
        // A page-range chapter's url (`Books/X/X.pdf#page=17`) names a run of its
        // book, not a file of its own, and stops here: its extension is not `pdf`.
        guard (relative as NSString).pathExtension.lowercased() == "pdf" else { return nil }
        return relative
    }

    private static func isContentRoot(_ component: String) -> Bool {
        component.range(of: #"^ForeverLM(?: [0-9]+)?$"#, options: .regularExpression) != nil
    }

    /// The name a shared PDF carries into Files, ChatGPT or AirDrop. The
    /// cached copy is named by a hash of the source id, which says nothing to
    /// whoever receives it, so the share is named after the source's title.
    static func sharedPDFFileName(title: String) -> String {
        sharedFileName(title: title, extension: "pdf")
    }

    /// The same naming for any file a share hands on: the title, cleaned for a filesystem, under `extension`.
    static func sharedFileName(title: String, extension fileExtension: String) -> String {
        var name = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " - ")
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let suffix = "." + fileExtension
        if name.lowercased().hasSuffix(suffix) { name.removeLast(suffix.count) }
        // A leading dot would hide the file; 120 characters keeps the name
        // well inside every filesystem's limit once the extension is on it.
        name = String(name.prefix(120))
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".-")))
        return (name.isEmpty ? "Document" : name) + suffix
    }

    /// The link that opens the Files app on a file the phone keeps in its
    /// Documents folder: the file's own URL under Files' `shareddocuments`
    /// scheme. nil for anything that is not a local file.
    static func filesAppURL(for fileURL: URL) -> URL? {
        guard fileURL.isFileURL,
              var components = URLComponents(url: fileURL.standardizedFileURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = "shareddocuments"
        return components.url
    }
}

/// Where a page-range book chapter lies in its book's PDF (`Source.meta.pageStart`,
/// 0-based, and `meta.pageCount`). Everything stored about a chapter counts its
/// pages from the chapter's first page, so the phone shows exactly these pages,
/// numbered from 0; only the code that opens the book's file adds `pageStart`.
enum MobileBookChapterPages: Equatable, Sendable {
    /// The record names no run: the source's PDF is the source.
    case wholeFile
    /// The source is these pages of its book's file.
    case run(Range<Int>)
    /// The record names a run that cannot be one (a key missing, negative, empty
    /// or not a whole number). Such a chapter is never shown, rather than shown
    /// on pages that are not its own.
    case invalid

    init(pageStart: Int?, pageCount: Int?) {
        switch (pageStart, pageCount) {
        case (nil, nil):
            self = .wholeFile
        case let (start?, count?) where start >= 0 && count > 0 && start <= Int.max - count:
            self = .run(start ..< start + count)
        default:
            self = .invalid
        }
    }

    /// The run, when a book of `bookPageCount` pages holds all of it.
    static func pages(_ run: Range<Int>, inBookOf bookPageCount: Int) -> Range<Int>? {
        guard !run.isEmpty, run.lowerBound >= 0, run.upperBound <= bookPageCount else { return nil }
        return run
    }
}

/// The iOS projection of `SourceReviewGuide`. It deliberately mirrors only the
/// fields the phone needs; unknown/new payload fields remain forward-compatible.
struct MobileCloudSourceReviewGuide: Decodable, Equatable, Sendable {
    let sourceSHA256: String
    let guide: String
    let generatorVersion: Int
}

/// Pure payload parsing shared by the iPhone catalog and macOS-hosted contract
/// tests. Source payloads are encrypted by CloudKit, but their decoded JSON has
/// the same root-level `sourceReviewGuide` sibling on every device.
enum MobileSourceReviewGuidePayloadParser {
    private struct Envelope: Decodable {
        let sourceReviewGuide: MobileCloudSourceReviewGuide?
    }

    static func reviewGuide(from payloadData: Data) -> MobileCloudSourceReviewGuide? {
        try? JSONDecoder().decode(Envelope.self, from: payloadData).sourceReviewGuide
    }
}

enum MobilePaperFigurePayloadParser {
    private struct Envelope: Decodable {
        let paperFigures: [SyncedPaperFigure]?
    }

    static func figures(from payloadData: Data) -> [SyncedPaperFigure] {
        (try? JSONDecoder().decode(Envelope.self, from: payloadData).paperFigures) ?? []
    }
}

/// A Notebook synced from the Mac: a companion Learning Goal with no parent
/// Notebook. Carries the approved source pool so the phone can scope a voice
/// session to exactly the sources that Notebook holds on the Mac.
struct MobileCloudNotebook: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let title: String
    /// The Notebook's standing Instructions (`goal.description` on the Mac) —
    /// guidance the user wrote for chats inside this Notebook.
    let instructions: String?
    /// The short description shown on the Mac's Notebook card (`goal.summary`).
    let summary: String?
    /// The GitHub repository the Notebook is about, as `owner/repo`
    /// (`goal.repository` on the Mac); nil when none. Only the name syncs — the
    /// repository itself is read live through the GitHub tools.
    let repository: String?
    /// Approved pool source IDs in pool order, deduplicated — the mirror of
    /// `LearningGoalRecord.approvedSourceIDs`. Pending and rejected discovery
    /// suggestions are excluded, exactly as they are from the Mac's chat context.
    let sourceIDs: [String]
    /// The notebooks it links to, its context notebooks, in link order (the
    /// Mac's `relatedNotebookIDs`). A link is the notebook's own and reads
    /// nothing by itself: a context notebook's sources reach its chats only
    /// while the member has put it in (`MobileNotebookChatSelection`).
    let relatedNotebookIDs: [String]
    /// What a conversation on this value reads: the notebook's own sources,
    /// or, on a value `narrowed(toSourceIDs:)` to what its chats read, exactly
    /// those, its context notebooks' included. Never what the chats read on
    /// its own: that is the member's two rows (`MobileNotebookChatSelection`).
    let contextSourceIDs: [String]
    /// Its own approved sources as the Mac knows them: every approved id of
    /// the record, archived and hidden ones included, by the Mac's ids, so a
    /// box written here stays inside the pool the Mac prunes the rows to —
    /// plus, after each source this phone holds under another id, that id
    /// (`MobileNotebookSourceIdentityResolver.remap`), so that row's box
    /// writes. What the member's rows name; the rows this phone lists are
    /// `sourceIDs`. Defaults to `sourceIDs`.
    let poolSourceIDs: [String]
    /// Its context notebooks this phone has a record of, in link order, each
    /// with the sources its group lists and the ids its boxes are kept by:
    /// the groups under the notebook's own sources. A link this phone has no
    /// record of has none (`MobileNotebookChatSelection.linked(of:)`).
    let contextNotebooks: [MobileCloudContextNotebook]
    /// The courses the Mac links to this notebook (the payload's top-level
    /// `linkedCourseIDs`, `notebook_course_links`), in the Mac's order.
    let linkedCourseIDs: [String]
    /// How many approved sources its record names: the Mac's
    /// `approvedSourceIDs`, archived and hidden ones included, the ones a
    /// share carries into a team (what its Share says, `NotebookShareLine`).
    /// Defaults to the count of `sourceIDs`.
    let approvedSourceCount: Int
    /// Archived Notebooks stay synced but leave every selector, matching the Mac.
    let isArchived: Bool
    let updatedAt: Date

    init(
        id: String,
        title: String,
        instructions: String?,
        summary: String? = nil,
        repository: String? = nil,
        sourceIDs: [String],
        relatedNotebookIDs: [String] = [],
        contextSourceIDs: [String]? = nil,
        poolSourceIDs: [String]? = nil,
        contextNotebooks: [MobileCloudContextNotebook] = [],
        linkedCourseIDs: [String] = [],
        approvedSourceCount: Int? = nil,
        isArchived: Bool,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.instructions = instructions
        self.summary = summary
        self.repository = repository
        self.sourceIDs = sourceIDs
        self.relatedNotebookIDs = relatedNotebookIDs
        self.contextSourceIDs = contextSourceIDs ?? sourceIDs
        self.poolSourceIDs = poolSourceIDs ?? sourceIDs
        self.contextNotebooks = contextNotebooks
        self.linkedCourseIDs = linkedCourseIDs
        self.approvedSourceCount = approvedSourceCount ?? sourceIDs.count
        self.isArchived = isArchived
        self.updatedAt = updatedAt
    }

    /// This notebook reading exactly `sourceIDs`, in their order — what its
    /// chats read (`MobileNotebookChatSelection.chatSourceIDs(of:selection:)`),
    /// its context notebooks' sources included — for a voice conversation on
    /// them. The id, title and instructions stay, so the session is filed
    /// under the notebook; its own sources narrow with it.
    func narrowed(toSourceIDs sourceIDs: [String]) -> MobileCloudNotebook {
        let kept = Set(sourceIDs)
        var seen = Set<String>()
        return MobileCloudNotebook(
            id: id,
            title: title,
            instructions: instructions,
            summary: summary,
            repository: repository,
            sourceIDs: self.sourceIDs.filter(kept.contains),
            relatedNotebookIDs: relatedNotebookIDs,
            contextSourceIDs: sourceIDs.filter { seen.insert($0).inserted },
            poolSourceIDs: poolSourceIDs,
            contextNotebooks: contextNotebooks,
            linkedCourseIDs: linkedCourseIDs,
            approvedSourceCount: approvedSourceCount,
            isArchived: isArchived,
            updatedAt: updatedAt
        )
    }
}

/// A notebook a notebook links to — one of its **context notebooks**
/// (`relatedNotebookIDs`, the Mac inspector's "Uses context from") — as this
/// phone holds it: what its group under the notebook's own sources lists, and
/// the ids its boxes are kept by (docs/notebooks-design.md, "iPhone"). Its
/// own links never come in: one level deep.
struct MobileCloudContextNotebook: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let title: String
    /// Its approved sources this phone lists, in its study order, by the ids
    /// this phone holds them under: the group's rows.
    let sourceIDs: [String]
    /// Its approved sources as the Mac knows them, with this phone's ids
    /// beside them: its record's `poolSourceIDs`, what the member's rows name.
    let poolSourceIDs: [String]
}

/// A notebook as the phone lists it, from its record and every notebook
/// record this phone holds (archived ones included, as the Mac's pool counts
/// them): its own sources narrowed to the ones this phone lists, and its
/// context notebooks in link order, each with the sources its group lists
/// and the ids its boxes are kept by. Foundation-only, so the Mac unit tests
/// build a notebook from records as the catalog does.
enum MobileNotebookCatalog {
    /// `isListed` answers whether this phone lists a source: an id whose
    /// source has not arrived yet stays (the count can then say it is still
    /// syncing), and one that arrived archived or hidden goes.
    static func notebook(
        _ record: MobileCloudNotebook,
        records: [String: MobileCloudNotebook],
        isListed: (String) -> Bool
    ) -> MobileCloudNotebook {
        let own = record.sourceIDs.filter(isListed)
        let contextNotebooks = record.relatedNotebookIDs.compactMap { linkedID -> MobileCloudContextNotebook? in
            guard linkedID != record.id, let linked = records[linkedID] else { return nil }
            return MobileCloudContextNotebook(
                id: linked.id,
                title: linked.title,
                sourceIDs: linked.sourceIDs.filter(isListed),
                poolSourceIDs: linked.poolSourceIDs
            )
        }
        return MobileCloudNotebook(
            id: record.id,
            title: record.title,
            instructions: record.instructions,
            summary: record.summary,
            repository: record.repository,
            sourceIDs: own,
            relatedNotebookIDs: record.relatedNotebookIDs,
            contextSourceIDs: own,
            poolSourceIDs: record.poolSourceIDs,
            contextNotebooks: contextNotebooks,
            linkedCourseIDs: record.linkedCourseIDs,
            approvedSourceCount: record.approvedSourceCount,
            isArchived: record.isArchived,
            updatedAt: record.updatedAt
        )
    }
}

enum MobileNotebookSourceIdentityResolver {
    static func remap(
        notebook: MobileCloudNotebook,
        identities: [MobileMemorySourceIdentity],
        sources: [MobileCloudSource],
        normalizeURL: @escaping (String) -> String
    ) -> MobileCloudNotebook {
        let identityIndex = MobileMemorySourceIdentityResolver.Index(
            sources: sources,
            normalizeURL: normalizeURL
        )
        return remap(
            notebook: notebook,
            identities: identities,
            identityIndex: identityIndex
        )
    }

    static func remap(
        notebook: MobileCloudNotebook,
        identities: [MobileMemorySourceIdentity],
        identityIndex: MobileMemorySourceIdentityResolver.Index
    ) -> MobileCloudNotebook {
        let identitiesBySourceID = Dictionary(
            identities.map { ($0.sourceID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen = Set<String>()
        let sourceIDs = notebook.sourceIDs.compactMap { sourceID -> String? in
            let resolved = identityIndex.resolvedSourceID(
                sourceID,
                identity: identitiesBySourceID[sourceID]
            )
            return seen.insert(resolved).inserted ? resolved : nil
        }
        var contextSeen = Set<String>()
        let contextSourceIDs = notebook.contextSourceIDs.compactMap { sourceID -> String? in
            let resolved = identityIndex.resolvedSourceID(
                sourceID,
                identity: identitiesBySourceID[sourceID]
            )
            return contextSeen.insert(resolved).inserted ? resolved : nil
        }
        // The boxes' pool keeps the Mac's own ids, which the synced rows name
        // and are pruned against on both sides, so a box ticked here never
        // drops an untick the Mac wrote for an id this phone holds under
        // another; the id it holds it under follows, so that row's box writes.
        // A notebook that links this one reads this pool for its group
        // (`MobileNotebookCatalog`), so a context notebook's boxes keep the
        // same ids.
        var poolSeen = Set<String>()
        var poolSourceIDs: [String] = []
        for sourceID in notebook.poolSourceIDs {
            if poolSeen.insert(sourceID).inserted { poolSourceIDs.append(sourceID) }
            let resolved = identityIndex.resolvedSourceID(
                sourceID,
                identity: identitiesBySourceID[sourceID]
            )
            if resolved != sourceID, poolSeen.insert(resolved).inserted { poolSourceIDs.append(resolved) }
        }
        guard sourceIDs != notebook.sourceIDs
            || contextSourceIDs != notebook.contextSourceIDs
            || poolSourceIDs != notebook.poolSourceIDs else { return notebook }
        return MobileCloudNotebook(
            id: notebook.id,
            title: notebook.title,
            instructions: notebook.instructions,
            summary: notebook.summary,
            repository: notebook.repository,
            sourceIDs: sourceIDs,
            relatedNotebookIDs: notebook.relatedNotebookIDs,
            contextSourceIDs: contextSourceIDs,
            poolSourceIDs: poolSourceIDs,
            contextNotebooks: notebook.contextNotebooks,
            linkedCourseIDs: notebook.linkedCourseIDs,
            approvedSourceCount: notebook.approvedSourceCount,
            isArchived: notebook.isArchived,
            updatedAt: notebook.updatedAt
        )
    }
}

/// The small goal projection the phone needs to label and filter shared
/// Schedule placements. It intentionally carries no source pool; Notebooks use
/// `MobileCloudNotebook` for that richer browsing context.
struct MobileCloudGoal: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let status: String
    let kind: String?
    let parentNotebookID: String?
    let updatedAt: Date

    var isActive: Bool {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "done", "archived": return false
        default: return true
        }
    }
}

/// One shared calendar placement decoded from a top-level ScheduledSource
/// CloudKit record. The source and goal titles are resolved only after the
/// complete catalog has been assembled, so record delivery order is irrelevant.
struct MobileCloudScheduledSource: Identifiable, Equatable, Sendable {
    let id: String
    let sourceID: String
    let sourceIdentity: MobileMemorySourceIdentity?
    let plannedAt: Date
    let completedAt: Date?
    let goalIDs: [String]
    let updatedAt: Date
    let activityDays: [SourceActivityDay]
    let isAutomatic: Bool

    init(
        id: String,
        sourceID: String,
        sourceIdentity: MobileMemorySourceIdentity?,
        plannedAt: Date,
        completedAt: Date?,
        goalIDs: [String],
        updatedAt: Date,
        activityDays: [SourceActivityDay] = [],
        isAutomatic: Bool = false
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceIdentity = sourceIdentity
        self.plannedAt = plannedAt
        self.completedAt = completedAt
        self.goalIDs = goalIDs
        self.updatedAt = updatedAt
        self.activityDays = activityDays
        self.isAutomatic = isAutomatic
    }

    var isCompleted: Bool { completedAt != nil }
}

/// A Schedule row ready for SwiftUI: the placement's source relationship and
/// display labels have already been resolved off the render path.
struct MobileScheduledCatalogItem: Identifiable, Equatable, Sendable {
    let id: String
    let source: MobileCloudSource
    let plannedAt: Date
    let isCompleted: Bool
    let completedAt: Date?
    let groupTitle: String?
    let goalTitles: [String]
    /// Full membership, including top-level Notebooks whose titles may be hidden
    /// from the row subtitle. Used for Notebook filtering and scoped removal.
    let goalIDs: [String]
    let activityDays: [SourceActivityDay]
    let isAutomatic: Bool

    init(
        id: String,
        source: MobileCloudSource,
        plannedAt: Date,
        isCompleted: Bool,
        completedAt: Date?,
        groupTitle: String?,
        goalTitles: [String],
        goalIDs: [String],
        activityDays: [SourceActivityDay] = [],
        isAutomatic: Bool = false
    ) {
        self.id = id
        self.source = source
        self.plannedAt = plannedAt
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.groupTitle = groupTitle
        self.goalTitles = goalTitles
        self.goalIDs = goalIDs
        self.activityDays = activityDays
        self.isAutomatic = isAutomatic
    }
}

enum MobileSourceArtwork {
    static func youtubeVideoId(from url: String) -> String? {
        ForeverLMCore.youtubeVideoID(from: url)
    }

    static func youtubeThumbnailURL(for url: String) -> URL? {
        ForeverLMCore.youtubeThumbnailURL(for: url).flatMap(URL.init(string:))
    }
}

/// A book synced from the Mac's `Book` record — display metadata for the
/// chapter sources that carry its id in `parentGroup`.
struct MobileCloudBook: Equatable, Sendable {
    let id: String
    let title: String
    let author: String?
    /// CloudKit record name of the backing Book record — the handle the cover
    /// fetch needs. Filled from the catalog's record-name key, not the payload.
    var recordName: String? = nil
}

/// One lecture inside a synced course — the Mac's `CourseSession`.
struct MobileCourseLecture: Identifiable, Equatable, Sendable {
    let id: String
    let number: Int
    let title: String?
}

/// One material attached to a lecture — the Mac's `CourseLectureItem`. The
/// phone renders whole sources only, so items pointing at a source unit rather
/// than a source are dropped at parse time.
struct MobileCourseLectureItem: Identifiable, Equatable, Sendable {
    let id: String
    let lectureID: String
    let sourceID: String
    /// The Mac's `CourseLectureItemRole` raw value; `video` is what separates a
    /// lecture recording from its supporting material.
    let role: String
    let sortIndex: Int
}

/// A course synced from the Mac's `Course` record. `isHidden` hides the whole
/// course and every lecture in it, exactly as the Mac's Courses tab does.
struct MobileCloudCourse: Equatable, Sendable {
    let id: String
    let title: String
    let institution: String?
    let isHidden: Bool
    /// The course outline the Mac syncs on the record. Course membership lives
    /// here and nowhere else: `addArticleToCourse` attaches a source to a
    /// lecture and deliberately leaves its `parentGroup` — its primary library
    /// home — alone. Grouping courses the way books are grouped therefore finds
    /// nothing at all.
    var lectures: [MobileCourseLecture] = []
    var lectureItems: [MobileCourseLectureItem] = []
    /// The course's stored quizzes, riding the same record
    /// (`CloudKitCoursePayload.quizzes`). Empty until the course has any.
    var quizzes: [CourseQuiz] = []
}

/// The non-source records the Knowledge zone carries that shape how sources
/// display: book/course metadata for grouped lists, and the hidden sets the
/// Mac's visibility rule reads.
struct MobileCatalogCollections: Equatable, Sendable {
    var booksByID: [String: MobileCloudBook] = [:]
    var coursesByID: [String: MobileCloudCourse] = [:]
    /// `HiddenPodcastShow.showName` values; episodes match on their domain.
    var hiddenPodcastShowNames: Set<String> = []
    /// `HiddenYouTubeChannel.channelName` values; videos match on their subtitle/domain.
    var hiddenYouTubeChannelNames: Set<String> = []
    /// Meeting-group ids whose synced metadata carries `isHidden`.
    var hiddenMeetingGroupIDs: Set<String> = []

    static let empty = MobileCatalogCollections()

    /// The title of the book or course `source` belongs to, which the lists'
    /// search matches along with the source's own fields.
    func groupTitle(of source: MobileCloudSource) -> String? {
        guard let group = source.parentGroup else { return nil }
        return booksByID[group]?.title ?? coursesByID[group]?.title
    }
}

/// Mirrors the Mac's `StudioViewModel.isSourceHidden` plus its hidden-group
/// metadata filters, so a source hidden on the Mac never shows on the phone:
/// the per-source flag, whole podcast shows (minus per-episode visible
/// overrides), hidden courses, and hidden meeting series.
enum MobileSourceVisibility {
    /// A source whose whole feed is hidden — an episode of a hidden show or a
    /// video of a hidden channel — with no visible override of its own. These
    /// leave the memory review too; a source hidden by itself does not, because
    /// hiding one source is visual only (product owner, 2026-09-11). Mirrors the Mac's
    /// `isSourceCollectionHidden` and `source_projection.is_collection_hidden`.
    static func isCollectionHidden(_ source: MobileCloudSource, collections: MobileCatalogCollections) -> Bool {
        if source.sourceType == "podcast",
           let show = source.subtitle,
           collections.hiddenPodcastShowNames.contains(show),
           !source.visiblePodcastEpisodeOverride {
            return true
        }
        if source.sourceType == "video",
           let channel = source.subtitle,
           collections.hiddenYouTubeChannelNames.contains(where: {
               $0.localizedCaseInsensitiveCompare(channel) == .orderedSame
           }),
           !source.visibleYouTubeVideoOverride {
            return true
        }
        return false
    }

    static func isHidden(_ source: MobileCloudSource, collections: MobileCatalogCollections) -> Bool {
        if source.isHidden { return true }
        if source.sourceType == "podcast",
           let show = source.subtitle,
           collections.hiddenPodcastShowNames.contains(show),
           !source.visiblePodcastEpisodeOverride {
            return true
        }
        if source.sourceType == "video",
           let channel = source.subtitle,
           collections.hiddenYouTubeChannelNames.contains(where: {
               $0.localizedCaseInsensitiveCompare(channel) == .orderedSame
           }),
           !source.visibleYouTubeVideoOverride {
            return true
        }
        if let group = source.parentGroup {
            if source.sourceType == "course",
               collections.coursesByID[group]?.isHidden == true {
                return true
            }
            if source.sourceType == "meeting",
               collections.hiddenMeetingGroupIDs.contains(group) {
                return true
            }
        }
        return false
    }
}

/// The phone's counterpart to the Mac's collapsed "Marked paywalled" shelf.
/// A marked source is separated out of the browsing lists rather than dropped:
/// it stays searchable and keeps its Notebook and Schedule memberships, exactly
/// as hiding does on the Mac. `paywalled` is what the shelf itself lists.
enum MobilePaywallShelf {
    /// The Mac's `SourceStatusFlag.paywall` sentinel. It is stored
    /// verbatim in `sources.error_message`, so it rides the wire in the synced
    /// article body alongside the newer `isPaywalled` column.
    static let paywallSentinel = "paywall"

    /// Folds the Mac's two paywall markers into the phone's single flag: the
    /// `is_paywalled` column, and the `paywall` sentinel it also stores in
    /// `error_message`. Only an
    /// exact sentinel match counts — a genuine free-text error is not a paywall.
    static func isPaywalled(column: Bool?, errorMessage: String?) -> Bool {
        (column ?? false) || errorMessage == paywallSentinel
    }

    static func browsable(_ sources: [MobileCloudSource]) -> [MobileCloudSource] {
        sources.filter { !$0.isPaywalled }
    }

    static func paywalled(
        _ sources: [MobileCloudSource],
        ofType sourceType: String? = nil
    ) -> [MobileCloudSource] {
        sources.filter { source in
            guard source.isPaywalled else { return false }
            guard let sourceType else { return true }
            return source.sourceType == sourceType
        }
    }
}

/// Which sources the phone lists as rows. An explainer is stored as an
/// ordinary article-typed source (explainer-design.md) but is never a row of
/// its own: it belongs to the paper or article it explains, whose row badge,
/// menu item and reader control (`MobileExplainerStatus`) reach it. An audio
/// overview's carrier is the same kind of row and belongs to its notebook,
/// whose page lists it under Audio overviews. Every browsing list runs
/// through `listed` so the two never disagree.
enum MobileSourceListing {
    static func isExplainer(_ source: MobileCloudSource) -> Bool {
        ExplainerScript.isExplainerURL(source.url ?? "")
    }

    /// A spoken script ForeverLM wrote: an explainer or an audio overview's
    /// carrier. Never a row of its own.
    static func isSpokenScript(_ source: MobileCloudSource) -> Bool {
        ExplainerScript.isSpokenScriptURL(source.url ?? "")
    }

    /// The sources a list shows: not marked paywalled (those sit on the shelf)
    /// and not a spoken script (those sit under their source or notebook).
    static func listed(_ sources: [MobileCloudSource]) -> [MobileCloudSource] {
        MobilePaywallShelf.browsable(sources).filter { !isSpokenScript($0) }
    }
}

extension MobileCloudSource {
    /// The automatic-audio switch this source falls under: its source type,
    /// or `explainer` for an explainer, which is an article-typed row with a
    /// switch of its own — the same rule the Mac applies
    /// (`SourceAudioAutomation.kind(forSourceType:url:)`).
    var audioAutomationKind: String {
        SourceAudioAutomation.kind(forSourceType: sourceType, url: url)
    }
}

/// The memory attempt payload as the phone reads it. It lives with the pure
/// source projections so macOS unit tests can verify out-of-order delivery
/// without compiling the phone's CloudKit/UI actor.
struct MobileCloudMemoryAttemptPayload: Decodable, Sendable {
    let payloadVersion: Int
    let attempt: MemoryAttempt
    let parentCurriculumFingerprint: String?

    init(
        payloadVersion: Int,
        attempt: MemoryAttempt,
        parentCurriculumFingerprint: String? = nil
    ) {
        self.payloadVersion = payloadVersion
        self.attempt = attempt
        self.parentCurriculumFingerprint = parentCurriculumFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case payloadVersion
        case attempt
        case parentCurriculumFingerprint
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        payloadVersion = try values.decodeIfPresent(Int.self, forKey: .payloadVersion) ?? 0
        attempt = try values.decode(MemoryAttempt.self, forKey: .attempt)
        parentCurriculumFingerprint = try values.decodeIfPresent(
            String.self,
            forKey: .parentCurriculumFingerprint
        )
    }
}

enum MobileMemoryAttemptCurriculumProjection {
    /// Fail closed on missing parents and on malformed/mismatched v2 evidence.
    /// A nil fingerprint is accepted only for payloads without the parent
    /// snapshot field.
    static func compatibleAttempts(
        items: [MemoryItem],
        envelopesByRecordName: [String: MobileCloudMemoryAttemptPayload]
    ) -> [String: MemoryAttempt] {
        let itemsByID = Dictionary(
            items.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return envelopesByRecordName.reduce(into: [:]) { result, entry in
            let envelope = entry.value
            guard let parent = itemsByID[envelope.attempt.memoryItemID] else { return }
            let expected = MemoryTutorIdentity.immutableCurriculumFingerprint(parent)
            if envelope.payloadVersion >= 2 {
                guard envelope.parentCurriculumFingerprint == expected else { return }
            } else if let fingerprint = envelope.parentCurriculumFingerprint {
                guard fingerprint == expected else { return }
            }
            result[entry.key] = envelope.attempt
        }
    }
}

/// Pure all-anchor scope gate used before mobile scheduling applies its LIMIT.
/// Filtering a global top-N afterward can starve a Notebook whose first eligible
/// item sits behind more-overdue work from elsewhere in the library.
enum MobileMemoryReviewScope {
    static func eligibleItems(
        _ items: [MemoryItem],
        availableSourceIDs: Set<String>,
        restrictToSourceIDs: Set<String>? = nil
    ) -> [MemoryItem] {
        var scopedSourceIDs = availableSourceIDs
        if let restrictToSourceIDs {
            scopedSourceIDs.formIntersection(restrictToSourceIDs)
        }
        return items.filter { item in
            item.status == .active
                && !item.sources.isEmpty
                && item.sources.allSatisfy { scopedSourceIDs.contains($0.sourceID) }
        }
    }
}

/// What the phone deals today's cards by from the account's Memory review
/// settings (the Mac's Settings › Background › Memory review): the day's minutes
/// (`MemoryReviewBudget`) and its new cards (`memory.new_cards_per_day`). Each
/// is a synced row the phone fetches from CloudKit on every load and
/// foreground; the phone hydrates no synced preference, so these are what it
/// last read.
struct MobileMemoryReviewPreferences: Equatable, Sendable {
    /// nil until the first read lands, and today's cards are dealt uncut
    /// until then.
    var budgetMinutes: Int?
    /// The Mac's default until the first read lands.
    var newCardsPerDay = MemoryCardQueue.defaultNewPerDay

    /// These preferences after one read of each row. A row the learner never
    /// set is the product's default, the Mac's; a read that failed keeps the
    /// value last read.
    func refreshed(budgetRead: Result<Int?, Error>, newCardsRead: Result<Int?, Error>) -> Self {
        var next = self
        if case .success(let stored) = budgetRead {
            next.budgetMinutes = stored ?? MemoryReviewBudget.defaultMinutes
        }
        if case .success(let stored) = newCardsRead {
            next.newCardsPerDay = MemoryCardQueue.newPerDay(stored: stored)
        }
        return next
    }
}

/// One member row inside a group screen. `displayTitle` carries the Mac's
/// lecture numbering ("3) Architectures"); nil keeps the source's own title.
struct MobileSourceGroupItem: Identifiable, Equatable, Sendable {
    let source: MobileCloudSource
    var displayTitle: String? = nil

    var id: String { source.id }
}

/// One folder inside a course screen — the Mac's Lectures / Papers / Materials
/// split. Books and folder-derived course groups carry none; their screens list
/// `sources` flat.
struct MobileSourceGroupSection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let systemImage: String
    let items: [MobileSourceGroupItem]
}

/// One book or course, as the phone's lists render it: the Mac's display
/// metadata over the member sources in the Mac's order.
struct MobileSourceGroup: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let sources: [MobileCloudSource]
    /// Record name of the backing Book record, for the synced cover asset.
    /// nil for courses and for groups whose Book record has not synced.
    var coverRecordName: String? = nil
    /// "18 lectures · 6 materials" — what this group actually holds, built
    /// where the members are known rather than guessed from the type.
    var memberSummary: String? = nil
    /// Course folders, in the Mac's order. Empty means a flat member list.
    var sections: [MobileSourceGroupSection] = []

    /// Whether this book is a finished audiobook — see
    /// `MobileSourceGrouping.isAudiobookComplete`.
    var isAudiobookComplete: Bool {
        MobileSourceGrouping.isAudiobookComplete(chapters: sources)
    }
}

enum MobileSourceGrouping {
    /// Which types render as grouped containers rather than flat lists.
    static func isGroupedType(_ sourceType: String) -> Bool {
        sourceType == "book" || sourceType == "course"
    }

    /// Whether every chapter still in a book has text-to-speech audio on this
    /// phone — synced from the Mac or generated here — so the book row can
    /// say "audiobook ready" without being opened, the way the Mac's book row
    /// does. `hasAudio` is stamped on each row from the synced manifests, and
    /// a manifest counts before its audio has downloaded: the library says the
    /// narration exists, and pressing play fetches it. Archived chapters are
    /// not part of the book any more (the whole-book generation quote skips
    /// them for the same reason), and a book with nothing to narrate is not a
    /// finished audiobook.
    static func isAudiobookComplete(chapters: [MobileCloudSource]) -> Bool {
        let current = chapters.filter { !$0.isArchived }
        return !current.isEmpty && current.allSatisfy(\.hasAudio)
    }

    /// Splits one type's sources into its containers plus standalone rows.
    ///
    /// Books group by `parentGroup`, the key their chapters carry. Courses do
    /// not: see `courseGroups`.
    static func groups(
        ofType sourceType: String,
        in sources: [MobileCloudSource],
        collections: MobileCatalogCollections
    ) -> (groups: [MobileSourceGroup], standalone: [MobileCloudSource]) {
        if sourceType == "course" {
            return courseGroups(in: sources, collections: collections)
        }
        return parentGroupGroups(ofType: sourceType, in: sources, collections: collections)
    }

    /// Splits one type's sources into `parentGroup` groups plus standalone
    /// rows, titling each group from the synced Book record. A group whose
    /// record has not synced falls back to the raw group key rather than
    /// disappearing. Groups come back in natural title order.
    private static func parentGroupGroups(
        ofType sourceType: String,
        in sources: [MobileCloudSource],
        collections: MobileCatalogCollections
    ) -> (groups: [MobileSourceGroup], standalone: [MobileCloudSource]) {
        var byGroup: [String: [MobileCloudSource]] = [:]
        var standalone: [MobileCloudSource] = []
        for source in sources where source.sourceType == sourceType {
            if let group = source.parentGroup, !group.isEmpty {
                byGroup[group, default: []].append(source)
            } else {
                standalone.append(source)
            }
        }

        let groups = byGroup
            .map { key, members -> MobileSourceGroup in
                let ordered = members.sorted(by: memberOrder)
                switch sourceType {
                case "book":
                    let book = collections.booksByID[key]
                    return MobileSourceGroup(
                        id: key,
                        title: book?.title ?? key,
                        subtitle: book?.author,
                        sources: ordered,
                        coverRecordName: book?.recordName,
                        memberSummary: countSummary(ordered.count, noun: "chapter")
                    )
                default:
                    return MobileSourceGroup(
                        id: key,
                        title: key,
                        subtitle: nil,
                        sources: ordered,
                        memberSummary: countSummary(ordered.count, noun: "item")
                    )
                }
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return (groups, standalone)
    }

    /// A course's members are the sources its synced lecture outline names —
    /// mostly videos and papers, which keep their own library home and so carry
    /// no `parentGroup` pointing back at the course. Grouping courses the way
    /// books are grouped found nothing and listed every lecture as a loose row.
    ///
    /// Each outlined course comes back as one path, the way the Mac's ladder
    /// lists it: every lecture's video, then the papers, readings and notes
    /// filed under it, lecture by lecture, with material no lecture claims at
    /// the end. There is no Papers folder (product owner, 2026-09-26: "it should just
    /// be like one structured flow"). Courses come back in natural title order.
    /// Course-typed material no course claims is surfaced nowhere, exactly as on
    /// the Mac — see the note where the outlined courses are returned.
    static func courseGroups(
        in sources: [MobileCloudSource],
        collections: MobileCatalogCollections
    ) -> (groups: [MobileSourceGroup], standalone: [MobileCloudSource]) {
        let sourcesByID = Dictionary(
            sources.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var outlined: [MobileSourceGroup] = []
        for course in collections.coursesByID.values where !course.isHidden {
            let itemsByLecture = Dictionary(grouping: course.lectureItems, by: \.lectureID)
            var pathItems: [MobileSourceGroupItem] = []
            var lectureCount = 0
            var readingCount = 0
            var materialCount = 0
            var seen = Set<String>()

            func appendUnderLecture(_ source: MobileCloudSource) {
                pathItems.append(MobileSourceGroupItem(source: source))
                if source.sourceType == "paper" || source.sourceType == "book" {
                    readingCount += 1
                } else {
                    materialCount += 1
                }
            }

            for lecture in course.lectures.sorted(by: lectureOrder) {
                let ordered = (itemsByLecture[lecture.id] ?? []).sorted(by: lectureItemOrder)
                var videos: [MobileSourceGroupItem] = []
                var readings: [MobileCloudSource] = []
                var materials: [MobileCloudSource] = []
                let citedOnly = citedOnlyItemIDs(ordered, sourcesByID: sourcesByID)
                for item in ordered where !citedOnly.contains(item.id) {
                    guard let source = sourcesByID[item.sourceID],
                          seen.insert(source.id).inserted else { continue }
                    if source.sourceType == "paper" {
                        readings.append(source)
                    } else if item.role == "video" {
                        videos.append(MobileSourceGroupItem(
                            source: source,
                            displayTitle: lectureDisplayTitle(number: lecture.number, title: lecture.title)
                        ))
                    } else {
                        materials.append(source)
                    }
                }
                // The Mac's ladder order within a lecture: the video, then its
                // readings, then its notes, slides and problem sets.
                pathItems.append(contentsOf: videos)
                lectureCount += videos.count
                for source in readings + materials {
                    appendUnderLecture(source)
                }
            }

            // Sources the Mac filed under the course itself without attaching
            // them to a lecture close the path, as they do on the Mac.
            for source in sources
            where source.parentGroup == course.id && seen.insert(source.id).inserted {
                appendUnderLecture(source)
            }

            // A course whose members have not synced yet is an empty row the
            // phone cannot open into anything. The Mac shows it because the Mac
            // can drop sources onto it; the phone cannot.
            guard !pathItems.isEmpty else { continue }

            let summary = [
                (lectureCount, "lecture"),
                (readingCount, "reading"),
                (materialCount, "material"),
            ]
            .filter { $0.0 > 0 }
            .map { countSummary($0.0, noun: $0.1) }
            .joined(separator: " \u{00B7} ")

            outlined.append(MobileSourceGroup(
                id: course.id,
                title: course.title,
                subtitle: course.institution,
                sources: pathItems.map(\.source),
                memberSummary: summary,
                sections: [MobileSourceGroupSection(
                    id: "course",
                    title: "Lectures",
                    systemImage: "play.rectangle.on.rectangle",
                    items: pathItems
                )]
            ))
        }

        // Course material the outline never claimed is surfaced nowhere, which
        // is what the Mac does with it too: a course-typed source reaches a list
        // only through a course, so material in none of them has no home to be
        // listed under. The Mac hides it when the course that held it is removed
        // (`hideCourseSourcesWithoutCourse`), and hidden sources never reach
        // this far; anything still here is either mid-sync or from a Mac that
        // has not run that migration, and grouping it by the course name it
        // happens to carry would resurrect a course the learner deleted.
        let byTitle: (MobileSourceGroup, MobileSourceGroup) -> Bool = {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        return (outlined.sorted(by: byTitle), [])
    }

    private static func countSummary(_ count: Int, noun: String) -> String {
        "\(count) \(count == 1 ? noun : noun + "s")"
    }

    /// The Mac's lecture numbering. Mac-authored lecture titles usually already
    /// carry the number ("3) Architectures"), so only a title missing it gets
    /// the prefix added.
    /// Papers a lecture's video only cites: on the lecture as `reference` or
    /// `other` rather than assigned as `reading`. The Mac keeps them off the
    /// course's path and under the video's Papers menu
    /// (`StudioViewModel.lectureVideoPapers`), so they are not course material
    /// here either. A lecture with no video has nothing that cites them.
    static func citedOnlyItemIDs(
        _ items: [MobileCourseLectureItem],
        sourcesByID: [String: MobileCloudSource]
    ) -> Set<String> {
        let hasVideo = items.contains { item in
            item.role == "video" && sourcesByID[item.sourceID].map { $0.sourceType != "paper" } == true
        }
        guard hasVideo else { return [] }
        return Set(items.filter { item in
            item.role != "reading" && sourcesByID[item.sourceID]?.sourceType == "paper"
        }.map(\.id))
    }

    static func lectureDisplayTitle(number: Int, title: String?) -> String {
        let prefix = "\(number))"
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return prefix
        }
        if trimmed.hasPrefix(prefix) { return trimmed }
        return "\(prefix) \(trimmed)"
    }

    static func lectureOrder(_ lhs: MobileCourseLecture, _ rhs: MobileCourseLecture) -> Bool {
        lhs.number != rhs.number ? lhs.number < rhs.number : lhs.id < rhs.id
    }

    static func lectureItemOrder(_ lhs: MobileCourseLectureItem, _ rhs: MobileCourseLectureItem) -> Bool {
        lhs.sortIndex != rhs.sortIndex ? lhs.sortIndex < rhs.sortIndex : lhs.id < rhs.id
    }

    /// The Mac's in-group order: explicit sort index first (nils after), then
    /// natural title order so "Chapter 2" sorts before "Chapter 10".
    static func memberOrder(_ lhs: MobileCloudSource, _ rhs: MobileCloudSource) -> Bool {
        if let left = lhs.courseSortIndex, let right = rhs.courseSortIndex, left != right {
            return left < right
        }
        if (lhs.courseSortIndex != nil) != (rhs.courseSortIndex != nil) {
            return lhs.courseSortIndex != nil
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}

extension MobileSourceGrouping {
    /// The chapters the reader scrolls through when `source` is opened: every
    /// chapter of its book still in the library, in the book's own order (the order
    /// its chapter list shows), with `source` among them even when it is archived.
    /// Empty — the reader then reads `source` alone, as it always has — unless
    /// `source` is an EPUB book chapter whose book has another chapter. A chapter
    /// imported from a PDF reads as its own document and is never part of the scroll.
    static func bookReadingOrder(
        for source: MobileCloudSource,
        in catalog: [MobileCloudSource]
    ) -> [MobileCloudSource] {
        guard source.sourceType == "book",
              !source.isPDFBackedBookChapter,
              let book = source.parentGroup, !book.isEmpty else {
            return []
        }
        var seen = Set<String>()
        let chapters = ([source] + catalog)
            .filter { chapter in
                chapter.sourceType == "book"
                    && chapter.parentGroup == book
                    && (chapter.id == source.id || !chapter.isArchived)
                    && !chapter.isPDFBackedBookChapter
                    && seen.insert(chapter.id).inserted
            }
            .sorted(by: memberOrder)
        return chapters.count > 1 ? chapters : []
    }
}

func canonicalSourceType(_ sourceType: String) -> String {
    ForeverLMCore.canonicalSourceType(sourceType)
}

/// Groups a source list into type sections (Papers, Books, Podcasts, …) for
/// the phone's lists. Learning materials lead in a fixed curated order; types
/// this build has never heard of trail alphabetically rather than vanishing.
/// Input order is preserved within each group, so a newest-first list stays
/// newest-first inside every section.
enum MobileSourceTypeGrouping {
    private static let curatedOrder = [
        "paper", "book", "article", "podcast", "video",
        "course", "meeting", "xpost",
    ]

    private static let labels: [String: String] = [
        "paper": "Papers",
        "book": "Books",
        "article": "Articles",
        "podcast": "Podcasts",
        "video": "YouTube",
        "course": "Courses",
        "meeting": "Meetings",
        "xpost": "X",
    ]

    static func label(for sourceType: String) -> String {
        labels[sourceType] ?? sourceType.capitalized
    }

    /// `alsoIncluding` names types that must get a section even with no source
    /// of their own in `sources` — a course's members are videos and papers
    /// filed under their own types, so a library can hold browsable courses
    /// and not one course-typed source.
    static func groups(
        for sources: [MobileCloudSource],
        alsoIncluding extraTypes: Set<String> = []
    ) -> [(sourceType: String, label: String, sources: [MobileCloudSource])] {
        let byType = Dictionary(grouping: sources, by: \.sourceType)
        let knownRank = Dictionary(uniqueKeysWithValues: curatedOrder.enumerated().map { ($1, $0) })
        let orderedTypes = Set(byType.keys).union(extraTypes).sorted { lhs, rhs in
            switch (knownRank[lhs], knownRank[rhs]) {
            case (let left?, let right?): return left < right
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs < rhs
            }
        }
        return orderedTypes.map { (sourceType: $0, label: label(for: $0), sources: byType[$0] ?? []) }
    }
}

/// The phone's list search, shared by the Sources screen, a type screen
/// (Papers, Podcasts, …), a book or course, and a Notebook, so the same words
/// find the same rows wherever they are typed. It is lexical over the fields a
/// row actually shows — title, subtitle, author, journal, year, the Mac's
/// lecture numbering, and the book or course the source belongs to — because
/// that is what the eye would otherwise scan for. Every term must match, in
/// any order, ignoring case and accents; searching the text *inside* a source
/// is the reader's Find, not this.
enum MobileSourceListSearch {
    /// The query as match terms: whitespace-separated, case and accents folded.
    static func terms(in query: String) -> [String] {
        query
            .split(whereSeparator: \.isWhitespace)
            .map { folded(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// Whether one row matches every term. `groupTitle` is the book or course
    /// the source belongs to and `displayTitle` the title the row shows when
    /// it differs from the source's own ("3) Architectures").
    static func matches(
        _ source: MobileCloudSource,
        terms: [String],
        groupTitle: String? = nil,
        displayTitle: String? = nil
    ) -> Bool {
        guard !terms.isEmpty else { return true }
        let haystack = folded(
            [displayTitle, source.title, source.subtitle, source.author,
             source.journal, source.publishedYear, groupTitle]
                .compactMap { $0 }
                .joined(separator: " ")
        )
        return terms.allSatisfy { haystack.contains($0) }
    }

    /// The sources matching `query`, in their incoming order. An empty query
    /// is no filter at all.
    static func filter(
        _ sources: [MobileCloudSource],
        query: String,
        groupTitle: (MobileCloudSource) -> String? = { _ in nil }
    ) -> [MobileCloudSource] {
        let terms = terms(in: query)
        guard !terms.isEmpty else { return sources }
        return sources.filter { matches($0, terms: terms, groupTitle: groupTitle($0)) }
    }

    /// A grouped type (Books, Courses) under search. A container whose own
    /// title matches stays a container, with everything inside it; otherwise
    /// the members that match are surfaced as rows of their own, so a chapter
    /// is found by its name without knowing which book holds it. Standalone
    /// sources are filtered like any flat list.
    static func filter(
        groups: [MobileSourceGroup],
        standalone: [MobileCloudSource],
        query: String
    ) -> (groups: [MobileSourceGroup], members: [MobileCloudSource]) {
        let terms = terms(in: query)
        guard !terms.isEmpty else { return (groups, standalone) }
        var matchingGroups: [MobileSourceGroup] = []
        var members: [MobileCloudSource] = []
        for group in groups {
            // The container row shows its title and subtitle (a book's author,
            // a course's institution), so both count for it and for its members.
            let containerText = [group.title, group.subtitle].compactMap { $0 }.joined(separator: " ")
            if terms.allSatisfy({ folded(containerText).contains($0) }) {
                matchingGroups.append(group)
                continue
            }
            let itemsByID = Dictionary(
                group.sections.flatMap(\.items).map { ($0.source.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            members += group.sources.filter { source in
                matches(
                    source,
                    terms: terms,
                    groupTitle: containerText,
                    displayTitle: itemsByID[source.id]?.displayTitle
                )
            }
        }
        members += standalone.filter { matches($0, terms: terms) }
        return (matchingGroups, members)
    }

    /// A book's or course's own screen under search: each folder keeps only
    /// the items that match, and a folder left empty disappears.
    static func filter(
        sections: [MobileSourceGroupSection],
        query: String
    ) -> [MobileSourceGroupSection] {
        let terms = terms(in: query)
        guard !terms.isEmpty else { return sections }
        return sections.compactMap { section in
            let items = section.items.filter {
                matches($0.source, terms: terms, displayTitle: $0.displayTitle)
            }
            guard !items.isEmpty else { return nil }
            return MobileSourceGroupSection(
                id: section.id,
                title: section.title,
                systemImage: section.systemImage,
                items: items
            )
        }
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
