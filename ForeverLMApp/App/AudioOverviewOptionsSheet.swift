#if os(macOS)
import SwiftUI

/// The options the Studio column's Audio overview tile opens first, and the
/// second tap that makes it (Gemini's two-click lesson): the format, a
/// length (not for a Brief), an optional focus, which sources the script is
/// written from and how — whole, from their ideas, or condensed, named here
/// rather than cut silently — the voice, and the price of both the writing
/// and the audio. Make closes the sheet; the run shows as a pending row in
/// the notebook's outputs, and the narration asks its cost question the way
/// Listen does unless automatic audio covers it.
///
/// Presented as `.sheet(item: $target) { AudioOverviewOptionsSheet(vm: vm, target: $0) }`,
/// with the target from `vm.audioOverviewOptionsTarget(notebookID:)`, by the
/// notebook workspace when the Studio's Audio overview tile or the Notebook
/// menu's Make ▸ Audio Overview… asks (`showNotebookAudioOverviewOptions`).
struct AudioOverviewOptionsSheet: View {
    var vm: StudioViewModel
    let target: AudioOverviewOptionsTarget
    /// Called with the saved overview once it is written, for a caller that
    /// opens it.
    var onMade: ((AudioOverviewResult) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var format: AudioOverviewFormat = .default
    @State private var length: AudioOverviewLength = .default
    @State private var focus = ""
    @State private var notebook: AudioOverviewNotebook?
    @State private var quote: AudioOverviewQuote?
    @State private var errorMessage: String?
    @State private var isLoading = true

    private var options: AudioOverviewOptions {
        AudioOverviewOptions(format: format, length: length, focus: focus)
    }

    private var notebookTitle: String {
        notebook?.title ?? vm.notebook(id: target.notebookID)?.title ?? "Notebook"
    }

    /// The quote for the options on screen, and only that one: while a
    /// change of option is being re-quoted, Make waits rather than make what
    /// the previous price described.
    private var currentQuote: AudioOverviewQuote? {
        guard let quote, quote.plan.options == options else { return nil }
        return quote
    }

    /// Whether Make can run: a current quote, and a text-to-speech voice that can
    /// narrate the script.
    private var canMake: Bool {
        currentQuote.map { $0.speechConfigurationError == nil } ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("Audio Overview").font(.headline)
                Spacer()
                Button("Make") { make() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canMake)
                    .accessibilityIdentifier("audio-overview-sheet.make")
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        Text("Notebook")
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(notebookTitle).lineLimit(2)
                    }
                    GridRow {
                        Text("Format").foregroundStyle(.secondary)
                        Picker("Format", selection: $format) {
                            ForEach(AudioOverviewFormat.allCases) { format in
                                Text(format.label).tag(format)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("audio-overview-sheet.format")
                    }
                    if format.takesLength {
                        GridRow {
                            Text("Length").foregroundStyle(.secondary)
                            Picker("Length", selection: $length) {
                                ForEach(AudioOverviewLength.allCases) { length in
                                    Text(length.label).tag(length)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            .accessibilityIdentifier("audio-overview-sheet.length")
                        }
                    }
                    GridRow {
                        Text("Sources").foregroundStyle(.secondary)
                        sourcesLine
                    }
                    GridRow {
                        Text("Voice").foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text(quote?.voiceLabel ?? "—").lineLimit(1)
                            Button("Change…") { TextToSpeechSettingsNavigation.open() }
                                .buttonStyle(.hoverWash(tint: .accentColor))
                                .font(.callout)
                        }
                    }
                    GridRow {
                        Text("Price").foregroundStyle(.secondary)
                        priceLine
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Focus").font(.headline)
                        Text("Optional").font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("Focus", text: $focus, prompt: Text("What the overview should be about"), axis: .vertical)
                        .textFieldStyle(.plain)
                        .labelsHidden()
                        .lineLimit(1...3)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("audio-overview-sheet.focus")
            }
            .padding(20)

            if isLoading || errorMessage != nil {
                Divider()
                SourcesReadingStatusRow(errorMessage: errorMessage)
            }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .task { await load() }
        .onChange(of: options) { _, _ in
            Task { await requote() }
        }
    }

    // MARK: Lines

    @ViewBuilder
    private var sourcesLine: some View {
        if let plan = quote?.plan {
            VStack(alignment: .leading, spacing: 3) {
                Text(plan.sourcesSummary)
                if let detail = Self.readingDetail(plan) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
            }
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var priceLine: some View {
        if let quote {
            VStack(alignment: .leading, spacing: 3) {
                Text("Writing: \(quote.plan.writingCost.label)")
                if let error = quote.speechConfigurationError {
                    // Nothing could narrate the script, so nothing is made.
                    Text(error)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Audio: \(quote.audioLabel)\(quote.audioStartsAutomatically ? " · starts on its own" : "")")
                    if let notice = quote.speechSelectionNotice {
                        Text(notice)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    /// Which sources are not read whole, and which are left out, by name:
    /// the sheet says what the script is written from.
    static func readingDetail(_ plan: AudioOverviewPlan) -> String? {
        ReportPlan.readingDetail(
            ideas: plan.sources.filter { $0.readAs == .ideas }.map(\.candidate.source.title),
            condensed: plan.sources.filter { $0.readAs == .condensed }.map(\.candidate.source.title),
            skipped: plan.skipped.map { ($0.title, $0.reason) }
        )
    }

    // MARK: Actions

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            notebook = try await AudioOverviewGenerationCoordinator.loadNotebook(
                notebookID: target.notebookID,
                sourceIDs: target.sourceIDs,
                storage: vm.storage
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        await requote()
    }

    private func requote() async {
        guard let notebook else { return }
        let request = AudioOverviewRequest(notebookID: target.notebookID, options: options, sourceIDs: target.sourceIDs)
        do {
            let quoted = try await AudioOverviewGenerationCoordinator.quote(notebook, request: request)
            // A slower answer for options the learner has since changed is not theirs.
            guard quoted.plan.options == options else { return }
            quote = quoted
            errorMessage = nil
        } catch {
            quote = nil
            errorMessage = error.localizedDescription
        }
    }

    private func make() {
        guard canMake, let quote = currentQuote else { return }
        dismiss()
        let vm = vm
        let onMade = onMade
        Task {
            if let made = await vm.makeAudioOverview(quote) {
                onMade?(made)
            }
        }
    }
}

/// One audio overview in a notebook's outputs: its glyph, title and
/// "Deep dive · 12 sources · about 12 min", a play button, and its sources
/// and recipe on its menu. A run still being written shows its stage and a
/// Stop. Clicking the row opens the script in the Reader. The notebook's
/// Studio lists it; Delete asks first.
struct AudioOverviewOutputRow: View {
    var vm: StudioViewModel
    let output: AudioOverviewOutput
    @ObservedObject private var speech = ArticleSpeechService.shared
    @ObservedObject private var queue = SourceAudioGenerationQueue.shared
    @State private var settings: AudioOverviewSettings?
    @State private var confirmsDelete = false

    private var shown: AudioOverviewOutput {
        var output = output
        if output.settings == nil { output.settings = settings }
        return output
    }

    var body: some View {
        HStack(spacing: 10) {
            NotebookStudioBadge(symbolName: ArtifactKind.audioOverview.symbolName, hue: NotebookOutput.Kind.audioOverview.hue)
            VStack(alignment: .leading, spacing: 2) {
                Text(output.title).lineLimit(2)
                HStack(spacing: 4) {
                    Text(shown.subtitle)
                    if !output.isWriting {
                        Text("·")
                        Text(output.date, format: .relative(presentation: .named))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 6)
            trailingControl
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !output.isWriting else { return }
            Task { await vm.openAudioOverviewScript(output.id) }
        }
        .hoverHighlight()
        .contextMenu { menu }
        .task(id: output.id) {
            guard !output.isWriting, output.settings == nil else { return }
            settings = await vm.audioOverviewSettings(output.id)
        }
        .confirmationDialog("Delete this audio overview?", isPresented: $confirmsDelete) {
            Button("Delete Audio Overview", role: .destructive) {
                Task { await vm.deleteAudioOverview(output.id) }
            }
        } message: {
            Text("Its script and audio are deleted on every device.")
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if output.isWriting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Button("Stop") { vm.cancelAudioOverview(output.id) }
                    .buttonStyle(.hoverWash)
                    .font(.callout)
            }
        } else {
            let playback = vm.audioOverviewPlayback(output.id)
            if playback == .generating, speech.narratingArticleID != output.carrierSourceID {
                ProgressView()
                    .controlSize(.small)
                    .help("Generating its audio")
            } else {
                Button {
                    vm.toggleAudioOverviewPlayback(output.id)
                } label: {
                    Image(systemName: playback == .playing ? "pause.fill" : "play.fill")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
                .help(playback == .playing ? "Pause" : "Play")
                .accessibilityLabel(playback == .playing ? "Pause" : "Play")
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        if output.isWriting {
            Button("Stop Writing", systemImage: "stop.circle") { vm.cancelAudioOverview(output.id) }
        } else {
            Button(vm.audioOverviewPlayback(output.id) == .playing ? "Pause" : "Play",
                   systemImage: vm.audioOverviewPlayback(output.id) == .playing ? "pause" : "play") {
                vm.toggleAudioOverviewPlayback(output.id)
            }
            Button("Open Script", systemImage: "doc.text") {
                Task { await vm.openAudioOverviewScript(output.id) }
            }
            OtherWindowSourceMenuItem(sourceID: output.carrierSourceID)
            let sources = vm.audioOverviewSources(output.id)
            if !sources.isEmpty {
                Menu("Show Sources") {
                    ForEach(sources) { source in
                        Button(vm.displayTitle(for: source)) {
                            Task { await vm.revealSourceInReader(source.id) }
                        }
                    }
                }
            }
            if let recipe = shown.recipe {
                Divider()
                Text(recipe)
            }
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive) { confirmsDelete = true }
        }
    }
}
#endif

/// The sheet's status line while the sources are read: a progress spinner, or
/// the error that stopped it.
struct SourcesReadingStatusRow: View {
    let errorMessage: String?

    var body: some View {
        HStack(spacing: 10) {
            if let errorMessage {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            } else {
                ProgressView().controlSize(.small)
                Text("Reading the sources")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
