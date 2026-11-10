#if os(macOS)
import Foundation
import os
import PDFKit
import SwiftUI

enum ArticleSpeechContent {
    private static let storage = StorageService()
    /// Podcasts, YouTube videos, and meeting sessions whose recording plays
    /// in-app already carry their original audio, so generated text-to-speech is
    /// never offered for them — only their stale cached audio stays deletable
    /// via the reader overflow menu. Meetings without a playable recording
    /// (Read AI sessions, transcript-only folders) keep text-to-speech.
    static func isOriginalAudioSource(_ article: StudioArticle) -> Bool {
        article.sourceType == .podcast || article.isYouTubeURL
            || (article.sourceType == .meeting
                && MeetingRecordingAvailability.hasPlayableRecording(sourceID: article.id))
    }

    static func canAttemptRead(_ article: StudioArticle) -> Bool {
        guard !isOriginalAudioSource(article) else {
            return false
        }
        // A paper is listenable once its text is final — metadata and the
        // clean-up committed. The Listen derivative is prepared when the
        // learner presses Listen (2026-09-24), so it cannot gate the button.
        if article.sourceType == .paper, !article.isPaperReadyForListenPreparation {
            return false
        }

        // Called from SwiftUI view bodies (source rows, reader toolbars), so it
        // must stay cheap: look for the first non-whitespace character instead
        // of trimming (copying) the whole content string on every render, and
        // resolve local paths through the cached-only accessors — the stat-ing
        // ones block for seconds against an evicted iCloud file.
        if let content = article.content,
           content.contains(where: { !$0.isWhitespace }) {
            return true
        }
        if article.isPDF, article.cachedResolvedPDFPath != nil {
            return true
        }
        if (article.cachedIsEPUBChapter || article.cachedIsArchivedArticle),
           article.cachedResolvedLocalPath != nil {
            return true
        }
        if isWebURL(article.url) && !article.url.lowercased().hasSuffix(".pdf") {
            return true
        }
        return false
    }

    static func text(for article: StudioArticle) async -> String? {
        guard !isOriginalAudioSource(article) else {
            return nil
        }
        guard article.sourceType != .paper || article.isPaperReadyForListenPreparation else {
            return nil
        }

        // The reader can retain an older StudioArticle value while cleanup or a
        // sync commits newer canonical text. Read persisted content first
        // because every saved listenable derivative is integrity-bound to that
        // SQLite row; preparing from the stale view-model snapshot would make a
        // Listen click fail when the derivative is committed.
        if let persisted = await persistedText(sourceID: article.id) {
            return persisted
        }

        // Papers have one ingestion-time canonical derivative. Never reopen the
        // PDF here: doing so would bypass cleanup and make text-to-speech disagree
        // with source chat, embeddings and MCP.
        if article.sourceType == .paper {
            if let content = cleaned(article.content), !content.isEmpty {
                return content
            }
            return nil
        }

        if article.isPDF, let path = article.resolvedPDFPath {
            if let text = pdfText(at: path, pages: article.bookPages) {
                return text
            }
        }

        if let content = cleaned(article.content), !content.isEmpty {
            return content
        }

        if article.isEPUBChapter || article.isArchivedArticle, let path = article.resolvedLocalPath {
            return fileText(at: path)
        }

        if isWebURL(article.url) && !article.url.lowercased().hasSuffix(".pdf") {
            return await webText(from: article.url)
        }

        return nil
    }

    static func persistedText(sourceID: String) async -> String? {
        cleaned(await storage.loadSourceContent(sourceID))
    }

    static func listenableContent(sourceID: String) async -> StoredSourceListenableContent? {
        try? await storage.loadSourceListenableContent(sourceID)
    }

    static func saveListenableContent(
        candidate: SourceListenableContentCandidate,
        text: String,
        preparationSignature: String?
    ) async throws {
        try await storage.applySourceListenableContent(
            candidate: candidate,
            text: text,
            preparationSignature: preparationSignature
        )
    }

    private static func webText(from urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(SharedWebKit.desktopSafariUserAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty else {
                return nil
            }

            let mimeType = http.mimeType?.lowercased() ?? ""
            if mimeType.contains("html") || url.pathExtension.lowercased().contains("html") {
                return htmlText(from: data)
            }

            if let text = String(data: data, encoding: .utf8) {
                return cleaned(text)
            }

            return htmlText(from: data)
        } catch {
            return nil
        }
    }

