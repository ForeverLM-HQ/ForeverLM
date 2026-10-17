import CryptoKit
import Foundation
import OSLog
import UniformTypeIdentifiers
#if os(macOS)
import Darwin
#endif

extension StorageService {
    private static let artifactDirectoryName = "Artifacts"
    private static let artifactDocumentName = "document.md"

    func loadArtifacts(notebookID: String? = nil) throws -> [ArtifactRecord] {
        try notebookFilesKnowledgeStore().loadArtifacts(notebookID: notebookID)
    }

    /// A new Markdown Doc. `artifactID` is one the caller reserved, so a
    /// report's pending row and its MCP answer can name the Doc before it
    /// exists; nil makes a fresh one. `sourceIDs` are the sources the Doc is
    /// about — a report's, the sources it was written from — and in a team's
    /// library they name the team's copies, as a linked record's do. `kind`
    /// names what the record is when "a Doc" would misname it: a source's
    /// draft deck (`saveCardDrafts`).
    func createArtifact(
        title rawTitle: String,
        homeNotebookID: String?,
        linkedNotebookIDs: [String],
        markdown: String = "",
        isDraft: Bool = false,
        teamID: String? = nil,
        artifactID: String? = nil,
        sourceIDs: [String] = [],
        kind: ArtifactKind? = nil
    ) throws -> ArtifactMarkdownSnapshot {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ArtifactError.invalidTitle }
        let data = Data(markdown.utf8)
        guard data.count <= ArtifactRecord.markdownByteLimit else {
            throw NotebookMarkdownFileError.tooLarge(
                maxBytes: ArtifactRecord.markdownByteLimit
            )
        }

        let store = try notebookFilesKnowledgeStore()
        let id = artifactID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? UUID().uuidString.lowercased()
        guard !id.isEmpty, try store.loadArtifact(id) == nil else {
            throw KnowledgeStoreError.invalidData("An artifact with id \(id) already exists.")
        }
        var notebookIDs = Set(linkedNotebookIDs.filter { !$0.isEmpty })
        if let homeNotebookID, !homeNotebookID.isEmpty { notebookIDs.insert(homeNotebookID) }
        for notebookID in notebookIDs {
            guard try store.loadLearningGoal(notebookID)?.isNotebook == true else {
                throw ArtifactError.invalidNotebook(notebookID)
            }
        }

