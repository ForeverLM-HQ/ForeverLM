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

    // MARK: - Navigation

    /// A source body is available only when it contains something a reader can
    /// render. Synced and imported records may represent missing content as an
    /// empty string rather than `nil`; treating those spellings differently
    /// strands the source on an otherwise unnecessary manual fetch prompt.
    nonisolated static func sourceHasReadableContent(_ article: StudioArticle) -> Bool {
        article.content?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
    }

    /// Opening a YouTube reader is itself the request to read its captions.
    /// Preserve a surfaced failure until the learner explicitly retries, but
    /// never require a separate click merely because no fetch was started by
    /// the import, sync, restoration, or navigation path that opened the view.
    nonisolated static func shouldAutomaticallyFetchYouTubeTranscriptOnOpen(
        _ article: StudioArticle
    ) -> Bool {
        YouTubeTranscriptService.isYouTubeURL(article.url)
            && !sourceHasReadableContent(article)
            && article.errorMessage?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty != false
    }

    /// `destinationWindowState` names the window whose Reader shows the source;
    /// nil means the key window. A view acting inside a window passes its own
    /// state and `revealingReader: true` — the registry's notion of the key
    /// window can lag the click that focused a second window, and a Sources
    /// row must never read in a window other than the one it was clicked in.
    func selectArticle(
        _ articleId: String,
        updateContext: Bool = false,
        in destinationWindowState: StudioWindowState? = nil,
        revealingReader: Bool = false
    ) async {
        // A team Notebook or Doc card names the team's copy; the list shows the
        // learner's own row at that address, so select that one.
        let articleId = canonicalSourceID(articleId)
        let destination = destinationWindowState ?? activeWindowState
        destination.externalReaderPage = nil
        // A drop or a context menu can send a source to a window other than the
        // one being acted in, and that window may itself still be rendering the
        // global selection. Pin it before the selection moves, or sending a
        // source over there drags this window's Reader along with it.
        let active = activeWindowState
        if destination !== active {
            active.pinReaderSelection(to: selectedArticleId)
        }
        // A newly registered window may still be rendering the legacy global
        // selection until it makes its first local choice. Capture that source
        // before replacing it so the first explicit navigation in this pane
        // still has somewhere to go Back to.
        if !destination.ownsReaderSelection,
           let selectedArticleId,
           selectedArticleId != articleId {
            destination.readerArticleID = selectedArticleId
        }
        destination.readerArticleID = articleId
        // That window's Sources list highlights what its Reader now shows. In
        // the acting window the gesture that got here already set the row.
        if destination !== active {
            destination.sidebarSelectedSourceIDs = [articleId]
        }
        readerNavigationRevisionsBySourceID[articleId, default: 0] &+= 1
        selectedArticleId = articleId
        currentCardIndex = 0

        // Selecting a source is an explicit read: reveal the reader column,
        // which stays closed at launch and after the user dismisses it.
        showReaderPanel = true
        // Explicit destinations come from a Reader drop target (already on
        // screen) or an edge drop that placed Reader before selecting, unless
        // the caller is a row clicked in that very window. Legacy navigation
        // continues to reveal Reader in the active window.
        if destinationWindowState == nil || revealingReader {
            clearReaderSurfaces(in: destination)
        }

        // Context is intentional: a source click only focuses the reader.
        // Explicit flows such as Schedule start, context menu actions, and
        // drag-to-chat/context still choose when sources enter chat context.
        if updateContext {
            contextSourceIds = [articleId]
        }

        // Auto-fetch content for sources that haven't been fetched yet
        // except remote papers, which now require an explicit PDF download.
        if let article = articles.first(where: { $0.id == articleId }),
           !Self.sourceHasReadableContent(article),
           !article.cachedIsLocalDocument {
            if requiresExplicitPaperDownload(article) {
                // No network for a remote paper — that is the explicit-download
                // rule — but text already in the database is text the reader can
                // show, and until this it did not load: a paper whose full text
                // was stored still opened on a PDF loader, and a publisher that
                // refuses the file left a lock screen over a finished source.
                await hydrateStoredContent(for: articleId)
            } else {
                await fetchContent(for: articleId)
            }
        }
    }

    /// Opens an assistant-generated source link in the existing Studio window.
    /// This deliberately preserves chat context: following a citation is reader
    /// navigation, not a request to replace the sources attached to the chat.
    /// `companion` is the surface the link was clicked in — Chat for a citation,
    /// Docs for a doc's source chip — and it stays visible beside the Reader,
    /// because following a link should never close what you were reading it in.
    /// `seconds` is the moment a timed citation names (`?t=754` on the link);
    /// the reader that opens seeks there once it is showing the source.
    /// `passage` is the excerpt a citation of a text source carries; the reader
    /// scrolls to it and flashes it once it is showing the source. `page` is
    /// the page of a PDF the citation names (`?page=7`, counted within the
    /// source); the reader opens it when the passage is not on it, or when the
    /// citation carries no passage.
    func openLinkedSourceInReader(
        _ sourceID: String,
        at seconds: Double? = nil,
        passage: String? = nil,
        page: Int? = nil,
        beside companion: StudioCenterTab = .chat
    ) async {
        let token = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            showToast("Source not found in library")
            return
        }

        // The assistant writes citation links from a long, deterministic source id and
        // often reproduces it imperfectly (truncated or shortened), so the raw token in
        // the URL may not be an exact id. Resolve it to a real source id first — exact
        // match, an already-loaded article whose id starts with the token, or a unique
        // prefix match in storage — so clicking a citation reliably opens its source.
        let trimmedID: String
        if let loaded = loadedArticle(forLinkToken: token) {
            trimmedID = loaded.id
        } else if let stored = try? await storage.resolveSourceID(forLinkToken: token) {
            trimmedID = stored
        } else {
            showToast("Source not found in library")
            return
        }

        // The Chat's search tools cite any source in the knowledge base — including
        // ones that are hidden or archived — so following a citation must resolve
        // against the whole library, not just the active, visible sidebar list.
        // A hidden source is already in `articles`; `selectedArticle` reads from
        // `articlesById`, so the reader can display it directly without unhiding it.
        // An archived source is not loaded at all, so restore it. Resolution above
        // already confirmed the id exists, so this never unarchives a bogus id.
        if !articles.contains(where: { $0.id == trimmedID }) {
            do {
                // The same restore the Unarchive button and the
                // `unarchive_source` tool perform, so opening an archived
                // source from a citation or a planner row leaves it in the
                // same state as unarchiving it on purpose.
                guard try await storage.unarchiveSourceRestoringContent(trimmedID) != nil else {
                    throw StudioError.sourceNotFound(trimmedID)
                }
            } catch {
                logger.error("Failed to restore linked source \(trimmedID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                showToast("Could not open source: \(error.localizedDescription)")
                return
            }
            await refreshArticles()
            showToast("Restored source from archive")
        }

        guard let article = articles.first(where: { $0.id == trimmedID }) else {
            showToast("Source not found in library")
            return
        }

        // An explainer has no row of its own; its row is folded under the
        // source it explains, so that source's tab is where it is revealed.
        if let targetTab = sidebarTab(listing: article) {
            let retainedLimits = (
                displayLimit,
                papersWithPDFDisplayLimit,
                papersWithoutPDFDisplayLimit,
                paywalledPapersDisplayLimit
            )
            let staysOnCurrentTab = sidebarTab == targetTab
            // Reset search and metadata filters even when this is already the
            // active tab, otherwise the linked source can remain invisible.
            switchTab(to: targetTab)
            if staysOnCurrentTab {
                // A linked row that was already loaded should not disappear just
                // because clearing filters reset pagination back to the first page.
                displayLimit = retainedLimits.0
                papersWithPDFDisplayLimit = retainedLimits.1
                papersWithoutPDFDisplayLimit = retainedLimits.2
                paywalledPapersDisplayLimit = retainedLimits.3
            }
        }

        if let group = (explainedSource(of: article) ?? article).parentGroup {
            sidebarStore.expandedGroups.insert(group)
        }

        // A click opens the source in the window it was made in, even when
        // another window already has the Reader up. Sending it there is what
        // the context menu's Open in Other Window is for (product owner, 2026-09-22:
        // "no actual click on anything should ever open the thing in the
        // other ForeverLM window").
        await showLinkedSourceInReader(article, at: seconds, passage: passage, page: page, beside: companion)
    }

    /// A chat about to point at a figure of `sourceID` opens it first: the
    /// Reader beside `companion` in the chat's own window, the way a citation
    /// click in that chat would (product owner, 2026-09-22: highlight the figure in
    /// the paper beside the chat rather than show a crop of it). False when
    /// the source is not loaded — archived, or not in this library — and the
    /// chat falls back to showing the figure in the reply.
    func openSourceBesideChat(
        _ sourceID: String,
        beside companion: StudioCenterTab,
        in windowState: StudioWindowState
    ) async -> Bool {
        guard let article = articlesById[sourceID] else { return false }
        await showLinkedSourceInReader(article, at: nil, passage: nil, beside: companion, in: windowState)
        return true
    }

    /// The tail of `openLinkedSourceInReader` once the source is resolved and
    /// the window is settled: reveal the Reader beside `companion` in
    /// `destinationWindowState` (the key window when nil) and show `article`
    /// there.
    private func showLinkedSourceInReader(
        _ article: StudioArticle,
        at seconds: Double?,
        passage: String?,
        page: Int? = nil,
        beside companion: StudioCenterTab,
        in destinationWindowState: StudioWindowState? = nil
    ) async {
        let destination = destinationWindowState ?? activeWindowState
        // Following a citation is reader navigation, so it leaves the Sources
        // browser exactly as the learner left it. Taking the panel away here
        // used to be permanent — nothing ever handed it back — so a single
        // citation click silently undid a panel they had chosen to keep open.
        showReaderPanel = true
        readerPoppedOut = false
        revealReader(beside: companion, in: destination)
        clearReaderSurfaces(keeping: companion, in: destination)

        // Publish both reader and sidebar selection before any content fetch so
        // the click responds immediately even when the source lives in iCloud.
        selectedArticleId = article.id
        currentCardIndex = 0
        inWindow(destination) {
            selectedArticleIds = [article.id]
            revealSourceInSidebar(article)
        }
        await selectArticle(article.id, in: destination)
        var moment = seconds
        if moment == nil { moment = await transcriptMoment(saying: passage, in: article) }
        requestReaderTime(moment, for: article.id)
        requestReaderPassage(passage, page: page, for: article.id)
    }

    /// When a timed transcript says `passage`: a card's Show Passage and a
    /// text citation of a video, podcast or meeting carry the words, not a
    /// moment, and a transcript reader has no words to flash, only a time to
    /// open at. The words are placed the way a quiz question's Rewatch link is,
    /// a few seconds before they are said (`LectureQuizTimeline`). Nil for any
    /// other source, an untimed transcript, or words the transcript lacks, and
    /// the reader then opens the source at its start as before.
    private func transcriptMoment(saying passage: String?, in article: StudioArticle) async -> Double? {
        guard [.video, .podcast, .meeting].contains(article.sourceType),
              let passage = passage?.trimmingCharacters(in: .whitespacesAndNewlines), !passage.isEmpty,
              let content = await storage.loadSourceContent(article.id) else { return nil }
        let timeline = LectureQuizTimeline(CourseQuizPlanning.lines(from: content))
        return timeline.seconds(saying: passage)
    }

    /// Ask the reader showing `sourceID` to open at `seconds`. Set after the
    /// selection, not before: `selectArticle` remounts the reader, and a target
    /// already standing when it mounts is read before its player exists, whereas
    /// one arriving afterwards is a change the reader answers when it can. A
    /// reader that mounts later still finds it — the target waits until the
    /// reader for that source consumes it.
    func requestReaderTime(_ seconds: Double?, for sourceID: String, plays: Bool = true) {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return }
        readerTimeTargetRevision &+= 1
        readerTimeTarget = ReaderTimeTarget(
            sourceID: sourceID,
            seconds: seconds,
            revision: readerTimeTargetRevision,
            plays: plays
        )
    }

    /// Ask the video Reader showing `sourceID` to pause: the learner began
    /// typing a question about it, and the answer is about the moment they
    /// stopped at, not one the video has since played past. A Reader that
    /// shows another source leaves the request for its own.
    func requestReaderVideoPause(for sourceID: String) {
        readerVideoPauseRevision &+= 1
        readerVideoPauseRequest = ReaderVideoPauseRequest(sourceID: sourceID, revision: readerVideoPauseRevision)
    }

    /// Ask the reader showing `sourceID` to scroll to `passage` and flash it,
    /// or — for a PDF whose pages do not carry the passage, or a citation that
    /// names only a page — to open `page`. Same timing rule as
    /// `requestReaderTime`: set after the selection, so the reader that mounts
    /// for the source finds it waiting.
    func requestReaderPassage(_ passage: String?, page: Int? = nil, for sourceID: String) {
        let trimmed = passage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed?.isEmpty == false ? trimmed : nil
        let page = page.flatMap { $0 >= 1 ? $0 : nil }
        guard words != nil || page != nil else { return }
        readerPassageTargetRevision &+= 1
        readerPassageTarget = ReaderPassageTarget(
            sourceID: sourceID,
            passage: words,
            page: page,
            revision: readerPassageTargetRevision
        )
    }

    /// A reader acted on `target` — flashed the passage, or established that the
    /// source no longer carries it. Spent, so a reader that mounts for the same
    /// source later does not replay it; a newer request is left alone.
    func finishReaderPassage(_ target: ReaderPassageTarget) {
        guard readerPassageTarget == target else { return }
        readerPassageTarget = nil
    }

    /// The chat playing a walkthrough moved to a step: ask the reader showing
    /// the paper to scroll to what it points at and keep it outlined.
    func focusWalkthrough(
        _ target: ReaderWalkthroughFocus.Target,
        stepID: String,
        for sourceID: String,
        emphasis: ReaderWalkthroughFocus.Emphasis = .outline,
        pickablePanels: [ReaderWalkthroughFocus.PickablePanel] = []
    ) {
        readerWalkthroughFocusRevision &+= 1
        readerWalkthroughFocus = ReaderWalkthroughFocus(
            sourceID: sourceID,
            stepID: stepID,
            target: target,
            revision: readerWalkthroughFocusRevision,
            emphasis: emphasis,
            pickablePanels: pickablePanels
        )
    }

    /// The chat playing a walkthrough moved to a step, or the tutor pointed
    /// at a place in the source: the reader showing it follows.
    func applyWalkthroughReaderFocus(_ focus: WalkthroughReaderFocus) {
        switch focus {
        case .outline(let target, let stepID, let sourceID):
            focusWalkthrough(target, stepID: stepID, for: sourceID)
        case .spotlight(let target, let stepID, let sourceID, let veiled):
            focusWalkthrough(target, stepID: stepID, for: sourceID, emphasis: veiled ? .veiled : .spotlight)
        case .pickPanel(let target, let stepID, let sourceID, let panels):
            focusWalkthrough(target, stepID: stepID, for: sourceID, emphasis: .spotlight, pickablePanels: panels)
            // A click on one of the panels answers the Find it card of the
            // chat walking this window.
            readerPanelPickHandler = { [weak self] pickedSourceID, panel in
                guard let self, let manager = self.activeWindowState.walkthroughDeckManager else { return }
                Task { await manager.pickWalkthroughPanel(sourceID: pickedSourceID, panel: panel) }
            }
        case .flash(let passage, let sourceID):
            clearWalkthroughFocus()
            requestReaderPassage(passage, for: sourceID)
        case .moment(let seconds, let sourceID):
            clearWalkthroughFocus()
            requestReaderTime(Double(seconds), for: sourceID, plays: false)
        case .animation(let artifactID, let step, let conditions):
            clearWalkthroughFocus()
            animationWalkFocusRevision &+= 1
            animationWalkFocus = AnimationWalkFocus(artifactID: artifactID, step: step, conditions: conditions, revision: animationWalkFocusRevision)
        case .clear:
            clearWalkthroughFocus()
        }
    }

    /// Walk Through on a saved animation: reveal the chat beside the
    /// Animations pane and ask it to play the animation's walkthrough. Each
    /// step then pins the animation's page to the step it talks about.
    func requestWalkthroughPlayback(forAnimation artifactID: String) {
        guard !artifactID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        revealChat(beside: .animations)
        readerWalkthroughPlayRequestRevision &+= 1
        readerWalkthroughPlayRequest = ReaderWalkthroughPlayRequest(
            sourceID: artifactID,
            revision: readerWalkthroughPlayRequestRevision,
            isAnimation: true
        )
    }

    /// The animations that have a walkthrough, read again after one is saved
    /// or removed.
    func refreshArtifactWalkthroughIDs() async {
        artifactIDsWithWalkthroughs = (try? await storage.artifactIDsWithWalkthroughs()) ?? []
    }

    /// The chat moved to a step with nothing to point at, or the tutor asked
    /// for the outline to come down: the reader takes it down.
    func clearWalkthroughFocus() {
        guard readerWalkthroughFocus != nil else { return }
        readerWalkthroughFocusRevision &+= 1
        readerWalkthroughFocus = nil
    }

    /// Walk Through on a source: reveal the chat beside the Reader and ask it
    /// to play the source's walkthrough. The pane reuses the chat it shows
    /// when that chat is about the source or has nothing in it yet, and opens
    /// a new one otherwise — the rule a Reader selection follows.
    func requestWalkthroughPlayback(for sourceID: String) {
        guard !sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        addSourceToContext(sourceID)
        revealChatBesideReader()
        readerWalkthroughPlayRequestRevision &+= 1
        readerWalkthroughPlayRequest = ReaderWalkthroughPlayRequest(
            sourceID: sourceID,
            revision: readerWalkthroughPlayRequestRevision
        )
    }

    /// The × on the only pane while its chat plays a walk: the walk ends and
    /// the pane lands on New chat's greeting (product owner, 2026-09-29: "clicking
    /// the X at the top on this walkthrough should just close it and open
    /// that good afternoon the product owner chat page"). Dismissing Chat otherwise
    /// reveals the Reader, which put the walked video back up. The walk's
    /// place is kept in its record, so Walk Through resumes it. False, and
    /// nothing done, when no chat in this window is walking — or when a
    /// comparison chat might be the one that is.
    @discardableResult
    func leaveWalkthroughForNewChat(in windowState: StudioWindowState) -> Bool {
        let groups = windowState.centerTabGroups.groups
        let chatShowsAlone = groups.first(where: { $0.tabs.contains(.chat) })?.activeTab == .chat
            && !groups.contains(where: { $0.tabs.contains(.secondaryChat) })
        guard !windowState.isChatPoppedOut,
              chatShowsAlone,
              let manager = windowState.walkthroughDeckManager,
              manager.walkthroughPlayback != nil
        else { return false }
        manager.leaveWalkthroughPlayback()
        inWindow(windowState) { requestNewChat() }
        return true
    }

    /// A walkthrough was written, redrawn or removed; a chat playing it reloads.
    func noteWalkthroughChanged() {
        readerWalkthroughRevision &+= 1
        Task { await refreshArtifactWalkthroughIDs() }
    }

    /// Opens a provider-returned web citation beside Chat without importing it.
    /// Saving remains a separate, explicit Reader action that travels through
    /// `addArticle`, including canonical deduplication and archived-source revival.
    ///
    /// A citation the library already holds — by address, or by the paper's
    /// DOI under whatever address it was saved — opens as that source instead
    /// of as a live page: the saved copy is where the notes, highlights and
    /// reading position are, and a PDF beats a publisher's abstract page. An
    /// index page whose address names only its own record (PubMed) cannot be
    /// recognised before it loads; the Reader swaps it for the saved source
    /// once the page has declared its DOI (`SourceReaderPanel`).
    func openWebCitationInReader(
        _ citedURL: URL,
        title rawTitle: String? = nil,
        in destinationWindowState: StudioWindowState? = nil
    ) {
        guard let scheme = citedURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            showToast("Could not open this web source")
            return
        }
        // YouTube opens one video at a time (`YouTubeContainment`): a video at
        // its watch address, which the Reader plays alone, and none of
        // YouTube's other pages.
        let rawURL: URL
        switch YouTubeContainment.decision(for: citedURL) {
        case .video(let watchURL): rawURL = watchURL
        case .refused:
            showToast(YouTubeContainment.refusalMessage)
            return
        case .notYouTube: rawURL = citedURL
        }

        if let sourceID = librarySourceID(forURL: rawURL.absoluteString) {
            openSavedCopy(sourceID, in: destinationWindowState)
            return
        }

        let suppliedTitle = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = suppliedTitle?.isEmpty == false
            ? suppliedTitle!
            : (rawURL.host ?? rawURL.absoluteString)
        let page = StudioExternalReaderPage(url: rawURL, title: title)

        // A citation click opens here, like a library citation; a drop
        // target names its own window.
        let destination = destinationWindowState ?? activeWindowState
        destination.externalReaderPage = page
        showReaderPanel = true
        readerPoppedOut = false
        revealReader(beside: .chat, in: destination)
    }

    /// The saved source a web page turned out to be, opened where the page
    /// would have gone: in the named window, else beside the chat the way a
    /// source citation opens. `openLinkedSourceInReader` also restores an
    /// archived source and brings the Sources row into view, which a citation
    /// to a saved paper deserves as much as a `foreverlm://source` link does.
    func openSavedCopy(_ sourceID: String, in destinationWindowState: StudioWindowState? = nil) {
        Task { @MainActor in
            if let destinationWindowState {
                await selectArticle(sourceID, in: destinationWindowState, revealingReader: true)
            } else {
                await openLinkedSourceInReader(sourceID)
            }
        }
    }

    /// Keeps a page or paper someone cited — a chat's Web sources row, a paper
    /// a highlight's note names — through the canonical URL import, with
    /// deduplication and archived-source revival, the same path as the
    /// Reader's Add to Sources. Says in a toast what the library ended up
    /// with, and answers whether it now holds the page: a failed import
    /// leaves the caller's button available, so the click can be retried
    /// rather than pretending the page was kept.
    ///
    /// `notebookID` is the notebook the citing chat works in: the page then
    /// joins that notebook as well (`importLink`), and the answer is whether
    /// both hold it.
    @discardableResult
    func addCitedPageToSources(_ url: URL, notebookID: String? = nil, title: String? = nil) async -> Bool {
        if let notebook = importableNotebook(notebookID) {
            let outcome = await importLink(url.absoluteString, intoNotebook: notebook.id, knownTitle: title)
            showToast(Self.notebookImportToast(outcome, notebookTitle: notebook.title))
            return outcome.landed
        }
        let address = url.absoluteString
        if libraryContainsSource(url: address) {
            showToast("Already in Sources")
            return true
        }
        let previousError = errorMessage
        do {
            try await addArticle(
                url: address,
                revealInReader: false,
                waitForInitialPaperProcessing: false,
                reviveArchivedSourceIfNeeded: true,
                knownTitle: title
            )
        } catch {
            showToast("Could not add to Sources: \(error.localizedDescription)")
            return false
        }
        if libraryContainsSource(url: address) {
            if let errorMessage, errorMessage != previousError {
                showToast(errorMessage)
            } else {
                showToast("Added to Sources")
            }
            return true
        }
        if let errorMessage, errorMessage != previousError {
            showToast(errorMessage)
            return errorMessage.localizedCaseInsensitiveContains("already")
        }
        showToast("Could not add to Sources")
        return false
    }

    /// Match a citation link token against already-loaded articles: exact id first,
    /// then a unique prefix (the assistant tends to truncate the long id from the end).
    /// Mirrors storage-side resolution so loaded — including hidden — sources resolve
    /// without a storage round-trip. Chat also uses this to decorate source links.
    /// Returns nil when nothing matches or a prefix is ambiguous, so a token can never
    /// open or display metadata for the wrong source.
    func loadedArticle(forLinkToken token: String) -> StudioArticle? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = articlesById[trimmed] { return exact }
        guard trimmed.count >= 8 else { return nil }
        var match: StudioArticle?
        for article in articles where article.id.hasPrefix(trimmed) {
            if match != nil { return nil } // ambiguous prefix
            match = article
        }
        return match
    }

    /// Resolve citation metadata without changing source state. Archived
    /// sources are absent from the in-memory sidebar catalog but remain valid
    /// historical citations, so Chat asks the storage actor before declaring a
    /// link unavailable. This read never unarchives or otherwise mutates it.
    func persistedArticle(forLinkToken token: String) async -> StudioArticle? {
        if let loaded = loadedArticle(forLinkToken: token) { return loaded }
        guard let sourceID = try? await storage.resolveSourceID(forLinkToken: token),
              let article = try? await storage.loadPersistedSources(ids: [sourceID]).first else {
            return nil
        }
        return article
    }

    /// The library's cards for web addresses a Site links, keyed by address —
    /// only the ones an active source answers to, by URL, DOI or arXiv id, the
    /// way a Doc's reference cards ask (`librarySourceIDs(forReferenceURLs:)`).
    /// A team Site asks its team's library first and My Library after it, so
    /// a paper the team shares and one the learner holds privately both open
    /// in Reader. A source linked under two addresses is resolved once.
    func sourceCards(forWebAddresses addresses: [String], teamID: String? = nil) async -> [String: ChatSourceCard] {
        guard !addresses.isEmpty else { return [:] }
        var matches: [String: String] = [:]
        if let teamID {
            matches = await storage.librarySourceIDs(forReferenceURLs: addresses, teamID: teamID)
        }
        let remaining = addresses.filter { matches[$0] == nil }
        if !remaining.isEmpty {
            for (address, id) in await storage.librarySourceIDs(forReferenceURLs: remaining) { matches[address] = id }
        }
        guard !matches.isEmpty else { return [:] }
        let articles = (try? await storage.loadPersistedSources(ids: Array(Set(matches.values)))) ?? []
        let byID = Dictionary(articles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var resolved: [String: ChatSourceCard] = [:]
        var cards: [String: ChatSourceCard] = [:]
        for (address, id) in matches {
            if let card = resolved[id] {
                cards[address] = card
                continue
            }
            guard let article = byID[id] else { continue }
            let card = await ChatSourceCard.resolved(
                article: article,
                collectionTitle: sourceGroupTitle(for: article)
            )
            resolved[id] = card
            cards[address] = card
        }
        return cards
    }

    /// Make the selected source visible in the sidebar list, not just selected.
    /// Selection alone can leave nothing on screen: a source past the sidebar's
    /// page size has no row at all, and one that does have a row usually sits far
    /// below the fold. Grow pagination so the row exists, then ask the sidebar to
    /// scroll it into view.
    func revealSourceInSidebar(_ article: StudioArticle) {
        growDisplayLimit(toInclude: article)
        sidebarRevealRequest = SidebarRevealRequest(sourceID: article.id)
    }

    /// Raise whichever display limit governs this source's list far enough to
    /// include it. Grouped tabs render every item, so they need no growth — except
    /// the Videos tab, whose flat rows page like a flat tab's.
    private func growDisplayLimit(toInclude article: StudioArticle) {
        if sidebarTab == .videos {
            guard let index = pagedVideoRows.firstIndex(where: { $0.id == article.id }) else { return }
            displayLimit = max(displayLimit, index + 1)
            return
        }
        if sidebarTab.isGrouped { return }

        if sidebarTab == .papers {
            if let index = filteredPaperItems(hasPDF: true).firstIndex(where: { $0.id == article.id }) {
                papersWithPDFDisplayLimit = max(papersWithPDFDisplayLimit, index + 1)
            } else if let index = papersNeedingPDFAttention.firstIndex(where: { $0.id == article.id }) {
                papersWithoutPDFDisplayLimit = max(papersWithoutPDFDisplayLimit, index + 1)
            } else if let index = filteredPaywalledPapersWithoutPDF.firstIndex(where: { $0.id == article.id }) {
                paywalledPapersDisplayLimit = max(paywalledPapersDisplayLimit, index + 1)
            }
            return
        }

        guard let index = filteredActiveItems.firstIndex(where: { $0.id == article.id }) else { return }
        displayLimit = max(displayLimit, index + 1)
    }

    // MARK: - Toast

    /// How long a toast stays up on its own.
    ///
    /// One banner carries both "Copied source ID" and a provider's three-paragraph
    /// refusal, and the three seconds that suit the first give the second no chance
    /// of being read. Dwell tracks how much there is to read — about 180 words a
    /// minute — floored at the old three seconds so short confirmations feel
    /// unchanged, and capped so nothing outstays a pointer that never comes near it.
    /// The ceiling is safe to be generous about because the banner can now be
    /// dismissed outright.
    ///
    /// A toast carrying Undo is an offer as much as a notice, and three seconds
    /// is barely long enough to read "Hid <title>", let alone to decide it was a
    /// mistake and reach for the button. Such a toast stays at least six seconds,
    /// short of the deletion notices' ten because nothing is destroyed.
    static func toastDuration(for message: String, undoable: Bool = false) -> Duration {
        let unhurried = Double(max(0, message.count - 40)) * 0.06
        return .seconds(min(max(3 + unhurried, undoable ? 6 : 0), 20))
    }

    /// Show `message` in the status banner. Pass `undo` when the action it
    /// reports can be taken back; the banner then offers an Undo button that
    /// runs it and closes the toast. Pass `action` when the message reports
    /// something that happened in another window and can be redone in the
    /// one the banner is read in; the banner offers it under its own title.
    func showToast(
        _ message: String,
        undo: (() async -> Void)? = nil,
        action: StudioToastAction? = nil
    ) {
        toastDismissTask?.cancel()
        toastMessage = message
        toastUndo = undo
        toastAction = action
        scheduleToastDismissal(for: message)
    }

    /// Dismiss the current toast now, from the close button.
    func dismissToast() {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        toastMessage = nil
        toastUndo = nil
        toastAction = nil
    }

    /// Run the current toast's action from its button, for the window whose
    /// banner was pressed. The toast closes first, as Undo does, so whatever
    /// the action reports replaces it rather than racing it.
    func runToastAction(in window: StudioWindowState?) async {
        guard let action = toastAction else { return }
        dismissToast()
        await action.run(window)
    }

    /// Take back what the current toast reports, from its Undo button. The
    /// toast closes first so the action's own confirmation ("Unhid <title>")
    /// replaces it rather than racing it.
    func undoToast() async {
        guard let undo = toastUndo else { return }
        dismissToast()
        await undo()
    }

    /// Hold the current toast open while the pointer rests on it, and start the
    /// countdown again from the top once it leaves. Reading a long error or
    /// dragging a selection across it must not race a timer that started before
    /// the message was noticed.
    func setToastHovered(_ hovering: Bool) {
        guard let toastMessage else { return }
        toastDismissTask?.cancel()
        toastDismissTask = nil
        guard !hovering else { return }
        scheduleToastDismissal(for: toastMessage)
    }

    /// Defer a destructive write long enough to make an accidental removal
    /// undoable. The visible row/group is hidden before this is called; `undo`
    /// restores that lightweight visibility change, while `commit` performs the
    /// existing archive/delete workflow only after the grace period expires.
    @discardableResult
    func deferDeletion(
        message: String,
        sourceIDs: Set<String> = [],
        deletionKey: String? = nil,
        gracePeriod: Duration,
        undo: @escaping () async -> Void,
        commit: @escaping () async -> Void
    ) -> UUID {
        let id = UUID()
        pendingDeletionNotices.append(PendingDeletionNotice(id: id, message: message))
        pendingDeletionUndoActions[id] = undo
        if !sourceIDs.isEmpty {
            pendingDeletionSourceIDs[id] = sourceIDs
        }
        if let deletionKey {
            pendingDeletionKeys[id] = deletionKey
        }

        pendingDeletionTasks[id] = Task { [weak self] in
            do {
                try await Task.sleep(for: gracePeriod)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.clearPendingDeletion(id, cancelTask: false)
            await commit()
        }
        return id
    }

    func undoLatestDeletion() async {
        guard let id = pendingDeletionNotices.last?.id else { return }
        await undoPendingDeletion(id)
    }

    // MARK: - What is being removed

    /// The keys the group removals register with `deferDeletion`, kept in one
    /// place so the hidden-items lists ask about the same removal the Undo
    /// banner is showing.
    nonisolated static func meetingRemovalKey(_ groupID: String) -> String { "meeting:\(groupID)" }
    nonisolated static func courseRemovalKey(_ courseID: String) -> String { "course:\(courseID)" }
    nonisolated static func bookRemovalKey(_ groupName: String) -> String { "book:\(groupName)" }
    nonisolated static func podcastShowRemovalKey(_ showName: String) -> String { "podcast:\(showName)" }
    nonisolated static func videoPlaylistRemovalKey(_ groupID: String) -> String { "video-playlist:\(groupID)" }

    /// Whether a source is on its way out of the library: its removal is
    /// inside the Undo window, or its row is already off the sidebar while the
    /// writes that open that window drain.
    ///
    /// A removal hides first and deletes when the banner expires, so for those
    /// ten seconds the source (or its group) is hidden in every store. It is not
    /// a hidden item, though — the learner did not hide it, and the Undo banner
    /// is its affordance — so the hidden-items footer and popover leave it out.
    /// Every removal used to spend the window as "1 hidden item" at the foot of
    /// the list (product owner, 2026-09-20: a deleted meeting folder "still show[ed]
    /// up for a while at the bottom"). A removal interrupted before it finished
    /// has no pending deletion, so what it left hidden stays listed and can be
    /// restored from there.
    func isSourceBeingRemoved(_ sourceID: String) -> Bool {
        sourceIDsBeingRemoved.contains(sourceID) || hasPendingDeletion(forSourceID: sourceID)
    }

    func hasPendingDeletion(forSourceID sourceID: String) -> Bool {
        pendingDeletionSourceIDs.values.contains { $0.contains(sourceID) }
    }

    func hasPendingDeletion(forDeletionKey deletionKey: String) -> Bool {
        pendingDeletionKeys.values.contains(deletionKey)
    }

    @discardableResult
    func undoPendingDeletion(forSourceID sourceID: String) async -> Bool {
        guard let id = pendingDeletionNotices.reversed().first(where: {
            pendingDeletionSourceIDs[$0.id]?.contains(sourceID) == true
        })?.id else {
            return false
        }
        await undoPendingDeletion(id)
        return true
    }

    @discardableResult
    func undoPendingDeletion(forDeletionKey deletionKey: String) async -> Bool {
        guard let id = pendingDeletionNotices.reversed().first(where: {
            pendingDeletionKeys[$0.id] == deletionKey
        })?.id else {
            return false
        }
        await undoPendingDeletion(id)
        return true
    }

    private func undoPendingDeletion(_ id: UUID) async {
        pendingDeletionTasks[id]?.cancel()
        let undo = pendingDeletionUndoActions[id]
        clearPendingDeletion(id)
        await undo?()
    }

    private func clearPendingDeletion(_ id: UUID, cancelTask: Bool = true) {
        if cancelTask {
            pendingDeletionTasks[id]?.cancel()
        }
        pendingDeletionTasks[id] = nil
        pendingDeletionUndoActions[id] = nil
        pendingDeletionSourceIDs[id] = nil
        pendingDeletionKeys[id] = nil
        pendingDeletionNotices.removeAll { $0.id == id }
    }

    private func scheduleToastDismissal(for message: String) {
        // An Open here button is an offer as much as Undo is, and needs the
        // same time to be read and reached for.
        let undoable = toastUndo != nil || toastAction != nil
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.toastDuration(for: message, undoable: undoable))
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
            self?.toastUndo = nil
            self?.toastAction = nil
            self?.toastDismissTask = nil
        }
    }

    /// Hands a Reader selection — words, pictures, or both — to Chat.
    ///
    /// Words are staged at once. Pictures are fetched first
    /// (`ReaderSelectionImageResolver`), so the message the learner sends
    /// carries the figure itself and the model can read it; `pictureSnapshot`
    /// is the reader's web view photographing a picture its page will not
    /// hand over any other way, and is nil for a selection recalled from ⇧⌘K
    /// or a saved mark. A picture that cannot be read is said so, and the
    /// words (or the other pictures) still go.
    func requestReaderSelectionExplanation(
        sourceID: String,
        selectedText: String,
        images: [ReaderSelectionImage] = [],
        pictureSnapshot: ReaderSelectionImageResolver.Snapshot? = nil
    ) {
        let cleanedText = Self.cleanedReaderSelection(selectedText)
        guard !sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !cleanedText.isEmpty || !images.isEmpty else {
            showToast("Select text or a picture in the reader first")
            return
        }
        guard !images.isEmpty else {
            stageReaderSelection(sourceID: sourceID, cleanedText: cleanedText, attachments: [], unreadable: 0)
            return
        }
        Task { @MainActor in
            let outcome = await ReaderSelectionImageResolver.attachments(for: images, snapshot: pictureSnapshot)
            if outcome.attachments.isEmpty, cleanedText.isEmpty {
                showToast(outcome.unreadable == 1 ? "That picture could not be read" : "Those pictures could not be read")
                return
            }
            stageReaderSelection(
                sourceID: sourceID,
                cleanedText: cleanedText,
                attachments: outcome.attachments,
                unreadable: outcome.unreadable
            )
        }
    }

    private func stageReaderSelection(
        sourceID: String,
        cleanedText: String,
        attachments: [ChatImageAttachment],
        unreadable: Int
    ) {
        addSourceToContext(sourceID)
        revealChatBesideReader()
        readerSelectionExplanationRequest = ReaderSelectionExplanationRequest(
            sourceID: sourceID,
            selectedText: cleanedText,
            imageAttachments: attachments
        )
        let what: String
        if cleanedText.isEmpty {
            what = attachments.count == 1 ? "Picture" : "Pictures"
        } else {
            what = "Selection"
        }
        // Setting the request stamped its window; when that is not this one —
        // a popped-out Reader, or every pane here pinned — say where it went
        // in the same breath, rather than with a banner this one replaces.
        var message = Self.addedToChatMessage(what, elsewhere: chatRequestElsewhereNotice)
        if unreadable == 1 {
            message += "; one picture could not be read"
        } else if unreadable > 1 {
            message += "; \(unreadable) pictures could not be read"
        }
        showToast(message)
    }

    /// "Selection added to Chat", or "Selection added to Chat in the other
    /// ForeverLM window" when the stamp found the chat will show elsewhere.
    static func addedToChatMessage(_ what: String, elsewhere notice: String?) -> String {
        guard let notice else { return "\(what) added to Chat" }
        return "\(what) added to Chat in \(notice)"
    }

    /// Opens a fresh Chat beside Docs or Sites, on its right — the side the Reader's
    /// selection handoff uses, so a question about a passage always opens where
    /// the eye reads toward and the doc keeps its pane — and carries the exact
    /// selected passage/excerpt, revision pointer, and enabled sources. A
    /// highlighted passage is a new conversational intent: it must never be
    /// injected into whichever durable conversation happened to be open
    /// previously. The one exception is decided by the pane, which knows its
    /// chat: a conversation already working on this Doc takes the passage and
    /// lets the reset asked for here go
    /// (`StudioAssistantSessionStore.docPassageJoinsOpenChat`). The complete
    /// Article stays in its canonical body asset rather than being copied into
    /// every conversation.
    /// The note does not own a second conversation implementation.
    ///
    /// With no passage (`selectedText` empty) the chat is about the page as a
    /// whole: the page rides along by identity, so `read_doc` reaches all of
    /// it, and nothing is quoted. A `draft` — a Prompt block's words — waits
    /// under the composer as the writer's to edit; it is never sent from here.
    func requestNotepadChat(
        noteTitle: String,
        sectionTitle: String = "",
        selectedText: String,
        sourceIDs: [String],
        artifactID: String,
        artifactRevision: String,
        artifactNotebookID: String?,
        selectionRange: Range<Int>?,
        contextExcerpt: String?,
        artifactAttachment: ChatDocAttachment? = nil,
        draft: String? = nil,
        originSection: ArtifactSection = .docs
    ) {
        let selection = Self.notepadSelectionRequest(
            noteTitle: noteTitle,
            sectionTitle: sectionTitle,
            selectedText: selectedText,
            sourceIDs: sourceIDs,
            artifactID: artifactID,
            artifactRevision: artifactRevision,
            artifactNotebookID: artifactNotebookID,
            selectionRange: selectionRange,
            contextExcerpt: contextExcerpt,
            artifactAttachment: artifactAttachment,
            originSection: originSection
        )
        // Set rather than add. The chat pane's pool outlives the conversation
        // that filled it, so adding left sources from an hour ago sitting in
        // the context of a question about two highlighted citations — the
        // pane truthfully reported them as "in context", and they were.
        // A live session reads its sources from the session itself, so
        // replacing the idle pool cannot disturb one in progress.
        setContextSources(sourceIDs)
        revealChat(beside: originSection.centerTab)
        // A doc that lives in a Notebook hands its chat that Notebook too, so the
        // Notebook's instructions and research questions frame the question the
        // same way they frame a chat opened from the Notebook itself. Linking
        // stages none of the Notebook's sources: the grounding stays the
        // passage's own citations, set just above.
        pendingReviewChatNotebookID = artifactNotebookID
        let words = draft?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        pendingReviewChatDraft = words.isEmpty ? nil : words
        reviewChatResetRequestID = UUID()
        reviewChatFocusRequestID = UUID()

        if let selection {
            readerSelectionExplanationRequest = selection
            let what = originSection == .sites ? "Site selection" : "Article"
            showToast(Self.addedToChatMessage(what, elsewhere: chatRequestElsewhereNotice))
        } else if let artifactAttachment {
            // No passage carries the page to the chat, so it goes the way a
            // dropped Doc does; the pane takes it after the fresh chat opens.
            pendingChatDocAttachment = artifactAttachment
        }
    }

    /// The request a page's highlighted passage hands the chat, quoted and
    /// pointing back at its revision; nil when nothing is highlighted, which
    /// is a chat about the page as a whole. The docked route stages it through
    /// `readerSelectionExplanationRequest`, the page's side chat through its
    /// own store (`PageSideChatOpening`): both read the same words.
    static func notepadSelectionRequest(
        noteTitle: String,
        sectionTitle: String = "",
        selectedText: String,
        sourceIDs: [String],
        artifactID: String,
        artifactRevision: String,
        artifactNotebookID: String?,
        selectionRange: Range<Int>?,
        contextExcerpt: String?,
        artifactAttachment: ChatDocAttachment? = nil,
        originSection: ArtifactSection = .docs
    ) -> ReaderSelectionExplanationRequest? {
        let cleanedText = cleanedReaderSelection(selectedText)
        guard !cleanedText.isEmpty else { return nil }
        let title = noteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let section = sectionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let contextNoun = originSection == .sites ? "Site" : "Note"
        var contextTitle = title.isEmpty ? contextNoun : "\(contextNoun): \(title)"
        if !section.isEmpty, section != title { contextTitle += " — \(section)" }
        return ReaderSelectionExplanationRequest(
            sourceIDs: sourceIDs,
            selectedText: cleanedText,
            contextTitle: contextTitle,
            artifactID: artifactID,
            artifactRevision: artifactRevision,
            artifactNotebookID: artifactNotebookID,
            selectionRange: selectionRange,
            contextExcerpt: contextExcerpt,
            artifactAttachment: artifactAttachment,
            sectionTitle: section
        )
    }

    /// A pane with no neighbour to hand to — a comparison pane, the pop-out
    /// window — sends an exchange lifted out of a memory review to the primary
    /// Chat through the app-wide request, as a new chat: the exchange's sources
    /// replace the idle pool, whatever conversation the primary pane showed is
    /// parked, and the exchange waits under the composer.
    func requestChatAboutReviewExchange(_ request: ReaderSelectionExplanationRequest) {
        setContextSources(request.sourceIDs)
        pendingReviewChatNotebookID = nil
        pendingReviewChatDraft = nil
        reviewChatResetRequestID = UUID()
        reviewChatFocusRequestID = UUID()
        readerSelectionExplanationRequest = request
        showToast(Self.addedToChatMessage("Exchange", elsewhere: chatRequestElsewhereNotice))
    }

    /// The same route for a side question lifted out of a quiz, with one
    /// difference: the new chat is filed under the quiz's Notebook, so the
    /// detour stays beside the review it came from.
    func requestChatAboutSideQuestion(_ request: ReaderSelectionExplanationRequest) {
        setContextSources(request.sourceIDs)
        let notebookID = request.sideQuestionHandoff?.notebookID
        pendingReviewChatNotebookID = notebookID.flatMap { notebook(id: $0) != nil ? $0 : nil }
        pendingReviewChatDraft = nil
        reviewChatResetRequestID = UUID()
        reviewChatFocusRequestID = UUID()
        readerSelectionExplanationRequest = request
        showToast(Self.addedToChatMessage("Side question", elsewhere: chatRequestElsewhereNotice))
    }

    /// The same route for words selected in a reply of a pane with no
    /// neighbour to open a chat beside: the passage waits under the primary
    /// Chat's composer as a new chat's context, with the sources of the chat
    /// it was read in.
    func requestChatAboutPassage(_ request: ReaderSelectionExplanationRequest) {
        setContextSources(request.sourceIDs)
        pendingReviewChatNotebookID = nil
        pendingReviewChatDraft = nil
        reviewChatResetRequestID = UUID()
        reviewChatFocusRequestID = UUID()
        readerSelectionExplanationRequest = request
        showToast(Self.addedToChatMessage("Passage", elsewhere: chatRequestElsewhereNotice))
    }

    /// A fresh chat beside the pane showing a card to check, filed where this
    /// window files new chats. It carries no attachment of its own: the card
    /// on screen rides every message (`ChatContextAdditions.cardFraming`), and
    /// the chat keeps it pinned (`ReviewSessionManager.pinnedCard`), because
    /// opening the chat can take the Memory pane's place and a Reader behind
    /// it would otherwise be what the chat is about.
    func requestChatAboutCardOnScreen() {
        pendingChatCanvasCards = nil
        pendingReviewChatNotebookID = newChatNotebookID()
        pendingReviewChatDraft = nil
        pendingReviewChatCanvasQuestions = []
        pendingReviewChatCard = activeWindowState.memoryCardOnScreen
        reviewChatResetRequestID = UUID()
        reviewChatFocusRequestID = UUID()
        openCenterTabBeside(.chat)
    }

    static func cleanedReaderSelection(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ⇧⌘K entry point: if the reader has a live selection, chat about it;
    /// otherwise reveal and focus the docked Chat panel.
    func handleAssistantShortcut() {
        if let selection = activeReaderSelection,
           !Self.cleanedReaderSelection(selection.text).isEmpty || !selection.images.isEmpty {
            requestReaderSelectionExplanation(
                sourceID: selection.sourceID,
                selectedText: selection.text,
                images: selection.images
            )
        } else {
            showAssistantOverlay = true
            reviewChatFocusRequestID = UUID()
        }
    }

    /// ⌘R entry point: bring the Reader tab forward. Mirrors the reveal steps
    /// of the explicit open paths (openSourceInReader) but keeps whatever the
    /// reader is already showing — with no source selected it shows its idle state.
    func handleReaderShortcut() {
        showReaderPanel = true
        readerPoppedOut = false
        activateCenterTab(.reader)
    }

    /// Called by reader panels as the selection changes so ⇧⌘K knows what to act on.
    /// An empty selection only clears state that belongs to the same source, so a
    /// deselect in one reader can't wipe a live selection in another.
    ///
    /// `images` is what a web reader's page reported inside the selection;
    /// nil means "unchanged" and keeps the pictures that reader last
    /// reported, because the text bindings the panels re-report through know
    /// nothing about pictures and would otherwise clear them on every change.
    func updateActiveReaderSelection(sourceID: String, text: String, images: [ReaderSelectionImage]? = nil) {
        if let images {
            if images.isEmpty {
                if readerSelectionImages[sourceID] != nil { readerSelectionImages[sourceID] = nil }
            } else if readerSelectionImages[sourceID] != images {
                readerSelectionImages[sourceID] = images
            }
        }
        let pictures = readerSelectionImages[sourceID] ?? []
        if Self.cleanedReaderSelection(text).isEmpty, pictures.isEmpty {
            if activeReaderSelection?.sourceID == sourceID {
                activeReaderSelection = nil
            }
        } else {
            activeReaderSelection = ReaderChatSelection(sourceID: sourceID, text: text, images: pictures)
        }
    }

    /// The pictures the web reader for `sourceID` last reported inside its
    /// selection.
    func readerSelectionImages(for sourceID: String) -> [ReaderSelectionImage] {
        readerSelectionImages[sourceID] ?? []
    }

    /// Drop the tracked selection when a reader for `sourceID` goes away.
    func clearActiveReaderSelection(forSourceID sourceID: String) {
        if readerSelectionImages[sourceID] != nil { readerSelectionImages[sourceID] = nil }
        if activeReaderSelection?.sourceID == sourceID {
            activeReaderSelection = nil
        }
    }

    // MARK: - Private Helpers

    /// Save `article`, showing a failure unless `showErrorToast` is false.
    /// `replacingDerivedData` is for a source whose text was replaced at its
    /// root (a new PDF of the paper): the old text and everything derived from
    /// it go in the same transaction as the save, and stay if it fails.
    @discardableResult
    func persistSource(
        _ article: StudioArticle,
        context: String,
        showErrorToast: Bool = true,
        syncImmediately: Bool = false,
        replacingDerivedData: Bool = false
    ) async -> Bool {
        do {
            if replacingDerivedData {
                try await storage.saveSourceReplacingDerivedData(article, syncImmediately: syncImmediately)
            } else {
                try await storage.saveSource(article, syncImmediately: syncImmediately)
            }
            // A new source is searchable by its title at once, even queued with no text yet.
            kickSourceEmbeddingIndexingSoon()
            if article.state == .ready,
               SourceAudioAutomation.preferenceKey(
                   for: SourceAudioAutomation.kind(forSourceType: article.sourceType.rawValue, url: article.url)
               ) != nil {
                NotificationCenter.default.post(
                    name: .automaticSourceAudioCandidateDidChange,
                    object: article.id
                )
            }
            return true
        } catch {
            logger.error("\(context) failed for source \(article.id): \(error.localizedDescription)")
            if showErrorToast {
                showToast("\(context) failed: \(error.localizedDescription)")
            }
            return false
        }
    }

    /// Re-resolve an article by id at call time and mutate it in place. Writes that
    /// happen after an `await` must never target a captured array index: a
    /// concurrent refresh can reorder or shrink `articles` in the meantime, so a
    /// stale index would write to — or delete — the wrong source, or crash out of
    /// range. This resolves the index fresh and assigns once (a single `didSet`).
    /// Returns false if the source no longer exists.
    @discardableResult
    func mutateArticle(id: String, _ body: (inout StudioArticle) -> Void) -> Bool {
        guard let idx = articles.firstIndex(where: { $0.id == id }) else { return false }
        var updated = articles[idx]
        body(&updated)
        articles[idx] = updated
        return true
    }

    /// Restores an archived source: status back to active, the dismissal a
    /// removal left on its URL cleared, and text rebuilt from its local file
    /// when it has one. The `unarchive_source` MCP tool is this action's twin
    /// and runs the same store code, per the rule that every setting and UI
    /// action has MCP parity. The library is reloaded so every row that names
    /// the source reads it as in the library again. Returns the title, for
    /// the toast a caller may want beyond the one shown here.
    @discardableResult
    func unarchiveSource(_ sourceID: String) async throws -> String {
        guard let outcome = try await storage.unarchiveSourceRestoringContent(sourceID) else {
            throw StudioError.sourceNotFound(sourceID)
        }
        await refreshArticles()
        showToast("Restored “\(outcome.title)” from the archive")
        return outcome.title
    }

    /// Reload the articles array from SQLite. This is the ONLY way articles gets populated after mutations.
    func refreshArticles() async {
        let articlesSnapshot = articles
        do {
            let library = try await storage.loadLibrarySources()
            articlesStore.teamCopyAliases = library.teamCopyAliases
            articles = preservingLoadedContent(in: library.sources, preservingFrom: articlesSnapshot)
            // Team notebooks' copies are marked on the rows the aliases name.
            refreshNotebookSidebarIndex()
            autoFetchNewlyAddedPapers()
            autoFetchUnfetchedSources()
            await convergePaperIdentityDuplicates()
            // Runs against a loaded library, and only once — see the method.
            await resolveSuppressedDuplicatePapers()
            await refreshCourseOutline()
            await refreshMeetingMetadata()
        } catch {
            logger.error("Failed to refresh articles from database: \(error)")
        }
    }

    func refreshCourseOutline() async {
        do {
            async let lectures = storage.loadCourseLectures()
            async let items = storage.loadCourseLectureItems()
            async let artworkURLs = storage.loadCourseArtworkURLs()
            applyCourseOutline(
                lectures: try await lectures,
                items: try await items
            )
            courseCoverArtworkURLs = try await artworkURLs
        } catch {
            logger.error("Failed to refresh course lectures: \(error.localizedDescription)")
        }
        await refreshCourseQuizzes()
    }

    /// Reads every course's stored quizzes and their latest sittings into the
    /// outline. The launch load and the synced-course refresh call it beside
    /// their lecture loads: without it a relaunch showed a course with every
    /// quiz still in knowledge.db but none in its ladder, until a quiz was
    /// written again.
    func refreshCourseQuizzes() async {
        do {
            async let quizzes = storage.loadCourseQuizzes()
            async let sittingRows = storage.loadCourseQuizSittingRows()
            let loadedQuizzes = try await quizzes
            let quizzesByCourse = Dictionary(grouping: loadedQuizzes, by: \.courseID)
            if quizzesByCourse != courseQuizzesByCourse {
                courseQuizzesByCourse = quizzesByCourse
            }
            // A quiz's progress failing to read leaves the rows as they were
            // rather than failing the quizzes around them.
            do {
                let rows = try await sittingRows
                let (sittings, finished) = await Task.detached(priority: .userInitiated) {
                    (
                        CourseQuizSitting.latest(rows: rows, quizzes: loadedQuizzes),
                        CourseQuizSitting.latestFinished(rows: rows, quizzes: loadedQuizzes)
                    )
                }.value
                if sittings != courseQuizSittings {
                    courseQuizSittings = sittings
                }
                if finished != courseQuizFinishedSittings {
                    courseQuizFinishedSittings = finished
                }
            } catch {
                logger.error("Failed to read course quiz sittings: \(error.localizedDescription)")
            }
        } catch {
            logger.error("Failed to load course quizzes: \(error.localizedDescription)")
        }
    }

    func refreshMeetingMetadata() async {
        do {
            meetingMetadata = try await storage.loadMeetingMetadata()
            applyMeetingArtifacts(try await storage.loadMeetingArtifacts())
        } catch {
            logger.error("Failed to refresh meeting metadata: \(error.localizedDescription)")
        }
    }

    func applyCourseOutline(lectures: [CourseSession], items: [CourseLectureItem]) {
        courseLecturesByCourse = Dictionary(grouping: lectures, by: \.courseName)
            .mapValues { $0.sorted { $0.number < $1.number } }
        courseLectureItemsByLectureId = Dictionary(grouping: items, by: \.lectureId)
            .mapValues { $0.sorted { $0.sortIndex < $1.sortIndex } }
        refreshCourseSourceUnits(for: items)
    }

    func applyMeetingArtifacts(_ artifacts: [MeetingArtifact]) {
        meetingArtifactsBySourceId = Dictionary(grouping: artifacts, by: \.sourceId)
            .mapValues { $0.sorted { $0.sortIndex < $1.sortIndex } }
    }


    // MARK: - Move Article Between Tabs

    /// Allowed source type transitions. Only article↔paper is supported;
    /// books, courses, meetings, podcasts, videos, and X posts have distinct content
    /// structures that don't transfer cleanly.
    static let allowedMoves: Set<[StudioSourceType]> = [
        [.article, .paper],
        [.paper, .article],
        [.unclassified, .paper],
        [.unclassified, .article],
    ]

    /// Change an article's source type (e.g. move from Papers to Articles) and persist.
    /// Triggers paper enrichment (metadata lookup, PDF download) when moving to paper.
    func moveArticle(id: String, to newType: StudioSourceType) {
        guard let idx = articles.firstIndex(where: { $0.id == id }),
              articles[idx].sourceType != newType,
              Self.allowedMoves.contains([articles[idx].sourceType, newType]) else { return }
        let previousArticle = articles[idx]
        articles[idx].sourceType = newType
        if newType == .paper {
            articles[idx].dateAdded = Date()
            articles[idx].prepareForPaperMetadataExtraction()
        }
        let updatedArticle = articles[idx]
        Task {
            do {
                if newType == .paper {
                    try await storage.saveSource(updatedArticle, syncImmediately: true)
                } else {
                    try await storage.updateSourceType(id, to: newType.rawValue)
                }
            } catch {
                logger.error("Source type move failed for \(id): \(error.localizedDescription)")
                if let currentIdx = articles.firstIndex(where: { $0.id == id }) {
                    articles[currentIdx] = previousArticle
                }
                showToast("Could not move source: \(error.localizedDescription)")
                await refreshArticles()
                return
            }
            await refreshArticles()

            if newType == .paper {
                await backfillPaperMetadata(onlyIds: [id])
                enqueueAutoPaperFetch(id)
                autoExtractMissingPaperMetadata()
            }
        }
    }

    // MARK: - X Bookmarks

    func checkXSignInStatus() {
        Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                let service = XBookmarkService.shared
                let accounts = service.accounts
                return (
                    accounts: accounts,
                    needingReauth: Set(accounts.filter { service.needsReauthentication(accountID: $0.id) }.map(\.id)),
                    lastSyncDates: Dictionary(uniqueKeysWithValues: accounts.compactMap { account in
                        service.lastSyncDate(accountID: account.id).map { (account.id, $0) }
                    })
                )
            }.value
            guard let self else { return }
            xAccounts = snapshot.accounts
            xAccountsNeedingReauth = snapshot.needingReauth
            xLastSyncDates = snapshot.lastSyncDates
            // State of an account that is gone (disconnected from the pane or
            // dropped elsewhere) has nothing left to describe.
            let ids = Set(snapshot.accounts.map(\.id))
            xAccountFailures = xAccountFailures.filter { ids.contains($0.key) }
            xSyncPausedUntil = xSyncPausedUntil.filter { ids.contains($0.key) }
            pinIntegrationTabsInUse()
        }
    }

    /// Signs in with X, adding the account it signs in as (or refreshing the
    /// one already connected for that X user), then syncs that account.
    func signInWithX() async {
        // One browser session at a time: a second `authenticate()` would
        // replace the first session and leave its continuation waiting forever.
        guard !isConnectingX else { return }
        isConnectingX = true
        xConnectError = nil
        do {
            let account = try await XBookmarkService.shared.authenticate()
            isConnectingX = false
            xAccounts = XAccountBook.merging(account, into: xAccounts)
            xAccountsNeedingReauth.remove(account.id)
            xAccountFailures[account.id] = nil
            forgetXSyncPause(accountID: account.id)
            // Connecting is the evidence the X tab was waiting for.
            pinIntegrationTabsInUse()
            // The handle was written with the tokens; read it back off-main
            // the same way every other refresh does.
            checkXSignInStatus()
            // A successful connection should do the job the user connected it
            // for. Do not wait for a later app-activation or manual refresh.
            await syncXBookmarks(showResult: true, accountID: account.id)
        } catch {
            isConnectingX = false
            let message = XBookmarkError.userFacingMessage(for: error, action: .connect)
            logger.error("X sign-in failed: \(error.localizedDescription, privacy: .private)")
            errorMessage = message
            xConnectError = message
            showToast(message)
            checkXSignInStatus()
        }
    }

    /// Disconnects one X account; the others keep syncing.
    func signOutOfX(accountID: String) {
        XBookmarkService.shared.signOut(accountID: accountID)
        xAccounts = XAccountBook.removing(id: accountID, from: xAccounts)
        xAccountsNeedingReauth.remove(accountID)
        xLastSyncDates[accountID] = nil
        xAccountFailures[accountID] = nil
        forgetXSyncPause(accountID: accountID)
    }

    private func forgetXSyncPause(accountID: String) {
        xSyncPausedUntil[accountID] = nil
        xSyncResumeTasks[accountID]?.cancel()
        xSyncResumeTasks[accountID] = nil
    }

    /// Syncs every connected account (one failing account does not stop the
    /// others, and its failure is kept against it), or just `accountID`.
    /// Accounts waiting out a rate limit are skipped, and so are those that
    /// need reconnecting when no account is named: a sync of either is a
    /// request that cannot succeed.
    @discardableResult
    func syncXBookmarks(showResult: Bool = false, accountID: String? = nil) async -> Int {
        guard !isSyncingXBookmarks else { return 0 }
        let targets = xAccounts.filter { account in
            if let accountID { return account.id == accountID }
            return !xAccountsNeedingReauth.contains(account.id)
        }.filter { !isXSyncPaused(accountID: $0.id) }
        guard !targets.isEmpty else { return 0 }
        isSyncingXBookmarks = true
        xSyncingAccountIDs = Set(targets.map(\.id))
        defer {
            isSyncingXBookmarks = false
            xSyncingAccountIDs = []
        }

        var importedCount = 0
        var anySucceeded = false
        var anyFailed = false
        for account in targets {
            do {
                let saved = try await importXBookmarks(from: account)
                importedCount += saved
                anySucceeded = true
                xLastSyncDates[account.id] = XBookmarkService.shared.lastSyncDate(accountID: account.id)
                xAccountFailures[account.id] = nil
                forgetXSyncPause(accountID: account.id)
                xCreditsDepleted = false
            } catch {
                anyFailed = true
                let message = XBookmarkError.userFacingMessage(for: error, action: .syncBookmarks)
                logger.error("X bookmark sync failed: \(error.localizedDescription, privacy: .private)")
                errorMessage = xAccounts.count > 1 ? "\(account.displayLabel): \(message)" : message
                // No toast. Most syncs run on their own, and a banner that vanishes
                // before it is read is noise; the message becomes a red dot on the
                // X tab (`xPluginAttention`), and the X list and the plugin
                // page both show it in full, against the account, with a retry
                // beside it.
                xAccountFailures[account.id] = XAccountFailure(
                    message: message,
                    offersReconnect: XBookmarkError.reconnectMayHelp(after: error)
                )
                if case .creditsDepleted? = error as? XBookmarkError { xCreditsDepleted = true }
                scheduleXSyncResume(accountID: account.id, after: error)
            }
            xSyncingAccountIDs.remove(account.id)
        }
        if anyFailed {
            // A failed token refresh drops the account's tokens in the keychain;
            // re-read so the sidebar shows the reconnect button.
            checkXSignInStatus()
        }
        guard anySucceeded else { return 0 }

        // A freshly imported bookmark holds the post's text and nothing
        // else. Capture the thread it belongs to now, while x.com is
        // plainly reachable, so the post is still readable when it is not.
        autoFetchUnfetchedSources()
        let namedCount = await backfillXPostAuthorNames()
        let picturedCount = await backfillXPostArtwork()
        if importedCount > 0 || namedCount > 0 || picturedCount > 0 {
            syncCloudKitInBackground()
        }
        if showResult {
            showToast(importedCount == 0
                ? "X bookmarks are up to date"
                : "Imported \(importedCount) X bookmark\(importedCount == 1 ? "" : "s")")
        }
        return importedCount
    }

    /// One account's pass: fetches what is new in its bookmarks and saves it.
    private func importXBookmarks(from account: XAccount) async throws -> Int {
        let existingURLs = Set(articles.map { $0.url })
        // The posts already saved are what a sync stops at, so it asks X
        // only for what is newer than them.
        let savedPostIDs = Set(articles.lazy
            .filter { $0.sourceType == .xPost }
            .compactMap { XPostThreadService.postID(from: $0.url) })
        return try await XBookmarkService.shared.fetchNewBookmarks(
            accountID: account.id,
            savedPostIDs: savedPostIDs
        ) { bookmarks in
            var saved = 0
            // X returns bookmark candidates newest-first. Save oldest-first
            // so sequential dateAdded values and insert-at-front both leave
            // the newest bookmark at the top of Studio.
            for bookmark in bookmarks.reversed() {
                let postURL = "https://x.com/\(bookmark.authorUsername)/status/\(bookmark.tweetId)"
                guard !existingURLs.contains(postURL) else { continue }

                // Same title a thread capture writes, so a post saved from a
                // pasted link and the same post saved from a bookmark are
                // named identically.
                let title = XPostThread.sourceTitle(
                    handle: bookmark.authorUsername,
                    text: bookmark.text
                )

                var article = StudioArticle(
                    url: postURL,
                    title: title,
                    sourceType: .xPost,
                    discoveryOrigin: .xBookmarks
                )
                article.content = bookmark.text
                article.wordCount = bookmark.text.split(separator: " ").count
                article.state = .ready
                article.domain = "x.com"
                // The handle is the post's address; the display name is what
                // the learner remembers the author by, and it is the only
                // part of the search that a URL and an "@handle:" title
                // cannot already answer.
                article.author = Self.normalizedXAuthorName(bookmark.authorName)
                if let createdAt = bookmark.createdAt {
                    article.publishedYear = Self.xPostYearFormatter.string(from: createdAt)
                }

                let inserted = try await storage.insertSourceIfNew(&article)
                if inserted {
                    articles.insert(article, at: 0)
                    saved += 1
                }
            }
            return saved
        }
    }

    /// Honours a 429's reset time: that account does not sync until then, and
    /// the sync the message promised ("ForeverLM will sync again at …") runs
    /// when the window reopens. Any other failure leaves retries free.
    private func scheduleXSyncResume(accountID: String, after error: Error) {
        let now = Date()
        xSyncResumeTasks[accountID]?.cancel()
        xSyncResumeTasks[accountID] = nil
        guard let resumeAt = Self.xSyncPause(after: error, now: now) else {
            xSyncPausedUntil[accountID] = nil
            return
        }
        xSyncPausedUntil[accountID] = resumeAt
        xSyncResumeTasks[accountID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(resumeAt.timeIntervalSince(now)))
            guard !Task.isCancelled, let self else { return }
            // The pause has run out whatever the sync finds; a second 429
            // schedules the next one.
            self.xSyncPausedUntil[accountID] = nil
            await self.syncXBookmarks(accountID: accountID)
        }
    }

    /// Names the authors of X posts that carry only a handle.
    ///
    /// Posts saved before the display name was kept — and any post saved from a
    /// pasted link — know their author only as `@MartinBJensen`, which is what a
    /// search has to guess. One `users/by` lookup per handle (not per post) turns
    /// that into "Martin Borch Jensen" on every post that handle wrote.
    /// Returns how many sources were named.
    @discardableResult
    func backfillXPostAuthorNames() async -> Int {
        guard isXOAuthSignedIn else { return 0 }

        var usernamesBySourceID: [String: String] = [:]
        for article in articles where article.sourceType == .xPost {
            let hasAuthor = !(article.author ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            guard !hasAuthor, let username = Self.xPostUsername(inURL: article.url) else { continue }
            usernamesBySourceID[article.id] = username
        }
        guard !usernamesBySourceID.isEmpty else { return 0 }

        let names: [String: String]
        do {
            names = try await XBookmarkService.shared.fetchDisplayNames(
                forUsernames: Array(Set(usernamesBySourceID.values))
            )
        } catch {
            // Naming an old post is housekeeping, not the sync the learner asked
            // for: log it and leave the sync's own result standing.
            logger.warning("X author name lookup failed: \(error.localizedDescription)")
            return 0
        }
        guard !names.isEmpty else { return 0 }

        var named = 0
        for (sourceID, username) in usernamesBySourceID {
            guard let name = names[username.lowercased()],
                  let index = articles.firstIndex(where: { $0.id == sourceID }) else { continue }
            var article = articles[index]
            article.author = Self.normalizedXAuthorName(name)
            guard await persistSource(article, context: "Save X author", showErrorToast: false) else { continue }
            // Re-find: a concurrent refresh may have replaced the array while the
            // save was in flight.
            if let latest = articles.firstIndex(where: { $0.id == sourceID }) {
                articles[latest] = article
            }
            named += 1
        }
        if named > 0 {
            logger.info("Named the authors of \(named) X post(s)")
        }
        return named
    }

    // MARK: - X Post Pictures

    /// How many posts one pass may read straight from X's embed endpoint.
    ///
    /// That route answers one post per request, and it is only reached for
    /// handles the batched API lookup could not answer — a signed-out learner,
    /// an anonymous `i/status` post, a handle X refused. Capped so a library
    /// opened for the first time fills in over a few passes instead of firing a
    /// hundred requests at X the moment the list appears.
    static let xPostAvatarLookupsPerPass = 12

    /// Gives every X post the picture of whoever wrote it.
    ///
    /// An X post has no artwork of its own to find: x.com serves an HTTP client
    /// a login wall rather than the `og:image` the ordinary artwork backfill
    /// reads, which is why `shouldBackfillArtwork` skips the type entirely and
    /// why the rows drew the X mark instead of a picture. The author's profile
    /// picture is the one image every post is guaranteed to have, and it is the
    /// one that makes a list of posts scannable — you recognise the person
    /// before you read the handle.
    ///
    /// Looked up per handle, not per post, and remembered for the launch, so a
    /// hundred posts by twenty authors cost twenty lookups the first time and
    /// none after that.
    ///
    /// Concurrent callers share one pass: every X row asks as it appears, and
    /// they all appear at once.
    @discardableResult
    func backfillXPostArtwork() async -> Int {
        if let existing = xPostArtworkBackfillTask { return await existing.value }
        let pass = Task { [weak self] in await self?.runXPostArtworkBackfill() ?? 0 }
        xPostArtworkBackfillTask = pass
        let count = await pass.value
        xPostArtworkBackfillTask = nil
        return count
    }

    private func runXPostArtworkBackfill() async -> Int {
        struct Candidate {
            let sourceID: String
            let postID: String
            /// Lowercased, or nil for the `x.com/i/status/…` form, which names
            /// no author.
            let handle: String?
        }

        // In library order, so the rows the learner is looking at are the ones a
        // capped pass spends its lookups on.
        let candidates: [Candidate] = articles.compactMap { article in
            guard article.sourceType == .xPost,
                  (article.artworkURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let postID = XPostThreadService.postID(from: article.url) else { return nil }
            return Candidate(
                sourceID: article.id,
                postID: postID,
                handle: Self.xPostUsername(inURL: article.url)?.lowercased()
            )
        }
        guard !candidates.isEmpty else { return 0 }

        var avatars = xAuthorAvatarURLs

        // One `users/by` call covers a hundred handles, so it is the cheapest
        // way to answer a whole library — when there is a signed-in plugin
        // to ask with.
        let unknownHandles = Set(candidates.compactMap(\.handle)).subtracting(avatars.keys)
        if !unknownHandles.isEmpty, isXOAuthSignedIn {
            do {
                let profiles = try await XBookmarkService.shared.fetchProfiles(
                    forUsernames: Array(unknownHandles)
                )
                for (handle, profile) in profiles {
                    guard let avatarURL = profile.avatarURL else { continue }
                    avatars[handle] = avatarURL
                }
            } catch {
                // Picturing a post is housekeeping. The public endpoint below
                // still answers, so this is a note, not a failure to report.
                logger.info("X profile lookup failed: \(error.localizedDescription)")
            }
        }

        var resolved: [String: String] = [:]
        var remainingLookups = Self.xPostAvatarLookupsPerPass
        for candidate in candidates {
            if let handle = candidate.handle, let avatarURL = avatars[handle] {
                resolved[candidate.sourceID] = avatarURL
                continue
            }
            guard remainingLookups > 0 else { continue }
            remainingLookups -= 1
            do {
                guard let avatarURL = try await XPostThreadService.shared
                    .authorAvatarURL(forPostID: candidate.postID) else { continue }
                if let handle = candidate.handle { avatars[handle] = avatarURL }
                resolved[candidate.sourceID] = avatarURL
            } catch {
                logger.info("No X picture for post \(candidate.postID): \(error.localizedDescription)")
            }
        }
        xAuthorAvatarURLs = avatars
        guard !resolved.isEmpty else { return 0 }

        var pictured = 0
        for (sourceID, avatarURL) in resolved {
            guard let index = articles.firstIndex(where: { $0.id == sourceID }) else { continue }
            var article = articles[index]
            // A capture or a manual pick may have given the source a picture
            // while the lookups were in flight; that one wins.
            guard (article.artworkURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            article.artworkURL = avatarURL
            guard await persistSource(article, context: "Save X post picture", showErrorToast: false)
            else { continue }
            // Re-find: a concurrent refresh may have replaced the array while
            // the save was in flight.
            if let latest = articles.firstIndex(where: { $0.id == sourceID }) {
                articles[latest] = article
            }
            pictured += 1
        }
        if pictured > 0 {
            logger.info("Pictured \(pictured) X post(s)")
        }
        return pictured
    }

    /// The handle in an X post URL: `https://x.com/MartinBJensen/status/123` →
    /// `MartinBJensen`. Nil for anything that is not a post URL, including the
    /// `x.com/i/status/...` form, which names no author.
    static func xPostUsername(inURL url: String) -> String? {
        guard let components = URLComponents(string: url),
              let host = components.host?.lowercased(),
              host == "x.com" || host == "twitter.com"
                || host == "www.x.com" || host == "www.twitter.com" else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[1] == "status" else { return nil }
        let username = parts[0]
        guard username != "i", !username.isEmpty,
              username.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return username
    }

    /// X lets an account call itself anything, including nothing at all. A blank
    /// or placeholder name is worse than no author: it hides the post from the
    /// name search it was supposed to enable and leaves an empty attribution on
    /// screen.
    static func normalizedXAuthorName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "unknown" else { return nil }
        return trimmed
    }

    /// Year-only, in the learner's own calendar: the post's date is metadata to
    /// search by, not a timestamp to render.
    static let xPostYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter
    }()
}