    private static func fileText(at path: String) -> String? {
        // A file, or a chapter of an EPUB book kept as one file.
        guard let data = EPUBBookFiles.contents(atPath: path), !data.isEmpty else { return nil }

        let lowercasedPath = path.lowercased()
        if lowercasedPath.hasSuffix(".htm") || lowercasedPath.hasSuffix(".html") || lowercasedPath.hasSuffix(".xhtml") {
            return htmlText(from: data)
        }

        if let text = String(data: data, encoding: .utf8) {
            return cleaned(text)
        }

        return nil
    }

    /// The text of `pages` of the PDF at `path`, or of every page: a book
    /// chapter is its pages of the book's file.
    private static func pdfText(at path: String, pages: Range<Int>?) -> String? {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else { return nil }
        let range = pages ?? 0..<document.pageCount
        guard range.upperBound <= document.pageCount else { return nil }

        var parts: [String] = []
        for index in range {
            if let pageText = document.page(at: index)?.string,
               let cleanedText = cleaned(pageText),
               !cleanedText.isEmpty {
                parts.append(cleanedText)
            }
        }

        // Form feed is an unambiguous page boundary. The narration cleaner uses
        // it to recognize repeated page furniture and page-bottom note blocks;
        // ordinary paragraph breaks remain plain newlines.
        return cleaned(parts.joined(separator: "\n\u{000C}\n"))
    }

    private static func htmlText(from data: Data) -> String? {
        // EPUBParser.stripHTML is plain-Swift regex stripping, safe on any
        // thread. NSAttributedString's HTML importer is WebKit-backed and
        // documented main-thread-only, so it must not run on this (background)
        // extraction path.
        guard let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        return cleaned(EPUBParser.stripHTML(html))
    }

    private static func cleaned(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func isWebURL(_ url: String) -> Bool {
        url.hasPrefix("http://") || url.hasPrefix("https://")
    }
}

extension StudioArticle {
    /// The automatic-audio switch this source falls under: its source type,
    /// or `explainer` for an explainer, which is an article-typed row with a
    /// switch of its own (`SourceAudioAutomation.kind(forSourceType:url:)`).
    var audioAutomationKind: String {
        SourceAudioAutomation.kind(forSourceType: sourceType.rawValue, url: url)
    }
}

/// Event-driven, generate-only text-to-speech preparation. It never starts the
/// player or records listening activity; it only lands the same synced audio
/// manifest that an explicit Listen action would create.
@MainActor
final class AutomaticSourceAudioGenerationService: ObservableObject {
    static let shared = AutomaticSourceAudioGenerationService()

    @Published private(set) var currentTitle: String?
    @Published private(set) var currentSourceType: String?
    @Published private(set) var queuedCount = 0
    @Published private(set) var progress: SourceAudioAutomation.GenerationProgress?
    @Published private(set) var lastError: String?
    /// Per source type, what switching that type on would generate right now.
    /// Kept for every automatable type regardless of its switch, because
    /// Settings has to quote the spend *before* the switch moves.
    @Published private(set) var backlogs: [String: SourceAudioAutomation.Backlog] = [:]

    private var queued: [String: StudioArticle] = [:]
    private var queuedSourceIDsByDate: [String] = []
    private var completedSourceIDs: Set<String> = []
    private var failedSourceIDs: Set<String> = []
    private var currentSourceID: String?
    private var batchSourceIDs: Set<String> = []
    private var completedBatchSourceIDs: Set<String> = []
    private var schedulePreparationTask: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    /// The source being generated. Its work runs detached, off the main
    /// actor, so cancelling `worker` does not reach it: Stop cancels it here.
    private var generation: Task<Void, Error>?
    private let storage = StorageService()
    private var librarySources: [StudioArticle] = []

