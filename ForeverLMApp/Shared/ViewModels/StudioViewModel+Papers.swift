import Foundation
import CryptoKit
import Observation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif
import SwiftUI
import AppKit
import SQLite3
import WebKit
import Darwin

extension StudioViewModel {

    // MARK: - Paper Filename

    /// Generate a sensible filename for a paper PDF from its URL.
    /// Available on all platforms (used for deduplication and download paths).
    nonisolated static func paperFilename(from url: String) -> String {
        let lower = url.lowercased()

        // arXiv, bioRxiv, medRxiv — extract DOI and use DOI-based filename
        if let doi = PaperService.extractDOI(from: url) {
            return paperFilenameFromDOI(doi)
        }

        // OpenReview: openreview.net/forum?id=X or openreview.net/pdf?id=X
        if lower.contains("openreview.net") {
            if let comps = URLComponents(string: url),
               let paperId = comps.queryItems?.first(where: { $0.name == "id" })?.value {
                return "openreview_\(paperId).pdf"
            }
        }

        // Direct PDF URL: use the actual filename from the URL path
        if let parsed = URL(string: url), parsed.pathExtension.lowercased() == "pdf" {
            let filename = parsed.lastPathComponent
            if filename.count >= 3 && filename != "/" {
                return filename
            }
        }

        // Fallback: use a sanitized version of the URL path
        let sanitized = url
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ".", with: "_")
            .prefix(60)
        return "\(sanitized).pdf"
    }

    /// Generate a deterministic filename from a DOI (primary naming strategy).
    /// E.g. "10.1038/s41586-025-09429-6" → "10_1038_s41586-025-09429-6.pdf"
    nonisolated static func paperFilenameFromDOI(_ doi: String) -> String {
        let normalized = normalizeDOI(doi)
        let sanitized = normalized
            .replacingOccurrences(of: "/", with: "_")
        return "\(sanitized).pdf"
    }

    /// Preferred filename for a paper: DOI-based when available, URL-based fallback.
    /// Human-readable label for the PDF download source (shown in the progress indicator).
    nonisolated static func pdfSourceLabel(from urlString: String) -> String {
        let lower = urlString.lowercased()
        if lower.contains("arxiv.org") { return "arXiv" }
        if lower.contains("biorxiv.org") { return "bioRxiv" }
        if lower.contains("medrxiv.org") { return "medRxiv" }
        if lower.contains("nature.com") { return "Nature" }
        if lower.contains("cell.com") { return "Cell Press" }
        if lower.contains("science.org") { return "Science" }
        if lower.contains("plos.org") { return "PLOS" }
        if lower.contains("openreview.net") { return "OpenReview" }
        if lower.contains("ncbi.nlm.nih.gov") || lower.contains("pubmed") { return "PubMed" }
        if lower.contains("europepmc.org") { return "EuropePMC" }
        if lower.contains("springer.com") || lower.contains("springerlink") { return "Springer" }
        if lower.contains("wiley.com") { return "Wiley" }
        if lower.contains("acs.org") { return "ACS" }
        if let host = URLComponents(string: urlString)?.host {
            return host.replacingOccurrences(of: "www.", with: "")
        }
        return "publisher"
    }

    nonisolated static func preferredPaperFilename(doi: String?, url: String) -> String {
        if let doi, !doi.isEmpty {
            return paperFilenameFromDOI(doi)
        }
        return paperFilename(from: url)
    }

    /// Publisher-specific stable paper identities for URLs that do not expose a DOI.
    nonisolated static func paperPublisherIdentityKey(for url: String) -> String? {
        if let pii = scienceDirectPII(from: url) {
            return "publisher:sciencedirect:pii:\(pii.lowercased())"
        }

        guard let components = URLComponents(string: url),
              let host = components.host?.lowercased().replacingOccurrences(of: "www.", with: "") else {
            return nil
        }

        if host.hasSuffix("cell.com"),
           let rawPII = cellPressPII(from: components) {
            let pii = rawPII.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !pii.isEmpty {
                return "publisher:cell:pii:\(pii)"
            }
        }

        return nil
    }

    /// ScienceDirect's stable PII appears in both article URLs and Elsevier's
    /// downloaded filename (`1-s2.0-S0167488924001496-main.pdf`). Treating only
    /// the URL form as identity left a Safari-discovered landing page beside an
    /// already-ingested local PDF, where it incorrectly appeared to need a PDF
    /// after every launch.
    nonisolated static func scienceDirectPII(from urlOrPath: String) -> String? {
        let components = URLComponents(string: urlOrPath)
        let host = components?.host?.lowercased()
        if host == "sciencedirect.com" || host?.hasSuffix(".sciencedirect.com") == true {
            let pathParts = (components?.path ?? "")
                .split(separator: "/")
                .map(String.init)
            if let piiIndex = pathParts.firstIndex(where: { $0.lowercased() == "pii" }),
               pathParts.indices.contains(piiIndex + 1) {
                let pii = (pathParts[piiIndex + 1].removingPercentEncoding ?? pathParts[piiIndex + 1])
                    .replacingOccurrences(of: ".pdf", with: "", options: .caseInsensitive)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !pii.isEmpty { return pii }
            }
        }

        let path = components?.path.isEmpty == false ? (components?.path ?? urlOrPath) : urlOrPath
        let filename = (path as NSString).lastPathComponent
        let prefix = "1-s2.0-"
        let suffix = "-main.pdf"
        guard filename.count > prefix.count + suffix.count,
              filename.lowercased().hasPrefix(prefix),
              filename.lowercased().hasSuffix(suffix) else {
            return nil
        }
        let start = filename.index(filename.startIndex, offsetBy: prefix.count)
        let end = filename.index(filename.endIndex, offsetBy: -suffix.count)
        let pii = String(filename[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard pii.count >= 10,
              pii.first?.lowercased() == "s",
              pii.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        return pii
    }

    nonisolated static func cellPressPII(from components: URLComponents) -> String? {
        if let queryPII = components.queryItems?.first(where: { $0.name.lowercased() == "pii" })?.value,
           !queryPII.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return queryPII
        }

        let pathParts = components.path
            .split(separator: "/")
            .map(String.init)
        for marker in ["fulltext", "abstract", "pdf"] {
            guard let markerIndex = pathParts.firstIndex(where: { $0.lowercased() == marker }),
                  pathParts.indices.contains(markerIndex + 1) else { continue }
            let pii = pathParts[markerIndex + 1]
                .removingPercentEncoding?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? pathParts[markerIndex + 1]
            if !pii.isEmpty {
                return pii.replacingOccurrences(of: ".pdf", with: "")
            }
        }
        return nil
    }

    /// Produce an exact comparison key without interpreting title text. Typography
    /// is not identity: a catalog's `H<sub>2</sub>O<sub>2</sub>`, the library's
    /// `H₂O₂` and a PDF's `H2O2` compare equal.
    nonisolated static func normalizedPaperTitle(_ title: String) -> String {
        title.decodingTitleMarkup()
            .precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// Strip version suffixes from a paper filename for dedup comparison.
    /// e.g. "biorxiv_2024_11_04_615786v3.pdf" → "biorxiv_2024_11_04_615786.pdf"
    /// Only a version: a `v` after a letter is part of the name, so the files of two
    /// Oxford papers of 2015 (`10.1093_nar_gkv1344.pdf`, `10.1093_nar_gkv1157.pdf`)
    /// never compare equal.
    nonisolated static func normalizedPaperFilename(_ filename: String) -> String {
        // Strip vN suffix before .pdf: "615786v3.pdf" → "615786.pdf"
        let pattern = #"(?<=[0-9._])v\d+\.pdf$"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let range = NSRange(filename.startIndex..., in: filename)
            return regex.stringByReplacingMatches(in: filename, range: range, withTemplate: ".pdf")
        }
        return filename
    }

    /// Normalize a DOI for dedup comparison: lowercase and strip a preprint's version
    /// (`PaperService.unversionedDOI`).
    /// e.g. "10.1101/2024.11.04.615786v3" → "10.1101/2024.11.04.615786", while
    /// "10.1093/nar/gkv1344" keeps its `v`, the year letter of an Oxford DOI.
    nonisolated static func normalizeDOI(_ doi: String) -> String {
        PaperService.unversionedDOI(doi)
    }

    // MARK: - Paper Version Conflict Detection

    /// Detect biorxiv/medrxiv papers where multiple versions (v1, v2, v3…) are saved.
    /// Returns groups where more than one version of the same DOI base exists.
    static func detectPaperVersionConflicts(
        in articles: [StudioArticle]
    ) -> [(title: String, newerID: String, olderIDs: [String])] {
        let papers = articles.filter { $0.sourceType == .paper }

        // Extract biorxiv base DOI (strips vN suffix): 10.1101/YYYY.MM.DD.NNNNNN
        let doiBasePattern = try? NSRegularExpression(pattern: #"(10\.\d+/\d{4}\.\d{2}\.\d{2}\.\d+)"#)
        func baseDOI(from url: String) -> String? {
            guard let regex = doiBasePattern else { return nil }
            let ns = url as NSString
            guard let match = regex.firstMatch(in: url, range: NSRange(location: 0, length: ns.length)) else { return nil }
            return ns.substring(with: match.range(at: 1)).lowercased()
        }

        // Group papers by base DOI
        var groups: [String: [StudioArticle]] = [:]
        for p in papers {
            if let base = baseDOI(from: p.url) {
                groups[base, default: []].append(p)
            }
        }

        // Extract numeric version from URL (vN suffix, default 1 if absent)
        func version(of article: StudioArticle) -> Int {
            if let m = article.url.range(of: #"v(\d+)"#, options: .regularExpression) {
                let sub = article.url[m]
                return Int(sub.dropFirst()) ?? 1
            }
            return 1
        }

        var conflicts: [(title: String, newerID: String, olderIDs: [String])] = []
        for (_, group) in groups where group.count > 1 {
            let sorted = group.sorted { version(of: $0) > version(of: $1) }
            let newest = sorted[0]
            let olderIDs = sorted.dropFirst().map { $0.id }
            conflicts.append((title: newest.title, newerID: newest.id, olderIDs: olderIDs))
        }
        return conflicts
    }

    /// Keep only the latest version for each paper version conflict.
    /// Removes older entries and persists.
    func fixPaperVersionConflicts() async {
        guard !paperVersionConflicts.isEmpty else { return }

        var idsToRemove = Set<String>()
        for conflict in paperVersionConflicts {
            for oldID in conflict.olderIDs {
                idsToRemove.insert(oldID)
            }
        }

        for id in idsToRemove {
            try? await storage.archiveSource(id)
        }
        articles.removeAll { idsToRemove.contains($0.id) }
        paperVersionConflicts = []
        logger.info("Fixed \(idsToRemove.count) older paper version(s)")
    }

    /// The first group of papers that a deterministic identity key says are the
    /// same record: a shared DOI, a shared published DOI, a publisher item id, an
    /// identical content fingerprint, or an identical resolved title. One group at
    /// a time, because merging folds the losers' keys into the survivor and can
    /// pull a further row into the same group.
    ///
    /// The group is the first paper that matches another, with each candidate
    /// that matches every paper already in the group. Pairwise, because a title key
    /// meets a paper without a DOI from both sides: a DOI-less row titled like
    /// a Primer and like its PrimeView must not fold the two DOIs into one.
    nonisolated static func firstPaperIdentityDuplicateGroup(
        in papers: [StudioArticle]
    ) -> [StudioArticle]? {
        var indexesByKey: [String: [Int]] = [:]
        for (index, paper) in papers.enumerated() {
            for key in paperDedupDisplayKeys(for: paper) {
                indexesByKey[key, default: []].append(index)
            }
        }
        for (index, paper) in papers.enumerated() {
            let candidates = Set(paperDedupLookupKeys(for: paper).flatMap { indexesByKey[$0] ?? [] })
                .subtracting([index])
                .sorted()
            var group = [index]
            for candidate in candidates
            where group.allSatisfy({ paperDedupKeysMatch(papers[$0], papers[candidate]) }) {
                group.append(candidate)
            }
            if group.count > 1 { return group.sorted().map { papers[$0] } }
        }
        return nil
    }

    struct PaperIdentityMergePlan: Sendable {
        let canonicalID: String
        let duplicateIDs: Set<String>
    }

    /// Build one deterministic merge plan from an immutable library snapshot.
    /// The caller runs this off-main because identity grouping grows with the
    /// library; only applying the small returned id set belongs on the UI actor.
    nonisolated static func firstPaperIdentityMergePlan(
        in sources: [StudioArticle]
    ) -> PaperIdentityMergePlan? {
        // One library at a time: a team library lists the learner's own rows
        // beside the team's, and a merge never crosses from one to the other.
        let libraries = Dictionary(grouping: sources.filter { $0.sourceType == .paper }, by: \.teamID)
        if libraries.count > 1 {
            for teamID in libraries.keys.sorted(by: { ($0 ?? "") < ($1 ?? "") }) {
                if let plan = firstPaperIdentityMergePlan(in: libraries[teamID] ?? []) { return plan }
            }
            return nil
        }
        let papers = sources.filter { $0.sourceType == .paper }
        guard papers.count >= 2,
              let group = firstPaperIdentityDuplicateGroup(in: papers),
              let canonical = group.max(by: { paperStorageScore($0) < paperStorageScore($1) }) else {
            return nil
        }
        return PaperIdentityMergePlan(
            canonicalID: canonical.id,
            duplicateIDs: Set(group.lazy.map(\.id).filter { $0 != canonical.id })
        )
    }

    /// Collapse every set of papers that share a deterministic identity key.
    /// This makes no similarity judgment — unlike the model pass it can only act
    /// where an identifier, a content fingerprint, or an exact title already says
    /// two rows are one paper — so it is safe to run without asking first.
    @discardableResult
    func mergeDuplicatePapersByIdentity() async -> Int {
        var removed = 0
        while true {
            let snapshot = articles
            guard let plan = await Task.detached(priority: .utility, operation: {
                Self.firstPaperIdentityMergePlan(in: snapshot)
            }).value else { break }
            let before = articles.count
            _ = await mergeEquivalentPaperDuplicates(
                into: plan.canonicalID,
                knownDuplicateIDs: plan.duplicateIDs
            )
            let collapsed = before - articles.count
            // A group that survives its own merge would repeat forever. Stopping
            // is the safe answer: the model pass still sees these rows.
            guard collapsed > 0 else {
                logger.warning("mergeDuplicatePapersByIdentity: group led by \(plan.canonicalID) did not collapse")
                break
            }
            removed += collapsed
        }
        return removed
    }

    /// Event-driven identity convergence for launch, import completion, and
    /// CloudKit refresh. The list is published first; this repair then runs on the
    /// storage actor and republishes only when it actually removed duplicates.
    @discardableResult
    func convergePaperIdentityDuplicates() async -> Int {
        // First, once a launch: a preprint's published DOI is no identity key
        // (docs/paper-versions.md), and the keys older builds wrote must leave
        // before duplicate resolution can fold the journal version into it.
        if !didRepairPublishedDOIWorkKeys {
            didRepairPublishedDOIWorkKeys = true
            do {
                let removed = try await storage.removePublishedDOIWorkKeys()
                if removed > 0 { logger.info("Took \(removed) published DOI(s) out of preprints' work keys") }
            } catch {
                logger.error("Could not repair preprints' work keys: \(error.localizedDescription)")
            }
        }
        let removed = await mergeDuplicatePapersByIdentity()
        guard removed > 0 else { return 0 }
        await reloadSourceRelationshipsAfterMerge()
        return removed
    }

    /// Re-read the relationships a duplicate merge just moved onto a surviving
    /// source. Every merge hands schedule placements, Notebook membership and
    /// chat links to another id, and the copies this view model is holding still
    /// name the row that was archived.
    func reloadSourceRelationshipsAfterMerge() async {
        do {
            async let refreshedGoals = storage.loadLearningGoals()
            async let refreshedSessionLinks = storage.loadReviewSessionLinks()
            async let refreshedSchedule = storage.loadScheduledSources()
            learningGoals = try await refreshedGoals
            reviewSessionLinks = try await refreshedSessionLinks
            scheduledSources = try await refreshedSchedule
            invalidateFilteredSidebarCache()
        } catch {
            logger.error("Duplicate relationships merged but UI refresh failed: \(error.localizedDescription)")
        }
    }

    /// Run the catalog lookups off the main actor, a few at a time. A library
    /// can hold hundreds of preprints and each lookup walks up to four APIs with
    /// their own timeouts; done one after another the first duplicate review on
    /// such a library would take minutes. The width is deliberately small — these
    /// are free public APIs and this should stay a considerate client.
    nonisolated static func publishedVersionLookups(
        for candidates: [(id: String, url: String, title: String)],
        maxConcurrent: Int = 4
    ) async -> [String: PaperService.PublishedVersionResult] {
        var results: [String: PaperService.PublishedVersionResult] = [:]
        var next = 0
        await withTaskGroup(of: (String, PaperService.PublishedVersionResult?).self) { group in
            func startNext() {
                guard next < candidates.count else { return }
                let candidate = candidates[next]
                next += 1
                group.addTask {
                    let found = await PaperService.findPublishedVersion(
                        url: candidate.url,
                        title: candidate.title
                    )
                    return (candidate.id, found)
                }
            }
            for _ in 0..<Swift.min(maxConcurrent, candidates.count) { startNext() }
            while let (id, found) = await group.next() {
                if let found { results[id] = found }
                startNext()
            }
        }
        return results
    }

    /// Ask the catalogs whether saved preprints have since appeared in a
    /// peer-reviewed venue, and record the journal DOI on the preprint.
    ///
    /// This is what lets a preprint and its published version be recognized as
    /// one work at all: they share no DOI, no publisher path, and — because the
    /// journal typesets the manuscript again — no PDF fingerprint either. Only
    /// the exact title otherwise connects them, and a preprint whose title the
    /// journal reworded has not even that. The venue and year move to the
    /// published record too, so a paper that is no longer a preprint stops
    /// presenting itself as one. Returns how many papers gained a published DOI.
    @discardableResult
    func resolvePublishedVersionsForPreprints(onlyIds: Set<String>? = nil) async -> Int {
        let candidates = articles.filter { article in
            guard article.sourceType == .paper,
                  (article.publishedDOI ?? "").isEmpty,
                  onlyIds?.contains(article.id) ?? true else { return false }
            // A title still showing a filename or a bare domain would send the
            // catalogs' title search after the wrong paper.
            guard !Self.titleNeedsResolution(
                article.title,
                domain: article.domain,
                url: article.url
            ) else { return false }
            return PaperService.isPreprintPaper(url: article.url, journal: article.journal)
        }.map { (id: $0.id, url: $0.url, title: $0.title) }
        guard !candidates.isEmpty else { return 0 }

        let lookups = await Self.publishedVersionLookups(for: candidates)
        guard !lookups.isEmpty else { return 0 }

        var resolved = 0
        for articleId in candidates.map(\.id) {
            guard let published = lookups[articleId],
                  let original = articles.first(where: { $0.id == articleId }) else { continue }

            var candidate = original
            candidate.publishedDOI = published.publishedDOI
            let venueIsStillThePreprintServer = candidate.paperJournalNeedsEnrichment
                || PaperService.isPreprintVenue(candidate.journal ?? "")
            if venueIsStillThePreprintServer {
                candidate.journal = published.journal
                // Venue and year are one fact. Moving the venue forward while
                // leaving the posting year behind would misattribute the paper.
                if let year = published.year, !year.isEmpty {
                    candidate.publishedYear = year
                }
            }

            // Compare-and-swap for the same reason the metadata backfill uses one:
            // these lookups are slow enough for a PDF attachment to land first.
            let patch = PaperMetadataBackfillPatch(original: original, candidate: candidate)
            do {
                guard try await storage.mergePaperMetadataBackfill(patch) != nil else { continue }
            } catch {
                logger.error("Failed to record published version for \(articleId): \(error.localizedDescription)")
                continue
            }
            if let writeIdx = articles.firstIndex(where: { $0.id == articleId }) {
                var current = articles[writeIdx]
                if patch.apply(to: &current) {
                    articles[writeIdx] = current
                }
            }
            resolved += 1
            logger.info("Preprint \(articleId) resolved to published DOI \(published.publishedDOI)")
        }
        return resolved
    }

    /// Resolve the optional preprint-to-publication identity after the required
    /// ingestion pipeline has released its Processing row. Published-version
    /// discovery can walk several public catalogs and consume their full network
    /// timeouts even when the paper's visible metadata is already complete. It
    /// must still happen automatically, but it is not a prerequisite for reading,
    /// searching, listening, or trusting the metadata extracted from the PDF.
    func resolvePublishedVersionIdentityAfterIngestion(for articleId: String) async {
        guard publishedVersionResolutionInFlight.insert(articleId).inserted else { return }
        defer { publishedVersionResolutionInFlight.remove(articleId) }

        guard let article = articles.first(where: { $0.id == articleId }),
              PaperService.isPreprintPaper(url: article.url, journal: article.journal),
              (article.publishedDOI ?? "").isEmpty else { return }

        if await resolvePublishedVersionsForPreprints(onlyIds: [articleId]) > 0 {
            await mergePaperIntoBestEquivalent(articleId)
        }
    }

    /// Manual duplicate check. Resolves published versions of saved preprints,
    /// collapses everything a deterministic identity already settles, then asks
    /// the configured model about the ambiguous titles that remain. Merges
    /// metadata into the best entry and archives the rest. Returns count removed.
    @discardableResult
    func checkForDuplicates() async -> Int {
        guard articles.filter({ $0.sourceType == .paper }).count >= 2 else { return 0 }

        let resolvedPreprints = await resolvePublishedVersionsForPreprints()
        if resolvedPreprints > 0 {
            logger.info("checkForDuplicates: \(resolvedPreprints) preprint(s) matched a published version")
        }

        var removed = await mergeDuplicatePapersByIdentity()

        // Identified by source id, not by position: the merge above and the model
        // round-trip below both suspend, and `articles` can be reordered while
        // they do.
        let papers = articles
            .filter { $0.sourceType == .paper }
            .map { (id: $0.id, title: $0.title, url: $0.url) }
        var groups: [[Int]] = []
        if papers.count >= 2, let config = KeychainService.resolveConfig(for: .duplicateDetection) {
            let input = papers.map { (title: $0.title, url: $0.url) }
            let modelGroups = await aiService.findDuplicatePapers(papers: input, config: config)
            groups = modelGroups.filter { $0.count >= 2 }
        } else if removed == 0 {
            logger.warning("checkForDuplicates: no AI model configured and no deterministic matches found")
            return 0
        }

        guard !groups.isEmpty else {
            logger.info("checkForDuplicates: removed \(removed) duplicate(s) among \(papers.count) papers")
            return removed
        }

        var idsToRemove = Set<String>()
        for group in groups {
            // Map model indices (into the papers-only array) back to live sources
            let groupArticles = group.compactMap { idx -> StudioArticle? in
                guard idx >= 0, idx < papers.count else { return nil }
                let id = papers[idx].id
                return articles.first { $0.id == id }
            }
            guard groupArticles.count >= 2 else { continue }

            // A preprint and its journal version are versions of one work, each
            // kept as its own paper: the model's group is folded one version
            // at a time, never across them.
            let versionKinds = Dictionary(grouping: groupArticles) { Self.paperVersionKind(of: $0) == .preprint }
            for versionGroup in versionKinds.values where versionGroup.count >= 2 {
                // The model reads titles and addresses; two DOIs say two papers
                // (a Primer and its PrimeView share their title), so a group
                // spanning them is left whole rather than guessed apart.
                guard Set(versionGroup.compactMap(Self.paperIdentityDOI(of:))).count <= 1 else { continue }
                let best = versionGroup.max(by: { Self.paperStorageScore($0) < Self.paperStorageScore($1) })!

                if let bestIdx = articles.firstIndex(where: { $0.id == best.id }) {
                    for donor in versionGroup where donor.id != best.id {
                        _ = Self.mergePaperMetadata(from: donor, into: &articles[bestIdx])
                    }
                    _ = Self.finalizeRequiredPaperMetadata(for: &articles[bestIdx])
                }
                for a in versionGroup where a.id != best.id {
                    idsToRemove.insert(a.id)
                }
            }
        }

        for id in idsToRemove {
            try? await storage.archiveSource(id)
        }
        let before = articles.count
        articles.removeAll { idsToRemove.contains($0.id) }
        removed += before - articles.count

        logger.info("checkForDuplicates: identified \(groups.count) model group(s), removed \(removed) duplicate(s)")
        return removed
    }

    @discardableResult
    static func mergePaperMetadata(from donor: StudioArticle, into recipient: inout StudioArticle) -> Bool {
        guard recipient.sourceType == .paper else { return false }

        var changed = false
        if recipient.paperAuthorNeedsEnrichment, let author = donor.normalizedAuthor, author != StudioArticle.unknownPaperAuthor {
            recipient.author = author
            changed = true
        }
        if recipient.paperJournalNeedsEnrichment, let journal = donor.normalizedJournal, journal != StudioArticle.unknownPaperJournal {
            recipient.journal = journal
            changed = true
        }
        if recipient.paperYearNeedsEnrichment, let year = donor.normalizedPublishedYear, year != StudioArticle.unknownPaperYear {
            recipient.publishedYear = year
            changed = true
        }
        if recipient.doi == nil, let doi = donor.doi, !doi.isEmpty {
            recipient.doi = doi
            changed = true
        }
        // The published DOI is what proves a preprint and a journal record are
        // one work. Losing it when the two merge would let a later re-add of the
        // other version look like a different paper again.
        if (recipient.publishedDOI ?? "").isEmpty,
           let publishedDOI = donor.publishedDOI, !publishedDOI.isEmpty {
            recipient.publishedDOI = publishedDOI
            changed = true
        }
        return changed
    }

    nonisolated static func paperStorageScore(_ article: StudioArticle) -> Int {
        var score = 0
        if article.url.hasPrefix("/") {
            score += 20
        } else if article.localFilePath != nil {
            score += 10
        }
        return score + article.paperMetadataCompletenessScore
    }

    /// Set placeholder values for any missing paper metadata fields.
    /// Real metadata is filled asynchronously by `backfillPaperMetadata` (LLM + API).
    @discardableResult
    static func finalizeRequiredPaperMetadata(for article: inout StudioArticle) -> Bool {
        guard article.sourceType == .paper else { return false }
        var changed = false
        if article.paperAuthorNeedsEnrichment {
            article.author = StudioArticle.unknownPaperAuthor
            changed = true
        }
        if article.paperJournalNeedsEnrichment {
            article.journal = StudioArticle.unknownPaperJournal
            changed = true
        }
        if article.paperYearNeedsEnrichment {
            article.publishedYear = StudioArticle.unknownPaperYear
            changed = true
        }
        return changed
    }

    // MARK: - PDF Title Extraction

    #if canImport(PDFKit)
    /// Extract a paper title from a local PDF file's metadata or first-page text.
    /// Returns nil if no usable title is found.
    nonisolated static func extractPDFTitle(from path: String) -> String? {
        guard let trimmed = rawPDFMetadataTitle(from: path) else { return nil }
        return isUsablePDFTitle(trimmed) ? trimmed : nil
    }

    nonisolated static func extractPDFTitleOffMain(from path: String) async -> String? {
        await Task.detached(priority: .utility) {
            extractPDFTitle(from: path)
        }.value
    }

    nonisolated static func rawPDFMetadataTitle(from path: String) -> String? {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)),
              let attrs = doc.documentAttributes,
              let title = attrs[PDFDocumentAttribute.titleAttribute] as? String else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Extract a DOI from a local PDF file by checking metadata and first-page text.
    /// Used for dedup when importing local PDFs — needs immediate (non-async) result.
    nonisolated static func extractDOIFromPDF(at path: String) -> String? {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { return nil }

        if let attrs = doc.documentAttributes {
            for key in [PDFDocumentAttribute.subjectAttribute, PDFDocumentAttribute.keywordsAttribute] {
                if let value = attrs[key] as? String, let doi = extractDOIFromText(value) {
                    return doi
                }
            }
        }

        guard let firstPage = doc.page(at: 0), let text = firstPage.string else { return nil }
        return extractDOIFromText(text)
    }

    /// Find a DOI pattern (10.XXXX/...) in a block of text.
    /// A DOI's own parentheses stay (`PaperService.printedDOIs(in:)`).
    nonisolated static func extractDOIFromText(_ text: String) -> String? {
        PaperService.firstPrintedDOI(in: text)
    }

    #endif

    /// Check if a paper title still needs resolution (is a domain, URL, filename, or derived-from-URL placeholder).
    /// Whether a title is really a URL that was recorded in place of one.
    ///
    /// `URL(string:)` returning a scheme is not that test. It reads the colon in
    /// "PeptiVerse: A unified platform" as the scheme `peptiverse`, so the most
    /// ordinary shape a paper title takes — name, colon, subtitle — counted as
    /// unresolved. That suppressed the exact-title identity key for those papers
    /// and left obvious duplicates sitting next to each other in the library.
    /// Only a real network scheme means the title never got resolved.
    nonisolated static func titleLooksLikeURL(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = URL(string: trimmed)?.scheme?.lowercased() else { return false }
        return ["http", "https", "file", "ftp"].contains(scheme)
    }

    nonisolated static func titleNeedsResolution(_ title: String, domain: String, url: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.caseInsensitiveCompare(domain) == .orderedSame { return true }
        if titleLooksLikeURL(trimmed) { return true }
        if trimmed.lowercased().hasSuffix(".pdf") { return true }
        if ["untitled", "untitled video"].contains(trimmed.lowercased()) { return true }
        // A typesetter's job tag read out of the PDF's Title attribute
        // (`CMET4035_grabs 1..1`) is a placeholder, not the title.
        if titleLooksLikePublisherProductionTag(trimmed) { return true }
        // A publisher bot check answers with its own title ("Just a moment…",
        // "Attention Required!"). It is never the document's title, so a source
        // wearing one still needs resolving — and must not dedup on it either.
        if SourceDiscovery.isSecurityVerificationPage(title: trimmed, visibleText: "", url: url) {
            return true
        }
        // A redirect page's "Redirecting" (Elsevier's linkinghub, for every
        // 10.1016 DOI) or the host's own name is the page's chrome, not the
        // paper's title, so a source wearing one is still unresolved.
        if PaperService.isInterstitialPageTitle(trimmed, url: url) { return true }
        if !trimmed.contains(where: { $0.isWhitespace }),
           trimmed.contains("."),
           let host = URL(string: "https://\(trimmed)")?.host,
           host.caseInsensitiveCompare(trimmed) == .orderedSame {
            return true
        }
        return false
    }

    /// Check if a title looks like a filename rather than a real paper title.
    nonisolated static func titleLooksLikeFilename(_ title: String) -> Bool {
        let lower = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return true }
        if lower.hasSuffix(".pdf") { return true }
        if titleLooksLikeURL(lower) { return true }
        return false
    }

    /// Structural validation only. Semantic validation happens through AI metadata extraction.
    nonisolated static func isUsablePDFTitle(_ title: String) -> Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        let lower = title.lowercased()
        if lower.hasSuffix(".pdf") { return false }
        if titleLooksLikeURL(lower) { return false }
        if titleLooksLikePublisherProductionTag(title) { return false }
        return true
    }

    /// Publishers' typesetting pipelines stamp their own job identifiers into
    /// the PDF `Title` attribute — Cell Press writes `CMET4035_grabs 1..1`,
    /// Elsevier `1-s2.0-S0278584626002848-main`, Word-authored manuscripts
    /// `Microsoft Word - revision3.docx`. None of these is the paper's title,
    /// and a sidebar row wearing one looks like a broken import. Everything a
    /// human would read as a title (`p53 and cancer`, `COVID-19 vaccines: 2
    /// years on`, `NAD+ depletion in skeletal muscle`) stays usable.
    nonisolated static func titleLooksLikePublisherProductionTag(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()

        let authoringToolPrefixes = [
            "microsoft word", "microsoft powerpoint", "word -", "powerpoint -",
            "layout ", "slide ", "pii:", "pii ", "doi:", "1-s2.0-", "s2.0-", "untitled",
        ]
        if authoringToolPrefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        if lower == "print" || lower == "untitled document" { return true }

        let sourceDocumentSuffixes = [".doc", ".docx", ".tex", ".indd", ".qxd", ".dvi", ".ppt", ".pptx", ".fm", ".dot"]
        if sourceDocumentSuffixes.contains(where: { lower.hasSuffix($0) }) { return true }

        // Elsevier page ranges: `grabs 1..1`, `main 1..12`.
        if trimmed.range(of: #"\d+\.\.\d+"#, options: .regularExpression) != nil { return true }

        // A job code — letters immediately followed by digits, glued to the
        // rest of the tag by an underscore — such as `CMET4035_grabs` or
        // `NIHMS1234567_supplement`. Real titles separate words with spaces and
        // never join an alphanumeric code to another token with an underscore.
        if trimmed.range(
            of: #"(^|[\s_-])[A-Za-z]{1,8}\d{2,}[A-Za-z]?_"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        // Short tags with no spaces at all that mix letters and several digits
        // (`cmet4035`, `S0278584626002848`, `nihms-1234567`) are identifiers.
        // `COVID-19` and `H5N1` carry too few digits to be one.
        if !trimmed.contains(where: \.isWhitespace),
           trimmed.filter(\.isNumber).count >= 3,
           trimmed.contains(where: \.isLetter),
           trimmed.count <= 40 {
            return true
        }

        return false
    }

    static let ttmlDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// The real user home directory, not the sandbox container.
    /// In a sandboxed app, NSHomeDirectory() returns the container path
    /// (~/Library/Containers/com.foreverlm/Data/), not the real home.
    /// Use POSIX getpwuid to get the actual user home directory so we can
    /// find Safari bookmarks, Apple Podcasts DB, etc. via security-scoped bookmarks.
    var realHomeDirectory: String {
        if let host = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"], !host.isEmpty {
            return host
        }
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    /// Rewrite an absolute path from a different Mac's home directory to the current user's home.
    /// Handles iCloud-synced files where paths like `/Users/olduser/Library/...` need to
    /// become `/Users/currentuser/Library/...`.
    static func normalizePathForCurrentUser(_ path: String) -> String {
        let currentHome: String = {
            if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
                return String(cString: dir)
            }
            return NSHomeDirectory()
        }()
        guard path.hasPrefix("/Users/") else { return path }
        if path.hasPrefix(currentHome) { return path }
        var slashCount = 0
        var cutIndex = path.startIndex
        for i in path.indices {
            if path[i] == "/" {
                slashCount += 1
                if slashCount == 3 {
                    cutIndex = path.index(after: i)
                    break
                }
            }
        }
        guard slashCount >= 3 else { return path }
        let relativePart = String(path[cutIndex...])
        return (currentHome as NSString).appendingPathComponent(relativePart)
    }


    /// Deterministic guardrail: a source with a paper DOI or a recognized paper
    /// URL (arXiv, bioRxiv, direct PDF, DOI) is a scholarly paper regardless of
    /// what a classifier proposed. These are ground-truth identifiers, not fuzzy
    /// title guesses — title-based inference is left to the LLM classifier.
    nonisolated static func looksLikeScholarlyPaper(url: String) -> Bool {
        if PaperService.isNatureNewsURL(url) { return false }
        if detectSourceType(url: url) == .paper { return true }
        if PaperService.extractDOI(from: url) != nil { return true }
        return false
    }

    /// Apply URL/DOI guardrails after LLM classification. Only ground-truth paper
    /// identifiers override a `.book` classification back to `.paper`.
    nonisolated static func refinedSourceType(
        proposed: StudioSourceType,
        url: String
    ) -> StudioSourceType {
        // A Nature news story is an article whatever the model called it: the
        // URL settles it, so both a Dev and a Prod library that import the same
        // link agree without a coin flip.
        if proposed == .paper, PaperService.isNatureNewsURL(url) { return .article }
        guard proposed == .book else { return proposed }
        if looksLikeScholarlyPaper(url: url) { return .paper }
        return proposed
    }

    nonisolated static func applyClassifiedSourceType(_ type: StudioSourceType, to source: inout StudioArticle) {
        let refined = refinedSourceType(proposed: type, url: source.url)
        let previousType = source.sourceType
        source.sourceType = refined
        if refined == .paper, previousType != .paper {
            source.prepareForPaperMetadataExtraction()
        }
        if refined != .book, source.parentGroup == source.id {
            source.parentGroup = nil
        }
        normalizeWholeBookSource(&source)
    }

    /// Host-level X/Twitter check so unrelated domains like nfx.com never match.
    nonisolated static func isXHostURL(_ url: String) -> Bool {
        XPostThreadService.isXHostURL(url)
    }

    /// A link on a podcast hosting platform: an episode, processed via local
    /// Apple Podcast transcripts and never web-scraped. Show websites and
    /// generic paths are deliberately NOT podcast hosts: essays and blog posts
    /// on a podcaster's domain are articles.
    nonisolated static func isPodcastHostURL(_ url: String) -> Bool {
        let podcastDomains: Set<String> = [
            "podcasts.apple.com", "open.spotify.com", "overcast.fm",
            "pocketcasts.com", "castro.fm", "podbean.com", "anchor.fm",
            "buzzsprout.com", "transistor.fm", "simplecast.com",
            "megaphone.fm", "omnycontent.com",
        ]
        let host = URLComponents(string: url)?.host?.lowercased().replacingOccurrences(of: "www.", with: "") ?? ""
        return podcastDomains.contains(host)
    }

    nonisolated static func detectSourceType(url: String) -> StudioSourceType {
        let lower = url.lowercased()
        if lower.contains("/scrape/") || lower.hasSuffix(".ttml") {
            return .podcast
        }

        if isPodcastHostURL(url) {
            return .podcast
        }
        // Local files stored under the app's own Papers/Books/Courses folders are
        // typed by their storage location. This is a fact about where the app put
        // the file during import, not a guess about arbitrary web content, so it
        // stays deterministic. For web URLs we deliberately do NOT infer a type
        // from `/courses/`, `/books/`, or `/papers/` in the path — those cases
        // fall through to LLM classification instead of being force-typed.
        let isLocalFile = !lower.hasPrefix("http")
        if isLocalFile {
            if lower.contains("/courses/") { return .course }
            if lower.contains("/books/") { return .book }
            if lower.contains("/papers/") { return .paper }
        }
        if PaperService.isDirectPDFURL(url) {
            return .paper
        }
        // PubMed and PubMed Central article identifiers are deterministic paper
        // identities even though their landing pages are HTML and PMC's PDF URL
        // must be resolved later through Europe PMC.
        if PaperService.extractPMCID(from: url) != nil
            || PaperService.extractPMID(from: url) != nil {
            return .paper
        }

        // X / Twitter posts — check before video domains
        if isXHostURL(url) {
            // X posts with video in the URL path go under Videos
            if lower.contains("/video/") || lower.contains("/videos/") {
                return .video
            }
            return .xPost
        }

        // A Zoom cloud recording is a recording of a meeting, so it is typed as
        // one and lands in the Meetings tab beside the Drive and Read AI
        // sessions of the same series. Checked before the video domains below,
        // which would otherwise claim every zoom.us link.
        if ZoomRecordingService.isZoomRecordingURL(url) {
            return .meeting
        }

        // A Teachable course lecture is a video lecture; its transcript is its
        // audio (`fetchTeachableTranscript`), never the page's text.
        if TeachableCourseService.isLectureURL(url) {
            return .video
        }

        // Video platforms, and Zoom links that are not recordings
        let videoDomains = ["youtube.com", "youtu.be", "read.ai", "zoom.us",
                            "vimeo.com", "loom.com", "riverside.fm"]
        if videoDomains.contains(where: { lower.contains($0) }) {
            return .video
        }

        // Nature journalism carries a DOI and the journal's URL shape, but it is
        // an article: there is no PDF, and no model needs to be asked.
        if PaperService.isNatureNewsURL(url) { return .article }

        // PDFs are papers by default (unless path suggests otherwise — already handled above)
        // DOI URLs are always papers
        if lower.contains("doi.org/") { return .paper }

        // Reuse the paper URL resolver so preprint servers and journal landing pages
        // route consistently with the PDF-download path.
        if PaperService.paperPDFURL(from: url) != nil {
            return .paper
        }

        return .unclassified
    }
}

