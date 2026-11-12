import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Sites: HTML kept in the library

/// `save_site`, `read_site_file` and `replace_site_text`: a folder of HTML,
/// CSS, JavaScript and images becomes a site in the learner's library.
///
/// The product owner (2026-09-09), after a chat asked to "make a site" produced a Doc:
/// "it should also be able to make an arbitrary html site". A site is the
/// author's files served as written, scripts included. Those
/// files live in the library — under the record's folder, synced through the
/// learner's own iCloud inside the Artifact's body asset, and served in the
/// app from `foreverlm-site://<id>/` under a CSP sandbox (the product owner:
/// "data should stay in the user's icloud in general"). The record is a
/// linked page under Sites, like a linked Codex site or Claude artifact: it
/// opens as itself, keeps a text copy for chat, and is read-only here.
///
/// A site is never put on the web. Publishing a copy to sites.foreverlm.com
/// was retired on 2026-10-10 (the product owner: "maybe we shouldn't quite
/// have sites that can be published to the web"): a learner who wants a
/// public link makes a Claude artifact and links it with `link_page`.
///
/// The files can also come from a GitHub repository, read as the learner
/// through the read-only GitHub plugin: ForeverLM reads *from* a repo and
/// records the commit; it never writes *to* one (docs/github-plugin.md).
extension MCPDataStore {

    /// A repository read, as the tests inject it: repository, path, ref → the
    /// files under that path (text only), where they came from, and what was
    /// skipped with the reason.
    typealias SiteRepositoryReader = @Sendable (String, String?, String?) async throws -> SiteRepositoryRead

    struct SiteRepositoryRead: Sendable {
        var files: [SiteFile]
        var source: SiteRepositorySource
        var skipped: [String]
    }

    /// How many files a repository read will fetch one by one before it asks
    /// for a narrower path.
    private static let maxRepositoryFiles = LocalSite.maxFiles

    /// What one save of a site's files did.
    struct SiteSave {
        var artifact: ArtifactRecord
        var created: Bool
        var files: [SiteFile]
        var kept: [String] = []
        var removed: [String] = []
        var skipped: [String] = []
        var repositorySource: SiteRepositorySource?
        var sourceCards = SiteSourceCards.Attachment()
        var teamCopyIDs: [String] = []
    }

    // MARK: save_site

    /// Keep a site in the library: the files are written under the record's
    /// folder and sync through the learner's own iCloud with the record.
    func saveSite(
        site: String?,
        title: String?,
        html: String?,
        files rawFiles: [Any]?,
        repository: String?,
        repositoryPath: String?,
        ref: String?,
        removeFiles: [String] = [],
        replaceAll: Bool = false,
        homeNotebookID: String?,
        notebookIDs: [String],
        readRepository: SiteRepositoryReader? = nil
    ) async throws -> String {
        let saved = try await saveSiteFiles(
            site: site, title: title, html: html, files: rawFiles,
            repository: repository, repositoryPath: repositoryPath, ref: ref,
            removeFiles: removeFiles, replaceAll: replaceAll,
            homeNotebookID: homeNotebookID, notebookIDs: notebookIDs,
            readRepository: readRepository
        )
        var payload = savePayload(saved)
        payload["message"] = saveMessage(saved, noun: "site", section: "Sites", tool: "save_site")
        return try jsonString(payload)
    }

    /// The save itself, shared by `save_site` and `replace_site_text`.
    func saveSiteFiles(
        site: String?,
        title: String?,
        html: String?,
        files rawFiles: [Any]?,
        repository: String?,
        repositoryPath: String?,
        ref: String?,
        removeFiles: [String],
        replaceAll: Bool,
        homeNotebookID: String?,
        notebookIDs: [String],
        readRepository: SiteRepositoryReader?,
        allowAnimation: Bool = false
    ) async throws -> SiteSave {
        var existing: ArtifactRecord? = nil
        if let handle = Self.trimmedOrNil(site) {
            guard let found = try await existingSiteArtifact(handle: handle) else {
                throw MCPError.invalidInput("No site of yours is named \(handle). Pass the site_id from save_site or the Sites list, or omit site to make a new one.")
            }
            guard allowAnimation || !found.isAnimation else {
                throw MCPError.invalidInput("‘\(found.title)’ is an animation, not a Site. Change it with save_animation.")
            }
            existing = found
        }

        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression) ?? ""
        guard !trimmedTitle.isEmpty || existing?.title.isEmpty == false else {
            throw MCPError.invalidInput("title is required for a new site: what the tab and the Sites list call it.")
        }
        let siteTitle = trimmedTitle.isEmpty ? existing!.title : trimmedTitle

        // The files: inline, or read from a repository. Never both. An
        // inline update carries only the files that change; the stored files
        // it does not name are kept from the library, unless `replace_all`.
        // ForeverLM's own generated files are never kept: `SiteSourceCards`
        // remakes them from the pages on every save.
        let hasInline = (html?.isEmpty == false) || !(rawFiles ?? []).isEmpty
        let repositoryName = repository?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var kept: [String] = []
        var removed: [String] = []
        var skipped: [String] = []
        var repositorySource: SiteRepositorySource? = nil
        var siteFiles: [SiteFile]
        if !repositoryName.isEmpty {
            guard !hasInline else {
                throw MCPError.invalidInput("Pass either the files (html, files) or a repository to read them from, not both.")
            }
            let reader = readRepository ?? { try await self.readSiteFilesFromGitHub(repository: $0, path: $1, ref: $2) }
            let read = try await reader(repositoryName, Self.trimmedOrNil(repositoryPath), Self.trimmedOrNil(ref))
            siteFiles = read.files
            repositorySource = read.source
            skipped = read.skipped
            guard siteFiles.contains(where: { $0.path == LocalSite.entryFile }) else {
                let place = read.source.path.map { "\($0) in " } ?? ""
                throw MCPError.invalidInput("No \(LocalSite.entryFile) at the root of \(place)\(repositoryName)\(read.source.ref.map { " at \($0)" } ?? ""). Pass repository_path pointing at the folder that holds the site's \(LocalSite.entryFile).\(skipped.isEmpty ? "" : " Skipped: \(skipped.joined(separator: "; ")).")")
            }
        } else {
            guard hasInline else {
                throw MCPError.invalidInput("Pass the site's files: html for a one-page site, files for several, or repository to read them from GitHub.")
            }
            var stored: [SiteFile] = []
            if let existing { stored = try await notebookFileStorage.localSiteFiles(artifactID: existing.id) ?? [] }
            let merging = existing != nil && !replaceAll
            siteFiles = try Self.inlineSiteFiles(html: html, files: rawFiles, requireEntry: !merging)
            if merging {
                let merge = try Self.mergeStoredSiteFiles(into: &siteFiles, stored: stored, removeFiles: removeFiles)
                kept = merge.kept
                removed = merge.removed
                guard siteFiles.contains(where: { $0.path == LocalSite.entryFile }) else {
                    throw MCPError.invalidInput("The site would have no \(LocalSite.entryFile): pass one as html or as a file named index.html, or leave the stored one out of remove_files.")
                }
            }
        }

