import AppKit
import CoreImage
import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import WebKit

struct YouTubeSeekRequest: Equatable {
    let id: UUID
    let seconds: Double
    /// Play from the moment (a transcript row, a chapter, a citation), or hold
    /// there paused (a walkthrough step, read with the slide on screen).
    let plays: Bool

    init(seconds: Double, plays: Bool = true) {
        self.id = UUID()
        self.seconds = seconds
        self.plays = plays
    }
}

/// Loads the reader's own video again after the watch page moved on by itself
/// to a lecture the course's gate holds back (docs/courses-design.md). Each
/// request is spent once.
struct YouTubeReturnToSourceRequest: Equatable {
    let id = UUID()
}

/// Pauses the watch page's player: the learner began typing a question about
/// the video in the chat beside it (`ReaderVideoPauseRequest`). Each request
/// is spent once; one that arrives before the page is ready finds nothing
/// playing and is dropped.
struct YouTubePauseRequest: Equatable {
    let id = UUID()
}

/// A transcript section heading with a known start time — the reader's
/// equivalent of a talk page's table-of-contents entry.
struct YouTubeTranscriptChapter: Identifiable {
    let index: Int
    let title: String
    let seconds: Double

    var id: Int { index }

    var menuTitle: String {
        "\(YouTubeTranscriptTime.display(seconds))   \(title)"
    }
}

