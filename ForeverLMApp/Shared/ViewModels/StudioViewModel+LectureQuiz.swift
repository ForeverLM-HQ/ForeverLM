import Foundation

/// Lecture material for a course's quizzes (docs/lecture-quiz-design.md).
extension StudioViewModel {

    /// The stored text of a lecture, fetching a YouTube video's transcript
    /// first when the library does not have one yet.
    func lectureQuizContent(for article: StudioArticle) async -> String? {
        if let stored = await storage.loadSourceContent(article.id),
           !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stored
        }
        guard YouTubeTranscriptService.isYouTubeURL(article.url) else { return nil }
        await fetchYouTubeTranscript(for: article.id, userInitiated: true)
        guard let fetched = await storage.loadSourceContent(article.id),
              !fetched.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return fetched
    }
}
