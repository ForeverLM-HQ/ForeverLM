import Foundation

// MARK: - Imports made from inside a notebook
//
// A page or paper added while the learner works in a notebook lands in the
// library and in that notebook, through the library's one import
// (`addArticle`) and the notebook's one membership write
// (`addSourcesToNotebookContext`) — the chat's web-citation Add, a notebook
// page's link field, the Reader's and the Browser pane's Add to Sources for a
// live page, a calendar block made into a notebook. The source id
// exists when `addArticle` returns (it inserts the row before any fetch), so
// membership is written at once, as the Gemini Notebook importer does
// (docs/notebooks-design.md, "Imports").

// MARK: - Whether a notebook can take a new source

/// Why a new source cannot be filed in a notebook (a Notebook, or the Goal a
/// chat is filed under). The one rule the app's imports
/// (`importableNotebook`), a notebook chat's imports (`ReviewSessionManager`)
/// and MCP's notebook_id (`notebookForImport`, `add_notebook_sources`) apply;
/// each words the refusal for its own reader.
enum NotebookImportRefusal: Equatable, Sendable {
    /// No record has the id any more.
    case missing
    case archived
    /// A team's notebook, and the team is not on this Mac.
    case teamNotOnThisMac(teamID: String)
    /// A team's notebook this account can only read.
    case readOnlyTeam(teamName: String)

    /// Nil when `notebook` can take a new source. `team` is the notebook's
    /// team as this Mac holds it: nil for a personal notebook, or for a team
    /// this Mac does not hold.
    static func refusal(for notebook: LearningGoalRecord?, team: TeamRecord?) -> NotebookImportRefusal? {
        guard let notebook else { return .missing }
        guard !notebook.isArchived else { return .archived }
        return teamRefusal(for: notebook, team: team)
    }

    /// The team half of `refusal(for:team:)` alone: what `add_notebook_sources`
    /// checks, which also files into an archived Notebook the caller named.
    static func teamRefusal(for notebook: LearningGoalRecord, team: TeamRecord?) -> NotebookImportRefusal? {
        guard let teamID = notebook.teamID else { return nil }
        guard let team, team.id == teamID else { return .teamNotOnThisMac(teamID: teamID) }
        return team.canEdit ? nil : .readOnlyTeam(teamName: team.name)
    }

    /// Why, as the end of a sentence about the notebook: "… because it is
    /// archived".
    var reason: String {
        switch self {
        case .missing: return "it is no longer in the library"
        case .archived: return "it is archived"
        case .teamNotOnThisMac: return "its team is not on this Mac"
        case .readOnlyTeam(let name): return "team \u{2018}\(name)\u{2019} is read-only for this account"
        }
    }
}

extension StudioViewModel {
    /// What an import made from inside a notebook did, to the library and to
    /// the notebook.
    struct NotebookImportOutcome: Equatable, Sendable {
        enum Library: Equatable, Sendable {
            /// A new row, or an archived one brought back.
            case added
            /// The library already held the address, by URL or DOI.
            case alreadyHeld
            /// A page ForeverLM links rather than imports (a Google Doc, a
            /// Claude artifact, a Codex or ForeverLM site), linked with the
            /// notebook as its home.
            case linkedPage
            case failed(String)
        }

        enum Membership: Equatable, Sendable {
            /// No notebook was named, or the one named cannot take imports.
            case none
            case added
            case alreadyIn
            case failed(String)
        }

        var sourceID: String?
        var library: Library
        var membership: Membership

        /// The library holds the page now, and the notebook too when one was
        /// named: what a caller's Add button reads as done.
        var landed: Bool {
            if case .failed = library { return false }
            switch membership {
            case .added, .alreadyIn: return true
            case .failed: return false
            case .none: return true
            }
        }
    }

    /// A notebook an in-app import may file into: a live Notebook of the open
    /// library, whose team, if it has one, this account can edit
    /// (`NotebookImportRefusal`). Nil otherwise, and the caller then adds to
    /// the library only. Another library's notebook takes nothing from here:
    /// its rows are not the ones on screen (a team copy, or a team-only row,
    /// would land in My Library's notebook).
    func importableNotebook(_ id: String?) -> LearningGoalRecord? {
        guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
              let record = notebook(id: id), record.isNotebook,
              record.teamID == activeTeamID else { return nil }
        let team = record.teamID.flatMap { team(id: $0) }
        return NotebookImportRefusal.refusal(for: record, team: team) == nil ? record : nil
    }