// MARK: - Paper versions

/// A preprint and the journal version it became are two versions of one work and two rows of the
/// library (docs/paper-versions.md). The rows share no identity key (`paperDedupDisplayKeys`), so
/// importing the journal version adds a paper rather than being refused as a copy; what ties them is
/// the DOI the preprint resolved to, or an identical title, read here from what the rows already hold.
extension StudioViewModel {
    /// The journal version of a preprint, among `papers`: the paper whose DOI is the one the preprint
    /// resolved to, else a journal record in the same library with the same title.
    nonisolated static func publishedVersion(of preprint: StudioArticle, in papers: [StudioArticle]) -> StudioArticle? {
        guard preprint.sourceType == .paper, paperVersionKind(of: preprint) == .preprint else { return nil }
        let candidates = papers.filter {
            $0.id != preprint.id && $0.sourceType == .paper && $0.teamID == preprint.teamID
                && paperVersionKind(of: $0) != .preprint
        }
        if let published = preprint.publishedDOI?.trimmingCharacters(in: .whitespacesAndNewlines), !published.isEmpty {
            let publishedKey = normalizeDOI(published)
            if let match = candidates.first(where: { candidate in
                (candidate.doi ?? PaperService.extractDOI(from: candidate.url)).map(normalizeDOI) == publishedKey
            }) {
                return match
            }
        }
        guard !titleNeedsResolution(preprint.title, domain: preprint.domain, url: preprint.url) else { return nil }
        let titleKey = normalizedPaperTitle(preprint.title)
        guard !titleKey.isEmpty else { return nil }
        return candidates.first { candidate in
            paperVersionKind(of: candidate) == .journal
                && !titleNeedsResolution(candidate.title, domain: candidate.domain, url: candidate.url)
                && normalizedPaperTitle(candidate.title) == titleKey
        }
    }

