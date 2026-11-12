#if os(macOS)
import Foundation
import SwiftUI

enum TextToSpeechSettingsNavigation {
    static func open() {
        NotificationCenter.default.post(name: .requestOpenStudioSettings, object: SettingsPane.aiTextToSpeech)
    }
}

/// A source row's narration mark: a spinner while the narration is made, then
/// a grey speaker (a state mark: "Lists are monochrome", docs/ui-design.md)
/// and the trash that deletes it. The trash shows only while the pointer is
/// over the row, in a slot that keeps its size so the speaker never moves
/// (product owner, 2026-10-06, "kind of like the chatgpt app"); the row's
/// right-click menu and the Reader's ⋯ have Delete Cached Audio as well.
struct ArticleSpeechCacheDeleteButton: View {
    let sourceID: String
    var speech: ArticleSpeechService? = nil
    var showsSpeakerIcon = false
    /// The hosting row's hover, which reveals the trash. A host with no row
    /// hover leaves it drawn.
    var isRowHovered = true

    @State private var hasCached = false
    @State private var showConfirmation = false
    @ObservedObject private var audioQueue = SourceAudioGenerationQueue.shared

    var body: some View {
        Group {
            if audioQueue.isGenerating(sourceID) {
                // The same slot the speaker badge takes once the narration
                // lands, so a source shows where it is without opening a menu.
                ProgressView()
                    .controlSize(.mini)
                    .help(makingHelp)
                    .accessibilityLabel(SourceNarrationState.makingLine)
            } else if hasCached {
                HStack(spacing: 4) {
                    if showsSpeakerIcon {
                        Image(systemName: "speaker.wave.2.fill")
                            .zoomedSystemFont(size: 11)
                            .foregroundStyle(.secondary)
                            .help("Narration ready")
                    }

                    // Faded rather than removed, so the slot keeps its size
                    // and the dialog it presents outlives the pointer leaving.
                    Button {
                        showConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .zoomedSystemFont(size: showsSpeakerIcon ? 11 : 13)
                    }
                    .buttonStyle(.hoverWash(inset: -3))
                    .help("Delete cached text-to-speech audio")
                    .accessibilityLabel("Delete Cached Audio")
                    .opacity(isRowHovered ? 1 : 0)
                    .confirmationDialog(
                        "Delete cached text-to-speech audio?",
                        isPresented: $showConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Delete", role: .destructive) {
                            deleteCachedAudio()
                        }
                    }
                }
            }
        }
        .onAppear {
            refreshCacheStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: ArticleSpeechAudioCache.statusDidChangeNotification)) { notification in
            guard notification.object as? String == sourceID else { return }
            refreshCacheStatus()
        }
    }

    /// "Making narration, this takes a while", with the share done once there
    /// is one: the Reader's line for the same state.
    private var makingHelp: String {
        let state = SourceNarrationState(
            hasNarration: false,
            isMaking: true,
            progress: audioQueue.progressBySourceID[sourceID]
        )
        return state.statusLine(stage: ArticleSpeechService.shared.narrationStages[sourceID])
            ?? SourceNarrationState.makingLine
    }

    private func refreshCacheStatus() {
        Task {
            let cached = await Task.detached {
                ArticleSpeechAudioCache.hasCachedAudio(sourceID: sourceID)
            }.value
            await MainActor.run {
                hasCached = cached
            }
        }
    }

    private func deleteCachedAudio() {
        Task {
            await ArticleSpeechCacheDeletion.delete(sourceID: sourceID, speech: speech)
            hasCached = false
        }
    }
}

/// Deleting a source's narration: the row's trash, the Reader's ⋯ and the
/// row's right-click menu.
@MainActor
enum ArticleSpeechCacheDeletion {
    /// Delete Cached Audio from a menu with no view to present a dialog from
    /// (a source row's right-click): the question is asked over the window in
    /// front, as `PageSpaceNamePrompt` asks for a name.
    static func confirm(sourceID: String, speech: ArticleSpeechService?) {
        let alert = NSAlert()
        alert.messageText = "Delete cached text-to-speech audio?"
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { await delete(sourceID: sourceID, speech: speech) }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// Stops the narration if it is playing or being made, then removes it.
    static func delete(sourceID: String, speech: ArticleSpeechService?) async {
        if speech?.activeArticleID == sourceID {
            speech?.stop()
        }
        speech?.cancelBackgroundGeneration(sourceID: sourceID)
        await Task.detached {
            ArticleSpeechAudioCache.deleteCachedAudio(sourceID: sourceID)
        }.value
    }
}

struct ArticleSpeechCancelGenerationButton: View {
    @ObservedObject var speech: ArticleSpeechService
    var onCancel: (() -> Void)? = nil
    /// Shown while local UI is preparing text-to-speech before generation state is published.
    var forceVisible = false

