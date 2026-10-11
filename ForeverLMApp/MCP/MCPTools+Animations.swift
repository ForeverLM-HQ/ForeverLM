import Foundation

// MARK: - Animations: moving explanations of a source, kept like a site

/// `save_animation`, `list_animations` and `delete_animation`: an animation is
/// how something in a source works, drawn as code — HTML, SVG and script that
/// plays and can be scrubbed or toggled, or a video file a tool such as Manim
/// rendered — by the chat here or by Claude or Codex through the plugin, and
/// kept in the library linked to the sources it explains.
///
/// The product owner (2026-09-17), on a paper about empagliflozin and cardiac
/// energetics: "I would like to see an animation of how it's working and
/// affecting the Krebs cycle, ETC; and which of those steps are in the
/// mitochondria versus not … if I could actually see the flow of electrons
/// and the intermediates being generated, either with EMPA or without it."
/// And: "I also need to be able to do this in Codex or Claude and then use
/// MCP to save the actual animation in ForeverLM."
///
/// The files are kept exactly as a Site's are — in the library, under the
/// record's folder, synced through the learner's iCloud with the record, and
/// served in the app from `foreverlm-site://<id>/` under the same sandbox and
/// source cards — and the record is the same page a Site gets, with two
/// things of its own: `kind = animation`, which puts it under Animations
/// rather than Sites, and `sourceIDs`, the sources it is about. Like a Site,
/// it is never put on the web. Spec: docs/animations-design.md.
extension MCPDataStore {

    /// Video files a rendered animation arrives as. One of these alone, with
    /// no entry page, gets a player page written for it.
    static let animationVideoExtensions: Set<String> = ["mp4", "webm", "mov", "m4v"]

    /// The path a lone video is served under when the caller passed no page.
    static let animationPlayerPage = LocalSite.entryFile

    /// What resolving a `sources` argument found.
    struct AnimationSources: Equatable {
        /// Library source ids, in the order first named, each once.
        var resolved: [String] = []
        /// Tokens no source answered to, as passed.
        var unresolved: [String] = []
    }

    // MARK: save_animation

    func saveAnimation(
        animation: String?,
        title: String?,
        description rawDescription: String?,
        html: String?,
        files rawFiles: [Any]?,
        sources rawSources: [String],
        removeFiles: [String] = [],
        replaceAll: Bool = false,
        homeNotebookID: String?,
        notebookIDs: [String],
        readLocalFile: @Sendable (String) throws -> Data = { try Data(contentsOf: URL(fileURLWithPath: $0), options: [.mappedIfSafe]) }
    ) async throws -> String {
        // The animation being updated, when the handle names one. A handle
        // that names a Site is refused rather than quietly re-kinded: the
        // Site's own tool changes it. A handle that names nothing here is
        // refused too — an update is of something this library has.
        var existing: ArtifactRecord? = nil
        if let handle = Self.trimmedOrNil(animation) {
            guard let found = try await existingSiteArtifact(handle: handle) else {
                throw MCPError.invalidInput("No animation of yours is named \(handle). Pass the animation_id from save_animation or list_animations, or omit animation to save a new one.")
            }
            guard found.isAnimation else {
                throw MCPError.invalidInput("‘\(found.title)’ is a Site, not an animation. Change it with save_site, or omit animation to save a new animation.")
            }
            existing = found
        }

        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression) ?? ""
        guard !trimmedTitle.isEmpty || existing?.title.isEmpty == false else {
            throw MCPError.invalidInput("title is required for a new animation: what the Animations list and the page call it.")
        }
        let animationTitle = trimmedTitle.isEmpty ? existing!.title : trimmedTitle
        let description = rawDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // The sources it is about. A new animation that names sources none
        // of which resolve is refused: a typo must never save an unlinked
        // animation as if it were linked. No sources at all is allowed — a
        // concept the learner named — and the result says so.
        let sources = try resolveAnimationSources(rawSources)
        if existing == nil, !rawSources.isEmpty, sources.resolved.isEmpty {
            throw MCPError.invalidInput("No library source answers to \(sources.unresolved.joined(separator: ", ")). Pass the source ids from list_sources or search_sources_semantic, a foreverlm://source/<id> link, or a web address the library holds (a DOI, an arXiv page) — or pass sources: [] for an animation about no source.")
        }

