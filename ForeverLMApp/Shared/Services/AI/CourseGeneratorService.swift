import Foundation
import OSLog

/// The model-facing half of course generation, so the pipeline can run in a
/// test with no provider and no network.
///
/// Storage is not abstracted: the pipeline writes to a real `StorageService`
/// (a temporary one in tests), because what a generated course *is* in the
/// database is the thing worth pinning.
protocol CourseGenerationModelBackend: Sendable {
    /// A query vector for hybrid search, or nil to search lexically only.
    func embedQuery(_ text: String) async throws -> [Float]?
    /// A web investigation of the topic, or nil when the caller did not ask for
    /// one. Throws when asked for and unavailable.
    func research(request: CourseGenerationRequest) async throws -> DeepResearchReport?
    func plan(
        request: CourseGenerationRequest,
        briefs: [CourseSourceBrief],
        researchNotes: String?
    ) async throws -> CourseBlueprint
    func writeLesson(
        blueprint: CourseBlueprint,
        moduleIndex: Int,
        request: CourseGenerationRequest,
        briefs: [CourseSourceBrief],
        contents: [String: String],
        researchNotes: String?
    ) async throws -> CourseLessonDraft
}

/// The shipped backend: every step is an `AITask` whose model the learner picked
/// in Settings. A missing configuration is an error at the step that needs it,
/// so a course never starts on a model that cannot finish it.
struct LiveCourseGenerationModelBackend: CourseGenerationModelBackend {
    let aiService: AIService

    func embedQuery(_ text: String) async throws -> [Float]? {
        try await aiService.embedText(text)
    }

    func research(request: CourseGenerationRequest) async throws -> DeepResearchReport? {
        guard request.usesWeb else { return nil }
        guard let config = KeychainService.resolveConfig(for: .deepResearch) else {
            throw CourseGenerationError.noModelConfigured(.deepResearch)
        }
        let question = request.learnerNotes.isEmpty
            ? request.topic
            : "\(request.topic) — for a learner who says: \(request.learnerNotes)"
        return try await DeepResearchService(aiService: aiService).run(question: question, config: config)
    }

    func plan(
        request: CourseGenerationRequest,
        briefs: [CourseSourceBrief],
        researchNotes: String?
    ) async throws -> CourseBlueprint {
        guard let config = KeychainService.resolveConfig(for: .courseCurriculumPlan) else {
            throw CourseGenerationError.noModelConfigured(.courseCurriculumPlan)
        }
        return try await aiService.planCourse(
            request: request,
            briefs: briefs,
            researchNotes: researchNotes,
            config: config
        )
    }

    func writeLesson(
        blueprint: CourseBlueprint,
        moduleIndex: Int,
        request: CourseGenerationRequest,
        briefs: [CourseSourceBrief],
        contents: [String: String],
        researchNotes: String?
    ) async throws -> CourseLessonDraft {
        guard let config = KeychainService.resolveConfig(for: .courseLessonWriting) else {
            throw CourseGenerationError.noModelConfigured(.courseLessonWriting)
        }
        return try await aiService.writeCourseLesson(
            blueprint: blueprint,
            moduleIndex: moduleIndex,
            request: request,
            briefs: briefs,
            contents: contents,
            researchNotes: researchNotes,
            config: config
        )
    }
}

/// Turns a topic into a course: gathers sources, plans, writes, saves, and
/// optionally schedules. See docs/course-generation-design.md.
///
/// Nothing is written until every lesson has been written: model failures
/// happen before the first row, so a failed run leaves no half-course behind.
/// Web imports are the one exception — an imported page is a library source in
/// its own right and stays even when the course that wanted it fails.
struct CourseGeneratorService: Sendable {
    /// Imports one cited web page and returns its library source id, or nil
    /// when the page was skipped. The Mac passes the view model's importer; MCP
    /// passes its own. Throwing skips the page and continues.
    typealias WebImporter = @Sendable (DeepResearchCandidate) async throws -> String?
    /// Ranks the library for a query and returns source ids, best first. The
    /// default is the store's hybrid search; a test that has just saved its
    /// fixtures, before the background indexer has seen them, supplies its own.
    typealias LibrarySearch = @Sendable (_ query: String, _ vector: [Float]?, _ limit: Int) async -> [String]

    let storage: StorageService
    let backend: any CourseGenerationModelBackend
    let importWebSource: WebImporter?
    let librarySearch: LibrarySearch?