    private var isVisible: Bool {
        forceVisible || speech.isGeneratingAudio || speech.isWaitingForFirstChunk
    }

    var body: some View {
        if isVisible {
            ReaderToolbarButton(
                help: "Cancel audio generation",
                controlSize: 22,
                washInset: 3
            ) {
                speech.stop()
                onCancel?()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ArticleSpeechControls: View {
    @ObservedObject var speech: ArticleSpeechService
    @ObservedObject private var audioQueue = SourceAudioGenerationQueue.shared
    let article: StudioArticle
    var showsTitle = true
    /// Compact reader toolbars retain the preparation spinner and stop action
    /// but move the potentially long status string out of the constrained row.
    var showsPreparationStatus = true
    /// False on the Reader's bars, where Listen is state, not a command
    /// (Quiet chrome, docs/ui-design.md): the control draws
    /// nothing until Listen is preparing, making a narration or playing, and
    /// the ⋯ menu's `ArticleSpeechListenMenuItem` starts it. A host that hides
    /// it plays a narration that lands while it is hidden itself
    /// (`ArticleSpeechService.takeMadeNarration`), since nothing here is
    /// mounted to take it.
    var showsListenWhenIdle = true

    /// Whether the source's narration is there, read off the main actor on
    /// appearing and whenever the audio cache says it changed.
    @State private var hasNarration = false

    private var isActive: Bool {
        speech.activeArticleID == article.id
    }

    /// Making covers every way a narration gets started: this control's
    /// Listen, the source's Generate Audio, an assistant's queue.
    private var narrationState: SourceNarrationState {
        SourceNarrationState(
            hasNarration: hasNarration,
            isMaking: speech.isMakingNarration(article.id)
                || audioQueue.activeSourceIDs.contains(article.id),
            progress: speech.backgroundGenerationProgress[article.id]
        )
    }

    var body: some View {
        Group {
            if ArticleSpeechContent.canAttemptRead(article),
               showsListenWhenIdle || speech.hasListeningUnderWay(for: article.id) {
                HStack(spacing: 4) {
                    if speech.preparingArticleID == article.id || (isActive && speech.isWaitingForFirstChunk) {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                        if showsPreparationStatus {
                            Text(speech.preparationStatus ?? "Preparing audio…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .accessibilityIdentifier("reader.listenPreparing")
                        }
                        ArticleSpeechCancelGenerationButton(speech: speech, forceVisible: true)
                    } else if !isActive, narrationState.isMaking {
                        makingNarration
                    } else if showsTitle {
                        Button(action: toggleListening) { menuLabel }
                            .buttonStyle(.hoverWash(inset: -3))
                            .help(listenHelp)
                            .accessibilityLabel(listenHelp)
                    } else {
                        // The icon-only form otherwise announces its SF
                        // Symbol, "Volume High", to VoiceOver and to
                        // anything driving the app by accessibility name;
                        // `help` doubles as its accessibility label.
                        ReaderToolbarButton(
                            help: listenHelp,
                            accessibilityIdentifier: "reader.listen",
                            action: toggleListening
                        ) {
                            menuLabel
                        }
                    }
                }
            }
        }
        .task(id: article.id) { await refreshNarration() }
        .onReceive(NotificationCenter.default.publisher(for: ArticleSpeechAudioCache.statusDidChangeNotification)) { notification in
            guard notification.object as? String == article.id else { return }
            Task { await refreshNarration() }
        }
        // A narration Listen made lands while this control still shows its
        // source: Listen has turned into Play, and it starts at once, unless
        // the learner has since put something else on.
        .onChange(of: speech.madeNarrationSourceID) { _, sourceID in
            guard sourceID == article.id, speech.takeMadeNarration(article) else { return }
            hasNarration = true
        }
    }

    /// "Making narration, this takes a while", how far it has got, and Stop.
    /// What Listen shows in place of a live player: the narration is made in
    /// the background and keeps going if the learner leaves.
    private var makingNarration: some View {
        let state = narrationState
        return HStack(spacing: 4) {
            Group {
                if let fraction = state.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.circular)
                } else {
                    ProgressView()
                }
            }
            .controlSize(.small)
            .frame(width: 16, height: 16)
            if showsPreparationStatus, let line = state.statusLine(stage: speech.narrationStages[article.id]) {
                Text(line)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // Selectable text cannot carry its own AX label on macOS; see
                    // AGENTS.md, "Text that speaks for itself".
                    .textSelection(.disabled)
                    .accessibilityLabel(SourceNarrationState.makingLine)
                    .accessibilityValue(state.fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "")
                    .accessibilityIdentifier("reader.narrationMaking")
            }
            ReaderToolbarButton(
                help: "Stop making the narration",
                accessibilityLabel: "Stop making narration",
                accessibilityIdentifier: "reader.narrationStop",
                controlSize: 22,
                washInset: 3
            ) {
                speech.stopMakingNarration(sourceID: article.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        // A group of its own: on a plain container the help replaced the
        // Stop button's.
        .accessibilityElement(children: .contain)
        .help(state.statusLine(stage: speech.narrationStages[article.id]).map { "\($0). \(SourceNarrationState.makingHelp)" }
              ?? SourceNarrationState.makingHelp)
    }

    private var listenHelp: String {
        if isActive {
            return speech.isPaused ? "Resume listening" : "Pause listening"
        }
        switch narrationState.listenAction() {
        case .play: return hasNarration ? "Play the narration" : "Listen to this source"
        case .wait: return SourceNarrationState.makingHelp
        }
    }

    private func toggleListening() {
        if isActive {
            speech.pauseOrResume()
        } else {
            speech.listen(to: article, hasNarration: hasNarration)
        }
    }

    private func refreshNarration() async {
        let sourceID = article.id
        let found = await Task.detached(priority: .userInitiated) {
            ArticleSpeechAudioCache.hasCachedAudio(sourceID: sourceID)
        }.value
        guard !Task.isCancelled else { return }
        hasNarration = found
    }

    @ViewBuilder
    private var menuLabel: some View {
        let playsNarration = !isActive && hasNarration
        let filled = isActive && !speech.isPaused
        if showsTitle {
            Label(
                isActive ? "Listening" : (hasNarration ? "Play" : "Listen"),
                systemImage: playsNarration ? "play.fill" : (filled ? "speaker.wave.2.fill" : "speaker.wave.2")
            )
                .labelStyle(.titleAndIcon)
                .font(.caption)
        } else {
            Image(systemName: playsNarration ? "play.fill" : (filled ? "speaker.wave.2.fill" : "speaker.wave.2"))
        }
    }
}

struct ArticleSpeechTransportControls: View {
    @ObservedObject var speech: ArticleSpeechService

    var body: some View {
        Button {
            speech.skipBackward()
        } label: {
            Image(systemName: "gobackward.15")
        }
        .buttonStyle(.hoverWash(inset: -3))
        .disabled(!speech.canSeek)
        .help("Back 15 seconds")

        Button {
            speech.pauseOrResume()
        } label: {
            if speech.isWaitingForFirstChunk {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: speech.isPaused ? "play.fill" : "pause.fill")
            }
        }
        .buttonStyle(.hoverWash(inset: -3))
        .disabled(!speech.isPlaying || speech.isWaitingForFirstChunk)
        .help(speech.isPaused ? "Resume text to speech" : "Pause text to speech")

        Button {
            speech.skipForward()
        } label: {
            Image(systemName: "goforward.15")
        }
        .buttonStyle(.hoverWash(inset: -3))
        .disabled(!speech.canSeek)
        .help("Forward 15 seconds")

        Button {
            speech.cycleSpeed()
        } label: {
            Text(MacArticleSpeechSpeed.label(for: speech.speed))
                .font(.caption.monospacedDigit())
                .frame(minWidth: 30)
        }
        .buttonStyle(.hoverWash(inset: -3))
        .help("Playback speed")
    }
}

/// Where the Studio window's own player belongs. Playback is app-wide and
/// outlives any reader, so the audio needs a visible handle somewhere; the
/// reader showing the narrated source carries the player at its foot, and the
/// window-wide bar exists only for the moment that reader is gone — closed,
/// switched to another source, hidden behind Chat — so the audio never plays
/// on with nothing on screen to pause it.
enum StudioAudiobookPlayerPlacement {
    /// Whether the window should show its own bar at the bottom, given the
    /// sources the readers in that window are currently displaying.
    static func showsWindowPlayer(
        narratingSourceID: String?,
        readerSourceIDsOnScreen: Set<String>
    ) -> Bool {
        guard let narratingSourceID else { return false }
        return !readerSourceIDsOnScreen.contains(narratingSourceID)
    }
}

/// Persistent audiobook chrome for Studio. It lives outside the reader so
/// closing a source or working in another pane does not end the listening
/// session. The bar itself shows only while no reader in this window displays
/// the narrated source (`StudioAudiobookPlayerPlacement`); the reader has the
/// same player at its foot. Chapter auto-advance and error reporting stay here
/// regardless, because they belong to the session, not to a view of it.
struct StudioAudiobookPlayerHost: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @ObservedObject private var speech = ArticleSpeechService.shared

    private var shownSourceID: String? {
        guard speech.isVisible, let sourceID = speech.narratingArticleID,
              StudioAudiobookPlayerPlacement.showsWindowPlayer(
                  narratingSourceID: sourceID,
                  readerSourceIDsOnScreen: windowState.readerSourceIDsOnScreen
              ) else { return nil }
        return sourceID
    }

    var body: some View {
        Group {
            if let sourceID = shownSourceID {
                Divider()
                StudioAudiobookPlayer(speech: speech, sourceID: sourceID)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: shownSourceID)
        .onChange(of: speech.finishedListeningArticleID) { _, sourceID in
            guard let sourceID else { return }
            // A visible book reader gets the first chance to follow its native
            // Contents order, which can differ from stored chapter order. If no
            // reader consumes the event this turn, continue from the library
            // order so background listening still flows into the next chapter.
            Task { @MainActor in
                await Task.yield()
                guard speech.finishedListeningArticleID == sourceID else { return }
                continueBookAfterFinishedChapter(sourceID)
            }
        }
        .alert("Text to Speech Error", isPresented: Binding(
            get: { speech.errorMessage != nil },
            set: { if !$0 { speech.errorMessage = nil } }
        )) {
            Button(speech.errorSuggestsProviderSwitch ? "Switch Voice Provider" : "Text to Speech Settings") {
                speech.errorMessage = nil
                TextToSpeechSettingsNavigation.open()
            }
            Button("OK", role: .cancel) {
                speech.errorMessage = nil
            }
        } message: {
            Text(speech.errorMessage ?? "")
        }
    }

    private func continueBookAfterFinishedChapter(_ sourceID: String) {
        guard let finished = vm.articlesById[sourceID],
              let group = finished.parentGroup else {
            _ = speech.consumeFinishedListening(articleID: sourceID)
            return
        }
        let chapters = vm.bookChapterArticlesInOrder(for: group)
        guard speech.consumeFinishedListening(articleID: sourceID),
              let index = chapters.firstIndex(where: { $0.id == sourceID }),
              index + 1 < chapters.endIndex else { return }
        let next = chapters[index + 1]
        let followsVisibleReader = vm.selectedArticleId == sourceID
        Task {
            if followsVisibleReader {
                await vm.selectReaderSource(next.id)
            }
            speech.startTextToSpeech(article: next)
        }
    }
}

/// The player for one narrated source — title, chapter skip, transport,
/// options, stop, and the scrubber — mounted at the foot of the reader showing
/// that source, and in the window-wide bar when no reader does.
struct StudioAudiobookPlayer: View {
    @Environment(StudioViewModel.self) private var vm
    @ObservedObject var speech: ArticleSpeechService
    let sourceID: String
    /// In the window bar the title opens the source; at the foot of the
    /// reader already showing it, the title is only a title.
    var showsOpenSource = true

    @State private var previousChapterID: String?
    @State private var nextChapterID: String?

    var body: some View {
        ArticleSpeechMiniPlayer(
            speech: speech,
            sourceID: sourceID,
            previousChapterID: previousChapterID,
            nextChapterID: nextChapterID,
            openSource: showsOpenSource ? { openSource(sourceID) } : nil,
            playPreviousChapter: { playChapter(previousChapterID, from: sourceID) },
            playNextChapter: { playChapter(nextChapterID, from: sourceID) }
        )
        .onChange(of: sourceID, initial: true) { _, sourceID in
            refreshChapterNeighbors(for: sourceID)
        }
    }

    private func refreshChapterNeighbors(for sourceID: String?) {
        previousChapterID = nil
        nextChapterID = nil
        guard let sourceID,
              let article = vm.articlesById[sourceID],
              let group = article.parentGroup else { return }
        let chapters = vm.bookChapterArticlesInOrder(for: group)
        guard let index = chapters.firstIndex(where: { $0.id == sourceID }) else { return }
        if index > chapters.startIndex {
            previousChapterID = chapters[index - 1].id
        }
        if index + 1 < chapters.endIndex {
            nextChapterID = chapters[index + 1].id
        }
    }

    private func openSource(_ sourceID: String) {
        Task { await vm.revealSourceInReader(sourceID) }
    }

    private func playChapter(_ chapterID: String?, from sourceID: String) {
        guard let chapterID, let chapter = vm.articlesById[chapterID] else { return }
        let followsVisibleReader = vm.selectedArticleId == sourceID
        Task {
            if followsVisibleReader {
                await vm.selectReaderSource(chapterID)
            }
            speech.startTextToSpeech(article: chapter)
        }
    }
}

private struct ArticleSpeechMiniPlayer: View {
    @ObservedObject var speech: ArticleSpeechService
    let sourceID: String
    let previousChapterID: String?
    let nextChapterID: String?
    /// Nil where the source is already on screen behind the player.
    let openSource: (() -> Void)?
    let playPreviousChapter: () -> Void
    let playNextChapter: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 12) {
                if let openSource {
                    Button(action: openSource) {
                        nowPlayingTitle
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: -2))
                    .help("Open the source")
                } else {
                    nowPlayingTitle
                }

                Spacer(minLength: 0)

                // Chapter skips only where there are chapters: an article's
                // two disabled buttons made the bar wider than a narrow
                // Reader, which then drew past its pane's left edge.
                if hasChapters {
                    chapterButton(
                        systemImage: "backward.end.fill",
                        help: "Previous chapter",
                        isEnabled: previousChapterID != nil,
                        action: playPreviousChapter
                    )
                }

                ArticleSpeechTransportControls(speech: speech)
                    .layoutPriority(1)

                if hasChapters {
                    chapterButton(
                        systemImage: "forward.end.fill",
                        help: "Next chapter",
                        isEnabled: nextChapterID != nil,
                        action: playNextChapter
                    )
                }

                Menu {
                    Button {
                        TextToSpeechSettingsNavigation.open()
                    } label: {
                        Label("Text to Speech Settings", systemImage: "gearshape")
                    }
                    ArticleSpeechListeningOverflowItems(speech: speech, sourceID: sourceID)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Listening options")

                Button {
                    speech.stop()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.hoverWash(inset: -3))
                .help("Stop listening")
                .accessibilityLabel("Stop listening")
            }

            ArticleSpeechToolbarProgress(speech: speech)
                .frame(maxWidth: 520)

            if let notice = speech.languageNotice, notice.sourceID == sourceID {
                languageNotice(notice)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.audiobookPlayer")
    }

    private var hasChapters: Bool {
        previousChapterID != nil || nextChapterID != nil
    }

    private var nowPlayingTitle: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(speech.nowPlayingTitle ?? "Preparing audio…")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            if let subtitle = speech.nowPlayingSubtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        // No floor: in a narrow pane the title gives way to the transport.
        .frame(minWidth: 0, maxWidth: 260, alignment: .leading)
    }

    /// Why this source is not being read by the voice in Settings. It reports
    /// a decision that has already been made — playback is running — so it sits
    /// under the transport and dismisses rather than interrupting.
    private func languageNotice(_ notice: ArticleSpeechLanguageNotice) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: notice.kind == .unsupported
                ? "exclamationmark.triangle.fill"
                : "character.bubble")
                .foregroundStyle(notice.kind == .unsupported ? .orange : .secondary)
            Text(notice.message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                speech.languageNotice = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.hoverWash(inset: -3))
            .help("Dismiss")
            .accessibilityLabel("Dismiss language notice")
        }
        .font(.caption2)
        .frame(maxWidth: 520, alignment: .leading)
        // A group of its own: on a plain container the identifier landed on
        // the message and on the Dismiss button.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.audiobookPlayer.languageNotice")
    }