    /// The preprints among `papers` whose journal version is `published`, newest first.
    nonisolated static func earlierVersions(of published: StudioArticle, in papers: [StudioArticle]) -> [StudioArticle] {
        guard published.sourceType == .paper, paperVersionKind(of: published) != .preprint else { return [] }
        return papers
            .filter { $0.id != published.id && $0.sourceType == .paper && paperVersionKind(of: $0) == .preprint }
            .filter { publishedVersion(of: $0, in: [published])?.id == published.id }
            .sorted { $0.dateAdded > $1.dateAdded }
    }

    /// What `supersededPreprintIDs` reads off one paper: its place among its versions, its own
    /// DOI, the DOI it resolved to, and its exact-title key. Each is a parse of the address, the
    /// DOI or the title, so a caller that keeps them per paper (`paperListingFacts(for:)`) hands
    /// them in rather than having every pass over the library parse every paper again.
    struct PaperVersionFacts: Sendable, Equatable {
        let kind: PaperVersionKind
        /// `doi`, else the DOI in the paper's address, normalized (`normalizeDOI`).
        let ownDOI: String?
        /// The published DOI a preprint resolved to, trimmed and normalized; nil when it has none.
        let publishedDOI: String?
        /// `normalizedPaperTitle(title)`; nil while the title still needs resolving
        /// (`titleNeedsResolution`) or when it folds to nothing.
        let titleKey: String?

