import Foundation

/// How far a course's quiz writing has got, for the sidebar.
struct CourseQuizWritingProgress: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case fetchingTranscripts
        case writing
    }

    var stage: Stage
    var done: Int
    var total: Int
}

/// A course's quizzes written ahead of time (docs/lecture-quiz-design.md): the
/// Khan ladder of a practice quiz after each lecture, a checkpoint quiz after
/// every few, and the course test. Written when the learner asks, from the
/// course's context menu or over MCP (`generate_course_quizzes`), by the same
/// `CourseQuizGeneratorService`, or one lecture's from the lecture's own
/// context menu. Opening a quiz never writes one.
extension StudioViewModel {

    func courseQuizzes(for courseID: String) -> [CourseQuiz] {
        courseQuizzesByCourse[courseID] ?? []
    }

    func courseQuiz(_ id: String) -> CourseQuiz? {
        for quizzes in courseQuizzesByCourse.values {
            if let quiz = quizzes.first(where: { $0.id == id }) { return quiz }
        }
        return nil
    }

    /// The score a quiz row shows: the stored quiz's latest sitting.
    func courseQuizScore(quizID: String) -> LectureQuizScore? {
        courseQuizScores[quizID]
    }

    private var courseQuizGenerator: CourseQuizGeneratorService {
        CourseQuizGeneratorService(storage: storage, aiService: aiService)
    }

    /// Write a course's quizzes: the missing ones, or all of them again when
    /// `rewrite` is set. Lecture videos without a transcript get theirs first.
    func writeCourseQuizzes(courseID: String, rewrite: Bool = false) async {
        await writeCourseQuizzes(courseID: courseID, rewrite: rewrite, quizIDs: nil, lectureIDs: nil)
    }

    /// Writes one lecture's practice quiz from the lecture's context menu, or
    /// writes it again when it exists.
    func writeLectureQuiz(courseID: String, lectureID: String) async {
        let id = CourseQuizPlanning.practiceID(courseID: courseID, lectureID: lectureID)
        await writeCourseQuizzes(
            courseID: courseID,
            rewrite: courseQuiz(id) != nil,
            quizIDs: [id],
            lectureIDs: [lectureID]
        )
    }

    private func writeCourseQuizzes(
        courseID: String,
        rewrite: Bool,
        quizIDs: Set<String>?,
        lectureIDs: Set<String>?
    ) async {
        guard courseQuizWritingProgress[courseID] == nil else { return }
        let title = courseDisplayName(courseID)
        courseQuizWritingProgress[courseID] = CourseQuizWritingProgress(stage: .fetchingTranscripts, done: 0, total: 0)
        defer { courseQuizWritingProgress[courseID] = nil }
        await fetchMissingLectureTranscripts(courseID: courseID, lectureIDs: lectureIDs)
        // With drawing on, the writers may brief a picture for a question no
        // slide or figure shows, and it is drawn below with the quiz's own.
        let draws = MacImageGenerationSettings.drawsForNewQuizzes
        do {
            let result = try await courseQuizGenerator.run(
                courseID: courseID,
                options: CourseQuizGenerationOptions(
                    includeTest: quizIDs == nil,
                    rewrite: rewrite,
                    quizIDs: quizIDs,
                    briefsDrawings: draws
                )
            ) { [weak self] done, total in
                await MainActor.run {
                    self?.courseQuizWritingProgress[courseID] = CourseQuizWritingProgress(
                        stage: .writing, done: done, total: total
                    )
                }
            }
            await refreshCourseOutline()
            showToast(Self.courseQuizSummary(result, courseTitle: title))
            // A new quiz gets its picture straight away when the learner has
            // that on; a rewritten one keeps the picture it had. Then the
            // pictures its questions asked for are drawn.
            if draws, !result.written.isEmpty {
                courseQuizWritingProgress[courseID] = nil
                await drawCourseQuizPictures(courseID: courseID, only: Set(result.written.map(\.id)))
                await drawCourseQuizQuestionPictures(courseID: courseID, only: Set(result.written.map(\.id)))
            }
        } catch {
            await refreshCourseOutline()
            showToast("Couldn't write quizzes for \(title): \(error.localizedDescription)")
        }
    }