    private func chapterButton(
        systemImage: String,
        help: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(.hoverWash(inset: -3))
        .disabled(!isEnabled)
        .help(help)
    }
}

struct ArticleSpeechListeningOverflowItems: View {
    @ObservedObject var speech: ArticleSpeechService
    let sourceID: String

    var body: some View {
        Menu {
            ForEach(MacArticleSpeechSleepTimer.options, id: \.self) { duration in
                Button {
                    speech.startSleepTimer(duration: duration)
                } label: {
                    Text(MacArticleSpeechSleepTimer.label(for: duration))
                }
            }

            if speech.sleepTimerRemaining != nil {
                Divider()
                Button("Cancel Timer") {
                    speech.cancelSleepTimer()
                }
            }
        } label: {
            if let remaining = speech.sleepTimerRemaining {
                Label(
                    "Sleep Timer (\(MacArticleSpeechSleepTimer.remainingLabel(for: remaining)))",
                    systemImage: "moon.zzz"
                )
            } else {
                Label("Sleep Timer", systemImage: "moon.zzz")
            }
        }

        if speech.activeArticleID == sourceID {
            ArticleSpeechCacheDeleteMenuItem(sourceID: sourceID, speech: speech)
        }
    }
}

struct ArticleSpeechCacheDeleteMenuItem: View {
    let sourceID: String
    var speech: ArticleSpeechService? = nil