        let filing = try await pageFiling(existing: existing, homeNotebookID: homeNotebookID, notebookIDs: notebookIDs)
        var teamID = existing?.teamID
        if teamID == nil, let existing {
            teamID = try await notebookFileStorage.teamsHoldingArtifact(existing.id).first?.id
        }
        let siteTeamID = teamID ?? filing.teamNotebookIDs.keys.sorted().first
        let sourceCards = await SiteSourceCards.attach(
            to: &siteFiles,
            lookup: { token in await self.siteSourceCard(forToken: token) },
            lookupAddresses: { addresses in
                await self.siteSourceCards(forWebAddresses: addresses, teamID: siteTeamID)
            }
        )
        try Self.checkLocalSiteSize(siteFiles, noun: "site")

        let indexHTML = siteFiles.first(where: { $0.path == LocalSite.entryFile }).flatMap { String(data: $0.data, encoding: .utf8) } ?? ""
        let artifact: ArtifactRecord
        do {
            artifact = try await notebookFileStorage.saveLocalSite(
                artifactID: existing?.id,
                title: siteTitle,
                files: siteFiles,
                textCopy: LocalSite.visibleText(ofHTML: indexHTML),
                homeNotebookID: filing.homeNotebookID,
                linkedNotebookIDs: filing.linkedNotebookIDs
            )
        } catch let error as ArtifactError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        let teamCopyIDs = try await refreshTeamCopies(ofPage: artifact.id, previouslyIn: existing?.teamID, filing: filing)
        return SiteSave(
            artifact: artifact,
            created: existing == nil,
            files: siteFiles,
            kept: kept,
            removed: removed,
            skipped: skipped,
            repositorySource: repositorySource,
            sourceCards: sourceCards,
            teamCopyIDs: teamCopyIDs
        )
    }

    // MARK: read_site_file

    /// One file of a site in the library, or — with no path — the list of its
    /// files, so a chat about to change a site can see what it has without
    /// reading each file back.
    func readSiteFile(
        site: String,
        path rawPath: String?
    ) async throws -> String {
        let artifact = try await librarySite(site)
        let stored = (try await notebookFileStorage.localSiteFilePaths(artifactID: artifact.id) ?? []).filter { !SiteSourceCards.isGenerated($0) }
        let saveTool = artifact.isAnimation ? "save_animation" : "save_site"
        let handleKey = artifact.isAnimation ? "animation" : "site"
        guard let rawPath = Self.trimmedOrNil(rawPath) else {
            return try jsonString([
                "site": artifact.id,
                "url": artifact.linkedURL ?? "",
                "title": artifact.title,
                "files": stored.count,
                "file_paths": stored,
                "message": "‘\(artifact.title)’ has \(stored.count) file\(stored.count == 1 ? "" : "s") in the library. Pass path to read one. To change it, call \(saveTool) with \(handleKey) \"\(artifact.id)\" and only the files that change; the rest are kept.",
            ] as [String: Any])
        }
        guard let path = LocalSite.normalizePath(rawPath) else {
            throw MCPError.invalidInput("path must be a file path inside the site, such as index.html or css/site.css.")
        }
        guard let data = try await notebookFileStorage.readLocalSiteFile(artifactID: artifact.id, path: path) else {
            throw MCPError.invalidInput("‘\(artifact.title)’ has no file \(path). Its files: \(Self.pathList(stored)).")
        }
        var payload: [String: Any] = [
            "site": artifact.id,
            "path": path,
            "content_type": UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream",
            "bytes": data.count,
        ]
        if !SiteFile.looksBinary(data), let text = String(data: data, encoding: .utf8) {
            payload["content"] = text
        } else if data.count > LocalSite.maxInlineFileBytes {
            payload["note"] = "A binary file of \(data.count / 1_000_000) MB; not returned. A file under \(SiteSourceCards.folder)/ is ForeverLM's own, regenerated on every save."
        } else {
            payload["content_base64"] = data.base64EncodedString()
            payload["note"] = "A binary file; it is kept as it is when \(saveTool) is called without it."
        }
        return try jsonString(payload)
    }

    // MARK: replace_site_text

    /// One passage of a site changed in place: the app's **Change** action on
    /// a selection in an open Site, and the tool behind it. The passage is
    /// found in the page's source by `SiteTextEdit` — exactly once, or the
    /// call is refused with why — and the page is saved through the same path
    /// `save_site` takes, so every other file and the team copies are kept.
    /// `path` is the file inside the site, or the page's library address (the
    /// web view's current URL), or nothing for the entry page.
    func replaceSiteText(
        site: String,
        find: String,
        replace: String,
        path rawPath: String?
    ) async throws -> String {
        guard !SiteTextEdit.lines(of: find).isEmpty else {
            throw MCPError.invalidInput(SiteTextEdit.Failure.emptySelection.localizedDescription)
        }
        let artifact = try await librarySite(site)
        let stored = (try await notebookFileStorage.localSiteFilePaths(artifactID: artifact.id) ?? []).filter { !SiteSourceCards.isGenerated($0) }
        let path: String
        if let rawPath = Self.trimmedOrNil(rawPath) {
            if let url = URL(string: rawPath), url.scheme?.lowercased() == LinkedPage.localSiteScheme {
                guard let resolved = Self.storedSitePath(forPage: url, filePaths: stored) else {
                    throw MCPError.invalidInput("\(rawPath) is not a page of ‘\(artifact.title)’. Its files: \(Self.pathList(stored)).")
                }
                path = resolved
            } else {
                guard let normalized = LocalSite.normalizePath(rawPath) else {
                    throw MCPError.invalidInput("path must be a file path inside the site, such as index.html or about.html, or the page's address.")
                }
                guard let match = stored.first(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) else {
                    throw MCPError.invalidInput("The site has no file \(normalized). Its files: \(Self.pathList(stored)).")
                }
                path = match
            }
        } else {
            path = LocalSite.entryFile
        }
        guard let data = try await notebookFileStorage.readLocalSiteFile(artifactID: artifact.id, path: path),
              !SiteFile.looksBinary(data), let html = String(data: data, encoding: .utf8) else {
            throw MCPError.invalidInput("\(path) is not a text file of the site; only a page's text can be changed this way.")
        }
        let change: SiteTextEdit.Change
        do {
            change = try SiteTextEdit.apply(find: find, replace: replace, toHTML: html)
        } catch let failure as SiteTextEdit.Failure {
            throw MCPError.invalidInput(failure.localizedDescription)
        }
        let saved = try await saveSiteFiles(
            site: artifact.id, title: nil, html: nil,
            files: [["path": path, "content": change.html]],
            repository: nil, repositoryPath: nil, ref: nil,
            removeFiles: [], replaceAll: false,
            homeNotebookID: nil, notebookIDs: [],
            readRepository: nil,
            allowAnimation: true
        )
        let before = change.found.replacingOccurrences(of: "\n", with: " / ")
        let after = change.replacement.isEmpty ? "(removed)" : change.replacement.replacingOccurrences(of: "\n", with: " / ")
        let message = "Changed one passage of \(path) on ‘\(artifact.title)’: “\(before)” is now “\(after)”. Every other file is as it was."
        let base = saved.artifact.linkedURL.flatMap(URL.init(string:)) ?? LinkedPage.localSiteURL(artifactID: saved.artifact.id)
        let pageURL = path == LocalSite.entryFile ? base : base.appendingPathComponent(path)
        return try jsonString([
            "status": "changed",
            "site": saved.artifact.id,
            "url": pageURL.absoluteString,
            "path": path,
            "found": change.found,
            "replacement": change.replacement,
            "diff": "- \(before)\n+ \(after)",
            "message": message,
        ])
    }

    // MARK: Resolving a site
    /// The Sites or Animations entry a handle names — by record id or by its
    /// library address — when this library has one.
    ///
    /// The learner's own entry is the site's anchor: a team's copy is found
    /// by its id too, but answered with the entry in My Library when there is
    /// one, so a change is made once and flows to the copies.
    func existingSiteArtifact(handle: String?) async throws -> ArtifactRecord? {
        guard let handle = handle.flatMap(Self.siteHandle)?.lowercased() else { return nil }
        let artifacts = try await notebookFileStorage.loadArtifacts(notebookID: nil)
            .filter { $0.linkedKind == .foreverlmSite }
        guard let match = artifacts.first(where: { $0.id.lowercased() == handle }) else { return nil }
        guard let teamID = match.teamID else { return match }
        return artifacts.first(where: { original in
            original.teamID == nil
                && (original.linkedURL == match.linkedURL
                    || TeamContentIdentity.artifactCopyID(teamID: teamID, original: original) == match.id)
        }) ?? match
    }

    /// The site a handle names, refused with why when there is none.
    func librarySite(_ handle: String) async throws -> ArtifactRecord {
        guard let text = Self.trimmedOrNil(handle) else {
            throw MCPError.invalidInput("site is required: the site's site_id from save_site or the Sites list, or its address.")
        }
        guard let found = try await existingSiteArtifact(handle: text) else {
            throw MCPError.invalidInput("No site or animation of yours is named \(text).")
        }
        return found
    }


    /// The record id in a `foreverlm-site://` address, or the argument itself
    /// trimmed. Never nil for non-empty input. Shared with the animation tools.
    static func siteHandle(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let id = LinkedPage.localSiteID(from: url) { return id }
        return text
    }

    /// After a save: the page's copies in every team that holds one, or that
    /// the save names through a team Notebook, refreshed from the learner's
    /// own entry — title, files, text copy and sources — and filed under the
    /// team Notebooks named (docs/teams-design.md, decision 17). Returns the
    /// ids of the teams whose copy was written, sorted. A team row saved
    /// itself (made before build 114) is its team's record, not a copy in
    /// it: the share only sends the change out, and that team is not listed.
    func refreshTeamCopies(
        ofPage artifactID: String,
        previouslyIn previousTeamID: String?,
        filing: StorageService.PublishedPageFiling
    ) async throws -> [String] {
        var teamIDs = Set(try await notebookFileStorage.teamsHoldingArtifact(artifactID).map(\.id))
        if let previousTeamID { teamIDs.insert(previousTeamID) }
        teamIDs.formUnion(filing.teamNotebookIDs.keys)
        var copied: [String] = []
        for teamID in teamIDs.sorted() {
            do {
                let copy = try await notebookFileStorage.shareArtifact(
                    artifactID,
                    withTeam: teamID,
                    linkedTeamNotebookIDs: filing.teamNotebookIDs[teamID] ?? []
                )
                if copy.id != artifactID { copied.append(teamID) }
            } catch let error as KnowledgeStoreError {
                throw MCPError.invalidInput(error.localizedDescription)
            }
        }
        return copied
    }

    /// Where a save files the record (docs/teams-design.md, decision 17): the
    /// learner's own entry takes the Notebooks of My Library, and a team named
    /// through one of its Notebooks gets a copy. The Notebooks passed count for
    /// a new record only.
    func pageFiling(existing: ArtifactRecord?, homeNotebookID: String?, notebookIDs: [String]) async throws -> StorageService.PublishedPageFiling {
        do {
            return try await notebookFileStorage.publishedPageFiling(
                homeNotebookID: existing == nil ? homeNotebookID : nil,
                linkedNotebookIDs: existing == nil ? notebookIDs : []
            )
        } catch let error as ArtifactError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
    }

    /// The stored files an update keeps: every file the call neither passes
    /// nor names in `remove_files`, and never ForeverLM's generated ones.
    static func mergeStoredSiteFiles(
        into files: inout [SiteFile],
        stored: [SiteFile],
        removeFiles: [String]
    ) throws -> (kept: [String], removed: [String]) {
        let removeSet = Set(removeFiles.compactMap(LocalSite.normalizePath).map { $0.lowercased() })
        if let clash = files.first(where: { removeSet.contains($0.path.lowercased()) }) {
            throw MCPError.invalidInput("\(clash.path) is passed in files and named in remove_files; do one or the other.")
        }
        let passed = Set(files.map { $0.path.lowercased() })
        var kept: [String] = []
        var removed: [String] = []
        for file in stored {
            let key = file.path.lowercased()
            if passed.contains(key) || SiteSourceCards.isGenerated(file.path) { continue }
            if removeSet.contains(key) {
                removed.append(file.path)
                continue
            }
            files.append(file)
            kept.append(file.path)
        }
        return (kept, removed)
    }

    /// A site in the library travels inside its record's CloudKit asset, so
    /// it has that asset's room and no more.
    static func checkLocalSiteSize(_ files: [SiteFile], noun: String) throws {
        guard files.count <= LocalSite.maxFiles else {
            throw MCPError.invalidInput("The \(noun) would have \(files.count) files; at most \(LocalSite.maxFiles). Drop some with remove_files.")
        }
        let total = files.reduce(0) { $0 + $1.data.count }
        guard total <= LocalSite.maxBytes else {
            throw MCPError.invalidInput("The \(noun)'s files come to \(total / 1_000_000) MB; one kept in the library can be at most \(LocalSite.maxBytes / 1_000_000) MB, so it syncs through iCloud with the record. Render videos smaller or shorter, or drop files with remove_files.")
        }
    }

    /// The file a library page address (`foreverlm-site://<id>/about.html`)
    /// names inside the site. A folder is its index.html.
    static func storedSitePath(forPage url: URL, filePaths: [String]) -> String? {
        var path = url.pathComponents.filter { $0 != "/" }.joined(separator: "/")
        if path.isEmpty || url.path.hasSuffix("/") {
            path = path.isEmpty ? LocalSite.entryFile : path + "/" + LocalSite.entryFile
        }
        guard let normalized = LocalSite.normalizePath(path) else { return nil }
        if let match = filePaths.first(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) { return match }
        let asFolder = normalized + "/" + LocalSite.entryFile
        return filePaths.first(where: { $0.caseInsensitiveCompare(asFolder) == .orderedSame })
    }

    // MARK: Results

    func saveMessage(_ saved: SiteSave, noun: String, section: String, tool: String) -> String {
        let count = saved.files.count
        var message = "‘\(saved.artifact.title)’ is \(saved.created ? "saved" : "updated") in the library under \(section) with \(count) file\(count == 1 ? "" : "s"), and syncs through your iCloud like the rest of the library. It opens in ForeverLM, which never puts a \(noun) on the web. "
        if !saved.teamCopyIDs.isEmpty {
            message += "The team\(saved.teamCopyIDs.count == 1 ? "" : "s") holding it got the change in \(saved.teamCopyIDs.count == 1 ? "its" : "their") copy. "
        }
        if let source = saved.repositorySource {
            message += "Read from \(source.repository)\(source.ref.map { " at \($0)" } ?? "")\(source.path.map { ", folder \($0)" } ?? "")\(source.commit.map { " (commit \($0.prefix(12)))" } ?? ""). "
        }
        if !saved.kept.isEmpty {
            message += "\(saved.kept.count) stored file\(saved.kept.count == 1 ? " was" : "s were") kept unchanged: \(Self.pathList(saved.kept)). "
        }
        if !saved.removed.isEmpty {
            message += "Removed: \(saved.removed.joined(separator: ", ")). "
        }
        message += "To change it again, call \(tool) with \(noun == "animation" ? "animation" : "site") \"\(saved.artifact.id)\" and only the files that change; the rest are kept. read_site_file lists or reads its files."
        if !saved.sourceCards.cards.isEmpty {
            let sources = Set(saved.sourceCards.cards.values.map(\.sourceID)).count
            message += " \(sources) library source\(sources == 1 ? " is" : "s are") drawn as the app's banner card; the pictures and the card script live under \(SiteSourceCards.folder)/ and are regenerated on every save, so never draw your own."
        }
        if !saved.sourceCards.addresses.isEmpty {
            let addresses = saved.sourceCards.addresses.count
            message += " \(addresses) of the pages' web link\(addresses == 1 ? " points" : "s point") at a library source and \(addresses == 1 ? "is" : "are") drawn as that card too."
        }
        if !saved.sourceCards.unresolved.isEmpty {
            message += " No library source answers to \(saved.sourceCards.unresolved.joined(separator: ", ")); those links stay plain — check the ids with list_sources."
        }
        if !saved.skipped.isEmpty {
            message += " Skipped: \(saved.skipped.joined(separator: "; "))."
        }
        return message
    }

    func savePayload(_ saved: SiteSave) -> [String: Any] {
        var payload: [String: Any] = [
            "status": saved.created ? "saved" : "updated",
            "site_id": saved.artifact.id,
            "url": saved.artifact.linkedURL ?? LinkedPage.localSiteURL(artifactID: saved.artifact.id).absoluteString,
            "title": saved.artifact.title,
            "files": saved.files.count,
            "file_paths": saved.files.map(\.path),
            "bytes": saved.files.reduce(0) { $0 + $1.data.count },
            "doc": artifactPayload(saved.artifact),
        ]
        if let source = saved.repositorySource { payload["source"] = source.payload }
        if !saved.teamCopyIDs.isEmpty { payload["team_ids_holding_copy"] = saved.teamCopyIDs }
        if !saved.kept.isEmpty { payload["kept_files"] = saved.kept }
        if !saved.removed.isEmpty { payload["removed_files"] = saved.removed }
        if !saved.skipped.isEmpty { payload["skipped"] = saved.skipped }
        payload["source_cards"] = Set(saved.sourceCards.cards.values.map(\.sourceID)).count
        if !saved.sourceCards.addresses.isEmpty { payload["linked_addresses"] = saved.sourceCards.addresses }
        if !saved.sourceCards.unresolved.isEmpty { payload["unresolved_sources"] = saved.sourceCards.unresolved }
        return payload
    }

    static func trimmedOrNil(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Paths for a sentence: the first dozen, then how many more.
    static func pathList(_ paths: [String]) -> String {
        let shown = paths.prefix(12)
        let rest = paths.count - shown.count
        return shown.joined(separator: ", ") + (rest > 0 ? " and \(rest) more" : "")
    }

    // MARK: Inline files

    /// The files an argument carries: `html` as the entry page, and `files` as
    /// `{path, content}` or `{path, content_base64}` objects. Paths are
    /// checked here so a bad one is refused with its name before anything is
    /// saved; the library applies the same rule. `requireEntry` is false for an
    /// update that keeps the stored files, whose index.html may be one of them.
    static func inlineSiteFiles(html: String?, files rawFiles: [Any]?, requireEntry: Bool = true) throws -> [SiteFile] {
        var files: [SiteFile] = []
        var seen = Set<String>()
        if let html, !html.isEmpty {
            files.append(SiteFile(path: LocalSite.entryFile, data: Data(html.utf8)))
            seen.insert(LocalSite.entryFile)
        }
        for (index, entry) in (rawFiles ?? []).enumerated() {
            guard let object = entry as? [String: Any], let rawPath = object["path"] as? String else {
                throw MCPError.invalidInput("files[\(index)] must be an object with path and content (text) or content_base64 (bytes).")
            }
            guard let path = LocalSite.normalizePath(rawPath) else {
                throw MCPError.invalidInput("files[\(index)].path ‘\(rawPath)’ is not a file path a site can serve: relative, forward slashes, letters, digits, dots, hyphens and underscores, no dot segments.")
            }
            guard !seen.contains(path.lowercased()) else {
                throw MCPError.invalidInput(path == LocalSite.entryFile && html != nil
                    ? "Pass the entry page once: as html, or as a file named index.html."
                    : "The file \(path) appears twice.")
            }
            seen.insert(path.lowercased())
            let text = object["content"] as? String
            let base64 = object["content_base64"] as? String
            switch (text, base64) {
            case (let text?, nil):
                files.append(SiteFile(path: path, data: Data(text.utf8)))
            case (nil, let base64?):
                guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
                    throw MCPError.invalidInput("\(path): content_base64 is not valid base64.")
                }
                files.append(SiteFile(path: path, data: data))
            default:
                throw MCPError.invalidInput("\(path): pass exactly one of content (text) or content_base64 (bytes).")
            }
        }
        guard files.count <= LocalSite.maxFiles else {
            throw MCPError.invalidInput("A site can have at most \(LocalSite.maxFiles) files.")
        }
        guard !requireEntry || seen.contains(LocalSite.entryFile) else {
            throw MCPError.invalidInput("A site needs an \(LocalSite.entryFile) at its root — pass it as html, or as a file named index.html.")
        }
        for file in files where file.data.count > LocalSite.maxInlineFileBytes {
            throw MCPError.invalidInput("\(file.path) is \(file.data.count / 1000) KB; a file can be at most \(LocalSite.maxInlineFileBytes / 1_000_000) MB.")
        }
        guard files.reduce(0, { $0 + $1.data.count }) <= LocalSite.maxInlineBytes else {
            throw MCPError.invalidInput("The files passed inline can be at most \(LocalSite.maxInlineBytes / 1_000_000) MB together; pass the rest in a second call, which keeps the stored files.")
        }
        return files
    }

    // MARK: Files from GitHub

    /// The text files under `path` in the repository at `ref`, read one by one
    /// through the gateway's read-only GitHub grant. The plugin returns text
    /// only — it refuses binaries and files over 1 MB — so images in the repo
    /// are skipped and named, and the site should reference pictures by an
    /// https URL or receive them inline as content_base64.
    private func readSiteFilesFromGitHub(repository rawRepository: String, path rawPath: String?, ref: String?) async throws -> SiteRepositoryRead {
        let repository = try Self.validatedGitHubRepository(rawRepository)
        let fullName = "\(repository.owner)/\(repository.repo)"
        var folder = rawPath?.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n\t")) ?? ""
        if folder == "." { folder = "" }
        var items: [URLQueryItem] = [URLQueryItem(name: "recursive", value: "true")]
        if !folder.isEmpty { items.append(URLQueryItem(name: "path", value: folder)) }
        if let ref { items.append(URLQueryItem(name: "ref", value: ref)) }
        let tree = try await Self.githubGatewayJSON(path: Self.githubRepoPath(repository, "/files"), query: items)
        let resolvedRef = (tree["ref"] as? String) ?? ref
        let entries = (tree["entries"] as? [[String: Any]]) ?? []
        if tree["truncated"] as? Bool == true {
            throw MCPError.invalidInput("\(fullName) has more files under \(folder.isEmpty ? "its root" : folder) than can be read in one save. Pass repository_path pointing at the folder that holds just the site.")
        }
        let blobs = entries.compactMap { entry -> String? in
            guard entry["type"] as? String == "file", let path = entry["path"] as? String else { return nil }
            return path
        }
        guard !blobs.isEmpty else {
            throw MCPError.invalidInput("No files found under \(folder.isEmpty ? "the root of" : "\(folder) in") \(fullName)\(resolvedRef.map { " at \($0)" } ?? "").")
        }
        guard blobs.count <= Self.maxRepositoryFiles else {
            throw MCPError.invalidInput("\(blobs.count) files under \(folder.isEmpty ? "the root of" : "\(folder) in") \(fullName); a site has at most \(Self.maxRepositoryFiles). Pass repository_path pointing at the folder that holds just the site.")
        }

        var files: [SiteFile] = []
        var skipped: [String] = []
        let prefix = folder.isEmpty ? "" : folder + "/"
        for blob in blobs {
            let relative = blob.hasPrefix(prefix) ? String(blob.dropFirst(prefix.count)) : blob
            guard let sitePath = LocalSite.normalizePath(relative) else {
                skipped.append("\(relative) (not a path a site can serve)")
                continue
            }
            var query = [URLQueryItem(name: "path", value: blob)]
            if let resolvedRef { query.append(URLQueryItem(name: "ref", value: resolvedRef)) }
            let file: [String: Any]
            do {
                file = try await Self.githubGatewayJSON(path: Self.githubRepoPath(repository, "/file"), query: query)
            } catch let error as MCPError {
                skipped.append("\(relative) (\(error.localizedDescription))")
                continue
            }
            guard let content = file["content"] as? String else {
                skipped.append("\(relative) (\((file["encoding_note"] as? String) ?? "no content returned"))")
                continue
            }
            if file["content_truncated"] as? Bool == true {
                skipped.append("\(relative) (longer than the plugin returns)")
                continue
            }
            files.append(SiteFile(path: sitePath, data: Data(content.utf8)))
        }
        let commit = (tree["sha"] as? String) ?? (tree["commit"] as? String)
        return SiteRepositoryRead(
            files: files,
            source: SiteRepositorySource(repository: fullName, ref: resolvedRef, path: folder.isEmpty ? nil : folder, commit: commit),
            skipped: skipped
        )
    }
}

