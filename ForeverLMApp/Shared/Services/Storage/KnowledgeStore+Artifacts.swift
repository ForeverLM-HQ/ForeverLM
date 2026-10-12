import CryptoKit
import Foundation
import SQLite3

/// Which records a listing of artifacts reads. A source's draft deck of cards
/// to check (`ArtifactKind.flashcards`) and the working memory
/// (`WorkingMemoryRecords`) are the learner's private memory state, not
/// Docs: every listing leaves them out unless it asks for every record.
enum ArtifactListing: Sendable {
    /// Docs, Sites, animations, audio overviews: everything but card decks
    /// and the working memory.
    case listed
    /// Every record, card decks and the working memory too: a lookup by id, sync.
    case everyRecord
    /// Only the sources' draft decks.
    case cardDecksOnly

    /// The SQL condition on `global_artifacts`, by its kind and by the fixed
    /// id a deck keeps when an older build drops its kind
    /// (`ArtifactRecord.isCardDeck`), and by the working memory's fixed ids.
    /// `IS`, not `=`: a Doc's kind is NULL, and `NOT (NULL OR false)` would
    /// drop every Doc.
    fileprivate var condition: String {
        let isDeck = "(global_artifacts.kind IS '\(ArtifactKind.flashcards.rawValue)' OR substr(global_artifacts.id, 1, \(MemoryCard.draftDeckIDPrefix.count)) = '\(MemoryCard.draftDeckIDPrefix)')"
        let workingMemoryIDs = WorkingMemoryRecords.ids.sorted().map { "'\($0)'" }.joined(separator: ", ")
        switch self {
        case .listed: return "NOT \(isDeck) AND global_artifacts.id NOT IN (\(workingMemoryIDs))"
        case .everyRecord: return "1 = 1"
        case .cardDecksOnly: return isDeck
        }
    }
}

