import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Sites: HTML kept in the library, published on request

/// `save_site`, `publish_site`, `read_site_file`, `replace_site_text` and
/// `unpublish_site`: a folder of HTML, CSS, JavaScript and images becomes a
/// site in the learner's library.
///
/// The product owner (2026-09-09), after a chat asked to "make a site" produced a Doc:
/// "it should also be able to make an arbitrary html site". A site is the
/// author's files served as written, scripts included. Since 2026-09-22 those
/// files live in the library — under the record's folder, synced through the
/// learner's own iCloud inside the Artifact's body asset, and served in the
/// app from `foreverlm-site://<id>/` under the same CSP sandbox the web host
/// uses (the product owner: "data should stay in the user's icloud in general"). The
/// record is a linked page under Sites, like a linked Codex site or Claude
/// artifact: it opens as itself, keeps a text copy for chat, and is
/// read-only here.
///
/// Putting a copy on the web at `sites.foreverlm.com/<slug>/` is a separate,
/// explicit step (`publish_site`), because hosting costs money per site and
/// is meant to become a paid feature. The service knows a published copy by
/// the record's id; the record never points at it.
///
/// The files can also come from a GitHub repository, read as the learner
/// through the read-only GitHub plugin: ForeverLM reads *from* a repo and
/// records the commit; it never writes *to* one (docs/github-plugin.md).
extension MCPDataStore {

    /// A publish, as the tests inject it: id, title, files, slug, source,
    /// access. Nil preserves an existing Site's visibility and readers.
    typealias SitePublisher = @Sendable (String, String, [SiteFile], String?, SitePublishingSource?, SitePublishingAccess?) async throws -> PublishedSiteStatus
    /// A repository read, as the tests inject it: repository, path, ref → the
    /// files under that path (text only), where they came from, and what was
    /// skipped with the reason.
    typealias SiteRepositoryReader = @Sendable (String, String?, String?) async throws -> SiteRepositoryRead
    /// What the service holds for a site, as the tests inject it: nil when
    /// nothing is published under the handle.
    typealias SiteStatusReader = @Sendable (String) async throws -> PublishedSiteStatus?
    /// One stored file of a site, as the tests inject it: site, path → bytes
    /// and content type.
    typealias SiteFileReader = @Sendable (String, String) async throws -> (data: Data, contentType: String)

    struct SiteRepositoryRead: Sendable {
        var files: [SiteFile]
        var source: SitePublishingSource
        var skipped: [String]
    }

    static let siteSignedOutMessage = "Sign in with Apple in Settings › Billing to publish a site. Publishing is tied to your ForeverLM account so only you can update or take down the published copy; saving a site needs no account."

    /// How many files a repository read will fetch one by one before it asks
    /// for a narrower path.
    private static let maxRepositoryFiles = SitePublishing.maxFiles

    // MARK: Hosting, as the tests inject it

    /// Everything that reaches sites.foreverlm.com, in one place: the
    /// account check, a publish, what the service holds for a site, one of
    /// its stored files, and a take-down. Saving a site never touches any of
    /// it; publishing, unpublishing and bringing an old hosted site home do.
    struct SiteHosting: Sendable {
        var isSignedIn: Bool = ManagedAI.isSignedIn
        var publish: SitePublisher = { try await SitePublishing.publish(siteID: $0, title: $1, files: $2, slug: $3, source: $4, access: $5) }
        var status: SiteStatusReader = { try await SitePublishing.status(site: $0) }
        var readFile: SiteFileReader = { try await SitePublishing.readFile(site: $0, path: $1) }
        var unpublish: @Sendable (String) async throws -> Bool = { try await SitePublishing.unpublish(site: $0) }
    }

    /// What one save of a site's files did.
    struct SiteSave {
        var artifact: ArtifactRecord
        var created: Bool
        var files: [SiteFile]
        var kept: [String] = []
        var removed: [String] = []
        var skipped: [String] = []
        var repositorySource: SitePublishingSource?
        var sourceCards = SiteSourceCards.Attachment()
        var teamCopyIDs: [String] = []
        /// The record pointed at sites.foreverlm.com and its files were
        /// brought into the library before this save (`HostedSiteAdoption`).
        var broughtHome = false
        /// The sites.foreverlm.com slug the record pointed at before it was
        /// brought home, so a republish can put it back at the same address.
        var broughtHomeFrom: String? = nil
    }

    // MARK: save_site