    func schedule(_ sources: [StudioArticle], retryFailures: Bool = false) {
        librarySources = sources
        // The price this gate reads is the model's on OpenRouter's speech
        // list. A Mac that has never read the list reads it now, in the
        // background; the next source event or activation schedules again.
        if !ArticleSpeechCatalog.isDirectoryBacked {
            OpenRouterAudioDirectory.warm(.speech)
        }
        guard Self.automaticSelectionIsAllowed else {
            discardPendingWork()
            return
        }
        // Stopped under Running in the background: nothing starts until the
        // learner resumes it there (`AIInFlightCalls`).
        guard !Self.isStoppedByLearner else {
            discardPendingWork(disableOptIns: false)
            return
        }
        if retryFailures {
            failedSourceIDs.removeAll()
            lastError = nil
        }

        let completedSnapshot = completedSourceIDs
        let failedSnapshot = failedSourceIDs
        let currentSnapshot = currentSourceID
        // A source whose audio an explicit action is already producing — the
        // sidebar's Generate Audio, the MCP queue, or an explainer whose switch
        // let its writer start the narration — is not a candidate: the marker
        // it will leave is minutes away, and generating it here too would bill
        // the same narration twice.
        let generatingSnapshot = ArticleSpeechService.shared.backgroundGenerationSourceIDs
            .union(SourceAudioGenerationQueue.shared.activeSourceIDs)
        let storage = storage
        schedulePreparationTask?.cancel()
        schedulePreparationTask = Task { [weak self] in
            let pass = await Task.detached(priority: .utility) {
                let automatable = sources.filter(Self.isAutomatable)
                let candidates = automatable
                    .filter {
                        SourceAudioAutomation.isEnabled(for: $0.audioAutomationKind)
                            && !ArticleSpeechAudioCache.hasCachedMarker(sourceID: $0.id)
                            && !completedSnapshot.contains($0.id)
                            && !failedSnapshot.contains($0.id)
                            && !generatingSnapshot.contains($0.id)
                            && currentSnapshot != $0.id
                    }
                    // Descending lets the worker take the oldest source with
                    // O(1) `popLast()` instead of sorting the whole queue for
                    // every generated item.
                    .sorted { $0.dateAdded > $1.dateAdded }
                let pending = Self.pendingBacklogSources(automatable)
                async let pendingSummaries = storage.sourceListenableContentSummaries(
                    for: pending.map(\.id)
                )
                async let pendingSignature = PaperTextToSpeechPreparationService
                    .currentPreparationSignature()
                let summaries = await pendingSummaries
                let preparationSignature = await pendingSignature
                return SchedulePass(
                    candidates: candidates,
                    backlogs: Self.backlogs(
                        pending: pending,
                        listenableSummaries: summaries,
                        currentPreparationSignature: preparationSignature
                    ),
                    // Every candidate is also pending, so this sweep already
                    // sized them. Carry the lengths out rather than making the
                    // constraint filter read them back from SQLite.
                    candidateCharacterCounts: candidates.reduce(into: [:]) { counts, source in
                        guard let count = Self.narrationCharacterCount(
                            for: source,
                            listenableSummaries: summaries,
                            preparationSignature: preparationSignature
                        ) else { return }
                        counts[source.id] = count
                    }
                )
            }.value
            guard let self, !Task.isCancelled else { return }
            let candidates: [StudioArticle]
            do {
                candidates = try await Self.filteredBySavedConstraints(
                    pass.candidates,
                    characterCounts: pass.candidateCharacterCounts
                )
            } catch {
                self.lastError = "Automatic audio filter failed: \(error.localizedDescription)"
                self.discardPendingWork(disableOptIns: false)
                self.schedulePreparationTask = nil
                return
            }
            self.backlogs = pass.backlogs
            self.queued = Dictionary(
                candidates.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            if let currentSourceID = self.currentSourceID {
                self.queued[currentSourceID] = nil
            }
            self.queuedSourceIDsByDate = candidates
                .map(\.id)
                .filter { self.queued[$0] != nil }
            self.queuedCount = self.queued.count
            let candidateIDs = Set(candidates.map(\.id))
            if self.worker == nil, self.currentSourceID == nil {
                self.batchSourceIDs = candidateIDs
                self.completedBatchSourceIDs.removeAll()
            } else {
                self.batchSourceIDs.formUnion(candidateIDs)
            }
            self.publishProgress()
            self.schedulePreparationTask = nil
            self.startWorkerIfNeeded()
        }
    }

    func previewConstraint(
        sourceType: String,
        constraint: String
    ) async throws -> SourceAudioAutomation.FilterPreview {
        let normalized = constraint.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = librarySources
        let storage = storage
        return try await Task.detached(priority: .userInitiated) {
            let pending = snapshot.filter {
                $0.audioAutomationKind == sourceType
                    && Self.isAutomatable($0)
                    && !ArticleSpeechAudioCache.hasCachedMarker(sourceID: $0.id)
            }
            let summaries = await storage.sourceListenableContentSummaries(for: pending.map(\.id))
            let signature = await PaperTextToSpeechPreparationService.currentPreparationSignature()
            let candidates = pending.map { source in
                Self.filterCandidate(
                    source,
                    characterCount: Self.narrationCharacterCount(
                        for: source,
                        listenableSummaries: summaries,
                        preparationSignature: signature
                    )
                )
            }
            let matchingIDs: Set<String>
            if normalized.isEmpty {
                matchingIDs = Set(candidates.map(\.id))
            } else {
                guard let config = KeychainService.resolveConfig(for: .automaticAudioFiltering) else {
                    throw AIError.missingAPIKey
                }
                matchingIDs = try await AIService().matchingAutomaticAudioSourceIDs(
                    constraint: normalized,
                    candidates: candidates,
                    config: config
                )
            }
            return SourceAudioAutomation.FilterPreview(
                constraint: normalized,
                matches: candidates
                    .filter { matchingIDs.contains($0.id) }
                    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            )
        }.value
    }

    /// One detached pass over the library: what to generate now, and what each
    /// type would generate if its switch moved. Computed together so the sweep
    /// over the source list and its file stats happens once.
    private struct SchedulePass {
        let candidates: [StudioArticle]
        let backlogs: [String: SourceAudioAutomation.Backlog]
        /// Narration length per candidate, for the saved-constraint filter.
        /// Absent for a source whose listen-ready derivative is missing or
        /// stale — the same sources the backlog estimate declines to quote.
        let candidateCharacterCounts: [String: Int]
    }

    /// A source automation could narrate, whether or not its kind is switched
    /// on. The switch is checked separately so the backlog estimate survives it.
    /// Membership comes from `SourceAudioAutomation`, so a kind added there is
    /// generated here without a second list to keep in step.
    private nonisolated static func isAutomatable(_ source: StudioArticle) -> Bool {
        guard SourceAudioAutomation.preferenceKey(for: source.audioAutomationKind) != nil,
              source.state == .ready,
              ArticleSpeechContent.canAttemptRead(source) else { return false }
        return true
    }

    /// Sources with no local audio marker. Kept separate from sizing so the
    /// SQLite listen-ready length lookup receives one bounded ID list.
    private nonisolated static func pendingBacklogSources(
        _ automatable: [StudioArticle]
    ) -> [StudioArticle] {
        automatable.filter { !ArticleSpeechAudioCache.hasCachedMarker(sourceID: $0.id) }
    }

    /// Sources of each automatable type that have no audio yet, sized from the
    /// exact durable listen-ready derivative that generation will send to TTS.
    /// Articles and papers with a missing or stale derivative remain counted,
    /// but receive no quote until preparation finishes; canonical text and
    /// historical spend are never substituted.
    private nonisolated static func backlogs(
        pending sources: [StudioArticle],
        listenableSummaries: [String: SourceListenableContentSummary],
        currentPreparationSignature: String?
    ) -> [String: SourceAudioAutomation.Backlog] {
        var backlogs: [String: SourceAudioAutomation.Backlog] = [:]
        var sizedSourceCounts: [String: Int] = [:]
        for sourceType in SourceAudioAutomation.automatableSourceTypes {
            backlogs[sourceType] = SourceAudioAutomation.Backlog()
            sizedSourceCounts[sourceType] = 0
        }
        for source in sources {
            // Keyed by automation kind: an explainer counts under Explainers,
            // never under Articles. The preparation policy below still takes
            // the row's real source type.
            let sourceType = source.audioAutomationKind
            guard backlogs[sourceType] != nil else { continue }
            backlogs[sourceType]?.sourceCount += 1

            let usesAIPreparation = TextToSpeechPreparationPolicy.usesAIPreparation(
                sourceType: source.sourceType.rawValue,
                url: source.url
            )
            let characters: Int?
            if let summary = listenableSummaries[source.id],
               !usesAIPreparation
                || (currentPreparationSignature != nil
                    && summary.preparationSignature == currentPreparationSignature) {
                characters = summary.characterCount
            } else if !usesAIPreparation, let content = source.content {
                characters = MacArticleSpeechText.narrationText(from: content).count
            } else {
                characters = nil
            }
            guard let characters, characters > 0 else { continue }
            // Read through a local first: reading and writing the same subscript
            // in one expression is an exclusivity violation, not just a style nit.
            let accumulated = backlogs[sourceType]?.characterCount ?? 0
            backlogs[sourceType]?.characterCount = accumulated + characters
            sizedSourceCounts[sourceType, default: 0] += 1
        }
        for sourceType in SourceAudioAutomation.automatableSourceTypes {
            if sizedSourceCounts[sourceType] != backlogs[sourceType]?.sourceCount {
                backlogs[sourceType]?.characterCount = nil
            }
        }
        return backlogs
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !queued.isEmpty else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                // Re-check between every source. A model can change while a
                // long free request is running; the next item must not inherit
                // a newly selected paid route.
                guard Self.automaticSelectionIsAllowed else {
                    self.discardPendingWork()
                    break
                }
                // A stop made on another Mac arrives between sources.
                guard !Self.isStoppedByLearner else {
                    self.discardPendingWork(disableOptIns: false)
                    break
                }
                guard let source = self.nextSource() else { break }
                self.currentTitle = source.title
                self.currentSourceType = source.audioAutomationKind
                self.currentSourceID = source.id
                self.publishProgress()
                do {
                    let storage = self.storage
                    let generation = Task.detached(priority: .utility) {
                        try await Self.generate(source, storage: storage)
                    }
                    self.generation = generation
                    defer { self.generation = nil }
                    try await generation.value
                    self.completedSourceIDs.insert(source.id)
                    self.completedBatchSourceIDs.insert(source.id)
                } catch where AITransientErrorClassifier.isCancellation(error) {
                    // Stopped: the source was never given its chance, so it
                    // is not counted as failed, and it is let go of here so
                    // the next schedule offers it again.
                    self.currentTitle = nil
                    self.currentSourceType = nil
                    self.currentSourceID = nil
                    break
                } catch {
                    self.failedSourceIDs.insert(source.id)
                    self.lastError = "Automatic audio for \(source.title) failed: \(error.localizedDescription)"
                    ArticleSpeechDiagnostics.append(
                        "AUTOMATIC_GENERATION_FAILED source=\(source.id) \(error.localizedDescription)"
                    )
                }
                self.currentTitle = nil
                self.currentSourceType = nil
                self.currentSourceID = nil
                self.publishProgress()
            }
            self.queuedCount = self.queued.count
            self.worker = nil
            self.progress = nil
            self.batchSourceIDs.removeAll()
            self.completedBatchSourceIDs.removeAll()
        }
    }

