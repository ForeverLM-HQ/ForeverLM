#if os(macOS)
import Foundation
import os

private let quizGradingLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
    category: "QuizGrading"
)

extension AIService {

    /// Grades one typed answer to a course quiz question
    /// (docs/lecture-quiz-design.md). `config` is the model that grades, the
    /// quiz chat's own. It is a call of its own, apart from the chat, so only
    /// the grader reads the reference answer before the learner has answered.
    /// Where the attempt allows it, the grader may answer with a follow-up
    /// instead of a grade.
    ///
    /// Every reply is checked as a grade (`validateResponse`), so a reply
    /// that is not one moves the call on to the model's backups, as a busy
    /// model does, and is never cached. When the whole chain fails in a way
    /// asking again could fix, the grade is asked for again in place
    /// (`QuizGrading.withRetries`); when no try gives a grade, the failure
    /// names the model (`QuizGradingFailure`).
    func gradeQuizAnswer(
        source: StudioArticle,
        question: String,
        referenceAnswer: String,
        keyPoints: [String],
        coveredTranscript: String,
        attempt: QuizAnswerAttempt,
        config: AITaskConfig
    ) async throws -> QuizGraderResult {
        let system = Prompts.videoQuizGrader
        let user = VideoQuizPlanning.graderMessage(
            question: question,
            referenceAnswer: referenceAnswer,
            keyPoints: keyPoints,
            coveredTranscript: coveredTranscript,
            attempt: attempt
        )
        do {
            return try await QuizGrading.withRetries(
                onRetry: { failures, wait, error in
                    quizGradingLogger.warning(
                        "Grading on \(config.model, privacy: .public) failed (try \(failures)), trying again in \(wait, format: .fixed(precision: 0))s: \(error.localizedDescription, privacy: .public)"
                    )
                },
                operation: {
                    let reply = try await self.call(
                        config: config,
                        system: system,
                        user: user,
                        maxTokens: VideoQuizPlanning.graderMaxTokens,
                        temperature: 0,
                        jsonMode: true,
                        validateResponse: { _ = try VideoQuizPlanning.graderResult(fromReply: $0, for: attempt) },
                        sourceTitle: source.title,
                        subjectID: source.id,
                        subjectType: source.sourceType.rawValue
                    )
                    return try VideoQuizPlanning.graderResult(fromReply: reply, for: attempt)
                }
            )
        } catch {
            if AITransientErrorClassifier.isCancellation(error) { throw error }
            quizGradingLogger.error(
                "Grading on \(config.model, privacy: .public) gave no grade: \(error.localizedDescription, privacy: .public)"
            )
            throw QuizGradingFailure(
                underlying: error,
                modelName: AIModelCatalog.pickerName(provider: config.provider, modelID: config.model),
                modelIsFree: AIModelCatalog.isFree(provider: config.provider, modelID: config.model)
            )
        }
    }
}
#endif