        // The files: inline (content, content_base64) or read from this Mac
        // (local_path) — the route a video rendered here takes, since a
        // 20 MB file has no business travelling as base64 inside a tool call.
        let (inlineEntries, localEntries) = try Self.splitAnimationFiles(rawFiles)
        let merging = existing != nil && !replaceAll
        var siteFiles = try Self.inlineSiteFiles(html: html, files: inlineEntries.isEmpty ? nil : inlineEntries, requireEntry: false)
        for entry in localEntries {
            let file = try Self.localSiteFile(entry, validate: { try self.validateClientProvidedPath($0) }, read: readLocalFile)
            guard !siteFiles.contains(where: { $0.path.lowercased() == file.path.lowercased() }) else {
                throw MCPError.invalidInput("The file \(file.path) appears twice.")
            }
            siteFiles.append(file)
        }
        guard !siteFiles.isEmpty else {
            throw MCPError.invalidInput("Pass the animation's files: html for a one-page animation, or files — HTML, SVG, CSS and JavaScript with index.html at the root, or one video file (mp4, webm, mov, m4v) with or without a page around it. A file can be passed as content, content_base64, or local_path to a file on this Mac.")
        }

        var kept: [String] = []
        var removed: [String] = []
        if merging, let existing {
            let stored = try await notebookFileStorage.localSiteFiles(artifactID: existing.id) ?? []
            let merge = try Self.mergeStoredSiteFiles(into: &siteFiles, stored: stored, removeFiles: removeFiles)
            kept = merge.kept
            removed = merge.removed
        }

        // A lone video with no page around it gets one: the title, the
        // description and a looping player, from a fixed template.
        var playerPageWritten = false
        if !siteFiles.contains(where: { $0.path == LocalSite.entryFile }) {
            let videos = siteFiles.filter { Self.isAnimationVideoPath($0.path) }
            guard videos.count == 1 else {
                throw MCPError.invalidInput(videos.isEmpty
                    ? "The animation would have no \(LocalSite.entryFile): pass one as html or as a file named index.html, or pass exactly one video file (mp4, webm, mov, m4v) and a player page is written for it."
                    : "Several video files and no \(LocalSite.entryFile): pass a page that plays them, or one video at a time.")
            }
            let page = Self.animationPlayerHTML(title: animationTitle, description: description, videoPath: videos[0].path)
            siteFiles.insert(SiteFile(path: Self.animationPlayerPage, data: Data(page.utf8)), at: 0)
            playerPageWritten = true
        }

        // Library sources the pages link draw as the app's banner cards,
        // exactly as on a Site. The sources it is about are named on the
        // record. Where it is filed follows decision 17 of the teams design:
        // the learner's own entry takes the Notebooks of My Library, and a
        // team named through one of its Notebooks gets a copy.
        let filing = try await pageFiling(existing: existing, homeNotebookID: homeNotebookID, notebookIDs: notebookIDs)
        var existingTeamID = existing?.teamID
        if existingTeamID == nil, let existing {
            existingTeamID = try await notebookFileStorage.teamsHoldingArtifact(existing.id).first?.id
        }
        let animationTeamID = existingTeamID ?? filing.teamNotebookIDs.keys.sorted().first
        let sourceCards = await SiteSourceCards.attach(
            to: &siteFiles,
            lookup: { token in await self.siteSourceCard(forToken: token) },
            lookupAddresses: { addresses in
                await self.siteSourceCards(forWebAddresses: addresses, teamID: animationTeamID)
            }
        )
        try Self.checkLocalSiteSize(siteFiles, noun: "animation")

        // What chat, review and search read of it: the description, the
        // page's visible text, and the sources by name. An update that names
        // sources replaces them; one that names none keeps what it had.
        let sourceIDs = existing == nil ? sources.resolved : (sources.resolved.isEmpty ? existing!.sourceIDs : sources.resolved)
        let indexHTML = siteFiles.first(where: { $0.path == LocalSite.entryFile }).flatMap { String(data: $0.data, encoding: .utf8) } ?? ""
        let textCopy = Self.animationTextCopy(
            description: description,
            pageText: LocalSite.visibleText(ofHTML: indexHTML),
            sourceTitles: try animationSourceDescriptors(for: sourceIDs).map { $0["title"] as? String ?? "" }
        )
        var artifact: ArtifactRecord
        do {
            artifact = try await notebookFileStorage.saveLocalSite(
                artifactID: existing?.id,
                title: animationTitle,
                files: siteFiles,
                textCopy: textCopy,
                homeNotebookID: filing.homeNotebookID,
                linkedNotebookIDs: filing.linkedNotebookIDs,
                kind: .animation,
                sourceIDs: sourceIDs
            )
        } catch let error as ArtifactError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        if existing != nil, !sources.resolved.isEmpty {
            artifact = try await notebookFileStorage.setArtifactGrounding(artifactID: artifact.id, sourceIDs: sources.resolved)
        }
        let teamCopyIDs = try await refreshTeamCopies(ofPage: artifact.id, previouslyIn: existing?.teamID, filing: filing)
        let saved = SiteSave(
            artifact: artifact,
            created: existing == nil,
            files: siteFiles,
            kept: kept,
            removed: removed,
            sourceCards: sourceCards,
            teamCopyIDs: teamCopyIDs
        )

