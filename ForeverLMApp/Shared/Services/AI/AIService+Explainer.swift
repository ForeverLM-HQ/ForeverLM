import Foundation

extension AIService {

    /// Write the spoken explainer of one source from its text and, for a
    /// paper whose figures were read, its figure lines.
    func writeExplainer(
        source: StudioArticle,
        text: String,
        truncated: Bool,
        figureLines: [String] = [],
        request: ExplainerRequest,
        config: AITaskConfig
    ) async throws -> ExplainerDraft {
        let system = AITask.explainerWriting.effectivePrompt ?? Prompts.explainerWriter
        let user = Self.explainerUserMessage(
            source: source,
            text: text,
            truncated: truncated,
            length: request.length,
            figureLines: figureLines
        )
        let response = try await call(
            config: config,
            system: system,
            user: user,
            maxTokens: 6_000,
            temperature: 0.6,
            jsonMode: true,
            sourceTitle: source.title,
            subjectID: source.id,
            subjectType: source.sourceType.rawValue
        )
        let draft: ExplainerDraft
        do {
            draft = try MemoryReviewPlanning.decodeJSON(response)
        } catch {
            throw AIError.invalidResponse
        }
        guard draft.isUsable else {
            throw ExplainerGenerationError.emptyScript
        }
        return draft
    }

    /// The writer's turn: what the source is, how long to speak, the figures
    /// it prints, and its text.
    static func explainerUserMessage(
        source: StudioArticle,
        text: String,
        truncated: Bool,
        length: ExplainerLength,
        figureLines: [String] = []
    ) -> String {
        // The one builder both apps use, so the phone's writer sees the same turn.
        ExplainerScript.writerUserMessage(
            title: source.title,
            sourceType: source.sourceType.rawValue,
            author: source.author,
            journal: source.journal,
            publishedYear: source.publishedYear,
            text: text,
            truncated: truncated,
            length: length,
            figureLines: figureLines
        )
    }
}
