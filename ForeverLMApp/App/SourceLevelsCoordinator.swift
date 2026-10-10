#if os(macOS)
import Foundation
import Observation
import SwiftUI

// MARK: - Levels in the Reader: the app's side
//
// docs/sensemaking-design.md, "Levels in the Reader". The Reader's Levels
// panel and `get_source_levels` write a source's levels through one
// coordinator, so a second ask for a source already being written waits for
// that run instead of paying twice; the panel shows its progress line and
// Stop. The panel's own choices — shown or not, its zoom, Follow — are this
// session's, like the Highlights list beside it.

extension Notification.Name {
    /// A source's levels were written. The object is the source's id.
    static let sourceLevelsDidChange = Notification.Name("sourceLevelsDidChange")
}

@MainActor
final class SourceLevelsCoordinator: ObservableObject {
    static let shared = SourceLevelsCoordinator()

    struct Run: Equatable {
        let sourceID: String
        var progress: SourceLevelsProgress
    }

    @Published private(set) var runs: [String: Run] = [:]
    /// Why the last run for a source ended without levels, until the next
    /// run starts; the panel says it where the learner pressed Write.
    @Published private(set) var failures: [String: String] = [:]
    private var tasks: [String: Task<Result<SourceLevels, Error>, Never>] = [:]

    func run(for sourceID: String) -> Run? { runs[sourceID] }

    func isWriting(_ sourceID: String) -> Bool { runs[sourceID] != nil }

    func failure(for sourceID: String) -> String? { failures[sourceID] }

    /// Stops a run; nothing it wrote is saved.
    func cancel(_ sourceID: String) {
        tasks[sourceID]?.cancel()
    }

    /// Writes a source's levels and saves them, or waits for the run already
    /// writing them. The learner's own press, so no background budget gates
    /// it (`AITask.sourceLevels` is learner-started).
    func write(sourceID: String, storage: StorageService) async -> Result<SourceLevels, Error> {
        if let running = tasks[sourceID] { return await running.value }
        failures[sourceID] = nil
        runs[sourceID] = Run(sourceID: sourceID, progress: SourceLevelsProgress(done: 0, total: 1))
        let task = Task<Result<SourceLevels, Error>, Never> {
            do {
                let levels = try await SourceLevelsWriter.write(sourceID: sourceID, storage: storage) { progress in
                    await SourceLevelsCoordinator.shared.note(progress, for: sourceID)
                }
                return .success(levels)
            } catch {
                return .failure(error)
            }
        }
        tasks[sourceID] = task
        // Stopping the caller stops the run: `cancel_ai_work` on the MCP
        // call that started it, as the panel's Stop does.
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        tasks[sourceID] = nil
        runs[sourceID] = nil
        switch result {
        case .success:
            NotificationCenter.default.post(name: .sourceLevelsDidChange, object: sourceID)
        case .failure(let error):
            if !(error is CancellationError) { failures[sourceID] = error.localizedDescription }
        }
        return result
    }

    private func note(_ progress: SourceLevelsProgress, for sourceID: String) {
        guard runs[sourceID] != nil else { return }
        runs[sourceID]?.progress = progress
    }
}

/// The Levels panel's choices for this session: whether it shows, at which
/// zoom, and whether it follows the learner's place.
@MainActor
@Observable
final class ReaderLevelsPanelState {
    static let shared = ReaderLevelsPanelState()

    enum Zoom: String, CaseIterable, Identifiable {
        case gist
        case sections
        case paragraphs

        var id: String { rawValue }

        var title: String {
            switch self {
            case .gist: return "Gist"
            case .sections: return "Sections"
            case .paragraphs: return "Paragraphs"
            }
        }
    }

    var isVisible = false {
        didSet {
            // Levels and Linked References share the trailing column
            // (ReaderReferencesPanel.swift): one at a time.
            if isVisible, ReaderReferencesPanelState.shared.isVisible {
                ReaderReferencesPanelState.shared.isVisible = false
            }
        }
    }
    var zoom: Zoom = .sections
    var follows = true
    /// Sources whose Key terms the learner folded away; open otherwise.
    var foldedTerms: Set<String> = []

    nonisolated init() {}
}

/// Where each source's Reader stands, as its reader reports it to the view
/// model (`updateReadingPosition`, `updateReadingLocator`): the Levels panel
/// reads it to follow the learner. Only a panel on screen reads it, so a
/// change redraws nothing else.
@MainActor
@Observable
final class ReaderLevelsPositionFeed {
    static let shared = ReaderLevelsPositionFeed()

    private(set) var positions: [String: ReaderLevelsPosition] = [:]

    nonisolated init() {}

    func position(for sourceID: String) -> ReaderLevelsPosition? {
        positions[sourceID]
    }

    func note(_ position: ReaderLevelsPosition, for sourceID: String) {
        let kept: ReaderLevelsPosition
        switch position {
        case .page:
            kept = position
        case .fraction(let fraction):
            // A web page reports every few pixels; the panel needs no more
            // than a few hundred steps down a source.
            kept = .fraction((min(max(fraction, 0), 1) * 400).rounded() / 400)
        }
        guard positions[sourceID] != kept else { return }
        positions[sourceID] = kept
    }
}

/// Which sources the Reader offers Levels for: the ones read as text —
/// papers, articles and book chapters — that have text, and not a spoken
/// script ForeverLM wrote.
enum ReaderLevels {
    static func offers(_ article: StudioArticle) -> Bool {
        switch article.sourceType {
        case .paper, .article, .book, .manual, .unclassified:
            return !TextToSpeechPreparationPolicy.isSpokenScript(url: article.url)
        case .podcast, .course, .meeting, .video, .xPost:
            return false
        }
    }
}
#endif
