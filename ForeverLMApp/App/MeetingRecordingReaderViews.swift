#if os(macOS)
import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// The in-app playable media behind a meeting session's recording artifact.
///
/// Local-folder imports reference the media file on disk. Google Drive imports
/// carry a stable file URL that is resolved through the plugin's OAuth grant
/// into a disposable local cache before native playback. Read AI sessions have
/// no recording artifact at all.
///
/// Only video counts. A Zoom call recorded without cameras leaves an
/// `audio*.m4a` behind, and putting that through the video pane drew a black
/// box with QuickTime's audio glyph over every camera-off standup — The product owner
/// (2026-09-21): "don't even show these video players". An audio-only session
/// reads as transcript-only: the transcript fills the reader, and the Recording
/// row hands the file to Finder.
enum MeetingRecordingMedia: Equatable {
    /// Recording file on disk — played natively, with transcript time sync.
    case localFile(URL)
    /// Drive-hosted recording — authenticated through the plugin, then
    /// played natively with transcript time sync.
    case googleDrive(original: URL, fileID: String, mimeType: String?, modifiedAt: Date?)

    /// Playable media for a meeting session's artifacts, if any. Pure string
    /// work on the already-loaded artifact rows — no file-system access, so it
    /// is safe to call while routing reader views.
    static func resolve(from artifacts: [MeetingArtifact]) -> MeetingRecordingMedia? {
        for artifact in artifacts where artifact.kind == .recording && !isAudioOnly(artifact) {
            if let path = artifact.localFilePath, !path.isEmpty {
                return .localFile(URL(fileURLWithPath: path))
            }
            if let urlString = artifact.url,
               let url = URL(string: urlString),
               url.host?.lowercased() == "drive.google.com",
               let fileID = GoogleDriveService.fileID(from: urlString) {
                return .googleDrive(
                    original: url,
                    fileID: fileID,
                    mimeType: artifact.mimeType,
                    modifiedAt: artifact.modifiedAt
                )
            }
        }
        return nil
    }

    var supportsTimeSync: Bool {
        true
    }

    /// File extensions a recording can carry without any picture in it. The
    /// Zoom importer types its files by extension, so the MIME check catches
    /// those; the extension list covers artifacts stored before MIME types
    /// were recorded, and Drive files whose type never came back.
    private static let audioOnlyExtensions: Set<String> = [
        "m4a", "mp3", "aac", "wav", "aif", "aiff", "flac", "ogg", "oga", "opus", "caf", "wma"
    ]

    /// Whether a recording artifact is sound with no picture — a recording the
    /// video pane has nothing to show for.
    static func isAudioOnly(_ artifact: MeetingArtifact) -> Bool {
        if let mimeType = artifact.mimeType?.trimmingCharacters(in: .whitespaces).lowercased(),
           !mimeType.isEmpty {
            if mimeType.hasPrefix("audio/") { return true }
            if mimeType.hasPrefix("video/") { return false }
        }
        for candidate in [artifact.localFilePath, artifact.url] {
            guard let candidate, !candidate.isEmpty else { continue }
            let path = URL(string: candidate)?.path ?? candidate
            let ext = (path as NSString).pathExtension.lowercased()
            if !ext.isEmpty { return audioOnlyExtensions.contains(ext) }
        }
        return false
    }
}

/// Which meeting sessions currently have an in-app playable recording, kept as
/// a lock-protected ID set so `ArticleSpeechContent.canAttemptRead` — called
/// from view bodies and from nonisolated speech paths — can consult it without
/// touching the main-actor view model. Rebuilt whenever
/// `StudioViewModel.meetingArtifactsBySourceId` changes (startup load and every
/// import), never polled.
enum MeetingRecordingAvailability {
    private static let lock = AppLock()
    private static var playableSourceIDs: Set<String> = []

    static func update(from artifactsBySourceID: [String: [MeetingArtifact]]) {
        let ids = Set(artifactsBySourceID.compactMap { sourceID, artifacts in
            MeetingRecordingMedia.resolve(from: artifacts) != nil ? sourceID : nil
        })
        lock.lock()
        playableSourceIDs = ids
        lock.unlock()
    }

    static func hasPlayableRecording(sourceID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return playableSourceIDs.contains(sourceID)
    }
}

/// How far into the recording the learner has watched, and what was last
/// written to the source record.
///
/// A reference type on purpose, exactly like `TranscriptScrollMetrics`: this is
/// updated twice a second while a recording plays, and `@State` invalidates its
/// view on every write whether or not the body ever read it. Holding it as
/// `@State` re-rendered the whole meeting reader — transcript included — on
/// every playback tick. Nothing here is read while rendering.
private final class MeetingWatchProgressTracker {
    var current: VideoWatchProgress?
    var lastFlushed: VideoWatchProgress?

    func reset() {
        current = nil
        lastFlushed = nil
    }
}