/// Slim bar under the theater-mode player: the live caption line keeps the
/// transcript's thread while the transcript itself is hidden.
struct TheaterBar: View {
    let playbackTime: Double?
    let activeCaption: String?
    let exitAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let playbackTime {
                Text(YouTubeTranscriptTime.display(playbackTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(activeCaption ?? "")
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                exitAction()
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(.hoverWash(inset: -3))
            .help("Exit theater view")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Shows YouTube embed player on top and scrollable transcript below.
/// Falls back to a "Watch on YouTube" link if embedding is unavailable.
struct YouTubeVideoReaderView: View {
    let article: StudioArticle
    @Binding var selectedText: String
    @Binding var currentWatchPageURL: URL?
    let findState: ReaderFindState
    let navigationTarget: SourceSearchBestMatch?
    let zoomScale: CGFloat
    var readerTheme: ReaderColorTheme = .system
    let zoomInAction: () -> Void
    let zoomOutAction: () -> Void
    let resetZoomAction: () -> Void
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    /// Where this video's commands go for the Reader's ⋯ › Video; nil in a
    /// host with no ⋯ to list them.
    @Environment(ReaderMenuCommands.self) private var menuCommands: ReaderMenuCommands?
    @State private var playbackTime: Double?
    /// The same position, handed to the transcript as an object so its rows are
    /// not rebuilt by the tick. This reader still reads `playbackTime` in its
    /// own body — the chapter menu and the theater bar name the moment — so it
    /// keeps both; the transcript takes only this.
    @State private var playhead = TranscriptPlayhead()
    /// Whether the watch page's player is paused, as it last reported; nil
    /// until it has. Registered with the playhead for the chat beside it.
    @State private var isPlayerPaused: Bool?
    @State private var pauseRequest: YouTubePauseRequest?
    @State private var transcriptSeekRequest: YouTubeSeekRequest?
    /// Papers found on this video's slides at ingest. Loaded once per source.
    @State private var citedPapers: [VideoCitedPaper] = []
    @State private var showsCitedPapersList = false
    @State private var isExtractingCitedPapers = false
    /// True while the opt-in Show Slides capture is running for this video.
    @State private var isExtractingSlides = false
    /// Set when a Show Slides attempt turned up nothing, so the ⋯ stops
    /// offering a capture that already came back empty. Reset when a new video
    /// opens (a fresh reader instance, cleared on `article.id` change).
    @State private var slideExtractionAttempted = false
    /// Slide currently being read on its own, so only its thumb shows progress.
    @State private var scanningSlideID: Int?
    // Transcript parsing (tens of KB) is expensive; parse once off-main into these caches,
    // keyed by content signature, instead of re-parsing in the render body each frame.
    @State private var parsedSlideContent: YouTubeSlideContent?
    @State private var displayTranscript: YouTubeTranscriptDisplayParser.Result?
    @State private var isTheaterMode = false
    /// Transcript hidden outright to give the whole pane to the video — a lighter
    /// alternative to theater view (no live-caption line, no sources-panel
    /// takeover). Transient per opened video, like theater mode, so a new video
    /// always opens with its transcript showing.
    @State private var isTranscriptHidden = false
    /// Duration reported by the watch page's video element.
    @State private var videoDuration: Double?
    /// Live watch-progress tracker for the open video; persisted on a coarse
    /// cadence through `flushWatchProgressIfDue` and flushed on close.
    @State private var watchProgress: VideoWatchProgress?
    /// Last progress handed to the persistence layer, so continuous playback
    /// writes the locator every ~30s of movement instead of on every time tick.
    @State private var lastFlushedWatchProgress: VideoWatchProgress?

    @State private var returnToSourceRequest: YouTubeReturnToSourceRequest?
    /// A lecture the player tried to move on to by itself — YouTube's
    /// autoplay, or the playlist the course came from — that the course's
    /// gate holds back until a quiz is completed. The card over the player says
    /// which quiz opens it.
    @State private var courseLockNotice: CourseLock?

    private var pendingCitedPaperCount: Int {
        citedPapers.filter { $0.status == .pending }.count
    }

    /// Whether this video's slides have been captured and are on screen. Drives the
    /// ⋯ › Video's two-step slide flow: capture (Show Slides) comes first, then
    /// reading them for papers (Extract Papers).
    private var hasExtractedSlides: Bool {
        !(currentParse?.slides.displaySlides.isEmpty ?? true)
    }

    private static let minVideoHeight: CGFloat = 160
    private static let minTranscriptHeight: CGFloat = 200
    private static let minVideoPaneWidth: CGFloat = 320
    private static let minTranscriptPaneWidth: CGFloat = 380
    /// Draggable divider between the side-by-side columns.
    private static let sideBySideHandleWidth: CGFloat = 8
    /// Below this pane width the side-by-side preference falls back to stacked —
    /// neither column would be usable. Derived from the column minimums so the
    /// gate can never turn the layout down over room the layout doesn't need.
    private static let minSideBySidePaneWidth: CGFloat =
        minVideoPaneWidth + minTranscriptPaneWidth + sideBySideHandleWidth

    /// Persisted video-pane height as a fraction of the reader pane; 0 means auto.
    /// The user drags the divider under the video to change it and double-clicks
    /// the divider to go back to auto.
    @SyncedStorage(wrappedValue: 0, "reader.youtubeVideoPaneFraction") private var storedVideoFraction: Double
    /// Live height while the divider is being dragged; nil when idle.
    @State private var draggedVideoHeight: CGFloat?
    @State private var dragStartVideoHeight: CGFloat?

    /// Layout choice: transcript beside the video instead of below it. On by
    /// default — a talk's slides and the words that go with them deserve as
    /// much of the pane as the player. The key is versioned because the old
    /// one holds the opt-in era's `false` for anyone who ever hit the toggle.
    @SyncedStorage(wrappedValue: true, "reader.youtubeTranscriptBesideVideo") private var videoBesideTranscript: Bool
    /// Persisted video-column width as a fraction of the reader pane; 0 means auto.
    @SyncedStorage(wrappedValue: 0, "reader.youtubeVideoPaneWidthFraction") private var storedVideoWidthFraction: Double
    /// Live width while the side-by-side divider is being dragged; nil when idle.
    @State private var draggedVideoWidth: CGFloat?
    @State private var dragStartVideoWidth: CGFloat?

    /// Height of the video pane. `watchPageChromeStyleScript` pins the watch-page
    /// player to fill the web view exactly and letterbox inside it, so any split is
    /// all video and the transcript starts at its bottom edge; this only decides
    /// how the reader divides the pane. Auto fits 16:9 to the width but never takes
    /// more than just over half the pane — a wide pane letterboxes the video rather
    /// than squeezing the transcript into a sliver.
    private func videoHeight(in size: CGSize) -> CGFloat {
        let height: CGFloat
        if let draggedVideoHeight {
            height = draggedVideoHeight
        } else if storedVideoFraction > 0 {
            height = size.height * CGFloat(storedVideoFraction)
        } else {
            height = min(size.width * 9.0 / 16.0, size.height * 0.55)
        }
        return Self.clampedVideoHeight(height, in: size)
    }

    private static func clampedVideoHeight(_ height: CGFloat, in size: CGSize) -> CGFloat {
        let maxHeight = max(minVideoHeight, size.height - minTranscriptHeight)
        return min(max(height, minVideoHeight), maxHeight)
    }

    /// Split-view style divider between video and transcript: drag to resize,
    /// double-click to return to the automatic split.
    private func videoResizeHandle(in size: CGSize) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 8)
            .frame(maxWidth: .infinity)
            .overlay { Divider() }
            .contentShape(Rectangle())
            .cursor(.resizeUpDown)
            .onTapGesture(count: 2) { storedVideoFraction = 0 }
            .gesture(
                // Global space: the handle moves with the video's bottom edge while
                // dragging, so a local-space translation would feed back into itself
                // and stutter.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartVideoHeight ?? videoHeight(in: size)
                        dragStartVideoHeight = start
                        draggedVideoHeight = Self.clampedVideoHeight(start + value.translation.height, in: size)
                    }
                    .onEnded { _ in
                        if let height = draggedVideoHeight, size.height > 0 {
                            storedVideoFraction = Double(height / size.height)
                        }
                        dragStartVideoHeight = nil
                        draggedVideoHeight = nil
                    }
            )
    }

    /// Width of the video column in the side-by-side layout. The player fills
    /// and letterboxes inside whatever box it gets, so this only splits the pane.
    private func videoWidth(in size: CGSize) -> CGFloat {
        let width: CGFloat
        if let draggedVideoWidth {
            width = draggedVideoWidth
        } else if storedVideoWidthFraction > 0 {
            width = size.width * CGFloat(storedVideoWidthFraction)
        } else {
            width = size.width * 0.5
        }
        return Self.clampedVideoWidth(width, in: size)
    }

    private static func clampedVideoWidth(_ width: CGFloat, in size: CGSize) -> CGFloat {
        let maxWidth = max(minVideoPaneWidth, size.width - minTranscriptPaneWidth)
        return min(max(width, minVideoPaneWidth), maxWidth)
    }

    /// The side-by-side counterpart of `videoResizeHandle`: a vertical divider
    /// between video and transcript columns, dragged horizontally.
    private func videoWidthResizeHandle(in size: CGSize) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: Self.sideBySideHandleWidth)
            .frame(maxHeight: .infinity)
            .overlay {
                // A ZStack-context Divider draws horizontally; the column split
                // needs an explicit vertical hairline.
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
            }
            .contentShape(Rectangle())
            .cursor(.resizeLeftRight)
            .onTapGesture(count: 2) { storedVideoWidthFraction = 0 }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartVideoWidth ?? videoWidth(in: size)
                        dragStartVideoWidth = start
                        draggedVideoWidth = Self.clampedVideoWidth(start + value.translation.width, in: size)
                    }
                    .onEnded { _ in
                        if let width = draggedVideoWidth, size.width > 0 {
                            storedVideoWidthFraction = Double(width / size.width)
                        }
                        dragStartVideoWidth = nil
                        draggedVideoWidth = nil
                    }
            )
    }

    private var timedTranscriptTaskID: String {
        let content = article.content ?? ""
        return "\(article.id):\(content.count):\(content.prefix(128).hashValue)"
    }

    /// Parse result for the current content: local `@State` when this view
    /// instance already parsed, otherwise the app-lifetime memo so re-opening a
    /// video renders the transcript on the first frame instead of flashing
    /// "Preparing transcript…" while the parse task re-runs.
    private var currentParse: (slides: YouTubeSlideContent, transcript: YouTubeTranscriptDisplayParser.Result)? {
        if let parsedSlideContent, let displayTranscript {
            return (parsedSlideContent, displayTranscript)
        }
        return TranscriptParseMemos.youtube[timedTranscriptTaskID]
    }

    var body: some View {
        GeometryReader { geo in
            // Side-by-side puts the transcript next to the video. The container
            // switches via AnyLayout so the web view keeps its identity — a
            // structural swap would tear it down and reload the video.
            // Hiding the transcript hands the whole pane to the video. Theater
            // already hides it its own way, so this only applies outside theater.
            let transcriptHidden = isTranscriptHidden && !isTheaterMode
            let sideBySide = videoBesideTranscript
                && !isTheaterMode
                && !transcriptHidden
                && geo.size.width >= Self.minSideBySidePaneWidth
                && URL(string: article.url) != nil
            // Video fills the pane whenever nothing sits beside or below it.
            let videoFillsPane = isTheaterMode || transcriptHidden
            let layout = sideBySide
                ? AnyLayout(HStackLayout(spacing: 0))
                : AnyLayout(VStackLayout(spacing: 0))

            layout {
                // YouTube's iframe embed is blocked often enough that we go straight
                // to the source URL and bridge playback time from the watch page.
                if let watchURL = URL(string: article.url) {
                    YouTubeWatchPageView(
                        watchURL: watchURL,
                        currentTime: $playbackTime,
                        duration: $videoDuration,
                        currentURL: $currentWatchPageURL,
                        seekRequest: transcriptSeekRequest,
                        returnToSourceRequest: returnToSourceRequest,
                        isPaused: $isPlayerPaused,
                        pauseRequest: pauseRequest,
                        initialResumeSeconds: storedWatchProgress?.resumeSeconds,
                        zoomScale: zoomScale,
                        isSavedVideo: { vm.librarySourceID(forURL: $0.absoluteString) != nil }
                    )
                        .frame(width: sideBySide ? videoWidth(in: geo.size) : nil)
                        .frame(height: sideBySide || videoFillsPane ? nil : videoHeight(in: geo.size))
                        .frame(maxHeight: sideBySide || videoFillsPane ? .infinity : nil)
                        // The web view draws no background of its own and the page
                        // paints black; black behind it means the band is a video
                        // stage from the first frame, not app panel waiting for
                        // the page to commit. Kept out of the safe area on
                        // purpose: docked in a window the reader toolbar hangs in
                        // the titlebar band above this player, and a background
                        // that extends into that band (the default) paints over
                        // it — the Reader's back, title, overflow and close were
                        // all gone above a video, leaving a solid black strip.
                        .background(Color.black, ignoresSafeAreaEdges: [])
                        .overlay(alignment: .topTrailing) {
                            // The way back from Hide Transcript (⋯ › Video), on
                            // the video itself, where a hidden transcript leaves
                            // nothing else to press.
                            if transcriptHidden {
                                showTranscriptButton
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if let lock = courseLockNotice {
                                courseLockCard(lock)
                            }
                        }

                    if isTheaterMode {
                        TheaterBar(
                            playbackTime: playbackTime,
                            activeCaption: activeCaptionText,
                            exitAction: { exitTheaterMode() }
                        )
                    } else if sideBySide {
                        videoWidthResizeHandle(in: geo.size)
                    } else if !transcriptHidden {
                        videoResizeHandle(in: geo.size)
                    }
                } else {
                    watchOnYouTubeLink
                        .frame(height: 60)

                    Divider()
                }

                if !isTheaterMode && !transcriptHidden {
                    // Transcript area
                    transcriptSection
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            // The papers list hangs below the Reader's ⋯, where Papers is
            // chosen (⋯ › Video).
            Color.clear
                .frame(width: 1, height: 1)
                .padding(.trailing, 28)
                .allowsHitTesting(false)
                .popover(isPresented: $showsCitedPapersList, arrowEdge: .top) {
                    citedPapersList
                }
        }
        .onChange(of: videoCommandsKey, initial: true) { _, _ in
            publishVideoCommands()
        }
        .onChange(of: isTranscriptHidden, initial: true) { _, _ in
            updateDockedReaderImmersiveState()
        }
        .onChange(of: isTheaterMode, initial: true) { _, _ in
            updateDockedReaderImmersiveState()
        }
        .onChange(of: vm.readerPoppedOut) { _, _ in
            updateDockedReaderImmersiveState()
        }
        .task(id: article.id) {
            citedPapers = await vm.loadCitedPapers(forSourceID: article.id)
        }
        .task(id: article.id) {
            // Selection is not the only way a reader appears: launch restore,
            // synced state, playlist navigation, and pop-out windows can mount
            // it directly. Make the reader uphold the same automatic-fetch
            // contract for every entry path. The view model deduplicates a
            // fetch already started by selection or import.
            guard StudioViewModel.shouldAutomaticallyFetchYouTubeTranscriptOnOpen(article) else {
                return
            }
            await vm.fetchYouTubeTranscript(for: article.id)
        }
        .task(id: timedTranscriptTaskID) {
            let key = timedTranscriptTaskID
            if let cached = TranscriptParseMemos.youtube[key] {
                parsedSlideContent = cached.slides
                displayTranscript = cached.transcript
            } else {
                let raw = article.content ?? ""
                let (slides, transcript) = await Task.detached(priority: .userInitiated) {
                    let parsed = YouTubeSlideContentParser.parse(raw)
                    return (parsed, YouTubeTranscriptDisplayParser.parse(parsed.transcriptContent))
                }.value
                guard !Task.isCancelled else { return }
                TranscriptParseMemos.youtube.store((slides: slides, transcript: transcript), for: key)
                parsedSlideContent = slides
                displayTranscript = transcript
            }
            // Migrate legacy transcripts to the video's real chapters; this is a
            // no-op when the video has no official chapters.
            await vm.refreshOfficialYouTubeChaptersIfNeeded(for: article.id)
        }
        .onChange(of: article.id) { oldID, _ in
            flushWatchProgress(sourceID: oldID)
            windowState.videoPlayheadsOnScreen.removeValue(forKey: oldID)
            watchProgress = nil
            lastFlushedWatchProgress = nil
            videoDuration = nil
            playbackTime = nil
            isPlayerPaused = nil
            isExtractingSlides = false
            slideExtractionAttempted = false
            isTranscriptHidden = false
            exitTheaterMode()
        }
        .onChange(of: chatTimeTarget?.presentationKey) { _, _ in
            applyChatTimeTarget()
        }
        .onChange(of: playbackTime) { _, newValue in
            playhead.time = newValue
            recordPlayback(time: newValue)
            registerPlayheadOnScreen()
        }
        .onChange(of: isPlayerPaused) { _, _ in
            registerPlayheadOnScreen()
        }
        .onChange(of: vm.readerVideoPauseRequest) { _, request in
            // The chat beside the player asked: the learner began typing a
            // question about this video, so it holds the moment they stopped at.
            guard let request, request.sourceID == article.id else { return }
            vm.readerVideoPauseRequest = nil
            guard isPlayerPaused != true else { return }
            pauseRequest = YouTubePauseRequest()
        }
        .onChange(of: currentWatchPageURL) { _, pageURL in
            holdLockedLectureHandoff(pageURL)
        }
        .onChange(of: article.id) { _, _ in
            courseLockNotice = nil
        }
        .onChange(of: videoDuration) { _, _ in
            // Fold a newly learned duration into the tracker right away so the
            // stored fraction becomes meaningful without waiting out the cadence.
            recordPlayback(time: playbackTime)
        }
        .onAppear {
            applyChatTimeTarget()
        }
        .onDisappear {
            withdrawVideoCommands()
            flushWatchProgress(sourceID: article.id)
            windowState.videoPlayheadsOnScreen.removeValue(forKey: article.id)
            windowState.isDockedReaderImmersive = false
        }
    }

    // MARK: Theater mode

    /// The docked player owns the entire Studio width in either video-only
    /// presentation. A popped-out reader already owns its window, so it must
    /// never alter the layout of the main window.
    private func updateDockedReaderImmersiveState() {
        windowState.isDockedReaderImmersive =
            !vm.readerPoppedOut && (isTranscriptHidden || isTheaterMode)
    }

    private func enterTheaterMode() {
        isTheaterMode = true
    }

    /// The moment a chat citation asked this video to open at, while it names
    /// this video: the target outlives one selection, and one aimed at another
    /// source is not this reader's to spend.
    private var chatTimeTarget: ReaderTimeTarget? {
        guard let target = vm.readerTimeTarget, target.sourceID == article.id,
              ReaderRequestWindow.reaches(target.windowID, readerIn: windowState.id) else { return nil }
        return target
    }

    /// Seek the player and move the playhead the way a click on a transcript
    /// row does, then spend the request so a remount does not replay it. The
    /// watch page holds the seek until it has finished loading, so this is safe
    /// to run the moment the reader appears.
    private func applyChatTimeTarget() {
        guard let target = chatTimeTarget else { return }
        transcriptSeekRequest = YouTubeSeekRequest(seconds: target.seconds, plays: target.plays)
        playbackTime = target.seconds
        vm.readerTimeTarget = nil
    }

    private func exitTheaterMode() {
        isTheaterMode = false
    }

    // MARK: Watch progress

    /// Saved progress for this article, through the memoized store. Drives the
    /// initial `t=` resume parameter and seeds the live tracker.
    private var storedWatchProgress: VideoWatchProgress? {
        savedWatchProgress(for: article.id)
    }

    /// The same for any source id: the flush on switching videos runs after
    /// `article` has already moved on to the next one.
    private func savedWatchProgress(for sourceID: String) -> VideoWatchProgress? {
        let fallbackLocator = sourceID == article.id
            ? article.readingPositionLocator
            : vm.articlesById[sourceID]?.readingPositionLocator
        return vm.readingProgressStore.videoWatchProgress(for: sourceID, fallbackLocator: fallbackLocator)
    }

    /// The watch page can SPA-navigate away from the source's video (a channel
    /// link, an end card). Progress must only ever describe `article`, so
    /// tracking pauses while the page's URL points at a different video.
    private var playbackDescribesThisArticle: Bool {
        guard let current = currentWatchPageURL else { return true }
        return YouTubeWatchPageIdentity.namesSameVideo(current.absoluteString, article.url)
    }

    /// Tells the window where this video stands, for the chat beside it: each
    /// message sent there carries the moment, and a question typed while it
    /// plays pauses it (docs/chat-design.md). Only a moment of this video is
    /// registered; while the page shows another, the entry goes.
    private func registerPlayheadOnScreen() {
        guard let time = playbackTime, time.isFinite, time >= 0, playbackDescribesThisArticle else {
            windowState.videoPlayheadsOnScreen.removeValue(forKey: article.id)
            return
        }
        windowState.videoPlayheadsOnScreen[article.id] = ChatOpenPanes.VideoPlayhead(
            seconds: time,
            isPlaying: isPlayerPaused.map { !$0 }
        )
    }

    private func recordPlayback(time: Double?) {
        guard let time, time.isFinite, time >= 0 else { return }
        guard playbackDescribesThisArticle else { return }
        // Joined with the store every time rather than read once: a Mark as
        // Watched or Not Watched can land while the video is open.
        let previous = VideoWatchProgress.continuing(watchProgress, over: storedWatchProgress)
        let updated = previous?.advanced(to: time, durationSeconds: videoDuration)
            ?? VideoWatchProgress(positionSeconds: time, watchedSeconds: time, durationSeconds: videoDuration)
        guard updated != previous else { return }
        watchProgress = updated
        flushWatchProgressIfDue(updated)
    }

    /// Persist when the playhead has moved meaningfully since the last write —
    /// not on every half-second tick. Each flush marks the source record changed
    /// for CloudKit, so the cadence is the sync-churn ceiling.
    private func flushWatchProgressIfDue(_ progress: VideoWatchProgress) {
        if let last = lastFlushedWatchProgress {
            let moved = abs(progress.positionSeconds - last.positionSeconds) >= 30
            let durationLearned = last.durationSeconds == nil && progress.durationSeconds != nil
            let finishedNow = progress.isEssentiallyWatched && !last.isEssentiallyWatched
            guard moved || durationLearned || finishedNow else { return }
        } else {
            // First write waits for real playback: merely opening a video, whose
            // player reports time 0 while paused, must not mark it "in progress".
            guard progress.positionSeconds >= 5 || progress.watchedSeconds >= 5 else { return }
        }
        persist(progress, for: article.id)
    }

    private func flushWatchProgress(sourceID: String) {
        // What the tracker holds unflushed is dropped when a Mark as Not
        // Watched superseded it while the video was open.
        guard let progress = VideoWatchProgress.continuing(watchProgress, over: savedWatchProgress(for: sourceID)),
              watchProgress != nil,
              progress != lastFlushedWatchProgress else { return }
        if lastFlushedWatchProgress == nil {
            // Same gate as the cadence path: closing a video that was opened but
            // never really played must not persist an "in progress" marker.
            guard progress.positionSeconds >= 5 || progress.watchedSeconds >= 5 else { return }
        }
        persist(progress, for: sourceID)
    }

    private func persist(_ progress: VideoWatchProgress, for sourceID: String) {
        guard let encoded = progress.encoded else { return }
        lastFlushedWatchProgress = progress
        vm.updateReadingLocator(for: sourceID, locator: encoded)
    }

    // MARK: Course gate

    /// The course's gate over the player's own moves (docs/courses-design.md):
    /// YouTube's autoplay, or the playlist a course was imported from, hands
    /// the player on to the next lecture by itself — the binge the gate is
    /// there to stop (product owner, 2026-09-27). When the video the page moved to
    /// is a lecture of this lecture's course that a quiz not yet completed holds
    /// back, the player goes back to this lecture and the card says which
    /// quiz opens the next. The reader does not follow it there either
    /// (`SourceReaderPanel.followWatchPageToSavedVideo`).
    private func holdLockedLectureHandoff(_ pageURL: URL?) {
        guard let movedTo = YouTubeWatchPageIdentity.videoNavigatedAwayFrom(
                  sourceURL: article.url,
                  livePageURL: pageURL
              ),
              let sourceID = vm.librarySourceID(forURL: movedTo.absoluteString),
              sourceID != article.id,
              let lock = vm.courseLock(forSourceID: sourceID, alongside: article.id) else { return }
        courseLockNotice = lock
        returnToSourceRequest = YouTubeReturnToSourceRequest()
    }

    private func courseLockCard(_ lock: CourseLock) -> some View {
        HStack(alignment: .center, spacing: StudioDesign.Spacing.medium) {
            Image(systemName: "lock.fill")
                .zoomedSystemFont(size: 15, weight: .semibold)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("The next lecture is locked")
                    .zoomedSystemFont(size: 13, weight: .semibold)
                Text("Pass \(lock.quizTitle) to open it.")
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: StudioDesign.Spacing.small)
            Button("Take Quiz") {
                courseLockNotice = nil
                vm.inWindow(windowState) { vm.takeCourseQuiz(lock.quizID) }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("studio.reader.courseLock.takeQuiz")
            Button {
                courseLockNotice = nil
            } label: {
                Image(systemName: "xmark")
                    .zoomedSystemFont(size: 11, weight: .semibold)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
            .help("Dismiss")
        }
        .padding(StudioDesign.Spacing.medium)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(StudioDesign.Spacing.medium)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.reader.courseLock")
    }

    @ViewBuilder
    private var transcriptSection: some View {
        if let content = article.content, !content.isEmpty {
            if let entry = currentParse {
            let parsed = entry.slides
            let transcript = entry.transcript
            VStack(spacing: 0) {
                TranscriptFindBar(state: findState)
                transcriptHeader(chapters: Self.chapters(in: transcript.segments))
                if transcript.segments.isEmpty {
                    InlineTextReaderView(
                        content: parsed.transcriptContent,
                        sourceID: article.id,
                        selectedText: $selectedText,
                        findState: findState,
                        findRevision: findState.searchRevision,
                        navigationTarget: navigationTarget,
                        zoomScale: zoomScale,
                        readerTheme: readerTheme,
                        zoomInAction: zoomInAction,
                        zoomOutAction: zoomOutAction,
                        resetZoomAction: resetZoomAction
                    )
                } else {
                    NativeTranscriptReaderView(
                        article: article,
                        segments: transcript.segments,
                        layout: transcript.layout,
                        kicker: "YouTube transcript",
                        metadata: transcript.layout == .speakerTurns
                            ? "\(transcript.segments.count) speaker turns"
                            : "\(transcript.segments.count) sections",
                        placeholderLabel: "Video",
                        selectedText: $selectedText,
                        findState: findState,
                        findRevision: findState.searchRevision,
                        playhead: playhead,
                        timeSelectionAction: { seconds in
                            transcriptSeekRequest = YouTubeSeekRequest(seconds: seconds)
                            playbackTime = seconds
                        },
                        navigationTarget: navigationTarget,
                        zoomScale: zoomScale,
                        readerTheme: readerTheme,
                        slideFrames: parsed.displaySlides,
                        scanningSlideID: scanningSlideID,
                        slideScanAction: { slide in
                            Task {
                                scanningSlideID = slide.id
                                citedPapers = await vm.extractPapersFromSlide(
                                    sourceID: article.id,
                                    slide: slide
                                )
                                scanningSlideID = nil
                            }
                        },
                        citedPapers: citedPapers,
                        citedPaperImportAction: { paper in
                            Task { citedPapers = await vm.importCitedPaper(paper) }
                        },
                        citedPaperDismissAction: { paper in
                            Task { citedPapers = await vm.dismissCitedPaper(paper) }
                        },
                        citedPaperFindAction: { paper in
                            citedPapers = await vm.findCitedPaper(paper)
                        }
                    )
                }
            }
            } else {
                // Transcript still parsing off-main; brief placeholder until the cache fills.
                ReaderLoadingView(
                    title: "Preparing transcript…",
                    subtitle: "The transcript will appear here in a moment."
                )
            }
        } else if article.state == .fetching {
            ReaderLoadingView(
                title: "Fetching transcript…",
                subtitle: "The transcript will appear here when it finishes."
            )
        } else if let error = article.errorMessage, !error.isEmpty {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .zoomedSystemFont(size: 32)
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Retry Transcript") {
                    Task { await vm.fetchYouTubeTranscript(for: article.id, userInitiated: true) }
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "text.below.photo")
                    .zoomedSystemFont(size: 32)
                    .foregroundStyle(.secondary)
                Text("No transcript yet")
                    .foregroundStyle(.secondary)
                Button("Fetch Transcript") {
                    Task { await vm.fetchYouTubeTranscript(for: article.id, userInitiated: true) }
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Above the transcript: its chapters, a menu that jumps the video, and
    /// what the slides are doing while a capture or a paper read runs. The
    /// rest of what the bar above the transcript held — the slides, their
    /// papers and the transcript's layout — is the Reader's ⋯ › Video since
    /// Quiet chrome (docs/ui-design.md, 2026-10-06), published by
    /// `publishVideoCommands`. With neither, there is no row at all.
    @ViewBuilder
    private func transcriptHeader(chapters: [YouTubeTranscriptChapter]) -> some View {
        let showsChapters = chapters.count >= 2
        if showsChapters || slideWorkStatus != nil {
            HStack(spacing: 8) {
                if showsChapters {
                    chaptersMenu(chapters)
                }
                Spacer(minLength: 0)
                if let status = slideWorkStatus {
                    ProgressView()
                        .controlSize(.small)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    /// Compact stand-in for the talk pages' table of contents: lists the
    /// transcript's sections, marks the one under the playhead, and jumps the
    /// video on selection. Quiet text, not a bordered button.
    private func chaptersMenu(_ chapters: [YouTubeTranscriptChapter]) -> some View {
        let current = currentChapter(in: chapters)
        return Menu {
            ForEach(chapters) { chapter in
                Button {
                    transcriptSeekRequest = YouTubeSeekRequest(seconds: chapter.seconds)
                    playbackTime = chapter.seconds
                } label: {
                    if chapter.id == current?.id {
                        Label(chapter.menuTitle, systemImage: "checkmark")
                    } else {
                        Text(chapter.menuTitle)
                    }
                }
            }
        } label: {
            Label(current?.title ?? "Chapters", systemImage: "list.bullet")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.visible)
        .hoverHighlight()
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 260, alignment: .leading)
        .help("Chapters — select one to jump the video there")
    }

    /// While a capture or a paper read started from the ⋯ runs: the one
    /// thing about the slides that is happening now.
    private var slideWorkStatus: String? {
        if isExtractingSlides { return "Capturing slides…" }
        if isExtractingCitedPapers { return "Reading slides for papers…" }
        return nil
    }

    /// The whole video's papers in one place, including the ones that resolved
    /// to nothing and the ones already waved off — neither of which the
    /// transcript's per-slide cards offer, and the dismissed ones are only
    /// restorable here.
    private var citedPapersList: some View {
        VideoCitedPapersList(
            papers: citedPapers,
            onImport: { paper in
                Task { citedPapers = await vm.importCitedPaper(paper) }
            },
            onDismiss: { paper in
                Task { citedPapers = await vm.dismissCitedPaper(paper) }
            },
            onRestore: { paper in
                Task { citedPapers = await vm.restoreCitedPaper(paper) }
            },
            onFind: { paper in
                citedPapers = await vm.findCitedPaper(paper)
            },
            onSeek: { seconds in
                transcriptSeekRequest = YouTubeSeekRequest(seconds: seconds)
                showsCitedPapersList = false
            }
        )
    }

    // MARK: The ⋯'s Video commands

    /// Everything the ⋯ › Video items read, so they are published again only
    /// when one of them changes.
    private struct VideoCommandsKey: Hashable {
        let sourceID: String
        let showsTranscript: Bool
        let paperCount: Int
        let pendingPaperCount: Int
        let hasSlides: Bool
        let slideExtractionAttempted: Bool
        let isCapturingSlides: Bool
        let isExtractingPapers: Bool
        let transcriptBesideVideo: Bool
        let isTranscriptHidden: Bool
        let isTheaterMode: Bool
    }

    /// The ⋯ lists the video's commands while its transcript is there to go
    /// with them, as the bar above the transcript did.
    private var offersVideoCommands: Bool {
        article.content?.isEmpty == false && currentParse != nil
    }

    private var videoCommandsKey: VideoCommandsKey {
        VideoCommandsKey(
            sourceID: article.id,
            showsTranscript: offersVideoCommands,
            paperCount: citedPapers.count,
            pendingPaperCount: pendingCitedPaperCount,
            hasSlides: hasExtractedSlides,
            slideExtractionAttempted: slideExtractionAttempted,
            isCapturingSlides: isExtractingSlides,
            isExtractingPapers: isExtractingCitedPapers,
            transcriptBesideVideo: videoBesideTranscript,
            isTranscriptHidden: isTranscriptHidden,
            isTheaterMode: isTheaterMode
        )
    }

    private func publishVideoCommands() {
        guard let menuCommands else { return }
        guard offersVideoCommands else {
            withdrawVideoCommands()
            return
        }
        // Slides, then the papers they cite — both opt-in per video (see
        // StudioViewModel+SlideCitations). A newly added video has neither until
        // asked: Show Slides captures the deck's frames (no AI), and Extract
        // Papers reads those frames with a vision model. Extract Papers is on
        // offer from the start, not only once the slides are up: it captures
        // them first when they are missing (every course lecture, 2026-09-25).
        // Once papers are found, Papers lists them instead; both retire when a
        // capture came back empty.
        let hasPapers = !citedPapers.isEmpty
        let offersSlideReads = !hasPapers && (hasExtractedSlides || !slideExtractionAttempted)
        menuCommands.video = ReaderVideoCommands(
            sourceID: article.id,
            showSlides: offersSlideReads && !hasExtractedSlides ? { captureSlides() } : nil,
            extractPapers: offersSlideReads ? { extractCitedPapers() } : nil,
            showPapers: hasPapers ? { showsCitedPapersList = true } : nil,
            pendingPaperCount: pendingCitedPaperCount,
            hasSlides: hasExtractedSlides,
            isCapturingSlides: isExtractingSlides,
            isExtractingPapers: isExtractingCitedPapers,
            transcriptBesideVideo: videoBesideTranscript,
            toggleTranscriptPlacement: { toggleTranscriptPlacement() },
            isTranscriptHidden: isTranscriptHidden,
            toggleTranscriptHidden: { isTranscriptHidden.toggle() },
            isTheaterMode: isTheaterMode,
            toggleTheaterMode: {
                if isTheaterMode { exitTheaterMode() } else { enterTheaterMode() }
            }
        )
    }

    /// Only this video's: the next reader may already have published its own.
    private func withdrawVideoCommands() {
        guard let menuCommands, menuCommands.video?.sourceID == article.id else { return }
        menuCommands.video = nil
    }

    /// Step 1: capture the deck's frames on demand. Cheap in AI (none), paid in
    /// bandwidth — it streams the video — so it waits for this command.
    private func captureSlides() {
        Task {
            isExtractingSlides = true
            let shown = await vm.extractSlideFrames(for: article.id)
            // Only a came-back-empty attempt retires the commands; on success
            // the slides now render and Show Slides is gone next pass.
            if !shown { slideExtractionAttempted = true }
            isExtractingSlides = false
        }
    }

    /// Step 2: read the slides for the papers they cite, capturing them first
    /// when they are not on screen yet.
    private func extractCitedPapers() {
        Task {
            isExtractingCitedPapers = true
            await vm.extractPapersFromSlides(for: article.id)
            citedPapers = await vm.loadCitedPapers(forSourceID: article.id)
            isExtractingCitedPapers = false
        }
    }

    private func toggleTranscriptPlacement() {
        videoBesideTranscript.toggle()
    }

    /// Floating restore control shown over the video while the transcript is
    /// hidden. Styled to read over the black video stage in either theme.
    private var showTranscriptButton: some View {
        Button {
            isTranscriptHidden = false
        } label: {
            Label("Transcript", systemImage: "sidebar.right")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .buttonStyle(.hoverWash(in: Capsule(), inset: 0, opacity: 0.14))
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
        .padding(12)
        .help("Show the transcript")
    }

    /// The transcript line under the playhead, for the theater bar.
    private var activeCaptionText: String? {
        guard let time = playbackTime,
              let segments = currentParse?.transcript.segments,
              let index = Self.activeSegmentIndex(at: time, in: segments) else { return nil }
        return segments[index].text
    }

    /// Section headings that carry a start time, in transcript order.
    static func chapters(in segments: [PodcastTranscriptSegment]) -> [YouTubeTranscriptChapter] {
        segments.compactMap { segment in
            guard let heading = segment.heading?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !heading.isEmpty,
                  let seconds = YouTubeTranscriptTime.seconds(from: segment.startTime) else { return nil }
            return YouTubeTranscriptChapter(index: segment.index, title: heading, seconds: seconds)
        }
    }

    /// The chapter under the playhead: the last one starting at or before it.
    private func currentChapter(in chapters: [YouTubeTranscriptChapter]) -> YouTubeTranscriptChapter? {
        guard let time = playbackTime else { return nil }
        return chapters.last { $0.seconds <= time + 0.25 }
    }

    /// Last segment whose start is at or before `time`. Segments carry display
    /// timestamps, so a small tolerance absorbs rounding.
    static func activeSegmentIndex(at time: Double, in segments: [PodcastTranscriptSegment]) -> Int? {
        var result: Int?
        for (offset, segment) in segments.enumerated() {
            guard let start = YouTubeTranscriptTime.seconds(from: segment.startTime) else { continue }
            if start <= time + 0.25 {
                result = offset
            } else {
                break
            }
        }
        return result
    }

    private var watchOnYouTubeLink: some View {
        Link(destination: URL(string: article.url) ?? URL(string: "https://youtube.com")!) {
            Label("Watch on YouTube", systemImage: "play.rectangle")
                .font(.callout.weight(.medium))
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
}

// MARK: - YouTube Watch Page for Reader Panel

/// The watch page a video reader shows can move to a different video on its
/// own — YouTube's autoplay, or the next entry of the playlist a course was
/// imported from — and every part of the reader that has to notice compares
/// the live address against the source's. A watch link carries the playlist it
/// was followed from, the index within it, and a start time, none of which say
/// which video is playing, so the comparison is made on the normalized address.
enum YouTubeWatchPageIdentity {
    /// Whether two addresses name the same video.
    static func namesSameVideo(_ lhs: String, _ rhs: String) -> Bool {
        URLNormalizer.normalize(lhs) == URLNormalizer.normalize(rhs)
    }

    /// The video the page has moved to, or nil while it is still showing the
    /// source's own video (or showing nothing yet).
    static func videoNavigatedAwayFrom(sourceURL: String, livePageURL: URL?) -> URL? {
        guard let livePageURL,
              !namesSameVideo(livePageURL.absoluteString, sourceURL) else { return nil }
        return livePageURL
    }

    /// Whether the address is a page of YouTube's own that shows no video: the
    /// home feed, a channel, a search, subscriptions. The reader never stays on
    /// one (`YouTubeWatchPageView.watchPageStayOnVideoScript`), so it is never
    /// reported as where the page is either. Google's sign-in and YouTube's
    /// consent page live on other hosts and are reported as before.
    static func isYouTubePageWithoutVideo(_ url: URL) -> Bool {
        guard var host = url.host?.lowercased() else { return false }
        for prefix in ["www.", "m."] where host.hasPrefix(prefix) {
            host.removeFirst(prefix.count)
        }
        return host == "youtube.com" && StudioArticle.youtubeVideoId(from: url.absoluteString) == nil
    }

    /// Whether the page may show the video at an address: the source's own, or
    /// one the library holds. A video YouTube chose — autoplay, the next entry
    /// of a Mix the saved link came with — is neither.
    static func mayShow(_ url: URL, sourceURL: URL, isSavedVideo: (URL) -> Bool) -> Bool {
        namesSameVideo(url.absoluteString, sourceURL.absoluteString) || isSavedVideo(url)
    }
}

/// A YouTube video opened from a link — a chat's citation, a page in the Browser
/// or the Reader — that the library does not hold: the one-video player alone,
/// with no transcript, notes or progress, until Add to Sources saves it
/// (`YouTubeContainment`).
struct ExternalYouTubeVideoView: View {
    let watchURL: URL
    let zoomScale: CGFloat
    @Environment(StudioViewModel.self) private var vm
    @State private var playbackTime: Double?
    @State private var duration: Double?
    @State private var pageURL: URL?

    var body: some View {
        YouTubeWatchPageView(
            watchURL: watchURL,
            currentTime: $playbackTime,
            duration: $duration,
            currentURL: $pageURL,
            seekRequest: nil,
            initialResumeSeconds: nil,
            zoomScale: zoomScale,
            isSavedVideo: { vm.librarySourceID(forURL: $0.absoluteString) != nil }
        )
        .background(Color.black)
    }
}

/// A saved address that is one of YouTube's own pages — a channel, a playlist,
/// search — which ForeverLM does not open (`YouTubeContainment`).
struct YouTubePageNotShownView: View {
    var body: some View {
        ContentUnavailableView("ForeverLM opens YouTube one video at a time", systemImage: "play.rectangle")
    }
}

/// A WKWebView that acts on the click which (re)activates the app window instead
/// of swallowing it to become first responder first. The reader's video is one
/// view among the transcript and side panels, so when the user clicks back into
/// the app from elsewhere — or from another pane — that click should toggle
/// play/pause immediately, the way a media player does, not be spent focusing
/// the view and leave the user clicking twice.
final class FirstMouseWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// No Apple Intelligence badge on a selection (`SharedWebKit.allowsWritingToolsAffordance(in:)`).
    @objc(allowsWritingToolsAffordance)
    var allowsWritingToolsAffordance: Bool { SharedWebKit.allowsWritingToolsAffordance(in: self) }
    /// macOS 27.0.1 shows the badge without asking the property above; an empty
    /// selection rect keeps it hidden (`SharedWebKit.unionRectInVisibleSelectedRange(in:)`).
    @objc(unionRectInVisibleSelectedRange)
    var unionRectInVisibleSelectedRange: NSRect { SharedWebKit.unionRectInVisibleSelectedRange(in: self) }
}

/// Lightweight WKWebView wrapper that loads the original YouTube URL directly.
struct YouTubeWatchPageView: NSViewRepresentable {
    let watchURL: URL
    @Binding var currentTime: Double?
    @Binding var duration: Double?
    @Binding var currentURL: URL?
    let seekRequest: YouTubeSeekRequest?
    var returnToSourceRequest: YouTubeReturnToSourceRequest? = nil
    /// Whether the page's player is paused, as the time bridge reports it.
    var isPaused: Binding<Bool?> = .constant(nil)
    /// Pause the player, once per request.
    var pauseRequest: YouTubePauseRequest? = nil
    /// Saved watch position to reopen at, applied as a `t=` parameter on the
    /// watch URL — YouTube's native start-time path, so it works before any of
    /// our scripts can reach the player. Read once per page load.
    let initialResumeSeconds: Double?
    let zoomScale: CGFloat
    /// Whether the library holds the video at an address. The page shows its
    /// own video or one of these — the next lecture of a course the learner
    /// saved — and never one YouTube picked: autoplay, a Mix the saved link
    /// came with, a playlist's next entry nobody saved.
    let isSavedVideo: (URL) -> Bool

    /// The watch URL with the resume position folded in as `t=`. Any `t`/`start`
    /// already on the stored URL loses to the newer saved position.
    static func loadURL(for watchURL: URL, resumeSeconds: Double?) -> URL {
        guard let resumeSeconds, resumeSeconds >= 1,
              var components = URLComponents(url: watchURL, resolvingAgainstBaseURL: false) else {
            return watchURL
        }
        var items = (components.queryItems ?? []).filter { $0.name != "t" && $0.name != "start" }
        items.append(URLQueryItem(name: "t", value: "\(Int(resumeSeconds))s"))
        components.queryItems = items
        return components.url ?? watchURL
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        SharedWebKit.applySharedProcessPool(to: config)
        SharedWebKit.disableSystemWritingTools(on: config)
        config.mediaTypesRequiringUserActionForPlayback = .all
        // WKWebView disables the HTML Fullscreen API by default. YouTube checks
        // that capability before enabling its player button, so without this it
        // reports that the browser does not support fullscreen.
        config.preferences.isElementFullscreenEnabled = true
        config.userContentController.addUserScript(Self.watchPageChromeStyleScript)
        config.userContentController.addUserScript(Self.watchPageAdSuppressionScript)
        config.userContentController.addUserScript(Self.watchPageStayOnVideoScript)
        config.userContentController.addUserScript(Self.watchPageTimeBridgeScript)
        config.userContentController.add(WeakMessageHandler(context.coordinator), name: "youtubePlayer")
        let webView = FirstMouseWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        ArticleReaderZoom.apply(zoomScale, to: webView)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView

        // Hold the first load until the distraction filter is in place, otherwise the
        // masthead and sidebar paint for a frame before the rules attach. Resolution is a
        // disk lookup after the first launch, and the completion always fires — including
        // on failure, where `loadWatchPage` proceeds unfiltered.
        YouTubeDistractionFilter.resolve { ruleList in
            if let ruleList {
                webView.configuration.userContentController.add(ruleList)
            }
            context.coordinator.markFilterResolved()
            context.coordinator.loadWatchPage(in: webView)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        ArticleReaderZoom.apply(zoomScale, to: webView)
        context.coordinator.loadWatchPage(in: webView)
        context.coordinator.seekIfNeeded(in: webView)
        context.coordinator.returnToSourceIfRequested(in: webView)
        context.coordinator.pauseIfRequested(in: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "youtubePlayer")
        webView.loadHTMLString("", baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: YouTubeWatchPageView
        weak var webView: WKWebView?
        private var loadedURL: URL?
        private var isPageReady = false
        private var isFilterResolved = false
        private var lastSeekRequestID: UUID?
        private var pendingSeekRequest: YouTubeSeekRequest?
        private var lastReturnToSourceRequestID: UUID?
        private var lastPauseRequestID: UUID?
        /// The page is on a video it may not show and is being sent back. Its
        /// address is not reported, so its playback time must not be either:
        /// the reader would take it for the source's and rewind its progress.
        private var isOnRefusedVideo = false

        init(parent: YouTubeWatchPageView) {
            self.parent = parent
        }

        /// Called once the content rule list has been attached (or failed to compile).
        /// Until then `loadWatchPage` is a no-op so `updateNSView` cannot race the filter
        /// and load an unfiltered page on the first frame.
        func markFilterResolved() {
            isFilterResolved = true
        }

        func loadWatchPage(in webView: WKWebView, resumingAt resumeSeconds: Double? = nil) {
            self.webView = webView
            guard isFilterResolved else { return }
            guard loadedURL != parent.watchURL else { return }
            // The reader follows the player to a video it moved to by itself,
            // and hands this view the source for the video already on screen.
            // Loading it again would restart it from the top and leave it
            // paused — WKWebView's playback policy refuses to resume without a
            // fresh gesture — so the page that is already playing is adopted
            // instead. Only the address the reader asked for is remembered;
            // the page keeps playing untouched.
            if let live = webView.url,
               YouTubeWatchPageIdentity.namesSameVideo(live.absoluteString, parent.watchURL.absoluteString) {
                loadedURL = parent.watchURL
                updateCurrentURL(live)
                return
            }
            loadedURL = parent.watchURL
            isPageReady = false
            updateCurrentURL(parent.watchURL)
            let target = YouTubeWatchPageView.loadURL(
                for: parent.watchURL,
                resumeSeconds: resumeSeconds ?? parent.initialResumeSeconds
            )
            webView.load(URLRequest(url: target))
        }

        /// A whole page load — not YouTube's in-page moves, which the
        /// stay-on-video script holds — goes only to this video, a saved one,
        /// or off YouTube (Google's sign-in, the consent page). YouTube's
        /// other pages and the videos it picks are never loaded. On the main
        /// actor: whether a video is saved is the view model's to say.
        @MainActor
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard navigationAction.targetFrame?.isMainFrame != false,
                  let url = navigationAction.request.url,
                  !YouTubeWatchPageIdentity.namesSameVideo(url.absoluteString, parent.watchURL.absoluteString) else {
                return .allow
            }
            switch YouTubeContainment.decision(for: url) {
            case .notYouTube: return .allow
            case .video: return isAllowedVideo(url) ? .allow : .cancel
            case .refused: return .cancel
            }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            isPageReady = false
            updateCurrentURL(webView.url)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isPageReady = true
            updateCurrentURL(webView.url)
            seekIfNeeded(in: webView)
        }

        func seekIfNeeded(in webView: WKWebView) {
            guard let request = parent.seekRequest else { return }
            if lastSeekRequestID != request.id {
                lastSeekRequestID = request.id
                pendingSeekRequest = request
            }
            guard isPageReady, let pendingSeekRequest else { return }
            self.pendingSeekRequest = nil
            let seconds = max(0, pendingSeekRequest.seconds)
            let secondsLiteral = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), seconds)
            let plays = pendingSeekRequest.plays ? "true" : "false"
            let script = "window.foreverlmSeekYouTubePlayer && window.foreverlmSeekYouTubePlayer(\(secondsLiteral), \(plays));"
            webView.evaluateJavaScript(script)
        }

        /// The page moved on by itself to a lecture the course's gate holds
        /// back: load the reader's own video again, once per request.
        func returnToSourceIfRequested(in webView: WKWebView) {
            guard let request = parent.returnToSourceRequest,
                  lastReturnToSourceRequestID != request.id else { return }
            lastReturnToSourceRequestID = request.id
            loadedURL = nil
            loadWatchPage(in: webView)
        }

        /// Pause the page's video, once per request. A request that arrives
        /// before the page is ready is dropped: nothing is playing yet.
        func pauseIfRequested(in webView: WKWebView) {
            guard let request = parent.pauseRequest, lastPauseRequestID != request.id else { return }
            lastPauseRequestID = request.id
            guard isPageReady else { return }
            webView.evaluateJavaScript(
                "window.foreverlmSetYouTubePlayerPaused && window.foreverlmSetYouTubePlayerPaused(true);"
            )
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            // The bridge runs in the watch page's main frame only
            // (`ScriptMessageSender`); an ad or embed frame is not the player.
            guard message.isFrom(.web),
                  message.name == "youtubePlayer",
                  let body = message.body as? [String: Any],
                  let event = body["event"] as? String else { return }

            if event == "time" {
                guard !isOnRefusedVideo else { return }
                let seconds = body["seconds"] as? Double
                    ?? (body["seconds"] as? NSNumber)?.doubleValue
                guard let seconds else { return }
                let duration = body["duration"] as? Double
                    ?? (body["duration"] as? NSNumber)?.doubleValue
                let paused = body["paused"] as? Bool
                DispatchQueue.main.async {
                    self.parent.currentTime = seconds
                    if let duration, duration.isFinite, duration > 0 {
                        self.parent.duration = duration
                    }
                    if let paused, self.parent.isPaused.wrappedValue != paused {
                        self.parent.isPaused.wrappedValue = paused
                    }
                }
                return
            }

            if event == "location" {
                guard let urlString = body["url"] as? String,
                      let url = URL(string: urlString) else { return }
                updateCurrentURL(url)
                return
            }

            if event == "leftVideo", let webView {
                returnToVideo(in: webView)
                return
            }

            // The page is about to move to another video and waits for the
            // answer (`watchPageStayOnVideoScript`). Only an allowed video is
            // let through; anything else is dropped where it stands. A video
            // id is letters, digits, `-` and `_` only, so it quotes as is.
            if event == "askVideo",
               let urlString = body["url"] as? String,
               let url = URL(string: urlString),
               let videoID = StudioArticle.youtubeVideoId(from: urlString),
               isAllowedVideo(url) {
                webView?.evaluateJavaScript(
                    "window.foreverlmReleaseVideo && window.foreverlmReleaseVideo('\(videoID)');"
                )
                return
            }
        }

        private func isAllowedVideo(_ url: URL) -> Bool {
            YouTubeWatchPageIdentity.mayShow(url, sourceURL: parent.watchURL, isSavedVideo: parent.isSavedVideo)
        }

        /// The page reached a YouTube page it may not show — one with no
        /// video, or a video YouTube picked — by a route the stay-on-video
        /// script did not stop. The history entry it left still holds
        /// YouTube's player, so going back to it resumes the video where it
        /// was, the way Back does in a browser. With no such entry the video is
        /// loaded again from the time it had reached.
        private func returnToVideo(in webView: WKWebView) {
            let history = webView.backForwardList
            let source = parent.watchURL.absoluteString
            if let entry = (history.backList.reversed() + history.forwardList).first(where: {
                YouTubeWatchPageIdentity.namesSameVideo($0.url.absoluteString, source)
            }) {
                webView.go(to: entry)
                return
            }
            loadedURL = nil
            loadWatchPage(in: webView, resumingAt: parent.currentTime)
        }

        private func updateCurrentURL(_ url: URL?) {
            guard let url,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  // The page is on its way back to the video.
                  !YouTubeWatchPageIdentity.isYouTubePageWithoutVideo(url) else { return }
            // A video neither the source nor saved, reached by a route the
            // script could not hold (the player's own autoplay or playlist
            // advance): it is stopped, never reported — so the reader offers no
            // Add to Sources for it — and the page goes back to its video.
            if StudioArticle.youtubeVideoId(from: url.absoluteString) != nil, !isAllowedVideo(url) {
                isOnRefusedVideo = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, let webView = self.webView else { return }
                    webView.evaluateJavaScript("document.querySelectorAll('video').forEach(function(v) { v.pause(); });")
                    self.returnToVideo(in: webView)
                }
                return
            }
            isOnRefusedVideo = false
            DispatchQueue.main.async {
                self.parent.currentURL = url
            }
        }
    }

    /// Reclaims the space the hidden chrome leaves behind and makes the player fill the pane.
    ///
    /// `YouTubeDistractionFilter` can only apply `display: none`; the watch page still lays
    /// the player out for a full browser window. Today's markup renders it into the
    /// `#full-bleed-container` band whose height YouTube caps at
    /// `--ytd-watch-flexy-max-player-height` (`calc(100vh - masthead - padding)`); the
    /// classic watch layout centres a `#player` column sized for a desktop viewport. In the
    /// reader's pane both leave the player smaller than the web view, with page background
    /// filling the difference. Pinning every wrapper in both chains to the full viewport
    /// makes the player exactly the box the reader sized the web view to.
    ///
    /// The page also boots in two stages. Before the polymer app hydrates, the server HTML
    /// carries a skeleton (`#player.skeleton > #player-wrap > #player-api`) that hosts the
    /// *real* player for the first seconds, and an inline boot script
    /// (`yt.flexy.setPlayerlikeElementSize`) sizes `#player-api`/`#player-placeholder`
    /// with inline styles computed for a full watch page — masthead, sidebar, and metadata
    /// space all reserved even though the distraction filter hides them. Without pinning,
    /// that early player floats small in a sea of page background until hydration reparents
    /// it into the flexy chain and the rules above snap it full-bleed. Pinning the skeleton
    /// chain too (`!important` beats the boot script's inline sizes) makes the very first
    /// paint full-bleed, so the hand-off is invisible.
    ///
    /// The page background is solid black rather than transparent: the web view is always
    /// a video stage, so any transient gap — boot, live divider resize — reads as letterbox
    /// instead of a hole in the app. Also suppresses the autoplay countdown so a finished
    /// video does not wander to the next one.
    private static let watchPageChromeStyleScript = WKUserScript(
        source: """
        (function() {
            if (window.__foreverlmWatchPageChromeInstalled) { return; }
            window.__foreverlmWatchPageChromeInstalled = true;

            var css = [
                'ytd-app, #page-manager, ytd-watch-flexy {',
                '  margin: 0 !important; padding: 0 !important;',
                '  background: transparent !important;',
                '}',
                'ytd-watch-flexy #columns, ytd-watch-flexy #primary, ytd-watch-flexy #primary-inner {',
                '  margin: 0 !important; padding: 0 !important;',
                '  max-width: none !important; min-width: 0 !important; width: 100% !important;',
                '}',
                // The web view is the exact box the video should occupy, so every
                // wrapper down to the player is pinned to the full viewport.
                // `max-height: none` lifts YouTube's viewport-derived player cap;
                // 100vh (not aspect-ratio) keeps the player inside the pane even
                // when the reader had to grant less than 16:9, letting the video
                // letterbox instead of clipping the controls. Both watch layouts
                // (full-bleed band and classic #player column) are present in the
                // DOM with one of them empty, so only the chain actually hosting
                // the player is stretched — a 100vh empty sibling above it would
                // push the video off-screen.
                '#full-bleed-container:has(#movie_player), #player-full-bleed-container:has(#movie_player),',
                '#player:has(#movie_player), #player-container-outer:has(#movie_player), #player-container-inner:has(#movie_player) {',
                '  margin: 0 !important; padding: 0 !important;',
                '  max-width: none !important; width: 100% !important;',
                '  height: 100vh !important; max-height: none !important; min-height: 0 !important;',
                '}',
                '#player-container, ytd-player, ytd-player #container, #movie_player, .html5-video-player, .html5-video-container {',
                '  margin: 0 !important; padding: 0 !important;',
                '  inset: 0 !important;',
                '  width: 100% !important; height: 100% !important;',
                '  max-height: none !important; min-height: 0 !important;',
                '}',
                // The player chrome is transparent (ytp-transparent) so letterbox
                // bars would show the page background; solid black keeps them and
                // load flashes looking like video.
                '#movie_player {',
                '  background: #000 !important;',
                '}',
                // YouTube sizes the video element inline to letterbox it inside the
                // player; `contain` reproduces that for the odd non-16:9 upload without
                // letting it dictate the box.
                '#movie_player video, video.video-stream {',
                '  width: 100% !important; height: 100% !important;',
                '  left: 0 !important; top: 0 !important;',
                '  object-fit: contain !important;',
                '}',
                // Pre-hydration boot skeleton: the server HTML hosts the real
                // player in #player.skeleton > #player-wrap > #player-api for
                // the first seconds, and an inline boot script sizes
                // #player-api/#player-placeholder with inline styles that
                // reserve room for the (hidden) masthead, sidebar, and
                // metadata. Pin the whole skeleton chain to the viewport —
                // `!important` beats those inline sizes — so the first paint
                // is already full-bleed and hydration's reparenting of the
                // player into the flexy chain above changes nothing visually.
                // The skeleton root keeps pointer-events off so that, should
                // it ever linger after hydration empties it, a viewport-sized
                // box is not sitting over the real player eating clicks;
                // #player-api re-enables them while the player lives here.
                '#player.skeleton {',
                '  position: relative !important;',
                '  margin: 0 !important; padding: 0 !important;',
                '  width: 100vw !important; height: 100vh !important;',
                '  max-width: none !important; max-height: none !important;',
                '  pointer-events: none !important;',
                '}',
                '#player.skeleton #player-wrap, #player.skeleton #player-api, #player.skeleton #player-placeholder {',
                '  position: absolute !important; inset: 0 !important;',
                '  margin: 0 !important; padding: 0 !important;',
                '  width: 100% !important; height: 100% !important;',
                '  max-width: none !important; max-height: none !important;',
                '  border-radius: 0 !important;',
                '}',
                '#player.skeleton #player-api {',
                '  pointer-events: auto !important;',
                '}',
                // The skeleton thumbnail letterboxes like the video frame it
                // stands in for, instead of cropping to fill the box.
                '#player.skeleton #player-placeholder {',
                '  background-color: #000 !important;',
                '  background-size: contain !important;',
                '  background-position: center !important;',
                '  background-repeat: no-repeat !important;',
                '}',
                // Black, not transparent: the web view is always a video
                // stage, so gaps during boot or divider resizes read as
                // letterbox rather than app panel showing through a hole.
                'html, body {',
                '  margin: 0 !important; padding: 0 !important;',
                '  overflow: hidden !important; background: #000 !important;',
                '}',
                // Everything YouTubeDistractionFilter hides, again as a
                // stylesheet: the rule list can fail to compile or attach, and
                // then the recommendations column, the masthead's search and
                // the end-screen wall would all be back. Built from the same
                // list, so the two never drift apart.
                '\(YouTubeDistractionFilter.hiddenSelectors.joined(separator: ", ")) {',
                '  display: none !important;',
                '}'
            ].join('\\n');

            function installStyle() {
                if (document.getElementById('foreverlm-watch-chrome')) { return; }
                var parent = document.head || document.documentElement;
                if (!parent) { return; }
                var style = document.createElement('style');
                style.id = 'foreverlm-watch-chrome';
                style.textContent = css;
                parent.appendChild(style);
            }

            installStyle();
            document.addEventListener('DOMContentLoaded', installStyle);
            // YouTube swaps content nodes on SPA navigation; re-assert if ours went with it.
            window.addEventListener('yt-navigate-finish', installStyle);

            // Autoplay-next is what actually navigates away from the source the
            // reader is synced to, and pausing on 'ended' does not cancel it —
            // the queued autonav still fires. Switching the player's own toggle
            // off does, and the preference persists across videos through the
            // page's cookie, so this settles the whole reader profile after the
            // first video. Re-asserted per SPA navigation in case the user
            // re-enabled it mid-session; the controls build asynchronously,
            // hence the retry loop.
            function disableAutoplayNext(attemptsRemaining) {
                var toggle = document.querySelector('.ytp-autonav-toggle-button');
                if (toggle) {
                    if (toggle.getAttribute('aria-checked') === 'true') { toggle.click(); }
                    return;
                }
                if (attemptsRemaining > 0) {
                    window.setTimeout(function() { disableAutoplayNext(attemptsRemaining - 1); }, 500);
                }
            }
            document.addEventListener('DOMContentLoaded', function() { disableAutoplayNext(40); });
            window.addEventListener('yt-navigate-finish', function() { disableAutoplayNext(40); });

            // Backstop for the frame where autonav was still on: at least stop
            // the finished video from sitting on a suggestion it can act on.
            document.addEventListener('ended', function(event) {
                var video = event.target;
                if (video && typeof video.pause === 'function') { video.pause(); }
            }, true);
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )

    /// Uses YouTube's own Skip control whenever a skippable ad presents one.
    ///
    /// Deliberately do not block ad hosts or media requests here. YouTube can serve the
    /// ad and the requested video through overlapping request paths, so a stale network
    /// rule can strand the player on a black frame. DOM changes only make this helper stop
    /// finding the button, which fails open to normal YouTube playback. The player-state
    /// guard also prevents a future, overly broad selector from clicking an ordinary
    /// playback control outside an ad.
    private static let watchPageAdSuppressionScript = WKUserScript(
        source: """
        (function() {
            if (window.__foreverlmAdSuppressionInstalled) { return; }
            window.__foreverlmAdSuppressionInstalled = true;

            var skipSelectors = [
                '.ytp-ad-skip-button',
                '.ytp-ad-skip-button-modern',
                '.ytp-skip-ad-button',
                'button[class*="ytp-ad-skip"]',
                'button[class*="ytp-skip-ad"]'
            ];
            var attemptScheduled = false;

            function playerIsShowingAd(player) {
                return player && player.classList &&
                    (player.classList.contains('ad-showing') ||
                     player.classList.contains('ad-interrupting'));
            }

            function attemptNativeSkip() {
                attemptScheduled = false;
                try {
                    var player = document.getElementById('movie_player');
                    if (!playerIsShowingAd(player)) { return; }

                    var button = null;
                    for (var index = 0; index < skipSelectors.length; index += 1) {
                        button = player.querySelector(skipSelectors[index]);
                        if (button) { break; }
                    }
                    if (!button || button.disabled || button.getAttribute('aria-disabled') === 'true') {
                        return;
                    }

                    // YouTube sometimes reuses the same button while its ad UI settles.
                    // A few spaced retries cover that without turning DOM churn into a
                    // click loop if a future player ignores synthetic clicks.
                    var now = Date.now();
                    var attempts = Number(button.__foreverlmSkipAttempts || 0);
                    var lastAttempt = Number(button.__foreverlmLastSkipAttempt || 0);
                    if (attempts >= 4 || now - lastAttempt < 750) { return; }
                    button.__foreverlmSkipAttempts = attempts + 1;
                    button.__foreverlmLastSkipAttempt = now;
                    button.click();
                } catch (error) {
                    // Ad suppression is optional; normal playback always wins.
                }
            }

            function scheduleAttempt() {
                if (attemptScheduled) { return; }
                attemptScheduled = true;
                window.requestAnimationFrame(attemptNativeSkip);
            }

            function startObserver() {
                var root = document.documentElement;
                if (!root || window.__foreverlmAdSuppressionObserver) { return; }
                var observer = new MutationObserver(scheduleAttempt);
                observer.observe(root, {
                    subtree: true,
                    childList: true,
                    attributes: true,
                    attributeFilter: ['class', 'disabled', 'aria-disabled']
                });
                window.__foreverlmAdSuppressionObserver = observer;
                scheduleAttempt();
            }

            startObserver();
            document.addEventListener('DOMContentLoaded', startObserver);
            window.addEventListener('yt-navigate-finish', scheduleAttempt);
            document.addEventListener('canplay', scheduleAttempt, true);

            // Event-driven observation is primary. This low-frequency backstop covers
            // player implementations that expose a skip control without mutating DOM.
            window.setInterval(scheduleAttempt, 2000);
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )

    /// Keeps the page on its video, and off every video YouTube picks. The reader
    /// shows one video and nothing else of YouTube — no rabbit hole of
    /// recommendations (product owner, 2026-09-28) — but the watch page is the whole
    /// YouTube app: the miniplayer (the `i` key, or the player's own button)
    /// shrinks the video into a corner over the home feed, a channel or search
    /// link opens that page, and next/previous (Shift-N, Shift-P, the Mac's media
    /// keys) play another video. Each is refused where YouTube starts it,
    /// checked against the live site on 2026-09-28:
    ///
    /// - the miniplayer's own actions never reach the app, so the player stays
    ///   put and the page never leaves for the feed;
    /// - an in-page navigation to one of YouTube's own pages goes through only
    ///   to a watch page, and to another video's only once the coordinator says
    ///   the library holds it (`askVideo`, then `foreverlmReleaseVideo`): the
    ///   hand-off a course playlist makes to its next saved lecture, which the
    ///   reader follows (`SourceReaderPanel.followWatchPageToSavedVideo`) and the
    ///   course gate may send back (`holdLockedLectureHandoff`). Anything else
    ///   stays held. Links off YouTube, Google's sign-in among them, are
    ///   ordinary page loads and untouched;
    /// - the miniplayer and next/previous keys do nothing, and the page offers
    ///   no next or previous track to Control Center.
    ///
    /// YouTube renames its internals often enough that these cannot be the only
    /// guard, and a renamed event is simply not stopped. So should the page land
    /// on a YouTube page that is not a video anyway, it says so (`leftVideo`), and
    /// a video it may not show is caught when its address is reported
    /// (`updateCurrentURL`); either way the coordinator takes it back to the
    /// video (`returnToVideo`).
    private static let watchPageStayOnVideoScript = WKUserScript(
        source: """
        (function() {
            if (window.__foreverlmStayOnVideoInstalled) { return; }
            window.__foreverlmStayOnVideoInstalled = true;

            // The paths YouTube plays a video on; everything else of its own
            // is a feed, a channel, a search or an account page.
            function isVideoPath(path) {
                if (path === '/watch') { return true; }
                var parts = path.split('/');
                return parts.length >= 3 && parts[2].length === 11 &&
                    ['shorts', 'live', 'embed'].indexOf(parts[1]) !== -1;
            }

            // The miniplayer in its two steps: leaving the watch page for it,
            // and moving the player into it once the feed is up.
            var miniplayerActions = ['yt-activate-miniplayer-from-watch-action', 'yt-activate-miniplayer'];
            window.addEventListener('yt-action', function(event) {
                var name = event.detail && event.detail.actionName;
                if (miniplayerActions.indexOf(name) !== -1) { event.stopImmediatePropagation(); }
            }, true);

            // The video a watch address names, or null.
            function videoID(address) {
                try {
                    return new URL(address, window.location.href).searchParams.get('v');
                } catch (error) {
                    return null;
                }
            }

            // Every link inside YouTube's app, the miniplayer's trip home among
            // them, becomes a yt-navigate event that bubbles up to the app; a
            // window capture listener runs before it. Only a watch page is let
            // through — not a Short either, whose player is a feed of more —
            // and a watch page of another video waits for the coordinator.
            var heldNavigation = null;
            window.addEventListener('yt-navigate', function(event) {
                if (event.__foreverlmReleased) { return; }
                var endpoint = event.detail && event.detail.endpoint;
                var metadata = endpoint && endpoint.commandMetadata && endpoint.commandMetadata.webCommandMetadata;
                var url = metadata && typeof metadata.url === 'string' ? metadata.url : '';
                if (url.charAt(0) !== '/' || url.charAt(1) === '/') { return; }
                if (url.split(/[?#]/)[0] !== '/watch') {
                    event.stopImmediatePropagation();
                    return;
                }
                var target = videoID(url);
                if (!target || target === videoID(window.location.href)) { return; }
                event.stopImmediatePropagation();
                heldNavigation = { videoID: target, detail: event.detail, node: event.target };
                try {
                    window.webkit.messageHandlers.youtubePlayer.postMessage({
                        event: 'askVideo',
                        url: new URL(url, window.location.href).href
                    });
                } catch (error) {}
            }, true);

            // The coordinator's yes: the held navigation goes on as YouTube
            // started it, so the player hands over without reloading the page.
            window.foreverlmReleaseVideo = function(id) {
                var held = heldNavigation;
                if (!held || held.videoID !== id) { return; }
                heldNavigation = null;
                var released = new CustomEvent('yt-navigate', { detail: held.detail, bubbles: true, composed: true });
                released.__foreverlmReleased = true;
                var node = held.node && held.node.isConnected ? held.node : document.querySelector('ytd-app');
                if (node) { node.dispatchEvent(released); }
            };

            // Next and previous track — the media keys, Control Center — are
            // YouTube's next video, so the page never registers them.
            try {
                var session = navigator.mediaSession;
                if (session && typeof session.setActionHandler === 'function') {
                    var setActionHandler = session.setActionHandler.bind(session);
                    session.setActionHandler = function(action, handler) {
                        if (action === 'nexttrack' || action === 'previoustrack') { handler = null; }
                        return setActionHandler(action, handler);
                    };
                }
            } catch (error) {}

            window.addEventListener('keydown', function(event) {
                if (event.metaKey || event.ctrlKey || event.altKey) { return; }
                var target = event.target;
                if (target && (target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName || ''))) { return; }
                var key = (event.key || '').toLowerCase();
                var leavesVideo = key === 'mediatracknext' || key === 'mediatrackprevious' ||
                    (event.shiftKey ? (key === 'n' || key === 'p') : key === 'i');
                if (!leavesVideo) { return; }
                event.stopImmediatePropagation();
                event.preventDefault();
            }, true);

            window.addEventListener('yt-navigate-finish', function() {
                if (isVideoPath(window.location.pathname)) { return; }
                try {
                    window.webkit.messageHandlers.youtubePlayer.postMessage({ event: 'leftVideo' });
                } catch (error) {}
            });
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )

    private static let watchPageTimeBridgeScript = WKUserScript(
        source: """
        (function() {
            if (window.__foreverlmWatchPageTimeBridgeInstalled) { return; }
            window.__foreverlmWatchPageTimeBridgeInstalled = true;
            var lastPostedTime = -1;
            var lastPostedURL = '';

            function postCurrentLocation(force) {
                try {
                    var url = window.location.href;
                    if (!force && url === lastPostedURL) { return; }
                    lastPostedURL = url;
                    window.webkit.messageHandlers.youtubePlayer.postMessage({
                        event: 'location',
                        url: url
                    });
                } catch (error) {}
            }

            function postCurrentTime(force) {
                try {
                    // During an ad the video element describes the ad, not the
                    // watched video — reporting it would rewind the transcript
                    // sync and corrupt the saved watch progress.
                    var player = document.getElementById('movie_player');
                    if (player && player.classList &&
                        (player.classList.contains('ad-showing') || player.classList.contains('ad-interrupting'))) { return; }
                    var video = document.querySelector('video');
                    if (!video || !Number.isFinite(video.currentTime)) { return; }
                    // Steady-state playback reports at ~1 Hz, not on every 0.35 s of
                    // progress. Each report crosses the bridge and updates playbackTime,
                    // which re-runs the reader's body and the whole transcript view
                    // (O(segments) work, main thread) — at the old ~3 Hz that churn made
                    // clicking the video to pause/resume feel laggy. Nothing shown needs
                    // finer granularity: the active-segment highlight, caption line, and
                    // chapter marker all move on segment boundaries, and watch progress
                    // flushes on its own coarse cadence. User-driven moments (play, seek)
                    // still report immediately via the force path, so they stay instant.
                    if (!force && Math.abs(video.currentTime - lastPostedTime) < 1.0) { return; }
                    lastPostedTime = video.currentTime;
                    var payload = {
                        event: 'time',
                        seconds: video.currentTime,
                        // The chat beside the player sends the moment with
                        // each message, and whether the video was paused there.
                        paused: !!video.paused
                    };
                    if (Number.isFinite(video.duration) && video.duration > 0) {
                        payload.duration = video.duration;
                    }
                    window.webkit.messageHandlers.youtubePlayer.postMessage(payload);
                } catch (error) {}
            }

            window.foreverlmSeekYouTubePlayer = function(seconds, play) {
                seconds = Number(seconds);
                if (!Number.isFinite(seconds)) { return; }
                seconds = Math.max(0, seconds);

                var attemptsRemaining = 40;
                function attemptSeek() {
                    try {
                        var video = document.querySelector('video');
                        if (video) {
                            video.currentTime = seconds;
                            // Jumping to a moment implies wanting to hear it, like
                            // clicking a paragraph on a talk page. Autoplay policy
                            // may reject before the first real gesture; then this
                            // stays a plain seek. A walkthrough step holds the
                            // moment instead, so its card is read over the slide.
                            try {
                                if (play === false) {
                                    video.pause();
                                } else {
                                    var playPromise = video.play();
                                    if (playPromise && playPromise.catch) { playPromise.catch(function() {}); }
                                }
                            } catch (error) {}
                            postCurrentTime(true);
                            return;
                        }
                    } catch (error) {}

                    attemptsRemaining -= 1;
                    if (attemptsRemaining > 0) {
                        window.setTimeout(attemptSeek, 150);
                    }
                }
                attemptSeek();
            };

            // The chat beside the player pauses it when the learner starts
            // typing a question, so the answer is about the moment they
            // stopped at. Resuming is the learner's own click on the player.
            window.foreverlmSetYouTubePlayerPaused = function(paused) {
                try {
                    var video = document.querySelector('video');
                    if (!video) { return; }
                    if (paused) {
                        video.pause();
                    } else {
                        var playPromise = video.play();
                        if (playPromise && playPromise.catch) { playPromise.catch(function() {}); }
                    }
                    postCurrentTime(true);
                } catch (error) {}
            };

            var originalPushState = history.pushState;
            history.pushState = function() {
                var result = originalPushState.apply(this, arguments);
                postCurrentLocation(true);
                return result;
            };

            var originalReplaceState = history.replaceState;
            history.replaceState = function() {
                var result = originalReplaceState.apply(this, arguments);
                postCurrentLocation(true);
                return result;
            };

            window.addEventListener('popstate', function() { postCurrentLocation(true); });
            window.addEventListener('yt-navigate-finish', function() { postCurrentLocation(true); });
            document.addEventListener('play', function() { postCurrentTime(true); }, true);
            document.addEventListener('pause', function() { postCurrentTime(true); }, true);
            document.addEventListener('seeked', function() { postCurrentTime(true); }, true);
            document.addEventListener('timeupdate', function() { postCurrentTime(false); }, true);
            postCurrentLocation(true);
            // A 1 s backstop for the event listeners above (SPA navigations are
            // already caught immediately by pushState/replaceState/yt-navigate-finish,
            // and playback by 'timeupdate'). Kept at 1 s to match the ~1 Hz reporting
            // cadence rather than waking the bridge twice as often for reports the
            // throttle above would drop anyway.
            window.setInterval(function() {
                postCurrentLocation(false);
                postCurrentTime(false);
            }, 1000);
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )
}