        init(_ paper: StudioArticle) {
            kind = StudioViewModel.paperVersionKind(of: paper)
            ownDOI = (paper.doi ?? PaperService.extractDOI(from: paper.url)).map(StudioViewModel.normalizeDOI)
            if let published = paper.publishedDOI?.trimmingCharacters(in: .whitespacesAndNewlines), !published.isEmpty {
                publishedDOI = StudioViewModel.normalizeDOI(published)
            } else {
                publishedDOI = nil
            }
            if StudioViewModel.titleNeedsResolution(paper.title, domain: paper.domain, url: paper.url) {
                titleKey = nil
            } else {
                let key = StudioViewModel.normalizedPaperTitle(paper.title)
                titleKey = key.isEmpty ? nil : key
            }
        }
    }

    /// The preprints a journal version with its PDF stands in for in the Papers lists. The preprint
    /// stays in its notebooks and keeps its highlights; the library lists the version of record.
    /// Without that PDF the preprint stays listed, since it is the copy that can be read.
    ///
    /// `versionFacts` reads a paper's facts; the default parses them afresh, and the Papers lists
    /// pass the ones the view model keeps per paper, so a library change does not re-parse every
    /// paper.
    nonisolated static func supersededPreprintIDs(
        in articles: [StudioArticle],
        hasUsablePDF: (StudioArticle) -> Bool,
        versionFacts: (StudioArticle) -> PaperVersionFacts = { PaperVersionFacts($0) }
    ) -> Set<String> {
        var doisByLibrary: [String?: Set<String>] = [:]
        var titlesByLibrary: [String?: Set<String>] = [:]
        var preprints: [(paper: StudioArticle, facts: PaperVersionFacts)] = []
        for paper in articles where paper.sourceType == .paper {
            let facts = versionFacts(paper)
            if facts.kind == .preprint {
                preprints.append((paper, facts))
                continue
            }
            guard hasUsablePDF(paper) else { continue }
            if let doi = facts.ownDOI {
                doisByLibrary[paper.teamID, default: []].insert(doi)
            }
            if facts.kind == .journal, let titleKey = facts.titleKey {
                titlesByLibrary[paper.teamID, default: []].insert(titleKey)
            }
        }
        guard !preprints.isEmpty, !doisByLibrary.isEmpty || !titlesByLibrary.isEmpty else { return [] }
        return Set(preprints.compactMap { preprint, facts -> String? in
            if let published = facts.publishedDOI,
               doisByLibrary[preprint.teamID]?.contains(published) == true {
                return preprint.id
            }
            guard let titleKey = facts.titleKey else { return nil }
            return titlesByLibrary[preprint.teamID]?.contains(titleKey) == true ? preprint.id : nil
        })
    }