    @State private var hasCached = false
    @State private var showConfirmation = false
    @Environment(\.hostedMenuConfirmation) private var hostedMenuConfirmation

    var body: some View {
        Group {
            if hasCached {
                Button(role: .destructive) {
                    // Inside an `NSHostingMenu` there is no view to present a
                    // dialog from; the host presents it instead.
                    if let hostedMenuConfirmation {
                        hostedMenuConfirmation(HostedMenuConfirmation(
                            title: "Delete cached text-to-speech audio?",
                            confirmTitle: "Delete",
                            role: .destructive,
                            action: deleteCachedAudio
                        ))
                    } else {
                        showConfirmation = true
                    }
                } label: {
                    Label("Delete Cached Audio", systemImage: "trash")
                }
                .confirmationDialog(
                    "Delete cached text-to-speech audio?",
                    isPresented: $showConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        deleteCachedAudio()
                    }
                }
            }
        }
        .onAppear {
            refreshCacheStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: ArticleSpeechAudioCache.statusDidChangeNotification)) { notification in
            guard notification.object as? String == sourceID else { return }
            refreshCacheStatus()
        }
    }

    private func refreshCacheStatus() {
        Task {
            let cached = await Task.detached {
                ArticleSpeechAudioCache.hasCachedAudio(sourceID: sourceID)
            }.value
            await MainActor.run {
                hasCached = cached
            }
        }
    }

    private func deleteCachedAudio() {
        Task {
            await ArticleSpeechCacheDeletion.delete(sourceID: sourceID, speech: speech)
            hasCached = false
        }
    }
}

