#if os(macOS)
import SwiftUI

/// What Make Mnemonic Reading opens first — the notebook Studio's tile for its
/// ticked sources, the Reader's for its chapter or its whole book — and the
/// second press that writes (docs/memory-design.md, "Mnemonic reading"): what
/// it reads, how many questions (Fewer · Auto · More), and the price with the
/// model. Make closes the sheet; the reading opens once its first source is
/// written, and fills in. Written again from a reading, it reads the
/// reading's pending sources.
///
/// Presented by `mnemonicReadingSheet()` on the Studio window, for the target
/// `StudioViewModel.presentMnemonicReading` set.
struct MakeMnemonicReadingSheet: View {
    var vm: StudioViewModel
    let target: MnemonicReadingTarget
    @Environment(\.dismiss) private var dismiss

    /// From a book's chapter: the chapter alone, or the whole book.
    enum Reach: String, Identifiable {
        case chapter
        case book

        var id: String { rawValue }
    }

    @State private var density: MnemonicReadingDensity = .auto
    @State private var reach: Reach = .book
    @State private var materials: [Reach: MnemonicReadingMaterials] = [:]
    @State private var plan: MnemonicReadingPlan?
    @State private var errorMessage: String?
    @State private var isLoading = true

    private var sourceIDs: [String] {
        reach == .book ? (target.bookSourceIDs ?? target.sourceIDs) : target.sourceIDs
    }

    /// The plan for what is on screen, and only that: while a change is
    /// being re-planned, Make waits rather than make what the previous price
    /// described.
    private var currentPlan: MnemonicReadingPlan? {
        guard let plan, plan.density == density, plan.request.sourceIDs == sourceIDs else { return nil }
        return plan
    }

    private var canMake: Bool {
        (currentPlan?.questionCount ?? 0) > 0
    }

    private var title: String {
        target.readingID == nil ? "Make Mnemonic Reading" : "Write Questions"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text(title).font(.headline)
                Spacer()
                Button("Make") { make() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canMake)
                    .accessibilityIdentifier("make-reading.make")
            }
            .padding()

            Divider()

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                if target.bookSourceIDs != nil {
                    GridRow {
                        Text("Read")
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Picker("Read", selection: $reach) {
                            Text("This Chapter").tag(Reach.chapter)
                            Text("Whole Book").tag(Reach.book)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("make-reading.reach")
                    }
                }
                GridRow {
                    Text("Questions")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Picker("Questions", selection: $density) {
                        ForEach(MnemonicReadingDensity.allCases) { density in
                            Text(density.label).tag(density)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("make-reading.density")
                }
                GridRow {
                    Text("Sources").foregroundStyle(.secondary)
                    sourcesLine
                }
                GridRow {
                    Text("Price").foregroundStyle(.secondary)
                    priceLine
                }
            }
            .padding(20)

            if isLoading || errorMessage != nil {
                Divider()
                statusRow
            }
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: sourceIDs) { await load() }
        .onChange(of: density) { _, _ in
            Task { await replan() }
        }
    }

    // MARK: Lines

    @ViewBuilder
    private var sourcesLine: some View {
        if let plan = currentPlan ?? plan {
            VStack(alignment: .leading, spacing: 3) {
                Text(plan.summary)
                if let detail = Self.detail(plan) {
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
        if let plan = currentPlan {
            VStack(alignment: .leading, spacing: 3) {
                Text(plan.priceLine)
                Text(plan.route.modelLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    /// The sources left out and those read in parts, by name: the sheet says
    /// what the questions are written from.
    static func detail(_ plan: MnemonicReadingPlan) -> String? {
        var parts: [String] = []
        if !plan.skipped.isEmpty {
            parts.append("Left out: " + plan.skipped.map { "\($0.title) (\(MakeCardsSheet.clause($0.reason)))" }
                .joined(separator: "; ") + ".")
        }
        if !plan.splitTitles.isEmpty {
            parts.append("Read in parts: \(plan.splitTitles.joined(separator: "; ")).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    @ViewBuilder
    private var statusRow: some View {
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
        .textSelection(.disabled)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Actions

    private func load() async {
        let ids = sourceIDs
        let asked = reach
        if materials[asked] == nil {
            isLoading = true
            defer { isLoading = false }
            let request = MnemonicReadingRequest(
                notebookID: target.notebookID,
                sourceIDs: ids,
                density: density,
                readingID: target.readingID
            )
            do {
                let loaded = try await MnemonicReadingCoordinator.load(request, storage: vm.storage)
                materials[asked] = loaded
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        await replan()
    }

    private func replan() async {
        guard let materials = materials[reach] else { return }
        let asked = density
        do {
            let planned = try await MnemonicReadingCoordinator.plan(materials, density: asked)
            // A slower answer for options the learner has since changed is not theirs.
            guard planned.density == density, planned.request.sourceIDs == sourceIDs else { return }
            plan = planned
            errorMessage = planned.questionCount == 0 ? MnemonicReadingError.noSources.localizedDescription : nil
        } catch {
            guard asked == density else { return }
            plan = nil
            errorMessage = error.localizedDescription
        }
    }

    private func make() {
        guard canMake, let plan = currentPlan else { return }
        dismiss()
        let vm = vm
        let windowID = target.windowID
        Task {
            await vm.makeMnemonicReading(plan, windowID: windowID)
        }
    }
}

/// The Reader's ⋯ items for a source read as text: **Make Mnemonic
/// Reading…**, whose sheet offers a book's chapter or the whole book, and
/// **Stop Writing Questions** while a reading of it is being written.
struct MnemonicReadingMenuItems: View {
    let article: StudioArticle
    let windowState: StudioWindowState

    @Environment(StudioViewModel.self) private var vm
    @ObservedObject private var coordinator = MnemonicReadingCoordinator.shared

    var body: some View {
        if Self.canRead(article) {
            if let run = coordinator.run(writing: article.id) {
                Button {
                    coordinator.cancel(run.id)
                } label: {
                    Label("Stop Writing Questions", systemImage: "stop.circle")
                }
            } else {
                Button {
                    vm.presentReaderMnemonicReading(sourceID: article.id, in: windowState)
                } label: {
                    Label("Make Mnemonic Reading…", systemImage: ArtifactKind.mnemonicReadingSymbolName)
                }
                .help("Read this with recall questions after the passages they test")
            }
        }
    }

    /// Whether a source is read as text a reading can set questions in: a
    /// book's chapter, a paper, an article, a course's document — not a
    /// transcript, a post, or a spoken script ForeverLM wrote.
    static func canRead(_ article: StudioArticle) -> Bool {
        guard !TextToSpeechPreparationPolicy.isSpokenScript(url: article.url) else { return false }
        switch article.sourceType {
        case .book, .paper, .article, .manual, .unclassified, .course: return true
        case .podcast, .video, .meeting, .xPost: return false
        }
    }
}
#endif