        // A Doc filed under a team Notebook is the team's; otherwise the caller's
        // library decides.
        let resolvedTeamID: String? = try {
            if let homeNotebookID, !homeNotebookID.isEmpty,
               let home = try store.loadLearningGoal(homeNotebookID)?.teamID {
                return home
            }
            return teamID?.isEmpty == false ? teamID : nil
        }()
        if let resolvedTeamID {
            guard let team = try store.loadTeam(resolvedTeamID) else {
                throw KnowledgeStoreError.invalidData("Team not found: \(resolvedTeamID)")
            }
            guard team.canEdit else {
                throw KnowledgeStoreError.invalidData("\(team.name) is read-only for you.")
            }
        }
        let resolvedSourceIDs: [String]
        if let resolvedTeamID, !sourceIDs.isEmpty {
            resolvedSourceIDs = carryArtifactSources(sourceIDs, intoTeam: resolvedTeamID, for: title, store: store)
        } else {
            var seen = Set<String>()
            resolvedSourceIDs = sourceIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        let now = Date()
        let artifact = ArtifactRecord(
            id: id,
            title: title,
            homeNotebookID: homeNotebookID?.isEmpty == false ? homeNotebookID : nil,
            linkedNotebookIDs: notebookIDs.sorted(),
            isDraft: isDraft,
            teamID: resolvedTeamID,
            kind: kind,
            sourceIDs: resolvedSourceIDs,
            createdAt: now,
            updatedAt: now
        )
        let directory = try artifactDirectoryURL(artifactID: artifact.id, createIfNeeded: true)
        let document = directory.appendingPathComponent(Self.artifactDocumentName)
        try data.write(to: document, options: .atomic)
        do {
            try store.saveArtifactRecord(artifact)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        invalidateArtifactContext(for: artifact.linkedNotebookIDs)
        if resolvedTeamID == nil {
            propagateDocToTeams(artifactID: artifact.id)
        }
        return ArtifactMarkdownSnapshot(
            artifact: artifact,
            markdown: markdown,
            revision: Self.artifactRevision(data)
        )
    }

    /// Put a linked page — a Google Doc, a Claude artifact, a Codex site — in
    /// the Docs pane. The record carries the canonical URL; the body starts
    /// empty and is filled by the text copy, so the same body asset, sync path
    /// and readers serve it as serve a Markdown doc. `kind` names what the
    /// record is when its link would misname it — an animation hosted as a
    /// ForeverLM site — and `sourceIDs` the sources it is about.
    func createLinkedArtifact(
        url: URL,
        title rawTitle: String,
        homeNotebookID: String?,
        linkedNotebookIDs: [String],
        teamID: String? = nil,
        kind: ArtifactKind? = nil,
        sourceIDs: [String] = []
    ) throws -> ArtifactRecord {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ArtifactError.invalidTitle }
        let store = try notebookFilesKnowledgeStore()
        var notebookIDs = Set(linkedNotebookIDs.filter { !$0.isEmpty })
        if let homeNotebookID, !homeNotebookID.isEmpty { notebookIDs.insert(homeNotebookID) }
        for notebookID in notebookIDs {
            guard try store.loadLearningGoal(notebookID)?.isNotebook == true else {
                throw ArtifactError.invalidNotebook(notebookID)
            }
        }

        let resolvedTeamID: String? = try {
            if let homeNotebookID, !homeNotebookID.isEmpty,
               let home = try store.loadLearningGoal(homeNotebookID)?.teamID {
                return home
            }
            return teamID?.isEmpty == false ? teamID : nil
        }()
        if let resolvedTeamID {
            guard let team = try store.loadTeam(resolvedTeamID) else {
                throw KnowledgeStoreError.invalidData("Team not found: \(resolvedTeamID)")
            }
            guard team.canEdit else {
                throw KnowledgeStoreError.invalidData("\(team.name) is read-only for you.")
            }
        }

        // A record made in a team names the team's copies of its sources,
        // copying them in where the team lacks them, the way a share does
        // (docs/teams-design.md, decision 16).
        let resolvedSourceIDs: [String]
        if let resolvedTeamID {
            resolvedSourceIDs = carryArtifactSources(sourceIDs, intoTeam: resolvedTeamID, for: title, store: store)
        } else {
            resolvedSourceIDs = Array(Set(sourceIDs.filter { !$0.isEmpty })).sorted()
        }

        let now = Date()
        let artifact = ArtifactRecord(
            id: UUID().uuidString.lowercased(),
            title: title,
            homeNotebookID: homeNotebookID?.isEmpty == false ? homeNotebookID : nil,
            linkedNotebookIDs: notebookIDs.sorted(),
            isDraft: false,
            linkedURL: url.absoluteString,
            teamID: resolvedTeamID,
            kind: kind,
            sourceIDs: resolvedSourceIDs,
            createdAt: now,
            updatedAt: now
        )
        let directory = try artifactDirectoryURL(artifactID: artifact.id, createIfNeeded: true)
        let document = directory.appendingPathComponent(Self.artifactDocumentName)
        try Data().write(to: document, options: .atomic)
        do {
            try store.saveArtifactRecord(artifact)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        invalidateArtifactContext(for: artifact.linkedNotebookIDs)
        if resolvedTeamID == nil {
            propagateDocToTeams(artifactID: artifact.id)
        }
        return artifact
    }

    /// Keep a ForeverLM site or animation in the library: its files under
    /// `Artifacts/<id>/Site/`, the entry page's visible text as the body chat
    /// reads, and the record's address `foreverlm-site://<id>/`. Nothing goes
    /// on the web. The files are written before the record is saved, so the
    /// sync that the save queues always carries them. `artifactID` nil makes a
    /// new record; an existing one keeps its Notebooks and team and takes the
    /// new title and files.
    func saveLocalSite(
        artifactID: String?,
        title rawTitle: String,
        files: [SiteFile],
        textCopy: String,
        homeNotebookID: String? = nil,
        linkedNotebookIDs: [String] = [],
        kind: ArtifactKind? = nil,
        sourceIDs: [String] = []
    ) throws -> ArtifactRecord {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ArtifactError.invalidTitle }
        let textData = Data(textCopy.utf8)
        guard textData.count <= ArtifactRecord.markdownByteLimit else {
            throw NotebookMarkdownFileError.tooLarge(maxBytes: ArtifactRecord.markdownByteLimit)
        }
        let store = try notebookFilesKnowledgeStore()
        let now = Date()
        var artifact: ArtifactRecord
        if let artifactID {
            guard let existing = try store.loadArtifact(artifactID) else {
                throw ArtifactError.unavailable(artifactID)
            }
            guard existing.linkedKind == .foreverlmSite else {
                throw KnowledgeStoreError.invalidData("“\(existing.title)” is not a ForeverLM site.")
            }
            artifact = existing
            artifact.title = title
            artifact.linkedURL = LinkedPage.localSiteURL(artifactID: existing.id).absoluteString
            artifact.updatedAt = now
        } else {
            var notebookIDs = Set(linkedNotebookIDs.filter { !$0.isEmpty })
            if let homeNotebookID, !homeNotebookID.isEmpty { notebookIDs.insert(homeNotebookID) }
            for notebookID in notebookIDs {
                guard try store.loadLearningGoal(notebookID)?.isNotebook == true else {
                    throw ArtifactError.invalidNotebook(notebookID)
                }
            }
            let id = UUID().uuidString.lowercased()
            artifact = ArtifactRecord(
                id: id,
                title: title,
                homeNotebookID: homeNotebookID?.isEmpty == false ? homeNotebookID : nil,
                linkedNotebookIDs: notebookIDs.sorted(),
                isDraft: false,
                linkedURL: LinkedPage.localSiteURL(artifactID: id).absoluteString,
                teamID: nil,
                kind: kind,
                sourceIDs: Array(Set(sourceIDs.filter { !$0.isEmpty })).sorted(),
                createdAt: now,
                updatedAt: now
            )
        }
        let isNew = artifactID == nil
        let directory = try artifactDirectoryURL(artifactID: artifact.id, createIfNeeded: true)
        do {
            try store.writeLocalSiteFiles(files, artifactID: artifact.id)
            try textData.write(to: directory.appendingPathComponent(Self.artifactDocumentName), options: .atomic)
            try store.saveArtifactRecord(artifact)
        } catch {
            if isNew { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
        invalidateArtifactContext(for: artifact.linkedNotebookIDs)
        if artifact.teamID == nil {
            propagateDocToTeams(artifactID: artifact.id)
        }
        return artifact
    }

    /// The files a site keeps in the library, or nil for a record that keeps
    /// none.
    func localSiteFiles(artifactID: String) throws -> [SiteFile]? {
        try notebookFilesKnowledgeStore().localSiteFiles(artifactID)
    }

    func localSiteFilePaths(artifactID: String) throws -> [String]? {
        try notebookFilesKnowledgeStore().localSiteFilePaths(artifactID)
    }

    func readLocalSiteFile(artifactID: String, path: String) throws -> Data? {
        try notebookFilesKnowledgeStore().readLocalSiteFile(artifactID, path: path)
    }

    /// Make a Markdown doc a linked doc, after its content has been copied
    /// into the Google Doc at `url`. The record gains the canonical edit URL
    /// and nothing else moves: the Markdown stays as the body so chat, search
    /// and review keep reading the same text until Google's export replaces
    /// it, and the id, Notebooks and body asset are untouched, so every other
    /// device sees one doc change kind rather than a doc vanish and another
    /// appear.
    func linkArtifactToGoogleDoc(artifactID: String, url: URL) throws -> ArtifactRecord {
        let store = try notebookFilesKnowledgeStore()
        guard var artifact = try store.loadArtifact(artifactID) else {
            throw ArtifactError.unavailable(artifactID)
        }
        guard !artifact.isLinked else {
            throw ArtifactError.alreadyLinked(artifact.title)
        }
        // One Google Doc, one row: a second doc pointing at the same document
        // would be two read-only copies of one thing.
        if let holder = try store.loadArtifacts().first(where: { $0.linkedURL == url.absoluteString }) {
            throw ArtifactError.alreadyLinked(holder.title)
        }
        artifact.linkedURL = url.absoluteString
        artifact.updatedAt = Date()
        try store.saveArtifactRecord(artifact)
        // The export is due at once: the body is still the Markdown that was
        // sent, and the first open should ask Google for its copy.
        linkedArtifactExportRefreshedAt[artifactID] = nil
        invalidateArtifactContext(for: artifact.linkedNotebookIDs)
        return artifact
    }

    /// Replace the sources a record is about. The one writer today is
    /// `save_animation`, when an update names sources; a Doc or a Site may
    /// take the same call later. The record's date moves, so the change
    /// syncs, and the text copy is the caller's to refresh.
    @discardableResult
    func setArtifactGrounding(artifactID: String, sourceIDs: [String]) throws -> ArtifactRecord {
        let store = try notebookFilesKnowledgeStore()
        guard var artifact = try store.loadArtifact(artifactID) else {
            throw ArtifactError.unavailable(artifactID)
        }
        // A team record's grounding is the team's: the sources named are
        // copied in where the team lacks them and the record names the copies.
        let normalized: [String]
        if let teamID = artifact.teamID {
            normalized = carryArtifactSources(sourceIDs, intoTeam: teamID, for: artifact.title, store: store)
        } else {
            normalized = Array(Set(sourceIDs.filter { !$0.isEmpty })).sorted()
        }
        guard Set(artifact.sourceIDs) != Set(normalized) else { return artifact }
        artifact.sourceIDs = normalized
        artifact.updatedAt = Date()
        try store.saveArtifactRecord(artifact)
        invalidateArtifactContext(for: artifact.linkedNotebookIDs)
        return artifact
    }

    /// The team's ids for the sources a record made or regrounded in a team
    /// names, copying each into the team where it is missing
    /// (`KnowledgeStore.carrySourcesIntoTeam`). A source that cannot be copied
    /// is logged and left out; the record is still saved. Sharing a source
    /// into a team is a team write, so the team's sync is scheduled when
    /// anything travelled.
    private func carryArtifactSources(_ sourceIDs: [String], intoTeam teamID: String, for title: String, store: KnowledgeStore) -> [String] {
        let carried = store.carrySourcesIntoTeam(sourceIDs, teamID: teamID) { path in
            try self.copyFileIntoTeam(relativePath: path, teamID: teamID)
        }
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "Teams")
        for failure in carried.carried.failed {
            logger.error("Source \(failure.originalID, privacy: .public) did not travel with ‘\(title, privacy: .public)’ into team \(teamID, privacy: .public): \(failure.reason, privacy: .public)")
        }
        if !carried.carried.linked.isEmpty {
            scheduleImmediateCloudKitSyncForTeams()
        }
        return carried.sourceIDs
    }

    /// Where a page published into Notebooks is filed (docs/teams-design.md,
    /// decision 17): the publisher's own record takes the Notebooks of My
    /// Library, and each team named through one of its Notebooks takes the
    /// team Notebooks among them, for the copy the share files there. A
    /// Notebook that does not exist is refused, the way `createLinkedArtifact`
    /// refuses it.
    struct PublishedPageFiling {
        var homeNotebookID: String?
        var linkedNotebookIDs: [String]
        /// Team Notebooks by team, for the copies.
        var teamNotebookIDs: [String: [String]]
    }

    func publishedPageFiling(homeNotebookID: String?, linkedNotebookIDs: [String]) throws -> PublishedPageFiling {
        let store = try notebookFilesKnowledgeStore()
        var notebookIDs = Set(linkedNotebookIDs.filter { !$0.isEmpty })
        if let homeNotebookID, !homeNotebookID.isEmpty { notebookIDs.insert(homeNotebookID) }
        var filing = PublishedPageFiling(homeNotebookID: nil, linkedNotebookIDs: [], teamNotebookIDs: [:])
        for notebookID in notebookIDs.sorted() {
            guard let notebook = try store.loadLearningGoal(notebookID), notebook.isNotebook else {
                throw ArtifactError.invalidNotebook(notebookID)
            }
            if let teamID = notebook.teamID {
                filing.teamNotebookIDs[teamID, default: []].append(notebookID)
            } else {
                filing.linkedNotebookIDs.append(notebookID)
            }
        }
        if let homeNotebookID, filing.linkedNotebookIDs.contains(homeNotebookID) {
            filing.homeNotebookID = homeNotebookID
        }
        return filing
    }

    // MARK: - Linked in: the artifacts a source is linked to

    /// One artifact a source is linked to, and how (docs/docs-design.md,
    /// "Linked in"). `grounded`: the record's own source links name the
    /// source — an animation's sources, a site's cards, a Doc's grounding, a
    /// book token standing for the chapter's book. `cited`: a Doc's body holds
    /// a reference to the source — a web address the library resolves to it
    /// (a DOI, its page), or a `foreverlm://source` link. Both when both.
    struct SourceArtifactLink: Equatable, Sendable {
        enum Way: String, Comparable, Sendable {
            case grounded, cited
            static func < (lhs: Way, rhs: Way) -> Bool { lhs.rawValue < rhs.rawValue }
        }
        let artifact: ArtifactRecord
        var ways: Set<Way>
    }

    /// Every artifact linked to a source, newest first. The product owner (2026-09-18):
    /// "For a given paper, it might be nice if we could also see which
    /// artifacts it's mentioned in somehow … or linked to rather." Derived
    /// from what the records already hold — no index, no migration: a
    /// record's `sourceIDs`, and for a Markdown Doc its body, read here on the
    /// storage actor and remembered per Doc by `updatedAt`
    /// (`SourceArtifactCitationCache`) so the sidebar's menu never rereads an
    /// unchanged Doc. A source the library does not hold is refused; a Doc
    /// citing an address this library does not hold links to nothing.
    func artifactsLinked(toSource sourceID: String) throws -> [SourceArtifactLink] {
        let store = try notebookFilesKnowledgeStore()
        guard let source = try store.loadSourceWithoutContent(sourceID) else {
            throw KnowledgeStoreError.invalidData("Source \(sourceID) does not exist.")
        }
        // What names this source in a record's links or a Doc's grounding:
        // its own id, and its book — as the book token a grounded passage
        // carries, or the book id itself.
        var tokens: Set<String> = [sourceID]
        if let book = source.parentGroup?.trimmingCharacters(in: .whitespacesAndNewlines), !book.isEmpty {
            tokens.insert(book)
            tokens.insert("book:\(book)")
        }
        var links: [SourceArtifactLink] = []
        for artifact in try store.loadArtifacts() where !TeamContentIdentity.isDraftArtifactID(artifact.id) {
            var ways = Set<SourceArtifactLink.Way>()
            if !tokens.isDisjoint(with: artifact.sourceIDs) { ways.insert(.grounded) }
            if !artifact.isLinked, artifact.kind == nil {
                let body = citations(of: artifact)
                if !tokens.isDisjoint(with: body.grounded) { ways.insert(.grounded) }
                if body.cited.contains(sourceID) { ways.insert(.cited) }
            }
            if !ways.isEmpty { links.append(SourceArtifactLink(artifact: artifact, ways: ways)) }
        }
        return links.sorted { $0.artifact.updatedAt > $1.artifact.updatedAt }
    }

    /// What a Markdown Doc's body links: the grounding tokens its
    /// `foreverlm://source` and `foreverlm://grounding` addresses carry
    /// (source ids and `book:` tokens), and the library source ids its web
    /// references resolve to — in the Doc's own library, a team Doc asking
    /// the team's copies. Cached by the Doc's `updatedAt`; a body that cannot
    /// be read links to nothing.
    private func citations(of artifact: ArtifactRecord) -> SourceArtifactCitationCache.Entry {
        if let cached = SourceArtifactCitationCache.shared.entry(for: artifact.id, updatedAt: artifact.updatedAt) {
            return cached
        }
        var entry = SourceArtifactCitationCache.Entry(updatedAt: artifact.updatedAt, grounded: [], cited: [])
        if let markdown = try? artifactMarkdown(artifact.id).markdown, !markdown.isEmpty {
            entry.grounded = Set(Self.groundingTokens(in: markdown))
            let references = Self.webReferences(in: markdown)
            entry.cited = Set(librarySourceIDs(forReferenceURLs: references, teamID: artifact.teamID).values)
        }
        SourceArtifactCitationCache.shared.store(entry, for: artifact.id)
        return entry
    }

    /// Compiled once: the notes graph reads every block of a library with it.
    private nonisolated static let groundingAddressExpression = try? NSRegularExpression(
        pattern: #"foreverlm://(source|grounding)/([^\)\s\]"']+)"#
    )

    /// The source ids and `book:` tokens a Doc's body links through
    /// `foreverlm://source/<id>` and `foreverlm://grounding/<a,b,…>`
    /// addresses, as the Notepad writes them.
    nonisolated static func groundingTokens(in markdown: String) -> [String] {
        guard let expression = groundingAddressExpression else { return [] }
        var tokens: [String] = []
        let ns = markdown as NSString
        for match in expression.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges == 3 else { continue }
            let kind = ns.substring(with: match.range(at: 1))
            let raw = ns.substring(with: match.range(at: 2))
            let parts = kind == "grounding" ? raw.split(separator: ",").map(String.init) : [raw]
            for part in parts {
                var token = (part.removingPercentEncoding ?? part).trimmingCharacters(in: .whitespacesAndNewlines)
                if let query = token.firstIndex(of: "?") { token = String(token[..<query]) }
                if let fragment = token.firstIndex(of: "#") { token = String(token[..<fragment]) }
                if !token.isEmpty { tokens.append(token) }
            }
        }
        return tokens
    }