    /// Keep a site in the library: the files are written under the record's
    /// folder and sync through the learner's own iCloud with the record.
    /// Nothing is hosted — that is `publish_site`. A site that is already
    /// published is republished with the change, so its page never drifts
    /// from the library.
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
        readRepository: SiteRepositoryReader? = nil,
        hosting: SiteHosting = SiteHosting()
    ) async throws -> String {
        let saved = try await saveSiteFiles(
            site: site, title: title, html: html, files: rawFiles,
            repository: repository, repositoryPath: repositoryPath, ref: ref,
            removeFiles: removeFiles, replaceAll: replaceAll,
            homeNotebookID: homeNotebookID, notebookIDs: notebookIDs,
            readRepository: readRepository, hosting: hosting
        )
        var message = saveMessage(saved, noun: "site", section: "Sites", tool: "save_site")
        var payload = savePayload(saved)
        if let republished = await republishIfPublished(saved, hosting: hosting) {
            switch republished {
            case .success(let status):
                message += " It is published, so the page at \(status.url.absoluteString) was updated with the change too."
                payload["published_url"] = status.url.absoluteString
            case .failure(let error):
                message += " It is published, but the page could not be updated (\(error.localizedDescription)); call publish_site with site \"\(saved.artifact.id)\" to try again."
                payload["publish_error"] = error.localizedDescription
            }
        }
        payload["message"] = message
        return try jsonString(payload)
    }

    /// The save itself, shared by `save_site`, `publish_site` with files and
    /// `replace_site_text`.
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
        hosting: SiteHosting,
        allowAnimation: Bool = false
    ) async throws -> SiteSave {
        var existing: ArtifactRecord? = nil
        if let handle = Self.trimmedOrNil(site) {
            guard let found = try await existingSiteArtifact(handle: handle, hosting: hosting) else {
                throw MCPError.invalidInput("No site of yours is named \(handle). Pass the site_id from save_site or the Sites list, or omit site to make a new one.")
            }
            guard allowAnimation || !found.isAnimation else {
                throw MCPError.invalidInput("‘\(found.title)’ is an animation, not a Site. Change it with save_animation.")
            }
            existing = found
        }
        var broughtHome = false
        var broughtHomeFrom: String? = nil
        if let found = existing {
            let home = try await bringSiteHomeIfHosted(found, hosting: hosting)
            existing = home.artifact
            broughtHome = home.broughtHome
            if home.broughtHome { broughtHomeFrom = HostedSiteAdoption.hostedSlug(of: found) }
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
        var repositorySource: SitePublishingSource? = nil
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
            guard siteFiles.contains(where: { $0.path == SitePublishing.entryFile }) else {
                let place = read.source.path.map { "\($0) in " } ?? ""
                throw MCPError.invalidInput("No \(SitePublishing.entryFile) at the root of \(place)\(repositoryName)\(read.source.ref.map { " at \($0)" } ?? ""). Pass repository_path pointing at the folder that holds the site's \(SitePublishing.entryFile).\(skipped.isEmpty ? "" : " Skipped: \(skipped.joined(separator: "; ")).")")
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
                guard siteFiles.contains(where: { $0.path == SitePublishing.entryFile }) else {
                    throw MCPError.invalidInput("The site would have no \(SitePublishing.entryFile): pass one as html or as a file named index.html, or leave the stored one out of remove_files.")
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
            includeSourceFiles: false,
            paywalledAllowed: false,
            lookup: { token in await self.siteSourceCard(forToken: token) },
            lookupAddresses: { addresses in
                await self.siteSourceCards(forWebAddresses: addresses, teamID: siteTeamID)
            }
        )
        try Self.checkLocalSiteSize(siteFiles, noun: "site")

        let indexHTML = siteFiles.first(where: { $0.path == SitePublishing.entryFile }).flatMap { String(data: $0.data, encoding: .utf8) } ?? ""
        let artifact: ArtifactRecord
        do {
            artifact = try await notebookFileStorage.saveLocalSite(
                artifactID: existing?.id,
                title: siteTitle,
                files: siteFiles,
                textCopy: SitePublishing.visibleText(ofHTML: indexHTML),
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
            teamCopyIDs: teamCopyIDs,
            broughtHome: broughtHome,
            broughtHomeFrom: broughtHomeFrom
        )
    }

    // MARK: publish_site

    /// Put a copy of a site on the web at `sites.foreverlm.com/<slug>/` — the
    /// one step that hosts anything. The library's files are what go up; with
    /// files passed, they are saved into the library first, exactly as
    /// `save_site` would. Hosting costs ForeverLM money per site, so it is
    /// never a side effect of making one (product owner, 2026-09-22: "ultimately
    /// that should be a paid feature"). The record keeps its library address;
    /// the service knows the site by the record's id.
    func publishSite(
        site: String?,
        title: String?,
        html: String?,
        files rawFiles: [Any]?,
        repository: String?,
        repositoryPath: String?,
        ref: String?,
        slug rawSlug: String?,
        visibility rawVisibility: String? = nil,
        includeSourceFiles: Bool = false,
        removeFiles: [String] = [],
        replaceAll: Bool = false,
        homeNotebookID: String?,
        notebookIDs: [String],
        readRepository: SiteRepositoryReader? = nil,
        hosting: SiteHosting = SiteHosting()
    ) async throws -> String {
        guard hosting.isSignedIn else { throw MCPError.invalidInput(Self.siteSignedOutMessage) }
        let visibility = try Self.siteVisibility(rawVisibility)
        let customSlug = try Self.customSiteSlug(rawSlug)

        let hasFiles = (html?.isEmpty == false) || !(rawFiles ?? []).isEmpty
            || Self.trimmedOrNil(repository) != nil
        var saved: SiteSave? = nil
        let artifact: ArtifactRecord
        // A record brought home from sites.foreverlm.com just now goes back
        // to the address it had unless the call names another.
        var formerSlug: String? = nil
        if hasFiles {
            let result = try await saveSiteFiles(
                site: site, title: title, html: html, files: rawFiles,
                repository: repository, repositoryPath: repositoryPath, ref: ref,
                removeFiles: removeFiles, replaceAll: replaceAll,
                homeNotebookID: homeNotebookID, notebookIDs: notebookIDs,
                readRepository: readRepository, hosting: hosting
            )
            saved = result
            artifact = result.artifact
            formerSlug = result.broughtHomeFrom
        } else {
            guard let handle = Self.trimmedOrNil(site) else {
                throw MCPError.invalidInput("site is required: the site to publish, by its site_id from save_site or the Sites list — or pass files to save and publish a new one.")
            }
            guard let found = try await existingSiteArtifact(handle: handle, hosting: hosting) else {
                throw MCPError.invalidInput("No site or animation of yours is named \(handle).")
            }
            let home = try await bringSiteHomeIfHosted(found, hosting: hosting)
            artifact = home.artifact
            if home.broughtHome { formerSlug = HostedSiteAdoption.hostedSlug(of: found) }
        }
        guard let files = try await notebookFileStorage.localSiteFiles(artifactID: artifact.id), !files.isEmpty else {
            throw MCPError.invalidInput("‘\(artifact.title)’ has no files in the library to publish.")
        }
        let published = try await publishSavedSite(
            artifact,
            files: files,
            slug: customSlug ?? formerSlug,
            visibility: visibility,
            includeSourceFiles: includeSourceFiles,
            source: saved?.repositorySource,
            hosting: hosting
        )

        let noun = artifact.isAnimation ? "animation" : "site"
        var message = ""
        if let saved {
            message += saveMessage(saved, noun: noun, section: artifact.isAnimation ? "Animations" : "Sites", tool: artifact.isAnimation ? "save_animation" : "save_site", publishing: true) + " "
        }
        message += "‘\(artifact.title)’ is published at \(published.status.url.absoluteString) with \(published.status.filePaths.count) file\(published.status.filePaths.count == 1 ? "" : "s"). "
        message += Self.accessSentence(published.access)
        message += "The library keeps the \(noun) itself; unpublish_site takes this copy down and leaves the \(noun) in the library. Saving it again updates the published page too."
        if !published.sourceCards.files.isEmpty {
            message += " \(published.sourceCards.files.count) stored PDF\(published.sourceCards.files.count == 1 ? "" : "s") travel\(published.sourceCards.files.count == 1 ? "s" : "") with the published copy under \(SiteSourceCards.sourceFolder)/; on the web those cards open the PDF and keep the publisher link."
        }
        if !published.sourceCards.skippedFiles.isEmpty {
            message += " Not attached: \(published.sourceCards.skippedFiles.joined(separator: "; "))."
        }
        var payload: [String: Any] = saved.map { savePayload($0) } ?? ["site_id": artifact.id, "title": artifact.title, "doc": artifactPayload(artifact)]
        payload["status"] = "published"
        payload["url"] = published.status.url.absoluteString
        payload["published_url"] = published.status.url.absoluteString
        payload["library_url"] = artifact.linkedURL ?? LinkedPage.localSiteURL(artifactID: artifact.id).absoluteString
        payload["slug"] = published.status.slug
        payload["custom_address"] = published.status.isCustomSlug
        payload["published_files"] = published.status.filePaths.count
        payload["published_at"] = ISO8601DateFormatter().string(from: published.status.publishedAt)
        payload["updated_at"] = ISO8601DateFormatter().string(from: published.status.updatedAt)
        payload["access"] = published.access.visibility == .publicSite ? "public" : (published.access.teamID == nil ? "owner" : "team")
        payload["visibility"] = published.access.visibility.rawValue
        if let teamID = published.access.teamID { payload["team_id"] = teamID }
        if let source = published.status.source ?? saved?.repositorySource { payload["source"] = source.payload }
        if !published.sourceCards.files.isEmpty { payload["source_files"] = published.sourceCards.files }
        if !published.sourceCards.skippedFiles.isEmpty { payload["skipped_source_files"] = published.sourceCards.skippedFiles }
        payload["message"] = message
        return try jsonString(payload)
    }

    /// Upload the library's files as the record's published copy. The source
    /// cards are remade for the web, a linked paper's PDF joins only when
    /// asked (and a paywalled one only when this publish makes the copy
    /// private), and a file over the inline limit is streamed after the
    /// publish.
    func publishSavedSite(
        _ artifact: ArtifactRecord,
        files: [SiteFile],
        slug: String?,
        visibility: SitePublishingAccess.Visibility?,
        includeSourceFiles: Bool,
        source: SitePublishingSource?,
        hosting: SiteHosting
    ) async throws -> (status: PublishedSiteStatus, access: SitePublishingAccess, sourceCards: SiteSourceCards.Attachment) {
        let current: PublishedSiteStatus?
        do {
            current = try await hosting.status(artifact.id)
        } catch let error as DocPublishingError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        var teamID = artifact.teamID
        if teamID == nil {
            teamID = try await notebookFileStorage.teamsHoldingArtifact(artifact.id).first?.id
        }
        var siteFiles = files
        let siteTeamID = teamID
        let sourceCards = await SiteSourceCards.attach(
            to: &siteFiles,
            includeSourceFiles: includeSourceFiles,
            paywalledAllowed: visibility == .privateSite || (current == nil && visibility == nil),
            lookup: { token in await self.siteSourceCard(forToken: token) },
            lookupAddresses: { addresses in
                await self.siteSourceCards(forWebAddresses: addresses, teamID: siteTeamID)
            }
        )
        siteFiles = siteFiles.map { file in
            var file = file
            if file.data.count > SitePublishing.maxFileBytes { file.upload = true }
            return file
        }
        guard siteFiles.reduce(0, { $0 + $1.data.count }) <= SitePublishing.maxSiteBytes else {
            throw MCPError.invalidInput("The published copy would come to more than \(SitePublishing.maxSiteBytes / 1_000_000) MB.")
        }
        let resolvedAccess: SitePublishingAccess
        do {
            resolvedAccess = try await notebookFileStorage.sitePublishingAccess(
                existingTeamID: teamID,
                homeNotebookID: nil,
                linkedNotebookIDs: [],
                visibility: visibility ?? .privateSite
            )
        } catch {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        // A first publish is private unless the learner asks for public; an
        // update that omits visibility keeps the live choice.
        let accessForPublish = current != nil && visibility == nil ? nil : resolvedAccess
        let status: PublishedSiteStatus
        do {
            status = try await hosting.publish(artifact.id, artifact.title, siteFiles, slug, source ?? current?.source, accessForPublish)
        } catch let error as DocPublishingError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        return (status, status.access ?? accessForPublish ?? resolvedAccess, sourceCards)
    }

    /// After a save: a site already published is republished with the
    /// change; nil when it is not published or the Mac is signed out.
    func republishIfPublished(_ saved: SiteSave, hosting: SiteHosting) async -> Result<PublishedSiteStatus, Error>? {
        guard hosting.isSignedIn, !saved.created,
              let current = try? await hosting.status(saved.artifact.id) else { return nil }
        do {
            let published = try await publishSavedSite(
                saved.artifact,
                files: saved.files,
                slug: nil,
                visibility: nil,
                includeSourceFiles: current.filePaths.contains { $0.hasPrefix(SiteSourceCards.sourceFolder + "/") },
                source: saved.repositorySource,
                hosting: hosting
            )
            return .success(published.status)
        } catch {
            return .failure(error)
        }
    }

    // MARK: read_site_file

    /// One file of a site in the library, or — with no path — the list of its
    /// files, so a chat about to change a site can see what it has without
    /// reading each file back.
    func readSiteFile(
        site: String,
        path rawPath: String?,
        hosting: SiteHosting = SiteHosting()
    ) async throws -> String {
        let artifact = try await librarySite(site, hosting: hosting)
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
        guard let path = SitePublishing.normalizePath(rawPath) else {
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
        } else if data.count > SitePublishing.maxFileBytes {
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
    /// `save_site` takes, so every other file and the team copies are kept
    /// (and a published copy is updated). `path` is the file inside the site,
    /// or the page's address (the web view's current URL), or nothing for the
    /// entry page.
    func replaceSiteText(
        site: String,
        find: String,
        replace: String,
        path rawPath: String?,
        hosting: SiteHosting = SiteHosting()
    ) async throws -> String {
        guard !SiteTextEdit.lines(of: find).isEmpty else {
            throw MCPError.invalidInput(SiteTextEdit.Failure.emptySelection.localizedDescription)
        }
        let artifact = try await librarySite(site, hosting: hosting)
        let stored = (try await notebookFileStorage.localSiteFilePaths(artifactID: artifact.id) ?? []).filter { !SiteSourceCards.isGenerated($0) }
        let path: String
        if let rawPath = Self.trimmedOrNil(rawPath) {
            if let url = URL(string: rawPath), let scheme = url.scheme?.lowercased(),
               ["https", "http", LinkedPage.localSiteScheme].contains(scheme) {
                guard let resolved = Self.storedSitePath(forPage: url, filePaths: stored) else {
                    throw MCPError.invalidInput("\(rawPath) is not a page of ‘\(artifact.title)’. Its files: \(Self.pathList(stored)).")
                }
                path = resolved
            } else {
                guard let normalized = SitePublishing.normalizePath(rawPath) else {
                    throw MCPError.invalidInput("path must be a file path inside the site, such as index.html or about.html, or the page's address.")
                }
                guard let match = stored.first(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) else {
                    throw MCPError.invalidInput("The site has no file \(normalized). Its files: \(Self.pathList(stored)).")
                }
                path = match
            }
        } else {
            path = SitePublishing.entryFile
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
            readRepository: nil, hosting: hosting,
            allowAnimation: true
        )
        let republished = await republishIfPublished(saved, hosting: hosting)
        let before = change.found.replacingOccurrences(of: "\n", with: " / ")
        let after = change.replacement.isEmpty ? "(removed)" : change.replacement.replacingOccurrences(of: "\n", with: " / ")
        var message = "Changed one passage of \(path) on ‘\(artifact.title)’: “\(before)” is now “\(after)”. Every other file is as it was."
        if case .success(let status)? = republished {
            message += " The published page at \(status.url.absoluteString) was updated too."
        } else if case .failure(let error)? = republished {
            message += " The published page could not be updated (\(error.localizedDescription)); publish_site tries again."
        }
        let base = saved.artifact.linkedURL.flatMap(URL.init(string:)) ?? LinkedPage.localSiteURL(artifactID: saved.artifact.id)
        let pageURL = path == SitePublishing.entryFile ? base : base.appendingPathComponent(path)
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

    // MARK: unpublish_site

    /// Take a site's (or an animation's) published copy off the web. The
    /// library keeps the site; only the hosted copy goes. A record made before
    /// 2026-09-22 whose files still live only on the web is brought home
    /// first, which is itself the take-down.
    func unpublishSite(
        site: String,
        hosting: SiteHosting = SiteHosting()
    ) async throws -> String {
        guard hosting.isSignedIn else { throw MCPError.invalidInput(Self.siteSignedOutMessage) }
        guard let handle = Self.trimmedOrNil(site) else {
            throw MCPError.invalidInput("site is required: the site's site_id from save_site or the Sites list.")
        }
        guard let found = try await existingSiteArtifact(handle: handle, hosting: hosting) else {
            throw MCPError.invalidInput("No site or animation of yours is named \(handle).")
        }
        let home = try await bringSiteHomeIfHosted(found, hosting: hosting)
        let wasPublished: Bool
        if home.broughtHome {
            wasPublished = true
        } else {
            do {
                wasPublished = try await hosting.unpublish(home.artifact.id)
            } catch let error as DocPublishingError {
                throw MCPError.invalidInput(error.localizedDescription)
            }
        }
        let noun = home.artifact.isAnimation ? "animation" : "site"
        return try jsonString([
            "status": wasPublished ? "unpublished" : "not_published",
            "site": home.artifact.id,
            "was_published": wasPublished,
            "removed_from_sites": false,
            "message": wasPublished
                ? "‘\(home.artifact.title)’ is no longer on the web; its published link stops working. The \(noun) stays in the library\(home.broughtHome ? ", its files now kept there" : "")."
                : "‘\(home.artifact.title)’ was not published; nothing changed. The \(noun) is in the library.",
        ] as [String: Any])
    }

    // MARK: Resolving a site

    /// The record id in a `foreverlm-site://` address, the slug in a
    /// sites.foreverlm.com address, or the argument itself trimmed. Never nil
    /// for non-empty input. Shared with the animation tools.
    static func siteHandle(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let id = LinkedPage.localSiteID(from: url) { return id }
        if text.contains("sites.foreverlm.com"), let url = URL(string: text.contains("://") ? text : "https://\(text)"),
           let slug = LinkedPage.foreverlmSiteSlug(from: url) {
            return slug
        }
        return text
    }

    /// The Sites or Animations entry a handle names — by record id, by its
    /// library address, by a sites.foreverlm.com address it still points at,
    /// or by the slug of its published copy — when this library has one.
    ///
    /// The learner's own entry is the site's anchor: a team's copy is found
    /// by its id too, but answered with the entry in My Library when there is
    /// one, so a change is made once and flows to the copies.
    func existingSiteArtifact(handle: String?, hosting: SiteHosting = SiteHosting()) async throws -> ArtifactRecord? {
        guard let handle = handle.flatMap(Self.siteHandle)?.lowercased() else { return nil }
        let artifacts = try await notebookFileStorage.loadArtifacts(notebookID: nil)
            .filter { $0.linkedKind == .foreverlmSite }
        // Only a handle that could be a slug names a hosted address; anything
        // else (an id, a stray word) is matched by id alone.
        let isSlug = SitePublishing.normalizeCustomSlug(handle) == handle
        let hostedURL = isSlug ? LinkedPage.foreverlmSiteURL(slug: handle).absoluteString : nil
        var match = artifacts.first(where: { $0.id.lowercased() == handle })
        if match == nil, let hostedURL {
            match = artifacts.first(where: { $0.teamID == nil && $0.linkedURL == hostedURL })
                ?? artifacts.first(where: { $0.linkedURL == hostedURL })
        }
        if match == nil, hosting.isSignedIn, isSlug,
           let status = try? await hosting.status(handle) {
            // The slug of a published copy: the service knows it by the id
            // of the record it was published from.
            match = artifacts.first(where: { $0.id == status.siteID })
        }
        guard let match else { return nil }
        guard let teamID = match.teamID else { return match }
        return artifacts.first(where: { original in
            original.teamID == nil
                && (original.linkedURL == match.linkedURL
                    || TeamContentIdentity.artifactCopyID(teamID: teamID, original: original) == match.id)
        }) ?? match
    }

    /// The site a handle names, with its files in the library — brought home
    /// first when it is a record that still points at sites.foreverlm.com.
    func librarySite(_ handle: String, hosting: SiteHosting) async throws -> ArtifactRecord {
        guard let text = Self.trimmedOrNil(handle) else {
            throw MCPError.invalidInput("site is required: the site's site_id from save_site or the Sites list, or its address.")
        }
        guard let found = try await existingSiteArtifact(handle: text, hosting: hosting) else {
            throw MCPError.invalidInput("No site or animation of yours is named \(text).")
        }
        return try await bringSiteHomeIfHosted(found, hosting: hosting).artifact
    }

    /// A record that still points at sites.foreverlm.com has no files in the
    /// library to read or keep; its hosted files are brought home first, and
    /// the hosted copy is taken down once they have landed. Signed out, that
    /// cannot happen, and the call says so rather than leaving a hosted copy
    /// nobody can reach.
    ///
    /// A team row made before build 114 — a page published straight into a
    /// team Notebook — is brought home in place too when this account
    /// published it: the service answers a slug only for its owner's own
    /// sites, so a hosted copy it finds is ours to move. A teammate's is not,
    /// and the call names who can move it. Until 2026-09-25 every team row was
    /// refused with advice nobody could follow: the Mitochondrial Therapeutics
    /// Atlas was its owner's own, the launch pass skips team rows, and a chat
    /// asked to add one compound to it retried the refusal some sixty times.
    func bringSiteHomeIfHosted(_ artifact: ArtifactRecord, hosting: SiteHosting) async throws -> (artifact: ArtifactRecord, broughtHome: Bool) {
        guard HostedSiteAdoption.hostedSlug(of: artifact) != nil,
              try await notebookFileStorage.hasLocalSite(artifactID: artifact.id) == false else {
            return (artifact, false)
        }
        guard hosting.isSignedIn else {
            if artifact.teamID != nil {
                throw MCPError.invalidInput("‘\(artifact.title)’ is a team's site whose files are still on sites.foreverlm.com, and this Mac is signed out, so they cannot be read. Sign in with Apple in Settings › Billing: if you published it, its files are then brought into your library first. Do not retry until then.")
            }
            throw MCPError.invalidInput("‘\(artifact.title)’ was made before sites were kept in the library, and its files are still on sites.foreverlm.com. Sign in with Apple in Settings › Billing so they can be brought into your library first.")
        }
        do {
            switch try await HostedSiteAdoption.bringHome(
                artifact,
                storage: notebookFileStorage,
                status: hosting.status,
                readFile: hosting.readFile,
                unpublish: hosting.unpublish
            ) {
            case .adopted(let home):
                return (home, true)
            case .notHosted:
                if artifact.teamID != nil {
                    throw MCPError.invalidInput("‘\(artifact.title)’ is a team's site whose files are still on sites.foreverlm.com under the account of the teammate who published it, not yours, so this Mac cannot read or change them. That teammate brings them into the team's library by changing the site once from their own ForeverLM. Do not retry this or another site tool on it until then; tell the learner instead.")
                }
                throw MCPError.invalidInput("‘\(artifact.title)’ points at \(artifact.linkedURL ?? "sites.foreverlm.com"), but nothing is published there under your account, so there are no files to bring into the library.")
            }
        } catch let error as DocPublishingError {
            throw MCPError.invalidInput(error.localizedDescription)
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
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
        let removeSet = Set(removeFiles.compactMap(SitePublishing.normalizePath).map { $0.lowercased() })
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
        guard files.count <= SitePublishing.maxFiles else {
            throw MCPError.invalidInput("The \(noun) would have \(files.count) files; at most \(SitePublishing.maxFiles). Drop some with remove_files.")
        }
        let total = files.reduce(0) { $0 + $1.data.count }
        guard total <= SitePublishing.maxLocalSiteBytes else {
            throw MCPError.invalidInput("The \(noun)'s files come to \(total / 1_000_000) MB; one kept in the library can be at most \(SitePublishing.maxLocalSiteBytes / 1_000_000) MB, so it syncs through iCloud with the record. Render videos smaller or shorter, or drop files with remove_files.")
        }
    }

    /// The file a page address names inside the site: a library address
    /// (`foreverlm-site://<id>/about.html`) or a published one
    /// (`sites.foreverlm.com/<slug>/about.html`). A folder is its index.html.
    static func storedSitePath(forPage url: URL, filePaths: [String]) -> String? {
        var parts = url.pathComponents.filter { $0 != "/" }
        if url.host?.lowercased() == LinkedPage.foreverlmSitesHost {
            guard !parts.isEmpty else { return nil }
            parts.removeFirst()
        }
        var path = parts.joined(separator: "/")
        if path.isEmpty || url.path.hasSuffix("/") {
            path = path.isEmpty ? SitePublishing.entryFile : path + "/" + SitePublishing.entryFile
        }
        guard let normalized = SitePublishing.normalizePath(path) else { return nil }
        if let match = filePaths.first(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) { return match }
        let asFolder = normalized + "/" + SitePublishing.entryFile
        return filePaths.first(where: { $0.caseInsensitiveCompare(asFolder) == .orderedSame })
    }

    static func siteVisibility(_ raw: String?) throws -> SitePublishingAccess.Visibility? {
        guard let raw else { return nil }
        guard let visibility = SitePublishingAccess.Visibility(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            throw MCPError.invalidInput("visibility must be private or public.")
        }
        return visibility
    }

    static func customSiteSlug(_ raw: String?) throws -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let normalized = SitePublishing.normalizeCustomSlug(raw) else {
            throw MCPError.invalidInput("slug must be 3–64 lowercase letters, digits and single hyphens, starting and ending with a letter or digit, and not a reserved word (api, docs, sites, www…).")
        }
        return normalized
    }

    static func accessSentence(_ access: SitePublishingAccess) -> String {
        if access.visibility == .publicSite {
            return "It is public on the web; anyone can open it without signing in. "
        } else if access.teamID == nil {
            return "Only your signed-in ForeverLM account can open it. "
        }
        return "It opens for accepted members of its team after they sign in to ForeverLM. "
    }

    // MARK: Results

    func saveMessage(_ saved: SiteSave, noun: String, section: String, tool: String, publishing: Bool = false) -> String {
        let count = saved.files.count
        var message = "‘\(saved.artifact.title)’ is \(saved.created ? "saved" : "updated") in the library under \(section) with \(count) file\(count == 1 ? "" : "s"), and syncs through your iCloud like the rest of the library. "
        if !publishing {
            message += "Nothing is on the web: publish_site puts a copy there when you want a link to share. "
        }
        if saved.broughtHome {
            if let slug = saved.broughtHomeFrom, !publishing {
                message += "Its files were brought into the library from sites.foreverlm.com/\(slug)/ first, and the hosted copy was taken down; to put it back at that address, call publish_site with site \"\(saved.artifact.id)\" and slug \"\(slug)\". "
            } else {
                message += "Its files were brought into the library from sites.foreverlm.com first, and the hosted copy was taken down. "
            }
        }
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
            "published": false,
            "doc": artifactPayload(saved.artifact),
        ]
        if let source = saved.repositorySource { payload["source"] = source.payload }
        if saved.broughtHome { payload["brought_home"] = true }
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
    /// sent; the service applies the same rule. `requireEntry` is false for an
    /// update that keeps the stored files, whose index.html may be one of them.
    static func inlineSiteFiles(html: String?, files rawFiles: [Any]?, requireEntry: Bool = true) throws -> [SiteFile] {
        var files: [SiteFile] = []
        var seen = Set<String>()
        if let html, !html.isEmpty {
            files.append(SiteFile(path: SitePublishing.entryFile, data: Data(html.utf8)))
            seen.insert(SitePublishing.entryFile)
        }
        for (index, entry) in (rawFiles ?? []).enumerated() {
            guard let object = entry as? [String: Any], let rawPath = object["path"] as? String else {
                throw MCPError.invalidInput("files[\(index)] must be an object with path and content (text) or content_base64 (bytes).")
            }
            guard let path = SitePublishing.normalizePath(rawPath) else {
                throw MCPError.invalidInput("files[\(index)].path ‘\(rawPath)’ is not a file path a site can serve: relative, forward slashes, letters, digits, dots, hyphens and underscores, no dot segments.")
            }
            guard !seen.contains(path.lowercased()) else {
                throw MCPError.invalidInput(path == SitePublishing.entryFile && html != nil
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
        guard files.count <= SitePublishing.maxFiles else {
            throw MCPError.invalidInput("A site can have at most \(SitePublishing.maxFiles) files.")
        }
        guard !requireEntry || seen.contains(SitePublishing.entryFile) else {
            throw MCPError.invalidInput("A site needs an \(SitePublishing.entryFile) at its root — pass it as html, or as a file named index.html.")
        }
        for file in files where file.data.count > SitePublishing.maxFileBytes {
            throw MCPError.invalidInput("\(file.path) is \(file.data.count / 1000) KB; a file can be at most \(SitePublishing.maxFileBytes / 1_000_000) MB.")
        }
        guard files.reduce(0, { $0 + $1.data.count }) <= SitePublishing.maxInlineBytes else {
            throw MCPError.invalidInput("The files passed inline can be at most \(SitePublishing.maxInlineBytes / 1_000_000) MB together; a site's stored PDFs travel separately (include_source_files).")
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
            throw MCPError.invalidInput("\(fullName) has more files under \(folder.isEmpty ? "its root" : folder) than can be read in one publish. Pass repository_path pointing at the folder that holds just the site.")
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
            guard let sitePath = SitePublishing.normalizePath(relative) else {
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
            source: SitePublishingSource(repository: fullName, ref: resolvedRef, path: folder.isEmpty ? nil : folder, commit: commit),
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
/// on the web the same link was dead text, and a model that could not reach
/// the library's pictures drew its own. So at publish the Mac looks up every
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
    /// Where a linked paper's stored PDF goes when the publish asks for it.
    static let sourceFolder = "foreverlm/sources"
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
        /// The source's own file inside the site — a paper's PDF — when the
        /// publish attached it; a browser card opens this and keeps `url`.
        var file: String?
    }

    /// A source's stored file, as the library holds it on this Mac.
    struct SourceFile: Equatable {
        var path: String
        var bytes: Int
        /// The library's paywall flag: a publisher's PDF that must not go on
        /// the open web.
        var isPaywalled: Bool
    }

    /// What the library said about a link's token.
    struct Lookup {
        var card: Card
        /// The rendered picture, when the source has a file to render one from.
        var thumbnailJPEG: Data?
        /// The source's own PDF, when it has one on this Mac.
        var sourceFile: SourceFile? = nil
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
        /// The stored PDFs attached, as paths inside the site.
        var files: [String] = []
        /// PDFs asked for but left out, each with its reason.
        var skippedFiles: [String] = []
    }

    static func isHTML(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".html") || lower.hasSuffix(".htm")
    }

    /// A path ForeverLM writes: the card script and every thumbnail.
    static func isGenerated(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower == scriptPath || lower.hasPrefix(thumbnailFolder + "/") || lower.hasPrefix(sourceFolder + "/")
    }

    /// Where a source's PDF is stored in the site, by the same naming as its picture.
    static func sourceFilePath(forSourceID id: String, taken: Set<String>) -> String {
        thumbnailPath(forSourceID: id, taken: taken)
            .replacingOccurrences(of: "^\(thumbnailFolder)/", with: "\(sourceFolder)/", options: .regularExpression)
            .replacingOccurrences(of: "\\.jpg$", with: ".pdf", options: .regularExpression)
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
            let address = SitePublishing.decodeEntities(String(html[swiftRange])).trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// A paper's stored PDF on this Mac, sized, or nil for any other source or
    /// a paper whose file is not here.
    static func sourceFile(for article: StudioArticle) async -> SourceFile? {
        guard article.sourceType == .paper else { return nil }
        return await Task.detached(priority: .utility) { () -> SourceFile? in
            guard let path = SourceArtwork.filePath(for: article), path.lowercased().hasSuffix(".pdf"),
                  let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue, bytes > 0 else { return nil }
            return SourceFile(path: path, bytes: bytes, isPaywalled: article.isPaywalled)
        }.value
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
    ///
    /// With `includeSourceFiles`, a linked paper's stored PDF is attached too,
    /// once per source, as a streamed upload when it is too big for the
    /// publish body — unless it is over the upload limit, would take the site
    /// over its limit, or is paywalled while `paywalledAllowed` is false (the
    /// Site is, or may be, public). Each PDF left out is named with its reason.
    static func attach(
        to files: inout [SiteFile],
        includeSourceFiles: Bool = false,
        paywalledAllowed: Bool = false,
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
        var sourceFiles: [SiteFile] = []
        var sourceFilePaths: [String: String] = [:]
        var skippedSources = Set<String>()
        var taken = Set(files.map { $0.path.lowercased() })
        var siteBytes = files.reduce(0) { $0 + $1.data.count }
        for (key, item) in resolved {
            var found = item
            if includeSourceFiles, let source = found.sourceFile {
                let id = found.card.sourceID
                if let stored = sourceFilePaths[id] {
                    found.card.file = stored
                } else if !skippedSources.contains(id) {
                    let megabytes = String(format: "%.1f", Double(source.bytes) / 1_000_000)
                    if source.isPaywalled && !paywalledAllowed {
                        skippedSources.insert(id)
                        attachment.skippedFiles.append("\(found.card.title): the library marks it paywalled, so its PDF stays off a public Site (publish with visibility private to attach it)")
                    } else if source.bytes > SitePublishing.maxUploadFileBytes {
                        skippedSources.insert(id)
                        attachment.skippedFiles.append("\(found.card.title): its PDF is \(megabytes) MB, over the \(SitePublishing.maxUploadFileBytes / 1_000_000) MB limit for one file")
                    } else if siteBytes + source.bytes > SitePublishing.maxSiteBytes {
                        skippedSources.insert(id)
                        attachment.skippedFiles.append("\(found.card.title): its \(megabytes) MB PDF would take the site over \(SitePublishing.maxSiteBytes / 1_000_000) MB")
                    } else if files.count + thumbnails.count + sourceFiles.count + 2 > SitePublishing.maxFiles {
                        skippedSources.insert(id)
                        attachment.skippedFiles.append("\(found.card.title): the site already has \(SitePublishing.maxFiles) files")
                    } else if let data = try? Data(contentsOf: URL(fileURLWithPath: source.path), options: .mappedIfSafe), !data.isEmpty {
                        let path = sourceFilePath(forSourceID: id, taken: taken)
                        taken.insert(path.lowercased())
                        sourceFiles.append(SiteFile(path: path, data: data, upload: data.count > SitePublishing.maxFileBytes))
                        sourceFilePaths[id] = path
                        siteBytes += data.count
                        found.card.file = path
                    } else {
                        skippedSources.insert(id)
                        attachment.skippedFiles.append("\(found.card.title): its PDF could not be read on this Mac")
                    }
                }
            }
            if let jpeg = found.thumbnailJPEG {
                if let stored = thumbnailPaths[found.card.sourceID] {
                    found.card.thumbnail = stored
                } else if files.count + thumbnails.count + sourceFiles.count + 1 < SitePublishing.maxFiles {
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
        // Uploads last: the publish stands with its pages before the PDFs stream in.
        files.append(contentsOf: sourceFiles)
        attachment.files = sourceFiles.map(\.path)
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
      .trail { align-items:flex-end; display:flex; flex:0 0 auto; flex-direction:column; gap:3px; }
      .tag { color:inherit; font-size:10px; font-weight:650; letter-spacing:.04em; opacity:.55; }
      .publisher { color:inherit; cursor:pointer; font-size:10px; opacity:.6; text-decoration:underline; }
      .publisher:hover { opacity:.95; }
    """

    /// The script a site serves. It mirrors the app's `sourceLinkScript`: the
    /// same notion of a source link — a `foreverlm://source/<id>` token, or a
    /// web address the library answered to at publish — the same rule for
    /// which links become cards (a link standing alone in its element, or one
    /// marked `data-foreverlm-source-card`; a link by address never inside the
    /// page's nav, header or footer), the same card. Two things differ. The
    /// cards are the ones written in at publish, so nothing is fetched — a
    /// sandboxed page cannot rely on storage or a session — and the pictures
    /// are the site's own files, found relative to the script. And the click
    /// goes to the source's public page in a new tab, because a browser has no
    /// Reader — or to the source's PDF when the publish attached it, with the
    /// publisher page as a small link beside the card; in the app, whose
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
          // at publish under the address as the page wrote it. Any other
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
        var opens = card.file ? assetURL(card.file) : card.url;
        if (opens) {
          anchor.setAttribute('href', opens);
          anchor.setAttribute('target', '_blank');
          anchor.setAttribute('rel', 'noopener');
          anchor.setAttribute('aria-label', 'Open ' + card.title + (card.file ? ' (PDF)' : ''));
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
        var trail;
        if (card.file) {
          trail = document.createElement('span');
          trail.className = 'trail';
          var tag = document.createElement('span');
          tag.className = 'tag';
          tag.textContent = 'PDF \u2197';
          trail.append(tag);
          if (card.url) {
            var publisher = document.createElement('span');
            publisher.className = 'publisher';
            publisher.setAttribute('role', 'link');
            publisher.setAttribute('tabindex', '0');
            publisher.textContent = 'Publisher';
            var openPublisher = function (event) {
              event.preventDefault();
              event.stopPropagation();
              try { window.open(card.url, '_blank', 'noopener'); } catch (_) {}
            };
            publisher.addEventListener('click', openPublisher);
            publisher.addEventListener('keydown', function (event) { if (event.key === 'Enter' || event.key === ' ') { openPublisher(event); } });
            trail.append(publisher);
          }
        } else {
          trail = document.createElement('span');
          trail.className = 'arrow';
          trail.setAttribute('aria-hidden', 'true');
          trail.textContent = card.url ? '\u2197' : '';
        }
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
            thumbnailJPEG: await SiteSourceCards.thumbnailJPEG(for: article),
            sourceFile: await SiteSourceCards.sourceFile(for: article)
        )
    }
}
