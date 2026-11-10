#if os(macOS)
import AppKit
import OSLog
import SwiftUI
import PDFKit

/// A pop-out window for reading a source article, PDF, or transcript.
/// Can be dragged to a second screen while keeping the Studio on the primary screen.
struct SourceReaderWindow: View {
    let article: StudioArticle
    @Environment(StudioViewModel.self) private var vm
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    /// Written here and read by every reader that would otherwise invert a page.
    @SyncedStorage(ReaderDarkMode.originalPageColorsKey) private var originalPageColors = false
    @State private var selectedText = ""
    @State private var findState = ReaderFindState()
    /// A video's and a podcast's own commands, published by their readers for
    /// the overflow menu's Video and Speakers submenus.
    @State private var readerMenuCommands = ReaderMenuCommands()
    @ObservedObject private var speech = ArticleSpeechService.shared
    @StateObject private var bookNavigationBridge = ReaderBookNavigationBridge()
    /// A book's Contents, open from the overflow menu as a popover off the ⋯ button.
    @State private var isBookContentsPresented = false
    @State private var articleReaderChrome = ArticleReaderChromeState()
    @State private var readerZoomScale = ArticleReaderZoom.defaultScale
    @State private var addingLibraryPageKey: String?
    @State private var savedLibraryPageKeys: Set<String> = []
    /// The chapter the reader has navigated to. This window stays bound to the
    /// source it was opened with, so in-reader book navigation reports where it
    /// landed here instead.
    @State private var navigatedChapterID: String?
    /// Where the archived-article reader actually is after in-page link clicks,
    /// so browser actions target the visible page rather than the source URL.
    @State private var archivedArticlePageURL: URL?
    /// Where the video player actually is: the watch page can hand itself on to
    /// the next video — YouTube's autoplay, or the next entry of the playlist a
    /// course was imported from.
    @State private var youtubeWatchPageURL: URL?
    /// The saved video the player moved to on its own. Like a navigated chapter,
    /// this window stays bound to the source it was opened with and reports
    /// where the reader landed here instead.
    @State private var navigatedVideoID: String?

    private var currentArticle: StudioArticle {
        vm.articles.first(where: { $0.id == article.id }) ?? article
    }

    /// The source actually on screen: the navigated chapter when the reader has
    /// moved through the book, the video the player moved on to when it took
    /// itself there, otherwise the source this window was opened with.
    private var displayedArticle: StudioArticle {
        guard let navigatedID = navigatedVideoID ?? navigatedChapterID,
              let navigated = vm.articles.first(where: { $0.id == navigatedID }) else {
            return currentArticle
        }
        return navigated
    }

    /// Whether the shared speech service is narrating the source on screen.
    private func isNarrating(_ article: StudioArticle) -> Bool {
        speech.isNarrating(article.id)
    }

