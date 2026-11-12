import Foundation

/// A course's quizzes over MCP (docs/lecture-quiz-design.md): write the Khan
/// ladder ahead of time, read one quiz, save an assistant's own, remove one,
/// and record a sitting that happened in the assistant's chat.
extension MCPDataStore {

    // MARK: generate_course_quizzes

    /// Off the store gate (`MCPToolRegistry.storeGateExemptToolNames`): every
    /// read and write here and in the writer goes through the storage actor,
    /// so the minutes of model calls hold up no other tool. Holding the gate
    /// alone would keep an assistant from reading a transcript or saving a
    /// quiz until they finished.
    func generateCourseQuizzes(arguments: [String: Any]) async throws -> String {
        let storage = notebookFileStorage
        let courseID = try await resolveExistingCourseID(input: arguments["course_id"] as? String ?? "", storage: storage)
        var options = CourseQuizGenerationOptions()
        if let every = arguments["checkpoint_every"] as? Int {
            guard CourseQuizPlanning.checkpointEveryRange.contains(every) else {
                throw MCPError.invalidInput(
                    "checkpoint_every must be between \(CourseQuizPlanning.checkpointEveryRange.lowerBound) and \(CourseQuizPlanning.checkpointEveryRange.upperBound)."
                )
            }
            options.checkpointEvery = every
        }
        options.includeTest = arguments["final_test"] as? Bool ?? true
        options.rewrite = arguments["rewrite"] as? Bool ?? false
        if let ids = arguments["quiz_ids"] as? [String], !ids.isEmpty {
            options.quizIDs = Set(ids)
        }
        // Drawing on, the writers may brief pictures for questions no slide or
        // figure shows; they are drawn below with the quizzes' own pictures.
        let drawsPictures = arguments["draw_pictures"] as? Bool ?? false
        options.briefsDrawings = drawsPictures
        let service = CourseQuizGeneratorService(storage: storage, aiService: AIService())
        let ladder = CourseQuizGeneratorService.ladder(
            for: try await service.material(courseID: courseID),
            options: options
        )
        if drawsPictures, arguments["confirm_drawings"] as? Bool != true {
            let existing = Set(try await storage.loadCourseQuizzes(courseID: courseID).map(\.id))
            let requested = ladder.filter { options.quizIDs?.contains($0.id) ?? true }
            let toWrite = options.rewrite ? requested : requested.filter { !existing.contains($0.id) }
            let maximumDrawings = toWrite.count * (CourseQuizPictures.maximumDrawingsPerQuiz + 1)
            if maximumDrawings > 0 {
                let model = try await ImageGenerationDirectory.priced(MacImageGenerationSettings.model)
                var quote = "No quizzes were written and no generated pictures were started. Drawing for this run can make up to \(maximumDrawings) separately billed image requests on \(model.name) (\(model.maker), through OpenRouter): one quiz cover plus up to \(CourseQuizPictures.maximumDrawingsPerQuiz) question diagrams per new quiz."
                quote += model.drawingQuote(forUpTo: maximumDrawings, chooser: "the writers")
                quote += " Show this quote to the learner. Only after they explicitly agree, call again with draw_pictures true, confirm_drawings true, and their approved total in approved_spend_usd. Omit draw_pictures (or pass false) to write the quizzes without generated-image requests."
                throw MCPError.invalidInput(quote)
            }
        }
        let result: CourseQuizGenerationResult
        do {
            if let only = options.quizIDs {
                // Checked before anything is written: an id outside the
                // ladder would otherwise write nothing and say nothing.
                let unknown = only.subtracting(ladder.map(\.id))
                if !unknown.isEmpty {
                    throw MCPError.invalidInput(
                        "quiz_ids \(unknown.sorted().joined(separator: ", ")) are not in this course's ladder (with these checkpoint_every and final_test settings). Call get_course for its quiz ids; an assistant's own quiz is rewritten with save_course_quiz."
                    )
                }
            }
            let activity = MCPToolActivityReporter.current
            result = try await service.run(courseID: courseID, options: options) { done, total in
                await activity?.report("\(done) of \(total) done")
            }
        } catch let error as CourseQuizError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        let title = try await storage.loadCourseMetadata()[courseID]?.title ?? courseID
        // Stopped (cancel_ai_work, or the chat that called it): the quizzes
        // written so far are saved, and nothing more is spent here, pictures
        // included.
        let stopped = Task.isCancelled
        // A newly written quiz gets its picture, as the sidebar's Write
        // Quizzes does; a rewrite kept the one it had.
        let draws = drawsPictures && !stopped
        let needPictures = draws ? result.written.filter { $0.artwork == nil } : []
        let briefed = draws
            ? result.written.filter { quiz in quiz.questions.contains { $0.picture?.isAwaitingDrawing == true } }
            : []
        if !needPictures.isEmpty || !briefed.isEmpty {
            await MCPToolActivityReporter.current?.report("Drawing pictures")
        }
        let pictureFailures = await service.drawArtwork(
            for: needPictures,
            courseTitle: title,
            model: MacImageGenerationSettings.model,
            style: MacImageGenerationSettings.style
        )
        let drewPicture = Set(needPictures.map(\.id)).subtracting(pictureFailures.keys)
        var questionPictures = CourseQuizDrawingResult()
        if !briefed.isEmpty {
            questionPictures = await service.drawQuestionPictures(
                courseID: courseID,
                quizIDs: briefed.map(\.id),
                courseTitle: title,
                model: MacImageGenerationSettings.model
            )
        }
        var lines = ["Course quizzes for '\(title)':"]
        // Each quiz by the name its writer gave it, not the ladder's placeholder.
        let storedTitles = Dictionary(
            try await storage.loadCourseQuizzes(courseID: courseID).map { ($0.id, $0.title) },
            uniquingKeysWith: { first, _ in first }
        )
        let named = Set(result.named.map(\.id))
        let written = Set(result.written.map(\.id))
        let kept = Set(result.kept)
        let failed = Dictionary(result.failed.map { ($0.slot.id, $0.message) }, uniquingKeysWith: { first, _ in first })
        let covered = Set(result.covered)
        for slot in result.slots {
            let status: String
            if written.contains(slot.id) {
                let quiz = result.written.first { $0.id == slot.id }
                let count = quiz?.questions.count ?? 0
                let shown = quiz?.questions.filter { $0.picture?.reference != nil }.count ?? 0
                var notes = ["written, \(count) questions"]
                if shown > 0 { notes.append("\(shown) shown with a slide or figure") }
                if let drawn = questionPictures.drawn[slot.id] { notes.append("\(drawn) with a picture drawn for it") }
                if let failure = questionPictures.failures[slot.id] { notes.append("a question's picture failed: \(failure)") }
                if drewPicture.contains(slot.id) { notes.append("picture drawn") }
                if let failure = pictureFailures[slot.id] { notes.append("picture failed: \(failure)") }
                status = notes.joined(separator: ", ")
            } else if let message = failed[slot.id] {
                status = "failed: \(message)"
            } else if kept.contains(slot.id) {
                status = named.contains(slot.id) ? "already written, kept, and named" : "already written, kept"
            } else if covered.contains(slot.id) {
                status = "not written: a checkpoint written before the ladder's groups moved already asks about some of its lectures (rewrite true replaces it)"
            } else if stopped, options.quizIDs?.contains(slot.id) ?? true {
                status = "not written: stopped before it was started"
            } else {
                status = "not requested"
            }
            lines.append("- \(storedTitles[slot.id] ?? slot.title) (quiz_id: \(slot.id), kind: \(slot.kind.rawValue), \(slot.lectureIDs.count) lecture\(slot.lectureIDs.count == 1 ? "" : "s")): \(status)")
        }
        if !result.retired.isEmpty {
            lines.append("")
            lines.append("Checkpoints written before the ladder's groups moved, removed now that the ladder's own checkpoints cover their lectures:")
            for quiz in result.retired {
                lines.append("- \(quiz.title) (quiz_id: \(quiz.id), \(quiz.lectureIDs.count) lectures)")
            }
        }
        if !result.lecturesWithoutMaterial.isEmpty {
            lines.append("")
            lines.append("Lectures with nothing to quiz yet (no transcript or text stored); fetch_video_transcript their videos, then call this again to write only what is missing:")
            for lecture in result.lecturesWithoutMaterial {
                lines.append("- \(lecture.title) (lecture_id: \(lecture.id))")
            }
        }
        lines.append("")
        if stopped {
            lines.append("Stopped before it finished. The quizzes written are saved; call generate_course_quizzes again to write only the rest.")
        }
        lines.append("Read a quiz with get_course_quiz; get_course shows the whole ladder in order.")
        return lines.joined(separator: "\n")
    }

