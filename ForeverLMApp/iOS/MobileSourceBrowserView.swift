import SwiftUI

// The reading side of the phone: the whole library (Home's Library row),
// browsable by type down to full source content in the reader. Notebooks own
// Home (`MobileNotebookHomeView`); here a tap opens the source and a swipe
// starts a voice session about it. Books and courses render as containers with
// their chapters and lectures inside, the way the Mac's sidebar shows them.

struct MobileSourceBrowserView: View {
    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @State private var query = ""
    @State private var showsCapture = false

    var body: some View {
        List {
            if searchedSources.isEmpty, !query.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if query.isEmpty {
                typeSection
            } else {
                searchResults
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Sources")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, prompt: "Search sources")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add Source", systemImage: "plus") { showsCapture = true }
            }
        }
        .sheet(isPresented: $showsCapture) {
            MobileCaptureSourceSheet()
        }
        .refreshable {
            await vm.load()
        }
        .task {
            // Opening Sources is itself a freshness event. The durable snapshot
            // renders immediately; the CloudKit delta only republishes on change.
            await vm.load(forceRefresh: true)
        }
    }

    @ViewBuilder
    private var typeSection: some View {
        if vm.allSources.isEmpty {
            // "No Sources" is a claim about the library, and during the first
            // sync it is simply not true yet — say which of the two it is.
            if let status = vm.syncStatus {
                ContentUnavailableView {
                    Label("Syncing your library", systemImage: "arrow.triangle.2.circlepath")
                } description: {
                    Text("\(status.stepText). Sources appear here as they arrive.")
                }
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("sources.syncing")
            } else {
                MobileEmptyLibraryView()
                    .listRowBackground(Color.clear)
            }
        } else {
            let courseSplit = MobileSourceGrouping.groups(
                ofType: "course",
                in: browsableSources,
                collections: vm.collections
            )
            // Types come from the whole library so a type whose every source is
            // marked paywalled keeps its row — the shelf inside it is the only
            // way to reach those sources. Counts come from the browsable split.
            let typeGroups = MobileSourceTypeGrouping.groups(
                for: vm.allSources,
                alsoIncluding: courseSplit.groups.isEmpty ? [] : ["course"]
            )
            Section {
                ForEach(typeGroups, id: \.label) { group in
                    NavigationLink {
                        MobileSourceTypeScreen(
                            selection: MobileSourceTypeSelection(
                                sourceType: group.sourceType,
                                label: group.label
                            )
                        )
                    } label: {
                        MobileSourceTypeButtonRow(
                            sourceType: group.sourceType,
                            label: group.label,
                            count: group.sourceType == "course"
                                ? courseSplit.groups.count + courseSplit.standalone.count
                                : containerCount(for: group.sourceType, in: group.sources)
                        )
                    }
                    .accessibilityIdentifier("browser.typeRow")
                }
            }
        }
    }

    /// Everything the lists actually browse: marked-paywalled sources are kept
    /// out, the way the Mac keeps them out of its paper lists. They remain in
    /// `vm.allSources` for search, Notebooks and Schedule.
    private var browsableSources: [MobileCloudSource] {
        MobileSourceListing.listed(vm.allSources)
    }

    /// Books count as containers ("12 books"), everything else as individual
    /// sources — matching what the next screen actually lists. Courses are
    /// counted from their own split, which the caller already has in hand.
    private func containerCount(for sourceType: String, in sources: [MobileCloudSource]) -> Int {
        let browsable = MobileSourceListing.listed(sources)
        guard MobileSourceGrouping.isGroupedType(sourceType) else { return browsable.count }
        let split = MobileSourceGrouping.groups(
            ofType: sourceType,
            in: browsableSources,
            collections: vm.collections
        )
        return split.groups.count + split.standalone.count
    }

    private var searchedSources: [MobileCloudSource] {
        MobileSourceListSearch.filter(MobileSourceListing.listed(vm.allSources), query: query, groupTitle: groupTitle(for:))
    }

    private func groupTitle(for source: MobileCloudSource) -> String? {
        guard let group = source.parentGroup else { return nil }
        return vm.collections.booksByID[group]?.title ?? vm.collections.coursesByID[group]?.title
    }

    private var searchResults: some View {
        Section {
            ForEach(searchedSources) { source in
                MobileBrowserSourceLink(source: source)
            }
        }
    }
}

/// The app-shell player. UI-started generation stays row-local until its first
/// playable chunk exists; from then on the bar exposes transport and generation
/// progress while the remaining chunks arrive.
struct MobileCompactPlaybackBar: View {
    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @State private var presentedItem: MobileAudioItem?

    var body: some View {
        // The bar rides above every screen, so it is the one surface that owns
        // text-to-speech failures — a destination that shows its own copy only says
        // the same thing twice. An error never displaces what the bar is
        // otherwise showing: audio already playing keeps its controls, and a
        // source still generating keeps its progress.
        VStack(spacing: 0) {
            if let message = vm.errorMessage {
                errorRow(message)
            }

            // A first sync runs for minutes across every destination, so it
            // belongs to the shell too: leaving the setup screen, or opening
            // Sources while it fills, must not be the same as losing the
            // progress. It never displaces playback — it stacks above it.
            if vm.showsShellSyncStatus {
                syncRow(vm.syncStatus)
            }

            if let item = vm.currentItem {
                playbackBar(
                    item,
                    showsGenerationProgress: vm.isPreparingAudio(sourceID: item.id)
                        || vm.narrationDownloadProgress(sourceID: item.id) != nil
                )
            } else if let title = vm.textToSpeechPreparingTitle {
                preparingRow(title)
            } else if let download = vm.narrationDownloadProgress {
                downloadingRow(download)
            }
        }
        .fullScreenCover(item: $presentedItem) { item in
            MobileFullScreenPlaybackView(item: item)
                .environmentObject(vm)
        }
        .alert(
            "Continue books automatically?",
            isPresented: Binding(
                // Queued behind the text-to-speech cost alert rather than presented
                // the moment the offer lands: both are raised by background
                // work, and two alerts asked to present together abort the
                // process. See `MobileAsyncAlert`.
                get: {
                    MobileAsyncAlert.resolve(
                        textToSpeechCostPending: vm.textToSpeechCostConfirmation != nil,
                        bookContinuationPending: vm.bookContinuationOffer != nil
                    ) == .bookContinuation
                },
                set: { if !$0 { vm.dismissBookContinuationOffer() } }
            ),
            presenting: vm.bookContinuationOffer
        ) { offer in
            Button("Enable") {
                Task {
                    await vm.respondToBookContinuationOffer(offer, enable: true)
                }
            }
            Button("Not Now", role: .cancel) {
                Task {
                    await vm.respondToBookContinuationOffer(offer, enable: false)
                }
            }
        } message: { offer in
            Text("ForeverLM can generate and play \(offer.nextTitle) when each chapter ends. Missing audio is billed to your OpenRouter key.")
        }
    }

