import Foundation
import OSLog

private let linkedSourcesLogger = Logger(subsystem: "com.foreverlm", category: "LinkedSources")

/// The sources an article links to, read from its archived page and offered for import.
///
/// The same candidate rows and the same Add / Dismiss / Restore decisions as the papers read
/// off a video's slides and a paper's reference list (`StudioViewModel+SlideCitations`,
/// `+PaperReferences`): one row per link the article uses as a source, typed off its URL,
/// marked as already held when the library has it, and never imported without the learner's
/// click. Opt-in per article, because reading the links is a model call over the whole
/// piece, which is not worth paying for on an article no one asks about.
extension StudioViewModel {

    /// Whether this source has links to read: any web page held as an article. Papers read
    /// their reference list instead, and a video, podcast or meeting has no page of links.
    nonisolated static func supportsLinkDiscovery(_ article: StudioArticle) -> Bool {
        guard [.article, .manual, .unclassified].contains(article.sourceType) else { return false }
        let lower = article.url.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    /// Whether the reader's cited-sources panel has anything to read for this source, whichever
    /// of the two reads applies.
    nonisolated static func supportsCitedSourceDiscovery(_ article: StudioArticle) -> Bool {
        supportsReferenceExtraction(article) || supportsLinkDiscovery(article)
    }

    /// "Find Linked Sources" from the article reader's overflow menu, the panel it opens, or
    /// the sidebar's context menu.
    ///
    /// Reads the links off the archived reader document rather than the stored text: the text
    /// is plain, and its links were the first thing the HTML-to-text pass dropped. An article
    /// with no archive yet — added by a plugin with its text, or archived before the app kept
    /// pages — is fetched and archived first, which is the same refetch the reader offers.
    /// Existing candidate rows are left alone — their status is a decision already made — so a
    /// rescan only adds.
    ///
    /// Progress and the outcome go to `citedPaperScanReports` for the panel to show. With
    /// `reportsInline` false — the sidebar's context menu, where no panel is open — the same
    /// words are also shown as a toast, naming the article since nothing else on screen does.
    func discoverLinkedSources(for sourceID: String, reportsInline: Bool = false) async {
        guard let article = articles.first(where: { $0.id == sourceID }) else { return }

        func report(_ phase: CitedPaperScanReport.Phase, _ message: String, toast: String? = nil) {
            citedPaperScanReports[sourceID] = CitedPaperScanReport(phase: phase, message: message)
            if !reportsInline { showToast(toast ?? message) }
        }

        guard Self.supportsLinkDiscovery(article) else {
            report(.failed, "Linked sources can only be read from a web article.")
            return
        }
        guard let config = KeychainService.resolveConfig(for: .articleLinkDiscovery) else {
            report(
                .failed,
                KeychainService.backgroundAIUnavailableMessage(for: .articleLinkDiscovery)
                    ?? "Article Link Discovery is not configured."
            )
            return
        }

        report(.running, "Reading the links…", toast: "Reading the links in \(article.title)…")

        let html: String
        do {
            guard let page = try await Self.archivedPageHTML(for: article) else {
                report(
                    .failed,
                    "This article has no saved page to read links from.",
                    toast: "\(article.title) has no saved page to read links from."
                )
                return
            }
            html = page
        } catch {
            report(.failed, "Couldn't fetch the article's page: \(error.localizedDescription)")
            return
        }

        let pageURL = URL(string: article.url)
        let reading = await Task.detached(priority: .userInitiated) {
            ArticleLinkDiscoveryService.read(html: html, pageURL: pageURL)
        }.value
        guard !reading.links.isEmpty else {
            report(
                .finished,
                "This article links to nothing outside itself.",
                toast: "\(article.title) links to nothing outside itself."
            )
            return
        }

        let existing = (try? await storage.loadVideoCitedPapers(forSourceID: sourceID)) ?? []
        let existingKeys = Set(existing.map(\.dedupKey))

        do {
            let picks = try await AIUsageAttribution.withSource(AIUsageSource(source: article)) {
                var picks: [ArticleLinkDiscoveryService.Pick] = []
                for chunk in ArticleLinkDiscoveryService.chunks(of: reading) {
                    picks += try await aiService.discoverArticleLinkedSources(
                        articleTitle: article.title,
                        markedText: chunk,
                        linkIndex: reading.linkIndex,
                        config: config
                    )
                }
                return picks
            }
            let candidates = ArticleLinkDiscoveryService.candidates(
                from: picks, reading: reading, sourceID: sourceID
            )
            linkedSourcesLogger.info(
                "Read \(candidates.count) linked source(s) from \(reading.links.count) link(s) in \(sourceID, privacy: .public)"
            )

            // Existing rows are decisions already made; a rescan must not put back what was
            // imported or waved off.
            var added = 0
            var alreadyHeld = 0
            for candidate in candidates where !existingKeys.contains(candidate.dedupKey) {
                let stamped = markingIfAlreadyInLibrary(candidate)
                if stamped.status == .imported {
                    alreadyHeld += 1
                } else {
                    added += 1
                }
                try await storage.saveVideoCitedPaper(stamped)
            }
            noteCitedPapersChanged()

            if added == 0 && alreadyHeld == 0 {
                if candidates.isEmpty {
                    report(
                        .finished,
                        "None of this article's \(reading.links.count) links is used as a source.",
                        toast: "None of \(article.title)'s links is used as a source."
                    )
                } else {
                    report(
                        .finished,
                        "No new sources — the links were already read.",
                        toast: "No new sources — \(article.title)'s links were already read."
                    )
                }
            } else {
                var parts: [String] = []
                if added > 0 { parts.append("\(added) linked source\(added == 1 ? "" : "s")") }
                if alreadyHeld > 0 { parts.append("\(alreadyHeld) already in your library") }
                let summary = parts.joined(separator: ", ")
                report(.finished, "\(summary.prefix(1).uppercased())\(summary.dropFirst()).",
                       toast: "\(article.title): \(summary).")
            }
        } catch {
            // A failed call is a failed read, not evidence that the article links to nothing.
            // Nothing is persisted from a partial run and the real error is surfaced.
            report(.failed, "Couldn't read the links: \(error.localizedDescription)")
        }
    }

    /// The article's archived reader document, fetched and archived first when there is
    /// none. Off the main actor throughout: resolving the path stats an iCloud-backed file,
    /// reading it pulls it down when evicted, and the fetch is a network round trip.
    nonisolated static func archivedPageHTML(for article: StudioArticle) async throws -> String? {
        let stored: String? = await Task.detached(priority: .userInitiated) {
            guard let path = article.resolvedLocalPath, path.lowercased().hasSuffix(".html") else { return nil }
            return try? String(contentsOfFile: path, encoding: .utf8)
        }.value
        if let stored, !stored.isEmpty { return stored }

        let archived = try await SourceService.shared.fetchAndArchiveWebContent(
            url: article.url,
            sourceId: article.id,
            attributionSourceId: article.id
        )
        guard let path = archived.localHTMLPath else { return nil }
        return await Task.detached(priority: .userInitiated) {
            try? String(contentsOfFile: path, encoding: .utf8)
        }.value
    }
}
