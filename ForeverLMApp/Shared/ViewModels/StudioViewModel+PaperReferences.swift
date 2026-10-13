import Foundation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif

private let paperReferencesLogger = Logger(subsystem: "com.foreverlm", category: "PaperReferences")

/// One read of a paper's reference list, as the cited-papers panel reports it: in progress,
/// finished with a count, or failed with the reason.
struct CitedPaperScanReport: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case running
        case finished
        case failed
    }

    var phase: Phase
    var message: String

    var isRunning: Bool { phase == .running }
}

/// The papers a paper cites, read from its reference list and offered for import.
///
/// The same candidate model and the same Add / Dismiss / Restore decisions as the papers
/// read off a video's slides (`StudioViewModel+SlideCitations`): a candidate row per cited
/// paper, resolved to a DOI where the catalogs can, marked as already held when the library
/// has it, and never imported without the learner's click. Opt-in per paper, because a
/// reference list is long and reading it is a model call per chunk plus a catalog lookup
/// per entry, which is not worth paying for on a paper no one asks about.
extension StudioViewModel {

    /// Whether this source has a reference list to read: every paper does.
    nonisolated static func supportsReferenceExtraction(_ article: StudioArticle) -> Bool {
        article.sourceType == .paper
    }

    /// "Find Cited Papers" from the paper reader's overflow menu, the cited-papers panel it
    /// opens, or the sidebar's context menu.
    ///
    /// Reads the reference list off the paper's PDF rather than its stored content: the
    /// content cleanup that prepares a paper for chat and Text to Speech removes bibliography
    /// entries on purpose, so the stored text usually has no references left in it. A paper
    /// without a local PDF falls back to whatever text it has. Existing candidate rows are
    /// left alone — their status is a decision already made — so a rescan only adds.
    ///
    /// Progress and the outcome go to `citedPaperScanReports` for the panel to show. With
    /// `reportsInline` false — the sidebar's context menu, where no panel is open — the same
    /// words are also shown as a toast, naming the paper since nothing else on screen does.
    func extractCitedPapersFromReferences(for sourceID: String, reportsInline: Bool = false) async {
        guard let article = articles.first(where: { $0.id == sourceID }) else { return }

        func report(_ phase: CitedPaperScanReport.Phase, _ message: String, toast: String? = nil) {
            citedPaperScanReports[sourceID] = CitedPaperScanReport(phase: phase, message: message)
            if !reportsInline { showToast(toast ?? message) }
        }

        guard Self.supportsReferenceExtraction(article) else {
            report(.failed, "Cited papers can only be read from a paper's reference list.")
            return
        }
        guard let config = KeychainService.resolveConfig(for: .paperReferenceExtraction) else {
            report(
                .failed,
                KeychainService.backgroundAIUnavailableMessage(for: .paperReferenceExtraction)
                    ?? "Paper Reference Extraction is not configured."
            )
            return
        }

        report(.running, "Reading the references…", toast: "Reading the references in \(article.title)…")

        guard let text = await referenceListText(for: article) else {
            report(
                .failed,
                "This paper has no text to read yet, so there are no references to find.",
                toast: "\(article.title) has no text to read yet, so there are no references to find."
            )
            return
        }
        // Cut to the reference list and chunk it off the main actor: a fifty-page paper is
        // a few hundred kilobytes of text, and the heading search walks every line.
        let (section, chunks) = await Task.detached(priority: .userInitiated) {
            let section = SlideCitationService.referenceSection(of: text)
            return (section, SlideCitationService.materialChunks(
                section, maxCharacters: 16_000, overlapCharacters: 800
            ))
        }.value
        guard !chunks.isEmpty else {
            report(
                .failed,
                "This paper has no text to read yet, so there are no references to find.",
                toast: "\(article.title) has no text to read yet, so there are no references to find."
            )
            return
        }

        let existing = (try? await storage.loadVideoCitedPapers(forSourceID: sourceID)) ?? []
        let existingKeys = Set(existing.map(\.dedupKey))
        // Rows an earlier read could not identify, by title. A rescan that now resolves one
        // — a catalog that has caught up, a better read of the entry — upgrades that row in
        // place rather than leaving the failed row beside the identified one.
        let unresolvedByTitle = Dictionary(
            existing.filter { $0.status == .unresolved }
                .map { ("title:\(VideoCitedPaper.normalizeTitle($0.title))", $0) },
            uniquingKeysWith: { first, _ in first }
        )

        do {
            let candidates = try await AIUsageAttribution.withSource(
                AIUsageSource(source: article)
            ) {
                var citations: [SlideCitationService.ExtractedCitation] = []
                for chunk in chunks {
                    citations += try await aiService.extractPaperReferences(
                        paperTitle: article.title,
                        content: chunk,
                        config: config
                    )
                }
                // Uncapped on purpose, like the lecture and meeting workflows: this is one
                // explicit request to find what one paper cites, and the catalog pass now
                // places title-less entries too, so the web is asked only about the few no
                // catalog holds.
                return await SlideCitationService.shared.resolveExtractedCitations(
                    citations,
                    sourceID: sourceID,
                    sourceText: section,
                    context: "Citing paper: \(article.title)",
                    aiService: aiService,
                    webLookupLimit: nil
                )
            }
            paperReferencesLogger.info(
                "Read \(candidates.count) cited paper(s) from \(chunks.count) chunk(s) of \(sourceID, privacy: .public)"
            )

            // Existing rows are decisions already made; a rescan must not put back what was
            // imported or waved off.
            var added = 0
            var alreadyHeld = 0
            var upgraded = 0
            for candidate in candidates where !existingKeys.contains(candidate.dedupKey) {
                var stamped = markingIfAlreadyInLibrary(candidate)
                if stamped.status != .unresolved,
                   let stale = unresolvedByTitle["title:\(VideoCitedPaper.normalizeTitle(candidate.title))"] {
                    stamped = Self.upgrading(stale, to: stamped)
                    upgraded += 1
                } else if stamped.status == .imported {
                    alreadyHeld += 1
                } else {
                    added += 1
                }
                try await storage.saveVideoCitedPaper(stamped)
            }
            noteCitedPapersChanged()

            if added == 0 && alreadyHeld == 0 && upgraded == 0 {
                if candidates.isEmpty {
                    report(
                        .finished,
                        "No cited papers could be read from the references.",
                        toast: "No cited papers could be read from \(article.title)'s references."
                    )
                } else {
                    report(
                        .finished,
                        "No new papers — the references were already read.",
                        toast: "No new papers — \(article.title)'s references were already read."
                    )
                }
            } else {
                var parts: [String] = []
                if added > 0 { parts.append("\(added) new paper\(added == 1 ? "" : "s")") }
                if upgraded > 0 { parts.append("\(upgraded) now matched") }
                if alreadyHeld > 0 { parts.append("\(alreadyHeld) already in your library") }
                let summary = parts.joined(separator: ", ")
                report(.finished, "\(summary.prefix(1).uppercased())\(summary.dropFirst()).",
                       toast: "\(article.title): \(summary).")
            }
        } catch {
            // A failed chunk is a failed read, not evidence that the paper cites nothing.
            // Nothing is persisted from a partial run and the real error is surfaced.
            report(.failed, "Couldn't read the references: \(error.localizedDescription)")
        }
    }