    // MARK: add_course_quiz_pictures

    /// Holds no store gate for its run (`MCPToolRegistry.selfGatedToolNames`):
    /// the course and its quizzes are read, and the pictures saved, through the
    /// storage actor, and each video's slides are captured in
    /// `extractVideoSlides`' own stretches.
    func addCourseQuizPictures(arguments: [String: Any]) async throws -> String {
        let storage = notebookFileStorage
        let courseID = try await resolveExistingCourseID(input: arguments["course_id"] as? String ?? "", storage: storage)
        let quizzes = try await storage.loadCourseQuizzes(courseID: courseID)
        guard !quizzes.isEmpty else {
            throw MCPError.invalidInput("Course \(courseID) has no quizzes yet; generate_course_quizzes writes them.")
        }
        var only: Set<String>?
        if let ids = arguments["quiz_ids"] as? [String], !ids.isEmpty {
            let unknown = Set(ids).subtracting(quizzes.map(\.id))
            guard unknown.isEmpty else {
                throw MCPError.invalidInput("quiz_ids \(unknown.sorted().joined(separator: ", ")) are not quizzes of course \(courseID). Call get_course for its quiz ids.")
            }
            only = Set(ids)
        }
        let chosen = quizzes.filter { only?.contains($0.id) ?? true }

        // Source pictures are cheap to attach; generated pictures are one
        // separately billed image request apiece. A whole course can ask for
        // twelve per quiz, so omission must be the safe source-only path and
        // an assistant cannot turn drawing on with a vague “images” request.
        let wantsDrawings = arguments["draw"] as? Bool ?? false
        let choosesPictures = arguments["choose"] as? Bool ?? true
        let replacing = arguments["replace"] as? Bool ?? false
        let maximumDrawings = chosen.reduce(into: 0) { total, quiz in
            let eligible: Int
            if choosesPictures {
                eligible = quiz.questions.filter { question in
                    replacing || question.picture == nil || question.picture?.isAwaitingDrawing == true
                }.count
            } else {
                eligible = quiz.questions.filter { $0.picture?.isAwaitingDrawing == true }.count
            }
            total += min(CourseQuizPictures.maximumDrawingsPerQuiz, eligible)
        }
        if wantsDrawings, maximumDrawings > 0,
           arguments["confirm_drawings"] as? Bool != true {
            let model = try await ImageGenerationDirectory.priced(MacImageGenerationSettings.model)
            var quote = "No generated pictures were started. Drawing can make up to \(maximumDrawings) separately billed image requests on \(model.name) (\(model.maker), through OpenRouter) for these quizzes."
            quote += model.drawingQuote(forUpTo: maximumDrawings, chooser: "the picker")
            quote += " Show this quote to the learner. Only after they explicitly agree, call again with draw true, confirm_drawings true, and their approved total in approved_spend_usd. Use draw false now to add lecture slides and reading figures without image-generation requests."
            throw MCPError.invalidInput(quote)
        }

        // The slides first, one lecture video at a time, as extract_video_slides
        // captures them; a video that cannot give slides is reported, not fatal.
        var captureNotes: [String] = []
        if arguments["capture_slides"] as? Bool ?? true {
            let lectureIDs = Set(chosen.flatMap(\.lectureIDs))
            let videos = try await storage.loadCourseLectureItems()
                .filter { lectureIDs.contains($0.lectureId) && $0.role == .video }
                .compactMap(\.sourceId)
            let videoIDs = Array(Set(videos)).sorted()
            for (index, sourceID) in videoIDs.enumerated() {
                await MCPToolActivityReporter.current?.report("Capturing slides, video \(index + 1) of \(videoIDs.count)")
                do {
                    _ = try await extractVideoSlides(sourceID: sourceID)
                } catch {
                    captureNotes.append("- \(sourceID): \(error.localizedDescription)")
                }
            }
        }

        let service = CourseQuizGeneratorService(storage: storage, aiService: AIService())
        let model = wantsDrawings ? MacImageGenerationSettings.model : nil
        let title = try await storage.loadCourseMetadata()[courseID]?.title ?? courseID
        let activity = MCPToolActivityReporter.current
        let progress: @Sendable (CourseQuizPicturePhase, Int, Int) async -> Void = { phase, done, total in
            await activity?.report("\(phase.rawValue) · \(done) of \(total) quizzes")
        }
        let result: CourseQuizPictureResult
        if choosesPictures {
            do {
                result = try await service.addQuestionPictures(
                    courseID: courseID,
                    quizIDs: only,
                    replacing: replacing,
                    drawingModel: model,
                    onProgress: progress
                )
            } catch let error as CourseQuizError {
                throw MCPError.invalidInput(error.localizedDescription)
            }
        } else {
            // Only the drawings already briefed: nothing new is chosen.
            var drawnOnly = CourseQuizPictureResult(courseID: courseID, outcomes: [])
            if let model {
                drawnOnly.drawing = await service.drawQuestionPictures(
                    courseID: courseID,
                    quizIDs: chosen.map(\.id),
                    courseTitle: title,
                    model: model,
                    onProgress: progress
                )
            }
            result = drawnOnly
        }
        var lines = ["Pictures for the quizzes of '\(title)': \(result.picturedCount) question\(result.picturedCount == 1 ? "" : "s") got a slide, a figure or a drawing briefed; \(result.drawing.drawnCount) picture\(result.drawing.drawnCount == 1 ? " was" : "s were") drawn."]
        if !wantsDrawings {
            lines.append("Nothing was drawn (draw false).")
        }
        let reported: [(quiz: CourseQuiz, outcome: CourseQuizPictureResult.Outcome)] = result.outcomes.isEmpty
            ? chosen.map { (quiz: $0, outcome: .nothingToPicture) }
            : result.outcomes
        for entry in reported {
            var status: String
            switch entry.outcome {
            case .pictured(let count): status = "\(count) question\(count == 1 ? "" : "s") got a picture"
            case .noneFitting: status = "no slide, figure or drawing helps any of its questions"
            case .nothingToPicture: status = result.outcomes.isEmpty ? "nothing new chosen (choose false)" : "nothing to picture (no captured slides or reading figures for its lectures, or every question has a picture)"
            case .failed(let message): status = "failed: \(message)"
            }
            if let drawn = result.drawing.drawn[entry.quiz.id] { status += "; \(drawn) drawn" }
            if let waiting = result.drawing.waiting[entry.quiz.id] { status += "; \(waiting) still to draw" }
            if let failure = result.drawing.failures[entry.quiz.id] { status += "; drawing failed: \(failure)" }
            lines.append("- \(entry.quiz.title) (quiz_id: \(entry.quiz.id)): \(status)")
        }
        if !captureNotes.isEmpty {
            lines.append("")
            lines.append("Lecture videos whose slides could not be captured:")
            lines += captureNotes
        }
        lines.append("")
        lines.append("get_course_quiz lists each question's picture.")
        return lines.joined(separator: "\n")
    }

