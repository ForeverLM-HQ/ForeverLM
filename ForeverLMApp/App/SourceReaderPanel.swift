import AppKit
import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// Inline source reader panel for the Studio 4-panel layout.
/// Shows the selected source's content (web article, PDF, or text transcript).
/// Includes a pop-out button to open the reader in a separate window.
struct SourceReaderPanel: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.studioTitlebarBandHeight) private var titlebarBandHeight
    @Environment(\.studioCenterPaneHeaderLeadingInset) private var headerLeadingInset
    @Environment(\.studioCenterTabStripVisible) private var centerTabStripVisible
    @Environment(\.studioChromeLineReservation) private var chromeReservation
    @Environment(\.studioPanelTrailingOverflow) private var panelTrailingOverflow
    /// The pane a side reader stands in, whose source a drop replaces.
    @Environment(\.studioPaneGroupID) private var paneGroupID
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.uiZoomScale) private var uiZoomScale
    /// Written here and read by every reader that would otherwise invert a page.
    @PreferenceStorage(Prefs.Readers.originalPageColors) private var originalPageColors
    private let dragVisibility = StudioDragVisibility.shared
    @State private var selectedText = ""
    /// Go to Page, open from the overflow menu or its shortcut.
    @State private var isGoToPagePresented = false
    /// The displayed source's cited sources — a paper's cited papers, an article's linked
    /// sources — open from the overflow menu as a popover off the ⋯ button. Loaded here so
    /// the menu can title its item from the count.
    @State private var isCitedPapersPresented = false
    @State private var citedPapers: [VideoCitedPaper] = []
    @State private var isScanningCitedPapers = false
    /// A book's Contents, open from the overflow menu as a popover off the ⋯ button.
    @State private var isBookContentsPresented = false
    /// Whether the displayed source has a walk, for the overflow menu's Walk
    /// Through item: the menu is built at each press and cannot look it up
    /// itself (`WalkthroughMenuItems.knownHasWalkthrough`).
    @State private var readerHasWalkthrough = false
    @State private var findState = ReaderFindState()
    @State private var isArticleDropTargeted = false
    @ObservedObject private var speech = ArticleSpeechService.shared
    @StateObject private var bookNavigationBridge = ReaderBookNavigationBridge()
    @State private var articleReaderChrome = ArticleReaderChromeState()
    @State private var readerZoomScale = ArticleReaderZoom.defaultScale
    @State private var surfacedBestMatchKey: String?
    @State private var youtubeWatchPageURL: URL?
    @State private var addingLibraryPageKey: String?
    @State private var savedLibraryPageKeys: Set<String> = []
    /// Where the archived-article reader actually is after in-page link clicks,
    /// so browser actions target the visible page rather than the source URL.
    @State private var archivedArticlePageURL: URL?
    /// A confirmation requested by an item of the overflow menu, which is an
    /// `NSHostingMenu` and so has no view of its own to present one from.
    @State private var hostedMenuConfirmation: HostedMenuConfirmation?
    /// A video's and a podcast's own commands, published by their readers for
    /// the overflow menu's Video and Speakers submenus.
    @State private var readerMenuCommands = ReaderMenuCommands()

    /// When set, this reader shows a specific article instead of the sidebar selection.
    var overrideArticleId: String? = nil

    /// When true, this is a secondary reader that should NOT fall back to the primary selection.
    var isSecondaryReader: Bool = false

    private var displayedArticle: StudioArticle? {
        if let id = overrideArticleId {
            return vm.articles.first { $0.id == id }
        }
        if isSecondaryReader { return nil }
        if let external = windowState.externalReaderPage {
            return external.article
        }
        let id = windowState.readerSourceID(fallingBackTo: vm.selectedArticleId)
        return id.flatMap { vm.articlesById[$0] }
    }

    private var trackedId: String? {
        if overrideArticleId == nil,
           !isSecondaryReader,
           let external = windowState.externalReaderPage {
            return external.article.id
        }
        return overrideArticleId ?? windowState.readerSourceID(fallingBackTo: vm.selectedArticleId)
    }

    private var isDisplayingExternalPage: Bool {
        overrideArticleId == nil && !isSecondaryReader && windowState.externalReaderPage != nil
    }

    private func bestMatchTaskKey(for article: StudioArticle) -> String {
        vm.readerBestSearchMatch(for: article.id)?.presentationKey ?? "\(article.id)|none"
    }

    private func bestMatch(for article: StudioArticle) -> SourceSearchBestMatch? {
        vm.readerBestSearchMatch(for: article.id)
    }

    private func readerContentIdentity(for article: StudioArticle) -> String {
        if article.isPDF, let group = article.parentGroup {
            return "pdf-book:\(group)"
        }
        if article.cachedIsEPUBChapter, let group = article.parentGroup {
            return "epub-book:\(group)"
        }
        // One player for a course, the way a book keeps one document: moving
        // between its videos — a click in the Lectures list, or the playlist
        // handing the player on to the next lecture — changes what the player
        // shows without tearing the player down. Remounting would give the
        // next lecture a fresh web view, and a fresh web view cannot inherit a
        // page that is already playing: the video would restart at the top,
        // paused. A source in two courses keys on the first of them, so the
        // pair it is watched between still shares one player.
        if article.isYouTubeURL, let course = vm.courseGroupIDs(for: article).min() {
            return "course-video:\(course)"
        }
        return "\(article.id)|navigation:\(readerReloadRevision(for: article))"
    }

    /// Book readers deliberately keep one mounted surface while chapters
    /// change; their own navigation bridge restores a chapter. A course's
    /// videos share one player for the same reason and never reach this.
    /// Other readers remount on an explicit source-row re-selection.
    private func readerReloadRevision(for article: StudioArticle) -> UInt {
        if article.parentGroup != nil,
           article.isPDF || article.cachedIsEPUBChapter {
            return 0
        }
        return vm.readerNavigationRevision(for: article.id)
    }

    /// Whether the shared speech service is narrating the source this panel shows.
    /// Anything else — audio a pop-out window drives, or a chapter the listener has
    /// since navigated away from — is not this reader's to display or control.
    private func isNarrating(_ article: StudioArticle) -> Bool {
        speech.isNarrating(article.id)
    }

    private func isSameBookChapterSwitch(from oldId: String?, to newId: String?) -> Bool {
        guard let chapters = sameBookChapters(from: oldId, to: newId) else { return false }
        // Cached-only: this runs from .onChange on the main actor, where a cold
        // stat blocks the chapter switch itself. A miss only costs a book
        // navigation bridge reset the switch didn't need.
        return (chapters.old.cachedIsEPUBChapter && chapters.new.cachedIsEPUBChapter)
            || (chapters.old.isPDF && chapters.new.isPDF)
    }

    /// Whether both are chapters of one book the reader assembles into a
    /// single document — a PDF book (`PDFBookReaderView`) or an EPUB book
    /// (`EPUBBookReaderView`): moving between them is a scroll, not a
    /// document change.
    private func isSameAssembledBookChapterSwitch(from oldId: String?, to newId: String?) -> Bool {
        guard let chapters = sameBookChapters(from: oldId, to: newId) else { return false }
        return (chapters.old.isPDF && chapters.new.isPDF)
            || (chapters.old.cachedIsEPUBChapter && chapters.new.cachedIsEPUBChapter)
    }

    private func sameBookChapters(
        from oldId: String?,
        to newId: String?
    ) -> (old: StudioArticle, new: StudioArticle)? {
        guard let oldId, let newId, oldId != newId,
              let oldArticle = vm.articlesById[oldId],
              let newArticle = vm.articlesById[newId],
              let group = oldArticle.parentGroup,
              group == newArticle.parentGroup else {
            return nil
        }
        return (oldArticle, newArticle)
    }

    var body: some View {
        ZStack {
            if let article = displayedArticle {
                VStack(spacing: 0) {
                    // No rule under the header: the top bar reads as part of the
                    // reader surface, not a strip fenced off from it. It still
                    // stays put while the source scrolls beneath it. In full
                    // screen there is no titlebar band, so the toolbar takes a
                    // normal full-height row before the source. Docked in a
                    // window, it hangs from the top overlay below instead of
                    // sitting in-flow — NOT via
                    // .ignoresSafeArea: on macOS 26 a safe-area-ignoring subtree
                    // stops painting its SwiftUI-drawn content in the band (the
                    // title went invisible; same failure as the source tab bar,
                    // see StudioSidebar).
                    if titlebarBandHeight == nil {
                        readerToolbar(for: article)
                            .background(Color(nsColor: .windowBackgroundColor))
                    }
                    // A transcript draws the find inside itself and this
                    // bar then stands down (`ReaderFindState.hasInlineBar`).
                    ReaderFindBar(state: findState)
                    if let bestMatch = bestMatch(for: article) {
                        SourceReaderBestMatchBanner(bestMatch: bestMatch) {
                            jumpToBestMatch(bestMatch)
                        }
                    }
                    HStack(spacing: 0) {
                        ZStack {
                            Group {
                                if isDisplayingExternalPage {
                                    externalPageContent(for: article)
                                } else {
                                    readerContent(for: article)
                                }
                            }
                                .environment(readerMenuCommands)
                                .id(readerContentIdentity(for: article))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .onDrop(of: readableSourceDropTypes, isTargeted: $isArticleDropTargeted, perform: handleArticleDrop)
                                .background {
                                    if supportsReaderZoom(article) {
                                        ReaderShortcutTarget(
                                            find: { findState.show() },
                                            zoomIn: { zoomIn(article) },
                                            zoomOut: { zoomOut(article) },
                                            resetZoom: { resetZoom(article) },
                                            magnify: { magnify(article, by: $0) }
                                        )
                                    }
                                }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // The card hangs off the mark that was clicked rather
                        // than displacing the page: a comment is written while
                        // still looking at the passage.
                        .readerHighlightCard(for: article.id)
                        .readerSideChat(for: article.id)

                        // The source zoomed out, beside it (ReaderLevelsPanel).
                        if showsLevelsPanel(for: article) {
                            Divider()
                            ReaderLevelsPanel(article: article)
                                .transition(.move(edge: .trailing))
                        }

                        // What in the Docs and Ideas links the source
                        // (ReaderReferencesPanel); Levels' column, one at a time.
                        if showsReferencesPanel {
                            Divider()
                            ReaderReferencesPanel(article: article)
                                .transition(.move(edge: .trailing))
                        }

                        // Every figure's legend, following the page
                        // (ReaderFigureLegendsPanel); the same column too.
                        if showsFigureLegendsPanel(for: article) {
                            Divider()
                            ReaderFigureLegendsPanel(article: article)
                                .transition(.move(edge: .trailing))
                        }

                        if vm.readerNotesListVisible {
                            Divider()
                            ReaderNotesList(sourceID: article.id)
                                .transition(.move(edge: .trailing))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(.easeInOut(duration: 0.18), value: vm.readerNotesListVisible)
                    .animation(.easeInOut(duration: 0.18), value: ReaderLevelsPanelState.shared.isVisible)
                    .animation(.easeInOut(duration: 0.18), value: ReaderReferencesPanelState.shared.isVisible)
                    .animation(.easeInOut(duration: 0.18), value: ReaderFigureLegendsPanelState.shared.isVisible)
                    .contextMenu { readerContextMenu(for: article) }
                    .onChange(of: selectedText) { _, newValue in
                        guard !isDisplayingExternalPage else { return }
                        vm.updateActiveReaderSelection(sourceID: article.id, text: newValue)
                    }
                    .onChange(of: findState.searchRevision) { _, _ in
                        selectedText = ""
                    }
                    .onDisappear {
                        vm.clearActiveReaderSelection(forSourceID: article.id)
                    }

                    // The player belongs to the reader showing the narrated
                    // source, at its foot. Leave this source and the window's
                    // own bar takes over (`StudioAudiobookPlayerPlacement`),
                    // so the audio always has a visible pause.
                    if !isDisplayingExternalPage, isNarrating(article) {
                        Divider()
                        StudioAudiobookPlayer(speech: speech, sourceID: article.id, showsOpenSource: false)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: isNarrating(article))
                .studioBandOverlay {
                        // No row-wide drag blocker: mounted behind this row it
                        // took the mouse-down away from the controls on top of
                        // it — Reader's close hovered but never fired — while
                        // failing at its own job, since the band drags the
                        // window either way. Each control owns its own mouse
                        // now; see `TitlebarBandHitSurfaceView`.
                        // The band is also the safe area, and a `.background`
                        // on reader content extends into it by default — the
                        // video players' black backdrops painted over this
                        // whole row, so the Reader had no visible close above
                        // a video. Content that touches the top of the pane
                        // passes `ignoresSafeAreaEdges: []` to its background.
                        // On the band's chrome (`studioBandOverlay`), so a page
                        // scrolled up under the band never shows there.
                        readerToolbar(for: article)
                }
                .onChange(of: trackedId) { oldId, _ in
                    // A book is one document on screen, and reading on into
                    // its next chapter moves the selection without changing
                    // what is in view: the find, the zoom, the selection and
                    // an open note card all still belong to it.
                    let sameDocument = isSameAssembledBookChapterSwitch(from: oldId, to: trackedId)
                    if !sameDocument {
                        if let oldId { vm.clearActiveReaderSelection(forSourceID: oldId) }
                        // A card left open on the previous source would be
                        // editing a mark that is no longer on screen. Whatever
                        // was typed into it is committed on the way out.
                        vm.dismissReaderHighlightCard()
                        selectedText = ""
                        findState.resetForDocumentChange()
                        resetReaderZoom()
                    }
                    if !isSameBookChapterSwitch(from: oldId, to: trackedId) {
                        bookNavigationBridge.clear()
                    }
                    articleReaderChrome.reset()
                    // The live address survives a switch the player made
                    // itself, because nothing navigated: the Reader moved to
                    // the video the page was already showing, and the page
                    // reports its address again only when it changes.
                    if !watchPageShowsTrackedSource() {
                        youtubeWatchPageURL = nil
                    }
                    archivedArticlePageURL = nil
                    surfacedBestMatchKey = nil
                }
                .onChange(of: readerReloadRevision(for: article)) { _, _ in
                    // Re-selecting the source is a navigation action even though
                    // its id did not change. The content identity remounts the
                    // WebView; clear the surrounding chrome at the same time so
                    // no URL, history, selection, or find state from the linked
                    // page survives while the original article loads.
                    vm.clearActiveReaderSelection(forSourceID: article.id)
                    vm.dismissReaderHighlightCard()
                    selectedText = ""
                    findState.resetForDocumentChange()
                    bookNavigationBridge.clear()
                    articleReaderChrome.reset()
                    youtubeWatchPageURL = nil
                    archivedArticlePageURL = nil
                    resetReaderZoom()
                    surfacedBestMatchKey = nil
                }
                .onChange(of: youtubeWatchPageURL) { _, pageURL in
                    followWatchPageToSavedVideo(pageURL, from: article)
                }
                .onChange(of: speech.finishedListeningArticleID) { _, finishedID in
                    guard let finishedID,
                          let finished = vm.articles.first(where: { $0.id == finishedID }),
                          let group = finished.parentGroup,
                          article.id == finishedID || article.parentGroup == group,
                          speech.consumeFinishedListening(articleID: finishedID) else { return }
                    autoAdvanceListening(after: finished)
                }
                .task(id: bestMatchTaskKey(for: article)) {
                    guard let bestMatch = bestMatch(for: article),
                          surfacedBestMatchKey != bestMatch.presentationKey else { return }
                    surfacedBestMatchKey = bestMatch.presentationKey
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled,
                          vm.readerBestSearchMatch(for: article.id)?.presentationKey == bestMatch.presentationKey else { return }
                    jumpToBestMatch(bestMatch, showFindBar: false)
                }
                .task(id: article.id) {
                    guard !isDisplayingExternalPage else { return }
                    ReaderRecentsStore.shared.record(article.id)
                    await vm.loadReaderHighlightsIfNeeded(for: article.id)
                    // Last, because it waits out the engagement dwell: nothing
                    // the reader needs on screen may sit behind it.
                    await vm.beginReaderEngagement(
                        article.id,
                        kind: vm.automaticActivityKind(for: article)
                    )
                }
                .siriSourceAnnotation(article.id)
            } else {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) {
                        // Use the same bounded toolbar row as an open source.
                        // A bare NSViewRepresentable accepts the overlay's full
                        // width and centers its symbol, which left Back floating
                        // in the middle of an idle Reader. The shared row also
                        // reserves the Sources restore control instead of
                        // drawing the Reader close target underneath it.
                        idleReaderToolbar
                            .offset(y: titlebarBandHeight.map { -$0 } ?? 0)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay {
            ReaderDropZoneOverlay(isActive: isArticleDropTargeted)
        }
        .animation(.easeInOut(duration: 0.2), value: dragVisibility.isDragging)
        .onDrop(of: readableSourceDropTypes, isTargeted: $isArticleDropTargeted, perform: handleArticleDrop)
        .onChange(of: dragVisibility.isDragging) { _, isDragging in
            guard !isDragging else { return }
            isArticleDropTargeted = false
        }
        .onChange(of: readerSourceIDOnScreen, initial: true) { previous, current in
            if let previous { windowState.readerSourceIDsOnScreen.remove(previous) }
            if let current { windowState.readerSourceIDsOnScreen.insert(current) }
        }
        .onChange(of: readerPositionOnScreen, initial: true) { previous, current in
            if let previous { windowState.readerPositionsOnScreen.removeValue(forKey: previous.sourceID) }
            if let current { windowState.readerPositionsOnScreen[current.sourceID] = current.label }
        }
        // The live page declared which paper it is; if the library holds that
        // paper, the Reader shows the saved copy instead. Also checked when a
        // page arrives, for a page whose identity an earlier load recorded.
        .onChange(of: vm.pageDeclaredDOIs) { _, _ in
            swapExternalPageForSavedSourceIfNeeded()
        }
        .onChange(of: windowState.externalReaderPage) { _, _ in
            swapExternalPageForSavedSourceIfNeeded()
        }
        .onDisappear {
            if let current = readerSourceIDOnScreen {
                windowState.readerSourceIDsOnScreen.remove(current)
            }
            if let current = readerPositionOnScreen {
                windowState.readerPositionsOnScreen.removeValue(forKey: current.sourceID)
            }
        }
    }

    /// The saved source whose content this reader is showing, for the window's
    /// record of what is on screen. A cited external page shows another site's
    /// content, so it counts as nothing here even though a saved source stands
    /// behind it.
    private var readerSourceIDOnScreen: String? {
        guard !isDisplayingExternalPage else { return nil }
        return displayedArticle?.id
    }

    private struct ReaderPositionOnScreen: Equatable {
        let sourceID: String
        let label: String
    }

    /// Where this Reader stands in the source on screen, in the toolbar's own
    /// numbers, for the window's record the chat's `list_open_panes` reads.
    private var readerPositionOnScreen: ReaderPositionOnScreen? {
        guard let sourceID = readerSourceIDOnScreen else { return nil }
        let label = bookNavigationBridge.pageNavigation.map { "page \($0.label)" }
            ?? bookNavigationBridge.navigation?.positionLabel.map { "chapter \($0)" }
        return label.map { ReaderPositionOnScreen(sourceID: sourceID, label: $0) }
    }

    private var readableSourceDropTypes: [UTType] {
        [.studioArticle]
    }

    private func jumpToBestMatch(_ bestMatch: SourceSearchBestMatch, showFindBar: Bool = true) {
        let query = bestMatch.findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        findState.query = query
        if showFindBar {
            findState.show()
        }
        findState.search()
        guard !showFindBar else { return }
        // With no bar open there is no close to take the match back, and the
        // word would stay boxed in yellow for good. It goes by itself, like a
        // citation's flash, unless the learner has opened the bar or searched
        // again since.
        let state = findState
        let revision = state.searchRevision
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(ReaderPassageFlash.holdDuration))
            guard !state.isVisible, state.searchRevision == revision else { return }
            state.takeBackMatch()
        }
    }

    // MARK: - Toolbar

    private var idleReaderToolbar: some View {
        HStack(spacing: 10) {
            if !isSecondaryReader, overrideArticleId == nil {
                // Keep Reader navigation in the same stable place even when
                // the current source disappeared. That makes the previous
                // source recoverable instead of replacing Back with an
                // unrelated empty state.
                ReaderNavigationButton(
                    systemImage: "chevron.left",
                    help: backHelp,
                    isEnabled: canNavigateToPreviousSource || backReturnsToCoveredPane,
                    action: goBackInReader
                )
                .fixedSize(horizontal: true, vertical: false)
            }

            Spacer(minLength: 0)

            if showsCloseButton {
                readerCloseButton
            }
        }
        // A clipped pane keeps a usable logical content width. Bring the row
        // back to the visible viewport before placing either edge control.
        .padding(.trailing, panelTrailingOverflow)
        .studioPanelHeaderChrome(
            height: titlebarBandHeight ?? StudioPanelChrome.headerHeight,
            extraLeadingPadding: headerLeadingInset,
            containsRow: true
        )
    }

    private func readerToolbar(for article: StudioArticle) -> some View {
        let pageURL = addableLibraryPageURL(for: article)
        let addPageState = pageURL.map(addPageToolbarState(for:))
        let bookNavigation = bookNavigationBridge.navigation
        let pageNavigation = bookNavigationBridge.pageNavigation

        return AdaptiveReaderToolbar {
            SourceReaderStableNavigation(
                showsBrowserNavigation: showsBrowserNavigation(article),
                canGoBack: articleReaderChrome.canGoBack || canNavigateToPreviousSource
                    || backReturnsToCoveredPane,
                canGoForward: articleReaderChrome.canGoForward,
                backHelp: backHelp,
                pageNavigation: pageNavigation,
                isGoToPagePresented: $isGoToPagePresented,
                goToPage: bookNavigationBridge.goToPage(_:),
                goBack: goBackInReader,
                goForward: { articleReaderChrome.goForward() }
            )
        } identity: { density in
            SourceReaderToolbarIdentity(
                density: density,
                title: vm.standaloneTitle(for: article),
                // A book counted in pages says where you are in pages; the
                // chapter count is what an EPUB has to offer instead.
                // A PDF's page lives in the pill at the foot of its pages
                // (`ReaderPagePill`), not under the title: the title stays one
                // line. An EPUB, which has no pages, still says its chapter.
                positionLabel: pageNavigation == nil ? bookNavigation?.positionLabel : nil,
                sourceSystemImage: article.sourceType == .book
                    ? nil
                    : iconForSourceType(article.sourceType),
                draggableSource: isDisplayingExternalPage ? nil : article,
                showsChatDragIcon: windowState.showsChatToDropInto
            )
        } actions: { density in
            SourceReaderToolbarActions(
                speech: speech,
                density: density,
                article: article,
                isSavedSource: !isDisplayingExternalPage,
                showsLoadingIndicator: !isNarrating(article)
                    && articleReaderChrome.isLoading
                    && usesEmbeddedBrowser(article),
                addPageState: addPageState,
                addPage: {
                    if let pageURL { addCurrentPageToLibrary(pageURL) }
                }
            )
        } trailing: {
            HStack(spacing: StudioTopBar.paneControlSpacing) {
                readerFullScreenButton
                readerOverflowMenuWithCitedPapers(for: article)
                if showsCloseButton {
                    readerCloseButton
                }
            }
        }
        // The column layout intentionally keeps a 200pt logical content width
        // while a divider is being dragged narrower, then clips it to the real
        // viewport. Feed that clipped width back into the toolbar proposal so
        // its adaptive policy changes tier before trailing buttons disappear.
        .padding(.trailing, panelTrailingOverflow)
        // In a window the toolbar hangs into the titlebar band and shares the
        // traffic lights' center line. Full screen has no band, so it uses the
        // regular in-flow header height rather than a compact tab-strip
        // height; that keeps source content out from under the controls.
        .studioPanelHeaderChrome(
            height: titlebarBandHeight ?? StudioPanelChrome.headerHeight,
            extraLeadingPadding: headerLeadingInset,
            containsRow: true
        )
        // Every control on this row is a titlebar-band control, not a SwiftUI
        // `Button`: in the band a `Button` neither hovers nor clicks. Shared
        // controls (Listen, Cards to check) read this to pick the right one.
        .environment(\.studioTitlebarBandControls, true)
        .task(id: "\(article.id)#\(vm.readerWalkthroughRevision)#\(isDisplayingExternalPage)") {
            guard !isDisplayingExternalPage, PaperWalkthroughGeneratorService.canPlayWalkthrough(article) else {
                readerHasWalkthrough = false
                return
            }
            let has = await WalkthroughGenerationCoordinator.hasWalkthrough(for: article, storage: vm.storage)
            guard !Task.isCancelled else { return }
            readerHasWalkthrough = has
        }
        // The overflow menu exists only while it is open, so its commands' key
        // equivalents are registered by this always-mounted stand-in.
        .background { readerKeyEquivalents(for: article) }
        .confirmationDialog(
            hostedMenuConfirmation?.title ?? "",
            isPresented: Binding(
                get: { hostedMenuConfirmation != nil },
                set: { if !$0 { hostedMenuConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let confirmation = hostedMenuConfirmation {
                Button(confirmation.confirmTitle, role: confirmation.role) {
                    confirmation.action()
                }
            }
        }
    }

    /// The overflow menu's shortcut-bearing commands, mounted invisibly so
    /// ⌘F and the zoom keys keep working while the menu is closed. A SwiftUI
    /// `Menu` registered these itself; an `NSHostingMenu` is built per press
    /// and holds nothing between presses.
    private func readerKeyEquivalents(for article: StudioArticle) -> some View {
        Group {
            Button("Find in Reader") { findState.show() }
                .keyboardShortcut("f", modifiers: .command)
            // The window's own Reader answers ⇧⌘↩; a second Reader beside it
            // has the button, so one press never means two panes.
            if paneGroupID != nil, !isSecondaryReader {
                Button("Full Screen") { toggleReaderFullScreen() }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
            }
            if supportsReaderZoom(article) {
                Button("Zoom In") { zoomIn(article) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") { zoomOut(article) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { resetZoom(article) }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private var canNavigateToPreviousSource: Bool {
        if isDisplayingExternalPage { return true }
        return windowState.readerBackStack.reversed().contains { sourceID in
            sourceID != trackedId && vm.articlesById[sourceID] != nil
        }
    }

    /// Whether ‹ shows again what this Reader covered when it took its pane —
    /// the Library a row was clicked in, the Space, Pages
    /// (`StudioWindowState.readerCover`) — rather than an earlier source: the
    /// Reader has read nothing since it took the pane, or nothing at all.
    private var backReturnsToCoveredPane: Bool {
        guard !isSecondaryReader, overrideArticleId == nil, !vm.readerPoppedOut,
              windowState.memoryCardSession == nil,
              !articleReaderChrome.canGoBack, !isDisplayingExternalPage,
              windowState.readerCover != nil else { return false }
        return windowState.readerBackReturnsToCover || !canNavigateToPreviousSource
    }

    /// ‹'s tooltip: "Back to Library" when it uncovers the Library.
    private var backHelp: String {
        if backReturnsToCoveredPane, let cover = windowState.readerCover {
            return "Back to \(cover.tab.title)"
        }
        return "Go back"
    }

    /// Reader Back is one continuous history. In-page web navigation is the
    /// most recent step when it exists; otherwise it returns to the source that
    /// previously occupied this pane, regardless of whether that source was an
    /// article, paper, transcript, or book chapter.
    private func goBackInReader() {
        if articleReaderChrome.canGoBack {
            articleReaderChrome.goBack()
            return
        }
        if isDisplayingExternalPage {
            windowState.externalReaderPage = nil
            return
        }
        if backReturnsToCoveredPane, let cover = windowState.readerCover {
            withAnimation(.easeInOut(duration: 0.22)) {
                if !windowState.returnFromReaderCover() {
                    vm.activateCenterTab(cover.tab, in: windowState)
                }
            }
            return
        }
        guard let sourceID = windowState.navigateReaderBack(where: {
            vm.articlesById[$0] != nil
        }) else { return }
        Task { await vm.selectArticle(sourceID, in: windowState) }
    }

    private func addPageToolbarState(for pageURL: URL) -> ReaderAddPageToolbarState {
        let pageKey = libraryPageKey(pageURL)
        return ReaderAddPageToolbarState(
            isAdding: addingLibraryPageKey == pageKey,
            isSaved: savedLibraryPageKeys.contains(pageKey)
                || vm.livePageIsAdded(pageURL, in: windowState)
        )
    }

    /// View in Sources: the page on screen is in the library, so the Reader
    /// shows that source instead — in this window, releasing the live page.
    private func openSavedSource(for pageURL: URL) {
        guard let sourceID = vm.librarySourceID(forURL: pageURL.absoluteString) else {
            vm.showToast("Already in Library")
            return
        }
        Task { await vm.selectArticle(sourceID, in: windowState, revealingReader: true) }
    }

    /// A citation page that has just said which paper it is, when the library
    /// holds that paper: the Reader was asked for the source, not for a
    /// publisher's page about it, so it swaps to the saved copy. A PubMed
    /// address cannot be recognised before the page loads
    /// (`openWebCitationInReader` catches every address that can), which is
    /// why the swap happens here rather than at the click.
    private func swapExternalPageForSavedSourceIfNeeded() {
        guard isDisplayingExternalPage, let external = windowState.externalReaderPage,
              let sourceID = vm.librarySourceID(forURL: external.url.absoluteString) else { return }
        Task {
            await vm.selectArticle(sourceID, in: windowState, revealingReader: true)
            vm.showToast("Opened from Library")
        }
    }

    private func chatAboutSource(_ article: StudioArticle) {
        vm.addSourceToContext(article.id)
        vm.revealChatBesideReader()
    }

    private func toggleReaderNotes() {
        vm.readerNotesListVisible.toggle()
    }

    /// The Levels panel shows beside a saved source the Reader offers it for,
    /// while the learner has it open; a live page reached through a link has
    /// no stored text to zoom out on.
    private func showsLevelsPanel(for article: StudioArticle) -> Bool {
        ReaderLevelsPanelState.shared.isVisible && !isDisplayingExternalPage && ReaderLevels.offers(article)
    }

    /// The Linked References panel shows beside any saved source while the
    /// learner has it open; a live page reached through a link is not one.
    private var showsReferencesPanel: Bool {
        ReaderReferencesPanelState.shared.isVisible && !isDisplayingExternalPage
    }

    /// The Figure Legends panel shows beside a paper the Reader has open as a
    /// PDF; the figure index reads that file.
    private func showsFigureLegendsPanel(for article: StudioArticle) -> Bool {
        ReaderFigureLegendsPanelState.shared.isVisible && !isDisplayingExternalPage
            && ReaderFigureLegends.offers(article)
    }

    /// Everything the Reader can do that its bar does not carry (Quiet chrome,
    /// docs/ui-design.md), at every width. Find and zoom stay
    /// listed for discoverability, but their primary interface is the
    /// keyboard: Cmd+F and Cmd+= / Cmd+- / Cmd+0.
    ///
    /// A `TitlebarBandButton` opening an `NSHostingMenu`, not a SwiftUI `Menu`:
    /// this row hangs in the titlebar band, where a `Menu` label never lit up
    /// under the pointer. The items are still authored in SwiftUI below; the
    /// menu is built fresh on each press so it reflects the current state.
    @ViewBuilder
    private func readerOverflowMenu(for article: StudioArticle) -> some View {
        if #available(macOS 14.4, *) {
            TitlebarBandButton(
                help: "More reader actions",
                accessibilityIdentifier: "studio.reader.overflow",
                controlSize: StudioPanelChrome.readerCloseButtonSize,
                action: {},
                menu: { NSHostingMenu(rootView: readerOverflowMenuItems(for: article)) }
            ) {
                RowMoreActionsLabel()
            }
        } else {
            // `NSHostingMenu` arrived in 14.4. Earlier systems keep the SwiftUI
            // `Menu`, which opens but does not light up in the band.
            Menu {
                readerOverflowMenuItems(for: article)
            } label: {
                RowMoreActionsLabel()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .hoverHighlight()
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More reader actions")
        }
    }

    /// Jumps to a page, for the Contents popover's sections, when the
    /// document is counted in pages.
    private var bookGoToPage: ((Int) -> Void)? {
        guard bookNavigationBridge.pageNavigation != nil else { return nil }
        let bridge = bookNavigationBridge
        return { bridge.goToPage($0) }
    }

    /// The overflow button with the cited-sources panel and a book's Contents hung off it.
    /// The candidates are reloaded whenever the source or the view model's cited-papers
    /// revision changes, so a read started from the sidebar's context menu shows up in the
    /// menu title and the list.
    private func readerOverflowMenuWithCitedPapers(for article: StudioArticle) -> some View {
        let readsCitations = !isDisplayingExternalPage && StudioViewModel.supportsCitedSourceDiscovery(article)
        return readerOverflowMenu(for: article)
            // Its own anchor, the button's frame, so the two popovers never
            // share one modifier's presentation.
            .background {
                Color.clear.bookContentsPopover(
                    isPresented: $isBookContentsPresented,
                    navigation: bookNavigationBridge.navigation,
                    navigate: bookNavigationBridge.navigate(to:),
                    logListened: logBookItemsAsListened,
                    goToPage: bookGoToPage
                )
            }
            .popover(isPresented: $isCitedPapersPresented, arrowEdge: .bottom) {
                CitedSourcesPopover(
                    article: article,
                    papers: $citedPapers,
                    isScanning: $isScanningCitedPapers
                )
            }
            .task(id: "\(article.id)#\(vm.citedPapersRevision)#\(readsCitations)") {
                guard readsCitations else {
                    citedPapers = []
                    isCitedPapersPresented = false
                    return
                }
                citedPapers = await vm.loadCitedPapers(forSourceID: article.id)
            }
    }

    /// The overflow menu's cited-sources item. Before the reference list or the links have
    /// been read the item reads them and opens the panel, where the read's progress and its
    /// results show; once candidates exist it opens the panel, saying how many are waiting,
    /// and the panel's own Read again is the way to read a second time.
    private func openCitedPapers(for article: StudioArticle) {
        isCitedPapersPresented = true
        guard citedPapers.isEmpty else { return }
        Task {
            await CitedSourcesPopover.scan(
                article, vm: vm, papers: $citedPapers, isScanning: $isScanningCitedPapers
            )
        }
    }

    /// The ⋯'s items, grouped (Quiet chrome, docs/ui-design.md:
    /// some thirty commands are not one flat list). The most used stay at the
    /// top level, then what this kind of source has of its own; Make ▸, View ▸
    /// and Open & Share ▸ hold the rest; filing, read state and the rare end
    /// it. Every command keeps its name, and the shortcuts are answered by
    /// `readerKeyEquivalents`, wherever the item sits.
    private func readerOverflowMenuItems(for article: StudioArticle) -> some View {
        let isSavedSource = !isDisplayingExternalPage
        return Group {
            // What the bar carried until Quiet chrome, first and together.
            // Each comes back to the bar only while it is under way: Listen
            // preparing or playing, a walk or cards being written, cards
            // waiting to be checked.
            if isSavedSource {
                ArticleSpeechListenMenuItem(speech: speech, article: article)
                RealtimeVoiceMenuItems(article: article, notebookID: windowState.notebook?.notebookID)
                WalkthroughMenuItems(article: article, knownHasWalkthrough: readerHasWalkthrough)
                CardsMenuItems(article: article, windowState: windowState)
                ReaderLevelsMenuItem(article: article)
            }

            if bookNavigationBridge.navigation != nil {
                Button {
                    isBookContentsPresented = true
                } label: {
                    Label("Contents…", systemImage: "list.bullet")
                }
            }

            if isSavedSource, bookNavigationBridge.pageNavigation != nil {
                Button {
                    isGoToPagePresented = true
                } label: {
                    Label("Go to Page…", systemImage: "number")
                }
                // Listed here for the hint; the toolbar's hidden button is
                // what answers the keys.
                .keyboardShortcut(ReaderGoToPage.shortcutKey, modifiers: ReaderGoToPage.shortcutModifiers)
            }

            if isSavedSource, bookNavigationBridge.canTurnPage {
                ReaderRotatePageMenuItems(bridge: bookNavigationBridge)
            }

            Button {
                findState.show()
            } label: {
                Label("Find in Reader", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: .command)

            if paneGroupID != nil {
                let isFullScreen = paneIsFullScreen
                Button {
                    toggleReaderFullScreen()
                } label: {
                    Label(
                        isFullScreen ? "Exit Full Screen" : "Full Screen",
                        systemImage: isFullScreen
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right"
                    )
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            }

            if let pageURL = addableLibraryPageURL(for: article) {
                let state = addPageToolbarState(for: pageURL)
                Button {
                    addCurrentPageToLibrary(pageURL)
                } label: {
                    Label(state.title, systemImage: state.systemImage)
                }
                .disabled(!state.isEnabled)
            }

            Divider()

            // What this kind of source has of its own: a video's commands, a
            // podcast's speakers, the papers or links a source cites, and the
            // Pages and sites that link it.
            if isSavedSource && article.isYouTubeURL {
                ReaderVideoMenu(
                    chatAboutVideo: { chatAboutSource(article) },
                    commands: readerMenuCommands.video(for: article.id)
                )
            }

            if isSavedSource, let speakers = readerMenuCommands.speakers(for: article.id) {
                ReaderSpeakersMenu(commands: speakers)
            }

            if isSavedSource && StudioViewModel.supportsCitedSourceDiscovery(article) {
                Button {
                    openCitedPapers(for: article)
                } label: {
                    Label(
                        CitedSourcesPopover.menuTitle(for: article, papers: citedPapers),
                        systemImage: StudioViewModel.supportsLinkDiscovery(article) ? "link" : "text.quote"
                    )
                }
                .help(CitedSourcesPopover.menuHelp(for: article, papers: citedPapers))
            }

            if isSavedSource {
                LinkedInMenuItems(article: article, windowState: windowState)
            }

            if isSavedSource && article.sourceType == .paper {
                PaperVersionsMenuItems(article: article, windowState: windowState)
            }

            if isSavedSource && offersMakeMenu(for: article) {
                Menu {
                    ExplainerMenuItems(article: article, windowState: windowState)
                    MnemonicReadingMenuItems(article: article, windowState: windowState)
                    if offersClip(for: article) {
                        ReaderClipMenuItem(article: article, isOn: vm.readerClipToolIsOn)
                    }
                } label: {
                    Label("Make", systemImage: "wand.and.stars")
                }
            }

            Menu {
                readerViewMenuItems(for: article)
            } label: {
                Label("View", systemImage: "eye")
            }

            if hasBrowserURL(article) || isSavedSource {
                Menu {
                    readerOpenAndShareMenuItems(for: article)
                } label: {
                    Label("Open & Share", systemImage: "square.and.arrow.up")
                }
            }

            if isSavedSource {
                Divider()
                ReaderNotebookMembershipButton(article: article, windowState: windowState)
                KnowledgeMapAddToCanvasMenu(refs: ["source:\(article.id)"])
                SourceNotebooksMenuSection(rowID: vm.canonicalSourceID(article.id), windowState: windowState)
                KnowledgeMapOnCanvasesSection(ref: "source:\(article.id)", windowState: windowState)
            }

            if isSavedSource && article.cachedSupportsReadTracking {
                if article.isRead {
                    Button {
                        Task { await vm.setArticleRead(article.id, read: false) }
                    } label: {
                        Label("Mark as Unread", systemImage: "circle")
                    }
                } else {
                    Button {
                        Task { await vm.setArticleRead(article.id, read: true) }
                    } label: {
                        Label("Mark as Read", systemImage: "checkmark.circle")
                    }
                }
            }

            if isSavedSource {
                VideoWatchedMenuItems(article: article)
            }

            if isSavedSource && article.sourceType == .book {
                Button {
                    logSourcesAsListened([article])
                } label: {
                    Label("Log Chapter as Listened", systemImage: "headphones")
                }
            }

            // A paper without a PDF whose publisher page is on screen: either
            // the source has no PDF link of its own, or the publisher refused
            // the PDF and the reader fell back to the page. Both show the page
            // through the reader that installs these actions.
            if isSavedSource,
               article.sourceType == .paper && article.localFilePath == nil
                && (usesEmbeddedBrowser(article) || vm.readerAbandonedRemotePDF(article.id)) {
                Button {
                    articleReaderChrome.downloadPDF?()
                } label: {
                    Label("Download PDF", systemImage: "arrow.down.doc")
                }
                Button {
                    articleReaderChrome.savePaperFromPage?()
                } label: {
                    Label("Save Paper from Page", systemImage: "doc.text.viewfinder")
                }
                .help("Save this page as the paper's text and print it to a PDF")
            }

            // An article the app could not read, whose page the reader shows:
            // the PDF the page hands over becomes the article's document.
            if isSavedSource, usesEmbeddedBrowser(article),
               WebPagePolicy.awaitsDocumentPDF(
                   sourceType: article.sourceType,
                   isUnreadable: article.hasPaywallMarker || article.state == .error
               ) {
                Button {
                    articleReaderChrome.downloadPDF?()
                } label: {
                    Label("Download PDF", systemImage: "arrow.down.doc")
                }
                .help("Download the article's PDF from this page and attach it")
            }

            if isSavedSource, article.sourceType == .article {
                Divider()
                ArticleReadingViewMenuItems(article: article)
            }

            if isSavedSource && isNarrating(article) {
                Divider()

                Button {
                    speech.stop()
                } label: {
                    Label("Stop Listening", systemImage: "stop.fill")
                }

                Button {
                    TextToSpeechSettingsNavigation.open()
                } label: {
                    Label("Text to Speech Settings", systemImage: "gearshape")
                }

                ArticleSpeechListeningOverflowItems(speech: speech, sourceID: article.id)
            } else if isSavedSource {
                ArticleSpeechCacheDeleteMenuItem(sourceID: article.id, speech: speech)
            }
        }
        // The hosting menu is its own SwiftUI root: nothing from the panel's
        // environment reaches it unless handed over here.
        .environment(vm)
        .environment(windowState)
        .environment(\.hostedMenuConfirmation) { confirmation in
            hostedMenuConfirmation = confirmation
        }
    }

    /// The ⋯'s View ▸: the panels beside the source, the page's own history,
    /// and how the page is drawn.
    @ViewBuilder
    private func readerViewMenuItems(for article: StudioArticle) -> some View {
        let showsPanels = !isDisplayingExternalPage
        let showsHistory = showsBrowserNavigation(article)
        let showsZoom = supportsReaderZoom(article)
        let showsPageColors = showsOriginalPageColorsToggle(for: article)

        if showsPanels {
            Button {
                toggleReaderNotes()
            } label: {
                Label(
                    vm.readerNotesListVisible ? "Hide Highlights" : "Show Highlights",
                    systemImage: "highlighter"
                )
            }
            // The passages that link the source, in a panel beside it.
            ReaderReferencesMenuItem()
            // A paper's legends beside its pages, wherever they are printed.
            if ReaderFigureLegends.offers(article) {
                ReaderFigureLegendsMenuItem()
            }
        }

        if showsHistory {
            if showsPanels {
                Divider()
            }

            Button {
                articleReaderChrome.goBack()
            } label: {
                Label("Go Back", systemImage: "chevron.left")
            }
            .disabled(!articleReaderChrome.canGoBack)

            Button {
                articleReaderChrome.goForward()
            } label: {
                Label("Go Forward", systemImage: "chevron.right")
            }
            .disabled(!articleReaderChrome.canGoForward)
        }

        if (showsZoom || showsPageColors) && (showsPanels || showsHistory) {
            Divider()
        }

        if showsZoom {
            Button("Zoom In") { zoomIn(article) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Zoom Out") { zoomOut(article) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { resetZoom(article) }
                .keyboardShortcut("0", modifiers: .command)
        }

        if showsPageColors {
            Toggle(isOn: $originalPageColors) {
                Label("Original Page Colors", systemImage: "circle.lefthalf.filled")
            }
            .help("Show this page as it was published instead of darkening it")
        }
    }

    /// The ⋯'s Open & Share ▸: the source elsewhere — Safari, its link,
    /// another window, Finder.
    @ViewBuilder
    private func readerOpenAndShareMenuItems(for article: StudioArticle) -> some View {
        if hasBrowserURL(article) {
            Button {
                openInSafari(article)
            } label: {
                Label(openInSafariMenuLabel(for: article), systemImage: "safari")
            }

            Button {
                copyBrowserURL(article)
            } label: {
                Label(copyBrowserURLMenuLabel(for: article), systemImage: "link")
            }
        }

        if !isDisplayingExternalPage {
            OpenSourceInOtherWindowMenu(
                article: article,
                currentWindowState: windowState,
                openNewWindow: { openWindow(id: "studio") }
            )
            RevealSourceInFinderButton(article: article)
        }
    }

    /// Whether Make ▸ has anything in it for this source: an explainer, a
    /// mnemonic reading or the Clip tool.
    private func offersMakeMenu(for article: StudioArticle) -> Bool {
        GeneratedExplainer.canExplain(article)
            || MnemonicReadingMenuItems.canRead(article)
            || offersClip(for: article)
    }

    private func offersClip(for article: StudioArticle) -> Bool {
        !isDisplayingExternalPage && WalkthroughAnchorResolver.readerShowsPDF(article) && BetaFeatures.showsCanvas
    }

    private func zoomIn(_ article: StudioArticle) {
        if usesEmbeddedBrowser(article) {
            articleReaderChrome.zoomIn?()
        } else {
            setReaderZoomScale(readerZoomScale + ArticleReaderZoom.step)
        }
    }

    private func zoomOut(_ article: StudioArticle) {
        if usesEmbeddedBrowser(article) {
            articleReaderChrome.zoomOut?()
        } else {
            setReaderZoomScale(readerZoomScale - ArticleReaderZoom.step)
        }
    }

    private func resetZoom(_ article: StudioArticle) {
        if usesEmbeddedBrowser(article) {
            articleReaderChrome.resetZoom?()
        } else {
            resetReaderZoom()
        }
    }

    private func magnify(_ article: StudioArticle, by amount: CGFloat) {
        if usesEmbeddedBrowser(article) {
            articleReaderChrome.setZoom?(articleReaderChrome.zoomScale + amount)
        } else {
            setReaderZoomScale(readerZoomScale + amount)
        }
    }

    private func setReaderZoomScale(_ scale: CGFloat) {
        let clamped = ArticleReaderZoom.clamped(scale)
        guard ArticleReaderZoom.differs(readerZoomScale, clamped) else { return }
        readerZoomScale = clamped
    }

    private func resetReaderZoom() {
        setReaderZoomScale(ArticleReaderZoom.defaultScale)
    }

    private func supportsReaderZoom(_ article: StudioArticle) -> Bool {
        usesEmbeddedBrowser(article)
            || article.cachedHasRemotePDFURL
            || article.isPDF
            || article.cachedIsEPUBChapter
            || article.isYouTubeURL
            || article.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    @ViewBuilder
    private func readerContextMenu(for article: StudioArticle) -> some View {
        if !isDisplayingExternalPage && hasSelectedReaderText {
            Button {
                explainSelectedText(for: article)
            } label: {
                Label("Chat About Selection", systemImage: "text.bubble")
            }
        }

        if !isDisplayingExternalPage && ArticleSpeechContent.canAttemptRead(article) {
            Button {
                startTextToSpeech(article)
            } label: {
                Label("Text to Speech", systemImage: "speaker.wave.2")
            }
        }

        if URL(string: article.url) != nil {
            Button {
                copyBrowserURL(article)
            } label: {
                Label(copyBrowserURLMenuLabel(for: article), systemImage: "link")
            }

            Button {
                openInSafari(article)
            } label: {
                Label(openInSafariMenuLabel(for: article), systemImage: "safari")
            }
        }

        if !isDisplayingExternalPage && article.sourceType == .paper && !article.isPaywalled {
            Button {
                Task { await vm.markPaywalled(article) }
            } label: {
                Label("Mark Paper as Paywalled", systemImage: "lock.doc")
            }
        }

        if !isDisplayingExternalPage && article.cachedSupportsReadTracking {
            Divider()
            if article.isRead {
                Button {
                    Task { await vm.setArticleRead(article.id, read: false) }
                } label: {
                    Label("Mark as Unread", systemImage: "circle")
                }
            } else {
                Button {
                    Task { await vm.setArticleRead(article.id, read: true) }
                } label: {
                    Label("Mark as Read", systemImage: "checkmark.circle")
                }
            }
        }

        if !isDisplayingExternalPage {
            VideoWatchedMenuItems(article: article)
        }
    }

    private func handleArticleDrop(_ providers: [NSItemProvider]) -> Bool {
        StudioDragVisibility.shared.endSoon()
        isArticleDropTargeted = false
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.studioArticle.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.studioArticle.identifier) { data, _ in
                    guard let data,
                          let transfer = try? JSONDecoder().decode(StudioArticleTransfer.self, from: data) else { return }
                    Task { @MainActor in
                        await openDroppedArticle(transfer.articleId)
                    }
                }
                handled = true
            }
        }
        return handled
    }

    @MainActor
    private func openDroppedArticle(_ articleID: String) async {
        if isSecondaryReader {
            // A side reader shows what is dropped on it, in its own pane.
            if let paneGroupID {
                windowState.sideReaderSources[paneGroupID] = articleID
            } else {
                vm.secondaryReaderArticleId = articleID
            }
        } else {
            await vm.selectArticle(articleID, in: windowState)
        }
    }

    /// Whether the watch page's live address is the source the Reader has just
    /// moved to — the state a follow leaves behind.
    private func watchPageShowsTrackedSource() -> Bool {
        guard let live = youtubeWatchPageURL,
              let trackedId,
              let tracked = vm.articlesById[trackedId] else { return false }
        return YouTubeWatchPageIdentity.namesSameVideo(live.absoluteString, tracked.url)
    }

    /// A video hands the player on to the next one by itself: YouTube's
    /// autoplay, or the next entry of the playlist a course was imported from.
    /// The Reader stayed bound to the source it opened, so its title, its
    /// transcript, its notes and its watch progress all went on describing the
    /// lecture that finished while a different one played. When the library
    /// holds the video now on screen, this Reader becomes that source — and,
    /// inside a course, without disturbing the player: the two lectures share
    /// one mounted player (`readerContentIdentity`), which adopts the page it
    /// is already showing rather than loading it again.
    ///
    /// Only a saved source is followed. A video the library does not hold
    /// leaves the Reader where it is, with Add to Sources over the page, the
    /// way any other address reached inside a reader is treated.
    private func followWatchPageToSavedVideo(_ pageURL: URL?, from article: StudioArticle) {
        guard overrideArticleId == nil, !isSecondaryReader, !isDisplayingExternalPage,
              article.isYouTubeURL,
              let movedTo = YouTubeWatchPageIdentity.videoNavigatedAwayFrom(
                  sourceURL: article.url,
                  livePageURL: pageURL
              ),
              let sourceID = vm.librarySourceID(forURL: movedTo.absoluteString),
              sourceID != article.id,
              // A lecture the course's gate holds back is not followed: the
              // player goes back and says which quiz opens it
              // (`YouTubeReaderView.holdLockedLectureHandoff`).
              vm.courseLock(forSourceID: sourceID, alongside: article.id) == nil else { return }
        // Not `revealingReader`: the player is already on screen, and the
        // learner did not ask for anything — a video ended. Following it must
        // not bring the Reader to the front of a pane they moved off.
        Task { await vm.selectArticle(sourceID, in: windowState) }
    }

    private func startTextToSpeech(_ article: StudioArticle) {
        speech.listen(to: article)
    }

    /// A visible book reader follows its Contents order. The persistent player
    /// handles this event only when no reader is mounted to consume it.
    private func autoAdvanceListening(after finished: StudioArticle) {
        guard let next = advanceReaderToChapter(after: finished) else { return }
        speech.startTextToSpeech(article: next)
    }

    private func advanceReaderToChapter(after finished: StudioArticle) -> StudioArticle? {
        if let nextItem = bookNavigationBridge.navigation?.nextItem,
           let next = readerChapterSource(for: nextItem) {
            bookNavigationBridge.navigate(to: nextItem)
            return next
        }
        guard let group = finished.parentGroup else { return nil }
        let chapters = vm.bookChapterArticlesInOrder(for: group)
        guard let index = chapters.firstIndex(where: { $0.id == finished.id }),
              index + 1 < chapters.count else { return nil }
        let next = chapters[index + 1]
        Task { await vm.selectReaderSource(next.id) }
        return next
    }

    private func readerChapterSource(for item: BookNavigationItem) -> StudioArticle? {
        vm.articles.first { $0.id == item.id } ?? vm.sourceMatchingLocalPath(item.path)
    }

    private func logBookItemsAsListened(_ items: [BookNavigationItem]) {
        let sources = items.compactMap(readerChapterSource(for:))
        guard sources.count == items.count else {
            vm.errorMessage = "Could not match every selected chapter to this book."
            return
        }
        logSourcesAsListened(sources)
    }

    private func logSourcesAsListened(_ sources: [StudioArticle]) {
        let sourceIDs = sources.map(\.id)
        guard !sourceIDs.isEmpty else { return }
        Task {
            await vm.recordExternalSourceCompletions(
                sourceIDs: sourceIDs,
                kind: .listening
            )
        }
    }

    private func openInSafari(_ article: StudioArticle) {
        guard let url = currentBrowserURL(for: article) else { return }
        BrowserService.open(url, discoveryOrigin: article.discoveryOrigin, preference: .safari)
    }

    private func copyBrowserURL(_ article: StudioArticle) {
        guard let url = currentBrowserURL(for: article) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        vm.showToast(article.isYouTubeURL ? "Copied current video link" : "Copied source link")
    }

    /// A linked page becomes saveable only after the reader has left the source
    /// it was opened with. Keeping this out of the overflow menu makes the action
    /// appear exactly when it becomes relevant, beside the browser controls.
    private func addableLibraryPageURL(for article: StudioArticle) -> URL? {
        guard let currentURL = currentBrowserURL(for: article),
              currentURL.hasWebScheme else {
            return nil
        }
        if isDisplayingExternalPage { return currentURL }
        guard libraryPageKey(currentURL) != SourceDiscovery.normalizedURL(article.url) else { return nil }
        return currentURL
    }

    private func libraryPageKey(_ url: URL) -> String {
        SourceDiscovery.normalizedURL(url.absoluteString)
    }

    private func addCurrentPageToLibrary(_ url: URL) {
        let pageKey = libraryPageKey(url)
        let state = addPageToolbarState(for: url)
        if state.opensSavedSource {
            openSavedSource(for: url)
            return
        }
        vm.showToast(state.activationMessage)
        guard state == .available else { return }

        addingLibraryPageKey = pageKey
        Task {
            // Let SwiftUI publish the Adding state and its toast before the
            // main-actor import workflow begins doing duplicate detection.
            await Task.yield()
            defer {
                if addingLibraryPageKey == pageKey {
                    addingLibraryPageKey = nil
                }
            }

            // Into the library, and into this window's notebook when it is
            // in one; the toast says where it went.
            if await vm.addLivePageToSources(url, in: windowState).landed {
                savedLibraryPageKeys.insert(pageKey)
            }
        }
    }

    /// Gates the context menu's "Chat About Selection" item. The selection chat
    /// action now lives on the in-page callout, but the context menu keeps its
    /// own entry for keyboard and right-click users.
    private var hasSelectedReaderText: Bool {
        !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func explainSelectedText(for article: StudioArticle) {
        vm.requestReaderSelectionExplanation(sourceID: article.id, selectedText: selectedText)
    }

    private func currentBrowserURL(for article: StudioArticle) -> URL? {
        ReaderBrowserURL.current(
            for: article,
            youtubeWatchPageURL: youtubeWatchPageURL,
            embeddedBrowser: usesEmbeddedBrowser(article) ? articleReaderChrome : nil,
            archivedArticlePageURL: archivedArticlePageURL
        )
    }

    private func openInSafariMenuLabel(for article: StudioArticle) -> String {
        article.sourceType == .podcast ? "Open Podcast" : "Open in Safari"
    }

    private func copyBrowserURLMenuLabel(for article: StudioArticle) -> String {
        article.isYouTubeURL ? "Copy Current Video Link" : "Copy Link"
    }

    // MARK: - Content

    /// Research citations are intentionally not `StudioViewModel.articles` yet.
    /// Render the live page without read progress, notes, highlights, schedule
    /// activity, or any other write keyed by a source id; only Add to Sources
    /// may turn this presentation-only article into a durable source.
    @ViewBuilder
    private func externalPageContent(for article: StudioArticle) -> some View {
        if case .video(let watchURL) = YouTubeContainment.decision(for: article.url) {
            // A YouTube video no source holds plays alone, never as the watch
            // page with YouTube's recommendations around it.
            ExternalYouTubeVideoView(watchURL: watchURL, zoomScale: readerZoomScale)
        } else {
            ArticleReaderView(
                article: article,
                reviewMode: true,
                showsSpeechControls: false,
                showsBrowserToolbar: false,
                findState: findState,
                chromeState: articleReaderChrome,
                speech: speech,
                selectionChanged: { selectedText = $0 }
            )
        }
    }

    @ViewBuilder
    private func readerContent(for article: StudioArticle) -> some View {
        if article.statusFlag == .confirmPodcast, let match = vm.heldPodcastMatch(for: article.id)?.info {
            PodcastMatchConfirmationView(article: article, match: match)
        } else if article.readerWaitsForFetch {
            fetchingSourceView(for: article)
        } else if article.fetchesPodcastTranscriptOnOpen {
            fetchingSourceView(for: article)
                .task(id: article.id) {
                    await fetchPodcastTranscriptOnOpenIfNeeded(article)
                }
        } else if article.offersPodcastTranscriptSearch {
            podcastTranscriptPrompt(for: article)
        } else if GeneratedExplainerVideo.isVideoURL(article.url) {
            ExplainerVideoReaderView(article: article)
        } else if article.isYouTubeURL {
            // YouTube videos: embed player on top, transcript below (if available)
            YouTubeVideoReaderView(
                article: article,
                selectedText: $selectedText,
                currentWatchPageURL: $youtubeWatchPageURL,
                findState: findState,
                navigationTarget: bestMatch(for: article),
                zoomScale: readerZoomScale,
                readerTheme: .system,
                zoomInAction: { setReaderZoomScale(readerZoomScale + ArticleReaderZoom.step) },
                zoomOutAction: { setReaderZoomScale(readerZoomScale - ArticleReaderZoom.step) },
                resetZoomAction: resetReaderZoom
            )
        } else if article.cachedIsArchivedArticle,
                  !article.cachedPrefersLiveWebPage,
                  let path = article.cachedResolvedLocalPath {
            ArchivedArticleReaderView(
                articleID: article.id,
                canonicalFilePath: path,
                fallbackText: article.content,
                liveWebArticle: article,
                allowsLiveWebFallback: article.cachedIsWebArticle
                    && !article.cachedHasRemotePDFURL
                    && !article.isPaywalled,
                initialScrollFraction: ArticleReadingPositionLocator(
                    encoded: vm.readingPositionLocator(for: article.id) ?? article.readingPositionLocator
                )?.webScrollFraction,
                selectedText: $selectedText,
                findState: findState,
                findRevision: findState.searchRevision,
                navigationTarget: bestMatch(for: article),
                zoomScale: readerZoomScale,
                readerTheme: .system,
                scrollPositionChanged: { fraction in
                    guard let encoded = ArticleReadingPositionLocator(scrollFraction: fraction).encoded else { return }
                    vm.updateReadingLocator(for: article.id, locator: encoded)
                },
                readingCompletionReached: {
                    Task { await vm.markArticleReadAfterReachingEnd(article.id) }
                },
                pageURLChanged: { archivedArticlePageURL = $0 },
                chromeState: articleReaderChrome,
                zoomInAction: { setReaderZoomScale(readerZoomScale + ArticleReaderZoom.step) },
                zoomOutAction: { setReaderZoomScale(readerZoomScale - ArticleReaderZoom.step) },
                resetZoomAction: resetReaderZoom
            )
        } else if article.cachedIsWebArticle
                    && !article.cachedHasRemotePDFURL
                    && (article.localFilePath == nil || article.cachedPrefersLiveWebPage) {
            // A paywalled paper's stored text is an extraction — markdown in a
            // plain text view, with the publisher's own structure flattened. The
            // page is the better reading of it, and it is also where signing in
            // happens, so it renders here too; the text stays the fallback below.
            ArticleReaderView(
                article: article,
                reviewMode: true,
                showsSpeechControls: false,
                showsBrowserToolbar: false,
                findState: findState,
                chromeState: articleReaderChrome,
                speech: speech,
                // An archived source reaching the live reader still owns durable
                // text. If the page has since died and its archive file is not
                // on this Mac, show that text rather than a load error. A
                // paywalled source holds text for the same reason.
                usesPersistedTextOnLoadFailure: article.cachedIsArchivedArticle
                    || hasAttachedPaywallText(article),
                selectionChanged: { selectedText = $0 }
            )
        } else if article.readsStoredTextOverRemotePDF {
            // Text handed in with a PDF URL is the source, often one part of
            // the file (see `readsStoredTextOverRemotePDF`). Never fall through
            // to the PDF while that text is still being loaded.
            if let content = article.content {
                TranscriptReaderView(
                    article: article,
                    content: content,
                    selectedText: $selectedText,
                    findState: findState,
                    zoomScale: readerZoomScale,
                    navigationTarget: bestMatch(for: article),
                    readerTheme: .system,
                    zoomInAction: { setReaderZoomScale(readerZoomScale + ArticleReaderZoom.step) },
                    zoomOutAction: { setReaderZoomScale(readerZoomScale - ArticleReaderZoom.step) },
                    resetZoomAction: resetReaderZoom
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task(id: article.id) { await vm.hydrateStoredContent(for: article.id) }
            }
        } else if article.cachedHasRemotePDFURL, vm.readerAbandonedRemotePDF(article.id) {
            // The publisher refused the PDF. Text ForeverLM already holds beats
            // a page that may only show the abstract; with no text, the page is
            // the paper for a subscriber, and the reader's own session is where
            // a sign-in for it lives. Text still being cleaned up is not shown:
            // until the paper is ready, its content is the raw page dump, and
            // the page itself reads better while Save Paper from Page finishes.
            if article.state == .ready,
               StudioViewModel.sourceHoldsReadableText(article),
               let content = article.content {
                TranscriptReaderView(
                    article: article,
                    content: content,
                    selectedText: $selectedText,
                    findState: findState,
                    zoomScale: readerZoomScale,
                    navigationTarget: bestMatch(for: article),
                    readerTheme: .system,
                    zoomInAction: { setReaderZoomScale(readerZoomScale + ArticleReaderZoom.step) },
                    zoomOutAction: { setReaderZoomScale(readerZoomScale - ArticleReaderZoom.step) },
                    resetZoomAction: resetReaderZoom
                )
            } else {
                ArticleReaderView(
                    article: article,
                    reviewMode: true,
                    showsSpeechControls: false,
                    showsBrowserToolbar: false,
                    findState: findState,
                    chromeState: articleReaderChrome,
                    speech: speech,
                    selectionChanged: { selectedText = $0 }
                )
            }
        } else if article.cachedHasRemotePDFURL, let pdfURL = article.remotePDFURL {
            RemotePDFReaderView(
                articleId: article.id,
                url: pdfURL,
                landingPageURL: URL(string: article.url).flatMap { $0 == pdfURL ? nil : $0 },
                initialPageIndex: article.readingPositionPage,
                selectedText: $selectedText,
                findState: findState,
                findRevision: findState.searchRevision,
                zoomScale: readerZoomScale,
                pageChanged: { page, pageCount in vm.updateReadingPosition(for: article.id, page: page, pageCount: pageCount) },
                zoomScaleChanged: setReaderZoomScale,
                zoomInAction: { setReaderZoomScale(readerZoomScale + ArticleReaderZoom.step) },
                zoomOutAction: { setReaderZoomScale(readerZoomScale - ArticleReaderZoom.step) },
                resetZoomAction: resetReaderZoom
            )
        } else if article.isPDF, article.cachedResolvedPDFPath != nil {
            PDFBookReaderView(
                initialArticle: article,
                chapterArticles: article.parentGroup.map { vm.bookChaptersWithReadingProgress(for: $0) } ?? [article],
                selectedText: $selectedText,
                findState: findState,
                findRevision: findState.searchRevision,
                zoomScale: readerZoomScale,
                bookNavigationBridge: bookNavigationBridge,
                chapterChanged: { chapter in
                    Task { await vm.selectReaderSource(chapter.id) }
                },
                pageChanged: { chapter, page, pageCount in vm.updateReadingPosition(for: chapter.id, page: page, pageCount: pageCount) },
                zoomScaleChanged: setReaderZoomScale,
                zoomInAction: { setReaderZoomScale(readerZoomScale + ArticleReaderZoom.step) },
                zoomOutAction: { setReaderZoomScale(readerZoomScale - ArticleReaderZoom.step) },
                resetZoomAction: resetReaderZoom
            )
        } else if article.cachedIsEPUBChapter, let path = article.cachedResolvedLocalPath {
            let lower = path.lowercased()
            if lower.hasSuffix(".htm") || lower.hasSuffix(".html") || lower.hasSuffix(".xhtml") {
                BookChapterFileGate(
                    path: path,
                    sourceID: article.id,
                    inMemoryText: article.content
                ) {
                    // A book's chapters read as one document: the whole book
                    // scrolls, and reading on moves the selection with it. A
                    // chapter that lost its book reads as a book of one.
                    EPUBBookReaderView(
                        initialArticle: article,
                        chapterArticles: article.parentGroup.map { vm.bookChaptersWithReadingProgress(for: $0) } ?? [],
                        selectedText: $selectedText,
                        findState: findState,
                        findRevision: findState.searchRevision,
                        zoomScale: readerZoomScale,
                        readerTheme: .system,
                        bookNavigationBridge: bookNavigationBridge,
                        chapterChanged: { chapter in
                            Task { await vm.selectReaderSource(chapter.id) }
                        },
                        zoomInAction: { setReaderZoomScale(readerZoomScale + ArticleReaderZoom.step) },
                        zoomOutAction: { setReaderZoomScale(readerZoomScale - ArticleReaderZoom.step) },
                        resetZoomAction: resetReaderZoom
                    )
                } textReader: { content in
                    InlineTextReaderView(
                        content: content,
                        sourceID: article.id,
                        selectedText: $selectedText,
                        findState: findState,
                        findRevision: findState.searchRevision,
                        navigationTarget: bestMatch(for: article),
                        zoomScale: readerZoomScale,
                        readerTheme: .system,
                        zoomInAction: { setReaderZoomScale(readerZoomScale + ArticleReaderZoom.step) },
                        zoomOutAction: { setReaderZoomScale(readerZoomScale - ArticleReaderZoom.step) },
                        resetZoomAction: resetReaderZoom
                    )
                }
            } else {
                LocalTextFileContentView(path: path) { content in
                    InlineTextReaderView(
                        content: content,
                        sourceID: article.id,
                        selectedText: $selectedText,
                        findState: findState,
                        findRevision: findState.searchRevision,
                        navigationTarget: bestMatch(for: article),
                        zoomScale: readerZoomScale,
                        readerTheme: .system,
                        zoomInAction: { setReaderZoomScale(readerZoomScale + ArticleReaderZoom.step) },
                        zoomOutAction: { setReaderZoomScale(readerZoomScale - ArticleReaderZoom.step) },
                        resetZoomAction: resetReaderZoom
                    )
                }
            }
        } else if article.sourceType == .meeting,
                  let media = MeetingRecordingMedia.resolve(from: vm.meetingArtifactsBySourceId[article.id] ?? []) {
            // Meeting sessions with a playable video recording: video on top,
            // transcript below — the YouTube reader layout. An audio-only
            // recording resolves to no media and falls through to the
            // transcript reader.
            MeetingRecordingReaderView(
                article: article,
                media: media,
                selectedText: $selectedText,
                findState: findState,
                navigationTarget: bestMatch(for: article),
                zoomScale: readerZoomScale,
                readerTheme: .system,
                zoomInAction: { setReaderZoomScale(readerZoomScale + ArticleReaderZoom.step) },
                zoomOutAction: { setReaderZoomScale(readerZoomScale - ArticleReaderZoom.step) },
                resetZoomAction: resetReaderZoom
            )
        } else if let content = article.content, !content.isEmpty {
            TranscriptReaderView(
                article: article,
                content: content,
                selectedText: $selectedText,
                findState: findState,
                zoomScale: readerZoomScale,
                navigationTarget: bestMatch(for: article),
                readerTheme: .system,
                zoomInAction: { setReaderZoomScale(readerZoomScale + ArticleReaderZoom.step) },
                zoomOutAction: { setReaderZoomScale(readerZoomScale - ArticleReaderZoom.step) },
                resetZoomAction: resetReaderZoom
            )
        } else if article.url.hasPrefix("http://") || article.url.hasPrefix("https://") {
            // Papers and other sources with web URLs but no local PDF/content yet
            ArticleReaderView(
                article: article,
                reviewMode: true,
                showsSpeechControls: false,
                showsBrowserToolbar: false,
                findState: findState,
                chromeState: articleReaderChrome,
                speech: speech,
                selectionChanged: { selectedText = $0 }
            )
        } else {
            ContentUnavailableView {
                Label("No Content", systemImage: "doc.text")
            } description: {
                Text("Select a source or fetch its content first.")
            }
            // A source whose text is stored but whose row arrived without it
            // loads it here. An explainer the Explain button had just written
            // opened, showed its text, and a second later a refresh replaced
            // its row with one carrying no content, leaving this view up for
            // good.
            .task(id: article.id) { await vm.hydrateStoredContent(for: article.id) }
        }
    }


    private func fetchingTitle(for article: StudioArticle) -> String {
        switch article.sourceType {
        case .podcast:
            return "Fetching transcript…"
        case .paper:
            return "Loading paper…"
        case .video, .course, .meeting:
            return "Fetching transcript…"
        default:
            return "Fetching content…"
        }
    }

    private func fetchingSubtitle(for article: StudioArticle) -> String {
        switch article.sourceType {
        case .podcast:
            return "Transcript will appear here when it finishes."
        case .paper:
            return "The paper will appear here when it finishes."
        default:
            return "Content will appear here when it finishes."
        }
    }

    private func fetchingSourceView(for article: StudioArticle) -> some View {
        ReaderLoadingView(
            title: fetchingTitle(for: article),
            subtitle: fetchingSubtitle(for: article)
        )
    }

    // MARK: - Empty State

    private func iconForSourceType(_ type: StudioSourceType) -> String {
        switch type {
        case .article, .unclassified: return "doc.richtext"
        case .paper: return "doc.text.magnifyingglass"
        case .podcast: return "headphones"
        case .book: return "book.closed"
        case .course: return "graduationcap"
        case .meeting: return "person.2.wave.2"
        case .video: return "play.rectangle"
        case .xPost, .manual: return "doc.text"
        }
    }

    /// Dark Mode only invents a page's colors on two surfaces: a PDF, inverted
    /// at the layer, and a live publisher page that turned out to have no dark
    /// design of its own. Everything else composes its own dark page, so there
    /// would be nothing there for this to switch off — and in Light Mode nothing
    /// is darkened at all.
    private func showsOriginalPageColorsToggle(for article: StudioArticle) -> Bool {
        guard colorScheme == .dark else { return false }
        return usesEmbeddedBrowser(article)
            || article.cachedHasRemotePDFURL
            || article.isPDF
    }

    private func usesEmbeddedBrowser(_ article: StudioArticle) -> Bool {
        guard !article.isYouTubeURL,
              !article.cachedHasRemotePDFURL,
              !article.isPDF,
              !article.cachedIsEPUBChapter else { return false }
        // Having archived a page is not a reason to stop showing it. See
        // `cachedPrefersLiveWebPage`: the archive is the offline snapshot, and
        // the reader falls back to it when the live load fails.
        if article.cachedIsArchivedArticle { return article.cachedPrefersLiveWebPage }
        if article.cachedIsWebArticle { return true }
        if article.content?.isEmpty == false { return false }
        return article.url.hasPrefix("http://") || article.url.hasPrefix("https://")
    }

    /// A paywalled or locally imported archive renders through the EPUB reader
    /// rather than the embedded browser, but its saved HTML keeps live
    /// hyperlinks — following one has to be reversible. Those chevrons stay
    /// hidden until there is history to walk.
    private func showsBrowserNavigation(_ article: StudioArticle) -> Bool {
        if usesEmbeddedBrowser(article) { return true }
        guard article.cachedIsArchivedArticle else { return false }
        return articleReaderChrome.canGoBack || articleReaderChrome.canGoForward
    }

    private func hasBrowserURL(_ article: StudioArticle) -> Bool {
        article.url.hasPrefix("http://") || article.url.hasPrefix("https://")
    }

    private func hasAttachedPaywallText(_ article: StudioArticle) -> Bool {
        article.isPaywalled && article.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// The visible center strip owns close at toolbar height. When that strip is
    /// hidden, the docked primary reader always supplies the in-pane fallback —
    /// including when Reader is the sole center pane. Secondary and
    /// override-driven hosts manage their own lifecycle.
    private var showsCloseButton: Bool {
        !centerTabStripVisible
            && !isSecondaryReader
            && overrideArticleId == nil
    }

    /// Full Screen: this Reader's pane alone across the window, the window
    /// full screen with it, and the same button back (product owner,
    /// 2026-11-11: "a nice way to quickly go into full screen mode for the
    /// reader"). On the bar beside ⋯ rather than inside it, since it is one
    /// click in and the visible way out. ⇧⌘↩ does the same
    /// (`readerKeyEquivalents`). Only in a pane of the tab layout: a
    /// notebook's slot and the pop-out window have no panes to step aside.
    @ViewBuilder
    private var readerFullScreenButton: some View {
        if paneGroupID != nil {
            let isFullScreen = paneIsFullScreen
            TitlebarBandButton(
                help: isFullScreen ? "Exit Full Screen (⇧⌘↩)" : "Full Screen (⇧⌘↩)",
                accessibilityLabel: isFullScreen ? "Exit Full Screen" : "Full Screen",
                accessibilityIdentifier: "studio.reader.fullScreen",
                controlSize: StudioPanelChrome.readerCloseButtonSize,
                action: toggleReaderFullScreen
            ) {
                Image(systemName: isFullScreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right")
                    .zoomedSystemFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
                    .frame(
                        width: StudioPanelChrome.readerCloseButtonSize,
                        height: StudioPanelChrome.readerCloseButtonSize
                    )
            }
        }
    }

    private var paneIsFullScreen: Bool {
        paneGroupID != nil && windowState.fullScreenGroupID == paneGroupID
    }

    private func toggleReaderFullScreen() {
        guard let paneGroupID else { return }
        windowState.toggleFullScreen(ofGroup: paneGroupID)
    }

    private var readerCloseButton: some View {
        // A `Button` here would hand its mouse-down to the titlebar's window
        // drag; see `TitlebarBandHitSurfaceView`.
        TitlebarBandButton(
            help: "Close pane",
            accessibilityLabel: "Close pane",
            accessibilityIdentifier: "studio.reader.closePane",
            controlSize: StudioPanelChrome.readerCloseButtonSize,
            action: closeReaderPane
        ) {
            Image(systemName: "xmark")
                .zoomedSystemFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
                // Unscaled on purpose. The shared chrome to the left reserves
                // `readerPaneCloseControlReservedWidth`, an unscaled 26 + 12; a
                // box that grew with the UI zoom slid its left edge under the
                // hit surface of the control there, layered above this one,
                // which then took every click on that side of the X.
                // The glyph still scales, through `zoomedSystemFont`.
                .frame(
                    width: StudioPanelChrome.readerCloseButtonSize,
                    height: StudioPanelChrome.readerCloseButtonSize
                )
        }
    }

    private func closeReaderPane() {
        withAnimation(.easeInOut(duration: 0.22)) {
            // Titlebar controls accept first mouse, so they can fire before
            // this window becomes key. Route through the scene that rendered
            // the button instead of whichever Studio window was last active.
            vm.dismissCenterSurface(.reader, in: windowState)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isSecondaryReader {
            ReaderIdleHero(
                systemImage: "rectangle.split.2x1",
                title: "Second reader",
                subtitle: "Drag a source here to read it side by side."
            )
        } else {
            ReaderIdleStateView()
        }
    }

    private func fetchPodcastTranscriptOnOpenIfNeeded(_ article: StudioArticle) async {
        guard article.fetchesPodcastTranscriptOnOpen else { return }
        await vm.fetchContent(for: article.id)
    }

    @ViewBuilder
    private func podcastTranscriptPrompt(for article: StudioArticle) -> some View {
        let canFetchTranscript = !StudioViewModel.isTerminalPodcastTranscriptError(article.errorMessage)
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "text.bubble")
                .zoomedSystemFont(size: 48)
                .foregroundStyle(.orange)

            VStack(spacing: 8) {
                Text(article.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                if let errorMessage = article.errorMessage,
                   !errorMessage.isEmpty,
                   article.statusFlag != .needsTranscript {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else if article.state == .queued {
                    Text("Getting transcript…")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Transcript is not available yet.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            if canFetchTranscript {
                Button {
                    Task { await vm.fetchContent(for: article.id) }
                } label: {
                    Label("Fetch Transcript", systemImage: "arrow.down.circle")
                        .font(.headline)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.large)
            } else {
                PodcastTranscriptRecoveryActions(article: article)
                    .id(article.id)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

/// Recovery actions shared by the inline and pop-out readers. Audio STT and a
/// confirmed YouTube import are both explicit per-episode choices.
struct PodcastTranscriptRecoveryActions: View {
    @Environment(StudioViewModel.self) private var vm
    let article: StudioArticle

    /// Ranked best-match-first, but only one is presented at a time.
    @State private var candidates: [YouTubeVideoSearchResult] = []
    @State private var shownMatchIndex = 0
    @State private var isSearching = false
    @State private var isShowingCandidates = false
    @State private var didAttemptAutomaticSearch = false
    @State private var importingVideoID: String?
    @State private var searchError: String?
    @State private var importError: String?

    var body: some View {
        VStack(spacing: 10) {
            if StudioViewModel.canOptInToPodcastAudioTranscription(article.errorMessage) {
                Button {
                    Task { await vm.transcribePodcastEpisodeAudio(for: article.id) }
                } label: {
                    Label("Transcribe Audio", systemImage: "waveform")
                        .font(.headline)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Button {
                Task { await searchYouTube(authenticateIfNeeded: true) }
            } label: {
                if isSearching {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Searching YouTube…")
                    }
                    .font(.headline)
                } else {
                    Label(
                        candidates.isEmpty ? "Find on YouTube" : "Review YouTube Match",
                        systemImage: "play.rectangle"
                    )
                        .font(.headline)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.large)
            .disabled(isSearching)

            if !article.domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Toggle(
                    "Always find \(article.domain) on YouTube",
                    isOn: Binding(
                        get: {
                            vm.prefersYouTubeTranscript(forPodcastShow: article.domain)
                        },
                        set: { enabled in
                            vm.setYouTubeTranscriptFallback(
                                forPodcastShow: article.domain,
                                enabled: enabled
                            )
                            if enabled {
                                Task { await searchYouTube(authenticateIfNeeded: true) }
                            }
                        }
                    )
                )
                .toggleStyle(.checkbox)
                .font(.callout)
            }

            if let page = article.podcastWebPageURL.flatMap({ URL(string: $0) }) {
                Link("Open Episode", destination: page)
                    .font(.callout)
            }

            if let searchError {
                Text(searchError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .sheet(isPresented: $isShowingCandidates) {
            candidatePicker
        }
        .task(id: automaticSearchTaskID) {
            guard !didAttemptAutomaticSearch,
                  StudioViewModel.shouldAutomaticallySearchYouTubeForPodcast(
                    article,
                    isYouTubeSignedIn: YouTubeService.shared.isSignedIn
                  ) else { return }
            didAttemptAutomaticSearch = true
            await searchYouTube(authenticateIfNeeded: false)
        }
    }

    /// The model has already ranked the candidates, so the sheet asks about one
    /// video — the best match — instead of handing the learner a list of five
    /// near-identical titles to rank again. **Show Another** walks down the
    /// ranking when the top match is the wrong episode, so nothing the search
    /// found is out of reach; confirmation still gates the import.
    @ViewBuilder
    private var candidatePicker: some View {
        if let candidate = shownMatch {
            VStack(spacing: 20) {
                Image(systemName: "play.rectangle")
                    .zoomedSystemFont(size: 40)
                    .foregroundStyle(.orange)

                Text("Is this the episode?")
                    .font(.title2.weight(.semibold))

                VStack(spacing: 6) {
                    Text(candidate.title)
                        .font(.headline)
                        .multilineTextAlignment(.center)

                    Text(candidateMetadata(candidate))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let summary = candidateSummary(candidate) {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .padding(.top, 4)
                    }
                }

                if let url = URL(string: candidate.url) {
                    Link("Preview on YouTube", destination: url)
                        .font(.callout)
                }

                if let importError {
                    Text(importError)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 12) {
                    Button("Cancel") {
                        isShowingCandidates = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                    .disabled(importingVideoID != nil)

                    if hasAnotherMatch {
                        Button("Show Another") {
                            showNextMatch()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(importingVideoID != nil)
                    }

                    Button {
                        importTranscript(from: candidate)
                    } label: {
                        if importingVideoID == candidate.id {
                            ProgressView()
                                .controlSize(.small)
                                .frame(minWidth: 96)
                        } else {
                            Text("Use Transcript")
                                .frame(minWidth: 96)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.large)
                    .disabled(importingVideoID != nil)
                }

                if candidates.count > 1 {
                    Text("Match \(shownMatchIndex + 1) of \(candidates.count)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(28)
            .frame(minWidth: 420, maxWidth: 520)
        }
    }

    private var shownMatch: YouTubeVideoSearchResult? {
        candidates.indices.contains(shownMatchIndex) ? candidates[shownMatchIndex] : nil
    }

    private var hasAnotherMatch: Bool {
        candidates.indices.contains(shownMatchIndex + 1)
    }

    private func showNextMatch() {
        guard hasAnotherMatch else { return }
        shownMatchIndex += 1
        importError = nil
    }

    private func candidateMetadata(_ candidate: YouTubeVideoSearchResult) -> String {
        [
            candidate.channelTitle,
            candidate.publishedAt?.formatted(date: .abbreviated, time: .omitted),
            candidateOrigin(candidate),
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    /// Why this video is offered, when that is better evidence than a search
    /// hit: the titles of an episode and its upload often share no word.
    private func candidateOrigin(_ candidate: YouTubeVideoSearchResult) -> String? {
        switch candidate.foundBy {
        case .episodePage: return "Linked from the episode’s page"
        case .showChannel: return "On the show’s channel"
        case .search, nil: return nil
        }
    }

    /// Editorial title differences are expected, so the description snippet is
    /// often what tells the learner this really is the episode they opened.
    private func candidateSummary(_ candidate: YouTubeVideoSearchResult) -> String? {
        let summary = candidate.description?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return summary.isEmpty ? nil : summary
    }

    private var automaticSearchTaskID: String {
        "\(article.id)|\(article.errorMessage ?? "")"
    }

    @MainActor
    private func searchYouTube(authenticateIfNeeded: Bool) async {
        guard !isSearching else { return }
        if !candidates.isEmpty {
            isShowingCandidates = true
            return
        }
        isSearching = true
        searchError = nil
        defer { isSearching = false }
        do {
            if !YouTubeService.shared.isSignedIn {
                guard authenticateIfNeeded else { return }
                try await YouTubeService.shared.authenticate()
            }
            candidates = try await vm.findYouTubeTranscriptCandidates(for: article.id)
            shownMatchIndex = 0
            importError = nil
            isShowingCandidates = true
        } catch is CancellationError {
            return
        } catch {
            searchError = error.localizedDescription
        }
    }

    private func importTranscript(from candidate: YouTubeVideoSearchResult) {
        guard importingVideoID == nil else { return }
        importingVideoID = candidate.id
        importError = nil
        Task { @MainActor in
            defer { importingVideoID = nil }
            do {
                try await vm.importYouTubeTranscript(for: article.id, from: candidate)
                isShowingCandidates = false
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

// MARK: - Idle (empty) reader state

/// Most-recently-read source ids, persisted as lightweight UI state so the
/// reader's idle view can offer "Continue reading" without touching files or
/// SQLite. UserDefaults only — this is ephemeral navigation state, not
/// knowledge-base data, so it deliberately stays out of the sync pipeline.
@MainActor
@Observable
final class ReaderRecentsStore {
    static let shared = ReaderRecentsStore()
    private static let capacity = 24

    private(set) var sourceIDs: [String]

    private init() {
        sourceIDs = Preferences.value(Prefs.Readers.recentSourceIDs) ?? []
    }

    func record(_ sourceID: String) {
        var ids = sourceIDs.filter { $0 != sourceID }
        ids.insert(sourceID, at: 0)
        if ids.count > Self.capacity {
            ids.removeLast(ids.count - Self.capacity)
        }
        guard ids != sourceIDs else { return }
        sourceIDs = ids
        Preferences.set(ids, for: Prefs.Readers.recentSourceIDs)
    }
}

/// Centered icon + title + subtitle used by both readers' idle states so the
/// two panes share one typographic voice. The glyph renders bare and
/// monochrome — no tinted badge disc — and the title is set in serif, matching
/// the idle chat greeting so every empty state speaks in one voice.
struct ReaderIdleHero: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 27, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 19, weight: .medium, design: .serif))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
    }
}

/// What the primary reader shows when no source is open: resume-reading rows,
/// today's plan, and a quiet drag hint — instead of a bare system placeholder.
/// Everything rendered here comes from already-published view-model state; no
/// I/O happens on this render path.
private struct ReaderIdleStateView: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @State private var hoveredRowID: String?
    @State private var readingListBrowser: ReadingListBrowser = .safari
    @State private var isCheckingReadingLists = false
    @State private var readingListCheckMessage: String?

    private var recents: ReaderRecentsStore { ReaderRecentsStore.shared }

    /// Most recent sources, collapsing book chapters into one row per book so a
    /// long reading session doesn't fill the list with itself.
    private static let recentRowLimit = 8

    private var recentArticles: [StudioArticle] {
        var seenKeys = Set<String>()
        var result: [StudioArticle] = []
        for id in recents.sourceIDs {
            guard let article = vm.articlesById[id] else { continue }
            guard !vm.isSourceHidden(article), vm.isVisibleInRecordingMode(article) else { continue }
            guard seenKeys.insert(Self.rowKey(for: article)).inserted else { continue }
            result.append(article)
            if result.count == Self.recentRowLimit { break }
        }
        return result
    }

    /// Today's plan, resolved once per render. `unifiedScheduleDays`
    /// walks every scheduled source, and reading it separately from each
    /// recents row, the today card and its summary re-ran that walk a dozen
    /// times per body — in every window whose reader sat idle — each time any
    /// source changed. Opening a video changes a source, so every click in the
    /// sidebar paid for it on the main thread.
    private struct TodayPlan {
        var items: [SchedulePlanItem]
        /// Row keys of sources still pending today, so recents rows can show
        /// that they double as today's scheduled work.
        var rowKeys: Set<String>
        var summary: String

        var isEmpty: Bool { items.isEmpty }
    }

    private var todayPlan: TodayPlan {
        let items = vm.unifiedScheduleDays(containing: Date())
            .first(where: \.isToday)?
            .items.filter { !$0.isCompleted } ?? []
        let rowKeys = Set(items.map { item in
            guard let article = vm.articlesById[item.sourceID] else { return item.sourceID }
            return Self.rowKey(for: article)
        })
        let words = items
            .compactMap { vm.articlesById[$0.sourceID]?.wordCount }
            .reduce(0, +)
        var summary = items.count == 1 ? "1 source planned" : "\(items.count) sources planned"
        if words > 0 {
            summary += " · about \(max(1, words / 220)) min"
        }
        return TodayPlan(items: items, rowKeys: rowKeys, summary: summary)
    }

    /// Books collapse to one recents row per book, so both the recents list and
    /// the today-badge match on the book group rather than the chapter id.
    private static func rowKey(for article: StudioArticle) -> String {
        article.sourceType == .book ? (article.parentGroup ?? article.id) : article.id
    }

    var body: some View {
        // Before the first library load, every list here is empty for the
        // wrong reason, and the first-source onboarding would flash at a
        // learner whose sources are still being read. Hold a quiet spinner
        // until an empty library actually means empty. A failed load falls
        // through — the sidebar carries that error, and spinning on it
        // forever would just relocate the lie.
        if vm.hasCompletedInitialQueueLoad || vm.libraryLoadErrorMessage != nil {
            ScrollView(.vertical) {
                idleContent
            }
            .scrollBounceBehavior(.basedOnSize)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var idleContent: some View {
        // Both derived once here and handed down: see `TodayPlan`.
        let today = todayPlan
        let recents = recentArticles
        return VStack(alignment: .leading, spacing: 22) {
            if !vm.activeArticles.isEmpty {
                GetStartedSuggestions(
                    source: recents.first ?? vm.activeArticles.first,
                    onOpenSource: open(sourceID:)
                )
            }

            if vm.activeArticles.isEmpty {
                firstSourceGuide
            } else if recents.isEmpty && today.isEmpty {
                if let notebook = suggestedReviewNotebook {
                    suggestedReviewHero(notebook)
                } else {
                    startNotebookHero
                }
            }

            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Continue reading")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    VStack(spacing: 4) {
                        ForEach(recents) { article in
                            continueReadingRow(
                                article,
                                isPlannedToday: today.rowKeys.contains(Self.rowKey(for: article))
                            )
                        }
                    }
                }
            }

            if !today.isEmpty {
                todayCard(today)
            }
        }
        .frame(maxWidth: 400)
        .padding(28)
        .frame(maxWidth: .infinity)
    }

    private var firstSourceGuide: some View {
        VStack(alignment: .leading, spacing: 18) {
            ReaderIdleHero(
                systemImage: "text.book.closed",
                title: "Add your first source",
                subtitle: "Turn the articles already worth saving into a learning library."
            )
            .frame(maxWidth: .infinity)
            .padding(.bottom, -8)

            Picker("Browser", selection: $readingListBrowser) {
                ForEach(ReadingListBrowser.allCases) { browser in
                    Text(browser.title).tag(browser)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 12) {
                firstSourceStep("1", "Open an article you want to learn")
                firstSourceStep("2", readingListBrowser.saveInstruction)
                if let shortcut = readingListBrowser.shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 30)
                        .padding(.top, -6)
                }
                firstSourceStep("3", "Return here and check your Reading Lists")
            }
            .padding(14)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))

            if vm.needsBrowserAccess {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "Add ForeverLM to Full Disk Access with the \"+\" button — macOS does not list it until you do — turn it on, then relaunch the app.",
                        systemImage: "lock.shield"
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    Button("Open Privacy Settings", action: openFullDiskAccessSettings)
                        .font(.system(size: 11, weight: .semibold))
                }
            }

            HStack(spacing: 10) {
                Button {
                    BrowserService.open(
                        URL(string: "https://en.wikipedia.org/wiki/Feynman_Technique")!,
                        preference: readingListBrowser.preference
                    )
                } label: {
                    Text("Open Example in \(readingListBrowser.title)")
                        .font(.system(size: 12, weight: .semibold))
                }

                Button(action: checkReadingLists) {
                    if isCheckingReadingLists {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Check Reading Lists")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCheckingReadingLists || vm.isLoadingQueue)
            }

            if let readingListCheckMessage {
                Text(readingListCheckMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Text("ForeverLM imports new Reading List items automatically. You can keep saving pages from either browser after this.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 440)
    }

    private func firstSourceStep(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(number)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20, height: 20)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func checkReadingLists() {
        guard !isCheckingReadingLists else { return }
        isCheckingReadingLists = true
        readingListCheckMessage = nil
        Task { @MainActor in
            await vm.refreshTab(.articles)
            isCheckingReadingLists = false
            if vm.activeArticles.isEmpty {
                readingListCheckMessage = vm.needsBrowserAccess
                    ? "Access is still needed before ForeverLM can see your Reading Lists."
                    : "Nothing new yet. Make sure the page is saved in Reading List, then check again."
            }
        }
    }

    private func openFullDiskAccessSettings() {
        let settingsURLs = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
        ]
        for raw in settingsURLs {
            guard let url = URL(string: raw) else { continue }
            NSWorkspace.shared.open(url)
            return
        }
    }

    /// The Notebook a fresh session should suggest reviewing: the active Notebook
    /// when it has approved sources, otherwise any Notebook that does.
    private var suggestedReviewNotebook: LearningGoalRecord? {
        let candidates = vm.notebooks.filter { !$0.approvedSourceIDs.isEmpty }
        if let activeID = vm.activeNotebookId,
           let active = candidates.first(where: { $0.id == activeID }) {
            return active
        }
        return candidates.first
    }

    private func suggestedReviewHero(_ notebook: LearningGoalRecord) -> some View {
        VStack(spacing: 12) {
            ReaderIdleHero(
                systemImage: "graduationcap",
                title: "Ready to review?",
                subtitle: "Test yourself on \u{201C}\(notebook.title)\u{201D} with the tutor."
            )
            .padding(.bottom, -12)
            Button {
                vm.requestNotebookReview(notebook.id)
            } label: {
                Text("Start review")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity)
    }

    private var startNotebookHero: some View {
        VStack(spacing: 12) {
            ReaderIdleHero(
                systemImage: "folder.badge.plus",
                title: "Start a notebook",
                subtitle: "Group sources around a goal, then plan and review them with the tutor."
            )
            .padding(.bottom, -12)
            Button {
                // Made at once and opened, as New ▸ Notebook in the Space does:
                // the button says what it does.
                vm.makeAndOpenNotebook(in: windowState)
            } label: {
                Text("New notebook")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity)
    }

    private func continueReadingRow(_ article: StudioArticle, isPlannedToday: Bool) -> some View {
        Button {
            open(sourceID: article.id)
        } label: {
            HStack(spacing: 10) {
                continueReadingThumbnail(for: article)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.playlistAwareTitle(for: article))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let subtitle = rowSubtitle(for: article) {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isPlannedToday {
                    Text("Today")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .help("On today's schedule")
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Color.primary.opacity(hoveredRowID == article.id ? 0.07 : 0.035),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        // The row says Watched for a finished video, so its menu can undo it.
        .contextMenu {
            OtherWindowSourceMenuItem(article)
            VideoWatchedMenuItems(article: article)
        }
        .onHover { hovering in
            hoveredRowID = hovering ? article.id : (hoveredRowID == article.id ? nil : hoveredRowID)
        }
        .task(id: article.artworkURL) {
            // Match ArticleRow: sources without persisted artwork should run the
            // same lightweight thumbnail backfill when they appear here.
            await vm.backfillArtworkIfNeeded(article.id)
        }
    }

    @ViewBuilder
    private func continueReadingThumbnail(for article: StudioArticle) -> some View {
        if article.sourceType == .book,
           let groupName = article.parentGroup,
           let coverPath = vm.bookCoverPaths[groupName] {
            // Recents collapse chapters into a single book row, so show the
            // book cover used by the Sources panel rather than chapter XHTML.
            BookCoverThumbnail(
                pdfPath: coverPath,
                size: CGSize(width: 30, height: 30),
                placeholderSystemImage: "book.closed",
                tint: .green
            )
        } else {
            SourceThumbnail(source: continueReadingThumbnailSource(for: article), size: 30)
        }
    }

    private func continueReadingThumbnailSource(for article: StudioArticle) -> StudioArticle {
        guard article.artworkURL == nil,
              article.youtubeThumbnailURL == nil,
              let groupName = article.parentGroup,
              vm.allCourseGroupNames.contains(groupName),
              let courseArtworkURL = vm.courseArtworkURL(groupName) else {
            return article
        }

        // Course materials without artwork borrow the same course cover shown
        // in Sources. A lecture's own artwork always wins when it has one.
        var source = article
        source.artworkURL = courseArtworkURL
        return source
    }

    private func rowSubtitle(for article: StudioArticle) -> String? {
        var parts: [String] = []
        if article.sourceType == .paper {
            // Papers mirror the Sources panel: author · journal · year, minus
            // the "Unknown …" enrichment placeholders that row has room for.
            parts = article.paperMetadataDisplayParts.filter {
                $0 != StudioArticle.unknownPaperAuthor
                    && $0 != StudioArticle.unknownPaperJournal
                    && $0 != StudioArticle.unknownPaperYear
            }
            if parts.isEmpty, let domain = article.displayDomain {
                parts.append(domain)
            }
        } else if let context = vm.sourceGroupTitle(for: article), !context.isEmpty {
            parts.append(context)
        } else if let domain = article.displayDomain {
            parts.append(domain)
        }
        if let page = vm.readingProgressStore.page(for: article.id) ?? article.readingPositionPage {
            parts.append("Page \(page + 1)")
        } else if article.sourceType == .video,
                  let watchLabel = vm.readingProgressStore.videoWatchProgress(
                    for: article.id,
                    fallbackLocator: article.readingPositionLocator
                  )?.displayLabel {
            parts.append(watchLabel)
        } else if vm.readingProgressStore.hasProgress(for: article.id) || article.hasSavedReadingPosition {
            parts.append("In progress")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    private func todayCard(_ today: TodayPlan) -> some View {
        HStack(spacing: 0) {
            Button {
                if let first = today.items.first {
                    open(sourceID: first.sourceID)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "calendar")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Today")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(today.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text("Start")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 10, inset: 0))
            .opensInOtherWindow(today.items.first.flatMap { vm.articlesById[$0.sourceID] })
            .help("Open the first pending source planned for today")
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func open(sourceID: String) {
        vm.selectedArticleIds = [sourceID]
        // This Reader's own window, not the registry's key window.
        Task { await vm.selectArticle(sourceID, in: windowState, revealingReader: true) }
    }

}

// MARK: - Remote PDF Reader

extension StudioArticle {
    /// Whether a reader shows the loading view rather than the source: only
    /// while a transcript that is the whole source is still arriving. A web
    /// page, a PDF or a YouTube video being fetched or cleaned up shows
    /// itself meanwhile, since a source reads the moment it is added.
    var readerWaitsForFetch: Bool {
        guard state == .fetching else { return false }
        switch sourceType {
        case .podcast:
            return true
        case .meeting, .video, .course:
            guard content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
                return false
            }
            // These render as plain transcripts, so show the loading view while
            // content streams in instead of the empty "No content" fallback.
            // YouTube videos keep their own embedded player + transcript-loading UI.
            return !isYouTubeURL
        default:
            return false
        }
    }
}

extension StudioArticle {
    /// A podcast with no transcript yet that the reader can offer to find one for.
    var offersPodcastTranscriptSearch: Bool {
        sourceType == .podcast
            && (content?.isEmpty != false)
            && state != .fetching
            && (
                statusFlag == .needsTranscript
                    || url.hasPrefix("apple-podcast:")
                    || url.hasPrefix("http://")
                    || url.hasPrefix("https://")
            )
    }

    /// An Apple Podcasts episode that has no transcript and no error yet, so
    /// opening it fetches one.
    var fetchesPodcastTranscriptOnOpen: Bool {
        sourceType == .podcast
            && state != .fetching
            && (errorMessage?.isEmpty != false)
            && url.hasPrefix("apple-podcast://")
            && content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }
}

/// "Is this the right podcast?": the match found for a podcast source, to
/// confirm or skip.
struct PodcastMatchConfirmationView: View {
    @Environment(StudioViewModel.self) private var vm
    let article: StudioArticle
    let match: PodcastMatchInfo

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "headphones")
                .zoomedSystemFont(size: 48)
                .foregroundStyle(.orange)
            Text("Is this the right podcast?")
                .font(.title2.weight(.semibold))
            VStack(spacing: 4) {
                Text(match.podcastName)
                    .font(.headline)
                Text(match.episodeTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 16) {
                Button {
                    Task { await vm.rejectPodcastMatch(for: article.id) }
                } label: {
                    Text("No, Skip")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    Task { await vm.confirmPodcastMatch(for: article.id) }
                } label: {
                    Text("Yes, Use This")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.large)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// The page a source reader's browser actions (open in Safari, copy link, add
/// to the library) act on.
@MainActor
enum ReaderBrowserURL {
    static func current(
        for article: StudioArticle,
        youtubeWatchPageURL: URL?,
        embeddedBrowser: ArticleReaderChromeState?,
        archivedArticlePageURL: URL?
    ) -> URL? {
        // The video on screen, which is the player's to choose once it hands
        // itself on to the next one.
        if article.isYouTubeURL,
           let url = youtubeWatchPageURL,
           url.hasWebScheme {
            return url
        }
        if let embeddedBrowser,
           let url = embeddedBrowser.liveBrowserURL(),
           url.hasWebScheme {
            return url
        }
        if let embeddedBrowser,
           let url = embeddedBrowser.currentURL,
           url.hasWebScheme {
            return url
        }
        // Archived articles render cached HTML whose links can navigate the
        // reader to a live external page; prefer that page over the source URL.
        if article.cachedIsArchivedArticle,
           let url = archivedArticlePageURL,
           url.hasWebScheme {
            return url
        }
        return URL(string: article.url)
    }
}