    /// Lecture videos in the course (or in the named lectures) whose
    /// transcript was never fetched get it now, one after another.
    func fetchMissingLectureTranscripts(courseID: String, lectureIDs: Set<String>? = nil) async {
        for lecture in courseLectures(for: courseID) where lectureIDs?.contains(lecture.id) ?? true {
            for item in courseLectureItems(for: lecture.id) where item.role == .video {
                guard let article = self.article(for: item) else { continue }
                _ = await lectureQuizContent(for: article)
            }
        }
    }

    static func courseQuizSummary(_ result: CourseQuizGenerationResult, courseTitle: String) -> String {
        var parts: [String] = []
        if !result.written.isEmpty {
            parts.append("wrote \(result.written.count) quiz\(result.written.count == 1 ? "" : "zes")")
        }
        if !result.named.isEmpty {
            parts.append("named \(result.named.count) quiz\(result.named.count == 1 ? "" : "zes")")
        }
        if !result.retired.isEmpty {
            parts.append("removed \(result.retired.count) old checkpoint\(result.retired.count == 1 ? "" : "s") the new ones replace")
        }
        if !result.kept.isEmpty, result.written.isEmpty, result.named.isEmpty, result.failed.isEmpty {
            parts.append("every quiz was already written")
        }
        if !result.failed.isEmpty {
            parts.append("\(result.failed.count) failed (\(result.failed.first?.message ?? ""))")
        }
        if !result.lecturesWithoutMaterial.isEmpty {
            let count = result.lecturesWithoutMaterial.count
            parts.append("\(count) lecture\(count == 1 ? " has" : "s have") no transcript yet")
        }
        return "\(courseTitle): " + (parts.isEmpty ? "nothing to write" : parts.joined(separator: "; ")) + "."
    }

    // MARK: Pictures

    /// Draws one quiz's picture on the learner's image model and style, and
    /// keeps it in the quiz (docs/lecture-quiz-design.md, "Titles, symbols
    /// and pictures"). Redrawing replaces the one it has.
    func drawCourseQuizPicture(_ quizID: String) async {
        guard let quiz = courseQuiz(quizID), !courseQuizDrawingIDs.contains(quizID) else { return }
        courseQuizDrawingIDs.insert(quizID)
        defer { courseQuizDrawingIDs.remove(quizID) }
        do {
            _ = try await courseQuizGenerator.drawArtwork(
                for: quiz,
                courseTitle: courseDisplayName(quiz.courseID),
                model: MacImageGenerationSettings.model,
                style: MacImageGenerationSettings.style
            )
            await refreshCourseOutline()
        } catch {
            showToast("Couldn't draw a picture for \(quiz.title): \(error.localizedDescription)")
        }
    }

    /// Draws a picture for every quiz of the course that has none (or only
    /// those in `only`), a few at a time.
    func drawCourseQuizPictures(courseID: String, only: Set<String>? = nil) async {
        let missing = courseQuizzes(for: courseID).filter {
            $0.artwork == nil && !courseQuizDrawingIDs.contains($0.id) && (only?.contains($0.id) ?? true)
        }
        guard !missing.isEmpty else { return }
        let title = courseDisplayName(courseID)
        courseQuizDrawingIDs.formUnion(missing.map(\.id))
        let failures = await courseQuizGenerator.drawArtwork(
            for: missing,
            courseTitle: title,
            model: MacImageGenerationSettings.model,
            style: MacImageGenerationSettings.style
        ) { [weak self] quizID in
            await MainActor.run { _ = self?.courseQuizDrawingIDs.remove(quizID) }
        }
        await refreshCourseOutline()
        if !failures.isEmpty {
            let drawn = missing.count - failures.count
            let firstError = missing.lazy.compactMap { failures[$0.id] }.first ?? ""
            showToast("\(title): drew \(drawn) quiz picture\(drawn == 1 ? "" : "s"); \(failures.count) failed (\(firstError)).")
        }
    }

