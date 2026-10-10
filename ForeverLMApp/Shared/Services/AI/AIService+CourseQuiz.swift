#if os(macOS)
import Foundation

extension AIService {

    /// Writes one call's worth of a quiz of a course's ladder. A practice
    /// quiz reads its one lecture on the Lecture Quiz Writing model with that
    /// task's prompt, and then each reading assigned with the lecture in a
    /// call of its own, the lecture's learning points alongside
    /// (`lecturePoints`); a checkpoint or the course test reads one part per
    /// lecture and per reading on Course Quiz Writing. With `coverage`, the
    /// call asks only for the learning points an earlier call on the same
    /// material listed and left without a question. With `drawings` above
    /// zero the writer may brief that many pictures for ForeverLM to draw,
    /// where no slide or figure shows a question's point. The draft is
    /// checked by `CourseQuizPlanning.questions`; this only asks and decodes.
    func writeCourseQuiz(
        kind: CourseQuiz.Kind,
        courseTitle: String?,
        parts: [CourseQuizPart],
        questionCount: Int,
        subject: StudioArticle,
        config: AITaskConfig,
        learnerContext: String? = nil,
        lecturePoints: [String]? = nil,
        coverage: CourseQuizCoverage? = nil,
        drawings: Int = 0
    ) async throws -> CourseQuizDraft {
        var header: [String] = []
        if let courseTitle = courseTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !courseTitle.isEmpty {
            header.append("Course: \(courseTitle)")
        }
        // The learner's own words about where they are coming from and what
        // they need: ask at their level and toward what they need.
        if let learnerContext, !learnerContext.isEmpty {
            header.append(learnerContext)
        }
        let system: String
        let material: String
        let truncated: Bool
        var instructions: [String] = []
        switch kind {
        case .practice:
            system = AITask.lectureQuizWriting.effectivePrompt ?? Prompts.lectureQuizWriter
            let part = parts.first
            let block = LectureQuizPlanning.transcriptBlock(part?.lines ?? [])
            truncated = block.truncated
            header.append("Lecture: \(part?.lectureTitle ?? subject.title)")
            if let reading = part?.reading {
                header.append("Reading assigned with this lecture: \(reading.title) (\(reading.place))")
                let figures = CourseQuizPictures.figureBlock(
                    part?.figures ?? [],
                    heading: "Figures:",
                    budget: LectureQuizPlanning.transcriptCharacterBudget / 4
                )
                material = "Reading:\n" + block.text + (figures.map { "\n\n" + $0 } ?? "")
                instructions.append(CourseQuizReadingInstructions.practice(lecturePoints: lecturePoints ?? []))
            } else {
                let slides = CourseQuizPictures.block(
                    part?.slides ?? [],
                    heading: "Slides:",
                    budget: LectureQuizPlanning.transcriptCharacterBudget / 4
                )
                material = "Transcript:\n" + block.text + (slides.map { "\n\n" + $0 } ?? "")
            }
        case .checkpoint, .test:
            system = AITask.courseQuizWriting.effectivePrompt ?? Prompts.courseQuizWriter
            let block = CourseQuizPlanning.materialBlock(parts)
            material = "Material:\n" + block.text
            truncated = block.truncated
            let lectures = parts.filter { $0.reading == nil }.count
            let readings = parts.count - lectures
            let readingNote = readings == 0 ? "" : ", and \(readings) reading\(readings == 1 ? "" : "s") assigned with them"
            header.append(kind == .test
                ? "This is the course test, across all \(lectures) lectures\(readingNote)."
                : "This is a checkpoint quiz across \(lectures) lectures\(readingNote).")
            if readings > 0 { instructions.append(CourseQuizReadingInstructions.parts) }
        }
        if coverage == nil {
            header.append("Questions for material of this length: at least \(questionCount); list every learning point first, and ask about each, however many that takes")
        }
        if truncated, kind == .practice {
            header.append("The \(parts.first?.reading == nil ? "transcript" : "reading") below is cut short; ask only about the part shown.")
        }
        if let coverage {
            // Only the questions the earlier call left out: the quiz keeps
            // the name it was given then.
            instructions.append(coverage.instruction)
        } else {
            instructions.append(CourseQuizNaming.draftNamingInstruction)
        }
        if parts.contains(where: { !$0.slides.isEmpty }) {
            instructions.append(CourseQuizPictures.draftInstruction)
        }
        if parts.contains(where: { !$0.figures.isEmpty }) {
            instructions.append(CourseQuizPictures.figureInstruction)
        }
        if drawings > 0 {
            instructions.append(CourseQuizPictures.drawInstruction(limit: drawings))
        }
        header += instructions
        let response = try await call(
            config: config,
            system: system,
            user: header.joined(separator: "\n") + "\n\n" + material,
            maxTokens: kind == .practice ? LectureQuizPlanning.writerMaxTokens : CourseQuizPlanning.writerMaxTokens,
            temperature: 0.4,
            jsonMode: true,
            sourceTitle: subject.title,
            subjectID: subject.id,
            subjectType: subject.sourceType.rawValue
        )
        do {
            return try MemoryReviewPlanning.decodeJSON(response)
        } catch {
            throw AIError.invalidResponse
        }
    }

