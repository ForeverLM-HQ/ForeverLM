import Foundation
import Testing
@testable import ForeverLM

/// A backend that answers from canned plans and drafts, so the pipeline's
/// storage side can be pinned without a provider.
private struct CannedCourseBackend: CourseGenerationModelBackend {
    var blueprint: CourseBlueprint
    var drafts: [CourseLessonDraft]
    var failWritingModule: Int? = nil
    var report: DeepResearchReport? = nil

    func embedQuery(_ text: String) async throws -> [Float]? { nil }

    func research(request: CourseGenerationRequest) async throws -> DeepResearchReport? {
        request.usesWeb ? report : nil
    }

    func plan(
        request: CourseGenerationRequest,
        briefs: [CourseSourceBrief],
        researchNotes: String?
    ) async throws -> CourseBlueprint {
        blueprint
    }

    func writeLesson(
        blueprint: CourseBlueprint,
        moduleIndex: Int,
        request: CourseGenerationRequest,
        briefs: [CourseSourceBrief],
        contents: [String: String],
        researchNotes: String?
    ) async throws -> CourseLessonDraft {
        if failWritingModule == moduleIndex {
            throw AIError.apiError("writer down")
        }
        return drafts[moduleIndex]
    }
}

private func makeTemporaryStorage() -> (StorageService, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CourseGenerationTests_\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (StorageService(storeRoot: root), root)
}

private func seedSource(_ storage: StorageService, url: String, title: String, type: StudioSourceType, content: String) async throws -> String {
    var article = StudioArticle(url: url, title: title, sourceType: type, discoveryOrigin: .manual)
    article.content = content
    article.wordCount = content.split(separator: " ").count
    article.state = .ready
    try await storage.saveSource(article)
    return article.id
}

@Suite("Course Generation")
struct CourseGenerationTests {

    // MARK: - Blueprint validation

    @Test("Validation keeps only offered source ids and drops untitled modules")
    func blueprintValidation() {
        let plan = CourseBlueprint(
            title: "  Mitochondrial Transplantation  ",
            summary: "",
            audience: "",
            modules: [
                .init(title: "Why mitochondria", objectives: [" a ", ""], sourceIDs: ["s1", "ghost", "s1", "s2"], exerciseFocus: " x "),
                .init(title: "   ", objectives: [], sourceIDs: ["s2"], exerciseFocus: ""),
                .init(title: "Delivery", objectives: [], sourceIDs: ["ghost"], exerciseFocus: ""),
            ]
        )
        let validated = plan.validated(against: ["s1", "s2"])
        #expect(validated.title == "Mitochondrial Transplantation")
        #expect(validated.modules.count == 2)
        #expect(validated.modules[0].sourceIDs == ["s1", "s2"])
        #expect(validated.modules[0].objectives == ["a"])
        #expect(validated.modules[0].exerciseFocus == "x")
        #expect(validated.modules[1].sourceIDs.isEmpty)
        #expect(validated.referencedSourceIDs == ["s1", "s2"])
    }

    @Test("Planner JSON decodes from a fenced reply with snake_case keys")
    func blueprintDecoding() throws {
        let reply = """
        Here is the plan:
        ```json
        {"title": "T", "summary": "S", "audience": "A", "modules": [
          {"title": "M1", "objectives": ["o1"], "source_ids": ["a"], "exercise_focus": "f"}
        ]}
        ```
        """
        let plan: CourseBlueprint = try AIService.decodeCourseJSON(reply)
        #expect(plan.title == "T")
        #expect(plan.modules.first?.sourceIDs == ["a"])
        #expect(plan.modules.first?.exerciseFocus == "f")
    }