    /// The inverse: a linked doc becomes a Markdown doc again, with whatever
    /// text ForeverLM holds for it — the export, or the Markdown a conversion
    /// sent — as its editable body. The page itself is not touched.
    func unlinkArtifact(artifactID: String) throws -> ArtifactRecord {
        let store = try notebookFilesKnowledgeStore()
        guard var artifact = try store.loadArtifact(artifactID) else {
            throw ArtifactError.unavailable(artifactID)
        }
        guard artifact.isLinked else {
            throw KnowledgeStoreError.invalidData("“\(artifact.title)” is not a linked page.")
        }
        artifact.linkedURL = nil
        artifact.updatedAt = Date()
        try store.saveArtifactRecord(artifact)
        linkedArtifactExportRefreshedAt[artifactID] = nil
        invalidateArtifactContext(for: artifact.linkedNotebookIDs)
        return artifact
    }

    /// Whether a linked doc's text export is due. Process-local: the first open
    /// after launch always refreshes, later opens within the interval do not.
    func linkedArtifactExportIsDue(_ artifactID: String) -> Bool {
        guard let refreshed = linkedArtifactExportRefreshedAt[artifactID] else { return true }
        return Date().timeIntervalSince(refreshed) >= LinkedGoogleDoc.exportRefreshInterval
    }

    /// Record the outcome of an export attempt, successful or not, so a doc that
    /// cannot be exported is not retried on every open either.
    func noteLinkedArtifactExportAttempt(_ artifactID: String) {
        linkedArtifactExportRefreshedAt[artifactID] = Date()
    }

    /// Replace a linked doc's body with a fresh text export. The one writer a
    /// linked doc's body has: `writeArtifactMarkdown` refuses these docs so a
    /// chat, the MCP surface or the editor can never edit a copy of something
    /// Google owns. Unchanged text is a no-op, so an open that finds nothing new
    /// queues no sync and moves no timestamp.
    @discardableResult
    func replaceLinkedArtifactExport(
        artifactID: String,
        text: String
    ) throws -> ArtifactMarkdownSnapshot {
        let store = try notebookFilesKnowledgeStore()
        guard let artifact = try store.loadArtifact(artifactID) else {
            throw ArtifactError.unavailable(artifactID)
        }
        guard artifact.isLinked else {
            throw KnowledgeStoreError.invalidData("“\(artifact.title)” is not a linked page.")
        }
        let data = Data(text.utf8)
        guard data.count <= ArtifactRecord.markdownByteLimit else {
            throw NotebookMarkdownFileError.tooLarge(maxBytes: ArtifactRecord.markdownByteLimit)
        }
        let document = try canonicalArtifactDocumentURL(
            artifactID: artifactID,
            createDirectoryIfNeeded: true
        )
        if let existing = try? Data(contentsOf: document, options: [.mappedIfSafe]),
           existing == data {
            return ArtifactMarkdownSnapshot(
                artifact: artifact,
                markdown: text,
                revision: Self.artifactRevision(data)
            )
        }
        try data.write(to: document, options: .atomic)
        var updated = artifact
        updated.updatedAt = Date()
        try store.saveArtifactRecord(updated)
        invalidateArtifactContext(for: updated.linkedNotebookIDs)
        propagateDocToTeams(artifactID: artifactID)
        return ArtifactMarkdownSnapshot(
            artifact: updated,
            markdown: text,
            revision: Self.artifactRevision(data)
        )
    }