    /// Chooses the lecture slides and reading figures for the questions of a
    /// quiz already written, and with `drawings` above zero briefs up to that
    /// many pictures for ForeverLM to draw where neither shows a point. One
    /// call on the route that writes quizzes; the picks are checked by
    /// `CourseQuizPictures.applying`, this only asks and decodes.
    func pickCourseQuizPictures(
        _ quiz: CourseQuiz,
        parts: [CourseQuizPart],
        candidates: [Int],
        courseTitle: String?,
        subject: StudioArticle,
        config: AITaskConfig,
        drawings: Int = 0
    ) async throws -> CourseQuizPictures.PickDraft {
        var header: [String] = []
        if let courseTitle = courseTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !courseTitle.isEmpty {
            header.append("Course: \(courseTitle)")
        }
        header.append("Quiz: \(quiz.title)")
        if drawings > 0 {
            // Like the writer's, not part of the fixed prompt: a pass that may
            // not draw is never offered it.
            header.append(CourseQuizPictures.drawInstruction(limit: drawings)
                .replacingOccurrences(of: "add to its JSON object:", with: "add to its entry in \"pictures\", in place of a slide or figure:"))
        }
        let material = CourseQuizPictures.pickerMaterial(quiz: quiz, parts: parts, candidates: candidates, drawing: drawings > 0)
        let response = try await call(
            config: config,
            system: Prompts.courseQuizPicturePicker,
            user: header.joined(separator: "\n") + "\n\n" + material,
            maxTokens: 4_000,
            temperature: 0.2,
            jsonMode: true,
            sourceTitle: subject.title,
            subjectID: subject.id,
            subjectType: subject.sourceType.rawValue
        )
        do {
            return try MemoryReviewPlanning.decodeJSON(response)
        } catch {
            throw AIError.invalidResponse
        }
    }

    /// Names a quiz written before quizzes were named: a short title for the
    /// topics its questions cover and an SF Symbol, read from the questions
    /// alone. One small call on the route that wrote the quiz.
    func nameCourseQuiz(
        _ quiz: CourseQuiz,
        courseTitle: String?,
        subject: StudioArticle,
        config: AITaskConfig
    ) async throws -> CourseQuizName {
        var lines: [String] = []
        if let courseTitle = courseTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !courseTitle.isEmpty {
            lines.append("Course: \(courseTitle)")
        }
        lines.append("Questions:")
        for question in quiz.questions.prefix(12) {
            lines.append("- \(question.question)")
        }
        let response = try await call(
            config: config,
            system: """
                You name quizzes in a course. Reply with one JSON object and nothing else:
                {"title": "...", "symbol": "..."}
                "title": two to six words naming the topics the questions cover, in title case, without the word "Quiz" (for example "Cristae and Supercomplexes").
                "symbol": the name of one SF Symbol that suits those topics (for example "bolt.heart", "atom", "leaf", "function").
                """,
            user: lines.joined(separator: "\n"),
            maxTokens: 400,
            temperature: 0.3,
            jsonMode: true,
            sourceTitle: subject.title,
            subjectID: subject.id,
            subjectType: subject.sourceType.rawValue
        )
        do {
            return try MemoryReviewPlanning.decodeJSON(response)
        } catch {
            throw AIError.invalidResponse
        }
    }
}

/// A quiz's name as the namer returns it.
struct CourseQuizName: Decodable, Sendable {
    let title: String?
    let symbol: String?
}
#endif
