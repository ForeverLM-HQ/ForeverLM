#if os(macOS)
import AppKit
import AVKit
import SwiftUI

// MARK: - Requests

/// The pane should select this video: set by the coordinator when a film is
/// finished, and by anything that wants a video brought forward. Stamped so
/// the same video can be asked for twice.
struct ExplainerVideoRevealRequest: Equatable {
    let id = UUID()
    let sourceID: String
}

/// The pane should open its composer with these fields filled — a paper's
/// menu asking for a video about the paper.
struct ExplainerVideoComposeRequest: Equatable {
    let id = UUID()
    var concept: String?
    var sourceID: String?
}

// MARK: - The pane

/// Videos: the explainer films ForeverLM has made, and the composer that makes
/// one. A place, not a document — every click on the rail's row lands here with
/// the last video still selected. The list on the left, the film on the right.
struct ExplainerVideosPane: View {
    @Environment(StudioViewModel.self) private var vm
    @ObservedObject private var coordinator = ExplainerVideoGenerationCoordinator.shared
    @State private var selectedVideoID: String?

    private var videos: [StudioArticle] {
        vm.articles
            .filter { GeneratedExplainerVideo.isVideoURL($0.url) }
            .sorted { $0.dateAdded > $1.dateAdded }
    }

    private var selectedVideo: StudioArticle? {
        guard let selectedVideoID else { return nil }
        return videos.first { $0.id == selectedVideoID }
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .studioChromeLineHeader {
                toolbar
                    .padding(.horizontal, 16)
                    .background(WindowDragBlocker())
            }
            .studioCenterTabCloseChrome(for: .videos)
            .sheet(item: $coordinator.composeDraft) { draft in
                ExplainerVideoComposeSheet(draft: draft) { request in
                    Task { await coordinator.generate(request, in: vm) }
                }
            }
            .onChange(of: vm.explainerVideoRevealRequest) { _, request in
                guard let request else { return }
                selectedVideoID = request.sourceID
                vm.explainerVideoRevealRequest = nil
            }
            .onChange(of: vm.explainerVideoComposeRequest, initial: true) { _, request in
                guard let request else { return }
                coordinator.compose(concept: request.concept, sourceID: request.sourceID)
                vm.explainerVideoComposeRequest = nil
            }
            .onAppear {
                if selectedVideoID == nil, let first = videos.first { selectedVideoID = first.id }
            }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Spacer()
            Button {
                coordinator.compose()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.hoverWash)
            .help("New video")
            .accessibilityIdentifier("studio.videos.new")
        }
    }

    @ViewBuilder
    private var content: some View {
        if videos.isEmpty && coordinator.jobs.isEmpty {
            ContentUnavailableView {
                Label("No videos yet", systemImage: "film")
            } actions: {
                Button("New Video") {
                    coordinator.compose()
                }
            }
        } else {
            HStack(spacing: 0) {
                list
                    .frame(width: 300)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(coordinator.jobs) { job in
                    ExplainerVideoJobRow(job: job) { coordinator.cancel(job.id) }
                }
                ForEach(videos) { video in
                    ExplainerVideoRow(
                        video: video,
                        isSelected: video.id == selectedVideoID,
                        select: { selectedVideoID = video.id },
                        openInReader: { Task { await vm.selectArticle(video.id, revealingReader: true) } },
                        delete: { Task { await vm.removeArticle(id: video.id) } }
                    )
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selectedVideo {
            ExplainerVideoDetailView(video: selectedVideo)
                .id(selectedVideo.id)
        } else {
            ContentUnavailableView {
                Label("Choose a video", systemImage: "film")
            }
        }
    }
}

// MARK: - Rows

private struct ExplainerVideoJobRow: View {
    let job: ExplainerVideoGenerationCoordinator.Job
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 64, height: 36)
                .overlay { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 3) {
                Text(job.concept)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                Text(job.stage.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ProgressView(value: job.stage.fraction)
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
            Button(action: cancel) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.hoverWash)
            .help("Cancel")
        }
        .padding(8)
        // A group of its own: on a plain container the identifier landed on
        // the Cancel button and every text.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.videos.job")
    }
}