    /// Draws the pictures briefed for the questions of the course's quizzes
    /// (or only those in `only`) on the learner's image model, pinning each to
    /// its question as it is drawn. Tiles spin while theirs are drawn.
    func drawCourseQuizQuestionPictures(courseID: String, only: Set<String>? = nil) async {
        let quizzes = courseQuizzes(for: courseID).filter { quiz in
            (only?.contains(quiz.id) ?? true) && !courseQuizDrawingIDs.contains(quiz.id)
                && quiz.questions.contains { $0.picture?.isAwaitingDrawing == true }
        }
        guard !quizzes.isEmpty else { return }
        let title = courseDisplayName(courseID)
        let ids = Set(quizzes.map(\.id))
        courseQuizDrawingIDs.formUnion(ids)
        defer { courseQuizDrawingIDs.subtract(ids) }
        let result = await courseQuizGenerator.drawQuestionPictures(
            courseID: courseID,
            quizIDs: quizzes.map(\.id),
            courseTitle: title,
            model: MacImageGenerationSettings.model
        ) { [weak self] quizID in
            await MainActor.run { _ = self?.courseQuizDrawingIDs.remove(quizID) }
        }
        await refreshCourseOutline()
        if let first = result.failures.values.first {
            showToast("\(title): drew \(result.drawnCount) question picture\(result.drawnCount == 1 ? "" : "s"); \(result.failures.count) quiz\(result.failures.count == 1 ? "" : "zes") failed (\(first)).")
        }
    }

    /// Gives the course's quizzes (or only those in `only`) the pictures that
    /// make their questions' points clear, without rewriting a question
    /// (docs/lecture-quiz-design.md, "Pictures"): a lecture's slide, a
    /// reading's figure, or, where neither shows the point and drawing is
    /// possible, a picture drawn for it. The slides of each lecture video the
    /// quizzes cover are captured first when they never were, as the reader's
    /// Show Slides does. Tiles spin while theirs are chosen and drawn.
    func addPicturesToCourseQuizzes(courseID: String, only: Set<String>? = nil) async {
        let quizzes = courseQuizzes(for: courseID).filter {
            (only?.contains($0.id) ?? true) && !courseQuizDrawingIDs.contains($0.id)
        }
        guard !quizzes.isEmpty else { return }
        let title = courseDisplayName(courseID)
        let ids = Set(quizzes.map(\.id))
        courseQuizDrawingIDs.formUnion(ids)
        defer { courseQuizDrawingIDs.subtract(ids) }
        let lectureIDs = Set(quizzes.flatMap(\.lectureIDs))
        for lecture in courseLectures(for: courseID) where lectureIDs.contains(lecture.id) {
            for item in courseLectureItems(for: lecture.id) where item.role == .video {
                guard let article = self.article(for: item), Self.supportsSlideExtraction(article) else { continue }
                await extractSlideFrames(for: article.id)
            }
        }
        do {
            let result = try await courseQuizGenerator.addQuestionPictures(
                courseID: courseID,
                quizIDs: ids,
                drawingModel: MacImageGenerationSettings.model
            ) { [weak self] quizID in
                await MainActor.run { _ = self?.courseQuizDrawingIDs.remove(quizID) }
            }
            await refreshCourseOutline()
            showToast(Self.courseQuizPictureSummary(result, courseTitle: title))
        } catch {
            await refreshCourseOutline()
            showToast("Couldn't add pictures to \(title)'s quizzes: \(error.localizedDescription)")
        }
    }