    /// The notebook a window's imports land in: the notebook this window
    /// holds (`sidebarNotebook(in:)`, which holds while a Reader covers its
    /// page), else the notebook this window's chat is filed in. Never the
    /// sticky `activeNotebookId`, which says nothing about what is on screen.
    func notebookInScope(for windowState: StudioWindowState?) -> LearningGoalRecord? {
        guard let windowState else { return nil }
        if let working = sidebarNotebook(in: windowState), let notebook = importableNotebook(working.notebookID) {
            return notebook
        }
        guard let sessionID = windowState.chatSessionID,
              let goalID = reviewSessionLinks.first(where: { $0.id == sessionID })?.goalID else { return nil }
        return importableNotebook(goalID)
    }

    /// What the Reader's and the Browser pane's Add to Sources did: whether
    /// the page now sits where the click asked (the library, and the
    /// window's notebook when there is one), and the source a page added
    /// just now became, which the Browser pane may hand its rendered copy.
    struct LivePageAdd: Equatable {
        var landed: Bool
        var addedSourceID: String?
    }

    /// Whether Add to Sources has nothing left to do for a live page in this
    /// window: the library holds it, and so does the notebook the window's
    /// imports land in (`notebookInScope(for:)`), when there is one. Then the
    /// button reads View in Sources.
    func livePageIsAdded(_ url: URL, in windowState: StudioWindowState?) -> Bool {
        guard librarySourceID(forURL: url.absoluteString) != nil else { return false }
        guard let notebook = notebookInScope(for: windowState) else { return true }
        return notebookHoldsSource(url: url.absoluteString, notebookID: notebook.id)
    }

    /// The Reader's and the Browser pane's Add to Sources for the page on
    /// screen, made in `windowState`. In a window whose imports land in a
    /// notebook (`notebookInScope(for:)`), the page joins the library and
    /// that notebook through the notebook import (`importLink`, the
    /// team-aware membership write), and the toast names the notebook
    /// ("Added to Library and to “Mito”", "Added to “Mito”"). Anywhere else
    /// it joins the library only. A pop-out Reader belongs to no Studio
    /// window and passes nil.
    func addLivePageToSources(_ url: URL, in windowState: StudioWindowState?) async -> LivePageAdd {
        let address = url.absoluteString
        if let notebook = notebookInScope(for: windowState) {
            let outcome = await importLink(address, intoNotebook: notebook.id)
            showToast(Self.notebookImportToast(outcome, notebookTitle: notebook.title))
            return LivePageAdd(
                landed: outcome.landed,
                addedSourceID: outcome.library == .added ? outcome.sourceID : nil
            )
        }
        let key = SourceDiscovery.normalizedURL(address)
        if articles.contains(where: { SourceDiscovery.normalizedURL($0.url) == key }) {
            showToast("Already in Library")
            return LivePageAdd(landed: true, addedSourceID: nil)
        }
        let previousError = errorMessage
        do {
            try await addArticle(
                url: address,
                revealInReader: false,
                waitForInitialPaperProcessing: false,
                reviveArchivedSourceIfNeeded: true
            )
        } catch {
            showToast("Could not add to Library: \(error.localizedDescription)")
            return LivePageAdd(landed: false, addedSourceID: nil)
        }
        // `addArticle` reports a refusal or a duplicate through
        // `errorMessage` rather than throwing.
        let newError = errorMessage != previousError ? errorMessage : nil
        guard let article = articles.first(where: { SourceDiscovery.normalizedURL($0.url) == key }) else {
            if let newError {
                showToast(newError)
                return LivePageAdd(landed: newError.localizedCaseInsensitiveContains("already"), addedSourceID: nil)
            }
            showToast("Could not add to Library")
            return LivePageAdd(landed: false, addedSourceID: nil)
        }
        showToast(newError ?? "Added to Library")
        return LivePageAdd(landed: true, addedSourceID: article.id)
    }

