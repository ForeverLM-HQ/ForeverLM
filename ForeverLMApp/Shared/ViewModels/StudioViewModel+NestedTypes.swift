// The nested value types the studio view model passes between its imports, merges and syncs.

import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

extension StudioViewModel {

    struct PendingDeletionNotice: Identifiable, Equatable {
        let id: UUID
        let message: String
        /// The window the removal was made in, which alone shows its banner.
        var windowID: UUID? = nil
    }

    struct ArtworkBackfillCandidate: Sendable {
        let id: String
        let url: URL
    }

    struct ArtworkBackfillResult: Sendable {
        let id: String
        let artworkURL: String
    }

    struct ReadingListImportReport: Sendable {
        let scannedCount: Int
        let candidateCount: Int
        let insertedCount: Int
        let promotedCount: Int
        let scannedByOrigin: String
        let scannedOriginLabel: String
        let candidatesByType: String
        let insertedByType: String
    }

    struct ReadingListAutoSyncInput: @unchecked Sendable {
        let request: BrowserReadingListWorkerRequest
        let articles: [StudioArticle]
        let storage: StorageService
        let shouldStopSafariFolderAccess: Bool
    }

    /// Main-actor snapshot for reading-list auto-sync. Excludes the resolved Safari
    /// security-scoped bookmark, which is resolved off the main actor (file I/O / TCC).
    struct ReadingListAutoSyncBase: @unchecked Sendable {
        let safariEnabled: Bool
        let chromeEnabled: Bool
        let braveEnabled: Bool
        let homeDir: String
        let articles: [StudioArticle]
        let storage: StorageService
    }

    struct ReadingListAutoSyncPersistenceResult: @unchecked Sendable {
        let changedIDs: Set<String>
        let promotedIDs: Set<String>
        let scannedSources: [StudioArticle]
        let candidateSources: [StudioArticle]
        let insertedSources: [StudioArticle]
        let warnings: [String]
    }

    struct LocalPDFAttachmentPlan: @unchecked Sendable {
        let sourcePath: String
        let destinationPath: String
        let doi: String?
    }

    struct AttachedTextFileResult: @unchecked Sendable {
        let attachedPath: String
        let relativePath: String
        let text: String
        let wordCount: Int
    }

    struct BrowserReadingListScanResult: @unchecked Sendable {
        let articles: [StudioArticle]
        let warnings: [String]
    }

    struct BrowserReadingListWorkerRequest: Codable, Sendable {
        let homeDir: String
        let safariEnabled: Bool
        let chromeEnabled: Bool
        let braveEnabled: Bool
        let safariFolderPath: String?
    }

    struct BrowserReadingListWorkerResponse: Codable {
        let articles: [StudioArticle]
        let warnings: [String]
    }

    struct PodcastDiscoveryFileSnapshot: @unchecked Sendable {
        let dbPath: String
        let episodeMetadata: [PodcastEpisodeMetadata]
        let status: PodcastDiscoveryStatus
        let databaseExists: Bool
    }

    struct PodcastLibraryFileFingerprint: Equatable, Sendable {
        let modifiedAt: Date
        let size: UInt64
    }

    struct PodcastAutoSyncPersistenceResult: @unchecked Sendable {
        let insertedIDs: Set<String>
        let insertedSources: [StudioArticle]
    }

    struct PodcastAutoSyncBase: @unchecked Sendable {
        let storage: StorageService
        let previousArticles: [StudioArticle]
    }

    struct PodcastTranscriptHydrationCandidate: Sendable {
        let id: String
        let url: String
        let title: String
        let podcastName: String
        let webPageURL: String?
        /// The learner chose YouTube as this show's transcript source. Identity
        /// still requires confirmation; this only skips a known-useless Apple call.
        let prefersYouTube: Bool
        /// Episodes on a hidden show (or hidden individually) still get their
        /// transcript downloaded so search keeps working, but they skip the
        /// billed formatting pass — nobody is reading them.
        let allowsFormatting: Bool
        /// The learner asked for this episode's transcript, so its formatting
        /// goes ahead of the queue (`PodcastTranscriptFormattingRequest`).
        var userInitiated = false
    }