    static func courseQuizPictureSummary(_ result: CourseQuizPictureResult, courseTitle: String) -> String {
        var quizzes = 0
        var empty = 0
        var failures: [String] = []
        for entry in result.outcomes {
            switch entry.outcome {
            case .pictured: quizzes += 1
            case .noneFitting, .nothingToPicture: empty += 1
            case .failed(let message): failures.append(message)
            }
        }
        var parts: [String] = []
        let questions = result.picturedCount
        if questions > 0 {
            parts.append("added pictures to \(questions) question\(questions == 1 ? "" : "s") in \(quizzes) quiz\(quizzes == 1 ? "" : "zes")")
        }
        let drawn = result.drawing.drawnCount
        if drawn > 0 {
            parts.append("drew \(drawn)")
        }
        if empty > 0 {
            parts.append(questions > 0
                ? "\(empty) quiz\(empty == 1 ? " had" : "zes had") nothing a picture would help"
                : "no question found a picture that helps (a lecture needs its slides captured, and questions with a picture keep theirs)")
        }
        if let first = failures.first {
            parts.append("\(failures.count) failed (\(first))")
        }
        if let drawingFailure = result.drawing.failures.values.first {
            parts.append("drawing failed for \(result.drawing.failures.count) quiz\(result.drawing.failures.count == 1 ? "" : "zes") (\(drawingFailure))")
        }
        return "\(courseTitle): " + (parts.isEmpty ? "no quizzes to add pictures to" : parts.joined(separator: "; ")) + "."
    }

    func removeCourseQuizPicture(_ quizID: String) async {
        do {
            try await courseQuizGenerator.removeArtwork(quizID: quizID)
            await refreshCourseOutline()
        } catch {
            showToast("Couldn't remove the picture: \(error.localizedDescription)")
        }
    }

    /// Removes a quiz and its score. A quiz written later starts with no score.
    func deleteCourseQuiz(_ id: String) async {
        do {
            try await storage.deleteCourseQuiz(id)
            courseQuizScores[id] = nil
            courseQuizSittings[id] = nil
            courseQuizFinishedSittings[id] = nil
            Preferences.reset(Prefs.Families.courseQuizScore.key(id))
            await refreshCourseOutline()
        } catch {
            showToast("Couldn't remove the quiz: \(error.localizedDescription)")
        }
    }

    /// Keeps a finished sitting as the quiz's score, shown on its row at once
    /// and synced as the `courseQuiz.score.<quizID>` preference row. The
    /// quiz's first pass is kept with it, so a worse retake leaves the
    /// lectures after it open (docs/courses-design.md, "The gate").
    func recordCourseQuizScore(_ score: LectureQuizScore, quizID: String) {
        let kept = score.recorded(after: courseQuizScores[quizID])
        courseQuizScores[quizID] = kept
        Preferences.set(kept.preferenceValue, for: Prefs.Families.courseQuizScore.key(quizID))
    }

    /// The quiz with its questions timed where their quotes are said, worked
    /// out off the main actor: a course test reads every lecture's text.
    nonisolated static func timedByQuotes(_ quiz: CourseQuiz, lines: [String: [LectureQuizLine]]) async -> CourseQuiz {
        await Task.detached(priority: .userInitiated) {
            var timed = quiz
            timed.questions = CourseQuizPlanning.timedByQuotes(quiz.questions, lines: lines)
            return timed
        }.value
    }

    /// Numbered lines of the sources a quiz's questions rest on, keyed by
    /// source ID, for grading, Memory and Rewatch.
    func courseQuizLines(for quiz: CourseQuiz) async -> [String: [LectureQuizLine]] {
        var lines: [String: [LectureQuizLine]] = [:]
        for sourceID in Set(quiz.questions.compactMap(\.sourceID)) {
            guard let content = await storage.loadSourceContent(sourceID) else { continue }
            let parsed = await Task.detached(priority: .userInitiated) {
                CourseQuizPlanning.lines(from: content)
            }.value
            lines[sourceID] = parsed
        }
        return lines
    }

