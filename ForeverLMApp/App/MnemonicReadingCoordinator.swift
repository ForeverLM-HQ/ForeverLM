#if os(macOS)
import Foundation
import SwiftUI

/// What Make Mnemonic Reading opens first (`StudioViewModel.presentMnemonicReading`):
/// the sheet for some sources, in the window it was asked from. The reading
/// opens in that window too, and in no other.
struct MnemonicReadingTarget: Identifiable, Equatable {
    /// The notebook the reading is made in — its home, where its row is
    /// listed — or nil from a Reader outside a notebook.
    let notebookID: String?
    /// The sources it reads, in reading order.
    let sourceIDs: [String]
    /// From one of a book's chapters: the whole book's chapters in order,
    /// which the sheet offers instead of the chapter alone.
    var bookSourceIDs: [String]? = nil
    /// The reading whose pending sources are written again; nil for a new one.
    var readingID: String? = nil
    /// The window the sheet shows in.
    let windowID: UUID

    var id: String {
        "\(windowID.uuidString)|\(notebookID ?? "")|\(readingID ?? "")|\(sourceIDs.joined(separator: ","))"
    }
}

/// The Mac's mnemonic readings in the making, shared by the Make Mnemonic
/// Reading sheet and `generate_mnemonic_reading` (docs/memory-design.md,
/// "Mnemonic reading"): each run is the coordinator's own task, listed while it
/// writes — the notebook's Studio shows it with its progress and a Stop, and
/// `list_running_ai_work` lists it — and writes through `MnemonicReadingWriter`.
/// The reading opens where it was asked for once its first source is written,
/// and fills in.
@MainActor
final class MnemonicReadingCoordinator: ObservableObject {
    static let shared = MnemonicReadingCoordinator()

    /// One reading being written.
    struct Run: Identifiable, Equatable {
        /// The reading's id, reserved before its first source is written.
        let id: String
        let notebookID: String?
        let title: String
        let sourceIDs: [String]
        let startedAt: Date
        var progress: MnemonicReadingRunProgress
        /// The running-work entry an assistant's run is listed under; nil for
        /// one started in the app, which `list_running_ai_work` lists itself.
        let workID: String?
    }

    /// What a finished run did, kept for the session so
    /// `get_mnemonic_reading` can say why a reading is not there.
    struct Outcome: Equatable {
        let readingID: String
        let finishedAt: Date
        /// Nil when the run was stopped or failed.
        let result: MnemonicReadingResult?
        /// Why it wrote nothing more, when it did not finish.
        let message: String?
    }

    @Published private(set) var runs: [Run] = []
    /// The sheet each window asked for, by window id.
    @Published private(set) var targets: [UUID: MnemonicReadingTarget] = [:]
    private var tasks: [String: Task<Result<MnemonicReadingResult, Error>, Never>] = [:]
    private var outcomes: [String: Outcome] = [:]

    // MARK: The sheet

    func present(_ target: MnemonicReadingTarget) {
        targets[target.windowID] = target
    }

    func target(in windowID: UUID) -> MnemonicReadingTarget? {
        targets[windowID]
    }

    func dismiss(in windowID: UUID) {
        targets[windowID] = nil
    }

    // MARK: Runs

    func run(_ readingID: String) -> Run? {
        runs.first { $0.id == readingID }
    }

    /// The runs writing readings for a notebook, oldest first.
    func runs(inNotebook notebookID: String) -> [Run] {
        runs.filter { $0.notebookID == notebookID }
    }

    /// Whether any run is writing questions about `sourceID` now.
    func isWriting(sourceID: String) -> Bool {
        runs.contains { $0.sourceIDs.contains(sourceID) }
    }

    /// The run writing questions about `sourceID`, for its Stop.
    func run(writing sourceID: String) -> Run? {
        runs.first { $0.sourceIDs.contains(sourceID) }
    }

    /// Stops a run: the sources already written keep their questions;
    /// nothing more is written.
    func cancel(_ readingID: String) {
        tasks[readingID]?.cancel()
    }

    /// What became of the last run that wrote `readingID`, once it ended.
    func outcome(forReading readingID: String) -> Outcome? {
        outcomes[readingID]
    }

    // MARK: Read and plan, off the main actor

    nonisolated static func load(_ request: MnemonicReadingRequest, storage: StorageService) async throws -> MnemonicReadingMaterials {
        try await MnemonicReadingWriter.load(request, storage: storage)
    }