extension KnowledgeStore {
    /// The library's artifacts, newest first, or those linked to `notebookID`.
    /// Card decks and the working memory are left out unless `listing` asks
    /// for them: a listing is what Docs, the home's Docs tab, the pickers,
    /// `list_docs`, search, team copies and a notebook's outputs read, and
    /// none of them shows one.
    func loadArtifacts(notebookID: String? = nil, listing: ArtifactListing = .listed) throws -> [ArtifactRecord] {
        var rows: [(id: String, title: String, homeNotebookID: String?, isDraft: Bool, linkedURL: String?, createdAt: Date, updatedAt: Date, teamID: String?, archivedAt: Date?, hiddenAt: Date?, kind: String?)] = []
        let sql: String
        if notebookID == nil {
            sql = """
                SELECT global_artifacts.id, global_artifacts.title, global_artifacts.home_notebook_id,
                       global_artifacts.is_draft, global_artifacts.linked_url,
                       global_artifacts.created_at, global_artifacts.updated_at, global_artifacts.team_id,
                       global_artifacts.archived_at, hidden_artifacts.hidden_at, global_artifacts.kind
                FROM global_artifacts
                LEFT JOIN hidden_artifacts ON hidden_artifacts.artifact_id = global_artifacts.id
                WHERE \(listing.condition)
                ORDER BY global_artifacts.updated_at DESC, global_artifacts.title COLLATE NOCASE, global_artifacts.id
                """
        } else {
            sql = """
                SELECT global_artifacts.id, global_artifacts.title, global_artifacts.home_notebook_id,
                       global_artifacts.is_draft, global_artifacts.linked_url,
                       global_artifacts.created_at, global_artifacts.updated_at, global_artifacts.team_id,
                       global_artifacts.archived_at, hidden_artifacts.hidden_at, global_artifacts.kind
                FROM global_artifacts
                JOIN global_artifact_notebook_links
                  ON global_artifact_notebook_links.artifact_id = global_artifacts.id
                LEFT JOIN hidden_artifacts ON hidden_artifacts.artifact_id = global_artifacts.id
                WHERE global_artifact_notebook_links.notebook_id = ?
                  AND \(listing.condition)
                ORDER BY global_artifacts.updated_at DESC, global_artifacts.title COLLATE NOCASE, global_artifacts.id
                """
        }
        try queryBind(sql, bind: { statement in
            if let notebookID { bind(statement, 1, notebookID) }
        }) { statement in
            guard let id = string(statement, 0), let title = string(statement, 1) else { return }
            rows.append((
                id: id,
                title: title,
                homeNotebookID: string(statement, 2),
                isDraft: sqlite3_column_int(statement, 3) != 0,
                linkedURL: string(statement, 4),
                createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 5)),
                updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 6)),
                teamID: string(statement, 7),
                archivedAt: sqlite3_column_type(statement, 8) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 8)),
                hiddenAt: sqlite3_column_type(statement, 9) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 9)),
                kind: string(statement, 10)
            ))
        }

        let links = try artifactNotebookLinks(artifactIDs: rows.map(\.id))
        let sourceLinks = try artifactSourceLinks(artifactIDs: rows.map(\.id))
        return rows.map { row in
            ArtifactRecord(
                id: row.id,
                title: row.title,
                homeNotebookID: row.homeNotebookID,
                linkedNotebookIDs: links[row.id] ?? [],
                isDraft: row.isDraft,
                linkedURL: row.linkedURL,
                teamID: row.teamID,
                archivedAt: row.archivedAt,
                hiddenAt: row.hiddenAt,
                // A kind this build does not know reads as none: the record
                // then lists by its link, as it does on every older build.
                kind: row.kind.flatMap(ArtifactKind.init(rawValue:)),
                sourceIDs: sourceLinks[row.id] ?? [],
                createdAt: row.createdAt,
                updatedAt: row.updatedAt
            )
        }
    }

    /// One record by id, a card deck or the working memory included: sync
    /// reads and writes them like any record, and their own writers find
    /// them by id.
    func loadArtifact(_ artifactID: String) throws -> ArtifactRecord? {
        try loadArtifacts(listing: .everyRecord).first(where: { $0.id == artifactID })
    }

    /// When the learner hid this doc or site, or nil while it is shown — and
    /// nil for a doc that does not exist; callers that need the distinction
    /// check `loadArtifact` first.
    func artifactHiddenAt(_ artifactID: String) throws -> Date? {
        var hiddenAt: Date?
        try queryBind("SELECT hidden_at FROM hidden_artifacts WHERE artifact_id = ? LIMIT 1", bind: { statement in
            bind(statement, 1, artifactID)
        }) { statement in
            hiddenAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 0))
        }
        return hiddenAt
    }

    /// Hides a doc or site from the Docs and Sites lists, or shows it again,
    /// on every Mac signed into this account. The hide is a row of its own,
    /// never a field of the record: `saveArtifactRecord` cannot touch it, so
    /// an inbound Artifact or a team propagation re-saving the record leaves
    /// the learner's choice standing, and a team Doc hidden here is hidden
    /// for this account alone — the row syncs as a private-zone
    /// `HiddenArtifact` whatever zone the Artifact itself lives in. Nothing
    /// on the record moves, not `updated_at`, so hiding never republishes the
    /// doc. Re-hiding keeps the original date; showing a shown doc is a
    /// no-op. Returns the resulting date, or nil when the doc is shown or
    /// does not exist.
    @discardableResult
    func setArtifactHidden(_ artifactID: String, hidden: Bool) throws -> Date? {
        var exists = false
        try queryBind("SELECT 1 FROM global_artifacts WHERE id = ? LIMIT 1", bind: { statement in
            bind(statement, 1, artifactID)
        }) { _ in exists = true }
        guard exists else { return nil }
        let existing = try artifactHiddenAt(artifactID)
        if hidden {
            if let existing { return existing }
            let hiddenAt = Date()
            try execBind("INSERT INTO hidden_artifacts (artifact_id, hidden_at) VALUES (?, ?) ON CONFLICT(artifact_id) DO UPDATE SET hidden_at = excluded.hidden_at") { statement in
                bind(statement, 1, artifactID)
                sqlite3_bind_double(statement, 2, hiddenAt.timeIntervalSinceReferenceDate)
            }
            try markRecordChanged(entity: .hiddenArtifact, logicalKey: artifactID, at: hiddenAt)
            return hiddenAt
        }
        guard existing != nil else { return nil }
        try execBind("DELETE FROM hidden_artifacts WHERE artifact_id = ?") { statement in
            bind(statement, 1, artifactID)
        }
        try markRecordDeleted(entity: .hiddenArtifact, logicalKey: artifactID)
        return nil
    }

    func loadArtifactForSync(_ artifactID: String) throws -> ArtifactRecord? {
        try loadArtifact(artifactID)
    }

    func loadArtifactMarkdownForSync(_ artifactID: String) throws -> String? {
        guard dbPath != ":memory:",
              let url = artifactMarkdownReadURL(artifactID),
              FileManager.default.fileExists(atPath: url.path),
              let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
              size <= ArtifactRecord.markdownByteLimit else { return nil }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= ArtifactRecord.markdownByteLimit else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func loadArtifactBodyPackageForSync(
        _ artifactID: String
    ) throws -> ArtifactBodyPackage.Encoded? {
        guard let markdown = try loadArtifactMarkdownForSync(artifactID),
              let documentURL = artifactMarkdownReadURL(artifactID) else { return nil }
        let attachments = documentURL.deletingLastPathComponent()
            .appendingPathComponent("Attachments", isDirectory: true)
        return try ArtifactBodyPackage.encode(
            markdown: markdown,
            attachmentDirectory: attachments,
            siteFiles: try localSiteFiles(artifactID)
        )
    }

    // MARK: - A site's files, kept in the library

    /// The folder a ForeverLM site or animation keeps its files in:
    /// `Artifacts/<id>/Site/` beside the record's text copy. The files are
    /// the site; the text copy is what chat reads of it. Both travel in the
    /// one body package (`ArtifactBodyPackage` format 2).
    func localSiteDirectoryURL(_ artifactID: String) -> URL? {
        artifactMarkdownURL(artifactID)?
            .deletingLastPathComponent()
            .appendingPathComponent(Self.localSiteFolderName, isDirectory: true)
    }

    static let localSiteFolderName = "Site"

    func hasLocalSite(_ artifactID: String) -> Bool {
        guard let directory = localSiteDirectoryURL(artifactID) else { return false }
        return FileManager.default.fileExists(atPath: directory.path)
    }

    /// Every file of the site, as paths inside it, sorted; nil when the
    /// record keeps no site. Anything a site could not serve — a Finder
    /// `.DS_Store`, a dotfile — is not one of its files.
    func localSiteFilePaths(_ artifactID: String) throws -> [String]? {
        guard let directory = localSiteDirectoryURL(artifactID),
              FileManager.default.fileExists(atPath: directory.path) else { return nil }
        // Both sides resolved, so a folder reached through a symlink (the
        // temporary directory's /var → /private/var) still yields relative paths.
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return [] }
        var paths: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let full = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard full.hasPrefix(root + "/") else { continue }
            let relative = String(full.dropFirst(root.count + 1))
            if let path = LocalSite.normalizePath(relative), path == relative { paths.append(path) }
        }
        return paths.sorted()
    }

    func localSiteFiles(_ artifactID: String) throws -> [SiteFile]? {
        guard let paths = try localSiteFilePaths(artifactID),
              let directory = localSiteDirectoryURL(artifactID) else { return nil }
        return try paths.map { path in
            SiteFile(path: path, data: try Data(contentsOf: directory.appendingPathComponent(path), options: [.mappedIfSafe]))
        }
    }

    /// One file of the site, or nil when it has no such file.
    func readLocalSiteFile(_ artifactID: String, path rawPath: String) throws -> Data? {
        guard let path = LocalSite.normalizePath(rawPath),
              let directory = localSiteDirectoryURL(artifactID) else { return nil }
        let url = directory.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    /// Replace the site's files with exactly these. The new set is written to
    /// a staging folder beside the old one and swapped in whole, so a failed
    /// write leaves the site as it was rather than half of each.
    func writeLocalSiteFiles(_ files: [SiteFile], artifactID: String) throws {
        guard let directory = localSiteDirectoryURL(artifactID) else {
            throw KnowledgeStoreError.invalidData("Invalid artifact identifier.")
        }
        let parent = directory.deletingLastPathComponent()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".\(Self.localSiteFolderName)-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            for file in files {
                guard let path = LocalSite.normalizePath(file.path) else {
                    throw ArtifactBodyPackageError.invalidSiteFile(file.path)
                }
                let url = staging.appendingPathComponent(path)
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data.write(to: url, options: .atomic)
            }
            if fileManager.fileExists(atPath: directory.path) {
                _ = try fileManager.replaceItemAt(directory, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: directory)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    struct ArtifactBodyRepairBatch: Sendable {
        let lastScannedID: String?
        let queuedCount: Int
        let adoptedLinkCount: Int
        let deferredDownloadCount: Int
        let deferredConflictCount: Int
        let isComplete: Bool
    }

    /// Repair one bounded page of Docs. This re-enrolls bodies skipped by builds
    /// that looked beside `knowledge.db` instead of in the canonical content
    /// root and adopts retired product-scheme link targets into ForeverLM.
    /// Each page commits independently, so an interrupted upgrade resumes safely
    /// on the next launch rather than holding one unbounded transaction.
    /// Only Articles with a readable, package-sized body are queued, so a
    /// metadata-only receiving device never overwrites a good server body with
    /// an absent local file.
    func enqueueArtifactBodyRepairBatch(
        after lastScannedID: String?,
        limit: Int = 50
    ) throws -> ArtifactBodyRepairBatch {
        let boundedLimit = max(1, min(limit, 100))
        var candidates: [(id: String, updatedAt: Date)] = []
        try queryBind("""
            SELECT id, updated_at
            FROM global_artifacts
            WHERE id > ?
            ORDER BY id
            LIMIT \(boundedLimit + 1)
        """, bind: { statement in
            bind(statement, 1, lastScannedID ?? "")
        }) { statement in
            guard let id = string(statement, 0) else { return }
            candidates.append((
                id,
                Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 1))
            ))
        }

        let isComplete = candidates.count <= boundedLimit
        let page = Array(candidates.prefix(boundedLimit))
        guard !page.isEmpty else {
            return ArtifactBodyRepairBatch(
                lastScannedID: lastScannedID,
                queuedCount: 0,
                adoptedLinkCount: 0,
                deferredDownloadCount: 0,
                deferredConflictCount: 0,
                isComplete: true
            )
        }

        var repairable: [(id: String, updatedAt: Date, adoptedLinks: Bool)] = []
        var adoptedLinkCount = 0
        var deferredDownloadCount = 0
        var deferredConflictCount = 0
        for candidate in page {
            if let markdown = try loadArtifactMarkdownForSync(candidate.id) {
                let adopted = LegacyIdentityAdoption.adoptingRetiredArtifactLinks(in: markdown)
                let adoptedLinks = adopted != markdown
                if adoptedLinks, try hasSyncConflict(entity: .artifact, logicalKey: candidate.id) {
                    deferredConflictCount += 1
                    continue
                }
                if adoptedLinks {
                    try saveArtifactMarkdownFromSync(adopted, artifactID: candidate.id)
                    adoptedLinkCount += 1
                }
                let recordName = CloudKitRecordMapper.recordName(
                    for: .artifact,
                    logicalKey: candidate.id
                )
                let package = try loadArtifactBodyPackageForSync(candidate.id)
                let acknowledged = try committedAssetDigests(recordName: recordName)["payloadAsset"]
                if acknowledged != package?.revision {
                    repairable.append((
                        candidate.id,
                        adoptedLinks ? Date() : candidate.updatedAt,
                        adoptedLinks
                    ))
                }
            } else if artifactMarkdownDownloadIsPending(candidate.id) {
                deferredDownloadCount += 1
            }
        }
        guard !repairable.isEmpty else {
            return ArtifactBodyRepairBatch(
                lastScannedID: page.last?.id,
                queuedCount: 0,
                adoptedLinkCount: adoptedLinkCount,
                deferredDownloadCount: deferredDownloadCount,
                deferredConflictCount: deferredConflictCount,
                isComplete: isComplete
            )
        }

        var queuedCount = 0
        try exec("BEGIN IMMEDIATE")
        do {
            for candidate in repairable {
                // A normal edit already pending will serialize a path-only
                // repair. Link adoption changes the body itself, so it receives
                // a fresh generation and replaces the pending body package.
                let alreadyPending = try hasPendingSyncChange(
                    entity: .artifact,
                    logicalKey: candidate.id
                )
                guard (candidate.adoptedLinks || !alreadyPending), try !hasSyncConflict(
                    entity: .artifact,
                    logicalKey: candidate.id
                ) else { continue }
                if candidate.adoptedLinks {
                    try execBind("UPDATE global_artifacts SET updated_at = ? WHERE id = ?") { statement in
                        sqlite3_bind_double(statement, 1, candidate.updatedAt.timeIntervalSinceReferenceDate)
                        bind(statement, 2, candidate.id)
                    }
                }
                try upsertSyncSave(
                    entity: .artifact,
                    logicalKey: candidate.id,
                    at: candidate.updatedAt
                )
                queuedCount += 1
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        if queuedCount > 0 {
            NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
        }
        return ArtifactBodyRepairBatch(
            lastScannedID: page.last?.id,
            queuedCount: queuedCount,
            adoptedLinkCount: adoptedLinkCount,
            deferredDownloadCount: deferredDownloadCount,
            deferredConflictCount: deferredConflictCount,
            isComplete: isComplete
        )
    }

    func saveArtifactMarkdownFromSync(_ markdown: String, artifactID: String) throws {
        let data = Data(markdown.utf8)
        guard data.count <= ArtifactRecord.markdownByteLimit else {
            throw KnowledgeStoreError.invalidData("Synced artifact Markdown is too large.")
        }
        guard let url = artifactMarkdownURL(artifactID) else {
            throw KnowledgeStoreError.invalidData("Invalid artifact identifier.")
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        try saveArtifactBaseMarkdown(markdown, artifactID: artifactID)
    }

    /// Verify the complete package before writing anything, materialize media
    /// first, then atomically replace Markdown last. A failed attachment write
    /// can therefore never make a good local document point at missing bytes.
    func saveArtifactBodyPackageFromSync(
        _ data: Data,
        artifactID: String,
        expectedRevision: String?
    ) throws -> String {
        let decoded = try ArtifactBodyPackage.decode(data, expectedRevision: expectedRevision)
        guard let documentURL = artifactMarkdownURL(artifactID) else {
            throw KnowledgeStoreError.invalidData("Invalid artifact identifier.")
        }
        // A site's files land before its text copy, for the same reason media
        // does: the record must never name a site this device cannot serve.
        if let siteFiles = decoded.siteFiles {
            try writeLocalSiteFiles(siteFiles, artifactID: artifactID)
        }
        let directory = documentURL.deletingLastPathComponent()
        let attachmentDirectory = directory.appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(
            at: attachmentDirectory,
            withIntermediateDirectories: true
        )
        for attachment in decoded.attachments {
            try attachment.data.write(
                to: attachmentDirectory.appendingPathComponent(attachment.token),
                options: .atomic
            )
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data(decoded.markdown.utf8).write(to: documentURL, options: .atomic)
        try saveArtifactBaseMarkdown(decoded.markdown, artifactID: artifactID)
        return decoded.revision
    }

    // MARK: - The server's body, as this device last knew it

    /// Beside `document.md` a Doc keeps `document.base.md`: the body this device
    /// last knew the server to hold, written when a body arrives from CloudKit
    /// and when CloudKit acknowledges an upload. It is the base a three-way
    /// merge needs when a server body arrives while this Mac holds a newer one
    /// (`CloudKitRecordMapper.mergeArtifactServerConflict`). Neither sidecar is
    /// synced; each is this device's own bookkeeping.
    private static let artifactBaseDocumentName = "document.base.md"
    /// A server body this Mac could not merge into its own — the same passage
    /// changed on both sides — kept whole until the writer picks a version.
    private static let artifactHeldRemoteDocumentName = "document.remote.md"
    /// A member's draft of a team Doc keeps the team body it was taken from:
    /// the base its Publish merges against (docs/teams-design.md, decision
    /// 11). It cannot be `document.base.md`. A draft is a Doc that syncs, so
    /// every acknowledged upload makes the draft's own body that base, and a
    /// Publish after one sync found no edit of its own and kept the team body
    /// over every change the draft made.
    private static let teamDraftPublishBaseDocumentName = "document.publish-base.md"

    func loadArtifactBaseMarkdown(_ artifactID: String) throws -> String? {
        try loadArtifactSidecar(artifactID, name: Self.artifactBaseDocumentName)
    }

    func saveArtifactBaseMarkdown(_ markdown: String, artifactID: String) throws {
        try saveArtifactSidecar(markdown, artifactID: artifactID, name: Self.artifactBaseDocumentName)
    }

    func loadTeamDraftPublishBaseMarkdown(_ draftID: String) throws -> String? {
        try loadArtifactSidecar(draftID, name: Self.teamDraftPublishBaseDocumentName)
    }

    func saveTeamDraftPublishBaseMarkdown(_ markdown: String, draftID: String) throws {
        try saveArtifactSidecar(markdown, artifactID: draftID, name: Self.teamDraftPublishBaseDocumentName)
    }

    func loadArtifactHeldRemoteMarkdown(_ artifactID: String) throws -> String? {
        try loadArtifactSidecar(artifactID, name: Self.artifactHeldRemoteDocumentName)
    }

    func saveArtifactHeldRemoteMarkdown(_ markdown: String, artifactID: String) throws {
        try saveArtifactSidecar(markdown, artifactID: artifactID, name: Self.artifactHeldRemoteDocumentName)
    }

    func discardArtifactHeldRemoteMarkdown(_ artifactID: String) throws {
        guard let url = artifactSidecarURL(artifactID, name: Self.artifactHeldRemoteDocumentName),
              FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// CloudKit acknowledged an upload of this Doc. If the body on disk is
    /// still the one that went up — its package hashes to the digest the
    /// upload committed — the server now holds exactly this body, and it
    /// becomes the base. A body edited again while the upload was in flight is
    /// left for the next acknowledgement.
    func adoptArtifactBaseIfCurrent(_ artifactID: String) throws {
        guard let markdown = try loadArtifactMarkdownForSync(artifactID),
              let package = try loadArtifactBodyPackageForSync(artifactID) else { return }
        let recordName = CloudKitRecordMapper.recordName(for: .artifact, logicalKey: artifactID)
        guard try committedAssetDigests(recordName: recordName)[.payloadAsset] == package.revision else {
            return
        }
        try saveArtifactBaseMarkdown(markdown, artifactID: artifactID)
    }

    /// The body after a merge with a server body: this device's own edit,
    /// newer than the server's, so the row's date moves and the pending upload
    /// carries the merged text.
    func saveArtifactMarkdownAfterMerge(_ markdown: String, artifactID: String) throws {
        let data = Data(markdown.utf8)
        guard data.count <= ArtifactRecord.markdownByteLimit else {
            throw KnowledgeStoreError.invalidData("Merged artifact Markdown is too large.")
        }
        guard let url = artifactMarkdownURL(artifactID) else {
            throw KnowledgeStoreError.invalidData("Invalid artifact identifier.")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        if var artifact = try loadArtifact(artifactID) {
            artifact.updatedAt = Date()
            try saveArtifactRecord(artifact)
        }
    }

    func artifactSidecarURL(_ artifactID: String, name: String) -> URL? {
        artifactMarkdownURL(artifactID)?.deletingLastPathComponent().appendingPathComponent(name, isDirectory: false)
    }

    func loadArtifactSidecar(_ artifactID: String, name: String) throws -> String? {
        guard dbPath != ":memory:",
              let url = artifactSidecarURL(artifactID, name: name),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= ArtifactRecord.markdownByteLimit else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func saveArtifactSidecar(_ markdown: String, artifactID: String, name: String) throws {
        guard dbPath != ":memory:", let url = artifactSidecarURL(artifactID, name: name) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(markdown.utf8).write(to: url, options: .atomic)
    }

    func loadAllArtifactIDs() throws -> [String] {
        var ids: [String] = []
        try query("SELECT id FROM global_artifacts ORDER BY id") { statement in
            if let id = string(statement, 0) { ids.append(id) }
        }
        return ids
    }

    func saveArtifactRecord(_ artifact: ArtifactRecord) throws {
        let title = artifact.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ArtifactError.invalidTitle }
        let notebookIDs = Array(Set(artifact.linkedNotebookIDs)).sorted()
        let sourceIDs = Array(Set(artifact.sourceIDs.filter { !$0.isEmpty })).sorted()

        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("""
                INSERT INTO global_artifacts (id, title, home_notebook_id, is_draft, linked_url, created_at, updated_at, team_id, archived_at, kind)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    home_notebook_id = excluded.home_notebook_id,
                    is_draft = excluded.is_draft,
                    linked_url = excluded.linked_url,
                    created_at = excluded.created_at,
                    updated_at = excluded.updated_at,
                    team_id = COALESCE(excluded.team_id, global_artifacts.team_id),
                    archived_at = excluded.archived_at,
                    kind = excluded.kind
                -- The hide is not here: it is a hidden_artifacts row of the
                -- learner's own (setArtifactHidden), so a re-save from sync
                -- or a team copy leaves it as it stands.
                """) { statement in
                bind(statement, 1, artifact.id)
                bind(statement, 2, title)
                bind(statement, 3, artifact.homeNotebookID)
                sqlite3_bind_int(statement, 4, artifact.isDraft ? 1 : 0)
                bind(statement, 5, artifact.linkedURL)
                sqlite3_bind_double(statement, 6, artifact.createdAt.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(statement, 7, artifact.updatedAt.timeIntervalSinceReferenceDate)
                bind(statement, 8, artifact.teamID)
                if let archivedAt = artifact.archivedAt {
                    sqlite3_bind_double(statement, 9, archivedAt.timeIntervalSinceReferenceDate)
                } else {
                    sqlite3_bind_null(statement, 9)
                }
                bind(statement, 10, artifact.kind?.rawValue)
            }
            try execBind("DELETE FROM global_artifact_notebook_links WHERE artifact_id = ?") { statement in
                bind(statement, 1, artifact.id)
            }
            for notebookID in notebookIDs {
                try execBind("""
                    INSERT INTO global_artifact_notebook_links (artifact_id, notebook_id, linked_at)
                    VALUES (?, ?, ?)
                    """) { statement in
                    bind(statement, 1, artifact.id)
                    bind(statement, 2, notebookID)
                    sqlite3_bind_double(statement, 3, artifact.updatedAt.timeIntervalSinceReferenceDate)
                }
            }
            // The grounding is rewritten with the record, the way its Notebook
            // links are: the record is the truth about what it is about.
            try execBind("DELETE FROM global_artifact_source_links WHERE artifact_id = ?") { statement in
                bind(statement, 1, artifact.id)
            }
            for sourceID in sourceIDs {
                try execBind("""
                    INSERT INTO global_artifact_source_links (artifact_id, source_id, linked_at)
                    VALUES (?, ?, ?)
                    """) { statement in
                    bind(statement, 1, artifact.id)
                    bind(statement, 2, sourceID)
                    sqlite3_bind_double(statement, 3, artifact.updatedAt.timeIntervalSinceReferenceDate)
                }
            }
            if try !artifactUsesSharedDatabase(artifact.id) {
                try markRecordChanged(entity: .artifact, logicalKey: artifact.id, at: artifact.updatedAt)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Whether a record is a notebook's audio overview: by its kind, or by
    /// the carrier its id names when an older build dropped the kind
    /// (`GeneratedAudioOverview.isOverview(_:hasCarrier:)`).
    func isAudioOverview(_ artifact: ArtifactRecord) throws -> Bool {
        try GeneratedAudioOverview.isOverview(artifact) { try loadSourceWithoutContent($0) != nil }
    }

    func deleteArtifactRecord(_ artifactID: String) throws {
        // Comments cascade on their foreign key; chat links deliberately have
        // none (a chat can arrive from CloudKit before its doc), so the doc has
        // to sweep them itself or they outlive what they point at.
        try deleteArtifactChatLinks(artifactID: artifactID)
        // The hide goes with the record, tombstone included. A remote delete
        // runs sync-suppressed, and the deleting client may never have known
        // the hide record existed, so that dependent tombstone is published
        // explicitly — the same contract a chat's memory attempts follow.
        if try artifactHiddenAt(artifactID) != nil {
            try execBind("DELETE FROM hidden_artifacts WHERE artifact_id = ?") { statement in
                bind(statement, 1, artifactID)
            }
            if syncTrackingSuppressionDepth > 0 {
                try enqueueCascadingRecordDeletion(entity: .hiddenArtifact, logicalKey: artifactID)
            } else {
                try markRecordDeleted(entity: .hiddenArtifact, logicalKey: artifactID)
            }
        }
        try execBind("DELETE FROM artifact_walkthroughs WHERE artifact_id = ?") { statement in
            bind(statement, 1, artifactID)
        }
        try deleteWalkthroughProgress(artifactID)
        try execBind("DELETE FROM global_artifacts WHERE id = ?") { statement in
            bind(statement, 1, artifactID)
        }
        // Its other satellites' pointers (schema 159) have no key to cascade on; generation 1 writes
        // none, and a store held below 154 has no such table.
        if syncGeneration == .two {
            try execBind("DELETE FROM artifact_files WHERE artifact_id = ?") { statement in
                bind(statement, 1, artifactID)
            }
        }
        try markRecordDeleted(entity: .artifact, logicalKey: artifactID)
        // An audio overview's script and audio live on a carrier source whose
        // id the URL grammar fixes; it has no life of its own and goes with
        // the record on every path — the row menu, `delete_doc`, an inbound
        // delete. Under an inbound delete the carrier's tombstone is published
        // explicitly, for a deleting client that never knew to send it.
        let carrierID = GeneratedAudioOverview.carrierSourceID(artifactID: artifactID)
        if try loadSourceWithoutContent(carrierID) != nil {
            try deleteSourceRows(carrierID)
            if syncTrackingSuppressionDepth > 0 {
                try enqueueCascadingRecordDeletion(entity: .source, logicalKey: carrierID)
            }
        }
    }

    /// A Notebook is an organizational relationship, never the artifact's owner.
    /// Removing it clears all matching links and the optional home label while
    /// preserving the canonical document and its remaining Notebook links.
    func removeNotebookFromArtifacts(_ notebookID: String) throws {
        var affectedIDs: [String] = []
        try queryBind("""
            SELECT id FROM global_artifacts WHERE home_notebook_id = ?
            UNION
            SELECT artifact_id FROM global_artifact_notebook_links WHERE notebook_id = ?
            """, bind: { statement in
                bind(statement, 1, notebookID)
                bind(statement, 2, notebookID)
            }) { statement in
                if let id = string(statement, 0) { affectedIDs.append(id) }
            }
        guard !affectedIDs.isEmpty else { return }

        let changedAt = Date()
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("UPDATE global_artifacts SET home_notebook_id = NULL, updated_at = ? WHERE home_notebook_id = ?") { statement in
                sqlite3_bind_double(statement, 1, changedAt.timeIntervalSinceReferenceDate)
                bind(statement, 2, notebookID)
            }
            try execBind("DELETE FROM global_artifact_notebook_links WHERE notebook_id = ?") { statement in
                bind(statement, 1, notebookID)
            }
            for artifactID in affectedIDs {
                try execBind("UPDATE global_artifacts SET updated_at = ? WHERE id = ?") { statement in
                    sqlite3_bind_double(statement, 1, changedAt.timeIntervalSinceReferenceDate)
                    bind(statement, 2, artifactID)
                }
                try markRecordChanged(entity: .artifact, logicalKey: artifactID, at: changedAt)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func artifactNotebookLinks(artifactIDs: [String]) throws -> [String: [String]] {
        guard !artifactIDs.isEmpty else { return [:] }
        let wanted = Set(artifactIDs)
        var links: [String: [String]] = [:]
        try query("""
            SELECT artifact_id, notebook_id
            FROM global_artifact_notebook_links
            ORDER BY artifact_id, notebook_id
            """) { statement in
            guard let artifactID = string(statement, 0),
                  wanted.contains(artifactID),
                  let notebookID = string(statement, 1) else { return }
            links[artifactID, default: []].append(notebookID)
        }
        return links
    }

    /// The sources each record is about, in the order they were linked. The
    /// same one-query shape as the Notebook links: the table holds one row a
    /// link and the artifact list is small, so filtering in memory beats a
    /// query per record.
    private func artifactSourceLinks(artifactIDs: [String]) throws -> [String: [String]] {
        guard !artifactIDs.isEmpty else { return [:] }
        let wanted = Set(artifactIDs)
        var links: [String: [String]] = [:]
        try query("""
            SELECT artifact_id, source_id
            FROM global_artifact_source_links
            ORDER BY artifact_id, linked_at, source_id
            """) { statement in
            guard let artifactID = string(statement, 0),
                  wanted.contains(artifactID),
                  let sourceID = string(statement, 1) else { return }
            links[artifactID, default: []].append(sourceID)
        }
        return links
    }

    func artifactMarkdownURL(_ artifactID: String) -> URL? {
        guard !artifactID.isEmpty,
              !artifactID.contains("/"),
              !artifactID.contains(".."),
              let contentDirectory else { return nil }
        return contentDirectory
            .appendingPathComponent("Artifacts", isDirectory: true)
            .appendingPathComponent(artifactID, isDirectory: true)
            .appendingPathComponent("document.md", isDirectory: false)
    }

    private func artifactMarkdownReadURL(_ artifactID: String) -> URL? {
        guard let canonical = artifactMarkdownURL(artifactID) else { return nil }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: canonical.path) { return canonical }
        let relative = "Artifacts/\(artifactID)/document.md"
        return legacyContentDirectories
            .map { $0.appendingPathComponent(relative, isDirectory: false) }
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    /// Start a legacy iCloud download without mistaking its placeholder for a
    /// permanently absent Note body. The repair completion marker stays unset,
    /// so the next activation or explicit sync rechecks it after CloudDocs has
    /// materialized the file.
    private func artifactMarkdownDownloadIsPending(_ artifactID: String) -> Bool {
        guard let canonical = artifactMarkdownURL(artifactID) else { return false }
        let relative = "Artifacts/\(artifactID)/document.md"
        let fileManager = FileManager.default
        for candidate in [canonical] + legacyContentDirectories.map({
            $0.appendingPathComponent(relative, isDirectory: false)
        }) {
            if fileManager.fileExists(atPath: candidate.path) {
                var refreshed = candidate
                refreshed.removeAllCachedResourceValues()
                let values = try? refreshed.resourceValues(
                    forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
                )
                if values?.isUbiquitousItem == true,
                   values?.ubiquitousItemDownloadingStatus == .notDownloaded {
                    try? fileManager.startDownloadingUbiquitousItem(at: candidate)
                    return true
                }
            }
            let placeholder = candidate.deletingLastPathComponent()
                .appendingPathComponent(".\(candidate.lastPathComponent).icloud")
            if fileManager.fileExists(atPath: placeholder.path) {
                try? fileManager.startDownloadingUbiquitousItem(at: placeholder)
                return true
            }
        }
        return false
    }

}