    private func syncRow(_ status: MobileCatalogSyncStatus?) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text(status?.stepText ?? "Syncing your library")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(status?.detailText ?? "Your sources appear as they arrive.")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // Linear, not a determinate circular: iOS draws that one as a
                // plain spinner, which would drop the fraction silently.
                if let fraction = status?.fractionComplete {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MobileDesign.Spacing.large)
        .padding(.vertical, MobileDesign.Spacing.medium)
        .mobileFloatingSurface(cornerRadius: MobileDesign.Radius.card)
        .padding(.horizontal, MobileDesign.Spacing.medium)
        .padding(.bottom, MobileDesign.Spacing.small)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("shell.syncStatus")
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                vm.clearError()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, MobileDesign.Spacing.large)
        .padding(.vertical, MobileDesign.Spacing.medium)
        .mobileFloatingSurface(cornerRadius: MobileDesign.Radius.card)
        .padding(.horizontal, MobileDesign.Spacing.medium)
        .padding(.bottom, MobileDesign.Spacing.small)
        .accessibilityIdentifier("listen.error")
    }

    private func preparingRow(_ title: String) -> some View {
        HStack(spacing: 12) {
            MobileTextToSpeechProgressIndicator(progress: vm.textToSpeechGenerationProgress)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            MobileTextToSpeechProgressText(
                detail: vm.textToSpeechPreparationDetail,
                progress: vm.textToSpeechGenerationProgress
            )
        }
        .padding(.horizontal, MobileDesign.Spacing.large)
        .padding(.vertical, MobileDesign.Spacing.medium)
        .mobileFloatingSurface(cornerRadius: MobileDesign.Radius.card)
        .padding(.horizontal, MobileDesign.Spacing.medium)
        .padding(.bottom, MobileDesign.Spacing.small)
        .accessibilityIdentifier("listen.preparing")
    }

    /// A narration on its way down from iCloud that has not made sound yet:
    /// the first chunks are still arriving, or the resume point is further in
    /// than what has landed. Once the opening plays this row becomes the
    /// playback bar's progress line.
    private func downloadingRow(_ download: MobileNarrationDownloadProgress) -> some View {
        HStack(spacing: 12) {
            MobileTextToSpeechProgressIndicator(progress: nil, download: download)
            Text(download.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            MobileTextToSpeechProgressText(detail: nil, progress: nil, download: download)
        }
        .padding(.horizontal, MobileDesign.Spacing.large)
        .padding(.vertical, MobileDesign.Spacing.medium)
        .mobileFloatingSurface(cornerRadius: MobileDesign.Radius.card)
        .padding(.horizontal, MobileDesign.Spacing.medium)
        .padding(.bottom, MobileDesign.Spacing.small)
        .accessibilityIdentifier("listen.downloading")
    }

    private func playbackBar(
        _ item: MobileAudioItem,
        showsGenerationProgress: Bool
    ) -> some View {
        VStack(spacing: 8) {
            if showsGenerationProgress {
                let progress = vm.textToSpeechGenerationProgress(sourceID: item.id)
                let download = vm.narrationDownloadProgress(sourceID: item.id)
                let detail = vm.textToSpeechPreparingSourceID == item.id
                    ? vm.textToSpeechPreparationDetail
                    : "Playing · generating remaining audio…"
                HStack(spacing: 8) {
                    MobileTextToSpeechProgressIndicator(progress: progress, download: download)
                    MobileTextToSpeechProgressText(
                        detail: detail,
                        progress: progress,
                        download: download
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Button {
                presentedItem = item
            } label: {
                HStack(spacing: MobileDesign.Spacing.medium) {
                    if let source = vm.allSources.first(where: { $0.id == item.id }) {
                        MobileSourceRowThumbnail(source: source, isActive: true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(vm.playerDetailText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open player for \(item.title)")
            .accessibilityIdentifier("listen.openPlayer")

            ProgressView(value: vm.progress)
                .tint(.accentColor)

            HStack(spacing: 14) {
                Spacer(minLength: 0)

                Button { vm.skip(seconds: -15) } label: {
                    Image(systemName: "gobackward.15")
                }
                .disabled(!vm.canSeek)
                .accessibilityLabel("Back 15 seconds")

                Button { vm.togglePlayback() } label: {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.body.weight(.semibold))
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel(vm.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("listen.togglePlayback")

                Button { vm.skip(seconds: 15) } label: {
                    Image(systemName: "goforward.15")
                }
                .disabled(!vm.canSeek)
                .accessibilityLabel("Forward 15 seconds")

                if vm.canDismissPlayback {
                    Button {
                        vm.dismissPlayback()
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 28, height: 28)
                    }
                    .accessibilityLabel("Close player")
                    .accessibilityIdentifier("listen.closePlayer")
                }

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, MobileDesign.Spacing.large)
        .padding(.vertical, MobileDesign.Spacing.small)
        .mobileFloatingSurface(cornerRadius: MobileDesign.Radius.card)
        .padding(.horizontal, MobileDesign.Spacing.medium)
        .padding(.bottom, MobileDesign.Spacing.small)
    }
}

/// The focused listening surface reached from the app-shell mini-player. It
/// keeps the shared playback model as the sole transport state so Lock Screen,
/// CarPlay, the mini-player, and this view never drift apart.
struct MobileFullScreenPlaybackView: View {
    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @Environment(\.dismiss) private var dismiss

    let item: MobileAudioItem
    @State private var scrubbedFraction: Double?
    /// The paper's synced first page or the book's cover, when the Mac uploaded
    /// one. Remote artwork (podcast art, YouTube frames) goes through
    /// `CachedAsyncImage` instead, so this stays nil for those.
    @State private var localArtwork: UIImage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: MobileDesign.Spacing.xLarge)

                    artwork
                        .padding(.horizontal, MobileDesign.Spacing.xxLarge)

                    Spacer(minLength: MobileDesign.Spacing.xxLarge)

                    VStack(alignment: .leading, spacing: MobileDesign.Spacing.xSmall) {
                        Text(displayedItem.title)
                            .font(.title2.weight(.bold))
                            .lineLimit(2)
                        if let subtitle = displayedItem.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    playbackProgress
                        .padding(.top, MobileDesign.Spacing.xLarge)

                    transportControls
                        .padding(.top, MobileDesign.Spacing.xLarge)

                    speedControl
                        .padding(.top, MobileDesign.Spacing.xxLarge)

                    if showsNextChapterControl {
                        nextChapterControl
                            .padding(.top, MobileDesign.Spacing.xLarge)
                    }

                    Spacer(minLength: MobileDesign.Spacing.xLarge)
                }
                .padding(.horizontal, MobileDesign.Spacing.xLarge)
            }
            .scrollIndicators(.hidden)
            .background(playerBackground.ignoresSafeArea())
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Minimize", systemImage: "chevron.down") {
                        dismiss()
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("listen.minimizePlayer")
                }
                if vm.canDismissPlayback {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close Player", systemImage: "xmark") {
                            vm.dismissPlayback()
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("listen.closeFullScreenPlayer")
                    }
                }
            }
        }
        .onChange(of: vm.currentItem?.id) { _, currentID in
            if currentID == nil {
                dismiss()
            }
        }
        .task(id: displayedItem.id) {
            localArtwork = nil
            guard let source = displayedSource else { return }
            let image = await MobileSourceArtworkLoader.localArtwork(
                for: source,
                collections: vm.collections
            )
            // The item may have advanced while the fetch was in flight.
            guard source.id == displayedItem.id else { return }
            localArtwork = image
        }
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.95), Color.accentColor.opacity(0.45)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: Color.accentColor.opacity(0.22), radius: 30, y: 16)
            if let localArtwork {
                // A page or a cover is portrait; fit it whole on the tile rather
                // than cropping the title off, the way a cover sits on a shelf.
                Image(uiImage: localArtwork)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.28), radius: 14, y: 8)
                    .padding(MobileDesign.Spacing.xLarge)
            } else if let thumbnailURL = displayedSource?.thumbnailURL {
                CachedAsyncImage(url: thumbnailURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        waveformArtwork
                    }
                }
            } else {
                waveformArtwork
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 420)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .accessibilityHidden(true)
    }

    private var waveformArtwork: some View {
        Image(systemName: "waveform")
            .font(.system(size: 76, weight: .medium))
            .foregroundStyle(.white)
            .symbolEffect(.variableColor.iterative, isActive: vm.isPlaying)
    }

    private var playbackProgress: some View {
        VStack(spacing: MobileDesign.Spacing.xSmall) {
            Slider(
                value: Binding(
                    get: { scrubbedFraction ?? vm.progress },
                    set: { scrubbedFraction = $0 }
                ),
                in: 0...1,
                onEditingChanged: { isEditing in
                    guard !isEditing, let scrubbedFraction else { return }
                    vm.seek(toFraction: scrubbedFraction)
                    self.scrubbedFraction = nil
                }
            )
            .disabled(!vm.canSeek)
            .accessibilityLabel("Playback position")

            HStack {
                Text(formattedTime(scrubbedTime ?? vm.currentTime))
                Spacer()
                Text("-\(formattedTime(remainingTime))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 34) {
            Button { vm.skip(seconds: -15) } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 30, weight: .regular))
            }
            .disabled(!vm.canSeek)
            .accessibilityLabel("Back 15 seconds")

            Button { vm.togglePlayback() } label: {
                Image(systemName: vm.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 74, weight: .regular))
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(vm.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("listen.fullScreenTogglePlayback")

            Button { vm.skip(seconds: 15) } label: {
                Image(systemName: "goforward.15")
                    .font(.system(size: 30, weight: .regular))
            }
            .disabled(!vm.canSeek)
            .accessibilityLabel("Forward 15 seconds")
        }
        .frame(maxWidth: .infinity)
    }

    private var speedControl: some View {
        Menu {
            ForEach(MobileAudioPlaybackSpeed.options, id: \.self) { speed in
                Button {
                    vm.setSpeed(speed)
                } label: {
                    if abs(vm.speed - speed) < 0.001 {
                        Label(MobileAudioPlaybackSpeed.label(for: speed), systemImage: "checkmark")
                    } else {
                        Text(MobileAudioPlaybackSpeed.label(for: speed))
                    }
                }
            }
        } label: {
            Text(MobileAudioPlaybackSpeed.label(for: vm.speed))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 64, minHeight: MobileDesign.Metrics.minimumTouchTarget)
                .background(.thinMaterial, in: Capsule())
        }
        .accessibilityLabel("Playback speed")
    }

    @ViewBuilder
    private var nextChapterControl: some View {
        if let nextChapter = vm.nextBookChapter(after: displayedItem.id) {
            if vm.isPreparingAudio(sourceID: nextChapter.id) {
                HStack(spacing: MobileDesign.Spacing.medium) {
                    MobileTextToSpeechProgressIndicator(
                        progress: vm.textToSpeechGenerationProgress(sourceID: nextChapter.id)
                    )
                    VStack(alignment: .leading, spacing: MobileDesign.Spacing.xSmall) {
                        Text("Generating Next Chapter")
                            .font(.subheadline.weight(.semibold))
                        Text(nextChapter.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(MobileDesign.Spacing.medium)
                .mobileFloatingSurface(cornerRadius: MobileDesign.Radius.compact)
                .accessibilityIdentifier("listen.generatingNextChapter")
            } else {
                let isReady = vm.hasSyncedTextToSpeechAudio(sourceID: nextChapter.id)
                Button {
                    Task {
                        if isReady {
                            await vm.playNextBookChapter(after: displayedItem.id)
                        } else {
                            await vm.prepareNextBookChapter(after: displayedItem.id)
                        }
                    }
                } label: {
                    VStack(spacing: MobileDesign.Spacing.xSmall) {
                        Label(
                            isReady ? "Play Next Chapter" : "Generate Audio for Next Chapter",
                            systemImage: isReady ? "play.fill" : "waveform.badge.plus"
                        )
                        .font(.subheadline.weight(.semibold))
                        Text(nextChapter.title)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, MobileDesign.Spacing.small)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(
                    isReady ? "listen.playNextChapter" : "listen.generateNextChapter"
                )
            }
        }
    }

    private var playerBackground: some View {
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.12),
                Color(uiColor: .systemBackground),
                Color(uiColor: .systemBackground),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var displayedItem: MobileAudioItem {
        vm.currentItem ?? item
    }

    private var displayedSource: MobileCloudSource? {
        vm.allSources.first { $0.id == displayedItem.id }
    }

    private var showsNextChapterControl: Bool {
        vm.currentItem?.id == displayedItem.id
            && !vm.isPlaying
            && vm.duration > 0
            && vm.currentTime >= vm.duration - 1
            && vm.nextBookChapter(after: displayedItem.id) != nil
    }

    private var scrubbedTime: TimeInterval? {
        scrubbedFraction.map { $0 * vm.duration }
    }

    private var remainingTime: TimeInterval {
        max(vm.duration - (scrubbedTime ?? vm.currentTime), 0)
    }

    private func formattedTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

struct MobileTextToSpeechProgressIndicator: View {
    let progress: MobileTextToSpeechGenerationProgress?
    var download: MobileNarrationDownloadProgress? = nil

    var body: some View {
        if let progress {
            ring(fraction: progress.fractionCompleted, percent: progress.percentCompleted)
                .accessibilityLabel("Audio generation progress")
        } else if let download {
            ring(fraction: download.fractionCompleted, percent: download.percentCompleted)
                .accessibilityLabel("Narration download progress")
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private func ring(fraction: Double, percent: Int) -> some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
        .accessibilityValue("\(percent) percent")
    }
}

struct MobileTextToSpeechProgressText: View {
    let detail: String?
    let progress: MobileTextToSpeechGenerationProgress?
    /// A narration coming down from iCloud. Shown when nothing is being
    /// generated: the counts are the whole story, so no phase text is needed.
    var download: MobileNarrationDownloadProgress? = nil

    var body: some View {
        if let progress {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                // The model on its own line: the status line is already the
                // width of a phone, and which model is narrating is worth a
                // line of its own when it is being paid for.
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusLabel(progress: progress, at: context.date))
                        .font(.caption.monospacedDigit())
                    Text(progress.modelName)
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityElement(children: .combine)
            }
        } else if let download {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(download.statusLabel(at: context.date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            Text(detail ?? "Preparing audio…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func statusLabel(
        progress: MobileTextToSpeechGenerationProgress,
        at date: Date
    ) -> String {
        if progress.completedChunks == 0 {
            let elapsed = max(0, Int(date.timeIntervalSince(progress.startedAt).rounded(.down)))
            let phase = detail?.replacingOccurrences(of: "…", with: "")
                ?? "Generating first chunk"
            return "\(phase) · \(elapsed)s"
        }

        var parts: [String] = []
        if detail?.hasPrefix("Playing") == true {
            parts.append("Playing")
        } else if detail?.hasPrefix("First chunk ready") == true {
            parts.append("First chunk ready")
        } else if detail?.hasPrefix("Waiting") == true {
            parts.append("Waiting for the next section")
        }
        parts += [
            "\(progress.completedChunks) of \(progress.totalChunks) chunks",
            "\(progress.percentCompleted)%",
        ]
        if let remaining = progress.estimatedRemaining(at: date) {
            parts.append(formatDuration(remaining))
        }
        return parts.joined(separator: " · ")
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let rounded = max(1, Int(seconds.rounded(.up)))
        if rounded < 60 { return "\(rounded)s left" }
        let minutes = rounded / 60
        let remainder = rounded % 60
        if minutes < 60 {
            return remainder == 0
                ? "\(minutes)m left"
                : String(format: "%d:%02d left", minutes, remainder)
        }
        return String(format: "%d:%02d left", minutes / 60, minutes % 60)
    }
}

/// The Mac's source-type visual identity, keyed by the phone's canonical
/// lowercase type strings, so a paper looks like the same paper on both
/// screens. Buttons get the Mac sidebar's full-color SVG badges (copied into
/// the iOS asset catalog); rows and fallbacks use SourceThumbnail.swift's
/// symbol + color pairs.
enum MobileSourceTypeStyle {
    /// The Mac sidebar's badge asset, when that type has one. X is a template
    /// asset so its bare monochrome mark follows the current foreground style.
    static func assetName(for sourceType: String) -> String? {
        switch sourceType {
        case "article": return "ArticlesIcon"
        case "paper": return "PapersIcon"
        case "book": return "BooksIcon"
        case "course": return "CoursesIcon"
        case "meeting": return "MeetingsIcon"
        case "podcast": return "ApplePodcastsIcon"
        case "video": return "YouTubeIcon"
        case "xpost": return "XIcon"
        default: return nil
        }
    }

    static func icon(for sourceType: String) -> String {
        switch sourceType {
        case "paper": return "doc.text.magnifyingglass"
        case "podcast": return "headphones"
        case "book": return "book.closed"
        case "course": return "graduationcap"
        case "meeting": return "person.2.wave.2"
        case "video": return "play.rectangle"
        case "xpost": return "bubble.left"
        default: return "doc.richtext"
        }
    }

    static func color(for sourceType: String) -> Color {
        switch sourceType {
        case "paper": return .purple
        case "podcast": return .orange
        case "book": return .green
        case "course": return .indigo
        case "meeting": return .teal
        case "video": return .red
        case "xpost": return .primary
        default: return .blue
        }
    }
}

struct MobileSourceTypeGlyph: View {
    let sourceType: String
    let pointSize: CGFloat
    var weight: Font.Weight = .regular

    @ViewBuilder
    var body: some View {
        if sourceType == "xpost" {
            Image("XIcon")
                .resizable()
                .scaledToFit()
                .frame(width: pointSize, height: pointSize)
        } else {
            Image(systemName: MobileSourceTypeStyle.icon(for: sourceType))
                .font(.system(size: pointSize, weight: weight))
        }
    }
}

/// One type's list entry on the browser root.
struct MobileSourceTypeSelection: Hashable {
    let sourceType: String
    let label: String
}

/// The geometry shared by artwork and its tinted icon fallback. Books keep a
/// portrait silhouette, while video and course frames stay landscape.
private enum MobileThumbnailLayout {
    static let square = CGSize(width: 42, height: 42)
    static let bookCover = CGSize(width: 36, height: 48)
    static let landscape = CGSize(width: 52, height: 34)

    static func artworkSize(for sourceType: String) -> CGSize {
        sourceType == "video" || sourceType == "course" ? landscape : square
    }

    static func cornerRadius(for size: CGSize) -> CGFloat {
        size.width == size.height ? 8 : 6
    }
}

struct MobileSourceIconTile: View {
    let sourceType: String
    var tint: Color? = nil
    var size = MobileThumbnailLayout.square

    var body: some View {
        let color = tint ?? MobileSourceTypeStyle.color(for: sourceType)
        MobileSourceTypeGlyph(
            sourceType: sourceType,
            pointSize: max(12, min(size.width, size.height) * 0.42)
        )
            .foregroundStyle(color)
            .frame(width: size.width, height: size.height)
            .background(color.opacity(0.10))
            .clipShape(
                RoundedRectangle(
                    cornerRadius: MobileThumbnailLayout.cornerRadius(for: size),
                    style: .continuous
                )
            )
    }
}

/// The Mac's `SourceThumbnail`, phone edition: remote artwork when the synced
/// source carries any (podcast feed art, the derived YouTube frame), the
/// tinted type icon otherwise. Images load lazily per row and land in the
/// shared memory + disk caches, so a list only pays the network once.
struct MobileSourceRowThumbnail: View {
    let source: MobileCloudSource
    var isActive: Bool = false

    @ViewBuilder
    var body: some View {
        if source.sourceType == "book" {
            if source.parentGroup == nil {
                MobileBookCoverThumbnail(recordName: nil)
            } else {
                MobileBookChapterThumbnail(
                    chapterNumber: source.courseSortIndex.map { $0 + 1 },
                    isActive: isActive
                )
            }
        } else if source.sourceType == "paper" {
            MobilePaperThumbnail(source: source, isActive: isActive)
        } else {
            let size = MobileThumbnailLayout.artworkSize(for: source.sourceType)
            Group {
                if let url = source.thumbnailURL {
                    CachedAsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .failure:
                            iconFallback(size: size)
                        default:
                            RoundedRectangle(
                                cornerRadius: MobileThumbnailLayout.cornerRadius(for: size),
                                style: .continuous
                            )
                            .fill(.quaternary)
                        }
                    }
                } else {
                    iconFallback(size: size)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: MobileThumbnailLayout.cornerRadius(for: size),
                    style: .continuous
                )
            )
        }
    }

    private func iconFallback(size: CGSize) -> some View {
        MobileSourceIconTile(
            sourceType: source.sourceType,
            tint: isActive ? Color.accentColor : nil,
            size: size
        )
    }
}

/// A chapter is one page inside its book, not another copy of the book cover.
/// The stable sort index gives it a useful visual identity without parsing a
/// human-authored title or loading any document data while the list scrolls.
private struct MobileBookChapterThumbnail: View {
    let chapterNumber: Int?
    let isActive: Bool

    private var tint: Color { isActive ? .accentColor : .green }

    var body: some View {
        VStack(spacing: 4) {
            if let chapterNumber {
                Text(chapterNumber.formatted())
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            } else {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 13, weight: .medium))
            }

            Capsule()
                .fill(tint.opacity(0.28))
                .frame(width: 16, height: 2)
        }
        .foregroundStyle(tint)
        .frame(
            width: MobileThumbnailLayout.bookCover.width,
            height: MobileThumbnailLayout.bookCover.height
        )
        .background(tint.opacity(0.08))
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// The paper's real first page when the Mac synced one; a compact citation card
/// remains the fallback for papers without a local/readable PDF.
private struct MobilePaperThumbnail: View {
    let source: MobileCloudSource
    let isActive: Bool

    @State private var thumbnail: UIImage?

    private var tint: Color { isActive ? .accentColor : .purple }

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                fallback
            }
        }
        .frame(
            width: MobileThumbnailLayout.bookCover.width,
            height: MobileThumbnailLayout.bookCover.height
        )
        .background(Color(uiColor: .secondarySystemBackground))
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(tint.opacity(thumbnail == nil ? 0.18 : 0.10), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .task(id: source.id) {
            thumbnail = await MobileSourceArtworkLoader.paperThumbnail(sourceID: source.id)
        }
    }

    private var fallback: some View {
        VStack(spacing: 4) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 13, weight: .medium))

            Text(yearLabel)
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tint.opacity(0.08))
    }

    private var yearLabel: String {
        guard let publishedYear = source.publishedYear, !publishedYear.isEmpty else { return "PDF" }
        return publishedYear
    }
}