    @Test("A planner reply with no JSON object is an invalid response")
    func blueprintDecodingFailure() {
        #expect(throws: AIError.self) {
            let _: CourseBlueprint = try AIService.decodeCourseJSON("no plan today")
        }
    }

    // MARK: - Lesson URL grammar and scheduling helpers

    @Test("Lesson URLs are recognised and yield stable ids")
    func lessonURLGrammar() {
        let url = GeneratedCourseLesson.url(courseID: "C-1", module: 3, kind: .exercises)
        #expect(url == "foreverlm://course/C-1/exercises/3")
        #expect(GeneratedCourseLesson.isGeneratedLessonURL(url))
        #expect(GeneratedCourseLesson.isGeneratedLessonURL("foreverlm://course/C-1/lesson/1"))
        #expect(!GeneratedCourseLesson.isGeneratedLessonURL("foreverlm://course/C-1/lesson/x"))
        #expect(!GeneratedCourseLesson.isGeneratedLessonURL("foreverlm://source/abc"))
        #expect(!GeneratedCourseLesson.isGeneratedLessonURL("https://example.com/course/C-1/lesson/1"))
        let a = CourseGeneratorService.lessonSource(courseID: "C-1", number: 1, moduleTitle: "M", kind: .lesson, text: "x", sortIndex: 0)
        let b = CourseGeneratorService.lessonSource(courseID: "C-1", number: 1, moduleTitle: "M renamed", kind: .lesson, text: "y", sortIndex: 0)
        #expect(a.id == b.id)
        #expect(a.sourceType == .course)
        #expect(a.parentGroup == "C-1")
        #expect(a.state == .ready)
        #expect(a.title == "Lesson 1: M")
    }

    @Test("Planned days start on the start day and step by the cadence")
    func plannedDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 15))!
        let days = GeneratedCourseLesson.plannedDays(start: start, moduleCount: 3, daysPerModule: 2, calendar: calendar)
        #expect(days.count == 3)
        #expect(calendar.component(.day, from: days[0]) == 7)
        #expect(calendar.component(.hour, from: days[0]) == 0)
        #expect(calendar.component(.day, from: days[1]) == 9)
        #expect(calendar.component(.day, from: days[2]) == 11)
        #expect(GeneratedCourseLesson.plannedDays(start: start, moduleCount: 0, daysPerModule: 2, calendar: calendar).isEmpty)
    }

    @Test("Request clamps module count and cadence into range")
    func requestClamping() {
        let request = CourseGenerationRequest(topic: "  x  ", moduleCount: 99, daysPerModule: 0)
        #expect(request.topic == "x")
        #expect(request.moduleCount == CourseGenerationRequest.moduleCountRange.upperBound)
        #expect(request.daysPerModule == CourseGenerationRequest.daysPerModuleRange.lowerBound)
        #expect(CourseGenerationRequest(topic: "x").moduleCount == nil)
    }

    @Test("A planning chat's sources head the planner's list as chosen, and its plan is kept")
    func plannerMessageCarriesAgreedPlan() {
        let request = CourseGenerationRequest(
            topic: "mitochondrial transplantation",
            chosenSourceIDs: [" s1 ", "s1", "", "s2"],
            agreedPlan: "  1. Why transplant. 2. Delivery routes.  "
        )
        #expect(request.chosenSourceIDs == ["s1", "s2"])
        #expect(request.agreedPlan == "1. Why transplant. 2. Delivery routes.")
        let briefs = [
            CourseSourceBrief(sourceID: "s1", title: "Chosen Paper", sourceType: .paper, author: nil, wordCount: 10, excerpt: "e", ideas: [], origin: .chosen),
            CourseSourceBrief(sourceID: "s3", title: "Found Paper", sourceType: .paper, author: nil, wordCount: 10, excerpt: "e", ideas: [], origin: .library),
        ]
        let message = AIService.coursePlannerUserMessage(request: request, briefs: briefs, researchNotes: nil)
        #expect(message.contains("Plan agreed with the learner"))
        #expect(message.contains("1. Why transplant. 2. Delivery routes."))
        #expect(message.contains("title: Chosen Paper | words: 10 | chosen by the learner for this course"))
        #expect(!message.contains("title: Found Paper | words: 10 | chosen"))
        #expect(!AIService.coursePlannerUserMessage(
            request: CourseGenerationRequest(topic: "t"), briefs: briefs, researchNotes: nil
        ).contains("Plan agreed"))
    }

    @Test("Lesson budgets give every source the minimum and share the rest by length")
    func lessonBudgets() {
        let contents = [
            "long": String(repeating: "a", count: 100_000),
            "short": String(repeating: "b", count: 1_000),
            "empty": "",
        ]
        let budgets = AIService.courseLessonCharacterBudgets(for: ["long", "short", "empty"], contents: contents)
        #expect(budgets["empty"] == nil)
        #expect(budgets["short"] == AIService.courseLessonMinimumCharactersPerSource)
        #expect(budgets["long"]! > AIService.courseLessonMinimumCharactersPerSource)
        #expect(budgets.values.reduce(0, +) <= AIService.courseLessonSourceCharacterBudget)
    }

    @Test("Lesson message carries source text, cuts it at the budget, and names sourceless modules")
    func lessonMessage() {
        let plan = CourseBlueprint(
            title: "T", summary: "S", audience: "A",
            modules: [
                .init(title: "M1", objectives: ["o"], sourceIDs: ["s1"], exerciseFocus: "f"),
                .init(title: "M2", objectives: [], sourceIDs: [], exerciseFocus: ""),
            ]
        )
        let briefs = [
            CourseSourceBrief(sourceID: "s1", title: "Paper One", sourceType: .paper, author: nil, wordCount: 10, excerpt: "e", ideas: [], origin: .library),
        ]
        let long = String(repeating: "z", count: AIService.courseLessonSourceCharacterBudget + 10)
        let message = AIService.courseLessonUserMessage(
            blueprint: plan, moduleIndex: 0, request: CourseGenerationRequest(topic: "t"),
            briefs: briefs, contents: ["s1": long], researchNotes: nil
        )
        #expect(message.contains("=== Paper One (paper) ==="))
        #expect(message.contains("[Text cut here at"))
        #expect(!message.contains("Earlier modules"))

        let second = AIService.courseLessonUserMessage(
            blueprint: plan, moduleIndex: 1, request: CourseGenerationRequest(topic: "t"),
            briefs: briefs, contents: [:], researchNotes: "notes"
        )
        #expect(second.contains("Earlier modules, already covered: M1"))
        #expect(second.contains("Sources: none for this module"))
        #expect(second.contains("Research notes:\nnotes"))
    }

    // MARK: - Pipeline against real storage

    @Test("A generated course is saved as lectures, readings, lessons, exercises, and a schedule")
    func pipelinePersistsCourseAndSchedule() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }

        // A book chapter rather than a paper: papers cannot become ready without the
        // metadata gate, and the reading role is what this test is about.
        let paper = try await seedSource(storage, url: "https://example.org/chapter", title: "Mito Chapter", type: .book, content: "Mitochondria transfer between cells.")
        let video = try await seedSource(storage, url: "https://www.youtube.com/watch?v=abc123", title: "Mito Talk", type: .video, content: "A talk about organelle delivery.")
        let article = try await seedSource(storage, url: "https://example.org/article", title: "Mito Article", type: .article, content: "Clinical trials so far.")

        let plan = CourseBlueprint(
            title: "Mitochondrial Transplantation",
            summary: "From organelle biology to the clinic.",
            audience: "A biologist new to the field.",
            modules: [
                .init(title: "Why transplant mitochondria", objectives: ["Explain the rationale"], sourceIDs: [paper, video, "not-a-source"], exerciseFocus: "rationale"),
                .init(title: "Clinical evidence", objectives: ["Weigh the trials"], sourceIDs: [article], exerciseFocus: "evidence"),
            ]
        )
        let drafts = [
            CourseLessonDraft(lesson: "Lesson one text.", exercises: "1. First exercise."),
            CourseLessonDraft(lesson: "Lesson two text.", exercises: "1. Second exercise."),
        ]
        let service = CourseGeneratorService(
            storage: storage,
            backend: CannedCourseBackend(blueprint: plan, drafts: drafts),
            librarySearch: { _, _, _ in [paper, video, article] }
        )
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        let start = calendar.startOfDay(for: Date()).addingTimeInterval(9 * 3600)
        let request = CourseGenerationRequest(topic: "mitochondrial transplantation", scheduleStart: start, daysPerModule: 3)

        let result = try await service.run(request: request)

        // Course and lectures.
        let metadata = try await storage.loadCourseMetadata()[result.courseID]
        #expect(metadata?.title == "Mitochondrial Transplantation")
        #expect(metadata?.institution == CourseGeneratorService.institution)
        let lectures = try await storage.loadCourseLectures().filter { $0.courseName == result.courseID }
        #expect(lectures.map(\.number) == [1, 2])
        #expect(lectures.map(\.title) == ["Why transplant mitochondria", "Clinical evidence"])
        #expect(result.lectures.map(\.id) == lectures.map(\.id))

        // Items: lesson first, readings by natural role, exercises last; the ghost id is gone.
        let items = try await storage.loadCourseLectureItems()
        let first = items.filter { $0.lectureId == lectures[0].id }.sorted { $0.sortIndex < $1.sortIndex }
        #expect(first.map(\.role) == [.notes, .reading, .video, .exercise])
        #expect(first.map(\.sourceId) == [result.lessonSourceIDs[0], paper, video, result.exerciseSourceIDs[0]])
        #expect(!items.contains { $0.sourceId == "not-a-source" })
        let second = items.filter { $0.lectureId == lectures[1].id }.sorted { $0.sortIndex < $1.sortIndex }
        #expect(second.map(\.role) == [.notes, .article, .exercise])

        // Lesson sources are course material in the course, with the written text.
        let lessons = try await storage.loadPersistedSources(ids: result.lessonSourceIDs + result.exerciseSourceIDs)
        #expect(lessons.count == 4)
        #expect(lessons.allSatisfy { $0.sourceType == .course && $0.parentGroup == result.courseID && $0.state == .ready })
        let lessonOne = await storage.loadSourceContent(result.lessonSourceIDs[0])
        #expect(lessonOne == "Lesson one text.")
        let exercisesTwo = await storage.loadSourceContent(result.exerciseSourceIDs[1])
        #expect(exercisesTwo == "1. Second exercise.")
        #expect(lessons.first { $0.id == result.lessonSourceIDs[1] }?.title == "Lesson 2: Clinical evidence")

        // Schedule: an open-ended Notebook holds the course; a Goal tagged to it
        // carries the deadline and one module per planned day. Asked for in
        // no notebook, the Notebook is made for the course and follows it.
        let notebookID = try #require(result.notebookID)
        let goalID = try #require(result.goalID)
        let goals = try await storage.loadLearningGoals()
        let notebook = try #require(goals.first { $0.id == notebookID })
        #expect(notebook.isNotebook)
        #expect(notebook.title == "Mitochondrial Transplantation")
        let linkedCourseIDs = try await storage.linkedCourseIDsForNotebook(goalID: notebookID)
        #expect(linkedCourseIDs == [result.courseID])
        #expect(result.madeNotebookForCourse)
        let dayOne = calendar.startOfDay(for: start)
        let dayTwo = calendar.date(byAdding: .day, value: 3, to: dayOne)!
        let goal = try #require(goals.first { $0.id == goalID })
        #expect(goal.isNotebookGoal)
        #expect(goal.parentNotebookID == notebookID)
        #expect(goal.title == "Finish Mitochondrial Transplantation")
        #expect(calendar.startOfDay(for: goal.endAt) == calendar.date(byAdding: .day, value: 1, to: dayTwo))
        let notebookPlacements = try await storage.loadScheduledSources(goalID: notebookID)
        #expect(notebookPlacements.isEmpty, "a Notebook has no timeline of its own")
        let placements = try await storage.loadScheduledSources(goalID: goalID)
        func day(of sourceID: String) -> Date? {
            placements.first { $0.placement.sourceID == sourceID }.map { calendar.startOfDay(for: $0.placement.plannedAt) }
        }
        #expect(day(of: result.lessonSourceIDs[0]) == dayOne)
        #expect(day(of: paper) == dayOne)
        #expect(day(of: video) == dayOne)
        #expect(day(of: result.exerciseSourceIDs[0]) == dayOne)
        #expect(day(of: result.lessonSourceIDs[1]) == dayTwo)
        #expect(day(of: article) == dayTwo)
        #expect(placements.allSatisfy { !$0.isAutomatic })
    }

    @Test("A writer failure leaves no course behind")
    func writerFailureLeavesNothing() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let paper = try await seedSource(storage, url: "https://example.org/p", title: "P", type: .article, content: "text")
        let plan = CourseBlueprint(
            title: "T", summary: "", audience: "",
            modules: [
                .init(title: "M1", objectives: [], sourceIDs: [paper], exerciseFocus: ""),
                .init(title: "M2", objectives: [], sourceIDs: [paper], exerciseFocus: ""),
            ]
        )
        let drafts = [CourseLessonDraft(lesson: "l", exercises: "e"), CourseLessonDraft(lesson: "l", exercises: "e")]
        let service = CourseGeneratorService(
            storage: storage,
            backend: CannedCourseBackend(blueprint: plan, drafts: drafts, failWritingModule: 1),
            librarySearch: { _, _, _ in [paper] }
        )
        await #expect(throws: AIError.self) {
            _ = try await service.run(request: CourseGenerationRequest(topic: "t"))
        }
        let metadata = try await storage.loadCourseMetadata()
        let lectures = try await storage.loadCourseLectures()
        let survivors = try await storage.loadPersistedSources(ids: [paper])
        #expect(metadata.isEmpty)
        #expect(lectures.isEmpty)
        #expect(survivors.count == 1)
    }

    @Test("An empty library with no research is refused before any model call")
    func emptyLibraryIsRefused() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = CourseBlueprint(title: "T", summary: "", audience: "", modules: [])
        let service = CourseGeneratorService(
            storage: storage,
            backend: CannedCourseBackend(blueprint: plan, drafts: []),
            librarySearch: { _, _, _ in [] }
        )
        await #expect(throws: CourseGenerationError.nothingToTeach) {
            _ = try await service.run(request: CourseGenerationRequest(topic: "t"))
        }
    }

    @Test("Web research imports cited pages and the plan may use them")
    func webImportsBecomeSources() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let importedURL = "https://example.org/imported"
        let importedID = try await seedSource(storage, url: importedURL, title: "Imported", type: .article, content: "Imported text")
        let report = DeepResearchReport(
            question: "q",
            passes: [DeepResearchPass(id: "a", title: "Research", notes: "Notes about the topic.", citations: [AIWebCitation(url: importedURL, title: "Imported")])],
            candidates: [DeepResearchCandidate(id: "example.org/imported", url: importedURL, title: "Imported", domain: "example.org", foundBy: ["Research"])],
            completedAt: Date()
        )
        let plan = CourseBlueprint(
            title: "T", summary: "", audience: "",
            modules: [.init(title: "M1", objectives: [], sourceIDs: [importedID], exerciseFocus: "")]
        )
        let imported = ImportLog()
        let service = CourseGeneratorService(
            storage: storage,
            backend: CannedCourseBackend(blueprint: plan, drafts: [CourseLessonDraft(lesson: "l", exercises: "e")], report: report),
            importWebSource: { candidate in
                await imported.record(candidate.url)
                return importedID
            },
            librarySearch: { _, _, _ in [] }
        )
        let result = try await service.run(request: CourseGenerationRequest(topic: "t", usesWeb: true))
        let importedURLs = await imported.urls
        #expect(importedURLs == [importedURL])
        #expect(result.attachedSourceIDs == [importedID])
        let items = try await storage.loadCourseLectureItems()
        #expect(items.contains { $0.sourceId == importedID && $0.role == .article })
    }

    @Test("generate_course is registered as an open-world tool and the instructions point at it")
    func mcpRegistration() {
        let toolNames = Set(MCPToolRegistry.shared.tools.map(\.name))
        #expect(toolNames.contains("generate_course"))
        #expect(MCPToolRegistry.annotations(for: "generate_course")["openWorldHint"] as? Bool == true)
        #expect(MCPToolRegistry.annotations(for: "generate_course")["readOnlyHint"] as? Bool == false)
        #expect(Prompts.mcpServerInstructions.contains("generate_course"))
    }

    // MARK: - A course made in a notebook (docs/notebooks-design.md, "Homing")

    @Test("A course asked for in a notebook lives there and makes no Notebook of its own")
    func homesInTheNotebookItWasAskedFrom() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let reading = try await seedSource(storage, url: "https://example.org/notebook-reading", title: "Reading", type: .article, content: "Cristae shape matters.")
        let notebook = try await storage.createCompanionGoal(
            title: "Cristae", topic: "cristae", startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
        )
        let plan = CourseBlueprint(
            title: "Cristae in Depth", summary: "", audience: "",
            modules: [.init(title: "Shape", objectives: [], sourceIDs: [reading], exerciseFocus: "")]
        )
        let service = CourseGeneratorService(
            storage: storage,
            backend: CannedCourseBackend(blueprint: plan, drafts: [CourseLessonDraft(lesson: "Lesson.", exercises: "1. Exercise.")]),
            librarySearch: { _, _, _ in [reading] }
        )
        let notebooksBefore = try await storage.loadLearningGoals().filter(\.isNotebook).count

        let result = try await service.run(request: CourseGenerationRequest(topic: "cristae", followingNotebookID: notebook.id))

        #expect(result.notebookID == notebook.id)
        #expect(result.goalID == nil)
        #expect(!result.madeNotebookForCourse)
        #expect(try await storage.linkedCourseIDsForNotebook(goalID: notebook.id) == [result.courseID])
        #expect(try await storage.loadLearningGoals().filter(\.isNotebook).count == notebooksBefore, "no Notebook of its own")
        let pool = Set(try await storage.loadLearningGoal(notebook.id)?.approvedSourceIDs ?? [])
        #expect(pool.isSuperset(of: [reading, result.lessonSourceIDs[0], result.exerciseSourceIDs[0]]), "the notebook gains the course's sources")
    }

    @Test("A course scheduled in a notebook nests its Goal there")
    func schedulesInsideTheNotebook() async throws {
        let (storage, root) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let reading = try await seedSource(storage, url: "https://example.org/scheduled-reading", title: "Reading", type: .article, content: "Supercomplexes.")
        let notebook = try await storage.createCompanionGoal(
            title: "Respiration", topic: "respiration", startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: []
        )
        let plan = CourseBlueprint(
            title: "Supercomplexes", summary: "", audience: "",
            modules: [.init(title: "Assembly", objectives: [], sourceIDs: [reading], exerciseFocus: "")]
        )
        let service = CourseGeneratorService(
            storage: storage,
            backend: CannedCourseBackend(blueprint: plan, drafts: [CourseLessonDraft(lesson: "Lesson.", exercises: "1. Exercise.")]),
            librarySearch: { _, _, _ in [reading] }
        )
        let notebooksBefore = try await storage.loadLearningGoals().filter(\.isNotebook).count

        let result = try await service.run(request: CourseGenerationRequest(
            topic: "respiration", scheduleStart: Date(), daysPerModule: 2, followingNotebookID: notebook.id
        ))

        #expect(result.notebookID == notebook.id)
        #expect(!result.madeNotebookForCourse)
        let goalID = try #require(result.goalID)
        let goal = try #require(try await storage.loadLearningGoal(goalID))
        #expect(goal.parentNotebookID == notebook.id)
        #expect(try await storage.loadLearningGoals().filter(\.isNotebook).count == notebooksBefore)
        #expect(try await storage.linkedCourseIDsForNotebook(goalID: notebook.id) == [result.courseID])
    }

    @Test("Every course-generation task has a Settings descriptor and a default prompt")
    func tasksAreConfigurable() {
        for task in [AITask.courseCurriculumPlan, .courseLessonWriting] {
            #expect(AITaskSettingsCatalog.descriptor(forRawID: task.rawValue) != nil)
            #expect(task.defaultPrompt?.isEmpty == false)
            #expect(AITask.advancedTasks.contains(task))
            #expect(task.sourceType == .course)
        }
    }
}

private actor ImportLog {
    var urls: [String] = []
    func record(_ url: String) { urls.append(url) }
}
