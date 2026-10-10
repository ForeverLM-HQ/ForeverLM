#if os(macOS)
import Foundation
import SwiftUI

/// What the Report tile and menu open (`StudioViewModel.presentReportOptions`):
/// the options sheet for one notebook, in the window it was asked from. The
/// made report opens in that window too, and in no other.
struct ReportOptionsTarget: Identifiable, Equatable {
    let notebookID: String
    /// The format the sheet opens on; nil opens on the default, Briefing.
    var format: ReportFormat?
    /// The sources to write from; nil reads the notebook's ticked sources
    /// (`NotebookSourceLoader.notebookSourceIDs`).
    var sourceIDs: [String]? = nil
    /// The window the sheet shows in.
    let windowID: UUID

    var id: String { "\(windowID.uuidString)|\(notebookID)|\(format?.rawValue ?? "")" }
}

/// The Mac's reports in the making, shared by the Report tile's sheet and by
/// `generate_report`: write the report, save it as a Doc in the notebook, and
/// — for the sheet's Make — open it where the learner asked for it.
///
/// A run is the coordinator's own task, not the caller's, so Stop — on the
/// pending row, or `cancel_ai_work` — ends it from anywhere while a request
/// is still out. The service checks for cancellation before it saves, so a
/// stopped run leaves nothing behind.
@MainActor
final class ReportGenerationCoordinator: ObservableObject {
    static let shared = ReportGenerationCoordinator()

    /// One report being written: the Doc id it will be saved under, its
    /// notebook, what was asked for, and where it is.
    struct Run: Identifiable, Equatable {
        /// The Doc id reserved for the report.
        let id: String
        let notebookID: String
        let notebookTitle: String
        let format: ReportFormat
        let sourceCount: Int
        let startedAt: Date
        var stage: ReportStage
    }

    /// What became of a report a caller may ask about once its run has
    /// ended without saving it: `read_doc` on its reserved id says so.
    struct Note: Equatable {
        enum Kind: Equatable {
            case writingFailed
            case writingStopped
        }

        let reportID: String
        let kind: Kind
        let message: String
    }

    /// Reports being written right now, oldest first.
    @Published private(set) var runs: [Run] = []
    /// The options sheet each window asked for, by window id. A window shows
    /// only its own, so a sheet asked for in one window never closes the
    /// sheet open in another.
    @Published private(set) var optionsTargets: [UUID: ReportOptionsTarget] = [:]
    /// The last note for each reserved id, kept for the session.
    private var notes: [String: Note] = [:]
    private var tasks: [String: Task<Result<ReportResult, Error>, Never>] = [:]
    /// Recipes read from report bodies, by record id and revision, so a row
    /// asks the disk once per change.
    private var recipeCache: [String: (updatedAt: Date, recipe: ReportRecipe?)] = [:]

    /// The runs writing into one notebook, oldest first.
    func runs(inNotebook notebookID: String) -> [Run] {
        runs.filter { $0.notebookID == notebookID }
    }

    func run(_ id: String) -> Run? {
        runs.first { $0.id == id }
    }

    /// What became of the report reserved under `id`, once its run ended
    /// without saving it.
    func note(forReport id: String) -> Note? {
        notes[id]
    }

    /// The options sheet asked for in a window; nil while it shows none.
    func optionsTarget(in windowID: UUID) -> ReportOptionsTarget? {
        optionsTargets[windowID]
    }

    /// Shows the options sheet in its window.
    func present(_ target: ReportOptionsTarget) {
        optionsTargets[target.windowID] = target
    }

    /// The window's options sheet closed.
    func dismissOptions(in windowID: UUID) {
        optionsTargets[windowID] = nil
    }

    // MARK: Plan

    /// Reads the notebook once for an options sheet: every selected source's
    /// text and ideas, and the Docs a feedback report can be about.
    nonisolated static func loadNotebook(
        notebookID: String,
        sourceIDs: [String]? = nil,
        storage: StorageService
    ) async throws -> ReportNotebook {
        try await ReportGeneratorService(
            storage: storage,
            backend: LiveReportModelBackend(aiService: AIService())
        ).load(notebookID: notebookID, sourceIDs: sourceIDs)
    }

    /// The text of the Doc a feedback report is about, whole.
    nonisolated static func loadSubjectDocument(
        _ id: String,
        in notebook: ReportNotebook,
        storage: StorageService
    ) async throws -> ReportSubjectDocument {
        try await ReportGeneratorService(
            storage: storage,
            backend: LiveReportModelBackend(aiService: AIService())
        ).loadSubjectDocument(id, in: notebook)
    }

    /// Fits a loaded notebook to the learner's Report Writing route and
    /// prices it. Cheap: the sheet re-plans on every change of option.
    nonisolated static func plan(
        _ notebook: ReportNotebook,
        request: ReportRequest,
        subjectDocument: ReportSubjectDocument?
    ) async throws -> ReportPlan {
        guard let route = LiveReportModelBackend.currentRoute() else {
            throw ReportGenerationError.noModelConfigured
        }
        return try ReportGeneratorService.plan(notebook, request: request, subjectDocument: subjectDocument, route: route)
    }

