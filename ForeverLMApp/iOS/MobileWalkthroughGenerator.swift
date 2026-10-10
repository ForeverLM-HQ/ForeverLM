import Foundation
import PDFKit

enum MobileWalkthroughError: LocalizedError {
    case notSignedIn
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to ForeverLM to write a walkthrough."
        case .badResponse(let message):
            return message
        }
    }
}

/// The phone's Walk Through writer: the same run the Mac's does
/// (`PaperWalkthroughWriting.run`) — the writer, a second pass for panels the
/// first left out, the checks, then up to four animations — with the
/// account's Walkthrough Writing and Walkthrough Animation models, saved into
/// the source's payload so every device reads the one record.
///
/// What the phone reads it from differs from the Mac only in where the
/// figures come from: the rows synced with the source (`paperFigures`) in
/// place of the Mac's figure index, with each figure's panel letters and
/// printed words read off the synced PDF's text layer
/// (`PaperFigurePanelLocator.textLayer(for:in:)`) exactly as the Mac reads
/// them. A paper the Mac never indexed has no rows, and its walk is written
/// without figure steps, which the result says.
@MainActor
final class MobileWalkthroughGenerator: ObservableObject {
    static let shared = MobileWalkthroughGenerator()

    /// Where each run is, by source id.
    @Published private(set) var stages: [String: PaperWalkthroughGenerationStage] = [:]
    /// The deck each run has saved so far, by source id: the steps as soon
    /// as they are saved, then again as each animation lands. The reader
    /// prefers it over the catalog's copy, which arrives with the next sync.
    @Published private(set) var decks: [String: MobileWalkthroughDeck] = [:]
    /// What the last run of a source could not do: an error that stopped it,
    /// or the steps and animations it had to leave out.
    @Published var notices: [String: String] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    func isWriting(_ sourceID: String) -> Bool {
        tasks[sourceID] != nil
    }

    /// Whether the phone can write a walkthrough of a source: a paper, a book
    /// chapter or an article (not an explainer's script) whose text has been
    /// read, as on the Mac (`PaperWalkthroughSubject`).
    nonisolated static func canWalkThrough(_ source: MobileCloudSource) -> Bool {
        subject(of: source) != nil && source.state == "ready" && !source.isPaywalled
    }

    nonisolated static func subject(of source: MobileCloudSource) -> PaperWalkthroughSubject? {
        switch source.sourceType {
        case "paper": return .paper
        case "book": return .chapter
        case "article": return ExplainerScript.isSpokenScriptURL(source.url ?? "") ? nil : .article
        default: return nil
        }
    }

    nonisolated static func summary(of source: MobileCloudSource) -> PaperWalkthroughSourceSummary {
        let subject = Self.subject(of: source)
        let allowsFigureAnchors: Bool = switch subject {
        case .paper: true
        case .chapter: source.isPDFBackedBookChapter
        case .article, .video, nil: false
        }
        return PaperWalkthroughSourceSummary(
            id: source.id,
            subject: subject,
            allowsFigureAnchors: allowsFigureAnchors,
            title: source.title,
            book: nil,
            domain: source.subtitle,
            author: source.author,
            journal: source.journal,
            publishedYear: source.publishedYear,
            sourceType: source.sourceType
        )
    }

    /// Writes (or writes again) the source's walkthrough. A source already
    /// being written is left alone.
    func write(_ source: MobileCloudSource, audio: MobileAudioReviewViewModel) {
        guard tasks[source.id] == nil else { return }
        notices[source.id] = nil
        stages[source.id] = .reading
        tasks[source.id] = Task { await self.run(source, audio: audio) }
    }

    /// Stops the run. Whatever was saved before stays — the steps are usable
    /// before a single animation is drawn.
    func cancel(_ sourceID: String) {
        tasks[sourceID]?.cancel()
    }

    private func run(_ source: MobileCloudSource, audio: MobileAudioReviewViewModel) async {
        defer {
            tasks[source.id] = nil
            stages[source.id] = nil
        }
        let sourceID = source.id
        do {
            let result = try await Self.writeWalkthrough(
                of: source,
                onStage: { stage in
                    Task { @MainActor in
                        guard MobileWalkthroughGenerator.shared.tasks[sourceID] != nil else { return }
                        MobileWalkthroughGenerator.shared.stages[sourceID] = stage
                    }
                },
                onStepsSaved: { walkthrough in
                    let deck = MobileWalkthroughPayloadParser.deck(from: walkthrough)
                    Task { @MainActor in
                        if let deck { MobileWalkthroughGenerator.shared.decks[sourceID] = deck }
                    }
                }
            )
            let left = result.warnings + result.animationFailures
            if !left.isEmpty { notices[sourceID] = left.joined(separator: "\n") }
            // The catalog is republished so every other surface sees the walk
            // from the synced payload too.
            _ = await audio.load(forceRefresh: true)
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            notices[sourceID] = error.localizedDescription
        }
    }

