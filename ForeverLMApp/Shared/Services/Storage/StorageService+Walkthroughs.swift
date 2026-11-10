// StorageService: walkthroughs, their progress and animation walkthroughs.
import Foundation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif

extension StorageService {

    // MARK: Walkthroughs

    /// The paper's walkthrough, when it has one for its current text.
    func loadPaperWalkthrough(_ sourceID: String) throws -> PaperWalkthrough? {
        try ensureStoreExists()
        return try knowledgeStore().loadPaperWalkthrough(sourceID)
    }

    /// Every source's walkthrough as `list_walkthroughs` lists it, newest
    /// first (`PaperWalkthroughSummary`).
    func paperWalkthroughSummaries() throws -> [PaperWalkthroughSummary] {
        try ensureStoreExists()
        return try knowledgeStore().paperWalkthroughSummaries()
    }

    /// The walkthroughs of `sourceIDs` alone, newest first: a notebook's
    /// Studio lists its own sources' walks without decoding the library's.
    func paperWalkthroughSummaries(forSources sourceIDs: [String]) throws -> [PaperWalkthroughSummary] {
        try ensureStoreExists()
        return try knowledgeStore().paperWalkthroughSummaries(forSources: sourceIDs)
    }

    /// Whether the paper has any walkthrough row, current or stale.
    func hasPaperWalkthrough(_ sourceID: String) throws -> Bool {
        try ensureStoreExists()
        return try knowledgeStore().hasPaperWalkthroughRow(sourceID)
    }

    /// `ok` or `stale` for each of the ids that has a walkthrough row; absent
    /// for the rest. One query for a Planner day or a `get_day_plan` answer.
    func paperWalkthroughStatuses(for sourceIDs: some Collection<String>) throws -> [String: PaperWalkthroughStatus] {
        try ensureStoreExists()
        return try knowledgeStore().paperWalkthroughStatuses(for: sourceIDs)
    }

    func savePaperWalkthrough(_ walkthrough: PaperWalkthrough) throws {
        try ensureStoreExists()
        try knowledgeStore().savePaperWalkthrough(walkthrough)
        scheduleCloudKitSync(.coalesced)
    }

    @discardableResult
    func deletePaperWalkthrough(_ sourceID: String) throws -> Bool {
        try ensureStoreExists()
        let removed = try knowledgeStore().deletePaperWalkthrough(sourceID)
        if removed { scheduleCloudKitSync(.coalesced) }
        return removed
    }

    // MARK: Walkthrough progress

    /// Where the learner is in the walk of `subjectID` (a source or an
    /// animation), and how its questions went.
    func loadWalkthroughProgress(_ subjectID: String) throws -> WalkthroughProgress? {
        try ensureStoreExists()
        return try knowledgeStore().loadWalkthroughProgress(subjectID)
    }

    func saveWalkthroughProgress(_ progress: WalkthroughProgress) throws {
        try ensureStoreExists()
        try knowledgeStore().saveWalkthroughProgress(progress)
        scheduleCloudKitSync(.coalesced)
    }

    /// A graded question about a source — a walkthrough's or a course
    /// quiz's — as a Memory attempt, a miss keeping its card
    /// (`KnowledgeStore.recordSourceQuestionAttempt`).
    func recordSourceQuestionAttempt(
        _ question: SourceMemoryQuestion,
        answer: String,
        feedback: String,
        score: Double,
        rating: MemoryScheduleRating
    ) throws {
        try ensureStoreExists()
        try knowledgeStore().recordSourceQuestionAttempt(
            question,
            answer: answer,
            feedback: feedback,
            score: score,
            rating: rating
        )
        scheduleCloudKitSync(.soon)
    }

    // MARK: Animation walkthroughs

    /// The animation's walkthrough, when it has one for its current address.
    func loadArtifactWalkthrough(_ artifactID: String) throws -> PaperWalkthrough? {
        try ensureStoreExists()
        return try knowledgeStore().loadArtifactWalkthrough(artifactID)
    }

    /// Whether the animation has any walkthrough row, current or stale.
    func hasArtifactWalkthrough(_ artifactID: String) throws -> Bool {
        try ensureStoreExists()
        return try knowledgeStore().hasArtifactWalkthroughRow(artifactID)
    }

    /// Every artifact with a walkthrough row, for the Animations list.
    func artifactIDsWithWalkthroughs() throws -> Set<String> {
        try ensureStoreExists()
        return try knowledgeStore().artifactIDsWithWalkthroughs()
    }

    func saveArtifactWalkthrough(_ walkthrough: PaperWalkthrough) throws {
        try ensureStoreExists()
        try knowledgeStore().saveArtifactWalkthrough(walkthrough)
        scheduleCloudKitSync(.coalesced)
    }