    /// User-facing abort for the batch in flight. Deliberately leaves the
    /// per-type opt-ins and the paid consent alone: this stops what is running
    /// now, and the copy shown afterwards says the switches are still on.
    @discardableResult
    func stopCurrentRun() -> Int {
        let generated = completedBatchSourceIDs.count
        generation?.cancel()
        worker?.cancel()
        worker = nil
        discardPendingWork(disableOptIns: false)
        lastError = nil
        return generated
    }

    /// Stop under Running in the background: the source being generated is
    /// cancelled mid-request, and no automatic audio starts again, on any Mac
    /// of the account, until the learner resumes it there. The switches stay
    /// as they are.
    func stopFromBackgroundWork() {
        AIInFlightCalls.shared.stop(step: AutomaticAudioStep.step)
        stopCurrentRun()
    }

    /// Resume under Running in the background: the library is looked at again
    /// at once rather than at the next source event.
    func resumeAfterStop() {
        AIInFlightCalls.shared.resume(step: AutomaticAudioStep.step)
        schedule(librarySources)
    }

    private nonisolated static var isStoppedByLearner: Bool {
        AIInFlightCalls.shared.isStopped(AutomaticAudioStep.step)
    }

    /// Per-type backlogs for the whole pending library, so the consent dialog
    /// can price what granting it would start. Sized by the same sweep the
    /// scheduler uses, so the quote matches what execution would enqueue —
    /// every pending source, not only the types already switched on.
    func libraryCostPreview(
        ratePerMillionCharacters rate: Double?
    ) async -> SourceAudioAutomation.LibraryCostPreview {
        let snapshot = librarySources
        let storage = storage
        let backlogs = await Task.detached(priority: .userInitiated) {
            let pending = Self.pendingBacklogSources(snapshot.filter(Self.isAutomatable))
            let summaries = await storage.sourceListenableContentSummaries(
                for: pending.map(\.id)
            )
            let signature = await PaperTextToSpeechPreparationService.currentPreparationSignature()
            return Self.backlogs(
                pending: pending,
                listenableSummaries: summaries,
                currentPreparationSignature: signature
            )
        }.value
        return SourceAudioAutomation.LibraryCostPreview(
            backlogs: backlogs,
            ratePerMillionCharacters: rate
        )
    }