/// A book group row's cover: the Book record's synced `bookCoverAsset`,
/// fetched once and cached; the tinted book icon until it arrives, or
/// forever when the Mac never uploaded one.
private struct MobileBookCoverThumbnail: View {
    let recordName: String?

    @State private var cover: UIImage?

    var body: some View {
        Group {
            if let cover {
                Image(uiImage: cover)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                MobileSourceIconTile(sourceType: "book", size: MobileThumbnailLayout.bookCover)
            }
        }
        .frame(
            width: MobileThumbnailLayout.bookCover.width,
            height: MobileThumbnailLayout.bookCover.height
        )
        .background(Color.green.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .task(id: recordName) {
            guard cover == nil, let recordName else { return }
            cover = await MobileSourceArtworkLoader.bookCover(recordName: recordName)
        }
    }
}

/// The artwork the Mac synced as a CloudKit asset rather than a URL: a paper's
/// rendered first page and a book's cover. Row thumbnails and the Now Playing
/// tile share these so both read the same memory cache and the same disk copy,
/// and a source never pays the record fetch twice.
enum MobileSourceArtworkLoader {
    static func paperThumbnail(sourceID: String) async -> UIImage? {
        let key = "paper-thumbnail-ck:\(sourceID)"
        if let cached = ImageCache.shared.image(for: key) { return cached }
        guard let fetched = await MobileSourceFileStore.shared.fetchPaperThumbnail(sourceID: sourceID) else {
            return nil
        }
        ImageCache.shared.set(fetched, for: key)
        return fetched
    }