    /// The journal version of the preprint `articleID`, once the library holds it.
    func publishedVersion(ofPreprint articleID: String) -> StudioArticle? {
        guard let preprint = articles.first(where: { $0.id == articleID }) else { return nil }
        return Self.publishedVersion(of: preprint, in: articles)
    }

    /// The preprints the library holds of the journal version `articleID`.
    func earlierVersions(ofPublished articleID: String) -> [StudioArticle] {
        guard let published = articles.first(where: { $0.id == articleID }) else { return [] }
        return Self.earlierVersions(of: published, in: articles)
    }

    /// Moves a notebook from a preprint to its journal version. Only the notebook's membership moves:
    /// the preprint keeps the highlights, chats and cards made against its text, and stays in every
    /// other notebook that holds it. The preprint leaves the notebook only once the journal version
    /// is in it.
    func switchNotebookToPublishedVersion(ofPreprint preprintID: String, notebookID: String) async {
        guard let published = publishedVersion(ofPreprint: preprintID),
              let notebook = notebook(id: notebookID) else { return }
        await addSourcesToNotebookContext([published.id], notebookID: notebookID, announce: false)
        guard notebookMembership(of: [canonicalSourceID(published.id)], in: notebookID) == .all else { return }
        await removeSourcesFromNotebook([preprintID], notebookID: notebookID, announce: false)
        showToast("\u{201C}\(notebook.title)\u{201D} now uses the published version")
    }
}