// MARK: - Library sources on a site

/// The banner cards a site draws for its `foreverlm://source/<id>` links.
///
/// The product owner (2026-09-10), after a chat drew its own "document-style" thumbnails
/// for the studies on a crosswalk site: "these sites must have access to the
/// same banner style cards with a thumbnail that is stored somewhere". In the
/// app a Site's standalone source link already became the compact banner
/// (`LinkedDocWebView.sourceLinkScript`), resolved from the live library — but
/// anywhere else the same link was dead text, and a model that could not reach
/// the library's pictures drew its own. So on every save the Mac looks up every
/// source the pages link, renders the thumbnail the library rows draw
/// (`SourceArtwork`: a paper's first page, a chapter's cover, a stored icon),
/// and stores the pictures with the site's own files, beside the pages —
/// `foreverlm/thumbnails/<id>.jpg` — together with one script,
/// `foreverlm/source-cards.js`, that carries every card's title, metadata
/// and address and draws the card the way the app does. Each page that links
/// a source loads the script once. In a browser the card opens the source's
/// public page; in the app, whose host draws its own card from the live
/// library and opens Reader beside the site, the script steps aside. The
/// generated files are ForeverLM's: a copy passed back is dropped and the set
/// is made again, so a stale picture never outlives its source.
enum SiteSourceCards {
    static let folder = "foreverlm"
    static let scriptPath = "foreverlm/source-cards.js"
    static let thumbnailFolder = "foreverlm/thumbnails"
    /// Marks the script tag a page carries, so a page passed back is not given a second one.
    static let scriptMarker = "data-foreverlm-source-cards"
    /// Twice the largest frame the card draws the picture in, so it stays crisp on Retina.
    static let thumbnailMaxPixelSize: CGFloat = 144

