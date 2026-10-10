#if os(macOS)
import Foundation

extension AIService {

    /// The first pass: the source's argument as claims in teaching order, on
    /// the Walkthrough Writing model with the mapper's own (not overridable)
    /// prompt. Short and cheap; the writer is handed the result.
    func mapWalkthroughArgument(
        source: StudioArticle,
        text: String,
        truncated: Bool,
        figures: [PaperWalkthroughFigureReference],
        config: AITaskConfig
    ) async throws -> PaperWalkthroughArgumentMap {
        let user = PaperWalkthroughGeneratorService.mapperUserMessage(
            source: source,
            text: text,
            truncated: truncated,
            figures: figures
        )
        let response = try await call(
            config: config,
            system: Prompts.walkthroughArgumentMapper,
            user: user,
            maxTokens: PaperWalkthroughWriting.mapperMaxTokens,
            temperature: PaperWalkthroughWriting.writerTemperature,
            jsonMode: true,
            sourceTitle: source.title,
            subjectID: source.id,
            subjectType: source.sourceType.rawValue
        )
        do {
            return try MemoryReviewPlanning.decodeJSON(response)
        } catch {
            throw AIError.invalidResponse
        }
    }

    /// Write the steps of a paper's walkthrough from its text and figure
    /// index, in chapters that teach `argument`'s claims when the first pass
    /// set them out.
    func writeWalkthrough(
        source: StudioArticle,
        text: String,
        truncated: Bool,
        figures: [PaperWalkthroughFigureReference],
        argument: PaperWalkthroughArgumentMap? = nil,
        config: AITaskConfig
    ) async throws -> PaperWalkthroughDraft {
        let system = AITask.walkthroughWriting.effectivePrompt ?? Prompts.walkthroughWriter
        // The learner's About you, so the writer pitches the walk to them
        // (Prompts.walkthroughWriter, "Pitch it to the learner").
        let user = PaperWalkthroughGeneratorService.writerUserMessage(
            source: source,
            text: text,
            truncated: truncated,
            figures: figures,
            argument: argument,
            learner: LearnerProfile.aboutYou
        )
        let response = try await call(
            config: config,
            system: system,
            user: user,
            maxTokens: PaperWalkthroughWriting.writerMaxTokens,
            temperature: PaperWalkthroughWriting.writerTemperature,
            jsonMode: true,
            sourceTitle: source.title,
            subjectID: source.id,
            subjectType: source.sourceType.rawValue
        )
        let draft: PaperWalkthroughDraft
        do {
            draft = try MemoryReviewPlanning.decodeJSON(response)
        } catch {
            throw AIError.invalidResponse
        }
        guard !draft.steps.isEmpty else {
            throw PaperWalkthroughGenerationError.emptyDraft
        }
        return draft
    }

    /// Draw one step's animation as a complete HTML document. `excerpt` is
    /// the source's own passages about the step, when the text has any.
    func drawWalkthroughAnimation(
        source: StudioArticle,
        step: PaperWalkthroughStep,
        figure: PaperWalkthroughFigureReference?,
        excerpt: String? = nil,
        config: AITaskConfig
    ) async throws -> String {
        let system = AITask.walkthroughAnimation.effectivePrompt ?? Prompts.walkthroughAnimator
        let user = PaperWalkthroughGeneratorService.animatorUserMessage(
            source: source,
            step: step,
            figure: figure,
            excerpt: excerpt
        )
        let response = try await call(
            config: config,
            system: system,
            user: user,
            maxTokens: PaperWalkthroughWriting.drawerMaxTokens,
            temperature: PaperWalkthroughWriting.drawerTemperature,
            sourceTitle: source.title,
            subjectID: source.id,
            subjectType: source.sourceType.rawValue
        )
        guard let html = Self.htmlDocument(in: response) else {
            throw AIError.invalidResponse
        }
        return html
    }

    /// The HTML document in a model's answer (`PaperWalkthroughWriting.htmlDocument`).
    static func htmlDocument(in response: String) -> String? {
        PaperWalkthroughWriting.htmlDocument(in: response)
    }
}
#endif
