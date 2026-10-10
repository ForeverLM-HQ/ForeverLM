import Foundation

extension AIService {

    /// Write the storyboard of a video explainer: a title, a shared style and
    /// one scene per clip, with the Explainer Writing route.
    func writeExplainerVideoStoryboard(
        request: ExplainerVideoRequest,
        sourceTitle: String?,
        sourceText: String?,
        truncated: Bool,
        config: AITaskConfig,
        subject: AIUsageSource? = nil
    ) async throws -> ExplainerVideoStoryboard {
        let system = Prompts.explainerVideoStoryboard
        let user = GeneratedExplainerVideo.storyboardUserMessage(
            concept: request.concept,
            length: request.length,
            sourceTitle: sourceTitle,
            sourceText: sourceText,
            truncated: truncated
        )
        let response = try await call(
            config: config,
            system: system,
            user: user,
            maxTokens: 4_000,
            temperature: 0.7,
            jsonMode: true,
            sourceTitle: subject?.title ?? request.concept,
            subjectID: subject?.id,
            subjectType: subject?.type
        )
        let storyboard: ExplainerVideoStoryboard
        do {
            storyboard = try MemoryReviewPlanning.decodeJSON(response)
        } catch {
            throw AIError.invalidResponse
        }
        guard storyboard.isUsable else {
            throw ExplainerVideoGenerationError.emptyStoryboard
        }
        return storyboard.limited(to: request.length)
    }
}