/// Meeting session reader in the YouTube layout: recording on top, transcript
/// below, split by the same draggable divider (or the transcript beside the
/// recording, by the toggle in the bar above the transcript). Local recordings bridge playback
/// time both ways — the transcript playhead follows the video and clicking a
/// timestamped turn seeks — and persist the same `VideoWatchProgress` locator
/// the YouTube reader uses, so resume and "% watched" behave identically.
/// One press of the offline control. A fresh id each time, so pressing it again
/// after a failure re-runs the task that watches it.
private struct OfflineRecordingRequest: Equatable {
    let id = UUID()
    let removes: Bool
}

struct MeetingRecordingReaderView: View {
    /// The Studio window this reader is drawn in: a moment asked for another
    /// window's Reader is not this one's (`ReaderRequestWindow`).
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    let article: StudioArticle
    let media: MeetingRecordingMedia
    @Binding var selectedText: String
    let findState: ReaderFindState
    let navigationTarget: SourceSearchBestMatch?
    let zoomScale: CGFloat
    var readerTheme: ReaderColorTheme = .system
    let zoomInAction: () -> Void
    let zoomOutAction: () -> Void
    let resetZoomAction: () -> Void

    @Environment(StudioViewModel.self) private var vm
    /// Held as an object, not as `@State`, so the half-second playhead ticks
    /// never re-run this body — and through it the transcript's. See
    /// `TranscriptPlayhead`.
    @State private var playhead = TranscriptPlayhead()
    @State private var videoDuration: Double?
    @State private var seekRequest: YouTubeSeekRequest?
    @State private var playbackError: String?
    @State private var watch = MeetingWatchProgressTracker()
    @State private var citedPapers: [VideoCitedPaper] = []
    @State private var showsCitedPapers = false
    @State private var isFindingPapers = false
    @State private var cachedDriveRecordingURL: URL?
    @State private var driveRecordingError: String?
    /// Set when the load failed in a way only a fresh Google sign-in repairs, so
    /// the pane shows the reconnect card instead of a one-line error. Derived
    /// from the error, never read from the keychain while drawing.
    @State private var driveReconnectHealth: GoogleDriveHealth?
    @State private var isReconnectingDrive = false
    @State private var driveRecordingRetryID = UUID()
    /// Whether this Mac keeps its own copy of the Drive recording; nil until the
    /// check has run, so the control never claims either state early.
    @State private var isAvailableOffline: Bool?
    @State private var isDownloadingOffline = false
    @State private var offlineError: String?
    @State private var offlineRequest: OfflineRecordingRequest?
    @State private var isTranscribingMeeting = false
    @State private var transcriptError: String?
    @State private var transcriptAvailable = false
    @State private var isExtractingSlides = false
    @State private var isReadingSlides = false
    @State private var slideExtractionAttempted = false
    @State private var scanningSlideID: Int?

    /// The moment a chat citation asked this recording to open at, while it
    /// names this session — see `YouTubeVideoReaderView.chatTimeTarget`.
    private var chatTimeTarget: ReaderTimeTarget? {
        guard let target = vm.readerTimeTarget, target.sourceID == article.id,
              ReaderRequestWindow.reaches(target.windowID, readerIn: windowState?.id) else { return nil }
        return target
    }

    /// Seek the recording and move the playhead as a transcript click does, then
    /// spend the request. Media the player cannot time-sync leaves the target
    /// standing for the transcript, which scrolls to the spoken moment instead.
    private func applyChatTimeTarget() {
        guard let target = chatTimeTarget, media.supportsTimeSync else { return }
        seekRequest = YouTubeSeekRequest(seconds: target.seconds)
        playhead.time = target.seconds
        vm.readerTimeTarget = nil
    }

    /// How the player reports its position. Built from the object, not from
    /// `$playhead`, and it reads `time` only inside the closures — so handing
    /// this to the player neither observes the ticks nor invalidates anything.
    private var playheadBinding: Binding<Double?> {
        let target = playhead
        return Binding(get: { target.time }, set: { target.time = $0 })
    }

    private static let minVideoHeight: CGFloat = 140
    private static let minTranscriptHeight: CGFloat = 160

    /// Whether ForeverLM may transcribe this recording itself. Off by default:
    /// Google Meet ships Gemini's transcript inside the notes Doc the import
    /// already read, so an untranscribed session is a reason to look at the Doc,
    /// not a reason to pay for speech-to-text. See
    /// `StudioViewModel.isMeetingOwnTranscriptionEnabled`.
    @PreferenceStorage(Prefs.Meetings.transcribeWhenGoogleDidNot)
    private var canTranscribeOwnRecordings
    @WindowStorage(Prefs.Readers.meetingVideoPaneFraction) private var storedVideoFraction
    @State private var draggedVideoHeight: CGFloat?
    @State private var dragStartVideoHeight: CGFloat?