    @discardableResult
    func deleteArtifactWalkthrough(_ artifactID: String) throws -> Bool {
        try ensureStoreExists()
        let removed = try knowledgeStore().deleteArtifactWalkthrough(artifactID)
        if removed { scheduleCloudKitSync(.coalesced) }
        return removed
    }

    /// One artifact by id, or nil.
    func loadArtifact(_ artifactID: String) throws -> ArtifactRecord? {
        try ensureStoreExists()
        return try knowledgeStore().loadArtifact(artifactID)
    }

    func sourceReviewGuideFailure(_ sourceID: String) throws -> String? {
        try ensureStoreExists()
        return try knowledgeStore().sourceReviewGuideFailure(sourceID: sourceID)
    }

    /// Stored content length per source, without materializing the text or
    /// deriving anything from local files.
    ///
    /// Deliberately does not fall back to `deriveLocalSourceContent` the way
    /// `loadSourceContent` does: the callers here are sizing a catalog, not
    /// reading it, and per-source PDF extraction or Vision OCR across a whole
    /// notebook pool is exactly the blocking work this is meant to replace.
    func sourceContentLengths(for sourceIDs: [String]) -> [String: Int] {
        guard let ks = try? knowledgeStore() else { return [:] }
        return (try? ks.sourceContentLengths(for: sourceIDs)) ?? [:]
    }

    /// A book's display title by group id, for the Now Playing subtitle and
    /// the synced audio manifest. Nil when the store has no title for it.
    func bookTitle(forGroupID groupID: String) -> String? {
        guard let ks = try? knowledgeStore() else { return nil }
        return (try? ks.bookTitle(forGroupID: groupID)) ?? nil
    }

    /// Search persisted source text without deriving missing local-file content.
    /// Used by explicit All-tab searches so cached book chapter text can match
    /// even when it is not loaded into `StudioArticle.content`.
    func searchSourceContent(query: String, maxResults: Int = 300) -> [String: Float] {
        guard let ks = try? knowledgeStore() else { return [:] }
        guard let excludedSources = try? ks.knowledgeSearchExcludedSourceIDs() else { return [:] }
        return (try? ks.searchSourceContent(
            query: query,
            maxResults: maxResults,
            excludedSources: excludedSources
        )) ?? [:]
    }

    func clearSourceDerivedData(_ sourceId: String) {
        guard let ks = try? knowledgeStore() else { return }
        try? ks.clearSourceDerivedData(sourceId)
    }

    private static let derivationLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
        category: "Performance"
    )

    /// Text for a source whose only copy is a local file. Static and
    /// nonisolated so `loadSourceContent` can run it off the storage actor:
    /// a whole-book PDF extraction is seconds of CPU that must not hold the
    /// lane every read shares.
    nonisolated static func deriveLocalSourceContent(for article: StudioArticle) -> String? {
        let candidatePath = article.localFilePath ?? article.url
        guard !candidatePath.hasPrefix("http://"), !candidatePath.hasPrefix("https://"),
              let resolvedURL = SourceService.resolveLocalFileURL(candidatePath) else {
            return nil
        }
        let path = resolvedURL.path
        let ext = resolvedURL.pathExtension.lowercased()
        // A chapter of an EPUB book kept as one file is an entry of it, not a file.
        if ["html", "htm", "xhtml"].contains(ext), EPUBBookFiles.location(ofPath: path) != nil {
            guard let raw = EPUBBookFiles.text(atPath: path) else { return nil }
            let text = EPUBParser.stripHTML(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        guard ensureICloudFileDownloaded(at: resolvedURL, fileManager: .default) else { return nil }

        do {
            switch ext {
            case "pdf":
                #if canImport(PDFKit)
                guard let document = PDFDocument(url: resolvedURL) else { return nil }
                // A book chapter's text is its pages of the book's file.
                let pages = article.bookPages ?? 0..<document.pageCount
                guard pages.upperBound <= document.pageCount else { return nil }
                let text = PDFTextExtractor.textWithFigureReferences(from: document, pages: pages)
                return text.isEmpty ? nil : text
                #else
                return nil
                #endif
            case "ttml":
                let raw = try String(contentsOf: resolvedURL, encoding: .utf8)
                return try? SourceService.extractTextFromTTMLContent(raw)
            case "html", "htm", "xhtml":
                let raw = try String(contentsOf: resolvedURL, encoding: .utf8)
                return EPUBParser.stripHTML(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            default:
                let raw = try String(contentsOf: resolvedURL, encoding: .utf8)
                let trimmed = raw.removingSoftHyphens().trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        } catch {
            derivationLogger.error("Failed to derive source content from \(path, privacy: .public): \(error.localizedDescription)")
            return nil
        }
    }

}
