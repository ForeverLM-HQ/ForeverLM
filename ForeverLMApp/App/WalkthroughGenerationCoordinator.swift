#if os(macOS)
import Foundation
import SwiftUI
import os

/// The Mac's Walk Through action, shared by the reader toolbar, the ⋯ menu
/// and a book's sidebar row: write the source's walkthrough, have the chat
/// beside the Reader play it as soon as the steps are saved, and keep drawing
/// its animations behind it.
///
/// The write is the coordinator's own task, not the caller's, so Cancel can
/// end it from anywhere. The pipeline saves the steps before it draws a single
/// animation, so a run stopped halfway leaves a walk that works and merely
/// lacks some motion.
@MainActor
final class WalkthroughGenerationCoordinator: ObservableObject {
    private nonisolated static let logger = Logger(subsystem: "com.foreverlm", category: "Walkthroughs")
    static let shared = WalkthroughGenerationCoordinator()

    struct Run: Identifiable, Equatable {
        let id: String
        let title: String
        var stage: PaperWalkthroughGenerationStage
    }

    @Published private(set) var runs: [Run] = []
    /// Chapters still to write, by book, while Write Walkthroughs for All
    /// Chapters runs; the book row's item reads its count.
    @Published private(set) var batchRemainingByGroup: [String: Int] = [:]
    /// The write itself, by source, so Cancel reaches the pipeline.
    private var tasks: [String: Task<Outcome, Never>] = [:]

    func isGenerating(_ sourceID: String) -> Bool {
        tasks[sourceID] != nil
    }

    func stage(for sourceID: String) -> PaperWalkthroughGenerationStage? {
        runs.first { $0.id == sourceID }?.stage
    }

    /// How many chapters of the book a running batch has still to write; 0
    /// when none runs.
    func batchRemaining(forGroup groupName: String) -> Int {
        batchRemainingByGroup[groupName] ?? 0
    }