    /// Layout choice: the transcript beside the recording instead of below it,
    /// as the video reader offers (`reader.youtubeTranscriptBesideVideo`). Off
    /// by default, so a meeting opens as it always has.
    @WindowStorage(Prefs.Readers.meetingTranscriptBesideVideo) private var transcriptBesideVideo
    /// The recording column's width as a fraction of the pane when the
    /// transcript is beside it; 0 means automatic.
    @WindowStorage(Prefs.Readers.meetingVideoPaneWidthFraction) private var storedVideoWidthFraction
    @State private var draggedVideoWidth: CGFloat?
    @State private var dragStartVideoWidth: CGFloat?

    /// Layout choice: the transcript and its bar out of view, the recording
    /// taking the whole pane (a notebook beside it holds the notes). Off by
    /// default; the recording's corner button and the bar's button toggle it.
    /// Kept on this Mac, not synced: it follows the window's room, not the account.
    @WindowStorage(Prefs.Readers.meetingTranscriptHidden) private var hidesTranscript

    private static let minVideoPaneWidth: CGFloat = 280
    private static let minTranscriptPaneWidth: CGFloat = 340
    private static let sideBySideHandleWidth: CGFloat = 8
    /// Narrower than this, the transcript stays below even when the choice is
    /// beside, so neither column is squeezed to a sliver.
    private static let minSideBySidePaneWidth: CGFloat =
        minVideoPaneWidth + minTranscriptPaneWidth + sideBySideHandleWidth