    /// The public Apple Podcasts identity hydration gave a row that had none:
    /// what the in-memory article must now say about itself so a later save
    /// does not write the old address back over the durable one.
    struct PodcastResolvedEpisodeIdentity: Sendable, Equatable {
        let url: String
        let webPageURL: String?
    }

    struct PodcastTranscriptHydrationResult: Sendable {
        enum Outcome: Sendable {
            case ready(content: String, persistedReadyState: Bool)
            case failed(message: String)
        }

        let id: String
        let outcome: Outcome
        /// Set when hydration moved the row onto a public episode identity.
        let resolvedIdentity: PodcastResolvedEpisodeIdentity?
        /// Set when the row resolved to an identity another row already holds
        /// and was archived into it; the surviving row's id.
        let mergedIntoSourceID: String?

        init(
            id: String,
            outcome: Outcome,
            resolvedIdentity: PodcastResolvedEpisodeIdentity? = nil,
            mergedIntoSourceID: String? = nil
        ) {
            self.id = id
            self.outcome = outcome
            self.resolvedIdentity = resolvedIdentity
            self.mergedIntoSourceID = mergedIntoSourceID
        }
    }

    enum PodcastTranscriptFetchOutcome: Sendable, Equatable {
        case available(String)
        /// Apple knows the episode but does not expose a transcript to this
        /// account. Paid/private feeds and publisher-disabled episodes commonly
        /// land here; retrying the same catalog request cannot change access.
        case unavailable
        /// Transport, authentication-helper, or server failure. These remain
        /// retryable because Apple may expose the same transcript later.
        case failed
    }

    enum PodcastTranscriptHTTPDisposition: Equatable {
        case success
        case authenticationExpired
        case unavailable
        case failed
    }

    struct ImportedBookFile: Sendable {
        /// The book the file already is, or nil for a new book (`BookFilePlacement`).
        let bookID: String?
        let baseName: String
        let bookDir: String
        let destPath: String
        let chaptersDir: String
        let importedTitle: String?
        let importedSubtitle: String?
        let importedAuthor: String?
        let importedEdition: String?
    }

    struct KindleConversionResult: Sendable {
        let epubPath: String
        let tempDir: String
    }

    struct BookChapterImportDraft: Sendable {
        let path: String
        let title: String
        let sortIndex: Int
        let plainText: String
        let wordCount: Int
        /// A PDF book's chapter: its pages of the book's file, which `path`
        /// names. Nil for an EPUB chapter, whose file is the chapter.
        var pages: Range<Int>? = nil
    }

    struct PDFBookSnapshot: Sendable {
        let pageCount: Int
        let outlineEntries: [PDFOutlineChapterEntry]
        let tocEntries: [PDFTOCChapterEntry]
        let detectedChapterEntries: [PDFOutlineChapterEntry]
        let pageEntries: [PDFPageChapterEntry]
        let frontMatterPages: [PDFPageChapterEntry]
    }

    struct PDFPageChapterEntry: Sendable {
        let pageIndex: Int
        let text: String
    }

    struct PDFTOCChapterEntry: Sendable {
        let title: String
        let printedPage: Int?
        let text: String
    }

    final class BookImportProgress: @unchecked Sendable {
        weak var viewModel: StudioViewModel?
        /// The book being finished in the background, whose row the line
        /// goes to (`finishingBookStatus`); nil for the import the learner
        /// waits on under Add Book.
        let bookID: String?

        init(_ viewModel: StudioViewModel, bookID: String? = nil) {
            self.viewModel = viewModel
            self.bookID = bookID
        }

        func update(_ message: String) {
            Task { @MainActor in
                guard let viewModel = self.viewModel else { return }
                if let bookID = self.bookID {
                    // A line that arrives after the book finished is dropped.
                    guard viewModel.finishingBookStatus[bookID] != nil else { return }
                    viewModel.finishingBookStatus[bookID] = message
                } else {
                    viewModel.bookImportStatus = message
                }
            }
        }
    }

    struct CourseMaterialOrdinal: Hashable {
        let kind: String
        let major: Int
        let detail: String?
    }

    struct ParsedMeetingArtifact: Sendable {
        let url: URL
        let title: String
        let sessionKey: String
        let kind: MeetingArtifactKind
        let text: String?
        let externalURL: String?
        let localFilePath: String?
        let mimeType: String?
        let modifiedAt: Date?
    }

}