    private func discardPendingWork(disableOptIns: Bool = true) {
        schedulePreparationTask?.cancel()
        schedulePreparationTask = nil
        queued.removeAll()
        queuedSourceIDsByDate.removeAll()
        queuedCount = 0
        batchSourceIDs.removeAll()
        completedBatchSourceIDs.removeAll()
        progress = nil
        // Execution is the final authority, including when a model changes via
        // sync while Settings is closed. Retire the synced opt-ins here so a
        // later switch back to a free model cannot silently resurrect them.
        if disableOptIns {
            for sourceType in SourceAudioAutomation.automatableSourceTypes
            where MacArticleSpeechSettings.automaticallyGenerates(sourceType) {
                MacArticleSpeechSettings.setAutomaticallyGenerates(false, sourceType: sourceType)
            }
        }
    }

    /// Whether the current selection may generate at all: free always, priced
    /// only behind account consent, unpriced never. Execution stays the final
    /// authority, so this is re-read between every source. One rule, shared
    /// with the Explain action and the MCP tools that start an explainer's
    /// audio on the strength of its switch.
    private nonisolated static var automaticSelectionIsAllowed: Bool {
        MacArticleSpeechSettings.automaticSelectionIsAllowed()
    }

    private nonisolated static func filteredBySavedConstraints(
        _ sources: [StudioArticle],
        characterCounts: [String: Int]
    ) async throws -> [StudioArticle] {
        let constrainedTypes = Dictionary(uniqueKeysWithValues:
            SourceAudioAutomation.automatableSourceTypes.compactMap { sourceType in
                SourceAudioAutomation.constraint(for: sourceType).map { (sourceType, $0) }
            }
        )
        guard !constrainedTypes.isEmpty else { return sources }
        guard let config = KeychainService.resolveConfig(for: .automaticAudioFiltering) else {
            throw AIError.missingAPIKey
        }

        var allowedIDs = Set(sources.filter {
            constrainedTypes[$0.audioAutomationKind] == nil
        }.map(\.id))
        let ai = AIService()
        for (sourceType, constraint) in constrainedTypes.sorted(by: { $0.key < $1.key }) {
            let typed = sources.filter { $0.audioAutomationKind == sourceType }
            let candidates = typed.map {
                Self.filterCandidate($0, characterCount: characterCounts[$0.id])
            }
            let matches = try await ai.matchingAutomaticAudioSourceIDs(
                constraint: constraint,
                candidates: candidates,
                config: config
            )
            allowedIDs.formUnion(matches)
        }
        return sources.filter { allowedIDs.contains($0.id) }
    }