    var body: some View {
        GeometryReader { geo in
            // The container switches through AnyLayout so the player keeps its
            // identity: a structural swap would rebuild it and restart playback.
            let sideBySide = transcriptBesideVideo && geo.size.width >= Self.minSideBySidePaneWidth
            let layout = sideBySide
                ? AnyLayout(HStackLayout(spacing: 0))
                : AnyLayout(VStackLayout(spacing: 0))
            VStack(spacing: 0) {
                // The recording's own pane already carries the reconnect card
                // when the load failed on it; the bar covers the rest, such as
                // a cached recording that plays while new files cannot import.
                if case .googleDrive(let original, _, _, _) = media, driveReconnectHealth == nil {
                    GoogleDriveHealthBanner(
                        accountID: GoogleDriveService.accountID(from: original.absoluteString),
                        isWorking: isReconnectingDrive,
                        reconnect: reconnectDrive
                    )
                }

                layout {
                    // The same view whether or not the transcript shows, so the
                    // recording keeps playing when it is hidden or brought back.
                    videoPane
                        .frame(width: sideBySide && !hidesTranscript ? videoWidth(in: geo.size) : nil)
                        .frame(height: sideBySide || hidesTranscript ? nil : videoHeight(in: geo.size))
                        .frame(maxHeight: sideBySide || hidesTranscript ? .infinity : nil)
                        // Not into the safe area: the reader toolbar hangs in the
                        // titlebar band above this pane, and a background that
                        // extends there paints over it (see YouTubeVideoReaderView).
                        .background(Color.black, ignoresSafeAreaEdges: [])
                        .overlay(alignment: .topLeading) {
                            if hidesTranscript { showTranscriptButton }
                        }

                    if !hidesTranscript {
                        if sideBySide {
                            videoWidthResizeHandle(in: geo.size)
                        } else {
                            videoResizeHandle(in: geo.size)
                        }

                        transcriptSection
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: article.id) {
            citedPapers = await vm.loadCitedPapers(forSourceID: article.id)
        }
        .onChange(of: chatTimeTarget?.presentationKey) { _, _ in
            applyChatTimeTarget()
        }
        .onAppear {
            applyChatTimeTarget()
        }
        .task(id: driveRecordingTaskID) {
            await loadDriveRecording()
            await refreshOfflineState()
        }
        .task(id: offlineRequest) {
            await runOfflineRequest()
        }
        .onChange(of: article.id) { oldID, _ in
            flushWatchProgress(sourceID: oldID)
            watch.reset()
            playhead.time = nil
            playhead.activeSegmentIndex = nil
            videoDuration = nil
            seekRequest = nil
            playbackError = nil
            citedPapers = []
            showsCitedPapers = false
            isFindingPapers = false
            cachedDriveRecordingURL = nil
            driveRecordingError = nil
            driveReconnectHealth = nil
            driveRecordingRetryID = UUID()
            offlineRequest = nil
            isAvailableOffline = nil
            isDownloadingOffline = false
            offlineError = nil
            isTranscribingMeeting = false
            transcriptError = nil
            transcriptAvailable = false
            isExtractingSlides = false
            isReadingSlides = false
            slideExtractionAttempted = false
            scanningSlideID = nil
        }
        // A ticker rather than an `onChange` here, for the same reason the
        // transcript mounts one: reading the playhead in this body would put
        // every tick back through the whole reader.
        .background {
            TranscriptPlayheadTicker(playhead: playhead) { time in
                recordPlayback(time: time)
            }
        }
        .onChange(of: videoDuration) { _, _ in
            recordPlayback(time: playhead.time)
        }
        .onDisappear {
            flushWatchProgress(sourceID: article.id)
        }
    }

    @ViewBuilder
    private var videoPane: some View {
        switch media {
        case .localFile(let url):
            MeetingRecordingPlayerView(
                mediaURL: url,
                currentTime: playheadBinding,
                duration: $videoDuration,
                seekRequest: seekRequest,
                initialResumeSeconds: storedWatchProgress?.resumeSeconds,
                loadError: $playbackError
            )
            .overlay {
                if let playbackError {
                    playerErrorOverlay(message: playbackError, fileURL: url)
                }
            }
        case .googleDrive(let original, _, _, _):
            if let cachedDriveRecordingURL {
                MeetingRecordingPlayerView(
                    mediaURL: cachedDriveRecordingURL,
                    currentTime: playheadBinding,
                    duration: $videoDuration,
                    seekRequest: seekRequest,
                    initialResumeSeconds: storedWatchProgress?.resumeSeconds,
                    loadError: $playbackError
                )
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 0) {
                        offlineButton
                        openInDriveButton(original)
                    }
                }
            } else if let driveReconnectHealth {
                driveReconnectCard(health: driveReconnectHealth, original: original)
            } else if let driveRecordingError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                    Text(driveRecordingError)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                    HStack {
                        Button("Try Again") { driveRecordingRetryID = UUID() }
                        Button("Open in Google Drive") { NSWorkspace.shared.open(original) }
                    }
                }
                .foregroundStyle(.white)
                .padding(24)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading recording from Google Drive…")
                        .font(.caption)
                }
                .foregroundStyle(.white)
                .overlay(alignment: .topTrailing) { openInDriveButton(original) }
            }
        }
    }

    /// What the black pane says when Google Drive cannot be read: what broke, what
    /// it stops, and the one button that repairs it. The disconnected state is
    /// the reader's loudest, because the recording cannot play at all.
    private func driveReconnectCard(health: GoogleDriveHealth, original: URL) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .zoomedSystemFont(size: 30)
                .foregroundStyle(.orange)
            Text(health.bannerTitle)
                .font(.headline)
            Text("This recording cannot play until Google Drive is reconnected. Your transcript and notes are not affected.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 10) {
                if isReconnectingDrive {
                    ProgressView().controlSize(.small)
                    Text("Waiting for Google…")
                    Button("Cancel") {
                        Task { await GoogleDriveService.shared.cancelPendingConnection() }
                    }
                } else {
                    Button(health.reconnectLabel, action: reconnectDrive)
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                }
                Button("Open in Google Drive") { NSWorkspace.shared.open(original) }
            }
            .controlSize(.large)
        }
        .foregroundStyle(.white)
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("googleDrive.reconnectCard")
    }

    private func reconnectDrive() {
        guard !isReconnectingDrive else { return }
        isReconnectingDrive = true
        Task {
            let reconnected = await vm.reconnectGoogleDriveMeetings()
            isReconnectingDrive = false
            if reconnected { driveRecordingRetryID = UUID() }
        }
    }

    private func openInDriveButton(_ url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Image(systemName: "arrow.up.forward.square")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.hoverWash(inset: -3))
        .help("Open in Google Drive")
        .padding(8)
    }

    /// Keep this recording on the Mac so it plays with no connection. The pin
    /// lives next to the recording, where it acts, and says what it does in its
    /// help; the app's cache already holds a recording for a while, this one
    /// stays until the learner removes it.
    @ViewBuilder
    private var offlineButton: some View {
        if isDownloadingOffline {
            ProgressView()
                .controlSize(.small)
                .padding(8)
                .help("Downloading for offline viewing…")
        } else if let offlineError {
            Button {
                offlineRequest = OfflineRecordingRequest(removes: false)
            } label: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.hoverWash(inset: -3))
            .help("Could not download: \(offlineError). Click to try again.")
            .padding(8)
        } else if isAvailableOffline == true {
            Menu {
                Button("Remove Download", role: .destructive) {
                    offlineRequest = OfflineRecordingRequest(removes: true)
                }
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .hoverHighlight(inset: -3)
            .help("Available offline")
            .padding(8)
        } else if isAvailableOffline == false {
            Button {
                offlineRequest = OfflineRecordingRequest(removes: false)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.hoverWash(inset: -3))
            .help("Download for offline viewing")
            .padding(8)
        }
    }

    private func refreshOfflineState() async {
        guard case .googleDrive(let original, _, let mimeType, let modifiedAt) = media else { return }
        let available = await GoogleDriveService.shared.hasOfflineRecording(
            fileURLOrID: original.absoluteString,
            mimeType: mimeType,
            modifiedAt: modifiedAt
        )
        guard !Task.isCancelled else { return }
        isAvailableOffline = available
    }

    /// Runs the download or the removal the learner asked for. Driven by
    /// `.task(id:)` so that opening another session cancels the wait and the
    /// result can never land on the wrong recording.
    private func runOfflineRequest() async {
        guard let request = offlineRequest,
              case .googleDrive(let original, _, let mimeType, let modifiedAt) = media else { return }
        if request.removes {
            await GoogleDriveService.shared.removeOfflineRecording(
                fileURLOrID: original.absoluteString,
                mimeType: mimeType,
                modifiedAt: modifiedAt
            )
            guard !Task.isCancelled else { return }
            isAvailableOffline = false
            return
        }
        isDownloadingOffline = true
        offlineError = nil
        do {
            try await GoogleDriveService.shared.makeRecordingAvailableOffline(
                fileURLOrID: original.absoluteString,
                mimeType: mimeType,
                modifiedAt: modifiedAt
            )
            guard !Task.isCancelled else { return }
            isAvailableOffline = true
        } catch {
            guard !Task.isCancelled else { return }
            offlineError = error.localizedDescription
        }
        isDownloadingOffline = false
    }

    private var driveRecordingTaskID: String {
        switch media {
        case .localFile:
            return "local:\(article.id)"
        case .googleDrive(let original, let fileID, _, let modifiedAt):
            let accountID = GoogleDriveService.accountID(from: original.absoluteString) ?? "untagged"
            return "drive:\(accountID):\(fileID):\(modifiedAt?.timeIntervalSince1970 ?? 0):\(driveRecordingRetryID)"
        }
    }

    private func loadDriveRecording() async {
        guard case .googleDrive(let original, _, let mimeType, let modifiedAt) = media else { return }
        cachedDriveRecordingURL = nil
        driveRecordingError = nil
        driveReconnectHealth = nil
        do {
            cachedDriveRecordingURL = try await GoogleDriveService.shared.cachedRecordingURL(
                fileURLOrID: original.absoluteString,
                mimeType: mimeType,
                modifiedAt: modifiedAt
            )
        } catch {
            guard !Task.isCancelled else { return }
            driveRecordingError = error.localizedDescription
            if let driveError = error as? GoogleDriveServiceError, driveError.needsReconnect {
                driveReconnectHealth = driveError.isNotConnected ? .notConnected : .needsReconnect
            }
        }
    }

    private func playerErrorOverlay(message: String, fileURL: URL) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "play.slash")
                .zoomedSystemFont(size: 26)
                .foregroundStyle(.secondary)
            Text("Could not play this recording")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85))
    }

    @ViewBuilder
    private var transcriptSection: some View {
        if let content = article.content, !content.isEmpty {
            VStack(spacing: 0) {
                mentionedPapersBar

                TranscriptReaderView(
                    article: article,
                    content: content,
                    selectedText: $selectedText,
                    findState: findState,
                    zoomScale: zoomScale,
                    navigationTarget: navigationTarget,
                    readerTheme: readerTheme,
                    zoomInAction: zoomInAction,
                    zoomOutAction: zoomOutAction,
                    resetZoomAction: resetZoomAction,
                    playhead: media.supportsTimeSync ? playhead : nil,
                    timeSelectionAction: media.supportsTimeSync
                        ? { seconds in
                            seekRequest = YouTubeSeekRequest(seconds: seconds)
                            playhead.time = seconds
                        }
                        : nil,
                    citedPapers: citedPapers,
                    citedPaperImportAction: { paper in
                        Task { citedPapers = await vm.importCitedPaper(paper) }
                    },
                    citedPaperDismissAction: { paper in
                        Task { citedPapers = await vm.dismissCitedPaper(paper) }
                    },
                    citedPaperFindAction: { paper in
                        citedPapers = await vm.findCitedPaper(paper)
                    },
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
                    }
                )
            }
        } else {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "text.badge.xmark")
                    .zoomedSystemFont(size: 28)
                    .foregroundStyle(.secondary)
                Text("No transcript for this session yet")
                    .foregroundStyle(.secondary)
                if let error = article.errorMessage, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                if isTranscribing {
                    ProgressView("Transcribing recording…")
                        .controlSize(.small)
                } else if canTranscribeOwnRecordings {
                    Button {
                        Task { await getTranscript() }
                    } label: {
                        Label("Get transcript", systemImage: "text.bubble")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    // No button, because there is nothing to offer: ForeverLM is
                    // set to use the transcript Google wrote and not to make one
                    // of its own. Say where that is decided instead of leaving a
                    // control that would only refuse.
                    Text("ForeverLM imports the transcript Google writes and doesn't make its own. Turn on \"Transcribe recordings Google didn't\" in Plugins › Google Drive to transcribe this recording.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal)
                }
                if let transcriptError {
                    Text(transcriptError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The way back while the transcript is hidden, in the recording's corner.
    private var showTranscriptButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { hidesTranscript = false }
        } label: {
            Label("Show transcript", systemImage: "text.alignleft")
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(8)
        .help("Show the transcript again")
        .accessibilityLabel("Show Transcript")
    }

    private var pendingCitedPaperCount: Int {
        citedPapers.filter { $0.status == .pending }.count
    }

    private var mentionedPapersBar: some View {
        HStack(spacing: 8) {
            if !hasTranscript {
                if isTranscribing {
                    ProgressView()
                        .controlSize(.small)
                    Text("Transcribing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if canTranscribeOwnRecordings {
                    Button {
                        Task { await getTranscript() }
                    } label: {
                        Label("Get transcript", systemImage: "text.bubble")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(transcriptError ?? "Transcribe this recording on-device")
                }
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { hidesTranscript = true }
            } label: {
                Image(systemName: "text.badge.minus")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Hide the transcript")
            .accessibilityLabel("Hide Transcript")

            Button {
                transcriptBesideVideo.toggle()
            } label: {
                Image(systemName: transcriptBesideVideo ? "rectangle.split.1x2" : "rectangle.split.2x1")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(transcriptBesideVideo ? "Move the transcript below the recording" : "Move the transcript beside the recording")
            .accessibilityLabel(transcriptBesideVideo ? "Move Transcript Below Recording" : "Move Transcript Beside Recording")

            slidesButton

            if citedPapers.isEmpty {
                Button {
                    findMentionedPapers()
                } label: {
                    if isFindingPapers {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Find mentioned papers", systemImage: "doc.text.magnifyingglass")
                            .font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isFindingPapers)
                .help("Read this meeting's transcript and notes for papers participants mentioned")
            } else {
                Button {
                    showsCitedPapers = true
                } label: {
                    Label(
                        pendingCitedPaperCount > 0 ? "\(pendingCitedPaperCount)" : "Papers",
                        systemImage: "doc.text.magnifyingglass"
                    )
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Papers mentioned in this meeting")
                .popover(isPresented: $showsCitedPapers, arrowEdge: .bottom) {
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
                        title: "Papers mentioned in this meeting",
                        emptyMessage: "No papers were explicitly mentioned in this meeting.",
                        onSeek: { _ in }
                    )
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Whether this session's recording has already had its deck captured.
    ///
    /// A substring probe of the stored text rather than a parse: it runs on every body pass,
    /// and the answer only decides which of two buttons to draw.
    private var hasExtractedSlides: Bool {
        guard let content = article.content else { return false }
        return SlideFrameExtraction.containsSlideSection(content)
    }

    /// The same two opt-in steps the YouTube reader offers, in the same order. Capturing
    /// frames decodes the whole recording and costs no AI; reading them for cited papers
    /// spends a vision call per slide, so each waits for its own click.
    @ViewBuilder
    private var slidesButton: some View {
        if hasExtractedSlides {
            Button {
                Task {
                    isReadingSlides = true
                    await vm.extractPapersFromSlides(for: article.id)
                    citedPapers = await vm.loadCitedPapers(forSourceID: article.id)
                    isReadingSlides = false
                }
            } label: {
                if isReadingSlides {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Read slides", systemImage: "rectangle.on.rectangle.angled")
                        .font(.caption)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isReadingSlides)
            .help("Read the slides shared in this meeting for the papers they cite")
        } else if !slideExtractionAttempted {
            Button {
                Task {
                    isExtractingSlides = true
                    let shown = await vm.extractSlideFrames(for: article.id)
                    // Only a came-back-empty attempt retires the button; on success the
                    // slides now render and this branch is unreachable next pass.
                    if !shown { slideExtractionAttempted = true }
                    isExtractingSlides = false
                }
            } label: {
                if isExtractingSlides {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Show slides", systemImage: "rectangle.on.rectangle.angled")
                        .font(.caption)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isExtractingSlides)
            .help("Capture the slides shared in this recording and show them alongside the transcript")
        }
    }

    private func findMentionedPapers() {
        guard !isFindingPapers else { return }
        let sourceID = article.id
        Task {
            isFindingPapers = true
            defer { isFindingPapers = false }
            await vm.extractMentionedPapersFromMeeting(for: sourceID)
            guard !Task.isCancelled else { return }
            citedPapers = await vm.loadCitedPapers(forSourceID: sourceID)
        }
    }

    /// Whether this session already has a transcript — as its own artifact, or
    /// as a `## Transcript` section merged into the session's text.
    ///
    /// The section half matters: a transcript generated on-device lives in the
    /// text, and checking only the artifact list made the reader start a fresh
    /// hour-long transcription of a meeting that was already transcribed.
    private var hasTranscript: Bool {
        transcriptAvailable
            || (vm.meetingArtifactsBySourceId[article.id] ?? []).contains { $0.kind == .transcript }
            || MeetingContent.contains(section: .transcript, in: article.content)
    }

    /// Transcription running for this session, whether this reader started it or
    /// the sidebar did.
    private var isTranscribing: Bool {
        isTranscribingMeeting || vm.transcribingMeetingSourceIDs.contains(article.id)
    }

    /// Only the "Get transcript" buttons call this. Opening a recording never
    /// transcribes it: that bills a provider, so it happens on a click. The
    /// preference gates it too; the buttons are hidden when it is off, so this
    /// is the backstop rather than the only check.
    private func getTranscript() async {
        guard canTranscribeOwnRecordings else { return }
        guard !isTranscribing else { return }
        isTranscribingMeeting = true
        transcriptError = nil
        defer { isTranscribingMeeting = false }
        do {
            _ = try await vm.ensureMeetingTranscript(for: article.id)
            transcriptAvailable = true
        } catch {
            guard !Task.isCancelled else { return }
            transcriptError = error.localizedDescription
        }
    }

    // MARK: Video pane sizing (mirrors the YouTube reader's stacked layout)

    private func videoHeight(in size: CGSize) -> CGFloat {
        VideoPaneSplit.height(
            in: size,
            dragged: draggedVideoHeight,
            storedFraction: storedVideoFraction,
            minVideo: Self.minVideoHeight,
            minTranscript: Self.minTranscriptHeight
        )
    }

    private static func clampedVideoHeight(_ height: CGFloat, in size: CGSize) -> CGFloat {
        VideoPaneSplit.clampedHeight(height, in: size, minVideo: minVideoHeight, minTranscript: minTranscriptHeight)
    }

    private func videoResizeHandle(in size: CGSize) -> some View {
        VideoStackedResizeHandle(
            paneLength: size.height,
            dragged: $draggedVideoHeight,
            dragStart: $dragStartVideoHeight,
            current: { videoHeight(in: size) },
            clamp: { Self.clampedVideoHeight($0, in: size) },
            onReset: { storedVideoFraction = 0 },
            onCommit: { storedVideoFraction = $0 }
        )
    }

    /// The recording column's width when the transcript is beside it.
    private func videoWidth(in size: CGSize) -> CGFloat {
        VideoPaneSplit.width(
            in: size,
            dragged: draggedVideoWidth,
            storedFraction: storedVideoWidthFraction,
            minVideo: Self.minVideoPaneWidth,
            minTranscript: Self.minTranscriptPaneWidth
        )
    }

    private static func clampedVideoWidth(_ width: CGFloat, in size: CGSize) -> CGFloat {
        VideoPaneSplit.clampedWidth(width, in: size, minVideo: minVideoPaneWidth, minTranscript: minTranscriptPaneWidth)
    }

    /// The side-by-side counterpart of `videoResizeHandle`: a vertical divider,
    /// dragged horizontally; double-click returns to the automatic split.
    private func videoWidthResizeHandle(in size: CGSize) -> some View {
        VideoSideBySideResizeHandle(
            handleWidth: Self.sideBySideHandleWidth,
            paneLength: size.width,
            dragged: $draggedVideoWidth,
            dragStart: $dragStartVideoWidth,
            current: { videoWidth(in: size) },
            clamp: { Self.clampedVideoWidth($0, in: size) },
            onReset: { storedVideoWidthFraction = 0 },
            onCommit: { storedVideoWidthFraction = $0 }
        )
    }

    // MARK: Watch progress (same cadence and gates as the YouTube reader)

    private var storedWatchProgress: VideoWatchProgress? {
        vm.readingProgressStore.videoWatchProgress(
            for: article.id,
            fallbackLocator: article.readingPositionLocator
        )
    }

    private func recordPlayback(time: Double?) {
        guard let time, time.isFinite, time >= 0 else { return }
        let previous = watch.current ?? storedWatchProgress
        let updated = VideoWatchProgress(
            positionSeconds: time,
            watchedSeconds: max(previous?.watchedSeconds ?? 0, time),
            durationSeconds: videoDuration ?? previous?.durationSeconds
        )
        guard updated != previous else { return }
        watch.current = updated
        flushWatchProgressIfDue(updated)
    }

    /// Persist when the playhead has moved meaningfully since the last write —
    /// not on every half-second tick. Each flush marks the source record changed
    /// for CloudKit, so the cadence is the sync-churn ceiling.
    private func flushWatchProgressIfDue(_ progress: VideoWatchProgress) {
        if let last = watch.lastFlushed {
            let moved = abs(progress.positionSeconds - last.positionSeconds) >= 30
            let durationLearned = last.durationSeconds == nil && progress.durationSeconds != nil
            let finishedNow = progress.isEssentiallyWatched && !last.isEssentiallyWatched
            guard moved || durationLearned || finishedNow else { return }
        } else {
            // First write waits for real playback: merely opening a recording,
            // which reports time 0 while paused, must not mark it "in progress".
            guard progress.positionSeconds >= 5 || progress.watchedSeconds >= 5 else { return }
        }
        persist(progress, for: article.id)
    }

    private func flushWatchProgress(sourceID: String) {
        guard let progress = watch.current, progress != watch.lastFlushed else { return }
        if watch.lastFlushed == nil {
            guard progress.positionSeconds >= 5 || progress.watchedSeconds >= 5 else { return }
        }
        persist(progress, for: sourceID)
    }

    private func persist(_ progress: VideoWatchProgress, for sourceID: String) {
        guard let encoded = progress.encoded else { return }
        watch.lastFlushed = progress
        vm.updateReadingLocator(for: sourceID, locator: encoded)
    }
}

/// AVKit player for a local meeting recording file. Publishes the playhead at
/// the same half-second cadence as the YouTube watch-page bridge and honors
/// transcript seek requests. All media loading is AVFoundation-async; nothing
/// here touches the file synchronously, so an evicted cloud file buffers
/// instead of beachballing.
struct MeetingRecordingPlayerView: NSViewRepresentable {
    let mediaURL: URL
    @Binding var currentTime: Double?
    @Binding var duration: Double?
    let seekRequest: YouTubeSeekRequest?
    let initialResumeSeconds: Double?
    @Binding var loadError: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        context.coordinator.attachPlayerIfNeeded(to: view)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.attachPlayerIfNeeded(to: view)
        context.coordinator.seekIfNeeded()
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.teardown()
        view.player = nil
    }

    @MainActor
    final class Coordinator {
        var parent: MeetingRecordingPlayerView
        private var player: AVPlayer?
        private var loadedMediaURL: URL?
        private var timeObserver: Any?
        private var loadTask: Task<Void, Never>?
        private var lastSeekRequestID: UUID?
        private var lastPublishedTime: Double?
        private var didApplyInitialResume = false

        init(parent: MeetingRecordingPlayerView) {
            self.parent = parent
        }

        func attachPlayerIfNeeded(to view: AVPlayerView) {
            guard loadedMediaURL != parent.mediaURL else { return }
            detachPlayer()
            loadedMediaURL = parent.mediaURL
            didApplyInitialResume = false

            let player = AVPlayer(url: parent.mediaURL)
            player.preventsDisplaySleepDuringVideoPlayback = true
            self.player = player
            view.player = player

            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 2),
                queue: .main
            ) { [weak self] time in
                MainActor.assumeIsolated {
                    self?.publishTime(time)
                }
            }

            loadTask = Task { [weak self] in
                guard let self, let asset = self.player?.currentItem?.asset else { return }
                do {
                    let (duration, isPlayable) = try await asset.load(.duration, .isPlayable)
                    guard !Task.isCancelled else { return }
                    guard isPlayable else {
                        self.parent.loadError = "The file format is not playable."
                        return
                    }
                    let seconds = duration.seconds
                    if seconds.isFinite, seconds > 0 {
                        self.parent.duration = seconds
                    }
                    self.applyInitialResumeIfNeeded()
                } catch {
                    guard !Task.isCancelled else { return }
                    self.parent.loadError = error.localizedDescription
                }
            }
        }

        func seekIfNeeded() {
            guard let request = parent.seekRequest, request.id != lastSeekRequestID else { return }
            lastSeekRequestID = request.id
            // An explicit seek is the position to start from; the saved resume
            // point that lands once the asset loads must not pull it back.
            didApplyInitialResume = true
            seek(to: request.seconds)
        }

        func teardown() {
            detachPlayer()
        }

        private func applyInitialResumeIfNeeded() {
            guard !didApplyInitialResume else { return }
            didApplyInitialResume = true
            guard let resume = parent.initialResumeSeconds, resume > 0 else { return }
            seek(to: resume)
        }

        private func seek(to seconds: Double) {
            let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
            player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        private func publishTime(_ time: CMTime) {
            let seconds = time.seconds
            guard seconds.isFinite, seconds >= 0 else { return }
            if let last = lastPublishedTime, abs(last - seconds) < 0.25 { return }
            lastPublishedTime = seconds
            parent.currentTime = seconds
        }

        private func detachPlayer() {
            loadTask?.cancel()
            loadTask = nil
            if let timeObserver, let player {
                player.removeTimeObserver(timeObserver)
            }
            timeObserver = nil
            player?.pause()
            player = nil
            loadedMediaURL = nil
            lastPublishedTime = nil
        }
    }
}

/// The bar that says, above everything else, that Google Drive cannot read the
/// meeting folders. It puts that fact where nobody can miss it, with the
/// repair beside it. It draws nothing while
/// Drive is healthy, and it re-checks whenever a connection changes.
struct GoogleDriveHealthBanner: View {
    /// The Drive account the content belongs to; nil answers for the connection
    /// as a whole.
    var accountID: String?
    var isWorking: Bool
    var reconnect: () -> Void

    // Healthy until a check says otherwise, so a connected Drive never flashes
    // a warning while the keychain is read off the main thread.
    @State private var health: GoogleDriveHealth = .connected

    var body: some View {
        Group {
            if health.isBroken {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(health.bannerTitle)
                            .font(.callout.weight(.semibold))
                        Text(health.bannerDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if isWorking {
                        ProgressView().controlSize(.small)
                        Button("Cancel") {
                            Task { await GoogleDriveService.shared.cancelPendingConnection() }
                        }
                        .controlSize(.small)
                    } else {
                        Button(health.reconnectLabel, action: reconnect)
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
                .overlay(alignment: .bottom) { Divider() }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("googleDrive.healthBanner")
            }
        }
        .task(id: accountID) { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .pluginConnectionChanged)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        let accountID = accountID
        let current = await Task.detached(priority: .utility) {
            GoogleDriveService.shared.health(accountID: accountID)
        }.value
        guard !Task.isCancelled, current != health else { return }
        health = current
    }
}

#endif
