#if os(macOS)
import Combine
import Foundation

/// One source an MCP caller asked to have narrated, and where that stands.
struct SourceAudioGenerationItem: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case queued
        case generating
        case ready
        case failed(String)
        /// Never attempted, for a reason the caller can act on (no readable
        /// text, a language no voice speaks, already generating in the app).
        case skipped(String)
        case cancelled

        var isActive: Bool {
            switch self {
            case .queued, .generating: return true
            case .ready, .failed, .skipped, .cancelled: return false
            }
        }

        var label: String {
            switch self {
            case .queued: return "queued"
            case .generating: return "generating"
            case .ready: return "ready"
            case .failed: return "failed"
            case .skipped: return "skipped"
            case .cancelled: return "cancelled"
            }
        }

        var detail: String? {
            switch self {
            case .failed(let message), .skipped(let message): return message
            case .queued, .generating, .ready, .cancelled: return nil
            }
        }
    }

    let sourceID: String
    let title: String
    /// The book the chapter belongs to, when it is one.
    let group: String?
    let sourceType: String
    var status: Status
    let enqueuedAt: Date
    var endedAt: Date?
}

/// Text-to-speech generation for a batch of sources asked for over MCP.
///
/// The sidebar's Generate Audio starts one source and lets the speech service
/// run it. "Generate audio for every book in my library" is hundreds of
/// chapters, and starting them all at once would open every chunk request at
/// the provider together. This queue feeds `ArticleSpeechService.generateAudio`
/// a bounded number of sources at a time, in the order the caller gave them
/// (chapters in reading order, so a book becomes listenable from the front),
/// and remembers how each ended so the caller can ask later. Every run is the
/// same headless, pre-approved generation; the approval itself happened in the
/// tool call, against the quote it returned.
@MainActor
final class SourceAudioGenerationQueue: ObservableObject {
    static let shared = SourceAudioGenerationQueue(speech: ArticleSpeechService.shared)

    /// Sources generating at once. Each one already fans out its chunks to the
    /// provider's per-source concurrency, so this stays small.
    static let maxConcurrentSources = 2
    /// Finished entries kept for status queries before the oldest are dropped.
    static let retainedFinishedItems = 500

    @Published private(set) var items: [SourceAudioGenerationItem] = []
    /// Every source the speech service is generating in the background right
    /// now, whether it came through this queue or the sidebar's own Generate
    /// Audio. Mirrored here so rows can observe one small object that changes
    /// only when a run starts or ends, not the service's per-tick playback clock.
    @Published private(set) var generatingSourceIDs: Set<String> = []
    /// How far each of those narrations has got, mirrored the same way: it
    /// changes once a part lands, so a row shows "Making narration · 40%"
    /// without observing the speech service's playback clock.
    @Published private(set) var progressBySourceID: [String: ArticleSpeechChunkProgress] = [:]
    /// When the learner last dismissed the finished-batch panel; entries that
    /// ended before this are no longer shown there.
    @Published private(set) var panelDismissedAt: Date = .distantPast

    private let speech: ArticleSpeechService
    private var allowsUnsupportedLanguages: [String: Bool] = [:]
    private var installedEndHook = false
    private var generatingMirror: AnyCancellable?
    private var progressMirror: AnyCancellable?

    init(speech: ArticleSpeechService) {
        self.speech = speech
        generatingMirror = speech.$backgroundGenerationSourceIDs
            .removeDuplicates()
            .sink { [weak self] ids in self?.generatingSourceIDs = ids }
        progressMirror = speech.$backgroundGenerationProgress
            .removeDuplicates()
            .sink { [weak self] progress in self?.progressBySourceID = progress }
    }

    func isGenerating(_ sourceID: String) -> Bool {
        generatingSourceIDs.contains(sourceID) || item(for: sourceID)?.status == .generating
    }

    func dismissFinished() {
        panelDismissedAt = Date()
    }

    var activeSourceIDs: Set<String> {
        Set(items.filter { $0.status.isActive }.map(\.sourceID))
    }

    var queuedCount: Int { items.filter { $0.status == .queued }.count }
    var generatingCount: Int { items.filter { $0.status == .generating }.count }

    /// Adds the sources in the given order. Sources already queued or generating
    /// are left alone and reported back so the caller can say so.
    @discardableResult
    func enqueue(
        _ articles: [StudioArticle],
        allowsUnsupportedLanguages: Bool
    ) -> (queued: [String], alreadyActive: [String]) {
        installEndHookIfNeeded()
        var queued: [String] = []
        var alreadyActive: [String] = []
        let active = activeSourceIDs
        var seen = Set<String>()
        for article in articles where !seen.contains(article.id) {
            seen.insert(article.id)
            if active.contains(article.id) {
                alreadyActive.append(article.id)
                continue
            }
            // A finished entry for the same source is superseded by the new ask.
            items.removeAll { $0.sourceID == article.id }
            items.append(SourceAudioGenerationItem(
                sourceID: article.id,
                title: article.title,
                group: article.parentGroup,
                sourceType: article.sourceType.rawValue,
                status: .queued,
                enqueuedAt: Date(),
                endedAt: nil
            ))
            pendingArticles[article.id] = article
            self.allowsUnsupportedLanguages[article.id] = allowsUnsupportedLanguages
            queued.append(article.id)
        }
        pruneFinished()
        pump()
        return (queued, alreadyActive)
    }