    var body: some View {
        let article = currentArticle
        ZStack(alignment: .bottomTrailing) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ReaderFindBar(state: findState)
                    Group {
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
                            navigationTarget: nil,
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
                    } else if GeneratedExplainerVideo.isVideoURL(article.url) {
                        ExplainerVideoReaderView(article: article)
                    } else if article.isYouTubeURL {
                        YouTubeVideoReaderView(
                            // The player, not this window, decides which video
                            // is on screen once it hands itself on to the next
                            // one; the whole reader follows it there.
                            article: displayedArticle,
                            selectedText: $selectedText,
                            currentWatchPageURL: $youtubeWatchPageURL,
                            findState: findState,
                            navigationTarget: nil,
                            zoomScale: readerZoomScale,
                            readerTheme: .system,
                            zoomInAction: { setReaderZoomScale(readerZoomScale + ArticleReaderZoom.step) },
                            zoomOutAction: { setReaderZoomScale(readerZoomScale - ArticleReaderZoom.step) },
                            resetZoomAction: resetReaderZoom
                        )
                    } else if article.cachedIsWebArticle
                                && !article.cachedHasRemotePDFURL
                                && (article.localFilePath == nil || article.cachedPrefersLiveWebPage) {
                        // See `SourceReaderPanel`: a paywalled source reads on
                        // the publisher's page, not as flattened extracted text.
                        ArticleReaderView(
                            article: article,
                            reviewMode: true,
                            showsSpeechControls: false,
                            showsBrowserToolbar: false,
                            findState: findState,
                            chromeState: articleReaderChrome,
                            speech: speech,
                            // An archived source reaching the live reader still
                            // owns durable text. If the page has since died and
                            // its archive file is not on this Mac, show that
                            // text rather than a load error. A paywalled source
                            // holds text for the same reason.
                            usesPersistedTextOnLoadFailure: article.cachedIsArchivedArticle
                                || hasAttachedPaywallText(article),
                            selectionChanged: { selectedText = $0 }
                        )
                    } else if article.readsStoredTextOverRemotePDF {
                        // See `SourceReaderPanel`: text handed in with a PDF
                        // URL is the source, often one part of the file.
                        if let content = article.content {
                            TranscriptReaderView(
                                article: article,
                                content: content,
                                selectedText: $selectedText,
                                findState: findState,
                                zoomScale: readerZoomScale,
                                navigationTarget: nil,
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
                    } else if article.cachedHasRemotePDFURL, let pdfURL = article.remotePDFURL {
                        RemotePDFWindowView(
                            articleId: article.id,
                            url: pdfURL,
                            landingPageURL: URL(string: article.url).flatMap { $0 == pdfURL ? nil : $0 },
                            title: article.title,
                            initialPageIndex: article.readingPositionPage,
                            selectedText: $selectedText,
                            findState: findState,
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
                                navigatedChapterID = chapter.id
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
                                        navigatedChapterID = chapter.id
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
                                    navigationTarget: nil,
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
                                    navigationTarget: nil,
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
                        // Meeting sessions with a playable video recording: video on
                        // top, transcript below — the YouTube reader layout. An
                        // audio-only recording resolves to no media and falls through
                        // to the transcript reader.
                        MeetingRecordingReaderView(
                            article: article,
                            media: media,
                            selectedText: $selectedText,
                            findState: findState,
                            navigationTarget: nil,
                            zoomScale: readerZoomScale,
                            readerTheme: .system,
                            zoomInAction: { setReaderZoomScale(readerZoomScale + ArticleReaderZoom.step) },
                            zoomOutAction: { setReaderZoomScale(readerZoomScale - ArticleReaderZoom.step) },
                            resetZoomAction: resetReaderZoom
                        )
                    } else if let content = article.content {
                        TranscriptReaderView(
                            article: article,
                            content: content,
                            selectedText: $selectedText,
                            findState: findState,
                            zoomScale: readerZoomScale,
                            navigationTarget: nil,
                            readerTheme: .system,
                            zoomInAction: { setReaderZoomScale(readerZoomScale + ArticleReaderZoom.step) },
                            zoomOutAction: { setReaderZoomScale(readerZoomScale - ArticleReaderZoom.step) },
                            resetZoomAction: resetReaderZoom
                        )
                    } else {
                        ContentUnavailableView {
                            Label("No Content", systemImage: "doc.text")
                        } description: {
                            Text("This source has no readable content yet.")
                        }
                    }
                    }
                    .environment(readerMenuCommands)
                    .contextMenu { readerContextMenu(for: article) }
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
                .readerHighlightCard(for: displayedArticle.id)
                .readerSideChat(for: displayedArticle.id)

                // The source zoomed out, beside it, as in the docked Reader.
                if ReaderLevelsPanelState.shared.isVisible, ReaderLevels.offers(displayedArticle) {
                    Divider()
                    ReaderLevelsPanel(article: displayedArticle)
                }

                // What links the source, in Levels' column, as in the docked Reader.
                if ReaderReferencesPanelState.shared.isVisible {
                    Divider()
                    ReaderReferencesPanel(article: displayedArticle)
                }

                // Every figure's legend, following the page, as in the docked Reader.
                if ReaderFigureLegendsPanelState.shared.isVisible, ReaderFigureLegends.offers(displayedArticle) {
                    Divider()
                    ReaderFigureLegendsPanel(article: displayedArticle)
                }

                if vm.readerNotesListVisible {
                    Divider()
                    ReaderNotesList(sourceID: displayedArticle.id)
                }
            }
        }
        // The source actually on screen, which the player can change out from
        // under this window by handing itself on to the next video.
        .navigationTitle(vm.displayTitle(for: displayedArticle))
        .siriSourceAnnotation(article.id)
        // A cited paper opens in a window of its own, beside this one.
        .environment(\.readerOpensCitedSource, { sourceID in
            openWindow(id: "source-reader", value: sourceID)
        })
        .toolbar {
            readerWindowToolbar(for: displayedArticle)
        }
        .onChange(of: article.id) { _, _ in
            findState.resetForDocumentChange()
            navigatedChapterID = nil
            navigatedVideoID = nil
            articleReaderChrome.reset()
            archivedArticlePageURL = nil
            youtubeWatchPageURL = nil
            resetReaderZoom()
        }
        .onChange(of: youtubeWatchPageURL) { _, pageURL in
            followWatchPageToSavedVideo(pageURL)
        }
        .task(id: displayedArticle.id) {
            await vm.loadReaderHighlightsIfNeeded(for: displayedArticle.id)
            // Last, because it waits out the engagement dwell: nothing the
            // reader needs on screen may sit behind it.
            await vm.beginReaderEngagement(
                displayedArticle.id,
                kind: vm.automaticActivityKind(for: displayedArticle)
            )
        }
        // A narration Listen made, landing while this window still shows its
        // source, plays; Listen is off the toolbar once it is no longer being
        // made, so nothing there is mounted to take it.
        .onChange(of: speech.madeNarrationSourceID) { _, sourceID in
            guard sourceID == displayedArticle.id else { return }
            speech.takeMadeNarration(displayedArticle)
        }
        .onChange(of: speech.finishedListeningArticleID) { _, finishedID in
            guard let finishedID,
                  let finished = vm.articles.first(where: { $0.id == finishedID }),
                  let group = finished.parentGroup,
                  article.id == finishedID || article.parentGroup == group,
                  speech.consumeFinishedListening(articleID: finishedID) else { return }
            autoAdvanceListening(after: finished)
        }
        .onChange(of: findState.searchRevision) { _, _ in
            selectedText = ""
        }
        // The pop-out reader feeds the same active-selection state as the docked
        // one, so ⇧⌘K and the in-page "Chat about this" pill act on what is
        // selected here.
        .onChange(of: selectedText) { _, newValue in
            vm.updateActiveReaderSelection(sourceID: displayedArticle.id, text: newValue)
        }
        .onDisappear {
            vm.clearActiveReaderSelection(forSourceID: displayedArticle.id)
            vm.readerPoppedOut = false
        }
        .alert("Text to Speech Error", isPresented: Binding(
            get: { speech.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    speech.errorMessage = nil
                }
            }
        )) {
            Button(speech.errorSuggestsProviderSwitch ? "Switch Voice Provider" : "Text to Speech Settings") {
                speech.errorMessage = nil
                TextToSpeechSettingsNavigation.open()
            }
            Button("Open in Safari") {
                speech.errorMessage = nil
                openInSafari(article)
            }
            Button("OK", role: .cancel) {
                speech.errorMessage = nil
            }
        } message: {
            Text(speech.errorMessage ?? "")
        }
        // This window's own actions (Download PDF, Copy source link, Attach PDF)
        // raise toasts through vm; render the shared banner here so they appear on
        // the reader window instead of only on the main Studio window.
        .studioToast(vm)
    }

    /// Written out, not as a ternary in the toolbar: the type checker gave up
    /// on the whole toolbar builder over that one expression.
    private var bookGoToPage: ((Int) -> Void)? {
        guard bookNavigationBridge.pageNavigation != nil else { return nil }
        let bridge = bookNavigationBridge
        return { bridge.goToPage($0) }
    }

    @ToolbarContentBuilder
    private func readerWindowToolbar(for article: StudioArticle) -> some ToolbarContent {
        // The day, in this window too: a pop-out Reader has no rail, so its
        // toolbar carries the Now chip, and, as in the rail, only while
        // something is happening (2026-10-06): an empty item would still
        // draw its toolbar slot.
        if DayModel.shared.nowPresentation != nil {
            ToolbarItem(placement: .navigation) {
                DayNowChip(style: .toolbar, maxWidth: 240)
            }
        }
        // Beside the window's title, the grip that drags this source into the
        // chat of the Studio window used last, while that chat is on screen.
        if vm.activeWindowState.showsChatToDropInto {
            ToolbarItem(placement: .navigation) {
                SourceReaderChatDragIcon(
                    source: article,
                    title: vm.displayTitle(for: article)
                )
            }
        }
        // Quiet chrome (docs/ui-design.md, 2026-10-06): navigation, Add to
        // Sources, Listen while it prepares or plays, and the ⋯, which holds
        // Listen and Contents the rest of the time.
        ToolbarItemGroup(placement: .primaryAction) {
            if !isNarrating(article) && showsBrowserNavigation(article) {
                ReaderNavigationButton(
                    systemImage: "chevron.left",
                    help: "Go back",
                    isEnabled: articleReaderChrome.canGoBack
                ) {
                    articleReaderChrome.goBack()
                }

                ReaderNavigationButton(
                    systemImage: "chevron.right",
                    help: "Go forward",
                    isEnabled: articleReaderChrome.canGoForward
                ) {
                    articleReaderChrome.goForward()
                }
            }

            if !isNarrating(article) && articleReaderChrome.isLoading && usesEmbeddedBrowser(article) {
                ProgressView()
                    .controlSize(.small)
            }

            if let pageURL = addableLibraryPageURL(for: article) {
                let pageKey = libraryPageKey(pageURL)
                let state = ReaderAddPageToolbarState(
                    isAdding: addingLibraryPageKey == pageKey,
                    isSaved: savedLibraryPageKeys.contains(pageKey)
                )
                ReaderAddPageToolbarButton(state: state, showsTitle: true) {
                    addCurrentPageToLibrary(pageURL)
                }
            }

            // Transport only once playback owns this source. While preparation
            // runs, `ArticleSpeechControls` is what acknowledges the click, with
            // a spinner, the current step, and a cancel — three disabled
            // transport buttons in its place read as a dead click. Idle, it
            // draws nothing: Listen is the ⋯ menu's.
            if speech.activeArticleID == article.id {
                ArticleSpeechTransportControls(speech: speech)
            } else {
                ArticleSpeechControls(
                    speech: speech,
                    article: article,
                    showsTitle: false,
                    showsListenWhenIdle: false
                )
            }

            readerOverflowMenu(for: article)
        }

        if isNarrating(displayedArticle), speech.showsToolbarProgress {
            ToolbarItem(placement: .status) {
                ArticleSpeechToolbarProgress(speech: speech)
            }
        }
    }

    /// A video hands the player on to the next one by itself: YouTube's
    /// autoplay, or the next entry of the playlist a course was imported from.
    /// This window stays bound to the source it was opened with, so its title,
    /// its transcript, its notes and its watch progress all went on describing
    /// the lecture that finished while a different one played. When the library
    /// holds the video now on screen, the whole reader moves to that source —
    /// without disturbing the player, which keeps the page it is already
    /// showing instead of loading it again.
    ///
    /// Only a saved source is followed. A video the library does not hold
    /// leaves the reader where it is.
    private func followWatchPageToSavedVideo(_ pageURL: URL?) {
        let shown = displayedArticle
        guard shown.isYouTubeURL,
              let movedTo = YouTubeWatchPageIdentity.videoNavigatedAwayFrom(
                  sourceURL: shown.url,
                  livePageURL: pageURL
              ),
              let sourceID = vm.librarySourceID(forURL: movedTo.absoluteString),
              sourceID != shown.id else { return }
        navigatedVideoID = sourceID == article.id ? nil : sourceID
    }

    /// A visible pop-out reader follows its Contents order before the Studio's
    /// persistent player falls back to stored book order.
    private func autoAdvanceListening(after finished: StudioArticle) {
        guard let next = advanceReaderToChapter(after: finished) else { return }
        speech.startTextToSpeech(article: next)
    }

    private func advanceReaderToChapter(after finished: StudioArticle) -> StudioArticle? {
        if let nextItem = bookNavigationBridge.navigation?.nextItem,
           let next = readerChapterSource(for: nextItem) {
            bookNavigationBridge.navigate(to: nextItem)
            navigatedChapterID = next.id
            return next
        }
        guard let group = finished.parentGroup else { return nil }
        let chapters = vm.bookChapterArticlesInOrder(for: group)
        guard let index = chapters.firstIndex(where: { $0.id == finished.id }),
              index + 1 < chapters.count else { return nil }
        let next = chapters[index + 1]
        navigatedChapterID = next.id
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

    /// Consolidated menu mirroring the inline reader panel: find and zoom stay
    /// listed for discoverability, but Cmd+F and Cmd+= / Cmd+- / Cmd+0 are the
    /// primary interface.
    private func readerOverflowMenu(for article: StudioArticle) -> some View {
        Menu {
            // The source's own actions first, in the docked Reader's order;
            // Listen and Contents were toolbar buttons until Quiet chrome
            // (docs/ui-design.md, 2026-10-06).
            ArticleSpeechListenMenuItem(speech: speech, article: article)
            RealtimeVoiceMenuItems(article: article, notebookID: nil)
            ExplainerMenuItems(article: article)
            ReaderLevelsMenuItem(article: article)
            if bookNavigationBridge.navigation != nil {
                Button {
                    isBookContentsPresented = true
                } label: {
                    Label("Contents…", systemImage: "list.bullet")
                }
            }
            if bookNavigationBridge.canTurnPage {
                ReaderRotatePageMenuItems(bridge: bookNavigationBridge)
            }
            // A video's and a podcast's own commands, which sat on a bar
            // above the transcript until Quiet chrome (docs/ui-design.md,
            // 2026-10-06). The player may have moved on to another saved
            // video, which is then the one on screen.
            if displayedArticle.isYouTubeURL {
                if let commands = readerMenuCommands.video(for: displayedArticle.id) {
                    ReaderVideoMenu(chatAboutVideo: nil, commands: commands)
                }
            }
            if let speakers = readerMenuCommands.speakers(for: article.id) {
                ReaderSpeakersMenu(commands: speakers)
            }
            Divider()

            LinkedInMenuItems(article: article)
            ReaderReferencesMenuItem()
            if ReaderFigureLegends.offers(displayedArticle) {
                ReaderFigureLegendsMenuItem()
            }

            Button {
                vm.readerNotesListVisible.toggle()
            } label: {
                Label(
                    vm.readerNotesListVisible ? "Hide Highlights" : "Show Highlights",
                    systemImage: "highlighter"
                )
            }

            if hasBrowserURL(article) {
                Button {
                    openInSafari(article)
                } label: {
                    Label(openInSafariMenuLabel(for: article), systemImage: "safari")
                }
            }

            if article.sourceType == .article {
                Divider()
                ArticleReadingViewMenuItems(article: article)
            }

            Divider()

            if isNarrating(article) {
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

                Divider()
            } else {
                ArticleSpeechCacheDeleteMenuItem(sourceID: article.id, speech: speech)
            }

            Button {
                findState.show()
            } label: {
                Label("Find in Reader", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: .command)

            if supportsReaderZoom(article) {
                Button("Zoom In") { zoomIn(article) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") { zoomOut(article) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { resetZoom(article) }
                    .keyboardShortcut("0", modifiers: .command)
            }

            if showsOriginalPageColorsToggle(for: article) {
                Toggle(isOn: $originalPageColors) {
                    Label("Original Page Colors", systemImage: "circle.lefthalf.filled")
                }
                .help("Show this page as it was published instead of darkening it")
            }

            // A pop-out Reader belongs to no Studio window: it files into the
            // notebook of the Studio window used last.
            ReaderNotebookMembershipButton(article: article, windowState: nil)
            SourceNotebooksMenuSection(rowID: vm.canonicalSourceID(article.id), windowState: nil)

            if article.sourceType == .book {
                Button {
                    logSourcesAsListened([article])
                } label: {
                    Label("Log Chapter as Listened", systemImage: "headphones")
                }
            }

            if usesEmbeddedBrowser(article),
               (article.sourceType == .paper && article.localFilePath == nil)
                || WebPagePolicy.awaitsDocumentPDF(
                    sourceType: article.sourceType,
                    isUnreadable: article.hasPaywallMarker || article.state == .error
                ) {
                Button {
                    articleReaderChrome.downloadPDF?()
                } label: {
                    Label("Download PDF", systemImage: "arrow.down.doc")
                }
            }
        } label: {
            RowMoreActionsLabel()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .hoverHighlight()
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More reader actions")
        .bookContentsPopover(
            isPresented: $isBookContentsPresented,
            navigation: bookNavigationBridge.navigation,
            navigate: bookNavigationBridge.navigate(to:),
            logListened: logBookItemsAsListened,
            goToPage: bookGoToPage
        )
    }

    @ViewBuilder
    private func readerContextMenu(for article: StudioArticle) -> some View {
        if hasSelectedReaderText {
            Button {
                explainSelectedText(for: article)
            } label: {
                Label("Chat About Selection", systemImage: "text.bubble")
            }
        }

        if ArticleSpeechContent.canAttemptRead(article) {
            Button {
                startTextToSpeech(article)
            } label: {
                Label("Text to Speech", systemImage: "speaker.wave.2")
            }
        }

        if URL(string: article.url) != nil {
            Button {
                openInSafari(article)
            } label: {
                Label(openInSafariMenuLabel(for: article), systemImage: "safari")
            }
        }

        if article.sourceType == .paper && !article.isPaywalled {
            Button {
                Task { await vm.markPaywalled(article) }
            } label: {
                Label("Mark Paper as Paywalled", systemImage: "lock.doc")
            }
        }

        if article.cachedSupportsReadTracking {
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

        VideoWatchedMenuItems(article: article)
    }

    private func startTextToSpeech(_ article: StudioArticle) {
        speech.listen(to: article)
    }

    private func openInSafari(_ article: StudioArticle) {
        guard let url = currentBrowserURL(for: article) else { return }
        BrowserService.open(url, discoveryOrigin: article.discoveryOrigin, preference: .safari)
    }

    private func addableLibraryPageURL(for article: StudioArticle) -> URL? {
        guard let currentURL = currentBrowserURL(for: article),
              currentURL.hasWebScheme,
              libraryPageKey(currentURL) != SourceDiscovery.normalizedURL(article.url) else {
            return nil
        }
        return currentURL
    }

    private func libraryPageKey(_ url: URL) -> String {
        SourceDiscovery.normalizedURL(url.absoluteString)
    }

    private func addCurrentPageToLibrary(_ url: URL) {
        let pageKey = libraryPageKey(url)
        let state = ReaderAddPageToolbarState(
            isAdding: addingLibraryPageKey == pageKey,
            isSaved: savedLibraryPageKeys.contains(pageKey)
        )
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

            if vm.articles.contains(where: { SourceDiscovery.normalizedURL($0.url) == pageKey }) {
                savedLibraryPageKeys.insert(pageKey)
                vm.showToast("Already in Library")
                return
            }

            let previousError = vm.errorMessage
            do {
                try await vm.addArticle(
                    url: url.absoluteString,
                    revealInReader: false,
                    waitForInitialPaperProcessing: false,
                    reviveArchivedSourceIfNeeded: true
                )
            } catch {
                vm.showToast("Could not add to Library: \(error.localizedDescription)")
                return
            }

            if vm.articles.contains(where: { SourceDiscovery.normalizedURL($0.url) == pageKey }) {
                savedLibraryPageKeys.insert(pageKey)
                if let errorMessage = vm.errorMessage,
                   errorMessage != previousError {
                    vm.showToast(errorMessage)
                } else {
                    vm.showToast("Added to Library")
                }
                return
            }

            if let errorMessage = vm.errorMessage,
               errorMessage != previousError {
                if errorMessage.localizedCaseInsensitiveContains("already") {
                    savedLibraryPageKeys.insert(pageKey)
                }
                vm.showToast(errorMessage)
                return
            }

            vm.showToast("Could not add to Library")
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
        guard !article.cachedHasRemotePDFURL,
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

    private func hasAttachedPaywallText(_ article: StudioArticle) -> Bool {
        article.isPaywalled && article.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func supportsReaderZoom(_ article: StudioArticle) -> Bool {
        usesEmbeddedBrowser(article)
            || article.cachedHasRemotePDFURL
            || article.isPDF
            || article.cachedIsEPUBChapter
            || article.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func hasBrowserURL(_ article: StudioArticle) -> Bool {
        article.url.hasPrefix("http://") || article.url.hasPrefix("https://")
    }

    private func fetchPodcastTranscriptOnOpenIfNeeded(_ article: StudioArticle) async {
        guard article.fetchesPodcastTranscriptOnOpen else { return }
        await vm.fetchContent(for: article.id)
    }

    private func fetchingSourceView(for article: StudioArticle) -> some View {
        VStack(spacing: 16) {
            ProgressView(article.sourceType == .podcast ? "Fetching transcript..." : "Fetching source...")
            Text(article.sourceType == .podcast ? vm.displayTitle(for: article) : article.url)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Text(vm.displayTitle(for: article))
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

// MARK: - Remote PDF Reader

private struct RemotePDFWindowView: View {
    let articleId: String
    let url: URL
    var landingPageURL: URL? = nil
    let title: String
    let initialPageIndex: Int?
    @Binding var selectedText: String
    let findState: ReaderFindState
    let zoomScale: CGFloat
    /// Page index the learner landed on, with the document's page count so the
    /// view model can turn "page 9 of 10" into a depth for the activity ledger.
    let pageChanged: (Int, Int) -> Void
    let zoomScaleChanged: (CGFloat) -> Void
    let zoomInAction: () -> Void
    let zoomOutAction: () -> Void
    let resetZoomAction: () -> Void
    @Environment(StudioViewModel.self) private var vm
    @State private var document: PDFDocument?
    /// The bytes `document` was read from, for the reader's citation preview.
    @State private var documentData: Data?
    @State private var isLoading = true
    @State private var loadFailure: RemotePDFLoadFailure?
    @State private var isPersistingPDF = false
    @State private var persistedPDFURL: URL?
    @State private var loadRevision = 0

    private var loadTaskID: String {
        "\(url.absoluteString)#\(loadRevision)"
    }

    var body: some View {
        Group {
            if let document {
                PDFKitInlineView(
                    document: document,
                    sourceID: articleId,
                    selectedText: $selectedText,
                    findState: findState,
                    findRevision: findState.searchRevision,
                    zoomScale: zoomScale,
                    initialPageIndex: initialPageIndex,
                    pageChanged: pageChanged,
                    zoomScaleChanged: zoomScaleChanged,
                    zoomInAction: zoomInAction,
                    zoomOutAction: zoomOutAction,
                    resetZoomAction: resetZoomAction,
                    documentData: documentData
                )
            } else if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading PDF…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if let loadFailure {
                RemotePDFFailureView(
                    failure: loadFailure,
                    articleId: articleId,
                    pdfURL: url,
                    landingPageURL: landingPageURL,
                    retry: { loadRevision += 1 }
                )
            }
        }
        .task(id: loadTaskID) { await loadRemotePDF() }
    }

    @MainActor
    private func loadRemotePDF() async {
        isLoading = true
        loadFailure = nil
        document = nil
        documentData = nil

        let result = await RemotePDFLoader.fetch(url)
        guard !Task.isCancelled else { return }

        switch result {
        case .failure(let failure):
            isLoading = false
            loadFailure = failure
        case .success(let data):
            guard let doc = await AsyncPDFDocumentLoader.load(data: data) else {
                guard !Task.isCancelled else { return }
                isLoading = false
                loadFailure = .unreadable
                return
            }
            guard !Task.isCancelled else { return }
            document = doc
            documentData = data
            isLoading = false
            await persistPDFDataIfNeeded(data)
        }
    }

    @MainActor
    private func persistPDFDataIfNeeded(_ data: Data) async {
        guard persistedPDFURL != url, !isPersistingPDF else { return }
        // Keeping the file attaches it as a paper — its text becomes the whole
        // PDF's. Only a paper may be filed that way on the reader's say-so; a
        // document or an excerpt handed in with a PDF URL keeps its type and
        // its text (2026-09-23: one abstract became the whole abstracts page).
        guard vm.articles.first(where: { $0.id == articleId })?.sourceType == .paper else { return }
        isPersistingPDF = true
        defer { isPersistingPDF = false }

        do {
            try await vm.attachDownloadedPDFData(to: articleId, data: data, sourceURL: url)
            persistedPDFURL = url
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "RemotePDFWindowView")
                .error("Failed to save remote PDF for \(articleId, privacy: .public): \(error.localizedDescription)")
        }
    }
}

#endif