    /// Characters generation would actually send to TTS: the durable
    /// listen-ready derivative, canonical text for the types that need no AI
    /// preparation, and `nil` when an AI-prepared derivative is missing or
    /// stale. One rule, so the length a saved constraint is judged against in
    /// the Settings preview is the length it is judged against at execution.
    private nonisolated static func narrationCharacterCount(
        for source: StudioArticle,
        listenableSummaries: [String: SourceListenableContentSummary],
        preparationSignature: String?
    ) -> Int? {
        let usesPreparation = TextToSpeechPreparationPolicy.usesAIPreparation(
            sourceType: source.sourceType.rawValue,
            url: source.url
        )
        if let summary = listenableSummaries[source.id],
           !usesPreparation || summary.preparationSignature == preparationSignature {
            return summary.characterCount
        }
        if !usesPreparation, let content = source.content {
            return MacArticleSpeechText.narrationText(from: content).count
        }
        return nil
    }

    private nonisolated static func filterCandidate(
        _ source: StudioArticle,
        characterCount: Int? = nil
    ) -> SourceAudioAutomation.FilterCandidate {
        let excerpt = source.content?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(800)
        return SourceAudioAutomation.FilterCandidate(
            id: source.id,
            // The kind, so a rule on Explainers is judged over explainers and
            // the preview names them as such.
            sourceType: source.audioAutomationKind,
            title: source.title,
            author: source.author,
            journal: source.journal,
            year: source.publishedYear,
            collection: source.parentGroup,
            url: source.url,
            description: excerpt.map(String.init),
            characterCount: characterCount
        )
    }