    /// How many library hits the planner is shown.
    static let librarySearchLimit = 24
    /// How many web citations are imported for one course.
    static let webImportLimit = 8
    /// The institution stamped on a generated course, which is how the sidebar
    /// and MCP can tell it from an imported one without a schema change.
    static let institution = "ForeverLM"

    private static let logger = Logger(subsystem: "com.foreverlm", category: "CourseGeneration")

    init(
        storage: StorageService,
        backend: any CourseGenerationModelBackend,
        importWebSource: WebImporter? = nil,
        librarySearch: LibrarySearch? = nil
    ) {
        self.storage = storage
        self.backend = backend
        self.importWebSource = importWebSource
        self.librarySearch = librarySearch
    }

    func run(
        request: CourseGenerationRequest,
        onProgress: @MainActor @Sendable (CourseGenerationProgress) -> Void = { _ in }
    ) async throws -> CourseGenerationResult {
        guard !request.topic.isEmpty else { throw CourseGenerationError.emptyTopic }
        let workflowID = "course-generation-\(UUID().uuidString.lowercased())"
        return try await AIUsageAttribution.$sessionID.withValue(workflowID) {
            try await AIUsageAttribution.$activityID.withValue(workflowID) {
                try await runStages(request: request, onProgress: onProgress)
            }
        }
    }

    // MARK: - Stages

