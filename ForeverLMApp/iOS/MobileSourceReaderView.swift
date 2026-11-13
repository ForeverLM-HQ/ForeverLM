import SwiftUI

struct MobileSourceReaderView: View {
    let source: MobileCloudSource
    /// The notebook the Reader was opened in, when it was: Ask and a
    /// walk file their chats under it (docs/notebooks-design.md, "iPhone").
    var notebook: MobileCloudNotebook? = nil

    @StateObject private var viewModel = MobileSourceReaderViewModel()
    @EnvironmentObject private var audio: MobileAudioReviewViewModel
    @ObservedObject private var offline = MobileOfflineLibrary.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var chatRequest: MobileReaderChatRequest?
    @State private var highlightRequest: MobileSourceHighlightEditorRequest?
    @State private var showsTextToSpeechSettings = false
    @State private var isListenRequestStarting = false
    /// The explainer to open in its own reader, from the Explain control's menu.
    @State private var explainerDestination: MobileExplainerDestination?
    /// The library paper a citation's reference card opened.
    @State private var citedDestination: MobileCitedSourceDestination?
    /// The source's walkthrough, flipped through as cards over the reader.
    @State private var showsWalkthrough = false
    @ObservedObject private var walkthroughGenerator = MobileWalkthroughGenerator.shared
    /// Find inside this source: the bar's state, performed by whichever
    /// content view is on screen. See `MobileReaderFind.swift`.
    @StateObject private var find = MobileReaderFindState()
    /// The top and bottom bars step aside while the learner reads on, and
    /// come back on a scroll up (product owner, 2026-11-12: "it would be nicer
    /// to have even more space to read").
    @StateObject private var chrome = MobileReaderChromeState()
    /// A PDF-split book chapter whose document could not be fetched falls back to
    /// the text reader rather than a dead end.
    @State private var chapterPDFUnavailable = false
    /// A paper with no PDF to show is read as its text.
    @State private var paperReadsAsText = false
    /// A book read whole: its chapter list, to jump to one.
    @State private var showsContents = false

    /// The source the reader is on: in a book read whole, the chapter under the
    /// reading line, which the title, Ask, Listen, Share and the rest act on;
    /// otherwise the source that was opened.
    private var readingSource: MobileCloudSource {
        viewModel.currentChapter ?? source
    }