private struct ExplainerVideoRow: View {
    let video: StudioArticle
    let isSelected: Bool
    let select: () -> Void
    let openInReader: () -> Void
    let delete: () -> Void
    @State private var poster: NSImage?
    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            HStack(alignment: .center, spacing: 10) {
                Group {
                    if let poster {
                        Image(nsImage: poster)
                            .resizable()
                            .aspectRatio(16 / 9, contentMode: .fill)
                    } else {
                        Color.secondary.opacity(0.12)
                            .overlay { Image(systemName: "film").foregroundStyle(.secondary) }
                    }
                }
                .frame(width: 64, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .lineLimit(2)
                    Text(video.dateAdded, style: .date)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(StudioDesign.selectionFill(isSelected: isSelected, isHovered: isHovered))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .ownsRowHoverWash()
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Open in Reader", systemImage: "doc.text", action: openInReader)
            OtherWindowMenuItem(.video(sourceID: video.id))
            Button("Reveal in Finder", systemImage: "folder") {
                if let path = video.localFilePath.flatMap(StorageService.locateSourceFile) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
            Divider()
            Button("Delete Video", systemImage: "trash", role: .destructive, action: delete)
        }
        .task(id: video.artworkURL) {
            poster = await ExplainerVideoFiles.poster(for: video)
        }
        .accessibilityIdentifier("studio.videos.row")
    }
}

// MARK: - Files

/// Resolving a video's files stats the filesystem, so it runs off the main
/// actor and the views ask for the answer in a `.task`.
enum ExplainerVideoFiles {
    struct Located: Sendable {
        let videoURL: URL?
        let manifest: ExplainerVideoManifest?
        /// True when the file exists only as an iCloud placeholder: it is
        /// asked for, and the player waits.
        let isDownloading: Bool
    }

    nonisolated static func locate(_ video: StudioArticle) async -> Located {
        let path = video.localFilePath
        let videoID = GeneratedExplainerVideo.videoID(from: video.url)
        return await Task.detached(priority: .userInitiated) {
            var videoURL: URL?
            var isDownloading = false
            if let path, let located = StorageService.locateSourceFile(path) {
                let url = URL(fileURLWithPath: located)
                if FileManager.default.fileExists(atPath: located) {
                    videoURL = url
                } else {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                    isDownloading = true
                }
            }
            var manifest: ExplainerVideoManifest?
            if let videoID,
               let manifestPath = StorageService.locateSourceFile(GeneratedExplainerVideo.relativeManifestPath(videoID: videoID)),
               let data = FileManager.default.contents(atPath: manifestPath) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                manifest = try? decoder.decode(ExplainerVideoManifest.self, from: data)
            }
            return Located(videoURL: videoURL, manifest: manifest, isDownloading: isDownloading)
        }.value
    }

    nonisolated static func poster(for video: StudioArticle) async -> NSImage? {
        guard let path = MeetingIconService.localArtworkPath(for: video.artworkURL) else { return nil }
        return await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return NSImage(contentsOfFile: path)
        }.value
    }
}

// MARK: - Detail