    /// The plan for what was read, on the learner's Mnemonic Reading Writing
    /// route as it stands now. Throws when no model is configured.
    nonisolated static func plan(_ materials: MnemonicReadingMaterials, density: MnemonicReadingDensity) async throws -> MnemonicReadingPlan {
        try MnemonicReadingWriter.plan(materials, density: density)
    }

    // MARK: Make

    /// The sheet's Make: write `plan`, opening the reading in the window Make
    /// was pressed in once its first source is written — while that window
    /// still holds the notebook it held then — and saying in a toast how it
    /// went, with Open when it did not open. Nil when it was stopped or
    /// failed (said in the toast).
    @discardableResult
    func make(_ plan: MnemonicReadingPlan, windowID: UUID?, in vm: StudioViewModel) async -> MnemonicReadingResult? {
        let readingID = plan.request.readingID ?? UUID().uuidString.lowercased()
        let window = windowID.flatMap { id in vm.allWindowStates.first { $0.id == id } }
        let notebookAtMake = window?.notebook?.notebookID
        // A reading written again is the one the learner has open already.
        if plan.existing != nil { appearedReadings.insert(readingID) }
        let result = await write(plan, readingID: readingID, storage: vm.storage) { [weak self, weak vm] _ in
            await self?.sourceWritten(readingID: readingID, window: window, notebookAtMake: notebookAtMake, vm: vm)
        }
        appearedReadings.remove(readingID)
        let revealed = revealedReadings.remove(readingID) != nil || plan.existing != nil
        await vm.reloadArtifactsAfterMnemonicReadingWrite()
        switch result {
        case .failure(let error):
            vm.showToast(error is CancellationError ? "Stopped writing the reading's questions" : error.localizedDescription)
            return nil
        case .success(let written):
            if !written.readingExists {
                vm.showToast(Self.nothingWrittenMessage(written))
            } else if !revealed {
                vm.showToast(written.summary, action: StudioToastAction(title: "Open") { window in
                    vm.revealArtifact(readingID, in: window)
                })
            } else {
                vm.showToast(written.summary)
            }
            return written
        }
    }

    /// Readings whose first source has landed, while their run lasts.
    private var appearedReadings = Set<String>()
    /// Readings opened in the window Make was pressed in.
    private var revealedReadings = Set<String>()

    /// After each source: the lists read the reading again, and the first
    /// time it exists it opens in the window Make was pressed in, while that
    /// window still holds the notebook it held then.
    private func sourceWritten(readingID: String, window: StudioWindowState?, notebookAtMake: String?, vm: StudioViewModel?) async {
        guard let vm else { return }
        await vm.reloadArtifactsAfterMnemonicReadingWrite()
        guard !appearedReadings.contains(readingID), vm.artifacts.contains(where: { $0.id == readingID }) else { return }
        appearedReadings.insert(readingID)
        guard let window, vm.allWindowStates.contains(where: { $0 === window }),
              window.notebook?.notebookID == notebookAtMake else { return }
        // A Reader on the paper's PDF draws the questions at their passages
        // itself, so the reading is not also opened beside it.
        if Self.readerDrawsQuestions(of: readingID, in: window, vm: vm) { return }
        revealedReadings.insert(readingID)
        vm.revealArtifact(readingID, in: window)
    }

    /// Whether `window` has a Reader open on a PDF of one of the reading's
    /// sources, which then shows the reading's questions on the page
    /// (`ReaderQuestionLayer`).
    private static func readerDrawsQuestions(of readingID: String, in window: StudioWindowState, vm: StudioViewModel) -> Bool {
        guard let reading = vm.artifacts.first(where: { $0.id == readingID }) else { return false }
        return reading.sourceIDs.contains { sourceID in
            window.readerSourceIDsOnScreen.contains(sourceID)
                && vm.articlesById[sourceID]?.cachedResolvedPDFPath != nil
        }
    }