        let sourceDescriptors = try animationSourceDescriptors(for: artifact.sourceIDs)
        var message = saveMessage(saved, noun: "animation", section: "Animations", tool: "save_animation") + " "
        if sourceDescriptors.isEmpty {
            message += "It is about no library source; pass sources to link it to the papers or articles it explains. "
        } else {
            let names = sourceDescriptors.compactMap { $0["title"] as? String }
            message += "It is linked to \(names.count) source\(names.count == 1 ? "" : "s"): \(names.joined(separator: "; ")). "
        }
        if !sources.unresolved.isEmpty {
            message += "No library source answers to \(sources.unresolved.joined(separator: ", ")); check the ids with list_sources. "
        }
        if playerPageWritten {
            message += "A player page was written around the video."
        }

        var payload = savePayload(saved)
        payload["animation_id"] = artifact.id
        payload["section"] = ArtifactSection.animations.rawValue
        payload["sources"] = sourceDescriptors
        payload["player_page_written"] = playerPageWritten
        payload.removeValue(forKey: "unresolved_sources")
        if !sources.unresolved.isEmpty { payload["unresolved_sources"] = sources.unresolved }
        if !sourceCards.unresolved.isEmpty { payload["unresolved_page_links"] = sourceCards.unresolved }
        payload["message"] = message
        return try jsonString(payload)
    }

    // MARK: list_animations

    /// Every animation, or only those about one source. The source may be
    /// named the way `sources` names one: an id, a unique prefix, a
    /// `foreverlm://source/<id>` link, or a web address the library holds.
    func listAnimations(sourceID rawSourceID: String?, notebookID: String? = nil) async throws -> String {
        // notebook_id: only the animations filed in that notebook — its home
        // or a link (`NotebookMembership`); explaining one of its sources is
        // not enough.
        let notebook = try await notebookMembershipForListing(notebookID: notebookID)
        var scopedSourceID: String? = nil
        if let token = Self.trimmedOrNil(rawSourceID) {
            let found = try resolveAnimationSources([token])
            guard let resolved = found.resolved.first else {
                throw MCPError.invalidInput("No library source answers to \(token). Pass a source id from list_sources or search_sources_semantic, a foreverlm://source/<id> link, or a web address the library holds.")
            }
            scopedSourceID = resolved
        }
        let screenScope = screenRecordScope()
        let animations = try await notebookFileStorage.loadArtifacts(notebookID: nil)
            .filter { $0.isAnimation && !TeamContentIdentity.isDraftArtifactID($0.id) }
            .filter { scopedSourceID == nil || $0.sourceIDs.contains(scopedSourceID!) }
            .filter { notebook?.contains($0) ?? true }
            // Screen record mode (admin only); nil scope keeps every one.
            .filter { artifact in screenScope.map { screenRecordAllowsArtifact(artifact, scope: $0) } ?? true }
            .sorted { $0.updatedAt > $1.updatedAt }
        let walked = (try? await notebookFileStorage.artifactIDsWithWalkthroughs()) ?? []
        var entries: [[String: Any]] = []
        for artifact in animations {
            var entry = artifactPayload(artifact)
            entry["has_walkthrough"] = walked.contains(artifact.id)
            entry["url"] = artifact.linkedURL.map { $0 as Any } ?? NSNull()
            entry["sources"] = try animationSourceDescriptors(for: artifact.sourceIDs)
            if let copy = try? await notebookFileStorage.artifactMarkdown(artifact.id).markdown, !copy.isEmpty {
                entry["summary"] = String(copy.prefix(280))
            }
            entries.append(entry)
        }
        var scope: [String: Any] = ["scope": scopedSourceID == nil ? (notebook == nil ? "library" : "notebook") : "source"]
        if let notebook { scope["notebook_id"] = notebook.notebookID }
        if let scopedSourceID {
            scope["source_id"] = scopedSourceID
            scope["source_title"] = try animationSourceDescriptors(for: [scopedSourceID]).first?["title"] ?? scopedSourceID
        }
        var payload: [String: Any] = scope
        payload["animation_count"] = entries.count
        payload["animations"] = entries
        payload["guidance"] = "Each animation is a moving explanation of the sources listed under sources, kept in the library (its url is the library address the app plays it from) and listed in the app's Animations section. read_doc with its id returns the description and the page's text; read_site_file with its id lists or reads its files; save_animation with animation set to its id changes only the files passed. An animation is a read-only page here — write_doc and edit_doc refuse it. has_walkthrough says whether the chat can walk the learner through it step by step (get_walkthrough / save_walkthrough with animation set to its id)."
        return try jsonString(payload)
    }

    // MARK: delete_animation

    /// Remove an animation from the library, its files with it.
    func deleteAnimation(animation rawHandle: String) async throws -> String {
        guard let handle = Self.trimmedOrNil(rawHandle) else {
            throw MCPError.invalidInput("animation is required: the animation_id from save_animation or list_animations.")
        }
        guard let existing = try await existingSiteArtifact(handle: handle) else {
            throw MCPError.invalidInput("No animation of yours is named \(handle).")
        }
        guard existing.isAnimation else {
            throw MCPError.invalidInput("‘\(existing.title)’ is a Site, not an animation; delete_doc removes a site from the library.")
        }
        try await notebookFileStorage.deleteArtifact(existing.id)
        return try jsonString([
            "status": "deleted",
            "animation_id": existing.id,
            "message": "‘\(existing.title)’ was removed from Animations with its files.",
        ])
    }

    // MARK: Sources

    /// The library sources a `sources` argument names: each token is an id
    /// or a unique prefix (the chat citation rule), a `foreverlm://source/<id>`
    /// link in either scheme, or a web address the library answers to the
    /// way a Doc's reference cards are answered — the address as saved or
    /// normalized, the DOI, the arXiv id.
    func resolveAnimationSources(_ tokens: [String]) throws -> AnimationSources {
        let store = try knowledgeStore()
        var found = AnimationSources()
        for raw in tokens {
            var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            if let range = token.range(of: #"^foreverlm(-dev)?://source/"#, options: .regularExpression) {
                token = String(token[range.upperBound...])
                if let slash = token.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
                    token = String(token[..<slash])
                }
            }
            let resolved = try store.resolveSourceID(forLinkToken: token) ?? store.activeSourceID(forReferenceURL: token)
            if let resolved {
                if !found.resolved.contains(resolved) { found.resolved.append(resolved) }
            } else {
                found.unresolved.append(raw)
            }
        }
        return found
    }

    /// `id` and `title` for each source, in the order given; a source the
    /// library no longer holds keeps its id as its title.
    func animationSourceDescriptors(for sourceIDs: [String]) throws -> [[String: Any]] {
        guard !sourceIDs.isEmpty else { return [] }
        let store = try knowledgeStore()
        return try sourceIDs.map { id in
            let article = try store.loadSourceForSync(id)
            let title = article?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var descriptor: [String: Any] = ["id": id, "title": title.isEmpty ? id : title]
            if let article {
                descriptor["source_type"] = article.sourceType.rawValue
                if !article.url.isEmpty { descriptor["url"] = article.url }
            }
            return descriptor
        }
    }

    // MARK: Files

    /// The `files` entries split by how their bytes arrive: inline (`content`,
    /// `content_base64`), which `inlineSiteFiles` parses, and `local_path`,
    /// read from this Mac. An entry naming both is refused.
    static func splitAnimationFiles(_ rawFiles: [Any]?) throws -> (inline: [Any], local: [[String: Any]]) {
        var inline: [Any] = []
        var local: [[String: Any]] = []
        for (index, entry) in (rawFiles ?? []).enumerated() {
            guard let object = entry as? [String: Any] else {
                throw MCPError.invalidInput("files[\(index)] must be an object with path and content (text), content_base64 (bytes) or local_path (a file on this Mac).")
            }
            if let localPath = object["local_path"] as? String, !localPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard object["content"] == nil, object["content_base64"] == nil else {
                    throw MCPError.invalidInput("files[\(index)]: pass local_path alone, or content / content_base64, not both.")
                }
                local.append(object)
            } else {
                inline.append(object)
            }
        }
        return (inline, local)
    }

    /// One file read from this Mac: the path it is served under (the entry's
    /// `path`, or the file's own name) and its bytes. A directory, a missing
    /// file or one bigger than an animation can be is refused by name.
    /// `validate` is the client-path check every file-taking tool applies
    /// (`validateClientProvidedPath`: library, Desktop, Documents and Downloads
    /// only; never a credential store). Until 2026-09-19 a local_path was read
    /// with no check beyond "exists and is not a folder", so a connector could
    /// have saved ~/.ssh/id_ed25519 as a site file.
    static func localSiteFile(
        _ entry: [String: Any],
        validate: (String) throws -> URL = { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
        read: @Sendable (String) throws -> Data
    ) throws -> SiteFile {
        let rawLocal = (entry["local_path"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawLocal.isEmpty else {
            throw MCPError.invalidInput("local_path is empty; pass the file's path on this Mac.")
        }
        let localURL = try validate(rawLocal)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory) else {
            throw MCPError.invalidInput("local_path \(rawLocal) is not a file on this Mac.")
        }
        guard !isDirectory.boolValue else {
            throw MCPError.invalidInput("local_path \(rawLocal) is a folder; pass each file on its own.")
        }
        let rawPath = (entry["path"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? localURL.lastPathComponent
        guard let path = LocalSite.normalizePath(rawPath) else {
            throw MCPError.invalidInput("‘\(rawPath)’ is not a file path an animation can serve: relative, forward slashes, letters, digits, dots, hyphens and underscores, no dot segments. Pass path beside local_path to name it.")
        }
        let data: Data
        do {
            data = try read(localURL.path)
        } catch {
            throw MCPError.invalidInput("local_path \(rawLocal) could not be read: \(error.localizedDescription)")
        }
        guard data.count <= LocalSite.maxBytes else {
            throw MCPError.invalidInput("\(path) is \(data.count / 1_000_000) MB; an animation kept in the library can be at most \(LocalSite.maxBytes / 1_000_000) MB in all, so it syncs through iCloud with the record. Render the video smaller or shorter.")
        }
        return SiteFile(path: path, data: data)
    }

    static func isAnimationVideoPath(_ path: String) -> Bool {
        animationVideoExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// The page written around a lone video: its title, the description as a
    /// lede, and a player that loops. A fixed template, so nothing here is a
    /// judgement about the content; the caller's words are escaped as text.
    static func animationPlayerHTML(title: String, description: String, videoPath: String) -> String {
        let escapedTitle = htmlEscaped(title)
        let lede = description.isEmpty ? "" : "\n    <p class=\"lede\">\(htmlEscaped(description))</p>"
        let type = Self.videoMIMEType(forPath: videoPath).map { " type=\"\($0)\"" } ?? ""
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapedTitle)</title>
        <style>
          :root { color-scheme: light dark; }
          body { margin: 0; font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: Canvas; color: CanvasText; }
          main { max-width: 960px; margin: 0 auto; padding: 28px 20px 40px; }
          h1 { font-size: 22px; font-weight: 600; margin: 0 0 6px; }
          .lede { margin: 0 0 18px; opacity: 0.75; }
          video { display: block; width: 100%; max-height: 80vh; background: #000; border-radius: 10px; }
        </style>
        </head>
        <body>
          <main>
            <h1>\(escapedTitle)</h1>\(lede)
            <video controls autoplay loop muted playsinline preload="metadata">
              <source src="\(htmlEscaped(videoPath))"\(type)>
            </video>
          </main>
        </body>
        </html>
        """
    }

    static func videoMIMEType(forPath path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "webm": return "video/webm"
        case "mov": return "video/quicktime"
        default: return nil
        }
    }

    /// The text copy chat, review and search read: the description first,
    /// then what the page says, then the sources by name.
    static func animationTextCopy(description: String, pageText: String, sourceTitles: [String]) -> String {
        var parts: [String] = []
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDescription.isEmpty { parts.append(trimmedDescription) }
        let trimmedPage = pageText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPage.isEmpty, trimmedPage != trimmedDescription { parts.append(trimmedPage) }
        let titles = sourceTitles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !titles.isEmpty { parts.append("About: " + titles.joined(separator: "; ")) }
        return parts.joined(separator: "\n\n")
    }

    private static func htmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