    static func bookCover(recordName: String) async -> UIImage? {
        let key = "book-cover-ck:\(recordName)"
        if let cached = ImageCache.shared.image(for: key) { return cached }
        guard let fetched = await MobileSourceFileStore.shared.fetchBookCover(recordName: recordName) else {
            return nil
        }
        ImageCache.shared.set(fetched, for: key)
        return fetched
    }

    /// The synced image for one source, if its type has one: papers show their
    /// first page, book chapters show their book's cover. Everything else
    /// (podcasts, videos, articles) either has a `thumbnailURL` or nothing.
    static func localArtwork(
        for source: MobileCloudSource,
        collections: MobileCatalogCollections
    ) async -> UIImage? {
        switch source.sourceType {
        case "paper":
            return await paperThumbnail(sourceID: source.id)
        case "book":
            guard let group = source.parentGroup,
                  let recordName = collections.booksByID[group]?.recordName else {
                return nil
            }
            return await bookCover(recordName: recordName)
        default:
            return nil
        }
    }
}

/// Course containers use the first lecture's YouTube frame, matching the Mac
/// sidebar. Keeping the landscape shape avoids cutting off most of the frame.
private struct MobileCourseCoverThumbnail: View {
    let artworkURL: URL?

    var body: some View {
        let size = MobileThumbnailLayout.landscape
        Group {
            if let artworkURL {
                CachedAsyncImage(url: artworkURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var placeholder: some View {
        MobileSourceIconTile(sourceType: "course", size: MobileThumbnailLayout.landscape)
    }
}

private struct MobileSourceTypeButtonRow: View {
    let sourceType: String
    let label: String
    let count: Int

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let asset = MobileSourceTypeStyle.assetName(for: sourceType) {
                Image(asset)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                MobileSourceTypeGlyph(sourceType: sourceType, pointSize: 16, weight: .semibold)
                    .foregroundStyle(MobileSourceTypeStyle.color(for: sourceType))
                    .frame(width: 34, height: 34)
                    .background(
                        MobileSourceTypeStyle.color(for: sourceType).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
            }

            Text(label)
                .font(.body)
                .foregroundStyle(.primary)

            Spacer(minLength: 0)

            Text(count.formatted())
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.horizontal, MobileDesign.Spacing.small)
                .padding(.vertical, MobileDesign.Spacing.xSmall)
                .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
        }
        .padding(.vertical, MobileDesign.Spacing.xSmall)
    }
}

/// One type's contents. Books and courses list their containers (chapters and
/// lectures one level deeper, in the Mac's order); every other type lists its
/// sources newest first.
struct MobileSourceTypeScreen: View {
    let selection: MobileSourceTypeSelection

    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @State private var query = ""

    private var isSearching: Bool {
        !MobileSourceListSearch.terms(in: query).isEmpty
    }

    var body: some View {
        List {
            if MobileSourceGrouping.isGroupedType(selection.sourceType) {
                let split = MobileSourceGrouping.groups(
                    ofType: selection.sourceType,
                    in: browsableSources,
                    collections: vm.collections
                )
                // Under search a book found by its title stays a book; a chapter
                // found by its own name is listed as a row, so the learner does
                // not have to know which container holds it.
                let shown = MobileSourceListSearch.filter(
                    groups: split.groups,
                    standalone: split.standalone,
                    query: query
                )
                if isSearching, shown.groups.isEmpty, shown.members.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .listRowBackground(Color.clear)
                }
                ForEach(shown.groups) { group in
                    NavigationLink {
                        // A course opens its page: the path with its checks,
                        // quizzes and gate, as on the Mac.
                        if selection.sourceType == "course" {
                            MobileCoursePageScreen(courseID: group.id)
                        } else {
                            MobileSourceGroupScreen(group: group)
                        }
                    } label: {
                        MobileSourceGroupRow(sourceType: selection.sourceType, group: group)
                    }
                }
                if !shown.members.isEmpty {
                    Section {
                        ForEach(shown.members) { source in
                            MobileBrowserSourceLink(source: source)
                        }
                    }
                }
            } else {
                let shown = MobileSourceListSearch.filter(typedSources, query: query)
                if isSearching, shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .listRowBackground(Color.clear)
                }
                ForEach(shown) { source in
                    MobileBrowserSourceLink(source: source)
                }
            }

            if !isSearching {
                paywalledShelf
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(selection.label)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search \(selection.label)")
        .refreshable {
            await vm.load(forceRefresh: true)
        }
        .task {
            // Type screens can remain on the navigation stack while the Mac
            // adds sources. Entering one must refresh independently of the
            // parent Sources screen, and pull-to-refresh above must be real.
            await vm.load(forceRefresh: true)
        }
    }

    /// The one way into the marked-paywalled sources of this type. They are off
    /// the list above because none of them has text or a document to open, but
    /// they are still in the library and still worth finding — the Mac keeps
    /// the same rows behind a collapsed "Marked paywalled" header.
    @ViewBuilder
    private var paywalledShelf: some View {
        let paywalled = MobilePaywallShelf.paywalled(vm.allSources, ofType: selection.sourceType)
        if !paywalled.isEmpty {
            Section {
                NavigationLink {
                    MobilePaywalledSourcesScreen(label: selection.label, sources: paywalled)
                } label: {
                    Label("Paywalled (\(paywalled.count))", systemImage: "lock")
                }
                .accessibilityIdentifier("browser.paywalledShelf")
            }
        }
    }

    private var browsableSources: [MobileCloudSource] {
        MobileSourceListing.listed(vm.allSources)
    }

    private var typedSources: [MobileCloudSource] {
        browsableSources.filter { $0.sourceType == selection.sourceType }
    }
}

/// The marked-paywalled shelf for one type. Every row here is a source the Mac
/// could not get text or a PDF for, so the screen says that once rather than
/// letting each row fail on its own when tapped.
struct MobilePaywalledSourcesScreen: View {
    let label: String
    let sources: [MobileCloudSource]

    var body: some View {
        List {
            Section {
                ForEach(sources) { source in
                    MobileBrowserSourceLink(source: source)
                }
            } footer: {
                Text("These are behind a paywall, so no text or PDF synced for them. Attach a PDF on your Mac and they move back into \(label).")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Paywalled")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MobileSourceGroupRow: View {
    let sourceType: String
    let group: MobileSourceGroup

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if sourceType == "book" {
                MobileBookCoverThumbnail(recordName: group.coverRecordName)
            } else if sourceType == "course" {
                MobileCourseCoverThumbnail(artworkURL: courseArtworkURL)
            } else if sourceType == "meeting" {
                Image("MeetingsIcon")
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                MobileSourceIconTile(sourceType: sourceType)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(group.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(subtitleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            // The same headphones the chapter rows inside wear once their
            // audio lands: here it means every chapter has it.
            if sourceType == "book", group.isAudiobookComplete {
                Image(systemName: "headphones")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Audiobook ready")
            }
        }
        .padding(.vertical, 2)
    }

    private var courseArtworkURL: URL? {
        for source in group.sources {
            if let url = source.thumbnailURL { return url }
        }
        return nil
    }

    private var subtitleText: String {
        let count = group.sources.count
        var parts = [group.memberSummary ?? "\(count) \(count == 1 ? "item" : "items")"]
        if let subtitle = group.subtitle, !subtitle.isEmpty {
            parts.insert(subtitle, at: 0)
        }
        return parts.joined(separator: " · ")
    }
}

/// One book or course: its chapters, or its Lectures / Papers / Materials
/// folders, in the Mac's order.
struct MobileSourceGroupScreen: View {
    let group: MobileSourceGroup

    @State private var query = ""

    private var isSearching: Bool {
        !MobileSourceListSearch.terms(in: query).isEmpty
    }

    var body: some View {
        List {
            if group.sections.isEmpty {
                let shown = MobileSourceListSearch.filter(group.sources, query: query)
                if isSearching, shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .listRowBackground(Color.clear)
                }
                ForEach(shown) { source in
                    MobileBrowserSourceLink(
                        source: source,
                        subtitleStyle: .titleOnly
                    )
                }
            } else {
                let shown = MobileSourceListSearch.filter(sections: group.sections, query: query)
                if isSearching, shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .listRowBackground(Color.clear)
                }
                ForEach(shown) { section in
                    Section {
                        ForEach(section.items) { item in
                            MobileBrowserSourceLink(
                                source: item.source,
                                subtitleStyle: .titleOnly,
                                displayTitle: item.displayTitle
                            )
                        }
                    } header: {
                        Label(section.title, systemImage: section.systemImage)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(group.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search \(group.title)")
    }
}

/// Add a Notebook to Context (docs/notebooks-design.md, "iPhone"): the
/// notebooks this one does not link to yet. A tap links the one picked and
/// puts it into this notebook's chats in one step (`MobileNotebookContextLinks.add`),
/// as the Mac's "Uses context from" + does; its group's × in Sources takes it
/// out again.
struct MobileRelatedNotebooksPickerSheet: View {
    let notebook: MobileCloudNotebook
    @ObservedObject var selection: MobileNotebookChatSelectionStore

    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// The notebook being linked and put in.
    @State private var adding: String?

    /// The notebook as it stands now, so a link made since the sheet opened
    /// is not offered again.
    private var currentNotebook: MobileCloudNotebook {
        vm.notebooks.first { $0.id == notebook.id } ?? notebook
    }

    private var candidates: [MobileCloudNotebook] {
        let all = MobileNotebookContextPicker.candidates(for: currentNotebook, in: vm.notebooks)
        let terms = MobileSourceListSearch.terms(in: query)
        guard !terms.isEmpty else { return all }
        return all.filter { candidate in
            let title = MobileSourceListSearch.folded(candidate.title)
            return terms.allSatisfy { title.contains($0) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if candidates.isEmpty {
                    Text(query.isEmpty ? "No other notebooks to add." : "No notebook matches.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(candidates) { candidate in
                    candidateRow(candidate)
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search notebooks")
            .navigationTitle("Add to Context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func candidateRow(_ candidate: MobileCloudNotebook) -> some View {
        let title = NotebookTitle(candidate.title)
        let name = title.text.isEmpty ? "Untitled notebook" : title.text
        let count = vm.notebookSources(in: candidate).count
        return Button {
            Task { await add(candidate) }
        } label: {
            HStack(spacing: MobileDesign.Spacing.medium) {
                MobileNotebookIconView(notebookID: candidate.id, size: 28, cornerRadius: 7) {
                    Text(title.displayIcon)
                        .font(.title3)
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(count == 1 ? "1 source" : "\(count) sources")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if adding == candidate.id {
                    ProgressView()
                }
            }
            .frame(minHeight: MobileDesign.Metrics.minimumTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(adding != nil || vm.isMutatingLibrary)
        .accessibilityLabel("Add \(name) to context")
        .accessibilityIdentifier("notebook.context.candidate")
    }

    private func add(_ candidate: MobileCloudNotebook) async {
        guard adding == nil else { return }
        adding = candidate.id
        defer { adding = nil }
        if await MobileNotebookContextLinks.add(candidate, to: currentNotebook, vm: vm, selection: selection) {
            dismiss()
        }
    }
}

/// A source row that opens the reader, with a swipe to start talking about
/// exactly this source (scoped to the notebook when opened inside one).
struct MobileBrowserSourceLink: View {
    enum SubtitleStyle {
        case citation
        /// Inside a book or course the type and container repeat every row;
        /// showing just the title reads cleaner.
        case titleOnly
    }

    let source: MobileCloudSource
    var subtitleStyle: SubtitleStyle = .citation
    /// The Mac's lecture numbering ("3) Architectures") when this row stands
    /// for a lecture; nil keeps the source's own title.
    var displayTitle: String? = nil
    var notebook: MobileCloudNotebook? = nil
    /// In a notebook's Sources tab, the row's box for the notebook's chat,
    /// beside the link so a tick never opens the Reader.
    var chatTick: MobileSourceChatTick? = nil
    /// In a notebook's Sources tab, Remove from Notebook, for a source the
    /// notebook holds itself (never a row of a context notebook's group).
    var onRemoveFromNotebook: (() -> Void)? = nil
    /// In a notebook's Sources search, the + on a library source the notebook
    /// does not list, beside the link so adding never opens the Reader (and
    /// opening never adds).
    var notebookAdd: MobileSourceNotebookAdd? = nil

    @ObservedObject private var live = MobileVoiceConversationController.shared
    @ObservedObject private var offline = MobileOfflineLibrary.shared
    @ObservedObject private var pdfExport = MobileSourcePDFExport.shared
    @ObservedObject private var sharing = MobileSourceShare.shared
    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @State private var actionDestination: MobileSourceActionDestination?
    @State private var confirmsDelete = false

    var body: some View {
        HStack(spacing: MobileDesign.Spacing.small) {
            // A destination, not a typed route: a source's list (a type's, a group's,
            // the paywalled shelf) is itself pushed as a destination, and a route pushed
            // from inside one lands under it, so the Reader slid in and was covered by
            // the list again (2026-10-26). A destination always opens on top of the
            // screen it was tapped on.
            NavigationLink {
                MobileShellSourceDestination(sourceID: source.id, notebookID: notebook?.id)
            } label: {
                MobileBrowserSourceRow(
                    source: source,
                    subtitleStyle: subtitleStyle,
                    displayTitle: displayTitle,
                    isActive: live.activeSourceTitle == source.title,
                    isPreparingAudio: vm.isPreparingAudio(sourceID: source.id),
                    isCurrentAudio: vm.currentItem?.id == source.id,
                    isPlaying: vm.isPlaying,
                    isAudioReady: isAudioReady,
                    downloadFraction: vm.narrationDownloadFraction(sourceID: source.id),
                    offlineState: offline.state(for: source.id),
                    isPreparingPDF: pdfExport.preparingSourceIDs.contains(source.id) || sharing.preparingSourceIDs.contains(source.id)
                )
            }
            .accessibilityIdentifier("browser.sourceRow")

            if let chatTick {
                MobileChatTickBox(
                    state: chatTick.isOn ? .checked : .unchecked,
                    label: "Include \(source.title) in chat",
                    isEnabled: chatTick.isEnabled,
                    action: chatTick.toggle
                )
                .accessibilityIdentifier("notebook.source.tick")
            }

            if let notebookAdd {
                MobileNotebookAddButton(
                    add: notebookAdd,
                    label: "Add \(source.title) to \(notebook?.title ?? "the notebook")"
                )
                .accessibilityIdentifier("notebook.source.add")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Task { await vm.toggleTextToSpeech(sourceID: source.id) }
            } label: {
                Label(listenActionTitle, systemImage: listenActionIcon)
            }
            .tint(.blue)
            .disabled(vm.isPreparingAudio(sourceID: source.id))

        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                Task { await sharing.share(source) }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .tint(.accentColor)
            .disabled(sharing.preparingSourceIDs.contains(source.id))
            if let onRemoveFromNotebook {
                Button("Remove", systemImage: "folder.badge.minus", role: .destructive) {
                    onRemoveFromNotebook()
                }
            }
        }
        .contextMenu {
            Button(listenActionTitle, systemImage: listenActionIcon) {
                Task { await vm.toggleTextToSpeech(sourceID: source.id) }
            }
            .disabled(vm.isPreparingAudio(sourceID: source.id))
            if MobileExplainerStatus.isExplainable(source) {
                MobileExplainerMenuButton(source: source)
            }
            MobileSourceShareButtons(source: source)
            MobileOfflineSaveButton(source: source)
            Divider()
            Button("Add to Notebook", systemImage: "folder.badge.plus") {
                actionDestination = .notebook
            }
            Button("Schedule", systemImage: "calendar.badge.plus") {
                actionDestination = .schedule
            }
            Button("Log as Listened", systemImage: "headphones") {
                Task {
                    _ = await vm.recordExternalSourceCompletions(
                        sourceIDs: [source.id],
                        kind: .listening
                    )
                }
            }
            Divider()
            Button("Archive Source", systemImage: "archivebox") {
                Task { _ = await vm.archiveSource(source) }
            }
            Button("Delete Source", systemImage: "trash", role: .destructive) {
                confirmsDelete = true
            }
        }
        .mobileSourceActionSheets(
            destination: $actionDestination,
            source: source,
            suggestedNotebook: notebook
        )
        .confirmationDialog("Delete this source everywhere?", isPresented: $confirmsDelete) {
            Button("Delete Source", role: .destructive) {
                Task { _ = await vm.deleteSource(source) }
            }
        } message: {
            Text("The source will be removed from the library, Notebooks, and Schedule on every device.")
        }
        // Saving offline is started from this row's menu, so what came of it
        // belongs here. The reader has its own banner; a list row has nowhere
        // quieter to put this, and a save that silently does nothing — or that
        // silently saved less than the user asked for — is the worse outcome.
        .alert(
            offlineNoticeTitle,
            isPresented: Binding(
                // This row shows its failure only when it is the one the queue
                // is holding, no higher-priority alert is waiting, and this
                // row's own delete confirmation is not on screen. A bulk save
                // failing for several sources would otherwise raise one alert
                // per row in the same runloop turn, and UIKit aborts the
                // process rather than queue them. See `MobileAsyncAlert`.
                get: {
                    guard !confirmsDelete else { return false }
                    return MobileAsyncAlert.resolve(
                        textToSpeechCostPending: vm.textToSpeechCostConfirmation != nil,
                        bookContinuationPending: vm.bookContinuationOffer != nil,
                        offlineFailureSourceID: offline.surfacedFailureSourceID
                    ) == .offlineSaveFailure(sourceID: source.id)
                },
                set: { isPresented in
                    guard !isPresented else { return }
                    offline.clearFailure(sourceID: source.id)
                }
            )
        ) {
            Button("OK", role: .cancel) {}
                .accessibilityIdentifier("source.offlineFailure.ok")
        } message: {
            Text(offline.failureMessage(for: source.id) ?? "")
        }
    }

    /// The same slot carries a refusal and a partial save, so the title has to
    /// follow the outcome: a saved paper whose document could not be downloaded
    /// is still saved.
    private var offlineNoticeTitle: String {
        if case .saved = offline.state(for: source.id) {
            return "Saved Without the Document"
        }
        return "Couldn’t Save Offline"
    }

    private var isAudioReady: Bool {
        vm.hasSyncedTextToSpeechAudio(sourceID: source.id)
    }

    private var listenActionTitle: String {
        if vm.isPreparingAudio(sourceID: source.id) { return "Generating" }
        guard vm.currentItem?.id == source.id else { return "Listen" }
        return vm.isPlaying ? "Pause" : "Resume"
    }

    private var listenActionIcon: String {
        if vm.isPreparingAudio(sourceID: source.id) { return "waveform" }
        guard vm.currentItem?.id == source.id else { return "headphones" }
        return vm.isPlaying ? "pause.fill" : "play.fill"
    }

}

struct MobileBrowserSourceRow: View {
    let source: MobileCloudSource
    let subtitleStyle: MobileBrowserSourceLink.SubtitleStyle
    var displayTitle: String? = nil
    let isActive: Bool
    let isPreparingAudio: Bool
    let isCurrentAudio: Bool
    let isPlaying: Bool
    let isAudioReady: Bool
    /// Set while this narration's audio is coming down from iCloud.
    var downloadFraction: Double? = nil
    let offlineState: MobileOfflineLibrary.SaveState
    /// Share PDF… or Show in Files from this row's menu is downloading the
    /// document first.
    var isPreparingPDF = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            MobileSourceRowThumbnail(source: source, isActive: isActive)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle ?? source.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let subtitle = subtitleText {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if source.isPaywalled {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Paywalled")
            }

            if isPreparingPDF {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Downloading PDF")
            }

            switch offlineState {
            case .saved:
                MobileOfflineRowBadge(isSaving: false)
            case .saving:
                MobileOfflineRowBadge(isSaving: true)
            case .notSaved, .failed:
                EmptyView()
            }

            if let downloadFraction {
                ProgressView(value: downloadFraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .accessibilityLabel("Downloading narration")
            } else if isPreparingAudio {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Preparing audio")
            } else if isCurrentAudio {
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.circle")
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel(isPlaying ? "Playing" : "Paused")
            } else if isActive {
                Image(systemName: "waveform")
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
            } else if isAudioReady {
                Image(systemName: "headphones")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Audio ready")
            }
        }
        .padding(.vertical, MobileDesign.Spacing.xSmall)
    }

    private var subtitleText: String? {
        switch subtitleStyle {
        case .titleOnly:
            return nil
        case .citation:
            var parts = [source.sourceType.capitalized]
            if let subtitle = source.citationSubtitle, !subtitle.isEmpty {
                parts.insert(subtitle, at: 0)
            }
            // Searching still turns these up, and the row has to be honest
            // about why opening it will not show anything to read.
            if source.isPaywalled {
                parts.append("Paywalled")
            }
            return parts.joined(separator: " · ")
        }
    }
}

/// The empty Sources list, saying where a library comes from. The phone only
/// shows what a Mac syncs through iCloud, and a Mac can keep everything to
/// itself (Settings › iCloud › Storage), so "No Sources" alone read as a
/// broken app (product owner, 2026-09-22).
private struct MobileEmptyLibraryView: View {
    var body: some View {
        if FileManager.default.ubiquityIdentityToken == nil {
            ContentUnavailableView {
                Label("Not Signed In to iCloud", systemImage: "icloud.slash")
            } description: {
                Text("Your library reaches this iPhone through iCloud. Sign in under Settings › your name, with the same Apple Account as your Mac.")
            }
            .accessibilityIdentifier("sources.emptyNoICloud")
        } else {
            ContentUnavailableView {
                Label("No Sources", systemImage: "books.vertical")
            } description: {
                Text("Your library syncs here from ForeverLM on your Mac, through iCloud. If your Mac keeps everything on that Mac, nothing arrives: choose Sync with iCloud in its Settings › Data & Privacy.")
            }
            .accessibilityIdentifier("sources.empty")
        }
    }
}