    private func runStages(
        request: CourseGenerationRequest,
        onProgress: @MainActor @Sendable (CourseGenerationProgress) -> Void
    ) async throws -> CourseGenerationResult {
        var completed = 0
        // Gather, plan, save, plus research and import when the web is on,
        // plus scheduling when asked; module writing is added once the plan
        // says how many modules there are.
        var total = 3 + (request.usesWeb ? 2 : 0) + (request.scheduleStart == nil ? 0 : 1)
        func report(_ stage: CourseGenerationProgress.Stage) async {
            let progress = CourseGenerationProgress(stage: stage, completedSteps: completed, totalSteps: total)
            await onProgress(progress)
        }

        // 1. Gather from the library.
        await report(.gathering)
        var briefs = try await gatherLibraryBriefs(request: request)
        completed += 1
        try Task.checkCancellation()

        // 2. Research the web and import what it cites.
        var researchNotes: String?
        if request.usesWeb {
            await report(.researching)
            if let report = try await backend.research(request: request) {
                researchNotes = Self.researchNotes(from: report)
                completed += 1
                let candidates = Array(report.candidates.prefix(Self.webImportLimit))
                var importedIDs: [String] = []
                for (index, candidate) in candidates.enumerated() {
                    try Task.checkCancellation()
                    await onProgress(CourseGenerationProgress(
                        stage: .importing(done: index, total: candidates.count),
                        completedSteps: completed,
                        totalSteps: total
                    ))
                    guard let importWebSource else { break }
                    do {
                        if let sourceID = try await importWebSource(candidate), !sourceID.isEmpty {
                            importedIDs.append(sourceID)
                        }
                    } catch {
                        Self.logger.notice("Skipped web source \(candidate.url, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
                let known = Set(briefs.map(\.sourceID))
                let fresh = importedIDs.filter { !known.contains($0) }
                briefs.append(contentsOf: try await makeBriefs(sourceIDs: fresh, origin: .web))
            } else {
                completed += 1
            }
            completed += 1
        }

        guard !briefs.isEmpty || !(researchNotes ?? "").isEmpty else {
            throw CourseGenerationError.nothingToTeach
        }

        // 3. Plan.
        try Task.checkCancellation()
        await report(.planning)
        var blueprint = try await backend.plan(request: request, briefs: briefs, researchNotes: researchNotes)
        blueprint = blueprint.validated(against: Set(briefs.map(\.sourceID)))
        if let requested = request.moduleCount, blueprint.modules.count > requested {
            blueprint = CourseBlueprint(
                title: blueprint.title,
                summary: blueprint.summary,
                audience: blueprint.audience,
                modules: Array(blueprint.modules.prefix(requested))
            )
        }
        guard !blueprint.modules.isEmpty else { throw CourseGenerationError.emptyPlan }
        completed += 1
        total += blueprint.modules.count

        // 4. Write every module before anything is saved.
        var drafts: [CourseLessonDraft] = []
        drafts.reserveCapacity(blueprint.modules.count)
        for (index, module) in blueprint.modules.enumerated() {
            try Task.checkCancellation()
            await report(.writing(module: index + 1, total: blueprint.modules.count))
            var contents: [String: String] = [:]
            for sourceID in module.sourceIDs {
                if let text = await storage.loadSourceContent(sourceID), !text.isEmpty {
                    contents[sourceID] = text
                }
            }
            let draft = try await backend.writeLesson(
                blueprint: blueprint,
                moduleIndex: index,
                request: request,
                briefs: briefs,
                contents: contents,
                researchNotes: researchNotes
            )
            guard draft.isUsable else { throw CourseGenerationError.emptyLesson(module: module.title) }
            drafts.append(draft)
            completed += 1
        }

        // 5. Save; the notebook the course was asked from follows it.
        try Task.checkCancellation()
        await report(.saving)
        let saved = try await materialize(blueprint: blueprint, drafts: drafts, briefs: briefs)
        var notebookID = try await follow(saved, byNotebook: request.followingNotebookID)
        completed += 1

        // 6. Schedule.
        var goalID: String?
        var madeNotebook = false
        if let start = request.scheduleStart {
            await report(.scheduling)
            let scheduled = try await schedule(
                saved: saved,
                blueprint: blueprint,
                request: request,
                start: start,
                followingNotebookID: notebookID
            )
            notebookID = scheduled.notebookID
            goalID = scheduled.goalID
            madeNotebook = scheduled.madeNotebook
            completed += 1
        }

        await report(.finished)
        return CourseGenerationResult(
            courseID: saved.courseID,
            blueprint: blueprint,
            lectures: saved.lectures,
            lessonSourceIDs: saved.lessonSourceIDs,
            exerciseSourceIDs: saved.exerciseSourceIDs,
            attachedSourceIDs: blueprint.referencedSourceIDs,
            notebookID: notebookID,
            goalID: goalID,
            madeNotebookForCourse: madeNotebook
        )
    }

    /// Makes the notebook the course was asked from follow it
    /// (`StorageService.followCourse`): the notebook gains its sources, and
    /// every source the course gains later. The notebook was checked before
    /// anything was paid for; if it went in the minutes since (archived,
    /// deleted), the course — written and paid for — is kept followed by none
    /// and the failure is logged, rather than thrown away. Returns the
    /// notebook that follows it.
    private func follow(_ saved: Saved, byNotebook notebookID: String?) async throws -> String? {
        guard let notebookID else { return nil }
        do {
            _ = try await storage.followCourse(courseID: saved.courseID, notebookID: notebookID)
            return notebookID
        } catch {
            Self.logger.error("Notebook \(notebookID, privacy: .public) could not follow course \(saved.courseID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Gathering

    private func gatherLibraryBriefs(request: CourseGenerationRequest) async throws -> [CourseSourceBrief] {
        var orderedIDs: [String] = []
        var seen: Set<String> = []
        func collect(_ ids: [String]) {
            for id in ids where seen.insert(id).inserted {
                orderedIDs.append(id)
            }
        }
        // What the learner chose in the planning chat comes first and is
        // marked, so the planner builds on it rather than on whatever ranked.
        collect(request.chosenSourceIDs)
        let chosen = try await makeBriefs(sourceIDs: orderedIDs, origin: .chosen)
        let topicVector = try? await backend.embedQuery(request.topic)
        collect(await search(request.topic, vector: topicVector, limit: Self.librarySearchLimit))
        if !request.learnerNotes.isEmpty {
            let combined = "\(request.topic). \(request.learnerNotes)"
            let vector = try? await backend.embedQuery(combined)
            collect(await search(combined, vector: vector, limit: Self.librarySearchLimit / 2))
        }
        let searched = Array(orderedIDs.dropFirst(request.chosenSourceIDs.count))
        return chosen + (try await makeBriefs(sourceIDs: searched, origin: .library))
    }

    private func search(_ query: String, vector: [Float]?, limit: Int) async -> [String] {
        if let librarySearch {
            return await librarySearch(query, vector, limit)
        }
        return await storage.searchSources(queryText: query, queryVector: vector, limit: limit).map(\.sourceId)
    }

    /// Briefs for `sourceIDs`, in that order. Generated lessons from an earlier
    /// course are left out: a course built on another course's lessons would
    /// teach the model's own words back to it.
    private func makeBriefs(sourceIDs: [String], origin: CourseSourceBrief.Origin) async throws -> [CourseSourceBrief] {
        guard !sourceIDs.isEmpty else { return [] }
        let articles = try await storage.loadPersistedSources(ids: sourceIDs)
        let byID = Dictionary(articles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ideas = (try? await storage.loadSourceIdeas(sourceIDs: sourceIDs)) ?? [:]
        var briefs: [CourseSourceBrief] = []
        for sourceID in sourceIDs {
            guard let article = byID[sourceID], article.status == .active else { continue }
            if GeneratedCourseLesson.isGeneratedLessonURL(article.url) { continue }
            let content = await storage.loadSourceContent(sourceID)
            briefs.append(CourseSourceBrief(
                sourceID: sourceID,
                title: article.title,
                sourceType: article.sourceType,
                author: article.author,
                wordCount: article.wordCount ?? content.map { $0.split(separator: " ").count },
                excerpt: CourseSourceBrief.excerpt(from: content),
                ideas: (ideas[sourceID] ?? []).map(\.statement),
                origin: origin
            ))
        }
        return briefs
    }

    static func researchNotes(from report: DeepResearchReport) -> String {
        let notes = report.passes
            .map { pass in
                let citations = pass.citations.map { "- \($0.title): \($0.url)" }.joined(separator: "\n")
                return citations.isEmpty ? pass.notes : "\(pass.notes)\n\nCited pages:\n\(citations)"
            }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        return notes
    }

    // MARK: - Saving

    struct Saved: Sendable {
        let courseID: String
        let lectures: [CourseSession]
        let lessonSourceIDs: [String]
        let exerciseSourceIDs: [String]
        /// Source ids each module places on its day: lesson, readings, exercises.
        let sourceIDsByModule: [[String]]
    }

    /// Writes the course, its lectures, the lesson and exercise sources, and
    /// every lecture item. On any failure the course group is removed again so a
    /// half-saved course is never listed.
    func materialize(
        blueprint: CourseBlueprint,
        drafts: [CourseLessonDraft],
        briefs: [CourseSourceBrief]
    ) async throws -> Saved {
        precondition(drafts.count == blueprint.modules.count)
        let courseID = UUID().uuidString
        let typesByID = Dictionary(briefs.map { ($0.sourceID, $0.sourceType) }, uniquingKeysWith: { first, _ in first })
        let metadata = CourseMetadata(
            title: blueprint.title,
            institution: Self.institution
        )

        var lectures: [CourseSession] = []
        var items: [CourseLectureItem] = []
        var lessonSources: [StudioArticle] = []
        var lessonSourceIDs: [String] = []
        var exerciseSourceIDs: [String] = []
        var sourceIDsByModule: [[String]] = []
        let now = Date()

        for (index, module) in blueprint.modules.enumerated() {
            let number = index + 1
            let lecture = CourseSession(courseName: courseID, number: number, title: module.title, createdAt: now)
            lectures.append(lecture)

            let lesson = Self.lessonSource(
                courseID: courseID,
                number: number,
                moduleTitle: module.title,
                kind: .lesson,
                text: drafts[index].lesson,
                sortIndex: index
            )
            let exercises = Self.lessonSource(
                courseID: courseID,
                number: number,
                moduleTitle: module.title,
                kind: .exercises,
                text: drafts[index].exercises,
                sortIndex: index
            )
            lessonSources.append(lesson)
            lessonSources.append(exercises)
            lessonSourceIDs.append(lesson.id)
            exerciseSourceIDs.append(exercises.id)

            var sortIndex = 0
            items.append(CourseLectureItem(
                lectureId: lecture.id,
                sourceId: lesson.id,
                role: .notes,
                label: GeneratedCourseLesson.Kind.lesson.titlePrefix,
                sortIndex: sortIndex,
                createdAt: now
            ))
            sortIndex += 1
            for sourceID in module.sourceIDs {
                items.append(CourseLectureItem(
                    lectureId: lecture.id,
                    sourceId: sourceID,
                    role: GeneratedCourseLesson.readingRole(for: typesByID[sourceID] ?? .article),
                    sortIndex: sortIndex,
                    createdAt: now
                ))
                sortIndex += 1
            }
            items.append(CourseLectureItem(
                lectureId: lecture.id,
                sourceId: exercises.id,
                role: .exercise,
                label: GeneratedCourseLesson.Kind.exercises.titlePrefix,
                sortIndex: sortIndex,
                createdAt: now
            ))
            sourceIDsByModule.append([lesson.id] + module.sourceIDs + [exercises.id])
        }

        do {
            try await storage.saveCourseGroup(name: courseID, metadata: metadata)
            for source in lessonSources {
                try await storage.saveSource(source)
            }
            try await storage.saveCourseOutline(courseName: courseID, lectures: lectures, items: items)
        } catch {
            do {
                try await storage.deleteCourseGroup(name: courseID)
            } catch {
                Self.logger.error("Could not remove the unfinished course: \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }

        return Saved(
            courseID: courseID,
            lectures: lectures,
            lessonSourceIDs: lessonSourceIDs,
            exerciseSourceIDs: exerciseSourceIDs,
            sourceIDsByModule: sourceIDsByModule
        )
    }

    /// A lesson or exercise sheet as a course-typed source with its text
    /// attached, ready to read, review, schedule and sync.
    static func lessonSource(
        courseID: String,
        number: Int,
        moduleTitle: String,
        kind: GeneratedCourseLesson.Kind,
        text: String,
        sortIndex: Int
    ) -> StudioArticle {
        let url = GeneratedCourseLesson.url(courseID: courseID, module: number, kind: kind)
        var article = StudioArticle(
            url: url,
            title: GeneratedCourseLesson.title(module: number, moduleTitle: moduleTitle, kind: kind),
            sourceType: .course,
            discoveryOrigin: .manual,
            parentGroup: courseID
        )
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        article.domain = institution
        article.content = trimmed
        article.wordCount = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        article.state = .ready
        article.courseSortIndex = sortIndex * 2 + (kind == .lesson ? 0 : 1)
        return article
    }

    // MARK: - Scheduling

    /// The title of the Goal that carries a generated course's schedule.
    static func scheduleGoalTitle(courseTitle: String) -> String {
        "Finish \(courseTitle)"
    }

    /// The day after the last planned module: the deadline of the Goal that
    /// carries the schedule.
    static func scheduleDeadline(days: [Date], start: Date, calendar: Calendar = .current) -> Date {
        let lastDay = days.last ?? calendar.startOfDay(for: start)
        return calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay.addingTimeInterval(MemoryTutorScheduler.secondsPerDay)
    }

    /// The notebook that follows the course holds the course subscription and
    /// its source pool; a Goal nested in it carries the deadline and the day
    /// schedule, one module per planned day. A Notebook is open-ended by
    /// definition (goals-design.md), so the deadline cannot live on it, and a
    /// Goal is timebound, so the course subscription cannot live on the Goal.
    /// A course asked for in a notebook is scheduled there; with none, a
    /// notebook named after the course is made and follows it. The course
    /// itself lives in neither.
    /// Returns both ids, and whether the notebook was made.
    private func schedule(
        saved: Saved,
        blueprint: CourseBlueprint,
        request: CourseGenerationRequest,
        start: Date,
        followingNotebookID: String?
    ) async throws -> (notebookID: String, goalID: String, madeNotebook: Bool) {
        let days = GeneratedCourseLesson.plannedDays(
            start: start,
            moduleCount: blueprint.modules.count,
            daysPerModule: request.daysPerModule
        )
        let calendar = Calendar.current
        let firstDay = calendar.startOfDay(for: start)
        let lastDay = days.last ?? firstDay
        let deadline = Self.scheduleDeadline(days: days, start: start, calendar: calendar)
        let everySourceID = saved.sourceIDsByModule.flatMap { $0 }
        let notebookID: String
        let madeNotebook: Bool
        if let followingNotebookID {
            notebookID = followingNotebookID
            madeNotebook = false
        } else {
            let notebook = try await storage.createCompanionGoal(
                title: blueprint.title,
                description: blueprint.summary.isEmpty ? nil : blueprint.summary,
                topic: request.topic,
                startAt: firstDay,
                endAt: LearningGoalRecord.openEndedEndAt,
                dailyTarget: 3,
                discoveryEnabled: false,
                seedSourceIDs: []
            )
            // The notebook made for the course follows it.
            _ = try await storage.followCourse(courseID: saved.courseID, notebookID: notebook.id)
            notebookID = notebook.id
            madeNotebook = true
        }
        // The Goal's own pool is the course as it stands today, the way a
        // course group dropped on a Goal is; the Notebook keeps subscribing to
        // modules the course gains later.
        let goal = try await storage.createCompanionGoal(
            title: Self.scheduleGoalTitle(courseTitle: blueprint.title),
            description: nil,
            topic: request.topic,
            startAt: min(firstDay, deadline.addingTimeInterval(-60)),
            endAt: deadline,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: everySourceID,
            parentNotebookID: notebookID
        )
        for (index, sourceIDs) in saved.sourceIDsByModule.enumerated() {
            let day = index < days.count ? days[index] : lastDay
            for sourceID in sourceIDs {
                try await storage.addSourceToGoal(sourceID: sourceID, goalID: goal.id, plannedAt: day)
            }
        }
        return (notebookID, goal.id, madeNotebook)
    }
}
