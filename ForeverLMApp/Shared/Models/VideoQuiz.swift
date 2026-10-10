import Foundation

/// Grading a typed quiz answer: what the grader is sent, how its reply is
/// checked, and what happens when it stumbles. Used by a course quiz taken in
/// a chat (docs/lecture-quiz-design.md). The file keeps the name of the video
/// checkpoint quiz it was written for, which was removed on 2026-09-28.

/// How a quiz answer gets graded when the grader stumbles (product owner,
/// 2026-09-27, of an answer the grading model sent back unreadable: "there
/// sjhould be some fallbacks here"). A reply that is not a grade fails the
/// call's own check (`AIService.call`'s `validateResponse`), so it moves on
/// to the grading model's backups where it has any, as a busy model does;
/// when that still gives no grade, the grade is asked for again in place.
/// Nothing grades in its place (AGENTS.md, AI tutor failures): a retry asks
/// the same grader about the same answer, and when every try fails the
/// learner is told, with the model that could not grade it.
enum QuizGrading {
    /// Tries per answer, the first included: two more, after 2 s and 4 s.
    static let attempts = 3
    /// The longest wait before a retry. The learner is watching the answer
    /// being checked, so a longer Retry-After is not waited out.
    static let maximumRetryWait: Double = 10

    /// The ledger's name for a grade given in a quiz's chat, on the chat's
    /// own model; like "chat_title", a purpose of the chat with no route of
    /// its own.
    static let chatTaskLabel = "chat_quiz_grading"

    /// An answer the grader sent back that cannot be used as a grade: not a
    /// grade at all (unreadable JSON, a verdict with no feedback), empty, or
    /// cut off before it finished. Asking again usually gets a good one.
    static func isUnusableAnswer(_ error: Error) -> Bool {
        switch error {
        case AIError.invalidResponse, AIError.emptyAnswer, AIError.outputTokenLimit:
            return true
        default:
            return false
        }
    }

    /// The wait before grading again after `failedAttempts` failures, or nil
    /// to give up: an unusable answer or a transient failure is retried,
    /// after 2 s and then 4 s, or the server's Retry-After when it names a
    /// short one. Anything else (no key, no balance, a refused request, a
    /// cancelled turn) is reported at once.
    static func retryDelay(after error: Error, failedAttempts: Int) -> Double? {
        guard failedAttempts < attempts,
              !AITransientErrorClassifier.isCancellation(error),
              isUnusableAnswer(error) || AITransientErrorClassifier.isTransient(error) else { return nil }
        if let retryAfter = AITransientErrorClassifier.retryAfterSeconds(error) {
            return retryAfter <= maximumRetryWait ? retryAfter : nil
        }
        return min(maximumRetryWait, 2 * pow(2, Double(max(0, failedAttempts - 1))))
    }

    /// Runs `operation`, one grading try, until it gives a grade or fails in
    /// a way `retryDelay` does not retry, and throws that last failure.
    static func withRetries<T>(
        sleep: (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        onRetry: (_ failedAttempts: Int, _ wait: Double, _ error: Error) -> Void = { _, _, _ in },
        operation: () async throws -> T
    ) async throws -> T {
        var failures = 0
        while true {
            do {
                return try await operation()
            } catch {
                failures += 1
                guard let wait = retryDelay(after: error, failedAttempts: failures) else { throw error }
                onRetry(failures, wait, error)
                try await sleep(wait)
            }
        }
    }
}

/// A grade no try could give, with the model that was asked for it, named
/// as the model pickers name it: the chat's own model. The product owner, 2026-09-27, of
/// a failure that blamed "Video Quiz Grading" on a free model: "why is quiz
/// grading running on the free nemotron model?"
struct QuizGradingFailure: LocalizedError {
    let underlying: Error
    /// "Claude Sonnet 5", "Nemotron 3 Super (free)".
    let modelName: String
    let modelIsFree: Bool

    /// Whether another model could have got past it: a busy or rate-limited
    /// model, a refusal, an answer that could not be used, or a stream the
    /// model's host dropped or stalled (the chat that reports it is getting
    /// through). A failure every model would meet the same way (no key, no
    /// balance, no connection) is not.
    var anotherModelCouldGrade: Bool {
        if let urlError = underlying as? URLError,
           urlError.code == .networkConnectionLost || urlError.code == .timedOut {
            return true
        }
        return AIBackupModels.shouldTryBackup(after: underlying)
    }

    var errorDescription: String? {
        switch underlying {
        case AIError.invalidResponse:
            return "\(modelName) sent back a reply that is not a grade."
        case AIError.emptyAnswer:
            return "\(modelName) sent back an empty answer."
        case AIError.outputTokenLimit:
            return "\(modelName) ran out of room before it gave a grade."
        default:
            return "\(modelName) could not grade it: \(underlying.localizedDescription)"
        }
    }
}

/// The grader's message and reply check, and the `m:ss` stamp quizzes put
/// on a moment of a video.
enum VideoQuizPlanning {
    /// Sized for the long-context models the Background default points at;
    /// a two-hour talk's captions fit.
    static let transcriptCharacterBudget = 180_000
    static let graderMaxTokens = QuizGraderExchange.maxTokens

    /// What the grader reads for one attempt (`Prompts.videoQuizGrader`):
    /// `QuizGraderExchange.message`, shared with the iPhone.
    static func graderMessage(
        question: String,
        referenceAnswer: String,
        keyPoints: [String],
        coveredTranscript: String,
        attempt: QuizAnswerAttempt
    ) -> String {
        QuizGraderExchange.message(
            question: question,
            referenceAnswer: referenceAnswer,
            keyPoints: keyPoints,
            coveredTranscript: coveredTranscript,
            attempt: attempt
        )
    }

    /// The grader's raw reply as what it means for the attempt it answers,
    /// or `AIError.invalidResponse` when it is no usable grade. This is the
    /// whole check of a grader reply, in one place, so a model call that
    /// validates replies before accepting them (and moves on to a backup
    /// model when one fails the check) can take it as is.
    static func graderResult(fromReply reply: String, for attempt: QuizAnswerAttempt) throws -> QuizGraderResult {
        guard let decoded = QuizGraderReply(reply: reply),
              let result = decoded.result(for: attempt) else { throw AIError.invalidResponse }
        return result
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
