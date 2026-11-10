import AppKit
import SwiftUI

struct PodcastSpeakerEditDraft: Identifiable, Equatable {
    let originalLabel: String
    var editedLabel: String

    var id: String { originalLabel }
}

struct TranscriptReaderView: View {
    /// The Studio window this reader is drawn in: a moment asked for another
    /// window's Reader is not this one's (`ReaderRequestWindow`).
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    let article: StudioArticle
    let content: String
    @Binding var selectedText: String
    let findState: ReaderFindState
    let zoomScale: CGFloat
    let navigationTarget: SourceSearchBestMatch?
    var readerTheme: ReaderColorTheme = .system
    let zoomInAction: () -> Void
    let zoomOutAction: () -> Void
    let resetZoomAction: () -> Void
    /// Playback bridge for meeting sessions whose recording plays in-app: the
    /// playhead (drives the follow-along highlight) and the seek action
    /// clicking a timestamped turn should perform. Nil everywhere else.
    var playhead: TranscriptPlayhead? = nil
    var timeSelectionAction: ((Double) -> Void)? = nil
    /// Slide-aware extras for a meeting whose recording has had its deck captured. The
    /// meeting reader owns the cited-paper list, so it passes it down rather than this view
    /// loading a second copy of the same rows.
    var citedPapers: [VideoCitedPaper] = []
    var citedPaperImportAction: ((VideoCitedPaper) -> Void)? = nil
    var citedPaperDismissAction: ((VideoCitedPaper) -> Void)? = nil
    var citedPaperFindAction: (@MainActor (VideoCitedPaper) async -> Void)? = nil
    var scanningSlideID: Int? = nil
    var slideScanAction: ((YouTubeSlideFrameContext) -> Void)? = nil
    @Environment(StudioViewModel.self) private var vm
    /// Where a podcast's Speakers commands go for the Reader's ⋯; nil in a
    /// host with no ⋯ to list them.
    @Environment(ReaderMenuCommands.self) private var menuCommands: ReaderMenuCommands?
    @State private var loadedPodcastArticleID: String?
    @State private var isLoadingPodcastSegments = false
    @State private var podcastSegments: [PodcastTranscriptSegment] = []
    @State private var meetingSegments: [PodcastTranscriptSegment] = []
    @State private var meetingLayout: TranscriptDisplayLayout = .sections
    @State private var meetingSlides: [YouTubeSlideFrameContext] = []
    @State private var isUpdatingSpeakersWithAI = false
    @State private var isSavingSpeakerEdits = false
    @State private var showSpeakerEditor = false
    @State private var speakerDrafts: [PodcastSpeakerEditDraft] = []

    /// An explainer is an essay written for the ear, so it reads in the prose
    /// form: a serif column under a masthead that names what it is, how long
    /// it runs, and the way back to the source it explains. Every other text
    /// this view shows keeps the transcript form.
    private var explainerPresentation: ProseReaderPresentation? {
        if let overviewID = GeneratedAudioOverview.artifactID(ofCarrier: article) {
            return audioOverviewPresentation(artifactID: overviewID)
        }
        guard let explainedID = GeneratedExplainer.explainedSourceID(from: article.url) else { return nil }
        let wordCount = article.wordCount ?? content
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .count
        var presentation = ProseReaderPresentation(
            kicker: "Explainer",
            title: GeneratedExplainer.displayTitle(for: article.title),
            detail: GeneratedExplainer.lengthLabel(wordCount: wordCount)
        )
        if let explained = vm.articlesById[explainedID] {
            presentation.linkTitle = explained.sourceType == .paper ? "Open the paper" : "Open the article"
            presentation.linkAction = { [vm] in
                Task { await vm.selectArticle(explainedID) }
            }
        }
        return presentation
    }

    /// A notebook's audio overview reads the same way: its script under a
    /// masthead with what it is, how long it runs, and the way back to its
    /// notebook.
    private func audioOverviewPresentation(artifactID: String) -> ProseReaderPresentation {
        let wordCount = article.wordCount ?? content
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .count
        var presentation = ProseReaderPresentation(
            kicker: AudioOverviewScript.kindLabel,
            title: article.title,
            detail: GeneratedExplainer.lengthLabel(wordCount: wordCount)
        )
        if let notebookID = vm.artifacts.first(where: { $0.id == artifactID })?.homeNotebookID,
           vm.notebook(id: notebookID) != nil {
            presentation.linkTitle = "Open the notebook"
            presentation.linkAction = { [vm] in
                vm.openNotebookInReader(notebookID)
            }
        }
        return presentation
    }