    /// The stale unresolved row, rewritten with what a later read identified. The row keeps
    /// its id and creation date, so the other Mac sees one candidate change status rather
    /// than a second candidate for the same entry.
    nonisolated static func upgrading(_ stale: VideoCitedPaper, to resolved: VideoCitedPaper) -> VideoCitedPaper {
        VideoCitedPaper(
            id: stale.id,
            sourceID: stale.sourceID,
            title: resolved.title,
            authors: resolved.authors ?? stale.authors,
            year: resolved.year ?? stale.year,
            journal: resolved.journal ?? stale.journal,
            doi: resolved.doi,
            url: resolved.url,
            status: resolved.status,
            importedSourceID: resolved.importedSourceID,
            createdAt: stale.createdAt,
            updatedAt: Date()
        )
    }

    /// The text to read references from: the paper's PDF when it has one, otherwise its
    /// stored content.
    ///
    /// The PDF's embedded text is taken as-is, with no OCR pass — a scanned paper's
    /// references are read from whatever the cleanup left in the stored content instead —
    /// and the whole document is read, not the ingestion page cap: the reference list is at
    /// the end, which is exactly the part a cap drops.
    private func referenceListText(for article: StudioArticle) async -> String? {
        #if canImport(PDFKit)
        let pdfText: String? = await Task.detached(priority: .userInitiated) {
            // Off the main actor on purpose: resolving the path stats an iCloud-backed file
            // and reading the PDF pulls it down when it is evicted.
            guard let document = article.pdfPages?.document() else { return nil }
            let text = PDFTextExtractor.embeddedText(from: document, pages: 0..<document.pageCount)
            return text.isEmpty ? nil : text
        }.value
        if let pdfText { return pdfText }
        #endif
        let stored = await storage.loadSourceContent(article.id)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else { return nil }
        return stored
    }
}