    /// Whether the source has a walkthrough row, current or stale. One query,
    /// so a menu can ask on open.
    nonisolated static func hasWalkthrough(for article: StudioArticle, storage: StorageService) async -> Bool {
        do {
            return try await storage.hasPaperWalkthrough(article.id)
        } catch {
            logger.error("Checking for a walkthrough failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Writes the source's walkthrough and returns when the run has ended,
    /// however it ended. A source already being written is left alone.
    func generate(_ article: StudioArticle, in vm: StudioViewModel, drawsAnimations: Bool = true) async {
        await generate(article, in: vm, drawsAnimations: drawsAnimations, showsPanel: true, toasts: true)
    }

    /// One book, one click (product owner, 2026-09-19: "books (or chapters
    /// thereof)"): writes a walkthrough for each chapter that can be walked
    /// through and has no current one — none, or one written for text the
    /// chapter no longer carries — one after another, steps only. Animations
    /// are off so the cost is one writing call a chapter; a chapter's own
    /// Write Walkthrough Again draws them. The panel is not opened for each
    /// chapter as it lands, and the toast comes once, at the end; the first
    /// failure stops the batch and names the chapter.
    func generateMissing(for chapters: [StudioArticle], group groupName: String, in vm: StudioViewModel) async {
        guard batchRemaining(forGroup: groupName) == 0 else { return }
        let candidates = chapters.filter { PaperWalkthroughGeneratorService.canWalkThrough($0) }
        let current: [String: PaperWalkthroughStatus]
        do {
            current = try await vm.storage.paperWalkthroughStatuses(for: candidates.map(\.id))
        } catch {
            Self.logger.error("Reading the walkthrough statuses failed: \(error.localizedDescription, privacy: .public)")
            current = [:]
        }
        let pending = candidates.filter { current[$0.id] != .ok && !isGenerating($0.id) }
        guard !pending.isEmpty else {
            vm.showToast(candidates.isEmpty
                ? "No chapter of \(vm.bookDisplayName(groupName)) is ready to walk through"
                : "Every chapter of \(vm.bookDisplayName(groupName)) already has a walkthrough")
            return
        }
        batchRemainingByGroup[groupName] = pending.count
        defer { batchRemainingByGroup[groupName] = nil }

        var written = 0
        for chapter in pending {
            let outcome = await generate(chapter, in: vm, drawsAnimations: false, showsPanel: false, toasts: false)
            batchRemainingByGroup[groupName] = max(0, (batchRemainingByGroup[groupName] ?? 1) - 1)
            switch outcome {
            case .written:
                written += 1
            case .cancelled:
                vm.showToast("Stopped after \(written) of \(pending.count) chapter walkthroughs of \(vm.bookDisplayName(groupName))")
                return
            case .failed(let message):
                vm.showToast("Stopped at \(vm.displayTitle(for: chapter)) after \(written) of \(pending.count) chapter walkthroughs: \(message)")
                return
            case .alreadyRunning:
                continue
            }
        }
        vm.showToast("Wrote \(written) chapter walkthrough\(written == 1 ? "" : "s") for \(vm.bookDisplayName(groupName))")
    }

    /// Stops writing. Steps already saved stay; a source that had a walkthrough
    /// before the run keeps whichever one was saved last.
    func cancel(_ sourceID: String) {
        tasks[sourceID]?.cancel()
    }

    /// Removes the source's walkthrough; a chat playing it drops the walk on
    /// its next reload, and the page's outline comes down.
    func remove(_ article: StudioArticle, in vm: StudioViewModel) async {
        cancel(article.id)
        do {
            let removed = try await vm.storage.deletePaperWalkthrough(article.id)
            vm.noteWalkthroughChanged()
            vm.clearWalkthroughFocus()
            vm.showToast(removed ? "Removed the walkthrough of \(vm.displayTitle(for: article))" : "No walkthrough to remove")
        } catch {
            vm.showToast(error.localizedDescription)
        }
    }

    // MARK: Runs

    enum Outcome: Equatable {
        case written
        case cancelled
        case failed(String)
        case alreadyRunning
    }

    @discardableResult
    private func generate(
        _ article: StudioArticle,
        in vm: StudioViewModel,
        drawsAnimations: Bool,
        showsPanel: Bool,
        toasts: Bool
    ) async -> Outcome {
        guard tasks[article.id] == nil else { return .alreadyRunning }
        let title = vm.displayTitle(for: article)
        let task = Task<Outcome, Never> {
            await self.write(article, title: title, in: vm, drawsAnimations: drawsAnimations, showsPanel: showsPanel, toasts: toasts)
        }
        tasks[article.id] = task
        runs.append(Run(id: article.id, title: title, stage: .reading))
        return await task.value
    }

    private func update(_ sourceID: String, stage: PaperWalkthroughGenerationStage) {
        guard let index = runs.firstIndex(where: { $0.id == sourceID }) else { return }
        runs[index].stage = stage
    }

    private func write(
        _ article: StudioArticle,
        title: String,
        in vm: StudioViewModel,
        drawsAnimations: Bool,
        showsPanel: Bool,
        toasts: Bool
    ) async -> Outcome {
        defer {
            tasks[article.id] = nil
            runs.removeAll { $0.id == article.id }
        }

        let service = PaperWalkthroughGeneratorService(
            storage: vm.storage,
            backend: LivePaperWalkthroughModelBackend(aiService: AIService()),
            figureIndexer: vm.paperFigureIndexer
        )
        let sourceID = article.id
        let result: PaperWalkthroughGenerationResult
        do {
            result = try await service.run(
                request: PaperWalkthroughRequest(sourceID: sourceID, drawsAnimations: drawsAnimations),
                onStage: { stage in
                    Task { @MainActor in self.update(sourceID, stage: stage) }
                },
                onStepsSaved: { _ in
                    Task { @MainActor in
                        vm.noteWalkthroughChanged()
                        if showsPanel { vm.requestWalkthroughPlayback(for: sourceID) }
                    }
                }
            )
        } catch {
            vm.noteWalkthroughChanged()
            if error is CancellationError || Task.isCancelled {
                if toasts { vm.showToast("Stopped writing the walkthrough of \(title)") }
                return .cancelled
            }
            if toasts { vm.showToast(error.localizedDescription) }
            return .failed(error.localizedDescription)
        }

        vm.noteWalkthroughChanged()
        if toasts { vm.showToast(Self.summary(of: result)) }
        return .written
    }

    /// One line on what the run produced, for the toast. Pure, so a test can
    /// read it off any actor.
    nonisolated static func summary(of result: PaperWalkthroughGenerationResult) -> String {
        let walkthrough = result.walkthrough
        var parts: [String] = ["\(walkthrough.steps.count) steps"]
        if walkthrough.quizCount > 0 { parts.append("\(walkthrough.quizCount) questions") }
        if walkthrough.animationCount > 0 { parts.append("\(walkthrough.animationCount) animations") }
        var line = (result.replacedExisting ? "Walkthrough rewritten: " : "Walkthrough written: ") + parts.joined(separator: ", ")
        if !result.animationFailures.isEmpty {
            line += ". \(result.animationFailures.count) animation\(result.animationFailures.count == 1 ? "" : "s") could not be drawn"
        }
        return line
    }
}
#endif