    func artifactMarkdown(_ artifactID: String) throws -> ArtifactMarkdownSnapshot {
        let store = try notebookFilesKnowledgeStore()
        guard let artifact = try store.loadArtifact(artifactID) else {
            throw ArtifactError.unavailable(artifactID)
        }
        return try artifactMarkdown(of: artifact)
    }

    /// The body of a record already in hand, read as `artifactMarkdown(_:)`
    /// reads it, without looking the record up again: the notes graph reads
    /// every Doc of a library from one listing (`StorageService+DocGraph.swift`).
    func artifactMarkdown(of artifact: ArtifactRecord) throws -> ArtifactMarkdownSnapshot {
        let url = try artifactDocumentURL(artifactID: artifact.id)
        switch try prepareArtifactForReading(url) {
        case .available:
            break
        case .downloading:
            throw ArtifactError.downloading(artifact.title)
        case .missing:
            throw ArtifactError.unavailable(artifact.title)
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= Self.notebookMarkdownFileByteLimit else {
            throw NotebookMarkdownFileError.tooLarge(maxBytes: Self.notebookMarkdownFileByteLimit)
        }
        return ArtifactMarkdownSnapshot(
            artifact: artifact,
            markdown: String(decoding: data, as: UTF8.self),
            revision: Self.artifactRevision(data)
        )
    }

    /// A version of the body from another writer that the sync engine could
    /// not merge into this Mac's — the same passage changed on both sides —
    /// held beside the doc until the writer picks one.
    func artifactHeldRemoteMarkdown(_ artifactID: String) throws -> String? {
        try notebookFilesKnowledgeStore().loadArtifactHeldRemoteMarkdown(artifactID)
    }

    func discardArtifactHeldRemoteMarkdown(_ artifactID: String) throws {
        try notebookFilesKnowledgeStore().discardArtifactHeldRemoteMarkdown(artifactID)
    }

    /// `versionReason` says what the write is, for the page's version history
    /// on this Mac: the body it replaces is kept as a version when the policy
    /// says so (`PageVersionPolicy`; docs/docs-design.md, "Version history").
    /// Typing is the default; an assistant's write and a restore say so.
    func writeArtifactMarkdown(
        artifactID: String,
        markdown: String,
        expectedRevision: String,
        versionReason: PageVersionReason = .learnerEdit
    ) throws -> ArtifactMarkdownSnapshot {
        let current = try artifactMarkdown(artifactID)
        guard !current.artifact.isLinked else {
            throw ArtifactError.linkedDocReadOnly(current.artifact.title)
        }
        guard current.revision.caseInsensitiveCompare(expectedRevision) == .orderedSame else {
            throw ArtifactError.conflict(current.artifact.title)
        }
        let data = Data(markdown.utf8)
        guard data.count <= ArtifactRecord.markdownByteLimit else {
            throw NotebookMarkdownFileError.tooLarge(
                maxBytes: ArtifactRecord.markdownByteLimit
            )
        }
        let document = try canonicalArtifactDocumentURL(
            artifactID: artifactID,
            createDirectoryIfNeeded: true
        )
        // Never fails the save: a version that cannot be kept is logged.
        (try? notebookFilesKnowledgeStore())?.pageVersionHistory?.keepIfDue(
            previous: current.markdown,
            replacedBy: markdown,
            artifactID: artifactID,
            reason: versionReason
        )
        try data.write(to: document, options: .atomic)

        var updated = current.artifact
        updated.updatedAt = Date()
        try notebookFilesKnowledgeStore().saveArtifactRecord(updated)
        invalidateArtifactContext(for: updated.linkedNotebookIDs)
        propagateDocToTeams(artifactID: artifactID)
        return ArtifactMarkdownSnapshot(
            artifact: updated,
            markdown: markdown,
            revision: Self.artifactRevision(data)
        )
    }

    func updateArtifact(
        artifactID: String,
        title rawTitle: String?,
        homeNotebookID: String?,
        linkedNotebookIDs: [String]?,
        isDraft: Bool? = nil,
        isArchived: Bool? = nil
    ) throws -> ArtifactRecord {
        let store = try notebookFilesKnowledgeStore()
        guard var artifact = try store.loadArtifact(artifactID) else {
            throw ArtifactError.unavailable(artifactID)
        }
        let previousNotebookIDs = artifact.linkedNotebookIDs
        if let rawTitle {
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw ArtifactError.invalidTitle }
            artifact.title = title
        }
        if let linkedNotebookIDs {
            artifact.linkedNotebookIDs = Array(Set(linkedNotebookIDs.filter { !$0.isEmpty })).sorted()
        }
        // `homeNotebookID` uses an empty string as the explicit clear value so MCP
        // and UI callers can distinguish clear from "leave unchanged".
        if let homeNotebookID {
            artifact.homeNotebookID = homeNotebookID.isEmpty ? nil : homeNotebookID
        }
        if let isDraft {
            artifact.isDraft = isDraft
        }
        // Archiving keeps the record whole and only takes it off the lists;
        // re-archiving something already archived keeps its original date.
        if let isArchived {
            if isArchived {
                if artifact.archivedAt == nil { artifact.archivedAt = Date() }
            } else {
                artifact.archivedAt = nil
            }
        }
        if let home = artifact.homeNotebookID {
            guard try store.loadLearningGoal(home)?.isNotebook == true else {
                throw ArtifactError.invalidNotebook(home)
            }
        }
        for notebookID in artifact.linkedNotebookIDs {
            guard try store.loadLearningGoal(notebookID)?.isNotebook == true else {
                throw ArtifactError.invalidNotebook(notebookID)
            }
        }
        artifact.updatedAt = Date()
        try store.saveArtifactRecord(artifact)
        invalidateArtifactContext(for: previousNotebookIDs + artifact.linkedNotebookIDs)
        propagateDocToTeams(artifactID: artifactID)
        return artifact
    }

    /// Files the Pages a chat wrote (`ChatWrittenPage`) in the Notebook the
    /// chat was just made into, so "turn this chat into a notebook" brings its
    /// Pages along as well as its sources. Asked to, a free model wrote a Page
    /// and left it, and the chat, in no Notebook (product owner, 2026-10-17:
    /// "turn a chat into a notebook with associated content").
    ///
    /// The Pages are the ones the chat's stored replies carry as cards, plus
    /// `pageIDs`: those the running turn wrote, whose reply is not stored
    /// yet. A Page with no home takes the Notebook as its home; one homed in
    /// another Notebook is linked to this one too. A Page already in it, gone,
    /// archived, not an ordinary Markdown Page, or in another library than
    /// the Notebook is left as it is. Returns the Pages filed.
    @discardableResult
    func fileChatPages(sessionID: String, pageIDs: [String] = [], inNotebook notebookID: String) throws -> [ArtifactRecord] {
        let store = try notebookFilesKnowledgeStore()
        guard let notebook = try store.loadLearningGoal(notebookID), notebook.isNotebook else { return [] }
        let stored = try store.loadReviewSessionExchanges(sessionID: sessionID)
            .flatMap { ChatWrittenPage.split($0.evaluation ?? "") }
            .compactMap { part -> String? in
                if case .page(let page) = part { return page.id }
                return nil
            }
        var seen = Set<String>()
        var filed: [ArtifactRecord] = []
        for id in stored + pageIDs where seen.insert(id).inserted {
            guard let page = try store.loadArtifact(id),
                  page.kind == nil, page.linkedURL == nil, page.archivedAt == nil,
                  page.teamID == notebook.teamID,
                  page.homeNotebookID != notebookID,
                  !page.linkedNotebookIDs.contains(notebookID) else { continue }
            filed.append(page.homeNotebookID == nil
                ? try updateArtifact(artifactID: id, title: nil, homeNotebookID: notebookID, linkedNotebookIDs: nil)
                : try updateArtifact(artifactID: id, title: nil, homeNotebookID: nil, linkedNotebookIDs: page.linkedNotebookIDs + [notebookID]))
        }
        return filed
    }

