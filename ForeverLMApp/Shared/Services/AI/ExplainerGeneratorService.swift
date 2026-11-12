import Foundation

/// Writes the explainer with the learner's Explainer Writing model.
struct LiveExplainerModelBackend: ExplainerModelBackend {
    let aiService: AIService

    func write(
        request: ExplainerRequest,
        source: StudioArticle,
        text: String,
        truncated: Bool,
        figureLines: [String]
    ) async throws -> ExplainerDraft {
        guard let config = KeychainService.resolveConfig(for: .explainerWriting) else {
            throw ExplainerGenerationError.noModelConfigured
        }
        return try await aiService.writeExplainer(
            source: source,
            text: text,
            truncated: truncated,
            figureLines: figureLines,
            request: request,
            config: config
        )
    }
}

/// The explainer pipeline: read the source's text and, for a paper, its
/// figures, have the writer turn them into a spoken script, and save the
/// script as a text-only source beside the original. Audio is not this
/// service's job — the caller hands the saved source to the same text-to-speech
/// path every other source uses, so the cost question is asked exactly once,
/// by the code that already asks it.
///
/// Runs off the main actor. Usage for the run — the writing call and any
/// figure a vision pass looks at for the first time — is attributed to one
/// activity id, so Settings → AI activity shows the explainer as one line.
struct ExplainerGeneratorService: Sendable {
    let storage: StorageService
    let backend: any ExplainerModelBackend
    /// The paper figure index the writer's figure lines are read from. Nil
    /// where no index exists (tests without a PDF), and the script is written
    /// from the text alone, as an article's always is.
    let figureIndexer: PaperFigureIndexer?

    /// Characters of source text one writing call may carry. A long paper is
    /// cut, not refused, and the writer is told where the text ends. The
    /// number is `ExplainerScript`'s, so the phone cuts at the same place.
    static let sourceCharacterBudget = ExplainerScript.sourceCharacterBudget

    init(storage: StorageService, backend: any ExplainerModelBackend, figureIndexer: PaperFigureIndexer? = nil) {
        self.storage = storage
        self.backend = backend
        self.figureIndexer = figureIndexer
    }

    func run(request: ExplainerRequest) async throws -> ExplainerGenerationResult {
        try await AIUsageAttribution.withWorkflow {
            try await runStages(request: request)
        }
    }

    private func runStages(request: ExplainerRequest) async throws -> ExplainerGenerationResult {
        let sourceID = request.sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let source = try await storage.loadSourceWithoutContent(sourceID) else {
            throw ExplainerGenerationError.sourceNotFound(sourceID)
        }
        guard GeneratedExplainer.explainableSourceTypes.contains(source.sourceType),
              !GeneratedExplainer.isSpokenScriptURL(source.url) else {
            throw ExplainerGenerationError.unsupportedSource(source.title)
        }
        guard let text = await storage.loadSourceContent(source.id)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw ExplainerGenerationError.noText(source.title)
        }

        let budgeted = Self.budgeted(text)
        let figureLines = await Self.figureLines(for: source, indexer: figureIndexer, storage: storage)
        try Task.checkCancellation()
        let draft = try await backend.write(
            request: request,
            source: source,
            text: budgeted.text,
            truncated: budgeted.truncated,
            figureLines: figureLines
        )
        // A cancelled run that the provider still answered must not land a
        // source the learner has already given up on.
        try Task.checkCancellation()
        guard draft.isUsable else {
            throw ExplainerGenerationError.emptyScript
        }

        let existing = try await storage.loadSourceWithoutContent(GeneratedExplainer.sourceID(explaining: source.id))
        var explainer = Self.explainerSource(for: source, draft: draft)
        if let existing {
            // A rewrite keeps the row's place in the library; only its text moves.
            explainer.dateAdded = existing.dateAdded
        }
        try await storage.saveSource(explainer)
        return ExplainerGenerationResult(explainer: explainer, replacedExisting: existing != nil)
    }

    /// The text the writer sees: whole when it fits, else the opening budget
    /// with a flag so the prompt can say the end is missing.
    static func budgeted(_ text: String) -> (text: String, truncated: Bool) {
        ExplainerScript.budgeted(text)
    }

    /// The paper's figures as the writer hears about them, one line each
    /// (`PaperWalkthroughGeneratorService.figureLines`), read from the same
    /// index the walkthrough writer and the picture tools use. The printed
    /// captions and the words inside each figure cost nothing; a figure not
    /// yet looked at is analysed once by the vision pass (`PaperFigureIndexer.prepare`),
    /// and the analysis is kept by figure id, so a paper that already has a
    /// walkthrough costs nothing more here. The product owner (2026-09-20), on an
    /// explainer written from the text alone: it "doesn't go through the
    /// figures" — the writer had never been shown them. An article has no PDF
    /// and no figures; a paper whose PDF cannot be read right now is explained
    /// from its text, as before.
    static func figureLines(
        for source: StudioArticle,
        indexer: PaperFigureIndexer?,
        storage: StorageService
    ) async -> [String] {
        guard source.sourceType == .paper, let indexer else { return [] }
        let records = (try? await indexer.prepare(sourceID: source.id)) ?? []
        guard !records.isEmpty else { return [] }
        let pdfPath = try? await storage.paperFigureIndexTarget(sourceID: source.id)?.pdfPath
        let references = PaperWalkthroughGeneratorService.figureReferences(from: records, pdfPath: pdfPath)
        return PaperWalkthroughGeneratorService.figureLines(references)
    }

    /// The explainer as an article-typed source with its script attached,
    /// ready to listen to, search, review and sync. Article, not paper: a
    /// paper must have a PDF and this has none; and the listen path reads an
    /// article's own text, which is exactly what a script written for the ear
    /// wants (`TextToSpeechPreparationPolicy.spokenScriptURLPrefix` keeps the
    /// preparation pass off it).
    static func explainerSource(for source: StudioArticle, draft: ExplainerDraft) -> StudioArticle {
        var article = StudioArticle(
            url: GeneratedExplainer.url(explaining: source.id),
            title: GeneratedExplainer.title(for: source.title),
            sourceType: .article,
            discoveryOrigin: .manual,
            author: source.author,
            journal: source.journal,
            publishedYear: source.publishedYear
        )
        let script = draft.script.trimmingCharacters(in: .whitespacesAndNewlines)
        article.domain = GeneratedExplainer.domain
        article.content = script
        article.wordCount = ExplainerScript.wordCount(of: script)
        article.state = .ready
        return article
    }
}