    // MARK: get_course_quiz

    func getCourseQuiz(arguments: [String: Any]) throws -> String {
        let store = try knowledgeStore()
        let quiz = try Self.requireCourseQuiz(arguments["quiz_id"] as? String, store: store)
        let includeAnswers = arguments["include_answers"] as? Bool ?? false
        let sources = try store.loadActiveSources()
        let titles = Dictionary(sources.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let score = LectureQuizScore.scoresFromDefaults(prefix: LectureQuizScore.courseQuizPreferenceKeyPrefix)[quiz.id]
        let scoreLine: String
        if let score, !score.matches(questionCount: quiz.questions.count) {
            scoreLine = "previous version: \(score.label); current quiz has \(quiz.questions.count) questions"
        } else {
            scoreLine = score?.label ?? "not taken"
        }
        var lines = [
            "\(quiz.title) (quiz_id: \(quiz.id), kind: \(quiz.kind.rawValue), course_id: \(quiz.courseID))",
            "covers lecture_ids: \(quiz.lectureIDs.joined(separator: ", "))",
            "follows lecture_id: \(quiz.afterLectureID ?? "end of course")",
            "written by: \(quiz.author == .assistant ? "an assistant" : "ForeverLM"), updated \(KnowledgeStore.iso8601Formatter.string(from: quiz.updatedAt))",
            "symbol: \(quiz.symbol ?? "none"); picture: \(quiz.artwork == nil ? "none" : "drawn")",
            "latest sitting: \(scoreLine)",
            "",
        ]
        // The sitting under way, so an assistant goes on where the learner
        // stopped rather than from question 1.
        if let underWay = try Self.courseQuizSittingUnderWayLine(quiz, store: store) {
            lines.insert(underWay, at: lines.count - 1)
        }
        // Each question at the moment its quote is said, as the quiz's chat
        // sends the learner back to it (`CourseQuizPlanning.timedByQuotes`).
        var sourceLines: [String: [LectureQuizLine]] = [:]
        for sourceID in Set(quiz.questions.filter { $0.quote != nil && $0.page == nil }.compactMap(\.sourceID)) {
            if let content = try store.loadSourceContent(sourceID) {
                sourceLines[sourceID] = CourseQuizPlanning.lines(from: content)
            }
        }
        for (index, question) in CourseQuizPlanning.timedByQuotes(quiz.questions, lines: sourceLines).enumerated() {
            let tag = [question.id, question.level?.rawValue].compactMap { $0 }.joined(separator: " · ")
            var head = "\(index + 1). [\(tag)] \(question.question)"
            var about: [String] = []
            if let sourceID = question.sourceID {
                about.append("source_id: \(sourceID)")
                if let title = titles[sourceID] { about.append("lecture source: \(title)") }
            }
            if let seconds = question.startSeconds {
                about.append("at \(VideoQuizPlanning.timestamp(seconds))")
            } else if let page = question.page {
                about.append("page \(page)")
            }
            if !about.isEmpty { head += " (\(about.joined(separator: ", ")))" }
            lines.append(head)
            if let picture = question.picture {
                lines.append(Self.courseQuizPictureLine(picture, includeAnswers: includeAnswers))
            }
            if includeAnswers {
                lines.append("   Answer: \(question.answer)")
                if !question.keyPoints.isEmpty {
                    lines.append("   Key points: \(question.keyPoints.joined(separator: "; "))")
                }
            }
        }
        if !includeAnswers {
            lines.append("")
            lines.append("Answers are left out so the learner is not shown them; pass include_answers true to grade. Ask one question at a time, and record each answer with record_course_quiz_result as soon as it is graded: the sitting is kept as it goes, so a quiz stopped halfway loses nothing.")
        }
        return lines.joined(separator: "\n")
    }

    /// How `get_course_quiz` and `set_course_quiz_picture` describe a
    /// question's picture: where it is shown, its address and how to look at
    /// it. The caption of a picture that shows the answer, and the brief it
    /// was drawn from, stay out unless answers are asked for.
    static func courseQuizPictureLine(_ picture: CourseQuizPicture, includeAnswers: Bool) -> String {
        let hidesAnswer = picture.placement == .answer && !includeAnswers
        let caption = hidesAnswer ? nil : picture.caption
        if picture.isAwaitingDrawing {
            var line = "   Picture to be drawn by ForeverLM, to show with the \(picture.placement.rawValue): not drawn yet; add_course_quiz_pictures draws it"
            if !hidesAnswer, let brief = picture.brief { line += " (brief: \(brief))" }
            return line
        }
        if let id = picture.storedImageID {
            var line = "   Picture, shown with the \(picture.placement.rawValue): \(picture.image)"
            if let caption { line += " (\(caption))" }
            line += "; an image in ForeverLM's store, look at it with get_image image_id \(id)"
            if !hidesAnswer, let brief = picture.brief { line += "; drawn from: \(brief)" }
            return line
        }
        guard let reference = picture.reference else {
            return "   Picture, shown with the \(picture.placement.rawValue): \(picture.image) (an address this build cannot read)"
        }
        var line = "   Picture, shown with the \(picture.placement.rawValue): \(reference.urlString)"
        if let caption { line += " (\(caption))" }
        let crop = reference.crop == nil ? nil : URLComponents(string: reference.urlString)?.queryItems?.first(where: { $0.name == "crop" })?.value
        switch reference.location {
        case .moment(let seconds):
            line += "; show it with show_source_image source_id \(reference.sourceID), at \(seconds)"
        case .page(let page):
            line += "; show it with show_source_image source_id \(reference.sourceID), page \(page)"
        case .image(let ordinal):
            line += "; show it with show_source_image source_id \(reference.sourceID), image \(ordinal)"
        case .slide(let number):
            line += "; show it with show_source_image source_id \(reference.sourceID), slide \(number)"
        }
        if let crop { line += ", crop \(crop)" }
        return line
    }

    /// The version of an image in this Mac's store that a picture shows: the
    /// latest when `id` names the image, that one when it names a version.
    /// Nil when the store holds no such image. Reads the store's files.
    static func storedImageVersion(_ id: String) -> String? {
        guard let group = GeneratedImageStore.group(containing: id) else { return nil }
        let wanted = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return group.versions.first { $0.id == wanted && wanted != group.imageID }?.id ?? group.latest.id
    }

    /// A picture as an assistant passes it, checked against the library: a
    /// source's picture must come from a source the library holds, and a
    /// stored image must be on this Mac.
    static func courseQuizPicture(
        _ raw: Any?,
        sourceID: String?,
        knownSources: Set<String>,
        label: String
    ) throws -> CourseQuizPicture? {
        let picture: CourseQuizPicture?
        switch CourseQuizPicture.parse(raw, sourceID: sourceID, resolveStoredImage: storedImageVersion) {
        case .success(let parsed): picture = parsed
        case .failure(let error): throw MCPError.invalidInput("\(label): \(error.message)")
        }
        if let pictured = picture?.reference?.sourceID, !knownSources.contains(pictured) {
            throw MCPError.invalidInput("\(label)'s picture is from \(pictured), which is not in the library.")
        }
        return picture
    }

    // MARK: set_course_quiz_picture

    /// Pins one question's picture, replaces it or takes it away, leaving the
    /// question and the rest of the quiz as they are: ids, scores and Memory
    /// items stay. The picture is the same object `save_course_quiz` takes.
    func setCourseQuizPicture(arguments: [String: Any]) throws -> String {
        let store = try knowledgeStore()
        var quiz = try Self.requireCourseQuiz(arguments["quiz_id"] as? String, store: store)
        guard let questionID = Self.nilIfBlank(arguments["question_id"] as? String ?? ""),
              let index = quiz.questions.firstIndex(where: { $0.id == questionID }) else {
            let ids = quiz.questions.prefix(8).map(\.id).joined(separator: ", ")
            throw MCPError.invalidInput("question_id must be one of the quiz's question ids, as get_course_quiz lists them in brackets (\(ids)\(quiz.questions.count > 8 ? ", …" : "")).")
        }
        let question = quiz.questions[index]
        let removing = arguments["remove"] as? Bool ?? false
        if removing {
            guard question.picture != nil else {
                return "Question \(index + 1) of \(quiz.title) has no picture; nothing changed."
            }
            quiz.questions[index].picture = nil
        } else {
            guard arguments["picture"] != nil else {
                throw MCPError.invalidInput("picture is required, or remove true to take the question's picture away.")
            }
            let knownSources = Set(try store.loadActiveSources().map(\.id))
            quiz.questions[index].picture = try Self.courseQuizPicture(
                arguments["picture"],
                sourceID: question.sourceID,
                knownSources: knownSources,
                label: "Question \(index + 1)"
            )
        }
        quiz.updatedAt = Date()
        try store.saveCourseQuiz(quiz)
        guard let picture = quiz.questions[index].picture else {
            return "Removed the picture of question \(index + 1) of \(quiz.title); the tutor may still show a slide or figure it finds."
        }
        return [
            "Set the picture of question \(index + 1) of \(quiz.title):",
            Self.courseQuizPictureLine(picture, includeAnswers: true),
        ].joined(separator: "\n")
    }

    // MARK: save_course_quiz

    func saveCourseQuiz(arguments: [String: Any]) throws -> String {
        let store = try knowledgeStore()
        let courseID = try resolveExistingCourseID(input: arguments["course_id"] as? String ?? "", store: store)
        let lectures = try store.loadCourseLectures()
            .filter { $0.courseName == courseID }
            .sorted { $0.number < $1.number }
        let lectureIDs = Set(lectures.map(\.id))
        guard let kindName = arguments["kind"] as? String, let kind = CourseQuiz.Kind(rawValue: kindName) else {
            throw MCPError.invalidInput("kind must be practice, checkpoint or test.")
        }
        var covered = (arguments["lecture_ids"] as? [String]) ?? []
        let after = Self.nilIfBlank(arguments["after_lecture_id"] as? String ?? "")
        switch kind {
        case .practice:
            if covered.isEmpty, let after { covered = [after] }
            guard covered.count == 1 else {
                throw MCPError.invalidInput("A practice quiz is about one lecture: pass its lecture_id in lecture_ids.")
            }
        case .checkpoint:
            guard !covered.isEmpty else {
                throw MCPError.invalidInput("A checkpoint quiz needs lecture_ids: the lectures it covers.")
            }
        case .test:
            if covered.isEmpty { covered = lectures.map(\.id) }
        }
        let unknown = covered.filter { !lectureIDs.contains($0) } + [after].compactMap { $0 }.filter { !lectureIDs.contains($0) }
        guard unknown.isEmpty else {
            throw MCPError.invalidInput("\(unknown.joined(separator: ", ")) \(unknown.count == 1 ? "is not a lecture" : "are not lectures") of course \(courseID). Call get_course for its lecture ids.")
        }
        let order = Dictionary(lectures.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        covered = Array(Set(covered)).sorted { (order[$0] ?? 0) < (order[$1] ?? 0) }

        guard let rawQuestions = arguments["questions"] as? [[String: Any]], !rawQuestions.isEmpty else {
            throw MCPError.invalidInput("questions is required: at least one {question, answer}.")
        }
        guard rawQuestions.count <= CourseQuizPlanning.maximumQuestionsPerQuiz else {
            throw MCPError.invalidInput("A quiz has at most \(CourseQuizPlanning.maximumQuestionsPerQuiz) questions.")
        }
        // The learning points come first and every one gets a question
        // (product owner, 2026-09-27: first "identify all the key points in the
        // video … and then make questions for all of them").
        let learningPoints = ((arguments["learning_points"] as? [String]) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !learningPoints.isEmpty else {
            throw MCPError.invalidInput("learning_points is required: before writing questions, read the lecture video's whole transcript and its readings, and list every key point and fact worth remembering, one short sentence each, then give every point a question.")
        }
        var tested = Set<Int>()
        let knownSources = Set(try store.loadActiveSources().map(\.id))
        // An assistant's question names no lines, so its quote is the only
        // Memory anchor it has (`CourseQuizPlanning.memoryExcerpts`): one the
        // source's text does not contain, or none, is a question whose miss
        // can never come back in review. The writer hears it while the
        // source is open, rather than from the quiz's tutor when the learner
        // misses the question. A source with no text yet has nothing to
        // quote.
        //
        // The same quote times the question: Rewatch opens where the lecture
        // says it (`LectureQuizTimeline`), which the transcript's markers,
        // thirty seconds apart, cannot tell an assistant.
        var groundingBySource: [String: (text: MemoryGroundingText, timeline: LectureQuizTimeline?)?] = [:]
        func grounding(_ sourceID: String) throws -> (text: MemoryGroundingText, timeline: LectureQuizTimeline?)? {
            if let known = groundingBySource[sourceID] { return known }
            var found: (text: MemoryGroundingText, timeline: LectureQuizTimeline?)?
            if let content = try store.loadSourceContent(sourceID) {
                let text = MemoryGroundingText(content)
                let timeline = LectureQuizTimeline(CourseQuizPlanning.lines(from: content))
                if !text.isEmpty { found = (text: text, timeline: timeline.isTimed ? timeline : nil) }
            }
            groundingBySource[sourceID] = .some(found)
            return found
        }
        var unanchored: [String] = []
        var questions: [CourseQuizQuestion] = []
        for (index, raw) in rawQuestions.enumerated() {
            let text = (raw["question"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let answer = (raw["answer"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !answer.isEmpty else {
                throw MCPError.invalidInput("Question \(index + 1) needs both question and answer.")
            }
            let points = ((raw["points"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue }
            guard !points.isEmpty else {
                throw MCPError.invalidInput("Question \(index + 1) needs points: the numbers of the learning points it tests, counting from 1.")
            }
            if let wrong = points.first(where: { !(1...learningPoints.count).contains($0) }) {
                throw MCPError.invalidInput("Question \(index + 1) names learning point \(wrong), but there are \(learningPoints.count), numbered from 1.")
            }
            tested.formUnion(points)
            let sourceID = Self.nilIfBlank(raw["source_id"] as? String ?? "")
            if let sourceID, !knownSources.contains(sourceID) {
                throw MCPError.invalidInput("Question \(index + 1)'s source_id \(sourceID) is not in the library.")
            }
            let keyPoints = ((raw["key_points"] as? [String]) ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let startSeconds = (raw["start_seconds"] as? NSNumber)?.doubleValue
            let page = (raw["page"] as? NSNumber)?.intValue
            if let page, page < 1 {
                throw MCPError.invalidInput("Question \(index + 1)'s page must be 1 or more, counted from the source's first page.")
            }
            let level = Self.nilIfBlank(raw["level"] as? String ?? "")?.lowercased()
            if let level, CourseQuizQuestion.Level(rawValue: level) == nil {
                throw MCPError.invalidInput("Question \(index + 1)'s level must be recall, explain, apply or challenge.")
            }
            let picture = try Self.courseQuizPicture(
                raw["picture"],
                sourceID: sourceID,
                knownSources: knownSources,
                label: "Question \(index + 1)"
            )
            let quote = Self.nilIfBlank(raw["quote"] as? String ?? "")
            var quoteSeconds: Double?
            if let sourceID, let source = try grounding(sourceID) {
                if let quote {
                    if !source.text.contains(quote) { unanchored.append("Question \(index + 1): \"\(quote)\" is not in the source's text") }
                    quoteSeconds = source.timeline?.seconds(saying: quote)
                } else {
                    unanchored.append("Question \(index + 1): no quote")
                }
            }
            questions.append(CourseQuizQuestion(
                id: "",
                sourceID: sourceID,
                firstLine: nil,
                lastLine: nil,
                startSeconds: quoteSeconds ?? startSeconds.flatMap { $0 >= 0 ? $0 : nil },
                question: text,
                answer: answer,
                keyPoints: keyPoints,
                quote: quote,
                levelName: level,
                picture: picture,
                page: page
            ))
        }
        let untested = learningPoints.indices.filter { !tested.contains($0 + 1) }
        guard untested.isEmpty else {
            let listed = untested.prefix(10).map { "\($0 + 1). \(learningPoints[$0])" }.joined(separator: "\n")
            throw MCPError.invalidInput("\(untested.count) of \(learningPoints.count) learning points have no question; give each at least one and save again:\n\(listed)\(untested.count > 10 ? "\n…" : "")")
        }
        guard unanchored.isEmpty else {
            let listed = unanchored.prefix(10).joined(separator: "\n")
            throw MCPError.invalidInput("\(unanchored.count) of \(questions.count) questions have no Memory anchor, so a miss on them could never come back in review. Give each a quote: eight to twenty-five words in a row, copied from its source's text as get_source_content returns it, and save again:\n\(listed)\(unanchored.count > 10 ? "\n…" : "")")
        }

        let id: String
        if let given = Self.nilIfBlank(arguments["quiz_id"] as? String ?? "") {
            if let existing = try store.loadCourseQuiz(given), existing.courseID != courseID {
                throw MCPError.invalidInput("quiz_id \(given) belongs to another course.")
            }
            id = given
        } else {
            switch kind {
            case .practice: id = CourseQuizPlanning.practiceID(courseID: courseID, lectureID: covered[0])
            case .checkpoint: id = CourseQuizPlanning.checkpointID(courseID: courseID, lectureIDs: covered)
            case .test: id = CourseQuizPlanning.testID(courseID: courseID)
            }
        }
        let previous = try store.loadCourseQuiz(id)
        let defaultTitle: String
        switch kind {
        case .practice:
            let lecture = lectures.first { $0.id == covered[0] }
            defaultTitle = "Quiz: \(lecture?.title ?? "Lecture \(lecture?.number ?? 0)")"
        case .checkpoint: defaultTitle = "Quiz"
        case .test: defaultTitle = "Course test"
        }
        let now = Date()
        let quiz = CourseQuiz(
            id: id,
            courseID: courseID,
            kind: kind,
            title: Self.nilIfBlank(arguments["title"] as? String ?? "") ?? previous?.title ?? defaultTitle,
            lectureIDs: covered,
            afterLectureID: after ?? covered.last,
            // Named by what each asks; one the replaced quiz asked keeps its
            // id, and so its Memory item, wherever it now sits.
            questions: CourseQuizPlanning.identified(questions, previous: previous?.questions ?? []),
            author: .assistant,
            createdAt: previous?.createdAt ?? now,
            updatedAt: now,
            symbol: CourseQuizGeneratorService.availableSymbol(arguments["symbol"] as? String) ?? previous?.symbol,
            artwork: previous?.artwork
        )
        try store.saveCourseQuiz(quiz)
        let pictured = questions.filter { $0.picture?.isShowable == true }.count
        let briefed = questions.filter { $0.picture?.isAwaitingDrawing == true }.count
        let drawing = briefed == 0 ? "" : ", \(briefed) with a picture briefed for ForeverLM to draw (add_course_quiz_pictures with choose false draws them)"
        // Named by title and lecture number; the quiz's id, new on a first
        // save, rides on its own line (Prompts.hiddenIDs).
        let placement = quiz.afterLectureID
            .flatMap { after in lectures.first { $0.id == after } }
            .map { "following lecture \($0.number)" } ?? "at the end"
        let courseTitle = try store.loadCourseGroups()[courseID]?.title ?? courseID
        return "\(previous == nil ? "Saved" : "Replaced") \(quiz.title) (kind: \(kind.rawValue), \(questions.count) questions on \(learningPoints.count) learning points, \(pictured) with a picture\(drawing)), \(placement) in course '\(courseTitle)'.\nquiz_id: \(quiz.id)"
    }

    // MARK: delete_course_quiz

    func deleteCourseQuiz(arguments: [String: Any]) throws -> String {
        let store = try knowledgeStore()
        let quiz = try Self.requireCourseQuiz(arguments["quiz_id"] as? String, store: store)
        try store.deleteCourseQuiz(quiz.id)
        let courseTitle = try store.loadCourseGroups()[quiz.courseID]?.title ?? quiz.courseID
        return "Removed \(quiz.title) from course '\(courseTitle)'. generate_course_quizzes writes a ForeverLM quiz again when asked."
    }

    // MARK: rename_course_quiz

    func renameCourseQuiz(arguments: [String: Any]) throws -> String {
        let store = try knowledgeStore()
        var quiz = try Self.requireCourseQuiz(arguments["quiz_id"] as? String, store: store)
        guard let title = CourseQuizNaming.cleanTitle(arguments["title"] as? String) else {
            throw MCPError.invalidInput("title is required: a few words naming the topics the quiz covers.")
        }
        let previous = quiz.title
        quiz.title = title
        if let symbol = CourseQuizGeneratorService.availableSymbol(arguments["symbol"] as? String) {
            quiz.symbol = symbol
        }
        quiz.updatedAt = Date()
        try store.saveCourseQuiz(quiz)
        let courseTitle = try store.loadCourseGroups()[quiz.courseID]?.title ?? quiz.courseID
        return "Renamed \(previous) to \(quiz.title) (symbol: \(quiz.symbol ?? "none")) in course '\(courseTitle)'."
    }

    // MARK: record_course_quiz_result

    /// Records answers into a sitting of the quiz as the quiz goes (product owner,
    /// 2026-09-27: "please make sure the results can be pushed iteratively").
    /// The sitting is kept the way the app keeps one
    /// (docs/lecture-quiz-design.md, "Taking a quiz"): a chat named for the
    /// quiz (`CourseQuizSitting.sessionID`) whose briefing holds the grades
    /// and skips, and whose exchanges hold each question, the learner's answer
    /// and the feedback. So the quiz's row reads In progress while an
    /// assistant quizzes, Continue Quiz picks the sitting up in the app on any
    /// Mac, and a chat that stops halfway keeps what it recorded. A call adds
    /// to the sitting `sitting_id` names, else to the quiz's sitting under
    /// way, else to a new one; the score is kept once every question has an
    /// outcome, or when `finish` ends the sitting early.
    func recordCourseQuizResult(arguments: [String: Any]) async throws -> String {
        let store = try knowledgeStore()
        let quiz = try Self.requireCourseQuiz(arguments["quiz_id"] as? String, store: store)
        guard let rawResults = arguments["results"] as? [[String: Any]], !rawResults.isEmpty else {
            throw MCPError.invalidInput("results is required: one {question_id, outcome} for each question answered since the last call.")
        }
        // Every result is read before anything is written, so a call with one
        // bad result records nothing.
        let byID = Dictionary(quiz.questions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let numbers = Dictionary(quiz.questions.enumerated().map { ($0.element.id, $0.offset + 1) }, uniquingKeysWith: { first, _ in first })
        var results: [CourseQuizRecordedResult] = []
        for (index, result) in rawResults.enumerated() {
            guard let questionID = result["question_id"] as? String, let question = byID[questionID] else {
                throw MCPError.invalidInput("Result \(index + 1) names no question of this quiz; pass each question's id as get_course_quiz lists it, in brackets before the question.")
            }
            guard let outcomeName = (result["outcome"] as? String)?.lowercased(),
                  let outcome = Self.courseQuizOutcome(outcomeName) else {
                throw MCPError.invalidInput("Result \(index + 1)'s outcome must be correct, partial, incorrect, remembered, forgot or skipped.")
            }
            results.append(CourseQuizRecordedResult(
                question: question,
                number: numbers[questionID] ?? index + 1,
                outcomeName: outcomeName,
                outcome: outcome,
                answer: Self.nilIfBlank(result["answer"] as? String ?? ""),
                feedback: Self.nilIfBlank(result["feedback"] as? String ?? "")
            ))
        }
        let finish = arguments["finish"] as? Bool ?? false
        let target = try courseQuizSittingToRecord(quiz: quiz, arguments: arguments, store: store)

        var sitting = target.sitting
        var regraded: Set<String> = []
        for result in results {
            let question = result.question
            if let verdict = Self.sittingVerdict(for: result.outcome) {
                if sitting.grades[question.id]?.question == question.question { regraded.insert(question.id) }
                sitting.grades[question.id] = CourseQuizSitting.Grade(verdict: verdict, question: question.question)
                sitting.skipped?[question.id] = nil
            } else if sitting.grades[question.id]?.question != question.question {
                // A skip never takes back a grade the sitting already has.
                var skipped = sitting.skipped ?? [:]
                skipped[question.id] = question.question
                sitting.skipped = skipped
            }
            if sitting.followUp?.questionID == question.id { sitting.followUp = nil }
        }
        if finish {
            // What the learner never answered counts as skipped, as a skip in
            // the app does: no grade, nothing in Memory, not right.
            let settled = Set(sitting.verdicts(for: quiz).keys).union(sitting.skips(for: quiz))
            var skipped = sitting.skipped ?? [:]
            for question in quiz.questions where !settled.contains(question.id) {
                skipped[question.id] = question.question
            }
            sitting.skipped = skipped
            sitting.followUp = nil
        }
        if sitting.skipped?.isEmpty == true { sitting.skipped = nil }

        // The chat: its sitting, then this call's questions and answers, which
        // keep it from reading as an abandoned empty chat when it is opened.
        let now = Date()
        if target.isNew {
            let chat = try newCourseQuizSittingChat(quiz, store: store)
            try store.createReviewSession(
                id: target.sessionID,
                topic: chat.topic,
                sourceIDs: chat.sourceIDs,
                startedAt: now,
                scheduleActivityAt: chat.sourceIDs.isEmpty ? nil : now,
                scheduleActivityKind: .review,
                briefing: sitting.briefingText,
                chatKind: .quizSitting
            )
        } else {
            try store.setReviewSessionBriefing(sessionID: target.sessionID, briefing: sitting.briefingText)
        }
        _ = try store.appendReviewChatExchanges(
            sessionID: target.sessionID,
            turns: results.map { result in
                ReviewChatTurn(
                    question: "Question \(result.number) of \(quiz.questions.count): \(result.question.question)",
                    answer: result.answer ?? (result.outcome == .skipped ? "(skipped)" : "(answer not recorded)"),
                    evaluation: result.feedback ?? Self.courseQuizOutcomeLabel(result.outcome)
                )
            },
            sourceIDs: [],
            summary: nil,
            overallScore: nil,
            modelProvider: nil,
            modelID: nil
        )

        var memoryNotes: [String] = []
        var linesBySource: [String: [LectureQuizLine]] = [:]
        for result in results {
            guard let (score, rating) = Self.memoryGrade(for: result.outcome), let sourceID = result.question.sourceID else { continue }
            if linesBySource[sourceID] == nil {
                linesBySource[sourceID] = (try store.loadSourceContent(sourceID)).map(CourseQuizPlanning.lines(from:)) ?? []
            }
            guard let memoryQuestion = CourseQuizPlanning.memoryQuestion(
                quizID: quiz.id, question: result.question, lines: linesBySource[sourceID] ?? []
            ) else { continue }
            // A graded Memory attempt needs the learner's words; a caller that
            // sends only the outcome gets a line saying so, or nothing lands.
            do {
                try store.recordSourceQuestionAttempt(
                    memoryQuestion,
                    answer: result.answer ?? "(answer not recorded; marked \(result.outcomeName))",
                    feedback: result.feedback ?? result.outcomeName,
                    score: score,
                    rating: rating
                )
            } catch {
                memoryNotes.append("\(result.question.id): not saved to Memory (\(error.localizedDescription))")
            }
        }

        let recorded = results.map { result in
            "question \(result.number) \(result.outcomeName)" + (regraded.contains(result.question.id) ? " (regraded)" : "")
        }
        var lines = [
            "\(target.isNew ? "Started a sitting of" : "Recorded in the sitting of") \(quiz.title): \(recorded.joined(separator: ", ")).",
            // The sitting's id on its own line, for a later call's sitting_id
            // (Prompts.hiddenIDs).
            "sitting_id: \(target.sessionID)",
        ]
        let progress = sitting.progress(for: quiz, sessionID: target.sessionID, takenAt: now)
        guard let sittingScore = progress.score else {
            let verdicts = sitting.verdicts(for: quiz)
            let skips = sitting.skips(for: quiz)
            let right = verdicts.values.filter { $0 == .correct }.count
            var standing = "\(progress.done) of \(progress.total) questions done, \(right) right so far"
            if let next = quiz.questions.enumerated().first(where: { verdicts[$0.element.id] == nil && !skips.contains($0.element.id) }) {
                standing += "; next unanswered: question \(next.offset + 1) [\(next.element.id)]"
            }
            lines.append(standing + ". Misses are in Memory already, and the quiz's row in the course shows the sitting under way; the learner can go on with it in the app too.")
            lines.append("Record each next answer the same way: with this sitting_id, or without one, which goes on with the sitting under way. The sitting completes once every question has an outcome; pass finish true if the learner stops, and the questions left count as skipped.")
            lines.append(contentsOf: memoryNotes)
            return lines.joined(separator: "\n")
        }

        // The quiz's first pass is kept with the new sitting, as the app keeps
        // it (`StudioViewModel.recordCourseQuizScore`): a worse retake leaves
        // the lectures after the quiz open.
        let scoreKey = Prefs.Families.courseQuizScore.key(quiz.id)
        let previous = Preferences.value(scoreKey).flatMap(LectureQuizScore.init(preferenceValue:))
        let score = LectureQuizScore(right: sittingScore.right, total: sittingScore.total, takenAt: now)
            .recorded(after: previous)
        Preferences.set(score.preferenceValue, for: scoreKey)
        // A correction to a completed sitting completes it again, with the
        // score it has now.
        try store.completeReviewSession(sessionID: target.sessionID, overallScore: score.fractionRight, summary: score.label)
        await PreferenceStore.flushPendingWrites()
        lines.append("Recorded \(quiz.title): \(score.label). The quiz's row in the course shows it; missed questions come back in Memory review. Pass this sitting_id to correct an answer.")
        // The course gate (docs/courses-design.md): finishing the sitting opens
        // what follows; passing remains a separate mastery signal.
        if score.hasPassed {
            lines.append("Completed and passed: what comes after this quiz in the course is open.")
        } else {
            lines.append("Completed: what comes after this quiz in the course is open. A pass needs \(LectureQuizScore.rightNeededToPass(total: score.total)) of \(score.total) right; the learner can retake it any time.")
        }
        lines.append(contentsOf: memoryNotes)
        return lines.joined(separator: "\n")
    }

    /// Where a record call writes: the sitting `sitting_id` names, else the
    /// quiz's newest sitting still under way, as the app's Continue Quiz picks
    /// it up (`CourseQuizOpening`), else a new sitting, which `new_sitting`
    /// asks for outright. A new sitting's chat is created with its first
    /// answers, never empty.
    private func courseQuizSittingToRecord(
        quiz: CourseQuiz,
        arguments: [String: Any],
        store: KnowledgeStore
    ) throws -> (sessionID: String, sitting: CourseQuizSitting, isNew: Bool) {
        let startOver = arguments["new_sitting"] as? Bool ?? false
        let named = Self.reviewSessionID(from: arguments["sitting_id"])
        let rows = try store.loadCourseQuizSittingRows()
        if !named.isEmpty {
            guard !startOver else {
                throw MCPError.invalidInput("Pass sitting_id to add to that sitting, or new_sitting true to start another, not both.")
            }
            guard CourseQuizSitting.quizID(inSessionID: named) == quiz.id,
                  let row = rows.first(where: { $0.sessionID == named }) else {
                throw MCPError.invalidInput("\(named) is no sitting of \(quiz.title). Leave sitting_id out to go on with the quiz's sitting under way, or to start one.")
            }
            let sitting = CourseQuizSitting(briefing: row.briefing) ?? CourseQuizSitting(quizID: quiz.id)
            guard sitting.canResume(in: quiz) else {
                throw MCPError.invalidInput("Sitting \(named) answered an earlier version of \(quiz.title), whose questions have all been rewritten since. Leave sitting_id out to start a new sitting.")
            }
            return (named, sitting, false)
        }
        if !startOver,
           let open = CourseQuizSitting.latest(rows: rows, quizzes: [quiz])[quiz.id], !open.isFinished,
           let sitting = rows.first(where: { $0.sessionID == open.sessionID }).flatMap({ CourseQuizSitting(briefing: $0.briefing) }) {
            return (open.sessionID, sitting, false)
        }
        return (CourseQuizSitting.sessionID(forQuizID: quiz.id), CourseQuizSitting(quizID: quiz.id), true)
    }

    /// A new sitting's chat, named and sourced as the app's Take Quiz names
    /// it (`StudioViewModel.courseQuizChatRequest`): the lecture sources its
    /// questions rest on, without a planned textbook reading's chapter.
    private func newCourseQuizSittingChat(_ quiz: CourseQuiz, store: KnowledgeStore) throws -> (topic: String, sourceIDs: [String]) {
        let courseTitle = try store.loadCourseGroups()[quiz.courseID]?.title ?? quiz.courseID
        let topic = quiz.kind == .test
            ? "\(courseTitle): \(quiz.title)"
            : (quiz.hasTopicTitle ? "Quiz: \(quiz.title)" : quiz.title)
        let books = Set(try store.loadActiveSources().filter { $0.sourceType == .book }.map(\.id))
        var sourceIDs: [String] = []
        for sourceID in quiz.questions.compactMap(\.sourceID) where !books.contains(sourceID) && !sourceIDs.contains(sourceID) {
            sourceIDs.append(sourceID)
        }
        return (topic, sourceIDs)
    }

    /// The quiz's sitting under way, for get_course_quiz, so an assistant goes
    /// on where the learner stopped, in the app or in another chat; nil when
    /// no sitting has an answer yet or the latest one is complete.
    static func courseQuizSittingUnderWayLine(_ quiz: CourseQuiz, store: KnowledgeStore) throws -> String? {
        let rows = try store.loadCourseQuizSittingRows()
        guard let open = CourseQuizSitting.latest(rows: rows, quizzes: [quiz])[quiz.id], open.isUnderWay,
              let sitting = rows.first(where: { $0.sessionID == open.sessionID }).flatMap({ CourseQuizSitting(briefing: $0.briefing) })
        else { return nil }
        let verdicts = sitting.verdicts(for: quiz)
        let skips = sitting.skips(for: quiz)
        let numbered = quiz.questions.enumerated().map { (number: $0.offset + 1, id: $0.element.id) }
        let graded = numbered.filter { verdicts[$0.id] != nil }.map { String($0.number) }
        let skipped = numbered.filter { skips.contains($0.id) }.map { String($0.number) }
        let right = verdicts.values.filter { $0 == .correct }.count
        var line = "sitting under way: \(open.done) of \(open.total) done, \(right) right (sitting_id: \(open.sessionID))"
        if !graded.isEmpty { line += "; graded: questions \(graded.joined(separator: ", "))" }
        if !skipped.isEmpty { line += "; skipped: questions \(skipped.joined(separator: ", "))" }
        if let next = numbered.first(where: { verdicts[$0.id] == nil && !skips.contains($0.id) }) {
            line += "; go on from question \(next.number) and record into this sitting, unless the learner wants to start over (new_sitting)"
        }
        return line
    }

    /// A result as the sitting keeps it; nil for a skip. A self-graded answer
    /// counts as `LectureQuizOutcome.isRight` counts it: remembered is right.
    static func sittingVerdict(for outcome: LectureQuizOutcome) -> VideoQuizVerdict? {
        switch outcome {
        case .graded(let verdict): return verdict
        case .remembered: return .correct
        case .forgot: return .incorrect
        case .skipped: return nil
        }
    }

    /// The grade line a sitting's chat shows when the caller sent no feedback.
    static func courseQuizOutcomeLabel(_ outcome: LectureQuizOutcome) -> String {
        switch outcome {
        case .graded(.correct): return "Right."
        case .graded(.partial): return "Partly right."
        case .graded(.incorrect): return "Not right."
        case .remembered: return "Remembered."
        case .forgot: return "Forgot."
        case .skipped: return "Skipped."
        }
    }

    // MARK: Helpers

    static func requireCourseQuiz(_ id: String?, store: KnowledgeStore) throws -> CourseQuiz {
        guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            throw MCPError.invalidInput("quiz_id is required. Call get_course for the course's quiz ids.")
        }
        guard let quiz = try store.loadCourseQuiz(id) else {
            throw MCPError.invalidInput("No course quiz \(id). Call get_course for the course's quiz ids.")
        }
        return quiz
    }

    static func courseQuizOutcome(_ name: String) -> LectureQuizOutcome? {
        switch name.lowercased() {
        case "correct": return .graded(.correct)
        case "partial": return .graded(.partial)
        case "incorrect": return .graded(.incorrect)
        case "remembered": return .remembered
        case "forgot": return .forgot
        case "skipped": return .skipped
        default: return nil
        }
    }

    /// How an outcome lands on the question's Memory item; nil for a skip.
    static func memoryGrade(for outcome: LectureQuizOutcome) -> (score: Double, rating: MemoryScheduleRating)? {
        switch outcome {
        case .graded(let verdict): return (verdict.score, verdict.scheduleRating)
        case .remembered: return (1, .good)
        case .forgot: return (0, .again)
        case .skipped: return nil
        }
    }
}

/// One result of a `record_course_quiz_result` call, read and checked before
/// anything is written.
private struct CourseQuizRecordedResult {
    let question: CourseQuizQuestion
    /// Its place in the quiz, counted from 1.
    let number: Int
    let outcomeName: String
    let outcome: LectureQuizOutcome
    let answer: String?
    let feedback: String?
}