    private func publishProgress() {
        let isActive = currentSourceID != nil || !queued.isEmpty
        guard isActive, !batchSourceIDs.isEmpty else {
            progress = nil
            return
        }
        progress = SourceAudioAutomation.GenerationProgress(
            completedCount: completedBatchSourceIDs.count,
            totalCount: batchSourceIDs.count,
            currentSourceType: currentSourceType,
            currentTitle: currentTitle
        )
    }

    private func nextSource() -> StudioArticle? {
        while let sourceID = queuedSourceIDsByDate.popLast() {
            if let source = queued.removeValue(forKey: sourceID) {
                queuedCount = queued.count
                return source
            }
        }
        queued.removeAll()
        queuedCount = 0
        return nil
    }

    private nonisolated static func generate(_ source: StudioArticle, storage: StorageService) async throws {
        // The queue is rebuilt from source events and on app activation. Its
        // in-memory completed set is only a same-process optimization; this
        // durable check prevents already-generated sources from being billed
        // again after relaunch or after audio arrives from another device.
        guard !ArticleSpeechAudioCache.hasCachedAudio(sourceID: source.id) else { return }
        // An explicit action may have started this source since the pass that
        // queued it — an explainer's writer does exactly that when its switch
        // is on. Let that run finish rather than narrating it twice.
        let startedElsewhere = await MainActor.run {
            ArticleSpeechService.shared.backgroundGenerationSourceIDs.contains(source.id)
                || SourceAudioGenerationQueue.shared.activeSourceIDs.contains(source.id)
        }
        guard !startedElsewhere else { return }
        guard ManagedAI.isSignedIn else {
            throw CloudArticleTTS.GenerationError.missingAPIKey
        }
        guard MacArticleSpeechSettings.provider == .openRouter else {
            throw CloudArticleTTS.GenerationError.invalidSelection(
                "Choose OpenRouter in Text to Speech settings."
            )
        }
        // The price automation is judged by is the model's on OpenRouter's
        // speech list, which this Mac may not have read yet.
        await OpenRouterAudioDirectory.prepare(.speech)
        // A pick the list dropped is repaired before it is priced or sent,
        // and the next Listen says so; this pass has no one to tell.
        MacArticleSpeechSettings.repairAfterDirectoryRead()
        let model = MacArticleSpeechSettings.openRouterModel
        guard SourceAudioAutomation.allowsAutomaticGeneration(
            provider: ArticleSpeechCatalog.provider,
            model: model,
            allowsPaidVoices: MacArticleSpeechSettings.allowsPaidAutomaticVoices
        ) else {
            throw CloudArticleTTS.GenerationError.invalidSelection(
                "Automatic audio requires a free voice, or paid voices allowed from chat."
            )
        }
        guard let canonicalText = await ArticleSpeechContent.text(for: source) else {
            throw CloudArticleTTS.GenerationError.emptyText
        }

        let usageSource = AIUsageSource(source: source)
        let narration = try await preparedNarration(
            source: source,
            canonicalText: canonicalText,
            storage: storage
        )
        let voice = ArticleSpeechCatalog.resolvedVoiceID(
            MacArticleSpeechSettings.openRouterVoice,
            forModel: model
        )

        let subtitle = await Self.manifestSubtitle(for: source, storage: storage)
        _ = try await AIUsageAttribution.withSource(usageSource) {
            try await CloudArticleTTS.generate(
                sourceID: source.id,
                title: source.title,
                subtitle: subtitle,
                sourceType: source.sourceType.rawValue,
                sourceURL: source.url,
                text: narration.text,
                sourceContentSignature: narration.sourceContentSignature,
                narrationPreparationSignature: narration.preparationSignature,
                createdAt: Date(),
                selection: CloudArticleTTS.Selection(model: model, voice: voice),
                generatedOnPlatform: "macos"
            )
        }
        ArticleSpeechAudioCache.markCached(articleID: source.id)
    }