    /// The pipeline, off the main actor: the source's text and figures, the
    /// shared run, the payload save after the steps and after each animation.
    nonisolated static func writeWalkthrough(
        of source: MobileCloudSource,
        drawsAnimations: Bool = true,
        onStage: (@Sendable (PaperWalkthroughGenerationStage) -> Void)? = nil,
        onStepsSaved: (@Sendable (PaperWalkthrough) -> Void)? = nil
    ) async throws -> (walkthrough: PaperWalkthrough, warnings: [String], animationFailures: [String]) {
        guard canWalkThrough(source) else {
            throw PaperWalkthroughGenerationError.unsupportedSource(source.title)
        }
        let text = try await MobileCloudSourceTextStore.shared.loadSourceText(sourceID: source.id)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PaperWalkthroughGenerationError.noText(source.title) }
        guard ManagedAI.isSignedIn else { throw MobileWalkthroughError.notSignedIn }

        let summary = Self.summary(of: source)
        let figures = summary.allowsFigureAnchors ? await Self.figureReferences(of: source) : []

        let workflowID = UUID().uuidString
        return try await AIUsageAttribution.$sessionID.withValue(workflowID) {
            try await AIUsageAttribution.withSource(
                AIUsageSource(id: source.id, type: source.sourceType, title: source.title),
                activityID: workflowID
            ) {
                try await PaperWalkthroughWriting.run(
                    summary: summary,
                    text: text,
                    figures: figures,
                    drawsAnimations: drawsAnimations,
                    map: { text, truncated in
                        let reply = try await Self.complete(
                            task: .walkthroughWriting,
                            system: Prompts.walkthroughArgumentMapper,
                            user: PaperWalkthroughWriting.mapperUserMessage(
                                summary: summary,
                                text: text,
                                truncated: truncated,
                                figures: figures
                            ),
                            maxTokens: PaperWalkthroughWriting.mapperMaxTokens,
                            jsonMode: true
                        )
                        do {
                            return try MemoryReviewPlanning.decodeJSON(reply) as PaperWalkthroughArgumentMap
                        } catch {
                            throw MobileWalkthroughError.badResponse("The argument pass's reply was not the map it was asked for.")
                        }
                    },
                    write: { text, truncated, argument in
                        let reply = try await Self.complete(
                            task: .walkthroughWriting,
                            system: Prompts.walkthroughWriter,
                            user: PaperWalkthroughWriting.writerUserMessage(
                                summary: summary,
                                text: text,
                                truncated: truncated,
                                figures: figures,
                                argument: argument
                            ),
                            maxTokens: PaperWalkthroughWriting.writerMaxTokens,
                            jsonMode: true
                        )
                        let draft: PaperWalkthroughDraft
                        do {
                            draft = try MemoryReviewPlanning.decodeJSON(reply)
                        } catch {
                            throw MobileWalkthroughError.badResponse("The writer's reply was not the walkthrough it was asked for.")
                        }
                        guard !draft.steps.isEmpty else { throw PaperWalkthroughGenerationError.emptyDraft }
                        return draft
                    },
                    draw: { step, figure, excerpt in
                        let reply = try await Self.complete(
                            task: .walkthroughAnimation,
                            system: Prompts.walkthroughAnimator,
                            user: PaperWalkthroughWriting.animatorUserMessage(
                                summary: summary,
                                step: step,
                                figure: figure,
                                excerpt: excerpt
                            ),
                            maxTokens: PaperWalkthroughWriting.drawerMaxTokens,
                            jsonMode: false
                        )
                        guard let html = PaperWalkthroughWriting.htmlDocument(in: reply) else {
                            throw MobileWalkthroughError.badResponse("The drawer's reply held no HTML document.")
                        }
                        return html
                    },
                    save: { try await MobileCloudMutationService.shared.savePaperWalkthrough($0) },
                    onStage: onStage,
                    onStepsSaved: onStepsSaved
                )
            }
        }
    }

    /// The figures as the writer and the validator see them, from the rows
    /// synced with the source: one per label (a caption continued overleaf
    /// is a second row), its caption's words, its panels — the analysis's
    /// where the Mac analysed it, the text layer's otherwise — and the words
    /// it prints. A PDF this phone cannot fetch costs only the text layer.
    nonisolated static func figureReferences(of source: MobileCloudSource) async -> [PaperWalkthroughFigureReference] {
        let rows = source.paperFigures.filter { $0.pageIndex >= 0 }
        guard !rows.isEmpty else { return [] }
        let chosen = PaperWalkthroughWriting.firstPerLabel(rows, label: \.figureLabel, pageIndex: \.pageIndex)
        var readings: [String: PaperFigurePanelLocator.TextLayerReading] = [:]
        let relativePath = MobileSourceFilePath.relativePDFPath(localFilePath: source.localFilePath, url: source.url)
        if let url = try? await MobileSourceFileStore.shared.fetchPDF(sourceID: source.id, relativePath: relativePath) {
            let locations = chosen.map {
                PaperFigurePanelLocator.FigureLocation(
                    id: $0.id,
                    label: $0.figureLabel,
                    pageIndex: $0.pageIndex,
                    caption: $0.caption,
                    measuredRect: $0.analysis?.figureRect
                )
            }
            readings = await Task.detached(priority: .userInitiated) {
                guard let document = PDFDocument(url: url) else { return [:] }
                return PaperFigurePanelLocator.textLayer(for: locations, in: document)
            }.value
        }
        return chosen.map { figure in
            let analysed = figure.analysis?.panels.map(\.label) ?? []
            let textLayer = readings[figure.id]
            return PaperWalkthroughFigureReference(
                label: figure.figureLabel,
                pageNumber: figure.pageNumber,
                caption: PaperWalkthroughWriting.displayCaption(
                    for: figure,
                    in: rows,
                    label: \.figureLabel,
                    pageIndex: \.pageIndex,
                    caption: \.caption
                ),
                panelLabels: analysed.isEmpty ? (textLayer?.panelLabels ?? []) : analysed,
                reading: figure.analysis.flatMap(PaperWalkthroughWriting.figureReading),
                printedText: textLayer?.printedText ?? []
            )
        }
    }

    /// One call with the task's model, through the managed proxy, usage
    /// recorded against the run's activity. Errors are the provider's, said
    /// as the explainer says them; nothing is retried on another model.
    nonisolated static func complete(
        task: AITask,
        system: String,
        user: String,
        maxTokens: Int,
        jsonMode: Bool
    ) async throws -> String {
        let route = try await MobileModelPreferenceStore.shared.resolve(task)
        var request = try MobileOpenRouterChat.request(
            route: route,
            system: system,
            messages: [(role: "user", content: user)],
            maxTokens: maxTokens,
            jsonMode: jsonMode
        )
        // A whole paper in and a walk of up to forty steps out.
        request.timeoutInterval = 300
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MobileWalkthroughError.badResponse("\(route.provider) did not return an HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "No response body."
            // In Free mode the policy that refused is the learner's own
            // OpenRouter account, which has not allowed free endpoints yet.
            if let explanation = AIFreeMode.refusalExplanation(
                forProviderBody: body,
                providerMessage: AIProviderErrorText.fromResponseBody(data)
            ) {
                throw MobileWalkthroughError.badResponse(explanation)
            }
            if AIDataPolicy.isTrainingPolicyRefusal(body) {
                throw MobileWalkthroughError.badResponse(
                    AIDataPolicy.trainingRefusalExplanation(providerMessage: AIProviderErrorText.fromResponseBody(data))
                )
            }
            if route.deniesDataCollection, AIDataPolicy.isDataPolicyRefusal(body) {
                throw MobileWalkthroughError.badResponse(
                    AIDataPolicy.refusalExplanation(providerMessage: AIProviderErrorText.fromResponseBody(data))
                )
            }
            let what = task == .walkthroughAnimation ? "Drawing the animation" : "Writing the walkthrough"
            throw MobileWalkthroughError.badResponse(
                AIFreeMode.annotatingBusy("\(what) failed (\(http.statusCode)): \(body)", status: http.statusCode)
            )
        }
        let parsed = try MobileOpenRouterChat.text(from: data)
        try MobileOpenRouterChat.requireSelectedModel(parsed.json, route: route)
        return parsed.text
    }
}