    var body: some View {
        content
            .navigationTitle(readingSource.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { readerToolbar }
            .toolbar(barsHidden ? .hidden : .automatic, for: .navigationBar, .bottomBar)
            .statusBarHidden(barsHidden)
            .task {
                // The catalog is how an EPUB chapter finds the rest of its book.
                await viewModel.load(source: source, catalog: audio.allSources)
                let kind: SourceActivityKind = switch source.sourceType {
                case "podcast": .listening
                case "video": .watching
                default: .reading
                }
                await audio.recordSourceActivity(sourceID: source.id, kind: kind)
            }
            .task(id: viewModel.currentChapterID) {
                // A chapter the reader scrolls on into is read like one opened
                // from the list, once it stays on screen; one flicked past on the
                // way to another is not. The opened chapter is recorded above.
                guard let chapterID = viewModel.currentChapterID, chapterID != source.id else { return }
                try? await Task.sleep(nanoseconds: Self.chapterActivityDwell)
                guard !Task.isCancelled, viewModel.currentChapterID == chapterID else { return }
                await audio.recordSourceActivity(sourceID: chapterID, kind: .reading)
            }
            .onDisappear {
                // Whatever this reader pushes or returns to has its bars.
                chrome.show()
                viewModel.flushProgress()
                audio.flushPlaybackProgress()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { viewModel.flushProgress() }
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: MobileDesign.Spacing.small) {
                    if find.isPresented {
                        MobileReaderFindBar(state: find)
                    }
                    if let message = viewModel.sessionSaveError {
                        noticeBanner(message, lineLimit: nil) {
                            viewModel.sessionSaveError = nil
                        }
                    }
                    if let message = offline.failureMessage(for: readingSource.id) {
                        noticeBanner(message, lineLimit: 3, identifier: "reader.offlineError") {
                            offline.clearFailure(sourceID: readingSource.id)
                        }
                    }
                    // Text-to-speech failures are not repeated here: the compact
                    // playback bar shows them above every screen, this one
                    // included. Preparation progress is source-scoped and has
                    // no such surface, so it stays.
                    if showsAudioPreparationFeedback {
                        audioPreparationBanner
                    }
                }
            }
            .sheet(item: $chatRequest) { request in
                MobileReaderChatSheet(
                    source: request.source,
                    notebook: notebook,
                    sourceText: request.sourceText,
                    selection: request.selection,
                    onSessionSaveFailure: { [viewModel] message in
                        viewModel.reportSessionSaveError(message)
                    }
                )
                .presentationDetents(chatDetents)
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $highlightRequest) { request in
                MobileSourceHighlightEditor(
                    request: request,
                    // In a book, the chapter the passage is in.
                    sourceID: request.existing?.sourceID ?? request.selection?.chapterID ?? readingSource.id,
                    onSave: { await viewModel.saveHighlight($0) },
                    onDelete: request.existing == nil ? nil : { await viewModel.deleteHighlight(id: $0) }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .navigationDestination(isPresented: $showsTextToSpeechSettings) {
                MobileTextToSpeechSettingsView()
            }
            .navigationDestination(item: $explainerDestination) { destination in
                MobileSourceReaderView(source: destination.source, notebook: notebook)
            }
            .navigationDestination(item: $citedDestination) { destination in
                MobileSourceReaderView(source: destination.source, notebook: notebook)
            }
            .onChange(of: walkthroughGenerator.decks[readingSource.id]?.steps.count) { oldCount, newCount in
                // A walk the learner asked for here opens as soon as its
                // steps are saved; animations land in it while it is open.
                if oldCount == nil, newCount != nil, walkthroughGenerator.isWriting(readingSource.id) {
                    showsWalkthrough = true
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let notice = walkthroughGenerator.notices[readingSource.id] {
                    noticeBanner(notice, lineLimit: 4, identifier: "reader.walkthroughNotice") {
                        walkthroughGenerator.notices[readingSource.id] = nil
                    }
                }
            }
            .fullScreenCover(isPresented: $showsWalkthrough) {
                if let deck = walkthroughDeck {
                    MobileWalkthroughDeckView(
                        source: readingSource,
                        deck: deck,
                        sourceText: viewModel.sourceText,
                        notebook: notebook
                    )
                }
            }
    }

    /// The bars are kept while Find is open, since its bar sits under them.
    private var barsHidden: Bool {
        chrome.isHidden && !find.isPresented
    }

    /// How long a chapter scrolled into stays on screen before it counts as
    /// read today.
    private static let chapterActivityDwell: UInt64 = 1_500_000_000

    /// The walk to open: the one this phone has just written, else the one
    /// the latest catalog carries, else the one the reader was opened with.
    private var walkthroughDeck: MobileWalkthroughDeck? {
        let reading = readingSource
        return walkthroughGenerator.decks[reading.id]
            ?? audio.allSources.first(where: { $0.id == reading.id })?.walkthroughDeck
            ?? reading.walkthroughDeck
    }

    /// True when the reader is rendering text or chapter markup rather than a
    /// document. The font-size controls only mean anything there — PDFKit does its
    /// own zooming.
    private var showsTextReader: Bool {
        (source.sourceType != "paper" || paperReadsAsText) && (!source.isPDFBackedBookChapter || chapterPDFUnavailable)
    }

    @ViewBuilder
    private var content: some View {
        if source.sourceType == "paper", !paperReadsAsText {
            // The Mac reader opens a paper's original document. iOS receives
            // that same shared iCloud file (with sourcePDFAsset as a fallback),
            // so it is the reader rather than a reflowed-text approximation.
            // A paper with no document to open (and not behind a paywall, which says so)
            // is read as its text.
            MobileSourcePDFView(
                source: source,
                highlights: viewModel.highlights,
                onNoPDF: source.isPaywalled ? nil : {
                    paperReadsAsText = true
                    Task { await viewModel.load(source: source, catalog: audio.allSources, readingPaperAsText: true) }
                },
                onCreateHighlight: { openHighlight(selection: $0) },
                onOpenHighlight: { openHighlight(id: $0) },
                find: find,
                chrome: chrome,
                onOpenCitedSource: { citedDestination = MobileCitedSourceDestination(source: $0) }
            )
        } else if source.isPDFBackedBookChapter, !chapterPDFUnavailable {
            // A book imported from a PDF is one file whose chapters are runs of
            // its pages (older imports: one PDF per chapter), and those pages are
            // the only place the chapter's figures, plates and layout exist —
            // extracted text has none of them. Read them the same way the Mac
            // does, and fall through to text if they cannot be fetched or found.
            MobileSourcePDFView(
                source: source,
                highlights: viewModel.highlights,
                onUnavailable: { chapterPDFUnavailable = true },
                onCreateHighlight: { openHighlight(selection: $0) },
                onOpenHighlight: { openHighlight(id: $0) },
                find: find,
                chrome: chrome,
                onOpenCitedSource: { citedDestination = MobileCitedSourceDestination(source: $0) }
            )
        } else {
            switch viewModel.state {
            case .loading:
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .ready(let html):
                MobileReaderWebView(
                    html: html,
                    initialScrollFraction: viewModel.initialScrollFraction,
                    find: find,
                    chrome: chrome,
                    onScrollFractionChange: { fraction in
                        if viewModel.recordScrollFraction(fraction) {
                            Task { await audio.recordSourceConsumption(sourceID: source.id, kind: .reading) }
                        } else if audio.shouldRecordDepth(sourceID: source.id, fraction: fraction) {
                            // How far the learner actually got is the only thing
                            // that distinguishes an article worked through from
                            // one merely opened. Reaching the end is stronger
                            // evidence still, and is handled above.
                            Task {
                                await audio.recordSourceDepth(
                                    sourceID: source.id,
                                    kind: .reading,
                                    fraction: fraction
                                )
                            }
                        }
                    },
                    onAskAboutSelection: { presentChat(selection: $0, chapterID: $1) },
                    highlights: viewModel.highlights,
                    onCreateHighlight: { openHighlight(selection: $0) },
                    onOpenHighlight: { openHighlight(id: $0) },
                    book: viewModel.bookPage,
                    onBookEvent: { handleBookEvent($0) }
                )
                .overlay {
                    if viewModel.isOpeningChapter {
                        ProgressView()
                            .controlSize(.large)
                    }
                }

            case .failed(let message):
                failureView(message)
            }
        }
    }

    /// The book page's reports. Where the reader is and the chapters either side
    /// are the view model's; reaching a chapter's end and how deep the reader got
    /// go to the activity ledger for that chapter, as they would for a chapter
    /// read alone.
    private func handleBookEvent(_ event: MobileBookPageEvent) {
        switch event {
        case .reading(let report):
            let outcome = viewModel.recordBookReading(report)
            for chapterID in outcome.reachedEnd {
                Task { await audio.recordSourceConsumption(sourceID: chapterID, kind: .reading) }
            }
            if let depth = outcome.depth,
               audio.shouldRecordDepth(sourceID: depth.chapterID, fraction: depth.fraction) {
                Task {
                    await audio.recordSourceDepth(
                        sourceID: depth.chapterID,
                        kind: .reading,
                        fraction: depth.fraction
                    )
                }
            }
        case .retry(let edge):
            viewModel.retryBookEdge(edge)
        }
    }

    private func openHighlight(selection: MobileReaderHighlightSelection) {
        highlightRequest = MobileSourceHighlightEditorRequest(existing: nil, selection: selection)
    }

    private func openHighlight(id: String) {
        guard let highlight = viewModel.highlights.first(where: { $0.id == id }) else { return }
        highlightRequest = MobileSourceHighlightEditorRequest(existing: highlight, selection: nil)
    }

    /// One dismissible warning line. The chat sheet's save failure and a failed
    /// offline save both arrive after their own surface is gone, so the reader
    /// is where the user actually sees them.
    @ViewBuilder
    private func noticeBanner(
        _ message: String,
        lineLimit: Int?,
        identifier: String? = nil,
        onDismiss: @escaping () -> Void
    ) -> some View {
        let banner = HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(lineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, MobileDesign.Spacing.large)
        .padding(.vertical, MobileDesign.Spacing.medium)
        .mobileFloatingSurface(cornerRadius: MobileDesign.Radius.compact)
        .padding(.horizontal, MobileDesign.Spacing.medium)
        .padding(.top, MobileDesign.Spacing.small)

        if let identifier {
            banner.accessibilityIdentifier(identifier)
        } else {
            banner
        }
    }

    /// The same phase text and counts the Listen tab shows, so a spinner here
    /// never has to say a bare "Preparing audio…" for a download or for a
    /// generation that is already half done.
    private var audioPreparationBanner: some View {
        let sourceID = readingSource.id
        let progress = audio.textToSpeechGenerationProgress(sourceID: sourceID)
        let download = audio.narrationDownloadProgress(sourceID: sourceID)
        let detail = audio.textToSpeechPreparingSourceID == sourceID
            ? audio.textToSpeechPreparationDetail
            : (audio.isPreparingAudio(sourceID: sourceID) ? "Generating audio…" : nil)
        return HStack(spacing: MobileDesign.Spacing.medium) {
            MobileTextToSpeechProgressIndicator(progress: progress, download: download)
            MobileTextToSpeechProgressText(
                detail: detail,
                progress: progress,
                download: download,
                modelName: audio.textToSpeechModelName(sourceID: sourceID)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            if audio.isPreparingAudio(sourceID: sourceID) {
                MobileTextToSpeechStopButton(audio: audio, sourceID: sourceID)
            }
        }
        .padding(.horizontal, MobileDesign.Spacing.large)
        .padding(.vertical, MobileDesign.Spacing.medium)
        .mobileFloatingSurface(cornerRadius: MobileDesign.Radius.compact)
        .padding(.horizontal, MobileDesign.Spacing.medium)
        .padding(.top, MobileDesign.Spacing.small)
        .accessibilityIdentifier("reader.listenPreparing")
    }

    private func failureView(_ message: String) -> some View {
        // Same reasoning as the PDF reader's failure: a paywalled source never
        // synced any text, and saying so beats a generic fetch error.
        ContentUnavailableView {
            Label(
                source.isPaywalled ? "Behind a Paywall" : "Can't Open This Source",
                systemImage: source.isPaywalled ? "lock" : "exclamationmark.triangle"
            )
        } description: {
            Text(
                source.isPaywalled
                    ? "No text synced for this source. Attach its PDF on your Mac to read it here."
                    : message
            )
        } actions: {
            Button("Try Again") {
                Task { await viewModel.retry() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The bottom bar keeps the reading measure clear and puts the listen, talk
    /// and ask controls in thumb reach; the reader stylesheet already reserves
    /// room for it.
    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if viewModel.isReadingBook {
                // Up beside Find rather than in the bottom bar, which is full on
                // an iPhone; a popover from here on an iPad, a sheet on a phone.
                Button {
                    showsContents = true
                } label: {
                    Label("Contents", systemImage: "list.bullet")
                }
                .accessibilityIdentifier("reader.contents")
                .popover(isPresented: $showsContents) {
                    MobileBookContentsList(
                        title: bookTitle,
                        chapters: viewModel.bookChapters,
                        currentChapterID: viewModel.currentChapterID,
                        onSelect: { viewModel.openChapter($0) }
                    )
                }
            }

            // Find in this source. The text reader has nothing to search until
            // its document is built; the PDF reader's bar opens at once and
            // reports "No matches" until the document is on screen.
            Button {
                find.toggle()
            } label: {
                Label("Find", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(showsTextReader && !viewModel.isReady)
            .accessibilityLabel("Find in this source")
            .accessibilityIdentifier("reader.find")

            MobileSourceManagementMenu(source: readingSource)
        }

        ToolbarItemGroup(placement: .bottomBar) {
            // One button for the text size, not two: with a smaller and a
            // larger button beside the six below, the bar was wider than an
            // iPhone and its first and last buttons were cut off at the
            // screen's edges (seen on a 16e and a 17 Pro Max).
            if showsTextReader {
                textSizeToolbarControl
            }

            Spacer()

            listenToolbarControl

            if walkthroughDeck != nil || MobileWalkthroughGenerator.canWalkThrough(readingSource) {
                MobileWalkthroughToolbarControl(source: readingSource, deck: walkthroughDeck) {
                    showsWalkthrough = true
                }
            }

            if MobileExplainerStatus.isExplainable(readingSource) {
                MobileExplainerToolbarControl(source: readingSource) { explainer in
                    explainerDestination = MobileExplainerDestination(source: explainer)
                }
            }

            // Share… is the first item of the ⋯ menu at the top, so it takes
            // no place here.
            voiceToolbarControl

            Button {
                presentChat(selection: nil, chapterID: nil)
            } label: {
                Label("Ask", systemImage: "text.bubble")
            }
            .disabled(!viewModel.isReady)
        }
    }

    /// Text size: a menu whose two steps stay open while they are tapped, so
    /// going up three sizes is three taps in one place.
    private var textSizeToolbarControl: some View {
        Menu {
            ControlGroup {
                Button {
                    viewModel.decreaseFontSize()
                } label: {
                    Label("Smaller", systemImage: "textformat.size.smaller")
                }
                .disabled(!viewModel.canDecreaseFontSize)
                .accessibilityLabel("Smaller text")

                Button {
                    viewModel.increaseFontSize()
                } label: {
                    Label("Larger", systemImage: "textformat.size.larger")
                }
                .disabled(!viewModel.canIncreaseFontSize)
                .accessibilityLabel("Larger text")
            }
            .menuActionDismissBehavior(.disabled)
        } label: {
            Label("Text Size", systemImage: "textformat.size")
        }
        .accessibilityIdentifier("reader.textSize")
    }

    /// Voice mode, as ChatGPT has it: tap to talk about the source out loud;
    /// hold for being quizzed on it, or for gym mode (`MobileRealtimeVoice`).
    private var voiceToolbarControl: some View {
        Menu {
            Button {
                startVoice(.talk)
            } label: {
                Label("Talk About It", systemImage: "waveform")
            }
            Button {
                startVoice(.quiz)
            } label: {
                Label("Quiz Me", systemImage: "questionmark.bubble")
            }
            // Gym mode: ForeverLM explains the source like a podcast and the
            // learner types follow-up questions (product owner, 2026-11-08).
            Button {
                startVoice(.gym)
            } label: {
                Label("Gym Mode", systemImage: "figure.strengthtraining.traditional")
            }
        } label: {
            Label("Voice", systemImage: "waveform")
        } primaryAction: {
            startVoice(.talk)
        }
        .accessibilityLabel("Talk about this source")
        .accessibilityHint("Hold for Quiz Me or Gym Mode.")
        .accessibilityIdentifier("reader.voice")
    }

    private func startVoice(_ opening: RealtimeVoiceOpening) {
        let spoken = readingSource
        let notebook = notebook
        Task { await MobileRealtimeVoice.start(source: spoken, notebook: notebook, opening: opening) }
    }

    /// The book's own title for Contents, from the synced Book record.
    private var bookTitle: String? {
        source.parentGroup.flatMap { audio.collections.booksByID[$0]?.title }
    }

    private var chatDetents: Set<PresentationDetent> {
        // On iPhone the half sheet is the point: the passage stays visible above
        // the answer. There is room for both on a regular-width iPad.
        horizontalSizeClass == .regular ? [.large] : [.medium, .large]
    }

    private var isPreparingAudio: Bool {
        audio.isPreparingAudio(sourceID: readingSource.id)
    }

    /// The narration is coming down from iCloud and has not started playing
    /// yet. Once it plays, the playback bar above every screen carries the
    /// download line, so this banner steps aside.
    private var isDownloadingAudio: Bool {
        audio.narrationDownloadProgress(sourceID: readingSource.id) != nil
            && audio.currentItem?.id != readingSource.id
    }

    /// A `Menu` with a primary action is the native toolbar control for this
    /// split interaction: a tap starts playback and a hold opens settings.
    /// Building the icon from competing tap/long-press gestures leaves a plain
    /// SwiftUI view in the toolbar; UIKit can display it without ever routing
    /// the user's tap to the gesture recognizer.
    private var listenToolbarControl: some View {
        Menu {
            // In a book: every chapter's audio in one go, from the chapter
            // being read, with one price question for the book.
            if let bookID = readingBookID {
                if audio.audiobookGeneration?.bookID == bookID {
                    Button {
                        audio.stopAudiobookGeneration()
                    } label: {
                        Label("Stop Generating Audiobook", systemImage: "stop.circle")
                    }
                } else if !audio.bookChapters(bookID: bookID).allSatisfy({ audio.hasSyncedTextToSpeechAudio(sourceID: $0.id) }) {
                    Button {
                        Task { await audio.requestAudiobook(bookID: bookID) }
                    } label: {
                        Label("Generate Audiobook", systemImage: "books.vertical")
                    }
                }
            }
            Button {
                showsTextToSpeechSettings = true
            } label: {
                Label("Text to Speech Settings", systemImage: "slider.horizontal.3")
            }
        } label: {
            listenToolbarLabel
                .labelStyle(.iconOnly)
                .foregroundStyle(isListenControlDisabled ? Color.secondary : Color.accentColor)
                .frame(
                    minWidth: MobileDesign.Metrics.minimumTouchTarget,
                    minHeight: MobileDesign.Metrics.minimumTouchTarget
                )
                .contentShape(Rectangle())
        } primaryAction: {
            startListening()
        }
            .disabled(isListenControlDisabled)
            .accessibilityLabel(listenControlTitle)
            .accessibilityHint(readingBookID == nil
                ? "Touch and hold to choose the Text to Speech model and voice"
                : "Touch and hold to generate the whole audiobook, or to choose the Text to Speech model and voice")
            .accessibilityIdentifier("reader.listen")
    }

    /// The book the chapter on screen belongs to.
    private var readingBookID: String? {
        guard readingSource.sourceType == "book",
              let bookID = readingSource.parentGroup, !bookID.isEmpty else { return nil }
        return bookID
    }

    private var listenToolbarLabel: some View {
        Label(listenControlTitle, systemImage: listenControlIcon)
    }

    private var listenControlTitle: String {
        let sourceID = readingSource.id
        if audio.currentItem?.id == sourceID { return listenActionTitle }
        if let download = audio.narrationDownloadProgress(sourceID: sourceID) {
            return "Downloading \(download.percentCompleted)%"
        }
        if isListenRequestStarting { return "Preparing" }
        if let progress = audio.textToSpeechGenerationProgress(sourceID: sourceID) {
            return progress.completedChunks == 0 ? "Generating" : "\(progress.percentCompleted)%"
        }
        if isPreparingAudio { return "Preparing" }
        return listenActionTitle
    }

    private var listenControlIcon: String {
        if audio.currentItem?.id == readingSource.id { return listenActionIcon }
        if isDownloadingAudio { return "icloud.and.arrow.down" }
        if isListenRequestStarting { return "hourglass" }
        if audio.textToSpeechGenerationProgress(sourceID: readingSource.id) != nil { return "waveform" }
        if isPreparingAudio { return "hourglass" }
        return listenActionIcon
    }

    private var isListenControlDisabled: Bool {
        (isListenRequestStarting || isPreparingAudio) && audio.currentItem?.id != readingSource.id
    }

    private var showsAudioPreparationFeedback: Bool {
        (isListenRequestStarting && audio.currentItem?.id != readingSource.id)
            || isPreparingAudio
            || isDownloadingAudio
    }

    private func startListening() {
        let sourceID = readingSource.id
        let needsPreparationFeedback = audio.currentItem?.id != sourceID
        if needsPreparationFeedback {
            isListenRequestStarting = true
        }
        Task {
            await audio.toggleTextToSpeech(sourceID: sourceID)
            isListenRequestStarting = false
        }
    }

    private var listenActionTitle: String {
        guard audio.currentItem?.id == readingSource.id else { return "Listen" }
        return audio.isPlaying ? "Pause" : "Resume"
    }

    private var listenActionIcon: String {
        guard audio.currentItem?.id == readingSource.id else { return "headphones" }
        return audio.isPlaying ? "pause.fill" : "play.fill"
    }

    /// Ask about the source on screen, or about a selection in it. On a book page
    /// a selection names its own chapter, which near a chapter break may not be
    /// the one under the reading line.
    private func presentChat(selection: MobileReaderSelection?, chapterID: String?) {
        let chapter = chapterID.flatMap { id in viewModel.bookChapters.first { $0.id == id } }
        let asked = chapter ?? readingSource
        let text = chapter.flatMap { viewModel.text(ofChapter: $0.id) } ?? viewModel.sourceText
        guard !text.isEmpty else { return }
        chatRequest = MobileReaderChatRequest(source: asked, sourceText: text, selection: selection)
    }

}

private struct MobileReaderChatRequest: Identifiable {
    let id = UUID()
    /// The source the chat is about, fixed when it opens: in a book, the chapter.
    let source: MobileCloudSource
    let sourceText: String
    let selection: MobileReaderSelection?
}

/// A book's chapters, the one on screen checked. Choosing one reads on from its
/// top (`MobileSourceReaderViewModel.openChapter`).
private struct MobileBookContentsList: View {
    let title: String?
    let chapters: [MobileCloudSource]
    let currentChapterID: String?
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(chapters) { chapter in
                    let isCurrent = chapter.id == currentChapterID
                    Button {
                        onSelect(chapter.id)
                        dismiss()
                    } label: {
                        HStack(spacing: MobileDesign.Spacing.medium) {
                            Text(chapter.title)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if isCurrent {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(isCurrent ? .isSelected : [])
                    .id(chapter.id)
                }
                .listStyle(.plain)
                .onAppear {
                    if let currentChapterID {
                        proxy.scrollTo(currentChapterID, anchor: .center)
                    }
                }
            }
            .navigationTitle(title ?? "Contents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 320, idealWidth: 380, minHeight: 320, idealHeight: 560)
        .presentationDetents([.medium, .large])
    }
}

/// Owns the chat view model for the lifetime of the sheet so the conversation
/// survives a detent drag or a redraw of the reader behind it.
private struct MobileReaderChatSheet: View {
    @StateObject private var viewModel: MobileChatViewModel
    @EnvironmentObject private var audio: MobileAudioReviewViewModel
    private let sourceID: String

    init(
        source: MobileCloudSource,
        notebook: MobileCloudNotebook?,
        sourceText: String,
        selection: MobileReaderSelection?,
        onSessionSaveFailure: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.sourceID = source.id
        _viewModel = StateObject(
            wrappedValue: MobileChatViewModel(
                source: source,
                sourceText: sourceText,
                selection: selection,
                // Asked inside a notebook, the chat is the notebook's: it is
                // filed under it and listed in its Chat tab.
                notebook: notebook,
                onSessionSaveFailure: onSessionSaveFailure
            )
        )
    }

    var body: some View {
        MobileChatView(viewModel: viewModel)
        .task {
            await audio.recordSourceActivity(sourceID: sourceID, kind: .chat)
        }
    }
}

/// Whether the reader's bars are out of the way. The learner's own scroll down
/// puts them away and a scroll up brings them back, as Safari does; reaching
/// the top or the end of the source brings them back too. A position the
/// reader restores, a Find jump or a chapter loading in moves nothing, since
/// only a finger on the page (or its glide after) counts.
@MainActor
final class MobileReaderChromeState: ObservableObject {
    @Published private(set) var isHidden = false

    private var observations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var lastOffsets: [ObjectIdentifier: CGFloat] = [:]
    /// How far the finger has gone one way since it last turned.
    private var travel: CGFloat = 0
    private var lastChange = Date.distantPast

    /// How far a scroll goes before the bars move: a small wobble while
    /// reading moves nothing.
    private static let threshold: CGFloat = 36
    /// The bars going or coming back shift the page's insets; the offset
    /// change that makes is not the learner's scroll.
    private static let settle: TimeInterval = 0.35

    func show() { setHidden(false) }

    /// Follows this scroll view; calling it again for the same one is free.
    func watch(_ scrollView: UIScrollView) {
        let id = ObjectIdentifier(scrollView)
        guard observations[id] == nil else { return }
        observations[id] = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
            MainActor.assumeIsolated { self?.scrolled(scrollView) }
        }
    }

    private func scrolled(_ scrollView: UIScrollView) {
        let id = ObjectIdentifier(scrollView)
        let offset = scrollView.contentOffset.y
        let previous = lastOffsets[id]
        lastOffsets[id] = offset
        guard let previous else { return }
        // VoiceOver reads the bars' controls; they never go away under it.
        guard !UIAccessibility.isVoiceOverRunning else { return setHidden(false) }
        guard scrollView.isTracking || scrollView.isDecelerating, !scrollView.isZooming,
              Date().timeIntervalSince(lastChange) > Self.settle else {
            travel = 0
            return
        }
        let inset = scrollView.adjustedContentInset
        let top = -inset.top
        let end = scrollView.contentSize.height - scrollView.bounds.height + inset.bottom
        if offset <= top + 1 || (end > top && offset >= end - 1) {
            travel = 0
            return setHidden(false)
        }
        let delta = offset - previous
        if delta == 0 { return }
        if (delta > 0) != (travel > 0) { travel = 0 }
        travel += delta
        if travel > Self.threshold {
            setHidden(true)
        } else if travel < -Self.threshold {
            setHidden(false)
        }
    }

    private func setHidden(_ hidden: Bool) {
        guard isHidden != hidden else { return }
        travel = 0
        lastChange = Date()
        withAnimation(.easeInOut(duration: 0.25)) { isHidden = hidden }
    }
}