    /// Same rule as `ArticleSpeechService.displaySubtitle`: a chapter names its
    /// book by title, never by the group id, which for an imported book is a
    /// UUID. Off-main, so the title comes from storage rather than Studio.
    private nonisolated static func manifestSubtitle(
        for source: StudioArticle,
        storage: StorageService
    ) async -> String? {
        if source.sourceType == .book, let groupID = source.parentGroup, groupID != source.id {
            return await storage.bookTitle(forGroupID: groupID) ?? source.displayAuthor
        }
        return source.parentGroup ?? source.displayAuthor
    }

    private nonisolated static func preparedNarration(
        source: StudioArticle,
        canonicalText: String,
        storage: StorageService
    ) async throws -> PreparedPaperNarration {
        let normalized = canonicalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceHash = PaperContentPreparationService.sha256(normalized)
        if !TextToSpeechPreparationPolicy.usesAIPreparation(
            sourceType: source.sourceType.rawValue,
            url: source.url
        ) {
            return PreparedPaperNarration(
                text: normalized,
                sourceContentSignature: sourceHash,
                preparationSignature: "automatic-free-passthrough-v1"
            )
        }
        let currentSignature = await PaperTextToSpeechPreparationService.currentPreparationSignature()
        if let stored = await ArticleSpeechContent.listenableContent(sourceID: source.id),
           stored.metadata.sourceSHA256 == sourceHash,
           let currentSignature,
           stored.metadata.preparationSignature == currentSignature {
            return PreparedPaperNarration(
                text: stored.text,
                sourceContentSignature: sourceHash,
                preparationSignature: currentSignature
            )
        }
        // Automatic audio must never smuggle a paid text-model call behind a
        // free speech model. Explicit Listen may prepare narration after its
        // own confirmation; the background worker waits for that durable
        // derivative instead of creating it with managed AI. Only the kinds
        // automatic audio covers are queued as their text arrives, so a
        // source already in the library when its switch went on is queued
        // here, and a later pass (app activation retries) finds it prepared.
        try? await storage.queueSourceListenableContentPreparation(sourceID: source.id)
        throw CloudArticleTTS.GenerationError.invalidSelection(
            "Automatic audio is waiting for prepared narration."
        )
    }
}

/// Appends text-to-speech failures to Application Support/ForeverLM/Diagnostics/
/// speech-log.txt. The unified log needs admin rights to read on managed
/// Macs and evaporates when the app runs under the debugger, so TTS errors
/// mirror to this file — it is the first place to look when generation
/// misbehaves.
enum ArticleSpeechDiagnostics {
    private static let maxLogBytes = 2_000_000

    static func append(_ line: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(timestamp) \(line)\n"
        Task.detached(priority: .utility) {
            do {
                let base = ForeverLMRuntimeIdentity.diagnosticsRootURL
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                let url = base.appendingPathComponent("speech-log.txt")
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   size > maxLogBytes {
                    let rotated = base.appendingPathComponent("speech-log.previous.txt")
                    try? FileManager.default.removeItem(at: rotated)
                    try? FileManager.default.moveItem(at: url, to: rotated)
                }
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(entry.utf8))
                } else {
                    try Data(entry.utf8).write(to: url)
                }
            } catch {
                articleSpeechLogger.error(
                    "Could not write speech diagnostics: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
#endif