/// Listen, in the Reader's ⋯ menu while nothing is under way for the source:
/// plays its narration, or makes one; Quiet chrome keeps Listen off the bar
/// until then. Once it starts, the bar shows it
/// (`ArticleSpeechControls`, `showsListenWhenIdle: false`) and this item
/// leaves the menu for the Stop Listening section.
struct ArticleSpeechListenMenuItem: View {
    @ObservedObject var speech: ArticleSpeechService
    let article: StudioArticle

    var body: some View {
        if ArticleSpeechContent.canAttemptRead(article), !speech.hasListeningUnderWay(for: article.id) {
            Button {
                speech.listen(to: article)
            } label: {
                Label("Listen", systemImage: "speaker.wave.2")
            }
            .help("Listen to this source")
        }
    }
}

extension ArticleSpeechService {
    /// Whether Listen has something under way for the source: preparing,
    /// making its narration (however it was asked for, the assistant queue
    /// included), or playing, paused or not. What puts Listen on the Reader's
    /// bar; otherwise it is a ⋯ item.
    func hasListeningUnderWay(for sourceID: String) -> Bool {
        preparingArticleID == sourceID
            || activeArticleID == sourceID
            || isMakingNarration(sourceID)
            || SourceAudioGenerationQueue.shared.activeSourceIDs.contains(sourceID)
    }

