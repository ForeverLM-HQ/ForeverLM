import Foundation

extension AIService {

    /// Plan a course over the offered sources.
    ///
    /// The returned blueprint is already validated against `briefs`: a source
    /// id the model made up is dropped here, so no caller can forget to do it.
    /// An empty plan is an error, never a silently empty course.
    func planCourse(
        request: CourseGenerationRequest,
        briefs: [CourseSourceBrief],
        researchNotes: String?,
        config: AITaskConfig
    ) async throws -> CourseBlueprint {
        let system = AITask.courseCurriculumPlan.effectivePrompt ?? Prompts.courseCurriculumPlanner
        let user = Self.coursePlannerUserMessage(
            request: request,
            briefs: briefs,
            researchNotes: researchNotes
        )
        let response = try await call(
            config: config,
            system: system,
            user: user,
            maxTokens: 4_000,
            temperature: 0.4,
            jsonMode: true
        )
        let plan: CourseBlueprint = try Self.decodeCourseJSON(response)
        let validated = plan.validated(against: Set(briefs.map(\.sourceID)))
        guard !validated.modules.isEmpty, !validated.title.isEmpty else {
            throw CourseGenerationError.emptyPlan
        }
        return validated
    }

    /// Write one module's lesson and exercise sheet from its sources' text.
    func writeCourseLesson(
        blueprint: CourseBlueprint,
        moduleIndex: Int,
        request: CourseGenerationRequest,
        briefs: [CourseSourceBrief],
        contents: [String: String],
        researchNotes: String?,
        config: AITaskConfig
    ) async throws -> CourseLessonDraft {
        let module = blueprint.modules[moduleIndex]
        let system = AITask.courseLessonWriting.effectivePrompt ?? Prompts.courseLessonWriter
        let user = Self.courseLessonUserMessage(
            blueprint: blueprint,
            moduleIndex: moduleIndex,
            request: request,
            briefs: briefs,
            contents: contents,
            researchNotes: researchNotes
        )
        let response = try await call(
            config: config,
            system: system,
            user: user,
            maxTokens: 6_000,
            temperature: 0.5,
            jsonMode: true
        )
        let draft: CourseLessonDraft = try Self.decodeCourseJSON(response)
        guard draft.isUsable else {
            throw CourseGenerationError.emptyLesson(module: module.title)
        }
        return draft
    }

    // MARK: - Message construction

    /// Characters of source text one lesson call may carry, split across the
    /// module's sources. A long paper is cut, not dropped; the writer is told.
    static let courseLessonSourceCharacterBudget = 60_000
    static let courseLessonMinimumCharactersPerSource = 4_000

    static func coursePlannerUserMessage(
        request: CourseGenerationRequest,
        briefs: [CourseSourceBrief],
        researchNotes: String?
    ) -> String {
        var lines: [String] = []
        lines.append("Topic: \(request.topic)")
        if !request.learnerNotes.isEmpty {
            lines.append("Learner's notes: \(request.learnerNotes)")
        }
        if let block = CourseLearnerContext(aboutYou: request.learnerBackground).promptBlock {
            lines.append(block)
        }
        if let count = request.moduleCount {
            lines.append("Requested module count: \(count)")
        }
        if !request.agreedPlan.isEmpty {
            lines.append("")
            lines.append("Plan agreed with the learner (follow it: its modules, order and emphasis; fill in objectives, sources and exercise focus):")
            lines.append(request.agreedPlan)
        }
        lines.append("")
        if briefs.isEmpty {
            lines.append("Sources: none. Plan from the research notes alone; every module has an empty source_ids list.")
        } else {
            lines.append("Sources (\(briefs.count)):")
            for (index, brief) in briefs.enumerated() {
                lines.append(contentsOf: briefLines(brief, index: index + 1))
                lines.append("")
            }
        }
        if let researchNotes, !researchNotes.isEmpty {
            lines.append("Research notes:")
            lines.append(researchNotes)
        }
        return lines.joined(separator: "\n")
    }