    /// Grades an attempt on `config`, the quiz chat's own model, and records
    /// it on the question's Memory item. The grade stands even when Memory
    /// cannot keep the question; that failure comes back as `memoryError`. A
    /// follow-up the grader asks instead is returned with nothing recorded,
    /// so the answer and the reply to it make one grade and one attempt.
    func gradeCourseQuizAttempt(
        quiz: CourseQuiz,
        question: CourseQuizQuestion,
        attempt: QuizAnswerAttempt,
        lines: [LectureQuizLine],
        config: AITaskConfig
    ) async throws -> (result: QuizGraderResult, memoryError: String?) {
        let subject = question.sourceID.flatMap { articlesById[$0] }
        let covered = CourseQuizPlanning.coveredLines(for: question, in: lines)
            .map(\.text)
            .joined(separator: "\n")
        let result: QuizGraderResult
        if let subject {
            result = try await AIUsageAttribution.withSource(AIUsageSource(source: subject)) {
                try await aiService.gradeQuizAnswer(
                    source: subject,
                    question: question.question,
                    referenceAnswer: question.answer,
                    keyPoints: question.keyPoints,
                    coveredTranscript: String(covered.prefix(12_000)),
                    attempt: attempt,
                    config: config
                )
            }
        } else {
            throw CourseQuizError.nothingToQuiz
        }
        guard case .graded(let grade) = result else { return (result, nil) }
        let memoryError = await recordCourseQuizAttempt(
            quiz: quiz, question: question, lines: lines, answer: attempt.memoryText,
            feedback: grade.feedback, score: grade.verdict.score, rating: grade.verdict.scheduleRating
        )
        return (result, memoryError)
    }

    // MARK: Planning a course

    /// Generate in the Courses tab: a new chat that plans the course with the
    /// learner before anything is written (`CoursePlanningChat`). The Chat
    /// panel opens on it with "I want to make a course about " typed.
    ///
    /// From a notebook's Studio (its Course tile) the chat is the notebook's:
    /// filed in it, with its own ticked sources as the chat's sources — what
    /// every Studio tile works from, never a context notebook's
    /// (`notebookStudioSourceIDs`) — and the opening names the notebook. The
    /// course it makes lives there: the chat's `generate_course` call is
    /// filed in the notebook (`ReviewSessionManager.madeThingArguments`).
    func startCoursePlanningChat(inNotebook notebookID: String? = nil) {
        if let notebookID, let notebook = notebook(id: notebookID) {
            pendingCoursePlanningNotebookID = notebook.id
            setContextSources(notebookStudioSourceIDs(notebook.id))
        } else {
            pendingCoursePlanningNotebookID = nil
        }
        reviewChatPanelMode = .chat
        isChatTabActive = true
        pendingCoursePlanningChat = true
        reviewChatAutoStartRequestID = UUID()
        reviewChatTargetWindowID = activeWindowState.id
    }

    // MARK: Taking a quiz

    /// Take a quiz (docs/lecture-quiz-design.md, "Taking a quiz"), as Khan
    /// Academy does: a sitting under way is picked up where it stopped, a
    /// finished quiz opens its results chat, and otherwise, or with
    /// `startOver`, the quiz starts on question 1 (`CourseQuizOpening`).
    func takeCourseQuiz(_ quizID: String, startOver: Bool = false) {
        guard let quiz = courseQuiz(quizID) else {
            showToast("This quiz is no longer in the course.")
            return
        }
        guard !quiz.questions.isEmpty else {
            showToast(CourseQuizError.noQuestions(quiz.title).localizedDescription)
            return
        }
        let chats = Set(reviewSessionLinks.map(\.id))
        if let sessionID = CourseQuizOpening.chatToOpen(
            latest: courseQuizSittings[quizID],
            lastFinished: courseQuizFinishedSittings[quizID],
            retake: startOver,
            chatExists: chats.contains
        ) {
            // The Chat panel reopens it and hands it back its grader
            // (`courseQuizChatRequest(forSessionID:)`).
            requestResumeReviewSession(sessionID)
            return
        }
        reviewChatPanelMode = .chat
        isChatTabActive = true
        // The request token is set once the lines are read, by which time the
        // `inWindow` scope the row opened is gone: remember the window now.
        let targetWindowID = activeWindowState.id
        Task { [weak self] in
            guard let self else { return }
            pendingCourseQuiz = await courseQuizChatRequest(for: quiz)
            reviewChatAutoStartRequestID = UUID()
            reviewChatTargetWindowID = targetWindowID
        }
    }

