#if os(macOS)
import Foundation
import SwiftUI

/// The Mac's cards in the making, for `draft_cards` — an assistant's or the
/// in-app chat's (docs/memory-design.md, "Drafting"): each run is the
/// coordinator's own task, listed while it drafts — the Reader's toolbar and
/// the notebook's Studio show it, with a Stop — and drafts through the one
/// `CardDraftingService`.
@MainActor
final class CardDraftingCoordinator: ObservableObject {
    static let shared = CardDraftingCoordinator()

    /// One request being drafted.
    struct Run: Identifiable, Equatable {
        let id: String
        let notebookID: String?
        let sourceIDs: [String]
        let startedAt: Date
        var progress: CardDraftingProgress
    }

    /// What a finished run did, kept for the session so `list_cards` can say
    /// what an assistant's `draft_cards` made.
    struct Outcome: Equatable {
        let runID: String
        let finishedAt: Date
        let sourceIDs: [String]
        /// Nil when the run was stopped or failed.
        let result: CardDraftingResult?
        /// Why it made nothing, when it did not finish.
        let message: String?
    }

    @Published private(set) var runs: [Run] = []
    private var tasks: [String: Task<Result<CardDraftingResult, Error>, Never>] = [:]
    private(set) var outcomes: [Outcome] = []
    static let keptOutcomes = 20

    // MARK: Runs

    /// Whether any run is drafting `sourceID` now.
    func isDrafting(_ sourceID: String) -> Bool {
        runs.contains { $0.sourceIDs.contains(sourceID) }
    }

    /// The run drafting `sourceID`, for its Stop.
    func run(drafting sourceID: String) -> Run? {
        runs.first { $0.sourceIDs.contains(sourceID) }
    }

    /// The runs making cards for a notebook, oldest first.
    func runs(inNotebook notebookID: String) -> [Run] {
        runs.filter { $0.notebookID == notebookID }
    }

    /// Stops a run: the sources already drafted keep their cards; nothing
    /// more is drafted.
    func cancel(_ runID: String) {
        tasks[runID]?.cancel()
    }

    // MARK: Read and plan, off the main actor

    nonisolated static func load(_ request: CardDraftingRequest, storage: StorageService) async throws -> CardDraftingMaterials {
        try await CardDraftingService.load(request, storage: storage)
    }

    /// The plan for what was read, on the learner's Card Drafting route as
    /// it stands now. Throws when no model is configured.
    nonisolated static func plan(
        _ materials: CardDraftingMaterials,
        count: MemoryCardRequestCount,
        focus: String?
    ) async throws -> CardDraftingPlan {
        guard let route = CardDraftingRoute.current() else { throw CardDraftingError.noModel }
        return CardDraftingService.plan(materials, count: count, focus: .some(focus), route: route)
    }

    /// Drafts `plan` as a run of this coordinator, listed until it ends,
    /// and returns when it has ended. `draft_cards` calls this from its
    /// background work, so an assistant's run shows in the Reader and the
    /// Studio with its Stop, and spends against what the assistant was
    /// approved for (the task inherits its running-work id).
    func write(
        _ plan: CardDraftingPlan,
        runID: String = UUID().uuidString.lowercased(),
        storage: StorageService,
        backend: (any CardDraftingBackend)? = nil,
        onProgress: (@Sendable (CardDraftingProgress) async -> Void)? = nil
    ) async -> Result<CardDraftingResult, Error> {
        guard tasks[runID] == nil else { return .failure(CancellationError()) }
        let sourceIDs = plan.sources.map(\.source.sourceID) + plan.sources.map(\.source.requestedID)
        runs.append(Run(
            id: runID,
            notebookID: plan.request.notebookID,
            sourceIDs: Array(Set(sourceIDs)).sorted(),
            startedAt: Date(),
            progress: CardDraftingProgress(done: 0, total: plan.sources.count)
        ))
        let writer = backend ?? LiveCardDraftingBackend(aiService: AIService())
        let task = Task<Result<CardDraftingResult, Error>, Never> {
            do {
                let drafted = try await CardDraftingService.shared.run(
                    plan,
                    storage: storage,
                    backend: writer,
                    gate: .learnerStarted
                ) { progress in
                    await self.setProgress(progress, for: runID)
                    await onProgress?(progress)
                }
                return .success(drafted)
            } catch {
                if error is CancellationError || Task.isCancelled { return .failure(CancellationError()) }
                return .failure(error)
            }
        }
        tasks[runID] = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        tasks[runID] = nil
        runs.removeAll { $0.id == runID }
        let outcome: Outcome
        switch result {
        case .success(let drafted):
            outcome = Outcome(runID: runID, finishedAt: Date(), sourceIDs: Array(Set(sourceIDs)), result: drafted, message: nil)
        case .failure(let error) where error is CancellationError:
            outcome = Outcome(
                runID: runID, finishedAt: Date(), sourceIDs: Array(Set(sourceIDs)), result: nil,
                message: "Stopped; the sources drafted before the stop keep their cards."
            )
        case .failure(let error):
            outcome = Outcome(runID: runID, finishedAt: Date(), sourceIDs: Array(Set(sourceIDs)), result: nil, message: error.localizedDescription)
        }
        outcomes.append(outcome)
        if outcomes.count > Self.keptOutcomes { outcomes.removeFirst(outcomes.count - Self.keptOutcomes) }
        return result
    }

    private func setProgress(_ progress: CardDraftingProgress, for runID: String) {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[index].progress = progress
    }

    /// The finished runs that drafted any of `sourceIDs`, newest first; every
    /// run kept when `sourceIDs` is nil.
    func outcomes(touching sourceIDs: Set<String>?) -> [Outcome] {
        outcomes.reversed().filter { outcome in
            guard let sourceIDs else { return true }
            return !sourceIDs.isDisjoint(with: outcome.sourceIDs)
        }
    }
}

// MARK: - The Studio's pending rows

/// A notebook's cards being made, where its outputs are listed: the run's
/// progress and Stop. Its drafts land in To Check, the Cards row above.
struct CardDraftingRunsList: View {
    var vm: StudioViewModel
    let notebookID: String
    @ObservedObject private var coordinator = CardDraftingCoordinator.shared

    var body: some View {
        ForEach(coordinator.runs(inNotebook: notebookID)) { run in
            HStack(spacing: 10) {
                NotebookStudioBadge(symbolName: MemoryReviewSession.sidebarIcon, hue: NotebookStudioTile.cards.hue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cards").lineLimit(1)
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
                    .accessibilityIdentifier("cards-run.stop")
            }
            .contextMenu {
                Button("Stop Making Cards", systemImage: "stop.circle") { coordinator.cancel(run.id) }
            }
        }
    }
}
#endif