/// One video: the film in AVKit, then a masthead and the storyboard beneath.
/// Shown in the Videos pane and, through `ExplainerVideoReaderView`, wherever a
/// video source is opened in the Reader.
struct ExplainerVideoDetailView: View {
    @Environment(StudioViewModel.self) private var vm
    let video: StudioArticle
    @State private var located: ExplainerVideoFiles.Located?
    @State private var currentTime: Double?
    @State private var duration: Double?
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                player
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: 960)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                masthead
                storyboard
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: video.localFilePath) {
            located = await ExplainerVideoFiles.locate(video)
            // An iCloud placeholder becomes a file while the pane is open;
            // ask again until it does.
            while located?.isDownloading == true, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                located = await ExplainerVideoFiles.locate(video)
            }
        }
        .accessibilityIdentifier("studio.videos.detail")
    }

    @ViewBuilder
    private var player: some View {
        if let url = located?.videoURL {
            MeetingRecordingPlayerView(
                mediaURL: url,
                currentTime: $currentTime,
                duration: $duration,
                seekRequest: nil,
                initialResumeSeconds: nil,
                loadError: $loadError
            )
            .overlay(alignment: .bottomLeading) {
                if let loadError {
                    Text(loadError)
                        .font(.system(size: 12))
                        .padding(8)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                }
            }
        } else {
            ZStack {
                Color.black.opacity(0.85)
                if located == nil || located?.isDownloading == true {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(located == nil ? "Opening" : "Downloading from iCloud")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                } else {
                    Text("The video file is not on this Mac.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("VIDEO EXPLAINER")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.8)
            Text(video.title)
                .font(.system(size: 22, weight: .semibold, design: .serif))
                .textSelection(.enabled)
            if let manifest = located?.manifest {
                Text(detailLine(manifest))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if let sourceID = manifest.sourceID, let source = vm.articles.first(where: { $0.id == sourceID }) {
                    Button {
                        Task { await vm.selectArticle(source.id, revealingReader: true) }
                    } label: {
                        Label(source.sourceType == .paper ? "Open the paper" : "Open the article", systemImage: "arrow.up.right")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.hoverWash)
                    .opensInOtherWindow(source)
                    .accessibilityIdentifier("studio.videos.openSource")
                }
            }
        }
    }

    private func detailLine(_ manifest: ExplainerVideoManifest) -> String {
        var parts = [GeneratedExplainerVideo.lengthLabel(durationSeconds: manifest.durationSeconds, sceneCount: manifest.storyboard.scenes.count)]
        let model = VideoGenerationCatalog.model(id: manifest.model)?.name ?? manifest.model
        parts.append("\(model) at \(manifest.resolution)")
        if let cost = manifest.costUSD {
            parts.append(VideoGenerationCatalog.costLabel(cost))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var storyboard: some View {
        if let manifest = located?.manifest {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(manifest.storyboard.scenes.enumerated()), id: \.offset) { index, scene in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(scene.narration)
                                .font(.system(size: 15, design: .serif))
                                .textSelection(.enabled)
                            Text(scene.visual)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
        } else if let script = video.content, !script.isEmpty {
            Text(script)
                .font(.system(size: 15, design: .serif))
                .textSelection(.enabled)
                .frame(maxWidth: 720, alignment: .leading)
        }
    }
}

/// The Reader's arm for a video source: the same detail the Videos pane shows.
struct ExplainerVideoReaderView: View {
    let article: StudioArticle

    var body: some View {
        ExplainerVideoDetailView(video: article)
            .id(article.id)
    }
}

// MARK: - Composer

/// What the composer holds while the learner fills it in. Identifiable so a
/// sheet can present it; a new draft is a new sheet.
struct ExplainerVideoComposeDraft: Identifiable, Equatable {
    let id = UUID()
    var concept: String
    var sourceID: String?
    var length: ExplainerVideoLength = .default
}

/// The New Video sheet: the concept, an optional source to lean on, the
/// length, and the price it will cost. Generate asks the cost question again
/// through the coordinator's alert, with the exact figure.
struct ExplainerVideoComposeSheet: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ExplainerVideoComposeDraft
    @State private var sourceQuery = ""
    /// Bumped when OpenRouter's video directory arrives, so the price line
    /// redraws with the chosen model's real rate.
    @State private var directoryReads = 0
    let generate: (ExplainerVideoRequest) -> Void

    init(draft: ExplainerVideoComposeDraft, generate: @escaping (ExplainerVideoRequest) -> Void) {
        _draft = State(initialValue: draft)
        self.generate = generate
    }

    private var model: VideoGenerationModel { MacVideoGenerationSettings.model }
    private var resolution: VideoGenerationCatalog.Resolution { MacVideoGenerationSettings.resolution }

    private var chosenSource: StudioArticle? {
        guard let id = draft.sourceID else { return nil }
        return vm.articles.first { $0.id == id }
    }

    /// Papers and articles whose title matches what was typed, a handful at
    /// a time; the whole library in a picker is unusable.
    private var sourceMatches: [StudioArticle] {
        let query = sourceQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard query.count >= 2 else { return [] }
        return vm.articles
            .filter { ExplainerVideoGeneratorService.groundingSourceTypes.contains($0.sourceType) && !GeneratedExplainer.isSpokenScriptURL($0.url) }
            .filter { $0.title.lowercased().contains(query) }
            .prefix(6)
            .map { $0 }
    }

    private var canGenerate: Bool {
        !draft.concept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Video")
                .font(.system(size: 17, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Explain")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("The concept, in your words", text: $draft.concept, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("studio.videos.compose.concept")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("From")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                if let chosenSource {
                    HStack(spacing: 8) {
                        Image(systemName: chosenSource.sourceType == .paper ? "doc.text" : "doc.richtext")
                            .foregroundStyle(.secondary)
                        Text(chosenSource.title)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            draft.sourceID = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.hoverWash)
                        .help("Remove the source")
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    TextField("Search papers and articles, or leave empty", text: $sourceQuery)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("studio.videos.compose.source")
                    if !sourceMatches.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(sourceMatches) { match in
                                Button {
                                    draft.sourceID = match.id
                                    sourceQuery = ""
                                    if draft.concept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        draft.concept = GeneratedExplainerVideo.concept(forSourceTitled: match.title)
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: match.sourceType == .paper ? "doc.text" : "doc.richtext")
                                            .foregroundStyle(.secondary)
                                        Text(match.title)
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.hoverWash)
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Length")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("Length", selection: $draft.length) {
                    ForEach(ExplainerVideoLength.allCases) { length in
                        Text(length.displayName).tag(length)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(costLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Generate") {
                    let request = ExplainerVideoRequest(
                        concept: draft.concept.trimmingCharacters(in: .whitespacesAndNewlines),
                        sourceID: draft.sourceID,
                        length: draft.length
                    )
                    dismiss()
                    generate(request)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canGenerate)
                .accessibilityIdentifier("studio.videos.compose.generate")
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            if (try? await VideoGenerationDirectory.models()) != nil { directoryReads += 1 }
        }
    }

    private var costLine: String {
        _ = directoryReads
        guard model.isResolved else { return "Reading OpenRouter's price for \(model.name)…" }
        let detail = draft.length.detail(clipSeconds: model.clipSeconds)
        guard let cost = GeneratedExplainerVideo.estimatedCostUSD(length: draft.length, model: model, resolution: resolution) else {
            if model.pricedByTokens {
                return "\(detail) with \(model.name) at \(resolution.displayName). OpenRouter prices it by video tokens, so the cost is known once it is made."
            }
            return "\(model.name) has no published price at \(resolution.displayName); change it in Settings › Videos."
        }
        return "\(detail) · \(VideoGenerationCatalog.costLabel(cost)) with \(model.name) at \(resolution.displayName)."
    }
}
#endif