    /// The quiz a reopened chat is a sitting of, ready to grade again; nil
    /// for any other chat, or when its quiz has been removed.
    func courseQuizChatRequest(forSessionID sessionID: String) async -> CourseQuizChatRequest? {
        guard let quizID = CourseQuizSitting.quizID(inSessionID: sessionID),
              let quiz = courseQuiz(quizID), !quiz.questions.isEmpty else { return nil }
        return await courseQuizChatRequest(for: quiz)
    }

    /// Everything the chat needs to run a quiz. The lectures' numbered lines
    /// are read first, off the main actor, so the grader and Memory have them
    /// from the first answer, and each question's Rewatch moment is set from
    /// them where its quote is said (`CourseQuizPlanning.timedByQuotes`).
    private func courseQuizChatRequest(for stored: CourseQuiz) async -> CourseQuizChatRequest {
        let lines = await courseQuizLines(for: stored)
        let quiz = await Self.timedByQuotes(stored, lines: lines)
        let readings = await courseQuizReadings(for: quiz)
        var questionSourceIDs: [String] = []
        for sourceID in quiz.questions.compactMap(\.sourceID) where !questionSourceIDs.contains(sourceID) {
            questionSourceIDs.append(sourceID)
        }
        let titles = Dictionary(uniqueKeysWithValues: questionSourceIDs.compactMap { id in
            articlesById[id].map { (id, displayTitle(for: $0)) }
        })
        // A planned reading's chapter is not attached, even when questions
        // are about it: the tutor reads its planned pages with
        // read_planned_reading, and the quiz's review stays its lectures'.
        let chapters = Set(readings.map(\.chapterID))
        let sourceIDs = questionSourceIDs.filter { !chapters.contains($0) }
        return CourseQuizChatRequest(
            quiz: quiz,
            // A named quiz reads "Quiz: Cristae and Supercomplexes"; an
            // unnamed one already says Quiz ("Quiz: <lecture>", "Quiz 3").
            topic: quiz.kind == .test
                ? "\(courseDisplayName(quiz.courseID)): \(quiz.title)"
                : (quiz.hasTopicTitle ? "Quiz: \(quiz.title)" : quiz.title),
            subtitle: courseQuizSubtitle(quiz),
            sourceIDs: sourceIDs,
            sourceTitles: titles,
            readings: readings,
            grade: { [weak self] question, attempt, grader in
                guard let self else { throw CancellationError() }
                return try await gradeCourseQuizAttempt(
                    quiz: quiz,
                    question: question,
                    attempt: attempt,
                    lines: question.sourceID.flatMap { lines[$0] } ?? [],
                    config: grader
                )
            },
            recorded: { [weak self] _, progress in
                guard let self else { return }
                courseQuizSittings[quiz.id] = progress
                if progress.isFinished {
                    courseQuizFinishedSittings[quiz.id] = progress
                }
                if let score = progress.score {
                    recordCourseQuizScore(score, quizID: quiz.id)
                }
            }
        )
    }