    /// Hides a doc or site from the Docs and Sites lists on every Mac signed
    /// into this account, or shows it again. This is not `updateArtifact`: the
    /// record does not change — `updatedAt` stays, the Artifact is not
    /// republished, no team copy is touched, and the Notebook context the doc
    /// feeds is unchanged — because hiding is the learner's view of the record,
    /// not a fact about it. The view travels as its own private-zone record,
    /// so a team Doc hidden here is hidden for this account alone. Re-hiding
    /// something hidden keeps its original date.
    func setArtifactHidden(artifactID: String, isHidden: Bool) throws -> ArtifactRecord {
        let store = try notebookFilesKnowledgeStore()
        guard var artifact = try store.loadArtifact(artifactID) else {
            throw ArtifactError.unavailable(artifactID)
        }
        artifact.hiddenAt = try store.setArtifactHidden(artifactID, hidden: isHidden)
        return artifact
    }

    func deleteArtifact(_ artifactID: String) throws {
        let store = try notebookFilesKnowledgeStore()
        guard let artifact = try store.loadArtifact(artifactID) else { return }
        try store.requireSpaceDeletion(.artifact, artifactID)
        let directory = try artifactDirectoryURL(artifactID: artifact.id, createIfNeeded: false)
        // An audio overview's carrier goes with it, in the store's own
        // transaction (`KnowledgeStore.deleteArtifactRecord`); its search rows
        // go here, as an explainer's do with its source.
        let carrierID = GeneratedAudioOverview.carrierSourceID(artifactID: artifactID)
        let hadCarrier = try store.loadSourceWithoutContent(carrierID) != nil
        try store.deleteArtifactRecord(artifactID)
        if hadCarrier {
            removeFromSearchIndexes(carrierID)
        }
        invalidateArtifactContext(for: artifact.linkedNotebookIDs)
        discardArtifactDirectory(at: directory)
        // Deleted for good: this Mac's versions of the page go too.
        store.pageVersionHistory?.removeHistory(of: artifactID)
    }

    /// A notebook's audio overview: its hidden carrier source with the
    /// script, then its Artifact — kind `.audioOverview`, homed on the
    /// notebook, grounded on the sources it was written from, with the recipe
    /// as its body — under the id the caller reserved. A failed save leaves
    /// neither behind. An overview is the author's own: it is made in their
    /// own notebooks, and it does not follow a shared notebook into a team
    /// (`KnowledgeStore.teamNotebooksAwaitingDoc`), since its audio lives on a
    /// carrier in the author's library.
    func saveAudioOverview(
        artifactID: String,
        title rawTitle: String,
        notebookID: String,
        sourceIDs: [String],
        markdown: String,
        carrier: StudioArticle
    ) throws -> ArtifactRecord {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ArtifactError.invalidTitle }
        let data = Data(markdown.utf8)
        guard data.count <= ArtifactRecord.markdownByteLimit else {
            throw NotebookMarkdownFileError.tooLarge(maxBytes: ArtifactRecord.markdownByteLimit)
        }
        let store = try notebookFilesKnowledgeStore()
        guard let notebook = try store.loadLearningGoal(notebookID), notebook.isNotebook else {
            throw ArtifactError.invalidNotebook(notebookID)
        }
        guard notebook.teamID == nil else {
            throw KnowledgeStoreError.invalidData("Audio overviews are made in your own notebooks; \(notebook.title) is a team's.")
        }
        guard try store.loadArtifact(artifactID) == nil else {
            throw KnowledgeStoreError.invalidData("An artifact with id \(artifactID) already exists.")
        }
        guard carrier.id == GeneratedAudioOverview.carrierSourceID(artifactID: artifactID) else {
            throw KnowledgeStoreError.invalidData("The audio overview's script source does not belong to \(artifactID).")
        }

        try saveSource(carrier, syncImmediately: true)
        let now = Date()
        var seen = Set<String>()
        let artifact = ArtifactRecord(
            id: artifactID,
            title: title,
            homeNotebookID: notebookID,
            linkedNotebookIDs: [notebookID],
            kind: .audioOverview,
            sourceIDs: sourceIDs.filter { !$0.isEmpty && seen.insert($0).inserted },
            createdAt: now,
            updatedAt: now
        )
        do {
            let directory = try artifactDirectoryURL(artifactID: artifact.id, createIfNeeded: true)
            do {
                try data.write(to: directory.appendingPathComponent(Self.artifactDocumentName), options: .atomic)
                try store.saveArtifactRecord(artifact)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        } catch {
            try? deleteSource(carrier.id)
            throw error
        }
        invalidateArtifactContext(for: artifact.linkedNotebookIDs)
        return artifact
    }

    func artifactFileURL(_ artifactID: String) throws -> URL {
        try artifactDocumentURL(artifactID: artifactID)
    }

    func importArtifactImage(_ sourceURL: URL, artifactID: String) throws -> ArtifactAttachment {
        if let artifact = try notebookFilesKnowledgeStore().loadArtifact(artifactID), artifact.isLinked {
            throw ArtifactError.linkedDocReadOnly(artifact.title)
        }
        guard let type = UTType(filenameExtension: sourceURL.pathExtension),
              type.conforms(to: .image) else {
            throw ArtifactError.unsupportedAttachment
        }
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        let token = try storeArtifactImage(
            data,
            fileExtension: type.preferredFilenameExtension ?? sourceURL.pathExtension.lowercased(),
            artifactID: artifactID
        )
        let alt = sourceURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ArtifactAttachment(
            id: token,
            token: token,
            altText: alt.isEmpty ? "Image" : alt
        )
    }

    /// A picture a model drew for the doc (Docs → **Generate image**), kept in
    /// its Attachments the way `importArtifactImage` keeps a file the writer
    /// chose. `mediaType` is the type the drawing came back as; one that is not
    /// an image type a file can be named for is refused, saying so, rather than
    /// guessed.
    /// Returns the attachment and the data URL the editor draws it from.
    func storeGeneratedArtifactImage(
        _ data: Data,
        mediaType: String,
        altText: String,
        artifactID: String
    ) throws -> (attachment: ArtifactAttachment, dataURL: String) {
        if let artifact = try notebookFilesKnowledgeStore().loadArtifact(artifactID), artifact.isLinked {
            throw ArtifactError.linkedDocReadOnly(artifact.title)
        }
        let normalizedType = mediaType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let type = UTType(mimeType: normalizedType),
              type.conforms(to: .image),
              let fileExtension = type.preferredFilenameExtension else {
            throw KnowledgeStoreError.invalidData("The model returned a “\(normalizedType)” file, which a page cannot keep as a picture.")
        }
        let token = try storeArtifactImage(data, fileExtension: fileExtension, artifactID: artifactID)
        return (
            ArtifactAttachment(id: token, token: token, altText: altText),
            "data:\(normalizedType);base64,\(data.base64EncodedString())"
        )
    }

