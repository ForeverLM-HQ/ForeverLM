#if os(macOS)
import Foundation
import SwiftUI

/// The Mac's Explain action, shared by the reader toolbar and the sidebar's
/// context menu: write the explainer, show it, then hand it to the same
/// interactive audio path the sidebar's Generate Audio uses, so the cost
/// alert, the language check and the progress badge are the ones the learner
/// already knows.
///
/// The write is the coordinator's own task, not the caller's, so Cancel — in
/// the strip's work icon (`StudioWorkButton`), the toolbar and the context
/// menu — can end it from anywhere while the request is still out to the
/// model. The pipeline checks for cancellation before it saves, so a stopped
/// write leaves nothing behind.
@MainActor
final class ExplainerGenerationCoordinator: ObservableObject {
    static let shared = ExplainerGenerationCoordinator()

    /// One explainer being written: the source's id and the title the work
    /// chip names it by.
    struct Writing: Identifiable, Equatable {
        let id: String
        let title: String
    }

    /// The explainers being written right now, oldest first.
    @Published private(set) var writings: [Writing] = []
    private var tasks: [String: Task<Void, Never>] = [:]

    func isWriting(_ sourceID: String) -> Bool {
        tasks[sourceID] != nil
    }

    /// Writes the source's explainer and returns when the write has ended,
    /// however it ended. A source already being written is left alone.
    func explain(_ article: StudioArticle, in vm: StudioViewModel, length: ExplainerLength = .default) async {
        guard tasks[article.id] == nil else { return }
        let title = vm.displayTitle(for: article)
        let task = Task { await self.write(article, title: title, in: vm, length: length) }
        tasks[article.id] = task
        writings.append(Writing(id: article.id, title: title))
        await task.value
    }

    /// Stops writing the source's explainer. Nothing is saved; the source
    /// keeps whatever explainer it already had.
    func cancel(_ sourceID: String) {
        tasks[sourceID]?.cancel()
    }

    private func write(_ article: StudioArticle, title: String, in vm: StudioViewModel, length: ExplainerLength) async {
        defer {
            tasks[article.id] = nil
            writings.removeAll { $0.id == article.id }
        }

        let service = ExplainerGeneratorService(
            storage: vm.storage,
            backend: LiveExplainerModelBackend(aiService: AIService()),
            figureIndexer: vm.paperFigureIndexer
        )
        let result: ExplainerGenerationResult
        do {
            result = try await service.run(request: ExplainerRequest(sourceID: article.id, length: length))
        } catch {
            // A cancelled request can surface as its own CancellationError or
            // as the transport's cancelled error wrapped by the provider;
            // either way the learner asked for it, so it is not a failure.
            if error is CancellationError || Task.isCancelled {
                vm.showToast("Stopped writing the explainer of \(title)")
            } else {
                vm.showToast(error.localizedDescription)
            }
            return
        }

        await vm.refreshAfterCloudKitRemoteChange(affectedEntities: [.source], requiresFullRefresh: false)
        // The partial refresh can return before the new explainer is in the
        // list, and the Reader then opened an id it could not resolve: "No
        // Content", which no later refresh replaced (seen on build 143,
        // 2026-09-24). The saved record is in hand, so the list takes it
        // directly; a rewrite replaces the explainer it already had.
        if let index = vm.articles.firstIndex(where: { $0.id == result.explainer.id }) {
            vm.articles[index] = result.explainer
        } else {
            vm.articles.insert(result.explainer, at: 0)
        }
        await vm.selectArticle(result.explainer.id)

        // With Explainers switched on under Settings › Text to Speech › Automatic
        // audio, the standing opt-in is the consent: the audio starts with the
        // selected voice and no cost alert, exactly as it would for an
        // explainer that arrived from another device. Otherwise the sidebar's
        // interactive path asks, as it always has.
        let interaction: ArticleSpeechGenerationInteraction =
            MacArticleSpeechSettings.automaticAudioStartsWithoutConfirmation(
                kind: SourceAudioAutomation.explainerKind
            )
            ? .headless(costApproved: true, allowsUnsupportedLanguage: false)
            : .interactive
        switch await ArticleSpeechService.shared.generateAudio(article: result.explainer, interaction: interaction) {
        case .started:
            vm.showToast("Explainer written; generating its audio")
        case .alreadyReady, .alreadyGenerating, .cancelled:
            vm.showToast("Explainer written")
        case .failed(let message):
            vm.showToast("Explainer written. \(message)")
        case .unsupportedLanguage(let message):
            // Headless only: the switch approved the spend, not a voice that
            // cannot speak the script's language.
            vm.showToast("Explainer written. \(message)")
        case .needsCostApproval:
            // Interactive requests answer cost with an alert inside
            // generateAudio, and the headless request above approved it.
            break
        }
    }
}
#endif