    // MARK: Make

    /// The sheet's Make: write the report the plan describes, then open it
    /// in the notebook's document slot of the window Make was pressed in,
    /// when that window still holds the notebook. Returns the saved report,
    /// or nil when it was stopped or failed (said in a toast).
    @discardableResult
    func make(_ plan: ReportPlan, windowID: UUID?, in vm: StudioViewModel) async -> ReportResult? {
        let result = await write(plan, storage: vm.storage)
        switch result {
        case .failure(let error):
            if error is CancellationError {
                vm.showToast("Stopped writing the report")
            } else {
                vm.showToast(error.localizedDescription)
            }
            return nil
        case .success(let report):
            await show(report, in: vm)
            open(report, windowID: windowID, in: vm)
            return report
        }
    }

    /// Writes and saves `plan` under `artifactID` as a run of this
    /// coordinator, listed until it ends, and returns when it has ended.
    /// `generate_report` calls this from its background work, so a report an
    /// assistant started shows as a pending row in the notebook and its Stop
    /// ends it.
    func write(
        _ plan: ReportPlan,
        artifactID: String = UUID().uuidString.lowercased(),
        storage: StorageService,
        backend: (any ReportModelBackend)? = nil,
        onStage: (@Sendable (ReportStage) async -> Void)? = nil
    ) async -> Result<ReportResult, Error> {
        guard tasks[artifactID] == nil else { return .failure(CancellationError()) }
        let service = ReportGeneratorService(
            storage: storage,
            backend: backend ?? LiveReportModelBackend(aiService: AIService())
        )
        runs.append(Run(
            id: artifactID,
            notebookID: plan.request.notebookID,
            notebookTitle: plan.notebookTitle,
            format: plan.options.format,
            sourceCount: plan.sources.count,
            startedAt: Date(),
            stage: .reading(sourceCount: plan.sources.count)
        ))
        // Inherits the caller's task-locals, among them an MCP call's
        // running-work id, so the usage ledger counts this run against the
        // spend the assistant was approved for.
        let task = Task<Result<ReportResult, Error>, Never> {
            do {
                let result = try await service.run(plan, artifactID: artifactID) { stage in
                    await self.setStage(stage, for: artifactID)
                    await onStage?(stage)
                }
                return .success(result)
            } catch {
                // A cancelled request can surface as its own CancellationError
                // or as the transport's cancelled error wrapped by the
                // provider; either way someone asked for it.
                if error is CancellationError || Task.isCancelled { return .failure(CancellationError()) }
                return .failure(error)
            }
        }
        tasks[artifactID] = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        tasks[artifactID] = nil
        runs.removeAll { $0.id == artifactID }
        switch result {
        case .success(let report):
            recipeCache[report.artifact.id] = (report.artifact.updatedAt, report.recipe)
            notes[artifactID] = nil
        case .failure(let error) where error is CancellationError:
            notes[artifactID] = Note(
                reportID: artifactID,
                kind: .writingStopped,
                message: "The writing was stopped before the report was saved; nothing was kept."
            )
        case .failure(let error):
            notes[artifactID] = Note(reportID: artifactID, kind: .writingFailed, message: error.localizedDescription)
        }
        return result
    }

    /// Stops the run. Nothing is saved.
    func cancel(_ runID: String) {
        tasks[runID]?.cancel()
    }

    private func setStage(_ stage: ReportStage, for id: String) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[index].stage = stage
    }

    /// The saved report in the open window's lists.
    func show(_ report: ReportResult, in vm: StudioViewModel) async {
        if let reloaded = try? await vm.loadScopedArtifacts() {
            vm.artifacts = reloaded
        }
    }

    /// Opens the report in the window Make was pressed in — in its notebook's
    /// document slot, which is where a Doc lands in a notebook window — when
    /// that window still holds the report's notebook. A window that has moved
    /// on is left as it is, and a toast says the report is written.
    func open(_ report: ReportResult, windowID: UUID?, in vm: StudioViewModel) {
        let notebookID = report.artifact.homeNotebookID
        if let windowID, let notebookID,
           let window = vm.allWindowStates.first(where: { $0.id == windowID }),
           window.notebook?.notebookID == notebookID {
            vm.revealArtifact(report.artifact.id, in: window)
        } else {
            vm.showToast("Report written: \(report.artifact.title)")
        }
    }

    // MARK: Recipe

    /// The recipe a report's body carries, read once per revision. Nil for a
    /// Doc that is not a report, and for every record that is not a
    /// Markdown Doc.
    func recipe(for artifact: ArtifactRecord, storage: StorageService) async -> ReportRecipe? {
        if let cached = recipeCache[artifact.id], cached.updatedAt == artifact.updatedAt {
            return cached.recipe
        }
        guard artifact.kind == nil, !artifact.isLinked,
              let snapshot = try? await storage.artifactMarkdown(artifact.id) else { return nil }
        let recipe = ReportRecipe.parse(fromMarkdown: snapshot.markdown)
        recipeCache[artifact.id] = (artifact.updatedAt, recipe)
        return recipe
    }
}
#endif