    /// Whether the Reader's ⋯ offers Speakers for this source: a podcast
    /// whose transcript names its speakers.
    private var offersSpeakerCommands: Bool {
        article.sourceType == .podcast
            && !shouldHoldPodcastFallback
            && !editableSpeakerLabels().isEmpty
    }

    /// The section a sidebar artifact row asked for, but only while it belongs to
    /// the session on screen — the reader outlives one selection, and a request
    /// aimed at another meeting is not this document's to honor.
    private var meetingSectionTarget: MeetingSectionReaderTarget? {
        guard let target = vm.meetingSectionReaderTarget,
              target.sourceID == article.id else { return nil }
        return target
    }

    /// The moment a chat citation asked this source to open at, for a transcript
    /// with no player behind it to scroll to. A meeting whose recording plays
    /// in-app seeks instead, and its reader spends the target before it gets here.
    private var readerTimeTarget: ReaderTimeTarget? {
        guard let target = vm.readerTimeTarget,
              target.sourceID == article.id,
              ReaderRequestWindow.reaches(target.windowID, readerIn: windowState?.id) else { return nil }
        return target
    }

    private var shouldHoldPodcastFallback: Bool {
        article.sourceType == .podcast
            && loadedPodcastArticleID != article.id
            && TranscriptParseMemos.podcast[podcastTranscriptTaskID] == nil
    }

    private var podcastTranscriptTaskID: String {
        "\(article.id):\(content.count):\(content.prefix(256).hashValue)"
    }