    /// The textbook readings planned for the quiz's lectures, in course order,
    /// with their pages (docs/textbook-readings-design.md). The pages are read
    /// from the store when the sidebar has not loaded them yet; a reading whose
    /// pages cannot be told is left out rather than read whole, and so is a
    /// chapter the learner keeps from AI.
    func courseQuizReadings(for quiz: CourseQuiz) async -> [CourseQuizReading] {
        let covered = Set(quiz.lectureIDs)
        let lectures = courseLectures(for: quiz.courseID)
            .filter { covered.contains($0.id) }
            .sorted { $0.number < $1.number }
        var found: [(lecture: CourseSession, reading: CourseTextbookReading, sources: Set<String>)] = []
        for lecture in lectures {
            let sources = Set(courseLectureItems(for: lecture.id).filter { !isTextbookReading($0) }.compactMap(\.sourceId))
            for reading in textbookReadings(for: lecture.id) {
                found.append((lecture, reading, sources))
            }
        }
        guard !found.isEmpty else { return [] }

        let excluded: Set<String>
        do {
            excluded = try await storage.knowledgeBoundaryExcludedSourceIDs()
        } catch {
            logger.error("Quiz \(quiz.id, privacy: .public): planned readings left out, the AI boundary could not be read: \(error.localizedDescription, privacy: .public)")
            return []
        }
        var units = courseSourceUnitsByID
        if found.contains(where: { $0.reading.item.sourceUnitId.map { units[$0] == nil } ?? false }) {
            do {
                units = try await storage.loadCourseSourceUnits()
            } catch {
                logger.error("Quiz \(quiz.id, privacy: .public): could not read the readings' pages: \(error.localizedDescription, privacy: .public)")
            }
        }

        return found.compactMap { entry in
            let chapter = entry.reading.chapter
            guard !excluded.contains(chapter.id) else { return nil }
            let reading = CourseTextbookReading(
                item: entry.reading.item,
                chapter: chapter,
                unit: entry.reading.item.sourceUnitId.flatMap { units[$0] }
            )
            if reading.item.sourceUnitId != nil, reading.pages == nil { return nil }
            let lectureTitle = entry.lecture.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return CourseQuizReading(
                lectureSourceIDs: entry.sources,
                lectureTitle: lectureTitle.isEmpty
                    ? "Lecture \(entry.lecture.number)"
                    : "Lecture \(entry.lecture.number), \(lectureTitle)",
                chapterID: chapter.id,
                chapterTitle: chapter.title,
                bookTitle: chapter.parentGroup.map(bookDisplayName),
                sections: reading.title,
                pages: reading.pages,
                reason: reading.reason
            )
        }
    }

    /// What a quiz is about, as its chat names it: the lecture, the lectures
    /// covered, or the course.
    func courseQuizSubtitle(_ quiz: CourseQuiz) -> String {
        let courseTitle = courseDisplayName(quiz.courseID)
        let lectures = courseLectures(for: quiz.courseID)
        switch quiz.kind {
        case .practice:
            guard let lecture = lectures.first(where: { $0.id == quiz.lectureIDs.first }) else { return courseTitle }
            return lecture.title ?? "Lecture \(lecture.number)"
        case .checkpoint:
            let numbers = lectures.filter { quiz.lectureIDs.contains($0.id) }.map(\.number).sorted()
            guard let first = numbers.first, let last = numbers.last else { return courseTitle }
            return first == last ? "Lecture \(first)" : "Lectures \(first)–\(last)"
        case .test:
            return courseTitle
        }
    }

    /// A question as an attempt on its Memory item, the way a walkthrough
    /// question is: a miss keeps its card, which comes back in spaced review.
    func recordCourseQuizAttempt(
        quiz: CourseQuiz,
        question: CourseQuizQuestion,
        lines: [LectureQuizLine],
        answer: String,
        feedback: String,
        score: Double,
        rating: MemoryScheduleRating
    ) async -> String? {
        guard let memoryQuestion = CourseQuizPlanning.memoryQuestion(quizID: quiz.id, question: question, lines: lines) else {
            return rating == .good || rating == .easy ? nil : "This question names no lecture to anchor it to."
        }
        do {
            try await storage.recordSourceQuestionAttempt(
                memoryQuestion, answer: answer, feedback: feedback, score: score, rating: rating
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