    /// Writes `plan` into `readingID` as a run of this coordinator, listed
    /// until it ends, and returns when it has ended.
    /// `generate_mnemonic_reading` calls this from its background work, so an
    /// assistant's run shows in the Studio with its Stop, and spends against
    /// what the assistant was approved for (the task inherits its
    /// running-work id).
    func write(
        _ plan: MnemonicReadingPlan,
        readingID: String,
        storage: StorageService,
        backend: (any MnemonicReadingBackend)? = nil,
        onProgress: (@Sendable (MnemonicReadingRunProgress) async -> Void)? = nil
    ) async -> Result<MnemonicReadingResult, Error> {
        guard tasks[readingID] == nil else { return .failure(CancellationError()) }
        runs.append(Run(
            id: readingID,
            notebookID: plan.request.notebookID,
            title: plan.title,
            sourceIDs: plan.sources.map(\.source.sourceID),
            startedAt: Date(),
            progress: MnemonicReadingRunProgress(done: 0, total: plan.sources.count),
            workID: MCPRunningWork.currentCallID
        ))
        let writer = backend ?? LiveMnemonicReadingBackend(aiService: AIService())
        // Inherits the caller's task-locals, among them an MCP call's
        // running-work id, so the usage ledger counts this run against the
        // spend the assistant was approved for.
        let task = Task<Result<MnemonicReadingResult, Error>, Never> {
            do {
                let written = try await MnemonicReadingWriter.run(
                    plan,
                    readingID: readingID,
                    storage: storage,
                    backend: writer
                ) { progress in
                    await self.setProgress(progress, for: readingID)
                    await onProgress?(progress)
                }
                return .success(written)
            } catch {
                // A cancelled request can surface as its own CancellationError
                // or as the transport's cancelled error wrapped by the
                // provider; either way someone asked for it.
                if error is CancellationError || Task.isCancelled { return .failure(CancellationError()) }
                return .failure(error)
            }
        }
        tasks[readingID] = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        tasks[readingID] = nil
        runs.removeAll { $0.id == readingID }
        switch result {
        case .success(let written):
            outcomes[readingID] = Outcome(readingID: readingID, finishedAt: Date(), result: written, message: nil)
        case .failure(let error) where error is CancellationError:
            outcomes[readingID] = Outcome(
                readingID: readingID, finishedAt: Date(), result: nil,
                message: "Stopped; the sources written before the stop keep their questions, and the rest wait in the reading."
            )
        case .failure(let error):
            outcomes[readingID] = Outcome(readingID: readingID, finishedAt: Date(), result: nil, message: error.localizedDescription)
        }
        return result
    }

    private func setProgress(_ progress: MnemonicReadingRunProgress, for readingID: String) {
        guard let index = runs.firstIndex(where: { $0.id == readingID }) else { return }
        runs[index].progress = progress
    }

    /// Why a run wrote no reading: each source's own reason, the first named.
    static func nothingWrittenMessage(_ result: MnemonicReadingResult) -> String {
        if let failure = result.failures.first, let message = failure.failure {
            return "No questions from \u{201C}\(failure.title)\u{201D}: \(message)"
        }
        if let skip = result.skipped.first {
            return "No questions: \u{201C}\(skip.title)\u{201D} was left out. \(skip.reason)"
        }
        return "No questions were written."
    }
}

// MARK: - The sheet's host and the Studio's pending rows

extension View {
    /// Presents the Make Mnemonic Reading sheet asked for in this Studio
    /// window (`StudioViewModel.presentMnemonicReading`), and in no other.
    func mnemonicReadingSheet() -> some View {
        modifier(MnemonicReadingSheetHost())
    }
}

private struct MnemonicReadingSheetHost: ViewModifier {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @ObservedObject private var coordinator = MnemonicReadingCoordinator.shared

    private var target: Binding<MnemonicReadingTarget?> {
        let windowID = windowState.id
        return Binding(
            get: { coordinator.target(in: windowID) },
            set: { newValue in
                guard newValue == nil else { return }
                coordinator.dismiss(in: windowID)
            }
        )
    }

    func body(content: Content) -> some View {
        content.sheet(item: target) { target in
            MakeMnemonicReadingSheet(vm: vm, target: target)
        }
    }
}

/// A notebook's readings being written before their first source lands,
/// where its outputs are listed: the run's progress and Stop. Once the reading
/// exists its own row says how far it has come.
struct MnemonicReadingRunsList: View {
    var vm: StudioViewModel
    let notebookID: String
    @ObservedObject private var coordinator = MnemonicReadingCoordinator.shared

    var body: some View {
        ForEach(coordinator.runs(inNotebook: notebookID).filter { run in !vm.artifacts.contains { $0.id == run.id } }) { run in
            HStack(spacing: 10) {
                NotebookStudioBadge(symbolName: ArtifactKind.mnemonicReadingSymbolName, hue: NotebookStudioHue.sepia)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.title).lineLimit(1)
                    Text(run.progress.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .textSelection(.disabled)
                Spacer(minLength: 6)
                ProgressView().controlSize(.small)
                Button("Stop") { coordinator.cancel(run.id) }
                    .buttonStyle(.hoverWash)
                    .font(.callout)
                    .accessibilityIdentifier("reading-run.stop")
            }
            .contextMenu {
                Button("Stop Writing Questions", systemImage: "stop.circle") { coordinator.cancel(run.id) }
            }
        }
    }
}
#endif
