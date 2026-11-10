// Part of ReviewSessionManager: course quiz chats and their scripted tools.

import Foundation
import Observation
import PDFKit
import os

extension ReviewSessionManager {
    /// Start a course quiz as a chat (docs/lecture-quiz-design.md, "Taking a
    /// quiz"): the lecture sources attached, a practice quiz's one lecture
    /// loaded in full, and the stored question 1 on screen at once, with no
    /// model turn before it. A quiz's chat is a review of its lectures on the
    /// Schedule, like any review.
    func startCourseQuiz(_ request: CourseQuizChatRequest, articles: [StudioArticle]) async {
        guard !request.quiz.questions.isEmpty else {
            errorMessage = CourseQuizError.noQuestions(request.quiz.title).localizedDescription
            return
        }
        let state = CourseQuizChatState(request: request)
        courseQuiz = state
        // A checkpoint or the test covers many lectures: they stay in the
        // catalog and are read when a question needs them.
        let preload = request.quiz.kind == .practice ? Set(articles.map(\.id)) : []
        // The id names the quiz and the row keeps the sitting, so the chat
        // can be picked up again where it stopped (`resumeSession`).
        await startSession(
            topic: request.topic,
            articles: articles,
            mode: .review,
            preloadSourceIDs: preload,
            fixedSessionID: CourseQuizSitting.sessionID(forQuizID: request.quiz.id),
            persistedBriefing: state.sitting.briefingText,
            scriptedOpening: state.openingMessage
        )
        guard sessionActive, let sessionID else {
            courseQuiz = nil
            return
        }
        // The row reads "In progress" from the first question, and Take Quiz
        // comes back to this chat.
        request.recorded(sessionID, state.progress(sessionID: sessionID))
    }

    /// Picks a quiz back up in a reopened chat: the grader attaches again
    /// with the grades the chat's row kept, so the tutor goes on from the
    /// first question not yet graded or accepts corrections after completion.
    func resumeCourseQuiz(_ request: CourseQuizChatRequest, sessionID: String) async {
        let briefing: String?
        do {
            briefing = try await storage.loadReviewSessionBriefing(sessionID: sessionID)
        } catch {
            errorMessage = "This quiz's progress could not be read, so it cannot go on here. \(error.localizedDescription)"
            logger.error("Quiz \(sessionID, privacy: .public): could not read its sitting: \(error.localizedDescription, privacy: .public)")
            return
        }
        courseQuiz = CourseQuizChatState(request: request, resuming: CourseQuizSitting(briefing: briefing))
    }

    /// Skip Question, pressed under the tutor's reply in a quiz's chat: the
    /// question the quiz is on is skipped here, before the learner's words go
    /// out, so the skip is kept whichever model the chat runs on. Returns what
    /// the tutor is told beside the message; nil when there is nothing to skip.
    func skipOpenCourseQuizQuestion() async -> String? {
        guard let index = courseQuiz?.currentIndex,
              let text = await applyCourseQuizSkip(at: index) else { return nil }
        return "[ForeverLM] The learner pressed Skip Question, and the app has skipped question \(index + 1) already: do not call \(CourseQuizChatState.skipToolName) for it.\n\(text)"
    }

    /// Records a skip, keeps the sitting with the chat at once and moves the
    /// quiz's row on. Returns the tutor's instructions for what follows, or
    /// nil when no quiz is running.
    func applyCourseQuizSkip(at index: Int) async -> String? {
        guard let skippingSessionID = sessionID, courseQuiz != nil else { return nil }
        courseQuiz?.recordSkip(forQuestionAt: index)
        guard let updated = courseQuiz else { return nil }
        let saveError = await keepCourseQuizSitting(updated, sessionID: skippingSessionID)
        updated.request.recorded(skippingSessionID, updated.progress(sessionID: skippingSessionID))
        pendingCourseQuizPictureTurn = .skipped
        var text = updated.skipAcknowledgement(forQuestionAt: index)
        if let saveError {
            text += "\nThis skip could not be saved with the chat (\(saveError)): if the chat is closed now, the quiz will ask this question again. Tell the learner in a few words."
        }
        return text
    }

    /// Writes the sitting to the chat's session row; the error's words when
    /// it could not be kept.
    func keepCourseQuizSitting(_ state: CourseQuizChatState, sessionID: String) async -> String? {
        do {
            try await storage.setReviewSessionBriefing(sessionID: sessionID, briefing: state.sitting.briefingText)
            return nil
        } catch {
            logger.error("Quiz \(sessionID, privacy: .public): could not keep its sitting: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }
}