    /// A narration Listen made has landed while a Reader still shows its
    /// source: takes it, once, and plays it unless another source is playing.
    /// Returns whether it was taken here.
    @discardableResult
    func takeMadeNarration(_ article: StudioArticle) -> Bool {
        guard consumeMadeNarration(sourceID: article.id) else { return false }
        let otherActive = activeArticleID.map { $0 != article.id } ?? false
        if SourceNarration.startsPlayingWhenMade(otherSourceIsActive: otherActive) {
            startTextToSpeech(article: article)
        }
        return true
    }

    /// Whether the player has a scrubber or a loading line to show. A
    /// narration that is still being generated live (a book that carried on
    /// into a chapter with no audio) has neither: its length is a guess, and
    /// "Generating audio" is not a state the player reports. Narrations are
    /// made first and played once they are there (`SourceNarrationState`).
    var showsToolbarProgress: Bool {
        (canSeek && !isGeneratingAudio) || isLoadingCachedPlayback || isBufferingNextChunk
    }
}

struct ArticleSpeechToolbarProgress: View {
    @ObservedObject var speech: ArticleSpeechService

    var body: some View {
        HStack(spacing: 8) {
            if speech.canSeek && !speech.isGeneratingAudio {
                ArticleSpeechPlaybackScrubber(speech: speech)
            }
            // No "Generating audio" line while a narration plays: it is made
            // first (`SourceNarrationState`) and played once it is there.
            if speech.isLoadingCachedPlayback {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                    Text(speech.preparationStatus ?? "Loading audio…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else if speech.isBufferingNextChunk {
                Text("Buffering…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct ArticleSpeechPlaybackScrubber: View {
    @ObservedObject var speech: ArticleSpeechService
    @State private var isEditingScrubber = false
    @State private var scrubberValue = 0.0

    var body: some View {
        HStack(spacing: 8) {
            Slider(
                value: scrubberBinding,
                in: 0...1,
                onEditingChanged: { editing in
                    if editing {
                        scrubberValue = speech.playbackFraction
                    } else {
                        speech.seek(toFraction: scrubberValue)
                    }
                    isEditingScrubber = editing
                }
            )
            .controlSize(.small)
            .frame(maxWidth: 180)

            Text(playbackTimeLabel())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var scrubberBinding: Binding<Double> {
        Binding(
            get: {
                isEditingScrubber ? scrubberValue : speech.playbackFraction
            },
            set: { newValue in
                scrubberValue = newValue
            }
        )
    }

    private func playbackTimeLabel() -> String {
        ArticleSpeechToolbarText.playbackTimeLabel(
            current: speech.playbackCurrentTime,
            duration: speech.playbackDuration,
            durationIsEstimated: speech.isPlaybackDurationEstimated
        )
    }
}

enum ArticleSpeechToolbarText {
    static func playbackTimeLabel(
        current: TimeInterval,
        duration: TimeInterval,
        durationIsEstimated: Bool
    ) -> String {
        let estimateMarker = durationIsEstimated ? "~" : ""
        return "\(formatPlaybackTime(current)) / \(estimateMarker)\(formatPlaybackTime(duration))"
    }

    private static func formatPlaybackTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        return YouTubeTranscriptTime.display(seconds)
    }
}

#endif