    static func courseLessonUserMessage(
        blueprint: CourseBlueprint,
        moduleIndex: Int,
        request: CourseGenerationRequest,
        briefs: [CourseSourceBrief],
        contents: [String: String],
        researchNotes: String?
    ) -> String {
        let module = blueprint.modules[moduleIndex]
        let briefsByID = Dictionary(briefs.map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
        var lines: [String] = []
        lines.append("Course: \(blueprint.title)")
        if !blueprint.summary.isEmpty { lines.append("Course summary: \(blueprint.summary)") }
        if !blueprint.audience.isEmpty { lines.append("Audience: \(blueprint.audience)") }
        if !request.learnerNotes.isEmpty { lines.append("Learner's notes: \(request.learnerNotes)") }
        if let block = CourseLearnerContext(aboutYou: request.learnerBackground).promptBlock {
            lines.append(block)
        }
        lines.append("")
        lines.append("Module \(moduleIndex + 1) of \(blueprint.modules.count): \(module.title)")
        if moduleIndex > 0 {
            let earlier = blueprint.modules[..<moduleIndex].map(\.title).joined(separator: "; ")
            lines.append("Earlier modules, already covered: \(earlier)")
        }
        if !module.objectives.isEmpty {
            lines.append("Objectives:")
            for objective in module.objectives { lines.append("- \(objective)") }
        }
        if !module.exerciseFocus.isEmpty {
            lines.append("Exercise focus: \(module.exerciseFocus)")
        }
        lines.append("")

        let budgets = courseLessonCharacterBudgets(for: module.sourceIDs, contents: contents)
        if module.sourceIDs.isEmpty {
            lines.append("Sources: none for this module. Teach from the research notes and your own explanation, and say in the lesson that the library holds no source for it yet.")
        } else {
            lines.append("Sources (\(module.sourceIDs.count)):")
            for sourceID in module.sourceIDs {
                let title = briefsByID[sourceID]?.title ?? sourceID
                let type = briefsByID[sourceID]?.sourceType.rawValue ?? "source"
                lines.append("")
                lines.append("=== \(title) (\(type)) ===")
                if let text = contents[sourceID]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    let budget = budgets[sourceID] ?? courseLessonMinimumCharactersPerSource
                    if text.count > budget {
                        lines.append(String(text.prefix(budget)))
                        lines.append("[Text cut here at \(budget) characters; the source continues.]")
                    } else {
                        lines.append(text)
                    }
                } else if let brief = briefsByID[sourceID] {
                    lines.append("[No text is available for this source yet. Known about it: \(brief.excerpt.isEmpty ? "only its title" : brief.excerpt)]")
                } else {
                    lines.append("[No text is available for this source yet.]")
                }
            }
        }
        if let researchNotes, !researchNotes.isEmpty {
            lines.append("")
            lines.append("Research notes:")
            lines.append(researchNotes)
        }
        return lines.joined(separator: "\n")
    }

    /// Splits the lesson budget across a module's sources: every source with
    /// text gets at least the minimum, and what is left is shared in proportion
    /// to length so a long primary source is not cut to the size of a blog post.
    static func courseLessonCharacterBudgets(for sourceIDs: [String], contents: [String: String]) -> [String: Int] {
        let withText = sourceIDs.filter { !(contents[$0]?.isEmpty ?? true) }
        guard !withText.isEmpty else { return [:] }
        let minimum = courseLessonMinimumCharactersPerSource
        let total = max(courseLessonSourceCharacterBudget, minimum * withText.count)
        let lengths = withText.map { min(contents[$0]?.count ?? 0, total) }
        let remainder = total - minimum * withText.count
        let excess = zip(withText, lengths).map { max(0, $1 - minimum) }
        let excessTotal = excess.reduce(0, +)
        var budgets: [String: Int] = [:]
        for (index, sourceID) in withText.enumerated() {
            let share = excessTotal > 0 ? Int(Double(remainder) * Double(excess[index]) / Double(excessTotal)) : 0
            budgets[sourceID] = minimum + share
        }
        return budgets
    }

    private static func briefLines(_ brief: CourseSourceBrief, index: Int) -> [String] {
        var header = "\(index). id: \(brief.sourceID) | type: \(brief.sourceType.rawValue) | title: \(brief.title)"
        if let author = brief.author, !author.isEmpty { header += " | author: \(author)" }
        if let words = brief.wordCount, words > 0 { header += " | words: \(words)" }
        switch brief.origin {
        case .web: header += " | imported from the web for this course"
        case .chosen: header += " | chosen by the learner for this course"
        case .library: break
        }
        var lines = [header]
        if !brief.excerpt.isEmpty {
            lines.append("   excerpt: \(brief.excerpt)")
        }
        if !brief.ideas.isEmpty {
            lines.append("   ideas: " + brief.ideas.prefix(6).joined(separator: " / "))
        }
        return lines
    }

    static func decodeCourseJSON<T: Decodable>(_ response: String) throws -> T {
        do {
            return try MemoryReviewPlanning.decodeJSON(response)
        } catch {
            throw AIError.invalidResponse
        }
    }
}
