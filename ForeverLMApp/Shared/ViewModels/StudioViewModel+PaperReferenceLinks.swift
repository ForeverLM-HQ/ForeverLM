import Foundation
import OSLog

private let paperReferenceLinksLogger = Logger(subsystem: "com.foreverlm", category: "PaperReferenceLinks")

extension Notification.Name {
    /// A paper's stored reference list changed (read, linked, or saved by an assistant). The
    /// notification's object is the source id (a `String`).
    static let paperReferencesDidChange = Notification.Name("ForeverLM.paperReferencesDidChange")
}

/// A paper's reference list, read and linked at ingest (schema 174).
///
/// `PaperReferenceLinkService` does the work; this is what the app, the citation popover and the
/// "Find Cited Papers" read go through. Nothing here calls a model.
extension StudioViewModel {

    // MARK: Ingest and backfill

    /// Reads and links the references of the papers owed it (a paper just added, a library
    /// from before schema 174), newest first. Event-driven: it runs where the other deferred
    /// source work does (`runCanonicalContentCleanup`), at `.utility`, off the main actor, and
    /// a failure leaves the paper readable and the rest of the queue to the next trigger.
    func runPaperReferenceLinking() async {
        _ = await paperReferenceLinkService.drain()
    }

    /// Reads one paper's reference list and finds each entry's link, with the free catalogs and
    /// no model. The entry point for a backfill (any paper, as often as asked) and for an
    /// assistant (`resolve_paper_references`). A paper already read and answered is returned as
    /// it stands; `force` reads its PDF again and keeps what the catalogs already said.
    @discardableResult
    func resolveReferenceLinks(forSource sourceID: String, force: Bool = false) async throws -> PaperReferenceLinkService.Outcome {
        let outcome = try await paperReferenceLinkService.resolve(sourceID: sourceID, force: force)
        NotificationCenter.default.post(name: .paperReferencesDidChange, object: sourceID)
        return outcome
    }

    // MARK: The seam the citation popover reads a link through

    /// A paper's stored reference list, as a snapshot to query synchronously: the entry and the
    /// link of citation number 12, of "5–7", of "Smith et al., 2019", or of the entry text the
    /// PDF's own link landed on. Empty (never nil) when the paper has no list yet, so a caller
    /// need not tell "not read" from "no entries": both show nothing.
    func paperReferenceIndex(forSource sourceID: String) async -> PaperReferenceIndex {
        do {
            return try await storage.paperReferenceIndex(sourceID: sourceID)
        } catch {
            paperReferenceLinksLogger.error(
                "Could not read the references of \(sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return .empty(sourceID: sourceID)
        }
    }

    /// The link of citation number `number` in `sourceID`, nil when the list has no such entry
    /// or the entry names no paper.
    func referenceLink(forNumber number: Int, inSource sourceID: String) async -> URL? {
        await paperReferenceIndex(forSource: sourceID).link(forNumber: number)
    }

    /// The link of the entry whose text is `text`, as the popover read it off the PDF.
    func referenceLink(forEntryText text: String, inSource sourceID: String) async -> URL? {
        await paperReferenceIndex(forSource: sourceID).link(forEntryText: text)
    }

    /// The library source each linked entry of `index` already is, by entry number: the paper's
    /// DOI or address matched to the library's active sources, read fresh because a source can
    /// be added or removed after the list was made, which is why the id is not stored with it.
    func referenceLibrarySourceIDs(in index: PaperReferenceIndex) async -> [Int: String] {
        let addresses = index.references.compactMap(\.url)
        guard !addresses.isEmpty else { return [:] }
        let matches = await storage.librarySourceIDs(forReferenceURLs: addresses)
        var byNumber: [Int: String] = [:]
        for reference in index.references {
            if let url = reference.url, let id = matches[url] { byNumber[reference.ordinal] = id }
        }
        return byNumber
    }

    // MARK: Find Cited Papers

    /// What the stored list gives "Find Cited Papers": a candidate for every entry that names a
    /// paper, with its address already on it, and the text of the entries that name none (for
    /// the model pass, which the learner asked for by pressing Find Cited Papers).
    struct StoredReferenceRead {
        var candidates: [VideoCitedPaper]
        /// The unlinked entries' text, one per line; nil when every entry is linked or there
        /// are none.
        var unlinkedText: String?
        var entryCount: Int
    }

    /// Reads (free: no model) the paper's references, then turns the linked ones into
    /// candidates through the existing candidate model, so adding one is the same click and the
    /// same import it always was, now through a link that was found rather than asked of a
    /// model. A failed read leaves `entryCount` 0, and the caller reads the whole list with the
    /// model as it always did.
    func readCitedPapersFromStoredReferences(for article: StudioArticle) async -> StoredReferenceRead {
        do {
            try await resolveReferenceLinks(forSource: article.id)
        } catch {
            paperReferenceLinksLogger.error(
                "Reading the references of \(article.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        let stored = (try? await storage.loadPaperReferences(sourceID: article.id)) ?? []
        return Self.citedPaperCandidates(from: stored, sourceID: article.id)
    }

    /// Pure: candidates for the linked entries, and the text of the rest.
    nonisolated static func citedPaperCandidates(from references: [PaperReference], sourceID: String) -> StoredReferenceRead {
        var candidates: [VideoCitedPaper] = []
        var unlinked: [String] = []
        for reference in references {
            guard let address = reference.url, reference.isLinked else {
                unlinked.append(reference.text)
                continue
            }
            candidates.append(VideoCitedPaper(
                sourceID: sourceID,
                // The record's title when a catalog gave one; otherwise the entry as printed,
                // which still says what the paper is.
                title: reference.title ?? String(reference.text.prefix(160)),
                authors: reference.authors,
                year: reference.year,
                journal: reference.journal,
                doi: reference.doi,
                url: address,
                status: .pending,
                kind: .paper
            ))
        }
        return StoredReferenceRead(
            candidates: candidates,
            unlinkedText: unlinked.isEmpty ? nil : unlinked.joined(separator: "\n"),
            entryCount: references.count
        )
    }
}