    /// Stops the given sources, or everything when `sourceIDs` is nil. Queued
    /// entries are dropped; a generating one is cancelled in the speech service,
    /// which reports back through the end hook.
    func cancel(sourceIDs: Set<String>?) -> (cancelled: [String], notActive: [String]) {
        var cancelled: [String] = []
        var notActive: [String] = []
        let targets: [String]
        if let sourceIDs {
            targets = Array(sourceIDs)
        } else {
            let queued = items.filter { $0.status.isActive }.map(\.sourceID)
            targets = queued + speech.backgroundGenerationSourceIDs.subtracting(queued).sorted()
        }
        for sourceID in targets {
            guard let index = items.firstIndex(where: { $0.sourceID == sourceID }),
                  items[index].status.isActive else {
                // A narration the learner started with Listen or Generate
                // Audio has no entry here; it is stopped through the service,
                // so a run that has hung can be ended from outside the app
                // (it used to answer "not active" and stay for ever).
                if speech.backgroundGenerationSourceIDs.contains(sourceID) || speech.isMakingNarration(sourceID) {
                    speech.stopMakingNarration(sourceID: sourceID)
                    cancelled.append(sourceID)
                } else {
                    notActive.append(sourceID)
                }
                continue
            }
            switch items[index].status {
            case .queued:
                pendingArticles[sourceID] = nil
                finish(sourceID: sourceID, status: .cancelled)
            case .generating:
                // The service calls back with `.cancelled`; mark it now so a
                // status read between the two never shows it still running.
                finish(sourceID: sourceID, status: .cancelled)
                speech.cancelBackgroundGeneration(sourceID: sourceID)
            default:
                break
            }
            cancelled.append(sourceID)
        }
        pump()
        return (cancelled, notActive)
    }

    func item(for sourceID: String) -> SourceAudioGenerationItem? {
        items.first { $0.sourceID == sourceID }
    }

    /// The books with chapters still queued or generating. A book row asks this
    /// set rather than scanning the item list itself, so the sidebar stays
    /// cheap while a few hundred chapters are in flight.
    var activeGroups: Set<String> {
        Set(items.compactMap { $0.status.isActive ? $0.group : nil })
    }

    /// How far a book has to go, as chapters left of chapters asked for.
    /// Counts only this queue's entries, so a chapter narrated some other day
    /// is neither remaining nor part of the total.
    func progress(forGroup group: String) -> (remaining: Int, total: Int) {
        let chapters = items.filter { $0.group == group }
        return (chapters.filter { $0.status.isActive }.count, chapters.count)
    }

    // MARK: - Driving the speech service

    private var pendingArticles: [String: StudioArticle] = [:]

    private func installEndHookIfNeeded() {
        guard !installedEndHook else { return }
        installedEndHook = true
        speech.backgroundGenerationDidEnd = { [weak self] sourceID, outcome in
            self?.noteEnded(sourceID: sourceID, outcome: outcome)
        }
    }

    private func pump() {
        while generatingCount < Self.maxConcurrentSources,
              let index = items.firstIndex(where: { $0.status == .queued }) {
            let sourceID = items[index].sourceID
            guard let article = pendingArticles.removeValue(forKey: sourceID) else {
                finish(sourceID: sourceID, status: .failed("The source was no longer available to generate."))
                continue
            }
            items[index].status = .generating
            let allowsUnsupported = allowsUnsupportedLanguages[sourceID] ?? false
            Task { [weak self] in
                guard let self else { return }
                let result = await self.speech.generateAudio(
                    article: article,
                    interaction: .headless(
                        costApproved: true,
                        allowsUnsupportedLanguage: allowsUnsupported
                    )
                )
                self.noteStartResult(result, sourceID: sourceID)
            }
        }
    }

    private func noteStartResult(_ result: ArticleSpeechGenerationRequestResult, sourceID: String) {
        // A cancel that landed while generateAudio was preparing already
        // settled this entry; do not resurrect it.
        guard item(for: sourceID)?.status == .generating else { return }
        switch result {
        case .started:
            // Ends through `backgroundGenerationDidEnd`.
            return
        case .alreadyReady:
            finish(sourceID: sourceID, status: .ready)
        case .alreadyGenerating:
            finish(sourceID: sourceID, status: .skipped("Already generating in the app; it will finish on its own."))
        case .cancelled:
            finish(sourceID: sourceID, status: .cancelled)
        case .failed(let message):
            finish(sourceID: sourceID, status: .failed(message))
        case .unsupportedLanguage(let message):
            finish(sourceID: sourceID, status: .skipped(message))
        case .needsCostApproval(let estimate, let model):
            // Unreachable: the queue always runs pre-approved. Reported rather
            // than swallowed so a regression is visible in status.
            finish(sourceID: sourceID, status: .failed(
                "Generation asked for cost approval again (\(model), \(estimate.summary))."
            ))
        }
        pump()
    }

    private func noteEnded(sourceID: String, outcome: ArticleSpeechBackgroundGenerationOutcome) {
        guard item(for: sourceID)?.status == .generating else { return }
        switch outcome {
        case .ready: finish(sourceID: sourceID, status: .ready)
        case .failed(let message): finish(sourceID: sourceID, status: .failed(message))
        case .cancelled: finish(sourceID: sourceID, status: .cancelled)
        }
        pump()
    }

    private func finish(sourceID: String, status: SourceAudioGenerationItem.Status) {
        guard let index = items.firstIndex(where: { $0.sourceID == sourceID }) else { return }
        items[index].status = status
        items[index].endedAt = Date()
        allowsUnsupportedLanguages[sourceID] = nil
    }

    private func pruneFinished() {
        let finished = items.filter { !$0.status.isActive }
        guard finished.count > Self.retainedFinishedItems else { return }
        let dropCount = finished.count - Self.retainedFinishedItems
        let dropIDs = Set(finished.prefix(dropCount).map(\.sourceID))
        items.removeAll { dropIDs.contains($0.sourceID) }
    }
}
#endif