    /// The title a page already carries where it was cited, as a source's
    /// first title: a site's name on either side of a bar ("… in human blood |
    /// bioRxiv", "Frontiers | Updating …") dropped by keeping the longest part,
    /// and nil when it says nothing the address does not (empty, the host).
    nonisolated static func citedPageTitle(_ raw: String?, host: String) -> String? {
        let parts = (raw ?? "").components(separatedBy: " | ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let title = parts.max(by: { $0.count < $1.count }), !title.isEmpty,
              title.caseInsensitiveCompare(host) != .orderedSame else { return nil }
        return title
    }

    /// The address a link field can import, or nil when the text is words to
    /// search for: an http(s) URL with a host, or a DOI (`10.…/…`, `doi:…`)
    /// as its doi.org address — the rule `import_paper_from_url` applies.
    nonisolated static func importableLink(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        if trimmed.lowercased().hasPrefix("doi:") {
            let doi = String(trimmed.dropFirst(4))
            return doi.hasPrefix("10.") && doi.contains("/") ? "https://doi.org/\(doi)" : nil
        }
        if trimmed.hasPrefix("10."), trimmed.contains("/") {
            return "https://doi.org/\(trimmed)"
        }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, host.contains(".") else { return nil }
        return trimmed
    }

    /// Whether the notebook holds the library source an address names. A
    /// team notebook holds the team's copies, which name the learner's own
    /// rows (`canonicalSourceID`).
    func notebookHoldsSource(url: String, notebookID: String) -> Bool {
        guard let sourceID = librarySourceID(forURL: url), let notebook = notebook(id: notebookID) else { return false }
        let canonical = canonicalSourceID(sourceID)
        return notebook.approvedSourceIDs.contains { canonicalSourceID($0) == canonical }
    }

    /// Imports a link into the library and, when `notebookID` names a
    /// notebook that can take it (`importableNotebook`), into that notebook.
    /// An address the library already holds — by URL or DOI — only joins the
    /// notebook. A page ForeverLM links is linked with the notebook as its
    /// home, or, linked already, filed under the notebook too. Reports
    /// through the outcome: the caller says it (`notebookImportToast`).
    @discardableResult
    func importLink(
        _ rawURL: String,
        intoNotebook notebookID: String?,
        revealInReader: Bool = false,
        knownTitle: String? = nil
    ) async -> NotebookImportOutcome {
        guard let address = Self.normalizedSourceAddress(rawURL) else {
            return NotebookImportOutcome(library: .failed("There is no address to add."), membership: .none)
        }
        let notebook = importableNotebook(notebookID)
        if let notebook, Self.linkedPageKind(forSourceURL: address) != nil {
            do {
                let pageURL = try LinkedPage.canonicalURL(from: address).absoluteString
                if let linked = artifacts.first(where: { $0.linkedURL == pageURL }) {
                    guard !linked.linkedNotebookIDs.contains(notebook.id) else {
                        return NotebookImportOutcome(library: .linkedPage, membership: .alreadyIn)
                    }
                    await setArtifactNotebookMembership(linked.id, notebookID: notebook.id, isMember: true)
                    let filed = artifacts.first(where: { $0.id == linked.id })?.linkedNotebookIDs.contains(notebook.id) == true
                    return NotebookImportOutcome(
                        library: .linkedPage,
                        membership: filed ? .added : .failed("the page could not be filed")
                    )
                }
                _ = try await linkPage(urlString: address, homeNotebookID: notebook.id, linkedNotebookIDs: [notebook.id])
                return NotebookImportOutcome(library: .linkedPage, membership: .added)
            } catch {
                return NotebookImportOutcome(library: .failed(error.localizedDescription), membership: .none)
            }
        }
        // A playlist comes in as a course, which lives in no notebook; the
        // notebook it was added in follows it, as a course dropped on it
        // does, so later lectures join it too.
        if let notebook, YouTubePlaylistService.isPlaylistURL(address) {
            let previousError = errorMessage
            guard let courseID = await importYouTubePlaylist(url: address) else {
                let reason = errorMessage != previousError ? errorMessage : nil
                return NotebookImportOutcome(library: .failed(reason ?? "The playlist could not be imported."), membership: .none)
            }
            let linked = await linkCourseToNotebookContext(
                courseID: courseID,
                sourceIDs: sourceIDsForGroupInOrder(courseID),
                notebookID: notebook.id
            )
            await reloadCourseFollowers()
            return NotebookImportOutcome(library: .added, membership: linked == nil ? .failed("the course could not be linked") : .added)
        }
        if let held = librarySourceID(forURL: address) {
            return NotebookImportOutcome(
                sourceID: held,
                library: .alreadyHeld,
                membership: await fileImportedSource(held, in: notebook)
            )
        }
        let previousError = errorMessage
        do {
            try await addArticle(
                url: address,
                revealInReader: revealInReader,
                waitForInitialPaperProcessing: false,
                reviveArchivedSourceIfNeeded: true,
                knownTitle: knownTitle
            )
        } catch {
            return NotebookImportOutcome(library: .failed(error.localizedDescription), membership: .none)
        }
        // `addArticle` reports a refusal or a duplicate through `errorMessage`
        // rather than throwing, so the library is asked what it holds now.
        guard let sourceID = librarySourceID(forURL: address)
            ?? existingArticleIndex(matchingSourceURL: address).map({ articles[$0].id }) else {
            let reason = errorMessage != previousError ? errorMessage : nil
            return NotebookImportOutcome(library: .failed(reason ?? "The page could not be added."), membership: .none)
        }
        let duplicate = errorMessage != previousError && errorMessage?.localizedCaseInsensitiveContains("already") == true
        return NotebookImportOutcome(
            sourceID: sourceID,
            library: duplicate ? .alreadyHeld : .added,
            membership: await fileImportedSource(sourceID, in: notebook)
        )
    }

    /// A PDF dropped on a notebook's Sources column or chosen with its Add
    /// sources sheet's Upload PDF…: imported as a paper through the library's
    /// one PDF import (`importPDF(from:)`, which finds a paper the library
    /// already holds), then filed in the notebook as a link is. Reports
    /// through the outcome, worded by `notebookImportToast`.
    func importPaperPDF(at url: URL, intoNotebook notebookID: String?) async -> NotebookImportOutcome {
        let notebook = importableNotebook(notebookID)
        let known = Set(articlesById.keys)
        let sourceID: String
        do {
            sourceID = try await importPDF(from: url.path, selectInReader: false)
        } catch {
            return NotebookImportOutcome(
                library: .failed("\(url.lastPathComponent): \(error.localizedDescription)"),
                membership: .none
            )
        }
        let isNew = !known.contains(sourceID)
        return NotebookImportOutcome(
            sourceID: sourceID,
            library: isNew ? .added : .alreadyHeld,
            membership: await fileImportedSource(sourceID, in: notebook)
        )
    }

    /// A video file chosen from a notebook's Studio (the Video overview tile)
    /// or sent by an assistant: copied into the library as a video source
    /// (`VideoOverviewImporter`, which finds the one the same file already
    /// made), then filed in the notebook as a link or a PDF is. A notebook
    /// that cannot take imports still gets the video in the library.
    func importVideoOverview(at url: URL, intoNotebook notebookID: String?) async -> NotebookImportOutcome {
        let notebook = importableNotebook(notebookID)
        let video: StudioArticle
        do {
            video = try await VideoOverviewImporter.importFile(at: url, contentRootPath: StorageService.libraryRootPath)
        } catch {
            return NotebookImportOutcome(library: .failed(error.localizedDescription), membership: .none)
        }
        let isNew = articlesById[video.id] == nil
        if isNew {
            do {
                try await storage.saveSource(video)
            } catch {
                return NotebookImportOutcome(
                    library: .failed("\(url.lastPathComponent): \(error.localizedDescription)"),
                    membership: .none
                )
            }
            await refreshAfterCloudKitRemoteChange(affectedEntities: [.source], requiresFullRefresh: false)
        }
        return NotebookImportOutcome(
            sourceID: video.id,
            library: isNew ? .added : .alreadyHeld,
            membership: await fileImportedSource(video.id, in: notebook)
        )
    }

    /// Files one library source in the notebook. A team's copy of a row just
    /// added, whose text may still be on its way, takes that text when the
    /// fetch lands (`StorageService.refreshTeamCopiesAwaitingText`).
    private func fileImportedSource(
        _ sourceID: String,
        in notebook: LearningGoalRecord?
    ) async -> NotebookImportOutcome.Membership {
        guard let notebook else { return .none }
        let canonical = canonicalSourceID(sourceID)
        if notebook.approvedSourceIDs.contains(where: { canonicalSourceID($0) == canonical }) { return .alreadyIn }
        let previousError = errorMessage
        guard await addSourcesToNotebookContext([sourceID], notebookID: notebook.id, announce: false) != nil else {
            let reason = errorMessage != previousError ? errorMessage : nil
            return .failed(reason ?? "the notebook could not take it")
        }
        return .added
    }

    /// What an import made from inside a notebook says when it is done.
    nonisolated static func notebookImportToast(_ outcome: NotebookImportOutcome, notebookTitle: String?) -> String {
        let notebook = notebookTitle.map { "\u{201C}\($0)\u{201D}" } ?? "the notebook"
        switch (outcome.library, outcome.membership) {
        case (.failed(let reason), _):
            return reason
        case (_, .alreadyIn):
            return outcome.library == .added ? "Added to Library; already in \(notebook)" : "Already in \(notebook)"
        case (.linkedPage, .failed(let reason)):
            return "Not linked in \(notebook): \(reason)"
        case (.linkedPage, _):
            return "Linked in \(notebook)"
        case (.added, .added):
            return "Added to Library and to \(notebook)"
        case (.alreadyHeld, .added):
            return "Added to \(notebook)"
        case (.added, .failed(let reason)):
            return "Added to Library, but not to \(notebook): \(reason)"
        case (.alreadyHeld, .failed(let reason)):
            return "Not added to \(notebook): \(reason)"
        case (.added, .none):
            return "Added to Library"
        case (.alreadyHeld, .none):
            return "Already in Library"
        }
    }

    // MARK: - A calendar block made into a notebook

    /// The library's sources a block's `foreverlm://source/<id>` links name,
    /// in the block's order, each once. A link may carry the short prefix a
    /// chat cites a source by; one the library does not hold is left out.
    func librarySourceIDs(forBlockLinks tokens: [String]) -> [String] {
        var seen = Set<String>()
        return tokens.compactMap { loadedArticle(forLinkToken: $0)?.id }.filter { seen.insert($0).inserted }
    }

    /// The notebook a block was made into before: a live notebook titled as
    /// the block that holds every source the block names. The block itself
    /// is the learner's and is never written, so this is how the Now chip
    /// knows not to offer making a second one.
    func notebookMade(fromBlockTitled title: String, sourceIDs: [String]) -> LearningGoalRecord? {
        let wanted = librarySourceIDs(forBlockLinks: sourceIDs).map(canonicalSourceID)
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, !name.isEmpty else { return nil }
        return notebooks.first { notebook in
            guard notebook.isNotebook,
                  notebook.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame
            else { return false }
            let held = Set(notebook.approvedSourceIDs.map(canonicalSourceID))
            return wanted.allSatisfy(held.contains)
        }
    }

    /// Makes a notebook from a calendar block that names sources and no
    /// notebook: titled as the block, holding the sources the library has,
    /// and opened. The block is left as it is (the calendar is the
    /// learner's); `blockKey` (its occurrence) remembers the notebook for a
    /// bout started on the block later this session. Nil when the library
    /// holds none of its sources or the notebook could not be made; the
    /// failure says so itself.
    @discardableResult
    func makeNotebook(fromBlockTitled title: String, sourceIDs: [String], blockKey: String? = nil) async -> LearningGoalRecord? {
        let ids = librarySourceIDs(forBlockLinks: sourceIDs)
        guard !ids.isEmpty else {
            showToast("None of this block's sources are in your library")
            return nil
        }
        guard let made = await createNotebookContext(title: title) else { return nil }
        if let blockKey { notebooksMadeFromBlocks[blockKey] = made.id }
        await addSourcesToNotebookContext(ids, notebookID: made.id, announce: false)
        openNotebookInReader(made.id)
        return notebook(id: made.id) ?? made
    }

    /// The notebook a bout started on a block is filed under: the one the
    /// block's notes or URL name (`AppleCalendarEvent.notebookID`), else the
    /// one the learner made from this block this session — never one found by
    /// its title alone (`notebookMade(fromBlockTitled:sourceIDs:)` only keeps
    /// the Now chip from offering to make a second). Nil when neither is a
    /// live notebook of the open library.
    func boutNotebookID(forBlockNotebook linkedID: String?, blockKey: String) -> String? {
        let live = Set(notebooks.map(\.id))
        if let linkedID, live.contains(linkedID) { return linkedID }
        guard let made = notebooksMadeFromBlocks[blockKey], live.contains(made) else { return nil }
        return made
    }
}
