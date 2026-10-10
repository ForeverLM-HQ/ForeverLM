import CryptoKit
import Foundation
import UIKit

// On-device file cache for synced source content.
//
// Two responsibilities, both under Caches (purgeable by the OS, never backed up):
// - Source text: a disk mirror of the source's text, so a cold launch reads
//   yesterday's sources instantly instead of spinning on a round trip.
//   MobileCloudSourceTextStore owns the fetch policy and calls in here; this
//   actor only moves bytes.
// - Paper PDFs, paper thumbnails, a book's cover, the illustrated reader HTML
//   of a chapter or archived article, and a walk's drawn pictures: each is the
//   source's (or the book's) satellite of that role (docs/cloudkit-schema-design.md
//   §3.5.30, §8b), fetched by name through `MobileSatellites` the first time it
//   is shown and kept on disk by its hash. Nothing is prefetched.
//
// A source the user saved offline keeps its satellites durable, and its PDF and
// reader document a second copy under Application Support
// (MobileOfflineSourceStore), which this actor prefers when one exists.
actor MobileSourceFileStore {
    static let shared = MobileSourceFileStore()

    /// Books whose cover came back empty this launch. Without this, every
    /// scroll past a coverless book asks again. Fetch *errors* are deliberately
    /// not recorded — those should retry.
    private var bookCoversKnownMissing: Set<String> = []
    /// Negative-result cooldown. Unlike book covers, paper thumbnails may
    /// appear shortly after launch when the Mac's one-time republish lands, so
    /// absence is not cached for the whole process lifetime.
    private var paperThumbnailMissingAt: [String: Date] = [:]
    private static let missingPaperThumbnailRetryInterval: TimeInterval = 5 * 60
    /// Sources with no reader document this launch. A text-only book or a
    /// PDF-backed chapter has none, and without this every chapter open would
    /// ask for it again. Fetch *errors* are deliberately not recorded.
    private var readerHTMLKnownMissing: Set<String> = []

    // MARK: - Source text disk cache

    func cachedText(sourceID: String) -> String? {
        // V2 invalidates pre-canonical paper caches from builds where this asset
        // could contain raw PDF extraction rather than ingestion-cleaned text.
        guard let url = try? Self.fileURL(kind: "SourceTextV2", sourceID: sourceID, fileExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }

    func storeText(_ text: String, sourceID: String) {
        guard let url = try? Self.fileURL(kind: "SourceTextV2", sourceID: sourceID, fileExtension: "txt") else { return }
        // Best effort: a failed cache write only costs the next launch a
        // CloudKit fetch, which is exactly where we already were.
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    // MARK: - Paper PDFs

    /// The cached original document, when it has already been pulled down.
    func cachedPDFURL(sourceID: String) -> URL? {
        guard let url = try? Self.fileURL(kind: "SourcePDFs", sourceID: sourceID, fileExtension: "pdf"),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    /// Returns the local PDF: the saved-offline copy, or the source's `pdf`
    /// satellite, downloaded on first use.
    func fetchPDF(sourceID: String, relativePath: String? = nil) async throws -> URL {
        // A saved-offline document comes first: it is the same bytes, in the one
        // directory iOS will not purge out from under the reader.
        if let saved = await MobileOfflineSourceStore.shared.savedPDFURL(sourceID: sourceID) {
            return saved
        }
        guard let satellites = await MobileSatellites.current() else { throw MobileSourceFileError.missingRecord }
        guard let url = try await satelliteURL(sourceID: sourceID, role: "pdf", satellites: satellites) else {
            throw MobileSourceFileError.noPDFAvailable
        }
        return url
    }

    // MARK: - Paper thumbnails

    /// The paper's synced first-page JPEG, its `thumbnail` satellite. This is
    /// intentionally independent from `fetchPDF`: a source list should transfer
    /// kilobytes, not megabytes. nil means there is none to show yet; the row
    /// keeps its citation-card fallback.
    func fetchPaperThumbnail(sourceID: String) async -> UIImage? {
        guard let cacheURL = try? Self.fileURL(
            kind: "PaperThumbnails",
            sourceID: sourceID,
            fileExtension: "jpg"
        ) else {
            return nil
        }
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            return UIImage(contentsOfFile: cacheURL.path)
        }
        if let missingAt = paperThumbnailMissingAt[sourceID],
           Date().timeIntervalSince(missingAt) < Self.missingPaperThumbnailRetryInterval {
            return nil
        }
        guard let satellites = await MobileSatellites.current() else { return nil }
        guard let url = try? await satelliteURL(sourceID: sourceID, role: "thumbnail", satellites: satellites),
              let image = UIImage(contentsOfFile: url.path) else {
            paperThumbnailMissingAt[sourceID] = Date()
            return nil
        }
        paperThumbnailMissingAt.removeValue(forKey: sourceID)
        return image
    }

    // MARK: - Book chapter documents

    /// The chapter document already on this device, if any.
    func cachedReaderHTML(sourceID: String) -> String? {
        guard let url = try? Self.fileURL(kind: "SourceReaderHTMLV1", sourceID: sourceID, fileExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8),
              !html.isEmpty else {
            return nil
        }
        return html
    }

    /// The source's illustrated reader document (its `readerHTML` satellite): an
    /// archived web article or EPUB chapter's own markup with every image
    /// inlined as a `data:` URI. Synced
    /// source text has had `<img>` and `<svg>` stripped out of it, so this is the
    /// only form in which rich-source figures reach the phone.
    ///
    /// nil means there is none — a PDF-backed chapter (which reads its PDF), a
    /// book published by a Mac build that predates chapter documents, or a fetch
    /// that failed — and the reader keeps its plain-text rendering.
    func fetchReaderHTML(sourceID: String) async -> String? {
        // The saved-offline copy first: on a plane it is the only copy, and it is
        // the one iOS cannot purge mid-read.
        if let saved = await MobileOfflineSourceStore.shared.savedReaderHTML(sourceID: sourceID) {
            return saved
        }
        if let cached = cachedReaderHTML(sourceID: sourceID) {
            return cached
        }
        guard !readerHTMLKnownMissing.contains(sourceID) else { return nil }
        guard let satellites = await MobileSatellites.current() else { return nil }
        return await satelliteReaderHTML(sourceID: sourceID, satellites: satellites)
    }

    func storeReaderHTML(_ html: String, sourceID: String) {
        guard let url = try? Self.fileURL(
            kind: "SourceReaderHTMLV1",
            sourceID: sourceID,
            fileExtension: "html"
        ) else {
            return
        }
        // Best effort: a failed cache write only costs the next open a fetch,
        // which is exactly where we already were.
        try? Data(html.utf8).write(to: url, options: .atomic)
    }

    // MARK: - Book covers

    /// The book's synced cover JPEG (the book's Collection's `cover` file),
    /// downloading it on first use like the paper PDFs. nil when there is none
    /// — a book that never had a cover.jpg — and the caller keeps its icon
    /// fallback. `recordName` is the Collection's id.
    func fetchBookCover(recordName: String) async -> UIImage? {
        guard let cacheURL = try? Self.fileURL(kind: "BookCovers", sourceID: recordName, fileExtension: "jpg") else {
            return nil
        }
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            return UIImage(contentsOfFile: cacheURL.path)
        }
        guard !bookCoversKnownMissing.contains(recordName) else { return nil }
        guard let satellites = await MobileSatellites.current() else { return nil }
        guard let cover = try? await satellites.locate(.collection, id: recordName, pick: { MobileSatellites.file(in: $0, map: "files") { $0 == "cover" } }) else {
            bookCoversKnownMissing.insert(recordName)
            return nil
        }
        guard let url = try? await satellites.url(cover) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    // MARK: - Walkthrough pictures

    /// The picture drawn for a walk's step (`MobileWalkthroughDeck.Picture.drawn`):
    /// the walk's `walkthroughPicture` child keyed by the image id. nil while
    /// there is none, and the card then shows none, as the Mac's does.
    func walkthroughPicture(sourceID: String, imageID: String) async -> UIImage? {
        guard let satellites = await MobileSatellites.current(),
              let walk = try? await satellites.source(sourceID, in: "derived", matching: { $0 == "walkthrough" }),
              let picture = walk.child(role: "walkthroughPicture", key: imageID),
              let url = try? await satellites.url(picture) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    // MARK: - Satellites

    /// The local file of a source's satellite of `role`, fetched by name the first time and kept durable
    /// while the source is saved offline; nil when no copy the phone holds names one. A body the Mac
    /// kept to itself (`sync.originals`) or one still arriving says so.
    private func satelliteURL(sourceID: String, role: String, satellites: MobileSatellites) async throws -> URL? {
        guard let satellite = try await satellites.source(sourceID, matching: { $0 == role }) else { return nil }
        let holder = MobileOfflinePins.contains(sourceID) ? MobileSatelliteHolder.source(sourceID) : nil
        do {
            return try await satellites.url(satellite, keepingFor: holder)
        } catch let error as BlobStoreError {
            throw MobileSourceFileError(error)
        }
    }

    /// The source's `readerHTML` satellite as the reader shows it: an HTML document with its images
    /// inlined. A zipped package (§3.5.30) is not one the phone opens yet, so the reader keeps its
    /// plain text.
    private func satelliteReaderHTML(sourceID: String, satellites: MobileSatellites) async -> String? {
        guard let satellite = try? await satellites.source(sourceID, matching: { $0 == "readerHTML" }) else { return nil }
        guard satellite.file.mime?.lowercased() == "text/html" else {
            readerHTMLKnownMissing.insert(sourceID)
            return nil
        }
        let holder = MobileOfflinePins.contains(sourceID) ? MobileSatelliteHolder.source(sourceID) : nil
        guard let data = try? await satellites.data(satellite, keepingFor: holder) else { return nil }
        let html = String(decoding: data, as: UTF8.self)
        return html.isEmpty ? nil : html
    }

    // MARK: - Paths

    private static func fileURL(kind: String, sourceID: String, fileExtension: String) throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = caches.appendingPathComponent("ForeverLM/\(kind)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Hash the id: source ids are URLs and free text, not filesystem-safe.
        let digest = SHA256.hash(data: Data(sourceID.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).\(fileExtension)")
    }
}

enum MobileSourceFileError: LocalizedError {
    case missingRecord
    case noPDFAvailable
    /// The Mac keeps this file to itself (`sync.originals`, D38).
    case keptOnMac
    /// The file's satellites have not reached iCloud yet (the seed sends bytes last).
    case arriving

    init(_ error: BlobStoreError) {
        switch error {
        case .heldOnlyBy: self = .keptOnMac
        case .missingParts: self = .arriving
        default: self = .noPDFAvailable
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingRecord:
            return "This source has not synced to iCloud yet."
        case .noPDFAvailable:
            return "The original PDF is unavailable. Open ForeverLM on your Mac to restore the document."
        case .keptOnMac:
            return "This document is kept on your Mac only, by its iCloud storage setting. Read it there, or open its text here."
        case .arriving:
            return "This document is still arriving in iCloud. Try again in a little while."
        }
    }
}