    /// Segments for the current podcast: local `@State` once this view instance
    /// loaded them, otherwise the app-lifetime memo so re-opening an episode
    /// renders instantly instead of re-reading the TTML behind a
    /// "Preparing transcript…" placeholder.
    private var effectivePodcastSegments: [PodcastTranscriptSegment] {
        if !podcastSegments.isEmpty { return podcastSegments }
        return TranscriptParseMemos.podcast[podcastTranscriptTaskID] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            if article.sourceType == .podcast || (article.sourceType == .meeting && effectiveMeetingParse?.transcript.segments.isEmpty == false) {
                TranscriptFindBar(state: findState)
            }

            // Update Speakers with AI and Edit Speakers Manually… are the
            // Reader's ⋯ › Speakers since Quiet chrome (docs/ui-design.md,
            // 2026-10-06), not a row of their own; while either runs, this
            // line says so, and the outcome arrives as a toast.
            if isUpdatingSpeakersWithAI || isSavingSpeakerEdits {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    ProgressView()
                        .controlSize(.small)
                    Text(progressLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            if shouldHoldPodcastFallback {
                podcastTranscriptLoadingView
            } else if article.sourceType == .podcast, !effectivePodcastSegments.isEmpty {
                let segments = effectivePodcastSegments
                NativeTranscriptReaderView(
                    article: article,
                    segments: segments,
                    layout: .speakerTurns,
                    kicker: article.domain.isEmpty ? "Podcast transcript" : article.domain,
                    metadata: "\(segments.count) speaker turns",
                    placeholderLabel: "Podcast",
                    selectedText: $selectedText,
                    findState: findState,
                    findRevision: findState.searchRevision,
                    playhead: nil,
                    timeSelectionAction: nil,
                    navigationTarget: navigationTarget,
                    zoomScale: zoomScale,
                    readerTheme: .system,
                    timeTarget: readerTimeTarget,
                    timeTargetHandled: { vm.readerTimeTarget = nil }
                )
            } else if article.sourceType == .podcast {
                let transcript = storedPodcastTranscript
                if transcript.segments.isEmpty {
                    InlineTextReaderView(
                        content: content,
                        sourceID: article.id,
                        selectedText: $selectedText,
                        findState: findState,
                        findRevision: findState.searchRevision,
                        navigationTarget: navigationTarget,
                        zoomScale: zoomScale,
                        readerTheme: .system,
                        zoomInAction: zoomInAction,
                        zoomOutAction: zoomOutAction,
                        resetZoomAction: resetZoomAction
                    )
                } else {
                    NativeTranscriptReaderView(
                        article: article,
                        segments: transcript.segments,
                        layout: transcript.layout,
                        kicker: article.domain.isEmpty ? "Podcast transcript" : article.domain,
                        metadata: transcript.layout == .speakerTurns
                            ? "\(transcript.segments.count) speaker turns"
                            : "\(transcript.segments.count) sections",
                        placeholderLabel: "Podcast",
                        selectedText: $selectedText,
                        findState: findState,
                        findRevision: findState.searchRevision,
                        playhead: nil,
                        timeSelectionAction: nil,
                        navigationTarget: navigationTarget,
                        zoomScale: zoomScale,
                        readerTheme: .system,
                        timeTarget: readerTimeTarget,
                        timeTargetHandled: { vm.readerTimeTarget = nil }
                    )
                }
            } else if article.sourceType == .meeting, let meetingParse = effectiveMeetingParse, !meetingParse.transcript.segments.isEmpty {
                NativeTranscriptReaderView(
                    article: article,
                    segments: meetingParse.transcript.segments,
                    layout: meetingParse.transcript.layout,
                    kicker: article.domain.isEmpty ? "Meeting transcript" : article.domain,
                    metadata: meetingParse.transcript.layout == .speakerTurns
                        ? "\(meetingParse.transcript.segments.count) speaker turns"
                        : "\(meetingParse.transcript.segments.count) sections",
                    placeholderLabel: "Meeting",
                    selectedText: $selectedText,
                    findState: findState,
                    findRevision: findState.searchRevision,
                    playhead: playhead,
                    timeSelectionAction: timeSelectionAction,
                    navigationTarget: navigationTarget,
                    zoomScale: zoomScale,
                    readerTheme: readerTheme,
                    slideFrames: meetingParse.slides,
                    scanningSlideID: scanningSlideID,
                    slideScanAction: slideScanAction,
                    citedPapers: citedPapers,
                    citedPaperImportAction: citedPaperImportAction,
                    citedPaperDismissAction: citedPaperDismissAction,
                    citedPaperFindAction: citedPaperFindAction,
                    sectionTarget: meetingSectionTarget,
                    sectionTargetHandled: { vm.meetingSectionReaderTarget = nil },
                    timeTarget: playhead == nil ? readerTimeTarget : nil,
                    timeTargetHandled: { vm.readerTimeTarget = nil }
                )
            } else if article.sourceType == .meeting, effectiveMeetingParse == nil {
                // A blob above the inline limit, still parsing off the main actor.
                // Say so, rather than drawing the transcript once as plain text and
                // again as rows: that is the flash the product owner asked about (2026-09-19).
                ReaderLoadingView(
                    title: "Preparing transcript…",
                    subtitle: "The transcript will appear here in a moment."
                )
            } else {
                InlineTextReaderView(
                    content: contentWithoutSlideBlock,
                    sourceID: article.id,
                    selectedText: $selectedText,
                    findState: findState,
                    findRevision: findState.searchRevision,
                    navigationTarget: navigationTarget,
                    zoomScale: zoomScale,
                    readerTheme: readerTheme,
                    prose: explainerPresentation,
                    zoomInAction: zoomInAction,
                    zoomOutAction: zoomOutAction,
                    resetZoomAction: resetZoomAction
                )
            }
        }
        .task(id: meetingTaskID) {
            guard article.sourceType == .meeting else {
                meetingSegments = []
                meetingSlides = []
                return
            }
            let key = meetingTaskID
            if let cached = TranscriptParseMemos.meeting[key] {
                meetingSegments = cached.transcript.segments
                meetingLayout = cached.transcript.layout
                meetingSlides = cached.slides
                return
            }
            // Only a blob above the inline limit gets here without a memo entry: the
            // render pass already parsed and stored anything smaller. Parse it off the
            // main actor; the body shows "Preparing transcript…" until this lands.
            let parsed = await Self.parseMeetingTranscriptOffMain(content)
            guard !Task.isCancelled else { return }
            TranscriptParseMemos.meeting.store(parsed, for: key)
            meetingSegments = parsed.transcript.segments
            meetingLayout = parsed.transcript.layout
            meetingSlides = parsed.slides
        }
        .task(id: podcastTranscriptTaskID) {
            guard article.sourceType == .podcast else {
                loadedPodcastArticleID = nil
                podcastSegments = []
                return
            }

            let key = podcastTranscriptTaskID
            let podcastArticleID = article.id
            if let cached = TranscriptParseMemos.podcast[key] {
                podcastSegments = cached
                loadedPodcastArticleID = podcastArticleID
                return
            }

            isLoadingPodcastSegments = true
            defer { isLoadingPodcastSegments = false }

            guard let rawTTML = await vm.loadPodcastRawTTML(for: podcastArticleID) else {
                guard !Task.isCancelled else { return }
                podcastSegments = []
                // Remember the miss so re-opening a TTML-less episode doesn't
                // hit storage again just to land on the stored-text fallback.
                TranscriptParseMemos.podcast.store([], for: key)
                loadedPodcastArticleID = podcastArticleID
                return
            }

            guard !Task.isCancelled else { return }
            // TTML parsing is regex-heavy over the full transcript; keep it off
            // the main actor.
            let storedContent = content
            let rawSegments = await Task.detached(priority: .userInitiated) {
                let rawSegments = PodcastTranscriptParser.parseTTML(rawTTML)
                let storedSegments = YouTubeTranscriptDisplayParser.parse(storedContent).segments
                let overrides = PodcastSpeakerNameInference.displayNameOverrides(
                    rawSegments: rawSegments,
                    storedSegments: storedSegments
                )
                guard !overrides.isEmpty else { return rawSegments }
                return rawSegments.map { segment in
                    PodcastTranscriptSegment(
                        index: segment.index,
                        speakerID: segment.speakerID,
                        speakerLabel: overrides[segment.speakerID] ?? segment.speakerLabel,
                        startTime: segment.startTime,
                        endTime: segment.endTime,
                        text: segment.text,
                        heading: segment.heading
                    )
                }
            }.value
            guard !Task.isCancelled else { return }
            guard !Task.isCancelled else { return }
            podcastSegments = rawSegments
            TranscriptParseMemos.podcast.store(rawSegments, for: key)
            loadedPodcastArticleID = podcastArticleID
        }
        .onChange(of: speakerCommandsKey, initial: true) { _, _ in
            publishSpeakerCommands()
        }
        .onDisappear {
            withdrawSpeakerCommands()
        }
        .sheet(isPresented: $showSpeakerEditor) {
            PodcastSpeakerEditorSheet(
                drafts: $speakerDrafts,
                isSaving: isSavingSpeakerEdits,
                onCancel: { showSpeakerEditor = false },
                onSave: { saveSpeakerEdits() }
            )
        }
    }

    /// Stored-text fallback (no TTML). Memoized: this used to re-parse the full
    /// transcript inside the render path on every body evaluation. The memo is
    /// not observable, so storing from here cannot invalidate views.
    private var storedPodcastTranscript: YouTubeTranscriptDisplayParser.Result {
        let key = podcastTranscriptTaskID
        if let cached = TranscriptParseMemos.storedPodcast[key] {
            return cached
        }
        let parsed = YouTubeTranscriptDisplayParser.parse(content)
        TranscriptParseMemos.storedPodcast.store(parsed, for: key)
        return parsed
    }

    /// The stored text with a captured slide block taken back off, for the plain-text
    /// fallback. The substring check is what keeps this cheap: it is false for every source
    /// that has no deck, which is nearly all of them, and only then is the split paid for.
    private var contentWithoutSlideBlock: String {
        guard SlideFrameExtraction.containsSlideSection(content) else { return content }
        return YouTubeSlideContentParser.parse(content).transcriptContent
    }

    private var meetingTaskID: String {
        Self.meetingParseKey(articleID: article.id, content: content)
    }

    /// The two halves of a stored meeting blob, ready to draw: the captured deck and the
    /// transcript's display model.
    typealias MeetingTranscriptParse = (
        slides: [YouTubeSlideFrameContext],
        transcript: YouTubeTranscriptDisplayParser.Result
    )

    /// Memo key for one meeting's parse. Keyed on the whole stored blob, so a
    /// slide block appended later is a new key and a transcript that has not
    /// changed is the same key on every mount.
    nonisolated static func meetingParseKey(articleID: String, content: String) -> String {
        "\(articleID):meeting:\(content.count):\(content.prefix(256).hashValue)"
    }

    /// Stored blobs up to this many UTF-8 bytes are parsed on the spot, inside
    /// the render pass, the first time a reader shows them.
    ///
    /// Measured in the debug unit-test bundle on 2026-09-19, after the parser
    /// stopped compiling its regexes per block: a Zoom caption transcript of
    /// the standup's shape (149 timestamped turns, 10 KB) parses in 2 ms, a
    /// Read AI export the size of the largest in the production library (1,158
    /// speaker lines, 135 KB) in 22 ms. The limit sits where the inline cost
    /// stays inside one frame — about 11 ms at 64 KB in that bundle, less in a
    /// release build — which takes in every standup (8–40 KB) and 142 of the
    /// 412 meetings stored that day. Above it, `parseMeetingTranscriptOffMain`
    /// runs the same parse at once, behind "Preparing transcript…" rather than
    /// the plain-text dump, for the frame or two it takes.
    nonisolated static let inlineMeetingParseByteLimit = 64 * 1024

    nonisolated static func parsesMeetingTranscriptInline(_ content: String) -> Bool {
        content.utf8.count <= inlineMeetingParseByteLimit
    }

    /// The one parse both routes run — the render pass for a blob under the
    /// limit and the detached task above it — so the rows a reader shows are
    /// the same whichever way they were made. Captured slides live in the same
    /// stored blob as the transcript; splitting them off here keeps their image
    /// paths out of the rendered text and puts the frames in the margin.
    nonisolated static func parseMeetingTranscript(_ content: String) -> MeetingTranscriptParse {
        let split = YouTubeSlideContentParser.parse(content)
        return (
            slides: split.displaySlides,
            transcript: YouTubeTranscriptDisplayParser.parse(
                normalizedMeetingTranscript(split.transcriptContent)
            )
        )
    }

    /// The same parse for a blob above the inline limit, run off the main actor
    /// on a GCD global queue rather than as a detached task.
    ///
    /// The distinction is the point. Swift's cooperative pool is one thread per
    /// core, shared by every detached job in the app — imports, embeddings,
    /// transcoding, file reads that may block on iCloud — and a new task,
    /// whatever its priority, waits for a free thread; that queue is where the
    /// first-open parse used to sit, sometimes for seconds, while the plain text
    /// stood in. A global queue over-commits, so this starts now and the
    /// placeholder lasts the parse and no longer.
    nonisolated static func parseMeetingTranscriptOffMain(_ content: String) async -> MeetingTranscriptParse {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInteractive).async {
                continuation.resume(returning: parseMeetingTranscript(content))
            }
        }
    }

    /// The parse a render pass can have right now: the memo's copy, or — for a
    /// blob under `inlineMeetingParseByteLimit` — a fresh parse stored into the
    /// memo on the way out, so the styled transcript is the first thing the
    /// reader ever draws. Nil only for a blob above the limit that no task has
    /// finished yet. The memo is not observable, so storing from here cannot
    /// invalidate views (`storedPodcastTranscript` relies on the same fact).
    static func meetingParse(key: String, content: String) -> MeetingTranscriptParse? {
        if let cached = TranscriptParseMemos.meeting[key] {
            return cached
        }
        guard parsesMeetingTranscriptInline(content) else { return nil }
        let parsed = parseMeetingTranscript(content)
        TranscriptParseMemos.meeting.store(parsed, for: key)
        return parsed
    }

    /// Parsed meeting transcript: local `@State` once this view instance parsed
    /// it, otherwise whatever `meetingParse(key:content:)` has — the memo, or
    /// an inline parse — so a meeting renders its styled rows on the first
    /// frame, on the first open as much as on a re-open.
    private var effectiveMeetingParse: MeetingTranscriptParse? {
        if !meetingSegments.isEmpty {
            return (
                slides: meetingSlides,
                transcript: YouTubeTranscriptDisplayParser.Result(segments: meetingSegments, layout: meetingLayout)
            )
        }
        return Self.meetingParse(key: meetingTaskID, content: content)
    }

    /// Prepare meeting transcript content for the shared transcript parser.
    /// Drops the redundant leading title heading, then promotes every source
    /// line to its own block. Meeting exports (Read AI, Meet) use one speaker
    /// turn — or heading/bullet — per line, so this lets the parser render each
    /// turn as a distinct styled block instead of collapsing single-newline
    /// turns into one paragraph.
    nonisolated static func normalizedMeetingTranscript(_ content: String) -> String {
        let withoutTitle = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(
                of: #"\A#[ \t]+[^\n]*\n+"#,
                with: "",
                options: .regularExpression
            )
        let blocks = withoutTitle
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return blocks.joined(separator: "\n\n")
    }

    private var progressLabel: String {
        if isUpdatingSpeakersWithAI { return "Updating speakers…" }
        return "Saving speakers…"
    }

    /// What the ⋯ › Speakers items read, so they are published again only
    /// when it changes.
    private struct SpeakerCommandsKey: Hashable {
        let sourceID: String
        let isOffered: Bool
        let isBusy: Bool
    }

    private var speakerCommandsKey: SpeakerCommandsKey {
        SpeakerCommandsKey(
            sourceID: article.id,
            isOffered: offersSpeakerCommands,
            isBusy: isUpdatingSpeakersWithAI || isSavingSpeakerEdits
        )
    }

    private func publishSpeakerCommands() {
        guard let menuCommands else { return }
        guard offersSpeakerCommands else {
            withdrawSpeakerCommands()
            return
        }
        menuCommands.speakers = ReaderSpeakerCommands(
            sourceID: article.id,
            isBusy: isUpdatingSpeakersWithAI || isSavingSpeakerEdits,
            updateWithAI: { updateSpeakersWithAI() },
            editManually: { openSpeakerEditor() }
        )
    }

    /// Only this source's: the next reader may already have published its own.
    private func withdrawSpeakerCommands() {
        guard let menuCommands, menuCommands.speakers?.sourceID == article.id else { return }
        menuCommands.speakers = nil
    }

    private func updateSpeakersWithAI() {
        guard ManagedAI.isSignedIn else {
            vm.showToast("Sign in with Apple first")
            return
        }
        isUpdatingSpeakersWithAI = true
        Task {
            do {
                let updated = try await vm.updatePodcastSpeakersWithAI(for: article.id)
                isUpdatingSpeakersWithAI = false
                vm.showToast(updated ? "Speakers updated" : "No clear speaker names found")
            } catch {
                isUpdatingSpeakersWithAI = false
                vm.showToast("Speaker update failed: \(error.localizedDescription)")
            }
        }
    }

    private func openSpeakerEditor() {
        speakerDrafts = editableSpeakerLabels().map {
            PodcastSpeakerEditDraft(originalLabel: $0, editedLabel: $0)
        }
        showSpeakerEditor = true
    }

    private func saveSpeakerEdits() {
        let mapping = Dictionary(uniqueKeysWithValues: speakerDrafts.map {
            ($0.originalLabel, $0.editedLabel)
        })
        isSavingSpeakerEdits = true
        Task {
            let updated = await vm.updatePodcastSpeakersManually(for: article.id, labels: mapping)
            isSavingSpeakerEdits = false
            showSpeakerEditor = false
            vm.showToast(updated ? "Speakers updated" : "No speaker changes to save")
        }
    }

    private func editableSpeakerLabels() -> [String] {
        let contentLabels = uniqueSpeakerLabels(speakerTurnLabels(in: content))
        if !contentLabels.isEmpty { return contentLabels }
        return uniqueSpeakerLabels(podcastSegments.map(\.speakerLabel))
    }

    private func uniqueSpeakerLabels(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for label in labels {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private func speakerTurnLabels(in transcript: String) -> [String] {
        let pattern = #"(?m)^\s*(?:\[(.+?)\]|\*\*(.+?):\*\*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
        return regex.matches(in: transcript, range: range).compactMap { match in
            let captureRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            guard let labelRange = Range(captureRange, in: transcript) else { return nil }
            return String(transcript[labelRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var podcastTranscriptLoadingView: some View {
        VStack(spacing: 12) {
            if isLoadingPodcastSegments {
                ProgressView()
                    .controlSize(.small)
            }
            Text("Preparing transcript…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

struct PodcastSpeakerEditorSheet: View {
    @Binding var drafts: [PodcastSpeakerEditDraft]
    let isSaving: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    private var canSave: Bool {
        drafts.contains {
            !$0.editedLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.editedLabel != $0.originalLabel
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Edit Speakers")
                .font(.title3.weight(.semibold))

            ScrollView {
                VStack(spacing: 12) {
                    ForEach($drafts) { $draft in
                        HStack(spacing: 12) {
                            Text(draft.originalLabel)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(width: 130, alignment: .leading)
                                .lineLimit(1)

                            TextField("Speaker name", text: $draft.editedLabel)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 120, maxHeight: 280)

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)

                Button("Save") {
                    onSave()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave || isSaving)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

// MARK: - YouTube Video Reader (embed + transcript)