    /// A file the writer chose to attach to the page for download (`/file`),
    /// kept in the doc's Attachments beside its pictures: `<uuid>.<extension>`,
    /// the extension lowercased and cleaned of anything a file name could not
    /// hold, `bin` for none. Any kind of file, up to
    /// `ArtifactFileAttachment.maxBytes`; a larger one is refused, never cut.
    /// Refused for a linked page, as a picture is.
    func importArtifactFile(_ sourceURL: URL, artifactID: String) throws -> ArtifactFileAttachment {
        if let artifact = try notebookFilesKnowledgeStore().loadArtifact(artifactID), artifact.isLinked {
            throw ArtifactError.linkedDocReadOnly(artifact.title)
        }
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw KnowledgeStoreError.invalidData("A folder cannot be attached to a page. Choose a file, or compress the folder first.")
        }
        // Checked before the file is read, so a huge one is never pulled into memory.
        if let size = values.fileSize, size > ArtifactFileAttachment.maxBytes {
            throw ArtifactError.fileTooLarge(maxMegabytes: ArtifactFileAttachment.maxMegabytes)
        }
        let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        guard !data.isEmpty else {
            throw KnowledgeStoreError.invalidData("“\(sourceURL.lastPathComponent)” is empty, so there is nothing to attach.")
        }
        let token = try storeArtifactAttachment(
            data,
            fileExtension: ArtifactFileAttachment.sanitizedExtension(sourceURL.pathExtension),
            artifactID: artifactID,
            maxBytes: ArtifactFileAttachment.maxBytes,
            tooLarge: .fileTooLarge(maxMegabytes: ArtifactFileAttachment.maxMegabytes)
        )
        return ArtifactFileAttachment(token: token, name: sourceURL.lastPathComponent, size: data.count)
    }

    /// Where a page's attached file is kept, for the writer to save a copy of.
    /// Only a token this app wrote (`<uuid>.<extension>`) names a file; anything
    /// else — a separator, `..`, a name of someone's choosing — is refused, so a
    /// link in a page can never reach outside its Attachments folder.
    func artifactAttachmentFileURL(artifactID: String, token: String) throws -> URL {
        guard ArtifactFileAttachment.isStoredToken(token) else {
            throw KnowledgeStoreError.invalidData("That link does not name a file attached to this page.")
        }
        let url = try artifactDirectoryURL(artifactID: artifactID, createIfNeeded: false)
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent(token, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ArtifactBodyPackageError.missingAttachment(token)
        }
        return url
    }

    /// Keeps picture bytes in the doc's Attachments and returns the token a
    /// `foreverlm://attachment/<token>` line names them by.
    private func storeArtifactImage(_ data: Data, fileExtension: String, artifactID: String) throws -> String {
        try storeArtifactAttachment(
            data,
            fileExtension: fileExtension,
            artifactID: artifactID,
            maxBytes: 20 * 1_024 * 1_024,
            tooLarge: .attachmentTooLarge
        )
    }

    /// Keeps bytes in the doc's Attachments and returns the token a
    /// `foreverlm://attachment/<token>` link names them by. `maxBytes` is what
    /// this kind of attachment may weigh, and `tooLarge` the error that says so.
    private func storeArtifactAttachment(
        _ data: Data,
        fileExtension: String,
        artifactID: String,
        maxBytes: Int,
        tooLarge: ArtifactError
    ) throws -> String {
        guard !data.isEmpty, data.count <= maxBytes else {
            throw tooLarge
        }
        let token = "\(UUID().uuidString.lowercased()).\(fileExtension)"
        let directory = try artifactDirectoryURL(artifactID: artifactID, createIfNeeded: true)
            .appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(token), options: .atomic)
        return token
    }

    #if os(macOS)
    // MARK: Pictures a doc keeps

    /// Renders every picture line of `markdown` that names a picture by its
    /// `foreverlm://image/…` address — a source's figure, page or slide, a frame
    /// of a video, a picture a chat drew or was given — as this Mac holds it.
    ///
    /// Such an address is drawn from this Mac's own files, which a doc cannot
    /// reach: the editor draws only the pictures in a doc's Attachments, and
    /// those are also what travel with its body to the other Mac, Web Studio, a
    /// team's copy and an export. `keepDocPictures` then stores what this
    /// renders as the doc's own attachments. The product owner (2026-09-29), of a
    /// walkthrough Doc whose 25 slides and a white paper's Doc whose 3 figures
    /// all drew as a broken-picture box: the assistant had pasted
    /// show_source_image's lines into them, as that tool tells it to.
    func renderDocPictures(in markdown: String) async -> DocPictureRendering {
        var rendering = DocPictureRendering()
        for address in DocPictureLines.addresses(in: markdown) where rendering.pictures[address] == nil {
            switch await renderDocPicture(address) {
            case .success(let picture): rendering.pictures[address] = picture
            case .failure(let failure): rendering.failures.append(failure)
            }
        }
        return rendering
    }

    /// Stores each rendered picture as one of the doc's attachments and points
    /// every line that names it there, keeping the line's description. A line
    /// whose picture was not rendered is left as written.
    func keepDocPictures(_ pictures: [String: SourceImageCatalog.RenderedImage], in markdown: String, artifactID: String) throws -> (markdown: String, kept: Int) {
        guard !pictures.isEmpty else { return (markdown, 0) }
        if let artifact = try notebookFilesKnowledgeStore().loadArtifact(artifactID), artifact.isLinked {
            throw ArtifactError.linkedDocReadOnly(artifact.title)
        }
        var tokens: [String: String] = [:]
        for (address, picture) in pictures {
            let fileExtension = UTType(mimeType: picture.mediaType)?.preferredFilenameExtension ?? "jpg"
            tokens[address] = try storeArtifactImage(picture.data, fileExtension: fileExtension, artifactID: artifactID)
        }
        return DocPictureLines.replacingAddresses(in: markdown) { address in
            tokens[address].map { DocPictureLines.attachmentPrefix + $0 }
        }
    }

    private func renderDocPicture(_ address: String) async -> Result<SourceImageCatalog.RenderedImage, DocPictureFailure> {
        func failure(_ reason: String) -> Result<SourceImageCatalog.RenderedImage, DocPictureFailure> {
            .failure(DocPictureFailure(address: address, reason: reason))
        }
        if let generated = GeneratedImageReference(urlString: address) {
            let stored = await Task.detached(priority: .userInitiated) {
                GeneratedImageStore.readShown(id: generated.id)
            }.value
            guard let stored else { return failure("no picture with this id is in this Mac's image store") }
            return .success(.init(data: stored.image.data, mediaType: stored.image.mediaType))
        }
        if let attached = AttachedImageReference(urlString: address) {
            let stored = await Task.detached(priority: .userInitiated) {
                AttachedImageStore.read(id: attached.id)
            }.value
            guard let stored else { return failure("the picture attached to that chat is not on this Mac") }
            return .success(.init(data: stored.data, mediaType: stored.mediaType))
        }
        guard let requested = SourceImageReference(urlString: address) else {
            return failure("this is not a picture address ForeverLM reads")
        }
        let article: StudioArticle
        do {
            guard let sourceID = try resolveSourceID(forLinkToken: requested.sourceID),
                  let found = try loadPersistedSources(ids: [sourceID]).first else {
                return failure("no source \(requested.sourceID) is in this library")
            }
            article = found
        } catch {
            return failure(error.localizedDescription)
        }
        let reference = SourceImageReference(sourceID: article.id, location: requested.location, crop: requested.crop)
        switch reference.location {
        case .moment(let seconds):
            return await renderedMoment(of: article, seconds: seconds, crop: reference.crop, address: address)
        case .slide(let index):
            guard let content = await loadSourceContent(article.id),
                  let frame = SourceImageCatalog.slideFrame(for: reference, in: content) else {
                return failure("‘\(article.title)’ has no slide \(index) captured")
            }
            let rendered = await Task.detached(priority: .userInitiated) {
                SourceImageCatalog.renderSlideFrame(frame, crop: reference.crop)
            }.value
            if let rendered { return .success(rendered) }
            // The deck was captured on the other Mac and only its listing
            // synced here. Its frame is taken again under its own path
            // (`SlideFrameRestorer`), where every reader of the block finds it.
            if await SlideFrameRestorer.shared.restore([frame], of: article, storage: self),
               let restored = await Task.detached(priority: .userInitiated, operation: {
                   SourceImageCatalog.renderSlideFrame(frame, crop: reference.crop)
               }).value {
                return .success(restored)
            }
            // Failing that, the slide is the frame of the video at the second
            // it was captured, so that moment is captured instead.
            guard let seconds = SourceImageReference.SlideFramePath(pathOrURL: frame.imagePath)?.fileNameSeconds
                ?? frame.timeSeconds.map({ Int($0.rounded()) }) else {
                return failure("slide \(index) of ‘\(article.title)’ is not on this Mac")
            }
            return await renderedMoment(
                of: article,
                seconds: seconds,
                crop: reference.crop,
                address: address,
                reasonPrefix: "slide \(index) is not on this Mac, and "
            )
        case .page, .image:
            guard let path = article.resolvedFileLocation else {
                return failure("‘\(article.title)’ has no file on this Mac")
            }
            let rendered = await Task.detached(priority: .userInitiated) {
                SourceImageCatalog.render(reference, filePath: path)
            }.value
            guard let rendered else { return failure("‘\(article.title)’ has no such picture") }
            return .success(rendered)
        }
    }

    /// The frame of a video or recording at `seconds`, captured now unless
    /// this Mac already holds it.
    private func renderedMoment(
        of article: StudioArticle,
        seconds: Int,
        crop: PaperFigureRect?,
        address: String,
        reasonPrefix: String = ""
    ) async -> Result<SourceImageCatalog.RenderedImage, DocPictureFailure> {
        let when = SlideFrameExtraction.displayTime(Double(seconds))
        do {
            try await ReviewSessionManager.ensureVideoMoment(article: article, seconds: seconds, storage: self)
        } catch {
            return .failure(DocPictureFailure(
                address: address,
                reason: reasonPrefix + "the frame at \(when) of ‘\(article.title)’ could not be captured: \(error.localizedDescription)"
            ))
        }
        let moment = SourceImageReference(sourceID: article.id, location: .moment(seconds), crop: crop)
        let rendered = await Task.detached(priority: .userInitiated) {
            SourceImageCatalog.renderMoment(moment)
        }.value
        guard let rendered else {
            return .failure(DocPictureFailure(
                address: address,
                reason: reasonPrefix + "the frame at \(when) of ‘\(article.title)’ could not be read back"
            ))
        }
        return .success(rendered)
    }
    #endif

    func artifactAttachmentDataURLs(
        _ artifactID: String,
        markdown: String
    ) throws -> [String: String] {
        let tokens = try ArtifactBodyPackage.referencedAttachmentTokens(markdown)
        guard !tokens.isEmpty else { return [:] }
        let directory = try artifactDirectoryURL(artifactID: artifactID, createIfNeeded: false)
            .appendingPathComponent("Attachments", isDirectory: true)
        var values: [String: String] = [:]
        for token in tokens {
            let url = directory.appendingPathComponent(token)
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard !data.isEmpty else {
                throw ArtifactBodyPackageError.missingAttachment(token)
            }
            let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            values[token] = "data:\(mimeType);base64,\(data.base64EncodedString())"
        }
        return values
    }

    func artifactComments(_ artifactID: String) throws -> [ArtifactCommentRecord] {
        try notebookFilesKnowledgeStore().loadArtifactComments(artifactID)
    }

    /// The conversations this doc's passages started, oldest first.
    func artifactChatLinks(_ artifactID: String) throws -> [ArtifactChatLinkRecord] {
        try notebookFilesKnowledgeStore().artifactChatLinks(artifactID: artifactID)
    }

    /// The doc passages this conversation was opened on, oldest first.
    func chatLinksForSession(_ sessionID: String) throws -> [ArtifactChatLinkRecord] {
        try notebookFilesKnowledgeStore().artifactChatLinks(sessionID: sessionID)
    }

    /// Records that a chat began on a passage of a doc. The doc's current body
    /// revision is what the anchor is bound to, so the offsets are only ever
    /// read back against the text they were measured in.
    @discardableResult
    func linkArtifactPassageToChat(
        artifactID: String,
        sessionID: String,
        selectionStart: Int,
        selectionEnd: Int,
        quote: String,
        sectionTitle: String,
        anchorRevision: String? = nil
    ) throws -> ArtifactChatLinkRecord? {
        let store = try notebookFilesKnowledgeStore()
        let trimmedQuote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuote.isEmpty else { return nil }
        // A doc whose body has never been packaged has no revision to bind to.
        // The link is still worth keeping — the quote is the part that lasts —
        // so it lands with an empty revision, which reads as "position unknown".
        let revision: String
        if let anchorRevision {
            revision = anchorRevision
        } else {
            revision = (try? store.loadArtifactBodyPackageForSync(artifactID)?.revision) ?? ""
        }
        return try store.linkArtifactPassageToChat(
            artifactID: artifactID,
            sessionID: sessionID,
            anchorRevision: revision,
            anchorStart: selectionStart,
            anchorEnd: selectionEnd,
            anchorQuote: trimmedQuote,
            sectionTitle: sectionTitle
        )
    }

    func deleteArtifactChatLink(_ linkID: String) throws {
        try notebookFilesKnowledgeStore().deleteArtifactChatLink(linkID)
    }

    func addArtifactComment(
        artifactID: String,
        parentCommentID: String?,
        authorRecordName: String,
        authorDisplayName: String,
        body: String,
        selection: ArtifactEditorSelection
    ) throws -> ArtifactCommentRecord {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ArtifactCommentError.emptyBody }
        guard selection.hasText else { throw ArtifactCommentError.missingSelection }
        guard let bodyRevision = try notebookFilesKnowledgeStore()
            .loadArtifactBodyPackageForSync(artifactID)?.revision else {
            throw ArtifactCollaborationError.missingBody
        }
        let now = Date()
        let comment = ArtifactCommentRecord(
            id: UUID().uuidString.lowercased(),
            artifactID: artifactID,
            parentCommentID: parentCommentID,
            authorRecordName: authorRecordName,
            authorDisplayName: authorDisplayName,
            body: text,
            anchorRevision: bodyRevision,
            anchorStart: selection.from,
            anchorEnd: selection.to,
            anchorQuote: selection.text,
            createdAt: now,
            updatedAt: now,
            resolvedAt: nil
        )
        try notebookFilesKnowledgeStore().saveArtifactCommentRecord(comment)
        return comment
    }

    func setArtifactCommentResolved(_ commentID: String, resolved: Bool) throws {
        let store = try notebookFilesKnowledgeStore()
        guard var comment = try store.loadArtifactCommentForSync(commentID) else {
            throw ArtifactCommentError.unavailable
        }
        comment.resolvedAt = resolved ? Date() : nil
        comment.updatedAt = Date()
        try store.saveArtifactCommentRecord(comment)
    }

    func replyToArtifactComment(
        _ commentID: String,
        authorRecordName: String,
        authorDisplayName: String,
        body: String
    ) throws -> ArtifactCommentRecord {
        try notebookFilesKnowledgeStore().replyToArtifactComment(
            commentID,
            authorRecordName: authorRecordName,
            authorDisplayName: authorDisplayName,
            body: body
        )
    }

    func editArtifactComment(_ commentID: String, body: String) throws {
        try notebookFilesKnowledgeStore().editArtifactComment(commentID, body: body)
    }

    func deleteArtifactComment(_ commentID: String) throws {
        try notebookFilesKnowledgeStore().deleteArtifactComment(commentID)
    }

    func deleteArtifactCommentThread(_ commentID: String) throws {
        try notebookFilesKnowledgeStore().deleteArtifactCommentThread(commentID)
    }

    func notebookArtifactContext(notebookID: String) throws -> String {
        // An audio overview's body is only its recipe; its script is a
        // spoken retelling of sources the chat reads for itself.
        let store = try notebookFilesKnowledgeStore()
        let artifacts = try loadArtifacts(notebookID: notebookID).filter { try !store.isAudioOverview($0) }
        guard !artifacts.isEmpty else { return "" }
        var blocks: [String] = ["## Linked artifacts"]
        var remaining = Self.notebookMaterialContextCharacterLimit
        for artifact in artifacts {
            guard remaining > 0 else { break }
            let snapshot = try artifactMarkdown(artifact.id)
            // A linked doc's body is a text export, so the reader is told where
            // the document itself lives and that this copy is not editable.
            let heading = artifact.linkedURL.map {
                "### \(artifact.title)\n\n\(artifact.linkedKind?.label ?? "Linked page"), read-only text copy of \($0)"
            } ?? "### \(artifact.title)"
            let allowance = max(0, remaining - heading.count - 2)
            let body = String(snapshot.markdown.prefix(allowance))
            blocks.append("\(heading)\n\n\(body)")
            remaining -= heading.count + body.count + 2
        }
        return blocks.joined(separator: "\n\n")
    }

    func artifactDirectoryURL(artifactID: String, createIfNeeded: Bool) throws -> URL {
        guard !artifactID.isEmpty,
              !artifactID.contains("/"),
              !artifactID.contains("..") else {
            throw KnowledgeStoreError.invalidData("Invalid artifact identifier.")
        }
        let directory = libraryRootURL
            .appendingPathComponent(Self.artifactDirectoryName, isDirectory: true)
            .appendingPathComponent(artifactID, isDirectory: true)
        if createIfNeeded {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private func artifactDocumentURL(artifactID: String) throws -> URL {
        let canonical = try canonicalArtifactDocumentURL(
            artifactID: artifactID,
            createDirectoryIfNeeded: false
        )
        if Self.artifactFileOrPlaceholderExists(canonical) { return canonical }

        let relative = "\(Self.artifactDirectoryName)/\(artifactID)/\(Self.artifactDocumentName)"
        for root in Self.legacyICloudContentRoots {
            let candidate = root.appendingPathComponent(relative, isDirectory: false)
            if Self.artifactFileOrPlaceholderExists(candidate) { return candidate }
        }
        return canonical
    }

    private func canonicalArtifactDocumentURL(
        artifactID: String,
        createDirectoryIfNeeded: Bool
    ) throws -> URL {
        try artifactDirectoryURL(
            artifactID: artifactID,
            createIfNeeded: createDirectoryIfNeeded
        ).appendingPathComponent(Self.artifactDocumentName)
    }

    private static func artifactFileOrPlaceholderExists(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) { return true }
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        return fileManager.fileExists(atPath: placeholder.path)
    }

    enum ArtifactReadiness: Equatable {
        case available
        case downloading
        case missing
    }

    static func artifactReadiness(
        fileExists: Bool,
        isDataless: Bool,
        isUbiquitousNotDownloaded: Bool,
        placeholderExists: Bool
    ) -> ArtifactReadiness {
        if fileExists {
            return (isDataless || isUbiquitousNotDownloaded) ? .downloading : .available
        }
        return placeholderExists ? .downloading : .missing
    }

    private func prepareArtifactForReading(_ url: URL) throws -> ArtifactReadiness {
        let fileManager = FileManager.default
        let fileExists = fileManager.fileExists(atPath: url.path)
        var isUbiquitousNotDownloaded = false
        if fileExists {
            var refreshedURL = url
            refreshedURL.removeAllCachedResourceValues()
            let values = try? refreshedURL.resourceValues(
                forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
            )
            isUbiquitousNotDownloaded = values?.isUbiquitousItem == true
                && values?.ubiquitousItemDownloadingStatus == .notDownloaded
        }
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        let placeholderExists = fileManager.fileExists(atPath: placeholder.path)
        let readiness = Self.artifactReadiness(
            fileExists: fileExists,
            isDataless: Self.artifactIsDatalessFile(url),
            isUbiquitousNotDownloaded: isUbiquitousNotDownloaded,
            placeholderExists: placeholderExists
        )
        if readiness == .downloading {
            try fileManager.startDownloadingUbiquitousItem(at: fileExists ? url : placeholder)
        }
        return readiness
    }

    private nonisolated static func artifactIsDatalessFile(_ url: URL) -> Bool {
        #if os(macOS)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return false }
        if metadata.st_flags & UInt32(SF_DATALESS) != 0 { return true }
        let isCloudManagedPath = url.path.contains("/Library/Mobile Documents/")
            || url.path.contains("/Library/CloudStorage/")
        return isCloudManagedPath && metadata.st_size > 0 && metadata.st_blocks == 0
        #else
        return false
        #endif
    }

    private func discardArtifactDirectory(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        #if os(macOS)
        if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil { return }
        #endif
        try? FileManager.default.removeItem(at: url)
    }

    private func invalidateArtifactContext(for notebookIDs: [String]) {
        for notebookID in Set(notebookIDs) {
            notebookMaterialContextCache[notebookID] = nil
        }
    }

    private nonisolated static func artifactRevision(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

#if os(macOS)
/// A picture line a doc could not keep, and why, in words a writer can act on.
struct DocPictureFailure: Error, Equatable, Sendable {
    let address: String
    let reason: String
}

/// What `renderDocPictures` made of a body: each address it rendered, and
/// each it could not.
struct DocPictureRendering: Sendable {
    var pictures: [String: SourceImageCatalog.RenderedImage] = [:]
    var failures: [DocPictureFailure] = []
}
#endif

/// A file attached to a page for download: the token its link names it by, the
/// name the writer sees, and its size in bytes. The page holds
/// `[name](foreverlm://attachment/<token>)`; the bytes live in the page's
/// Attachments folder and travel with it.
struct ArtifactFileAttachment: Equatable, Sendable {
    let token: String
    let name: String
    let size: Int

    static let maxMegabytes = 25
    static let maxBytes = maxMegabytes * 1_024 * 1_024

    /// A file extension as a stored token may carry it: lowercase letters and
    /// digits only, at most 16 of them, `bin` when nothing is left.
    static func sanitizedExtension(_ pathExtension: String) -> String {
        let cleaned = pathExtension.lowercased().unicodeScalars
            .filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
        let text = String(String.UnicodeScalarView(cleaned.prefix(16)))
        return text.isEmpty ? "bin" : text
    }

    /// Whether `token` is one this app writes: a UUID, a dot, an extension of
    /// letters and digits. No separator, no `..`, no trailing newline, nothing
    /// else (`\z`, not `$`, which would let one newline through).
    static func isStoredToken(_ token: String) -> Bool {
        token.range(
            of: #"\A[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.[A-Za-z0-9]{1,16}\z"#,
            options: .regularExpression
        ) != nil
    }

    /// The name the save panel offers for a file link: the name the page shows,
    /// or — for a link whose text is the token itself, as one with no name is —
    /// the page's title with the token's extension. A slash or colon is a dash.
    static func suggestedFileName(linkName: String, token: String, pageTitle: String) -> String {
        func safe(_ text: String) -> String {
            text.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let name = safe(linkName)
        if !name.isEmpty, name != token { return name }
        let fileExtension = (token as NSString).pathExtension
        let title = safe(pageTitle)
        let stem = title.isEmpty ? "Attachment" : title
        return fileExtension.isEmpty ? stem : "\(stem).\(fileExtension)"
    }
}

/// The picture lines of a doc's Markdown that name a picture by its
/// `foreverlm://image/…` address rather than as one of the doc's attachments.
/// An address inside code — a fenced block or an inline span — is text about
/// the address, not a picture, and is left alone.
enum DocPictureLines {
    static let attachmentPrefix = "foreverlm://attachment/"

    /// `![description](<address> "title")`; group 2 is the address.
    // swiftlint:disable:next force_try
    private static let picture = try! NSRegularExpression(
        pattern: #"!\[([^\]\n]*)\]\(\s*<?(foreverlm://image/[^\s)>]+)"#,
        options: [.caseInsensitive]
    )
    // swiftlint:disable:next force_try
    private static let fencedCode = try! NSRegularExpression(
        pattern: #"^ {0,3}(`{3,}|~{3,})[^\n]*\n.*?(?:^ {0,3}\1[^\n]*$|\z)"#,
        options: [.anchorsMatchLines, .dotMatchesLineSeparators]
    )
    // swiftlint:disable:next force_try
    private static let inlineCode = try! NSRegularExpression(pattern: #"`[^`\n]+`"#)

    /// Every address a picture line names, once each, in order.
    static func addresses(in markdown: String) -> [String] {
        var seen = Set<String>()
        return addressRanges(in: markdown).compactMap { range in
            let address = (markdown as NSString).substring(with: range)
            return seen.insert(address).inserted ? address : nil
        }
    }

    /// The body with each picture line's address replaced by what
    /// `replacement` returns for it — nil leaves that line as written — and
    /// how many lines changed.
    static func replacingAddresses(in markdown: String, with replacement: (String) -> String?) -> (markdown: String, kept: Int) {
        let text = NSMutableString(string: markdown)
        var kept = 0
        for range in addressRanges(in: markdown).reversed() {
            guard let new = replacement(text.substring(with: range)) else { continue }
            text.replaceCharacters(in: range, with: new)
            kept += 1
        }
        return (text as String, kept)
    }

    private static func addressRanges(in markdown: String) -> [NSRange] {
        let whole = NSRange(location: 0, length: (markdown as NSString).length)
        let code = fencedCode.matches(in: markdown, range: whole).map(\.range)
            + inlineCode.matches(in: markdown, range: whole).map(\.range)
        return picture.matches(in: markdown, range: whole).compactMap { match in
            guard !code.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { return nil }
            return match.range(at: 2)
        }
    }
}

/// What each Markdown Doc's body links, remembered by the Doc's `updatedAt` so
/// "Linked in" on a sidebar row never rereads a Doc that has not changed. In
/// memory only — the answer is derivable from the Doc at any time, and a
/// database index would be a second copy of the truth to keep right.
final class SourceArtifactCitationCache: @unchecked Sendable {
    struct Entry: Equatable, Sendable {
        let updatedAt: Date
        var grounded: Set<String>
        var cited: Set<String>
    }

    static let shared = SourceArtifactCitationCache()
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func entry(for artifactID: String, updatedAt: Date) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[artifactID], entry.updatedAt == updatedAt else { return nil }
        return entry
    }

    func store(_ entry: Entry, for artifactID: String) {
        lock.lock(); defer { lock.unlock() }
        entries[artifactID] = entry
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }
}