    /// One source as the site's script knows it: what the app's card shows,
    /// plus where a browser opens it and where its picture is.
    struct Card: Codable, Equatable {
        var sourceID: String
        var title: String
        var subtitle: String
        var kind: String
        var glyph: String
        /// The source's public page, when it has one; nil leaves the card a label.
        var url: String?
        /// The library's picture, as a path inside the site.
        var thumbnail: String?
        /// A picture the library shows from the web (podcast art, a video still).
        var thumbnailURL: String?
    }

    /// What the library said about a link's token.
    struct Lookup {
        var card: Card
        /// The rendered picture, when the source has a file to render one from.
        var thumbnailJPEG: Data?
    }

    struct Attachment: Equatable {
        /// The cards by the token — or the web address — the pages link them with.
        var cards: [String: Card] = [:]
        /// Tokens no library source answers to, in the order the pages use them.
        /// A web address no source answers to is not listed: it is an ordinary
        /// link, and stays one.
        var unresolved: [String] = []
        /// The web addresses a library source answered to, in the order the
        /// pages use them.
        var addresses: [String] = []
    }

    static func isHTML(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".html") || lower.hasSuffix(".htm")
    }

    /// A path ForeverLM writes: the card script and every thumbnail.
    static func isGenerated(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower == scriptPath || lower.hasPrefix(thumbnailFolder + "/")
    }

    private static let linkPattern = try! NSRegularExpression(
        pattern: #"foreverlm(?:-dev)?://source/([^\s"'<>?#)]+)"#,
        options: [.caseInsensitive]
    )

    /// The tokens of every source link in a page, in order, once each.
    static func tokens(inHTML html: String) -> [String] {
        var tokens: [String] = []
        var seen = Set<String>()
        for match in linkPattern.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let raw = String(html[range])
            let token = (raw.removingPercentEncoding ?? raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, seen.insert(token).inserted else { continue }
            tokens.append(token)
        }
        return tokens
    }

    private static let webLinkPattern = try! NSRegularExpression(
        pattern: #"<a\b[^>]*?\bhref\s*=\s*(?:"([^"]*)"|'([^']*)')"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    /// Every web address a page links — `<a href="https://…">` — in order, once
    /// each, as the browser reads the attribute (`&amp;` is `&`). A relative
    /// address is one of the site's own pages and a `foreverlm://` link is a
    /// token (`tokens(inHTML:)`); neither is listed.
    static func webAddresses(inHTML html: String) -> [String] {
        var addresses: [String] = []
        var seen = Set<String>()
        for match in webLinkPattern.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            let range = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            guard let swiftRange = Range(range, in: html) else { continue }
            let address = LocalSite.decodeEntities(String(html[swiftRange])).trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = address.lowercased()
            guard lower.hasPrefix("https://") || lower.hasPrefix("http://"), seen.insert(address).inserted else { continue }
            addresses.append(address)
        }
        return addresses
    }

    /// The page with the card script tag, added once: an earlier tag is
    /// replaced so a page passed back from `read_site_file` keeps one, and
    /// the address is relative to the page's own folder.
    static func injectingScript(into html: String, path: String) -> String {
        let depth = max(0, path.split(separator: "/").count - 1)
        let src = String(repeating: "../", count: depth) + scriptPath
        let tag = "<script defer src=\"\(src)\" \(scriptMarker)></script>"
        var page = html.replacingOccurrences(
            of: "(?is)[ \\t]*<script\\b[^>]*\\b\(scriptMarker)\\b[^>]*>\\s*</script>[ \\t]*\\r?\\n?",
            with: "",
            options: .regularExpression
        )
        if let range = page.range(of: "</head>", options: .caseInsensitive) {
            page.insert(contentsOf: tag + "\n", at: range.lowerBound)
        } else if let range = page.range(of: "</body>", options: [.caseInsensitive, .backwards]) {
            page.insert(contentsOf: tag + "\n", at: range.lowerBound)
        } else {
            page += "\n" + tag + "\n"
        }
        return page
    }

    /// Where a source's picture is stored in the site: its id as a file name
    /// the site can serve, made unique against the files already there.
    static func thumbnailPath(forSourceID id: String, taken: Set<String>) -> String {
        var stem = String(id.map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber || "._-".contains(character)) ? character : "-"
        })
        while let first = stem.first, !(first.isLetter || first.isNumber) { stem.removeFirst() }
        if stem.isEmpty { stem = "source" }
        if stem.count > 80 { stem = String(stem.prefix(80)) }
        var candidate = "\(thumbnailFolder)/\(stem).jpg"
        var suffix = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(thumbnailFolder)/\(stem)-\(suffix).jpg"
            suffix += 1
        }
        return candidate
    }

    /// The library's picture for a source, as the JPEG the site stores — the
    /// same rendering the app's cards embed — or nil when the source has no
    /// file to draw one from.
    static func thumbnailJPEG(for article: StudioArticle) async -> Data? {
        guard let path = await Task.detached(priority: .utility, operation: {
            SourceArtwork.filePath(for: article)
        }).value else { return nil }
        guard let image = await SourceArtwork.thumbnail(for: .file(path), maxPixelSize: thumbnailMaxPixelSize),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }

    /// The card's second line: for a paper the Sources row's author · venue ·
    /// year without the "Unknown …" placeholders, else what the chat card says.
    static func subtitle(for article: StudioArticle, chat: ChatSourceCard) -> String {
        guard article.sourceType == .paper else { return chat.subtitle }
        let parts = article.paperMetadataDisplayParts.filter {
            $0 != StudioArticle.unknownPaperAuthor && $0 != StudioArticle.unknownPaperJournal && $0 != StudioArticle.unknownPaperYear
        }
        return parts.isEmpty ? chat.subtitle : parts.joined(separator: " · ")
    }

    /// Where a browser opens the source: the address the library records for
    /// sharing, else the same fallback exports use.
    static func publicURL(for article: StudioArticle) -> String? {
        if let stored = article.publicURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           stored.hasPrefix("https://") || stored.hasPrefix("http://") {
            return stored
        }
        return KnowledgeStore.defaultPublicURL(for: article)
    }

    /// Gives the site its cards. ForeverLM's earlier files are dropped, every
    /// page's source links — by id, and by web address — are looked up, each
    /// resolved source's picture is stored once, every page that links a
    /// resolved source loads the card script, and the script is written last
    /// with every card in it. A site without source links is returned
    /// untouched.
    static func attach(
        to files: inout [SiteFile],
        lookup: (String) async -> Lookup?,
        lookupAddresses: ([String]) async -> [String: Lookup] = { _ in [:] }
    ) async -> Attachment {
        files.removeAll { isGenerated($0.path) }
        var attachment = Attachment()
        var pages: [(index: Int, keys: [String])] = []
        var tokenOrder: [String] = []
        var addressOrder: [String] = []
        var seen = Set<String>()
        for (index, file) in files.enumerated() where isHTML(file.path) {
            guard let html = String(data: file.data, encoding: .utf8) else { continue }
            let found = tokens(inHTML: html)
            let addresses = webAddresses(inHTML: html)
            guard !found.isEmpty || !addresses.isEmpty else { continue }
            pages.append((index, found + addresses))
            for token in found where seen.insert(token).inserted { tokenOrder.append(token) }
            for address in addresses where seen.insert(address).inserted { addressOrder.append(address) }
        }
        guard !tokenOrder.isEmpty || !addressOrder.isEmpty else { return attachment }

        // A token names a source and is answered on its own; one no source
        // answers to is reported, since the author meant a source. The web
        // addresses are asked together, and one no source answers to is
        // simply a link. A card found by address opens what the author
        // linked — the address, not the library's public page for it.
        var resolved: [(key: String, lookup: Lookup)] = []
        for token in tokenOrder {
            if let found = await lookup(token) {
                resolved.append((token, found))
            } else {
                attachment.unresolved.append(token)
            }
        }
        let addressLookups = addressOrder.isEmpty ? [:] : await lookupAddresses(addressOrder)
        for address in addressOrder {
            guard var found = addressLookups[address] else { continue }
            found.card.url = address
            resolved.append((address, found))
            attachment.addresses.append(address)
        }
        guard !resolved.isEmpty else { return attachment }

        var thumbnails: [SiteFile] = []
        var thumbnailPaths: [String: String] = [:]
        var taken = Set(files.map { $0.path.lowercased() })
        for (key, item) in resolved {
            var found = item
            if let jpeg = found.thumbnailJPEG {
                if let stored = thumbnailPaths[found.card.sourceID] {
                    found.card.thumbnail = stored
                } else if files.count + thumbnails.count + 1 < LocalSite.maxFiles {
                    let path = thumbnailPath(forSourceID: found.card.sourceID, taken: taken)
                    taken.insert(path.lowercased())
                    thumbnails.append(SiteFile(path: path, data: jpeg))
                    thumbnailPaths[found.card.sourceID] = path
                    found.card.thumbnail = path
                }
                if found.card.thumbnail != nil { found.card.thumbnailURL = nil }
            }
            attachment.cards[key] = found.card
        }
        guard !attachment.cards.isEmpty else { return attachment }

        for page in pages where page.keys.contains(where: { attachment.cards[$0] != nil }) {
            let file = files[page.index]
            guard let html = String(data: file.data, encoding: .utf8) else { continue }
            files[page.index] = SiteFile(path: file.path, data: Data(injectingScript(into: html, path: file.path).utf8))
        }
        files.append(contentsOf: thumbnails)
        files.append(SiteFile(path: scriptPath, data: Data(script(cards: attachment.cards).utf8)))
        return attachment
    }

    /// The card script with its cards written in.
    static func script(cards: [String: Card]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(cards)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return scriptTemplate
            .replacingOccurrences(of: "__FOREVERLM_CARDS__", with: json)
            .replacingOccurrences(of: "__FOREVERLM_CARD_STYLE__", with: cardStyle)
    }

    /// How a card looks — the Sources row's shape: the picture at the row's
    /// portrait size, the title on up to two lines, the metadata line under
    /// it. Shared with the app's own card (`LinkedDocWebView.sourceLinkScript`)
    /// so a site's card is the same card wherever it is seen.
    static let cardStyle = """
      :host { display:block; min-width:0; color:inherit; }
      .card { align-items:center; background:rgba(120,120,128,.10); border:1px solid rgba(120,120,128,.20); border-radius:10px; box-sizing:border-box; color:inherit; display:flex; font-family:-apple-system,BlinkMacSystemFont,system-ui,sans-serif; gap:10px; min-height:58px; padding:6px 10px; text-align:left; transition:background-color .12s ease; width:100%; }
      .card:hover { background:rgba(120,120,128,.20); }
      .thumb { align-items:center; background:rgba(120,120,128,.16); border-radius:6px; box-sizing:border-box; display:flex; flex:0 0 36px; height:46px; justify-content:center; overflow:hidden; width:36px; }
      img { display:block; height:100%; object-fit:cover; width:100%; }
      .glyph { color:currentColor; font-size:13px; font-weight:650; opacity:.68; }
      .copy { display:flex; flex:1 1 auto; flex-direction:column; min-width:0; }
      .title { color:inherit; display:-webkit-box; font-size:13px; font-weight:600; line-height:1.25; overflow:hidden; -webkit-box-orient:vertical; -webkit-line-clamp:2; }
      .subtitle { color:inherit; font-size:11px; line-height:1.3; margin-top:2px; opacity:.62; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
      .arrow { color:inherit; flex:0 0 auto; font-size:20px; opacity:.42; }
    """

    /// The script a site serves. It mirrors the app's `sourceLinkScript`: the
    /// same notion of a source link — a `foreverlm://source/<id>` token, or a
    /// web address the library answered to at save — the same rule for
    /// which links become cards (a link standing alone in its element, or one
    /// marked `data-foreverlm-source-card`; a link by address never inside the
    /// page's nav, header or footer), the same card. Two things differ. The
    /// cards are the ones written in at save, so nothing is fetched — a
    /// sandboxed page cannot rely on storage or a session — and the pictures
    /// are the site's own files, found relative to the script. And the click
    /// goes to the source's public page in a new tab, because a browser has no
    /// Reader; in the app, whose
    /// message handler is present before this runs, the script does nothing
    /// and the app's own card takes over.
    static let scriptTemplate = #"""
    (function () {
      var CARDS = __FOREVERLM_CARDS__;
      try {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.linkedPageSourceLinks) { return; }
      } catch (_) {}
      if (window.__foreverlmSiteSourceCards) { return; }
      window.__foreverlmSiteSourceCards = true;

      var scriptURL = (document.currentScript && document.currentScript.src) || '';
      var scheduled = false;

      function assetURL(path) {
        try { return new URL('../' + path, scriptURL).href; } catch (_) { return path; }
      }

      function sourceLink(anchor) {
        if (!anchor || !anchor.getAttribute) { return null; }
        var raw = anchor.getAttribute('href') || '';
        var url;
        try { url = new URL(raw, location.href); } catch (_) { return null; }
        var scheme = url.protocol.toLowerCase();
        if (scheme === 'http:' || scheme === 'https:') {
          // A source linked by its own web address: its card was written in
          // at save under the address as the page wrote it. Any other
          // address is an ordinary link and stays one.
          var address = raw.trim();
          if (CARDS[address]) { return { token: address, href: url.href, web: true }; }
          if (CARDS[url.href]) { return { token: url.href, href: url.href, web: true }; }
          return null;
        }
        if (scheme !== 'foreverlm:' && scheme !== 'foreverlm-dev:') { return null; }
        if (url.hostname.toLowerCase() !== 'source') { return null; }
        var token = url.pathname.replace(/^\/+/, '').split('/')[0] || '';
        try { token = decodeURIComponent(token); } catch (_) {}
        token = token.trim();
        return token ? { token: token, href: url.href, web: false } : null;
      }

      function shouldDecorate(anchor, web) {
        if (anchor.hasAttribute('data-foreverlm-source-card')) { return true; }
        if (web && anchor.closest && anchor.closest('nav, header, footer')) { return false; }
        var label = (anchor.textContent || '').trim().toLowerCase();
        if (/^open(?: this source)? in (?:the )?reader[.!]?$/.test(label)) { return true; }
        var parent = anchor.parentElement;
        if (!parent) { return false; }
        var remainder = (parent.textContent || '').replace(anchor.textContent || '', '').trim();
        return !remainder && parent.children.length === 1;
      }

      function fallbackGlyph(card) {
        var glyph = (card.glyph || 'S').trim();
        return glyph.length > 2 ? glyph.slice(0, 2) : glyph;
      }

      function decorate(anchor, card, web) {
        if (!card || !shouldDecorate(anchor, web)) { return; }
        if (anchor.dataset.foreverlmSourceCardID === card.sourceID) { return; }
        anchor.dataset.foreverlmSourceCardID = card.sourceID;
        var opens = card.url;
        if (opens) {
          anchor.setAttribute('href', opens);
          anchor.setAttribute('target', '_blank');
          anchor.setAttribute('rel', 'noopener');
          anchor.setAttribute('aria-label', 'Open ' + card.title);
        } else {
          anchor.removeAttribute('href');
          anchor.setAttribute('aria-label', card.title + ', in the ForeverLM library');
        }
        anchor.setAttribute('title', card.subtitle || card.title);
        anchor.style.setProperty('display', 'block', 'important');
        anchor.style.setProperty('width', '100%', 'important');
        anchor.style.setProperty('min-width', '0', 'important');
        anchor.style.setProperty('padding', '0', 'important');
        anchor.style.setProperty('border', '0', 'important');
        anchor.style.setProperty('background', 'transparent', 'important');
        anchor.style.setProperty('color', 'inherit', 'important');
        anchor.style.setProperty('text-decoration', 'none', 'important');
        anchor.style.setProperty('cursor', opens ? 'pointer' : 'default', 'important');

        var host = document.createElement('span');
        host.style.display = 'block';
        host.style.minWidth = '0';
        var root = host.attachShadow({ mode: 'open' });
        var style = document.createElement('style');
        style.textContent = `
    __FOREVERLM_CARD_STYLE__
        `;
        var body = document.createElement('span');
        body.className = 'card';
        var thumb = document.createElement('span');
        thumb.className = 'thumb';
        var picture = card.thumbnail ? assetURL(card.thumbnail) : (card.thumbnailURL || '');
        if (picture) {
          var image = document.createElement('img');
          image.alt = '';
          image.loading = 'lazy';
          image.src = picture;
          image.addEventListener('error', function () {
            thumb.replaceChildren();
            var glyph = document.createElement('span');
            glyph.className = 'glyph';
            glyph.textContent = fallbackGlyph(card);
            thumb.append(glyph);
          });
          thumb.append(image);
        } else {
          var glyph = document.createElement('span');
          glyph.className = 'glyph';
          glyph.textContent = fallbackGlyph(card);
          thumb.append(glyph);
        }
        var copy = document.createElement('span');
        copy.className = 'copy';
        var title = document.createElement('span');
        title.className = 'title';
        title.textContent = card.title || 'Source';
        var subtitle = document.createElement('span');
        subtitle.className = 'subtitle';
        subtitle.textContent = card.subtitle || 'ForeverLM source';
        copy.append(title, subtitle);
        var trail = document.createElement('span');
        trail.className = 'arrow';
        trail.setAttribute('aria-hidden', 'true');
        trail.textContent = card.url ? '\u2197' : '';
        body.append(thumb, copy, trail);
        root.append(style, body);
        anchor.replaceChildren(host);
      }

      function scan() {
        scheduled = false;
        var anchors = document.querySelectorAll('a[href]');
        for (var index = 0; index < anchors.length; index += 1) {
          var link = sourceLink(anchors[index]);
          if (link) { decorate(anchors[index], CARDS[link.token], link.web); }
        }
      }

      function scheduleScan() {
        if (scheduled) { return; }
        scheduled = true;
        requestAnimationFrame(scan);
      }

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', scan);
      } else {
        scan();
      }
      if (document.documentElement && typeof MutationObserver === 'function') {
        new MutationObserver(scheduleScan).observe(document.documentElement, { childList: true, subtree: true });
      }
    })();
    """#
}

extension MCPDataStore {
    /// What the library says about a source a site links, or nil when no
    /// source answers to the token. The same resolution as a chat citation:
    /// the id, or a unique prefix of it.
    func siteSourceCard(forToken token: String) async -> SiteSourceCards.Lookup? {
        guard let store = try? knowledgeStore(),
              let sourceID = try? store.resolveSourceID(forLinkToken: token),
              let article = try? store.loadSourceForSync(sourceID) else { return nil }
        return await siteSourceLookup(for: article)
    }

    /// What the library says about the web addresses a site links — a paper by
    /// its DOI or arXiv page, a video, an episode — keyed by the address as
    /// the page wrote it, only where an active source answers. The matching
    /// is the Doc reference cards' (`activeSourceID(forReferenceURL:)`): the
    /// address as saved or normalized, the DOI, the arXiv id. The site's own
    /// library is asked first — the publisher's, whose ids the pages would
    /// otherwise carry — and then its team's when it has one, so a paper the
    /// team holds draws its card too. A source linked under two addresses is
    /// rendered once.
    func siteSourceCards(forWebAddresses addresses: [String], teamID: String?) async -> [String: SiteSourceCards.Lookup] {
        guard !addresses.isEmpty, let store = try? knowledgeStore() else { return [:] }
        var lookups: [String: SiteSourceCards.Lookup] = [:]
        var bySource: [String: SiteSourceCards.Lookup] = [:]
        for address in addresses {
            guard let sourceID = store.activeSourceID(forReferenceURL: address)
                ?? teamID.flatMap({ store.activeSourceID(forReferenceURL: address, teamID: $0) }) else { continue }
            if let known = bySource[sourceID] {
                lookups[address] = known
                continue
            }
            guard let article = try? store.loadSourceForSync(sourceID) else { continue }
            let lookup = await siteSourceLookup(for: article)
            bySource[sourceID] = lookup
            lookups[address] = lookup
        }
        return lookups
    }

    private func siteSourceLookup(for article: StudioArticle) async -> SiteSourceCards.Lookup {
        let chat = ChatSourceCard(article: article)
        let card = SiteSourceCards.Card(
            sourceID: article.id,
            title: chat.title,
            subtitle: SiteSourceCards.subtitle(for: article, chat: chat),
            kind: chat.kind,
            glyph: chat.glyph,
            url: SiteSourceCards.publicURL(for: article),
            thumbnail: nil,
            thumbnailURL: chat.thumbnailURL
        )
        return SiteSourceCards.Lookup(
            card: card,
            thumbnailJPEG: await SiteSourceCards.thumbnailJPEG(for: article)
        )
    }
}
